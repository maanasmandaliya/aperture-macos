//
//  ShortcutRecorderView.swift
//  Aperture
//

import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Records a global shortcut.
///
/// While recording, a *local* key monitor swallows key-down events so the
/// keystroke edits the binding instead of triggering menu commands. A local
/// monitor is enough because the settings window is key during recording, and it
/// needs no Accessibility permission.
struct ShortcutRecorderView: View {

    @Binding var binding: HotKeyBinding
    var registrationFailed: Bool

    @State private var isRecording = false
    @State private var monitor: Any?
    @State private var message: String?

    var body: some View {
        HStack(spacing: 10) {
            Button {
                isRecording ? stopRecording() : startRecording()
            } label: {
                Text(isRecording ? "Press keys…" : binding.displayString)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .frame(minWidth: 110)
                    .padding(.vertical, 3)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Toggle hub shortcut")
            .accessibilityValue(isRecording ? "Recording. Press a key combination." : binding.accessibilityString)
            .accessibilityHint("Activate, then press the key combination you want")

            Button("Reset") {
                binding = .default
                message = nil
            }
            .controlSize(.small)
            .disabled(binding == .default)

            if let message {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(Tokens.Palette.warning)
            } else if registrationFailed {
                Text("Unavailable — another app may already use it.")
                    .font(.footnote)
                    .foregroundStyle(Tokens.Palette.warning)
            }
        }
        .onDisappear { stopRecording() }
    }

    private func startRecording() {
        guard monitor == nil else { return }
        isRecording = true
        message = nil

        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated {
                handle(event)
            }
            return nil // Swallow the keystroke while recording.
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
    }

    private func handle(_ event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) {
            stopRecording()
            return
        }

        let modifiers = HotKeyBinding.carbonModifiers(from: event.modifierFlags)
        guard modifiers != 0 else {
            message = "Include at least one modifier key."
            return
        }

        binding = HotKeyBinding(keyCode: UInt32(event.keyCode), modifiers: modifiers)
        message = nil
        stopRecording()
    }
}
