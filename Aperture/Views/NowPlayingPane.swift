//
//  NowPlayingPane.swift
//  Aperture
//

import CoreAudio
import SwiftUI

/// The hub's playback surface.
///
/// Laid out the way a now-playing panel conventionally is: artwork and titles
/// on one line with a level meter opposite, a scrubber flanked by elapsed and
/// remaining time, and a transport row underneath. Controls the current source
/// cannot drive are disabled rather than hidden, so the row does not reflow when
/// you switch between the demo player and Music.
struct NowPlayingPane: View {

    @Environment(AppEnvironment.self) private var environment

    var accent: AccentChoice
    var scale: CGFloat

    /// Local seek position while the user drags, so the playhead does not fight
    /// the source's own updates mid-gesture.
    @State private var scrubPosition: Double?

    private var media: MediaSnapshot { environment.media.snapshot }
    private var capabilities: MediaCapabilities { environment.media.capabilities }
    private var reduceMotion: Bool { environment.preferences.reduceMotion }

    /// Identity of the loaded track. Changing it drives both the header
    /// cross-fade and the cover flip.
    private var trackKey: String { media.identity }

    var body: some View {
        VStack(spacing: Tokens.Space.md) {
            if media.hasTrack {
                // Stacked rather than swapped in place: the outgoing and
                // incoming headers have to overlap to cross-fade, and a `VStack`
                // would lay them out one after the other and shunt the scrubber
                // down for the duration.
                ZStack(alignment: .topLeading) {
                    header
                        .id(trackKey)
                        .transition(.opacity)
                }
                // Scoped to the header. Applied any higher and the playhead
                // would ride it too, sliding back to zero like a rewind instead
                // of cutting to the new track's position.
                .animation(Tokens.Motion.trackChange(reduceMotion: reduceMotion), value: trackKey)
                scrubber
                transport
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Now Playing")
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: Tokens.Space.md) {
            ArtworkView(
                image: environment.media.artwork,
                side: Tokens.Size.artworkExpanded * scale,
                accent: accent,
                isPlaying: media.isPlaying,
                reactsToPlayback: true,
                reduceMotion: reduceMotion,
                animationIntensity: environment.preferences.resolvedAnimationIntensity,
                flipKey: trackKey
            )

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Tokens.Space.xs) {
                    Text(media.title)
                        .font(Tokens.Text.titleLarge)
                        .foregroundStyle(Tokens.Palette.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if media.isExplicit { ExplicitBadge() }
                }
                Text(media.artist)
                    .font(Tokens.Text.body)
                    .foregroundStyle(Tokens.Palette.textSecondary)
                    .lineLimit(1)
                if !media.album.isEmpty {
                    Text(media.album)
                        .font(Tokens.Text.caption)
                        .foregroundStyle(Tokens.Palette.textTertiary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            PlaybackPulse(accent: accent, isPlaying: media.isPlaying, reduceMotion: reduceMotion)
                .frame(width: 22, alignment: .trailing)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(media.title)\(media.isExplicit ? ", explicit" : "") by \(media.artist)"
        )
    }

    // MARK: - Scrubber

    private var scrubber: some View {
        HStack(spacing: Tokens.Space.sm) {
            Text(DurationFormatter.clock(displayedElapsed))
                .frame(minWidth: 34, alignment: .leading)

            ApertureSlider(
                value: Binding(
                    get: { scrubPosition ?? media.elapsed(at: environment.now) },
                    set: { scrubPosition = $0 }
                ),
                range: 0...max(media.duration ?? 1, 1),
                accent: accent,
                isEnabled: capabilities.contains(.seek) && media.duration != nil,
                trackHeight: 4,
                style: .timeline,
                increaseContrast: environment.preferences.increaseContrast,
                label: "Playback position",
                valueDescription: { DurationFormatter.spokenClock($0) },
                onCommit: { position in
                    environment.media.seek(to: position)
                    scrubPosition = nil
                }
            )

            // Counts down rather than showing the total, which is the more
            // useful of the two once a track is already playing.
            Text(remainingLabel)
                .frame(minWidth: 38, alignment: .trailing)
        }
        .font(Tokens.Text.micro)
        .foregroundStyle(Tokens.Palette.textTertiary)
        .monospacedDigit()
    }

    private var displayedElapsed: TimeInterval {
        scrubPosition ?? media.elapsed(at: environment.now)
    }

    private var remainingLabel: String {
        guard let duration = media.duration else { return "--:--" }
        return "-" + DurationFormatter.clock(max(duration - displayedElapsed, 0))
    }

    // MARK: - Transport

    private var transport: some View {
        HStack(spacing: Tokens.Space.md) {
            ApertureIconButton(
                systemName: "shuffle",
                accessibilityLabel: media.isShuffled ? "Shuffle on" : "Shuffle off",
                accent: accent,
                size: Tokens.Size.transportAuxiliary * scale,
                isActive: media.isShuffled,
                isEnabled: capabilities.contains(.shuffle),
                action: { environment.media.toggleShuffle() }
            )

            Spacer(minLength: 0)

            ApertureIconButton(
                systemName: "backward.fill",
                accessibilityLabel: "Previous track",
                accent: accent,
                size: Tokens.Size.transportSecondary * scale,
                isEnabled: capabilities.contains(.skip),
                action: { environment.media.previous() }
            )
            ApertureIconButton(
                systemName: media.isPlaying ? "pause.fill" : "play.fill",
                accessibilityLabel: media.isPlaying ? "Pause" : "Play",
                accent: accent,
                size: Tokens.Size.transportPrimary * scale,
                isProminent: true,
                isEnabled: capabilities.contains(.transport),
                action: { environment.media.togglePlayPause() }
            )
            ApertureIconButton(
                systemName: "forward.fill",
                accessibilityLabel: "Next track",
                accent: accent,
                size: Tokens.Size.transportSecondary * scale,
                isEnabled: capabilities.contains(.skip),
                action: { environment.media.next() }
            )

            Spacer(minLength: 0)

            OutputDeviceButton(accent: accent, size: Tokens.Size.transportAuxiliary * scale)
        }
    }

    // MARK: - Empty

    private var emptyState: some View {
        VStack(spacing: Tokens.Space.sm) {
            Image(systemName: "music.note.list")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(Tokens.Palette.textTertiary)
            Text(emptyTitle)
                .font(Tokens.Text.body)
                .foregroundStyle(Tokens.Palette.textSecondary)
            Text(emptyDetail)
                .font(Tokens.Text.caption)
                .foregroundStyle(Tokens.Palette.textTertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, Tokens.Space.lg)
    }

    private var emptyTitle: String {
        switch environment.media.availability {
        case .needsAuthorization: "Permission needed"
        case .unavailable: "Unavailable"
        default: "Nothing playing"
        }
    }

    private var emptyDetail: String {
        switch environment.media.availability {
        case .ready: "Start something in \(environment.media.sourceName)."
        case .idle(let reason): reason
        case .needsAuthorization(let reason): reason
        case .unavailable(let reason): reason
        }
    }
}

/// The small "E" mark shown when a source reports a track as explicit.
struct ExplicitBadge: View {
    var body: some View {
        Text("E")
            .font(.system(size: 8, weight: .bold, design: .rounded))
            .foregroundStyle(Tokens.Palette.graphite)
            .frame(width: 12, height: 12)
            .background {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Tokens.Palette.textTertiary)
            }
            .accessibilityLabel("Explicit")
    }
}

/// Switches the system's default audio output.
///
/// This is a device picker, not an AirPlay picker — macOS exposes no public API
/// for that popover. It lists what CoreAudio can see and sets the default
/// output, which is the same thing Sound settings does.
///
/// The list is an `NSMenu` popped up by hand rather than a SwiftUI `Menu`.
/// SwiftUI's menu wants a key window to attach to, and the overlay is a
/// non-activating panel that is deliberately not key while collapsed; popping
/// the menu directly works regardless of activation state.
struct OutputDeviceButton: View {

    @Environment(AppEnvironment.self) private var environment

    var accent: AccentChoice
    var size: CGFloat

    // Plain state, not observable: the presenter holds no state the view reads.
    @State private var presenter = OutputMenuPresenter()

    var body: some View {
        ApertureIconButton(
            systemName: environment.audio.currentDeviceSymbol,
            accessibilityLabel: "Output device",
            accent: accent,
            size: size,
            isEnabled: !environment.audio.capability.isUnavailable,
            action: {
                environment.audio.reloadDevices()
                presenter.present(
                    devices: environment.audio.availableDevices,
                    current: environment.audio.currentDeviceID
                ) { device in
                    environment.audio.selectDevice(device)
                }
            }
        )
        .help(environment.audio.deviceName)
        .accessibilityValue(environment.audio.deviceName)
    }
}

/// Owns the AppKit menu for ``OutputDeviceButton``.
@MainActor
final class OutputMenuPresenter {

    private var handler: ((AudioOutputController.Device) -> Void)?
    private var devices: [AudioOutputController.Device] = []
    private let target = MenuTarget()

    func present(
        devices: [AudioOutputController.Device],
        current: AudioObjectID,
        onSelect: @escaping (AudioOutputController.Device) -> Void
    ) {
        self.devices = devices
        handler = onSelect
        target.onPick = { [weak self] index in
            guard let self, devices.indices.contains(index) else { return }
            self.handler?(devices[index])
        }

        let menu = NSMenu()
        menu.autoenablesItems = false

        if devices.isEmpty {
            let empty = NSMenuItem(title: "No output devices", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for (index, device) in devices.enumerated() {
                let item = NSMenuItem(title: device.name, action: #selector(MenuTarget.pick(_:)), keyEquivalent: "")
                item.target = target
                item.tag = index
                item.image = NSImage(systemSymbolName: device.symbolName, accessibilityDescription: nil)
                item.state = device.id == current ? .on : .off
                menu.addItem(item)
            }
        }

        // Screen coordinates when no anchor view is supplied.
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    @MainActor
    final class MenuTarget: NSObject {
        var onPick: ((Int) -> Void)?
        @objc func pick(_ sender: NSMenuItem) { onPick?(sender.tag) }
    }
}

#Preview("Now Playing — playing") {
    NowPlayingPane(accent: .mono, scale: 1)
        .environment(AppEnvironment.preview(activity: .media(PreviewData.playingMedia)))
        .padding(Tokens.Space.lg)
        .frame(width: 420, height: 230)
        .background(Color.black)
        .environment(\.colorScheme, .dark)
}

#Preview("Now Playing — explicit + shuffled") {
    NowPlayingPane(accent: .rose, scale: 1)
        .environment(AppEnvironment.preview(activity: .media(PreviewData.explicitMedia)))
        .padding(Tokens.Space.lg)
        .frame(width: 420, height: 230)
        .background(Color.black)
        .environment(\.colorScheme, .dark)
}

#Preview("Now Playing — empty") {
    NowPlayingPane(accent: .azure, scale: 1)
        .environment(AppEnvironment.preview())
        .padding(Tokens.Space.lg)
        .frame(width: 420, height: 230)
        .background(Color.black)
        .environment(\.colorScheme, .dark)
}
