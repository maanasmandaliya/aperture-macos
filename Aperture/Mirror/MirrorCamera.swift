//
//  MirrorCamera.swift
//  Aperture
//
//  The camera behind the Mirror pane. AVFoundation only — public API throughout.
//
//  `AVCaptureSession.startRunning()` and `stopRunning()` block while the camera
//  powers up and down, so every session call happens on one serial queue inside
//  ``MirrorPipeline`` and the main actor only receives results. The session is
//  not `Sendable`; the pipeline is `@unchecked Sendable` because that queue is
//  the only place its state is touched. The one exception is attaching a preview
//  layer, which AVFoundation supports from the main thread.
//
//  Two rules shape the lifecycle, and both are about the camera light. The
//  session runs only while the Mirror pane is on screen: the overlay reports
//  every presentation change, and anything but `.expanded(.mirror)` stops it.
//  And nothing here asks macOS for access on its own — the pane's button is the
//  only caller of ``requestAccess()``, the same rule the calendar follows.
//

import AppKit
import AVFoundation
import ImageIO
import Observation
import OSLog
import UniformTypeIdentifiers

@MainActor
@Observable
final class MirrorCamera {

    enum Access: Equatable, Sendable {
        case notRequested
        case authorized
        case denied
        case restricted

        var statusText: String {
            switch self {
            case .notRequested:
                "Aperture asks macOS for the camera only when you choose to. Nothing is recorded or sent anywhere."
            case .authorized:
                "Camera access granted."
            case .denied:
                "Camera access is off for Aperture. Turn it on in System Settings ▸ Privacy & Security ▸ Camera."
            case .restricted:
                "Camera access is restricted on this Mac, for example by a management profile."
            }
        }
    }

    enum Status: Equatable, Sendable {
        /// Not running, with nothing wrong.
        case idle
        /// Asked to run; the camera is still powering up.
        case starting
        case running
        /// No camera this Mac can use: none built in, or the lid is closed with
        /// nothing attached.
        case noCamera
        case failed(String)
    }

    private(set) var access: Access
    private(set) var status: Status = .idle
    /// The camera in use, e.g. "FaceTime HD Camera".
    private(set) var cameraName: String?
    private(set) var isCapturing = false
    /// The photo most recently saved, for "Show in Finder".
    private(set) var lastPhoto: URL?
    private(set) var photoError: String?

    @ObservationIgnored let pipeline = MirrorPipeline()
    @ObservationIgnored private var showsMirror = false
    @ObservationIgnored private var isDisplayAsleep = false
    /// Incremented on every start or stop request, so a slow start that
    /// finishes after a newer stop cannot report the camera as running.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private let log = Logger(subsystem: ApertureInfo.bundleIdentifier, category: "Mirror")

    init() {
        access = Self.currentAccess()
        observeSleep()
    }

    // MARK: - Access

    func refreshAccess() {
        access = Self.currentAccess()
    }

    /// Raises the macOS camera prompt. Called only from the pane's button.
    func requestAccess() async {
        refreshAccess()
        guard access == .notRequested else { return }
        _ = await AVCaptureDevice.requestAccess(for: .video)
        refreshAccess()
        apply()
    }

    static func openPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") else { return }
        NSWorkspace.shared.open(url)
    }

    private static func currentAccess() -> Access {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: .authorized
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined: .notRequested
        @unknown default: .denied
        }
    }

    // MARK: - Running

    /// Reported by the overlay on every presentation change.
    func setShowsMirror(_ shows: Bool) {
        guard shows != showsMirror else { return }
        showsMirror = shows
        apply()
    }

    /// Called whenever the hub opens, on any pane, so opening the mirror only
    /// has to start the camera rather than find and wire it first. Nothing
    /// runs, so the camera light stays off; without access it does nothing.
    func prepare() {
        refreshAccess()
        guard access == .authorized else { return }
        pipeline.prepare()
    }

    /// Tries again after "no camera" or a failure — the lid opened, a camera was
    /// plugged in, or another app let go of it.
    func retry() {
        apply()
    }

    func invalidate() {
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers.removeAll()
        showsMirror = false
        apply()
    }

    private func apply() {
        refreshAccess()
        let shouldRun = MirrorGeometry.shouldRun(
            showsMirror: showsMirror,
            isAuthorized: access == .authorized,
            isDisplayAsleep: isDisplayAsleep
        )
        generation += 1
        let request = generation
        if shouldRun, status != .running { status = .starting }

        pipeline.setRunning(shouldRun) { [weak self] outcome in
            Task { @MainActor in
                guard let self, request == self.generation else { return }
                self.receive(outcome)
            }
        }
    }

    private func receive(_ outcome: MirrorPipeline.Outcome) {
        switch outcome {
        case .running(let name):
            status = .running
            cameraName = name
        case .stopped:
            status = .idle
        case .noCamera:
            status = .noCamera
            cameraName = nil
        case .failed(let reason):
            status = .failed(reason)
            log.notice("Mirror camera did not start: \(reason, privacy: .public)")
        }
    }

    /// A sleeping display means nobody is looking, so the camera stops, and
    /// resumes on wake if the pane is still open.
    private func observeSleep() {
        let center = NSWorkspace.shared.notificationCenter
        let transitions: [(Notification.Name, Bool)] = [
            (NSWorkspace.screensDidSleepNotification, true),
            (NSWorkspace.willSleepNotification, true),
            (NSWorkspace.screensDidWakeNotification, false),
            (NSWorkspace.didWakeNotification, false),
        ]
        for (name, asleep) in transitions {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.isDisplayAsleep = asleep
                    self.apply()
                }
            }
            observers.append(token)
        }
    }

    // MARK: - Photos

    /// Captures a still, cropped and flipped to exactly what the pane shows,
    /// and saves it to Pictures ▸ Aperture.
    func capturePhoto(mirrored: Bool, viewAspect: CGFloat) async {
        guard status == .running, !isCapturing else { return }
        isCapturing = true
        defer { isCapturing = false }

        do {
            let raw = try await pipeline.capturePhoto()
            let saved = try await Task.detached(priority: .userInitiated) {
                try Self.save(raw, mirrored: mirrored, viewAspect: viewAspect, at: Date())
            }.value
            lastPhoto = saved
            photoError = nil
        } catch {
            photoError = "The photo couldn't be saved."
            log.error("Mirror photo failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func revealLastPhoto() {
        guard let lastPhoto else { return }
        NSWorkspace.shared.activateFileViewerSelecting([lastPhoto])
    }

    nonisolated static func save(
        _ data: Data,
        mirrored: Bool,
        viewAspect: CGFloat,
        at date: Date
    ) throws -> URL {
        let jpeg = try render(data, mirrored: mirrored, viewAspect: viewAspect)
        let directory = MirrorGeometry.photosDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = MirrorGeometry.availableURL(
            in: directory,
            named: MirrorGeometry.photoFileName(for: date)
        ) { FileManager.default.fileExists(atPath: $0.path) }
        try jpeg.write(to: target, options: .withoutOverwriting)
        return target
    }

    /// Repeats the preview's crop and flip on the full-resolution frame, so the
    /// saved photo is what was on screen rather than what the sensor saw.
    nonisolated static func render(
        _ data: Data,
        mirrored: Bool,
        viewAspect: CGFloat
    ) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let frame = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw MirrorError.unreadablePhoto
        }

        let crop = MirrorGeometry.visibleRect(
            imageSize: CGSize(width: frame.width, height: frame.height),
            viewAspect: viewAspect
        )
        guard let cropped = frame.cropping(to: crop),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: cropped.width,
                height: cropped.height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: space,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              ) else {
            throw MirrorError.encodingFailed
        }

        if mirrored {
            context.translateBy(x: CGFloat(cropped.width), y: 0)
            context.scaleBy(x: -1, y: 1)
        }
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: cropped.width, height: cropped.height))

        let output = NSMutableData()
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithData(
                output, UTType.jpeg.identifier as CFString, 1, nil
              ) else {
            throw MirrorError.encodingFailed
        }
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: 0.92
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw MirrorError.encodingFailed }
        return output as Data
    }
}

enum MirrorError: Error {
    case notRunning
    case unreadablePhoto
    case encodingFailed
}

// MARK: - Pipeline

/// Owns the capture session and does all of its work on one serial queue.
final class MirrorPipeline: @unchecked Sendable {

    enum Outcome: Sendable {
        case running(cameraName: String)
        case stopped
        case noCamera
        case failed(String)
    }

    /// Configured and run only on `queue`.
    let session: AVCaptureSession

    /// The one preview layer, made without a connection and joined to the
    /// camera on `queue` during configuration. That keeps the main thread from
    /// ever touching the session: on a reopen, with the pane building a
    /// connected layer of its own and reading its connection, the main thread
    /// was measured stalled for 1.7 s — the whole of `startRunning`.
    let previewLayer: AVCaptureVideoPreviewLayer

    private let queue = DispatchQueue(label: "com.aperture.mirror.session", qos: .userInitiated)
    private let log = Logger(subsystem: ApertureInfo.bundleIdentifier, category: "Mirror")
    private let photoOutput = AVCapturePhotoOutput()
    private var input: AVCaptureDeviceInput?
    /// AVFoundation holds capture delegates weakly, so they live here until
    /// they report.
    private var pendingCaptures: [ObjectIdentifier: PhotoCaptureDelegate] = [:]

    init() {
        let session = AVCaptureSession()
        self.session = session
        previewLayer = AVCaptureVideoPreviewLayer(sessionWithNoConnection: session)
        previewLayer.videoGravity = .resizeAspectFill
    }

    func setRunning(_ running: Bool, completion: @escaping @Sendable (Outcome) -> Void) {
        queue.async {
            completion(running ? self.start() : self.stop())
        }
    }

    /// Finds the camera and wires the session, once. `nil` means ready.
    private func configureIfNeeded() -> Outcome? {
        guard input == nil else { return nil }
        let begin = DispatchTime.now()
        guard let device = Self.preferredCamera() else { return .noCamera }
        let discovered = DispatchTime.now()
        do {
            let input = try AVCaptureDeviceInput(device: device)
            let opened = DispatchTime.now()
            session.beginConfiguration()
            defer {
                session.commitConfiguration()
                log.debug("configure: discovery \(Self.ms(begin, discovered)) ms, input \(Self.ms(discovered, opened)) ms, commit \(Self.ms(opened, .now())) ms")
            }
            session.sessionPreset = .high
            guard session.canAddInput(input) else { return .failed("The camera couldn't be attached.") }
            session.addInput(input)
            if let port = input.ports.first(where: { $0.mediaType == .video }) {
                let connection = AVCaptureConnection(inputPort: port, videoPreviewLayer: previewLayer)
                // Mirroring is the view's transform; the connection's own is
                // switched off here, once, so the two cannot stack.
                if connection.isVideoMirroringSupported {
                    connection.automaticallyAdjustsVideoMirroring = false
                    connection.isVideoMirrored = false
                }
                if session.canAddConnection(connection) { session.addConnection(connection) }
            }
            if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }
            self.input = input
            return nil
        } catch {
            return .failed("The camera couldn't be opened.")
        }
    }

    /// Does the slow, silent part of starting — finding the camera and wiring
    /// the session — ahead of time. Nothing runs, so the camera light stays off.
    func prepare() {
        queue.async { _ = self.configureIfNeeded() }
    }

    private func start() -> Outcome {
        let begin = DispatchTime.now()
        if let problem = configureIfNeeded() { return problem }

        let beforeRun = DispatchTime.now()
        if !session.isRunning { session.startRunning() }
        let previewLive = previewLayer.connection.map { $0.isActive && $0.isEnabled } ?? false
        log.debug("start: setup \(Self.ms(begin, beforeRun)) ms, startRunning \(Self.ms(beforeRun, .now())) ms, preview connected \(previewLive)")

        guard session.isRunning, let input else {
            // Dropped so the next attempt rediscovers the camera — the device
            // behind a stale input may have been unplugged, or the lid closed.
            if let input {
                session.beginConfiguration()
                session.removeInput(input)
                session.commitConfiguration()
                self.input = nil
            }
            return .failed("The camera didn't start. Another app may be using it.")
        }
        return .running(cameraName: input.device.localizedName)
    }

    private static func ms(_ from: DispatchTime, _ to: DispatchTime) -> Int {
        Int((to.uptimeNanoseconds - from.uptimeNanoseconds) / 1_000_000)
    }

    private func stop() -> Outcome {
        if session.isRunning { session.stopRunning() }
        return .stopped
    }

    /// The built-in camera — the one in the notch — first, then a wired camera.
    /// Continuity Camera is left out on purpose: an iPhone taking over the
    /// mirror because it happened to be nearby would be a surprise.
    static func preferredCamera() -> AVCaptureDevice? {
        let devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external],
            mediaType: .video,
            position: .unspecified
        ).devices
        return devices.first { $0.deviceType == .builtInWideAngleCamera }
            ?? devices.first { $0.deviceType == .external }
    }

    func capturePhoto() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard self.session.isRunning else {
                    continuation.resume(throwing: MirrorError.notRunning)
                    return
                }
                let delegate = PhotoCaptureDelegate { [weak self] finished, result in
                    continuation.resume(with: result)
                    self?.queue.async { self?.pendingCaptures[ObjectIdentifier(finished)] = nil }
                }
                self.pendingCaptures[ObjectIdentifier(delegate)] = delegate
                self.photoOutput.capturePhoto(with: AVCapturePhotoSettings(), delegate: delegate)
            }
        }
    }
}

private final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {

    private let completion: @Sendable (PhotoCaptureDelegate, Swift.Result<Data, any Error>) -> Void

    init(completion: @escaping @Sendable (PhotoCaptureDelegate, Swift.Result<Data, any Error>) -> Void) {
        self.completion = completion
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: (any Error)?
    ) {
        if let error {
            completion(self, .failure(error))
        } else if let data = photo.fileDataRepresentation() {
            completion(self, .success(data))
        } else {
            completion(self, .failure(MirrorError.unreadablePhoto))
        }
    }
}
