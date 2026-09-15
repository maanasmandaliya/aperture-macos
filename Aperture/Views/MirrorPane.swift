//
//  MirrorPane.swift
//  Aperture
//
//  The front camera as a mirror: a live preview with a ring light and a
//  shutter. Whether the preview is mirrored is a setting.
//

import AppKit
import AVFoundation
import SwiftUI

struct MirrorPane: View {

    @Environment(AppEnvironment.self) private var environment

    var accent: AccentChoice

    /// Width over height of the preview. Near the camera's own 16:9 while
    /// leaving room for the controls beneath; a saved photo is cropped to this
    /// same shape so it matches what was on screen.
    static let previewAspect: CGFloat = 16.0 / 10.0

    @State private var isFlashing = false
    @State private var showsSavedBadge = false
    @State private var badgeTask: Task<Void, Never>?

    private var camera: MirrorCamera { environment.mirror }
    private var preferences: Preferences { environment.preferences }
    private var reduceMotion: Bool { preferences.reduceMotion }

    var body: some View {
        Group {
            switch camera.access {
            case .notRequested:
                MirrorMessage(symbol: "camera", title: "Use your camera as a mirror", detail: camera.access.statusText) {
                    ApertureTextButton(title: "Allow Camera", accent: accent, emphasis: .prominent) {
                        Task { await camera.requestAccess() }
                    }
                }
            case .denied, .restricted:
                MirrorMessage(symbol: "video.slash", title: "Camera access needed", detail: camera.access.statusText) {
                    ApertureTextButton(title: "Open Privacy Settings", accent: accent) {
                        MirrorCamera.openPrivacySettings()
                    }
                }
            case .authorized:
                switch camera.status {
                case .noCamera:
                    MirrorMessage(
                        symbol: "video.slash",
                        title: "No camera available",
                        detail: "There's no camera Aperture can use right now — the lid may be closed. A connected USB camera works too."
                    ) {
                        ApertureTextButton(title: "Try Again", accent: accent) { camera.retry() }
                    }
                case .failed(let reason):
                    MirrorMessage(symbol: "exclamationmark.triangle", title: "Camera unavailable", detail: reason) {
                        ApertureTextButton(title: "Try Again", accent: accent) { camera.retry() }
                    }
                case .idle, .starting, .running:
                    mirror
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Mirror")
    }

    // MARK: - Mirror

    private var mirror: some View {
        VStack(spacing: Tokens.Space.sm) {
            preview
            controls
        }
    }

    private var ringInset: CGFloat { preferences.mirrorRingLight ? Tokens.Space.sm : 0 }

    private var preview: some View {
        ZStack(alignment: .bottom) {
            MirrorPreview(
                previewLayer: camera.pipeline.previewLayer,
                isMirrored: preferences.mirrorFlipped
            )
            .accessibilityElement()
            .accessibilityLabel("Camera mirror")
            .accessibilityValue(previewDescription)

            if camera.status != .running {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel("Starting camera")
            }

            if showsSavedBadge, camera.lastPhoto != nil {
                savedBadge
                    .padding(Tokens.Space.sm)
                    .transition(.opacity)
            }

            // The shutter flash. Bright enough to double as a fill light for
            // the photo, the way a screen flash does.
            Color.white
                .opacity(isFlashing ? 0.85 : 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .aspectRatio(Self.previewAspect, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous))
        .padding(ringInset)
        .background { ringLight }
        .frame(maxWidth: .infinity)
        .animation(Tokens.Motion.controlState(reduceMotion: reduceMotion), value: preferences.mirrorRingLight)
        .accessibilityElement(children: .contain)
    }

    /// The screen as the light source: a bright white surround that lights a
    /// face in a dark room, the way a ring light does.
    @ViewBuilder
    private var ringLight: some View {
        if preferences.mirrorRingLight {
            RoundedRectangle(cornerRadius: Tokens.Radius.card + ringInset, style: .continuous)
                .fill(Color.white)
                .shadow(color: .white.opacity(0.6), radius: 12)
                .accessibilityHidden(true)
        }
    }

    private var controls: some View {
        HStack(spacing: Tokens.Space.sm) {
            ApertureIconButton(
                systemName: preferences.mirrorRingLight ? "sun.max.fill" : "sun.max",
                accessibilityLabel: "Ring light",
                accent: accent,
                isActive: preferences.mirrorRingLight
            ) {
                preferences.mirrorRingLight.toggle()
            }
            .help("Ring light")

            Spacer(minLength: 0)

            ApertureIconButton(
                systemName: "camera.fill",
                accessibilityLabel: "Take photo",
                accent: accent,
                size: 34,
                isProminent: true,
                isEnabled: camera.status == .running && !camera.isCapturing
            ) {
                takePhoto()
            }
            .help("Take a photo — saved to Pictures ▸ Aperture")
        }
        .frame(height: 34)
    }

    private var savedBadge: some View {
        Button {
            camera.revealLastPhoto()
        } label: {
            Label("Saved · Show in Finder", systemImage: "checkmark.circle.fill")
                .font(Tokens.Text.caption)
                .foregroundStyle(Tokens.Palette.textPrimary)
                .padding(.horizontal, Tokens.Space.sm)
                .padding(.vertical, Tokens.Space.xs)
                .background(Color.black.opacity(0.62), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Shows the photo in Finder")
    }

    private var previewDescription: String {
        var parts = [camera.status == .running ? "Live" : "Starting"]
        parts.append(preferences.mirrorFlipped ? "mirrored" : "not mirrored")
        if preferences.mirrorRingLight { parts.append("ring light on") }
        return parts.joined(separator: ", ")
    }

    // MARK: - Shutter

    private func takePhoto() {
        Task {
            if !reduceMotion {
                withAnimation(.easeOut(duration: 0.06)) { isFlashing = true }
            }
            await camera.capturePhoto(
                mirrored: preferences.mirrorFlipped,
                viewAspect: Self.previewAspect
            )
            withAnimation(.easeOut(duration: 0.35)) { isFlashing = false }

            if let error = camera.photoError {
                AccessibilityNotification.Announcement(error).post()
                return
            }
            AccessibilityNotification.Announcement("Photo saved to Pictures, Aperture").post()
            showSavedBadge()
        }
    }

    private func showSavedBadge() {
        badgeTask?.cancel()
        withAnimation(Tokens.Motion.contentIn(reduceMotion: reduceMotion)) { showsSavedBadge = true }
        badgeTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            withAnimation(Tokens.Motion.contentOut(reduceMotion: reduceMotion)) { showsSavedBadge = false }
        }
    }
}

// MARK: - Message

private struct MirrorMessage<Action: View>: View {
    var symbol: String
    var title: String
    var detail: String
    @ViewBuilder var action: Action

    var body: some View {
        VStack(spacing: Tokens.Space.sm) {
            VStack(spacing: Tokens.Space.xs) {
                Image(systemName: symbol)
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(Tokens.Palette.textTertiary)
                    .accessibilityHidden(true)
                Text(title)
                    .font(Tokens.Text.body)
                    .foregroundStyle(Tokens.Palette.textSecondary)
                Text(detail)
                    .font(Tokens.Text.caption)
                    .foregroundStyle(Tokens.Palette.textTertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            action
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, Tokens.Space.md)
    }
}

// MARK: - Preview layer

/// Hosts the pipeline's preview layer. It never creates one or touches the
/// session — see `MirrorPipeline.previewLayer` for why.
private struct MirrorPreview: NSViewRepresentable {
    let previewLayer: AVCaptureVideoPreviewLayer
    var isMirrored: Bool

    func makeNSView(context: Context) -> MirrorPreviewView {
        MirrorPreviewView(previewLayer: previewLayer)
    }

    func updateNSView(_ view: MirrorPreviewView, context: Context) {
        view.apply(isMirrored: isMirrored)
    }
}

private final class MirrorPreviewView: NSView {

    private let previewLayer: AVCaptureVideoPreviewLayer
    private var isMirrored = true
    private var appliedSize = CGSize.zero
    private var appliedTransform = CGAffineTransform.identity

    init(previewLayer: AVCaptureVideoPreviewLayer) {
        self.previewLayer = previewLayer
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.black.cgColor
        // A layer has one superlayer, so adding it here moves it out of any
        // earlier view the pane built — it is shared, not copied.
        layer?.addSublayer(previewLayer)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        applyGeometry()
    }

    func apply(isMirrored: Bool) {
        self.isMirrored = isMirrored
        applyGeometry()
    }

    /// Mirroring is this transform, applied here and nowhere else, and the saved
    /// photo repeats exactly this flip. This runs on every
    /// layout — every frame of the hub's opening spring — so it does only what
    /// has changed, and it is pure layer geometry: nothing here reaches the
    /// capture session.
    private func applyGeometry() {
        let transform = CGAffineTransform(scaleX: isMirrored ? -1 : 1, y: 1)
        let size = bounds.size
        let isNewHost = previewLayer.superlayer !== layer
        guard isNewHost || size != appliedSize || transform != appliedTransform else { return }
        if isNewHost { layer?.addSublayer(previewLayer) }
        appliedSize = size
        appliedTransform = transform

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // `bounds` and `position` rather than `frame`: a layer's frame is
        // undefined once it carries a non-identity transform.
        previewLayer.bounds = CGRect(origin: .zero, size: size)
        previewLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        previewLayer.setAffineTransform(transform)
        CATransaction.commit()
    }
}
