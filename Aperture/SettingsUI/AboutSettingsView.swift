//
//  AboutSettingsView.swift
//  Aperture
//

import SwiftUI

struct AboutSettingsView: View {

    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        Form {
            Section {
                HStack(spacing: 16) {
                    ApertureMark(accent: environment.preferences.accent)
                        .frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(ApertureInfo.name)
                            .font(.system(size: 20, weight: .semibold, design: .rounded))
                        Text(ApertureInfo.tagline)
                            .foregroundStyle(.secondary)
                        Text(ApertureInfo.versionDescription)
                            .font(.footnote)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .combine)
            }

            Section("Privacy") {
                Text(ApertureInfo.privacyStatement)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Reset") {
                Button("Restore Default Settings") {
                    environment.preferences.resetToDefaults()
                }
                Text("Leaves your calendar selection and login item alone.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// Aperture's mark: concentric arcs opening around a centre — the same motif the
/// generated artwork uses. Drawn in code so the app ships no image assets.
struct ApertureMark: View {
    var accent: AccentChoice

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            ZStack {
                RoundedRectangle(cornerRadius: side * 0.24, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Tokens.Palette.slate, Tokens.Palette.graphite],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                RoundedRectangle(cornerRadius: side * 0.24, style: .continuous)
                    .strokeBorder(Tokens.Palette.hairline, lineWidth: side * 0.015)

                ForEach(0..<3, id: \.self) { index in
                    let progress = Double(index) / 3
                    Circle()
                        .trim(from: 0.08 + progress * 0.05, to: 0.42 - progress * 0.04)
                        .stroke(
                            accent.gradient,
                            style: StrokeStyle(lineWidth: side * (0.065 - progress * 0.012), lineCap: .round)
                        )
                        .frame(width: side * (0.30 + progress * 0.22), height: side * (0.30 + progress * 0.22))
                        .rotationEffect(.degrees(-100 + progress * 26))
                        .opacity(1 - progress * 0.35)
                }

                Capsule(style: .continuous)
                    .fill(Color.black.opacity(0.85))
                    .frame(width: side * 0.34, height: side * 0.10)
                    .offset(y: -side * 0.30)
                    .overlay {
                        Capsule(style: .continuous)
                            .strokeBorder(Tokens.Palette.hairline.opacity(0.8), lineWidth: side * 0.008)
                            .frame(width: side * 0.34, height: side * 0.10)
                            .offset(y: -side * 0.30)
                    }
            }
            .frame(width: side, height: side)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

#Preview("About") {
    AboutSettingsView()
        .environment(AppEnvironment.preview())
        .frame(width: 600, height: 470)
}
