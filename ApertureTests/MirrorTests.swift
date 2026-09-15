//
//  MirrorTests.swift
//  ApertureTests
//

import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Aperture

@MainActor
final class MirrorTests: XCTestCase {

    // MARK: - When the camera runs

    func testTheCameraRunsOnlyWhileTheMirrorPaneIsShowing() {
        XCTAssertTrue(MirrorGeometry.showsMirror(.expanded(.mirror)))
        let elsewhere: [OverlayPresentation] = [
            .hidden, .minimal, .compact, .hud(.meter), .hud(.message),
            .expanded(.nowPlaying), .expanded(.schedule), .expanded(.controls),
        ]
        for presentation in elsewhere {
            XCTAssertFalse(MirrorGeometry.showsMirror(presentation), "\(presentation) must turn the camera off")
        }
    }

    func testTheCameraNeedsAccessAndAnAwakeDisplay() {
        XCTAssertTrue(MirrorGeometry.shouldRun(showsMirror: true, isAuthorized: true, isDisplayAsleep: false))
        XCTAssertFalse(MirrorGeometry.shouldRun(showsMirror: true, isAuthorized: false, isDisplayAsleep: false),
                       "Never without access")
        XCTAssertFalse(MirrorGeometry.shouldRun(showsMirror: true, isAuthorized: true, isDisplayAsleep: true),
                       "Nobody is looking at a sleeping display")
        XCTAssertFalse(MirrorGeometry.shouldRun(showsMirror: false, isAuthorized: true, isDisplayAsleep: false))
    }

    // MARK: - Idle collapse

    /// The regression this guards: the hub closes itself after ten seconds
    /// without cursor movement, which is exactly how someone uses a mirror.
    func testTheIdleTimerNeverClosesTheMirror() {
        XCTAssertFalse(OverlayManager.autoCollapses(.expanded(.mirror)))
        XCTAssertTrue(OverlayManager.autoCollapses(.expanded(.nowPlaying)))
        XCTAssertTrue(OverlayManager.autoCollapses(.expanded(.controls)))
        XCTAssertFalse(OverlayManager.autoCollapses(.minimal), "Nothing to collapse")
    }

    // MARK: - Crop

    func testASameShapedFrameIsUsedWhole() {
        let rect = MirrorGeometry.visibleRect(imageSize: CGSize(width: 1600, height: 1000), viewAspect: 1.6)
        XCTAssertEqual(rect, CGRect(x: 0, y: 0, width: 1600, height: 1000))
    }

    /// The camera's 16:9 frame is wider than the 16:10 preview, so the preview
    /// shows less than the sensor sees — and the photo must too.
    func testAWiderFrameLosesItsSidesLikeThePreviewDoes() {
        let rect = MirrorGeometry.visibleRect(imageSize: CGSize(width: 1920, height: 1080), viewAspect: 1.6)
        XCTAssertEqual(rect.height, 1080)
        XCTAssertEqual(rect.width, 1728)
        XCTAssertEqual(rect.midX, 960, accuracy: 0.5)
    }

    func testTheCropNeverLeavesTheFrame() {
        let size = CGSize(width: 1920, height: 1080)
        let frame = CGRect(origin: .zero, size: size)
        for aspect in [0.75, 1.0, 1.6, 2.4] {
            let rect = MirrorGeometry.visibleRect(imageSize: size, viewAspect: aspect)
            XCTAssertTrue(frame.contains(rect), "aspect \(aspect) escaped the frame")
            XCTAssertGreaterThan(rect.width, 0)
        }
    }

    func testDegenerateInputsProduceNoCrop() {
        XCTAssertEqual(MirrorGeometry.visibleRect(imageSize: .zero, viewAspect: 1.6), .zero)
        XCTAssertEqual(MirrorGeometry.visibleRect(imageSize: CGSize(width: 10, height: 10), viewAspect: 0), .zero)
    }

    // MARK: - Photo files

    func testPhotoNamesAreSortableAndFreeOfColons() {
        var calendar = Calendar(identifier: .gregorian)
        let utc = TimeZone(identifier: "UTC")!
        calendar.timeZone = utc
        let date = calendar.date(from: DateComponents(year: 2026, month: 9, day: 13, hour: 10, minute: 42, second: 17))!

        let name = MirrorGeometry.photoFileName(for: date, timeZone: utc)
        XCTAssertEqual(name, "Aperture 2026-09-13 at 10.42.17.jpg")
        XCTAssertFalse(name.contains(":"))
    }

    func testAFreeNameIsUsedAsIs() {
        let url = MirrorGeometry.availableURL(in: URL(fileURLWithPath: "/tmp"), named: "Aperture x.jpg") { _ in false }
        XCTAssertEqual(url.lastPathComponent, "Aperture x.jpg")
    }

    func testTwoPhotosInTheSameSecondNeverOverwriteEachOther() {
        let taken: Set<String> = ["Aperture x.jpg", "Aperture x (2).jpg"]
        let url = MirrorGeometry.availableURL(in: URL(fileURLWithPath: "/tmp"), named: "Aperture x.jpg") {
            taken.contains($0.lastPathComponent)
        }
        XCTAssertEqual(url.lastPathComponent, "Aperture x (3).jpg")
    }

    func testPhotosAreSavedToPicturesAperture() {
        let directory = MirrorGeometry.photosDirectory
        XCTAssertEqual(directory.lastPathComponent, "Aperture")
        XCTAssertEqual(directory.deletingLastPathComponent().lastPathComponent, "Pictures")
    }

    // MARK: - Rendering a saved photo

    /// A frame whose left half is red and right half blue. Saved mirrored, the
    /// halves must swap — the photo shows what the mirror showed.
    func testAMirroredPhotoIsFlipped() throws {
        let frame = try Self.jpeg(width: 160, height: 100) { context in
            context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 80, height: 100))
            context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
            context.fill(CGRect(x: 80, y: 0, width: 80, height: 100))
        }

        let mirrored = try MirrorCamera.render(frame, mirrored: true, viewAspect: 1.6)
        let left = try Self.pixel(in: mirrored, x: 30, y: 50)
        let right = try Self.pixel(in: mirrored, x: 130, y: 50)
        XCTAssertGreaterThan(left.blue, left.red, "Mirrored: blue belongs on the left")
        XCTAssertGreaterThan(right.red, right.blue, "Mirrored: red belongs on the right")

        let unmirrored = try MirrorCamera.render(frame, mirrored: false, viewAspect: 1.6)
        let plainLeft = try Self.pixel(in: unmirrored, x: 30, y: 50)
        XCTAssertGreaterThan(plainLeft.red, plainLeft.blue, "Unmirrored keeps red on the left")
    }

    /// The camera's 16:9 frame saved at the preview's 16:10 shape loses its
    /// sides, exactly as the preview does.
    func testASavedPhotoIsCroppedToThePreviewShape() throws {
        let frame = try Self.jpeg(width: 160, height: 90) { context in
            context.setFillColor(CGColor(gray: 0.5, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 160, height: 90))
        }
        let saved = try MirrorCamera.render(frame, mirrored: true, viewAspect: 1.6)
        let size = try Self.pixel(in: saved, x: 0, y: 0)
        XCTAssertEqual(size.width, 144)
        XCTAssertEqual(size.height, 90)
    }

    // MARK: - Shortcut

    func testTheMirrorShortcutDefaultsToControlOptionCommandM() {
        XCTAssertEqual(HotKeyBinding.mirrorDefault.displayString, "⌃⌥⌘M")
        XCTAssertTrue(HotKeyBinding.mirrorDefault.isValid)
        XCTAssertNotEqual(HotKeyBinding.mirrorDefault, HotKeyBinding.default,
                          "Two slots on one combination would leave one of them dead")
    }

    func testEveryShortcutSlotHasItsOwnCarbonID() {
        let ids = HotKeySlot.allCases.map(\.rawValue)
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    // MARK: - Preferences

    func testTheMirrorStartsMirroredAndUnlit() {
        let preferences = Preferences(store: InMemoryPreferenceStore())
        XCTAssertTrue(preferences.mirrorFlipped)
        XCTAssertFalse(preferences.mirrorRingLight)
        XCTAssertEqual(preferences.mirrorHotKey, .mirrorDefault)
    }

    func testMirrorChoicesAreRemembered() {
        let store = InMemoryPreferenceStore()
        let first = Preferences(store: store)
        first.mirrorFlipped = false
        first.mirrorRingLight = true

        let second = Preferences(store: store)
        XCTAssertFalse(second.mirrorFlipped)
        XCTAssertTrue(second.mirrorRingLight)
    }

    // MARK: - Helpers

    private static func jpeg(width: Int, height: Int, draw: (CGContext) -> Void) throws -> Data {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        draw(context)
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 1.0] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    /// The colour at (`x`, `y`) measured from the top-left, plus the image's size.
    private static func pixel(in data: Data, x: Int, y: Int) throws -> (red: Int, blue: Int, width: Int, height: Int) {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(
            data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let offset = (y * image.width + x) * 4
        return (Int(bytes[offset]), Int(bytes[offset + 2]), image.width, image.height)
    }
}
