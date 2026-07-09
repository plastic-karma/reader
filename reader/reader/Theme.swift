//
//  Theme.swift
//  reader
//

import AppKit
import CoreText
import SwiftUI

/// The redesign's visual language: two warm papers, one ink, one rust
/// accent, and a serif reading face. Single source of truth for native
/// views; ArticleTemplate mirrors the same values in CSS.
enum Theme {

    // MARK: Palette

    /// Reading paper — the brightest surface, reserved for the page.
    static let page = Color(red: 251 / 255, green: 249 / 255, blue: 244 / 255)
    /// List paper — one step darker, so light leads to the text.
    static let list = Color(red: 239 / 255, green: 233 / 255, blue: 221 / 255)
    /// Ink: near-black warm brown; recede with `.opacity(_:)`.
    static let ink = Color(red: 36 / 255, green: 27 / 255, blue: 16 / 255)
    /// Softer ink for icon strokes.
    static let inkSoft = Color(red: 67 / 255, green: 56 / 255, blue: 42 / 255)
    /// The one accent — rust. Unread, selection, and links only.
    static let accent = Color(red: 166 / 255, green: 75 / 255, blue: 36 / 255)
    static let accentHover = Color(red: 140 / 255, green: 61 / 255, blue: 27 / 255)
    /// Hairlines that replace toolbar bars and hard panel borders.
    private static let hairlineBase = Color(red: 50 / 255, green: 35 / 255, blue: 15 / 255)
    static let hairline = hairlineBase.opacity(0.10)
    static let hairlineSoft = hairlineBase.opacity(0.08)

    // MARK: Reading face

    /// Registers the bundled Literata variable fonts for this process.
    /// Called once from `readerApp.init` — no Info.plist keys needed.
    static func registerFonts() {
        for name in ["Literata", "Literata-Italic"] {
            let url = Bundle.main.url(forResource: name, withExtension: "ttf")
                ?? Bundle.main.url(forResource: name, withExtension: "ttf", subdirectory: "Fonts")
            guard let url else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    /// True once the bundled face registered; checked lazily on first use,
    /// which is always after `registerFonts()` has run in `readerApp.init`.
    private static let literataAvailable: Bool =
        NSFontManager.shared.availableFontFamilies.contains("Literata")

    /// The serif reading face at a fixed size, falling back to the system
    /// serif (New York) when Literata failed to register.
    static func serif(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        literataAvailable
            ? Font.custom("Literata", fixedSize: size).weight(weight)
            : Font.system(size: size, weight: weight, design: .serif)
    }
}

// MARK: - Quiet icon button

/// A 28×26 icon button that sits at low opacity and wakes on hover —
/// the redesign's replacement for toolbar items. Disabled state fades
/// further and ignores hover.
struct QuietIconButton<Icon: View>: View {
    var idleOpacity: Double = 0.4
    var width: CGFloat = 28
    var height: CGFloat = 26
    let help: String
    let action: () -> Void
    @ViewBuilder let icon: Icon

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            icon
                .foregroundStyle(Theme.inkSoft)
                .frame(width: width, height: height)
                .background(
                    isHovering && isEnabled ? Theme.ink.opacity(0.06) : .clear,
                    in: RoundedRectangle(cornerRadius: 6)
                )
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? (isHovering ? 1 : idleOpacity) : 0.15)
        .onHover { isHovering = $0 }
        .help(help)
    }
}

// MARK: - Accent buttons

/// Rust capsule — the one loud control, used for a view's single primary
/// action (empty-state onboarding, "publish now").
struct AccentPillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(
                configuration.isPressed ? Theme.accentHover : Theme.accent,
                in: Capsule()
            )
    }
}

/// Plain rust text — secondary actions next to an accent pill.
struct AccentTextButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(configuration.isPressed ? Theme.accentHover : Theme.accent)
            .padding(.vertical, 6)
    }
}

// MARK: - Ink tab

/// Plain-text filter/lens control: the active tab carries the accent and a
/// 1.5pt underline; inactive tabs recede into the ink.
struct InkTab: View {
    let label: String
    var size: CGFloat = 12
    var inactiveOpacity: Double = 0.5
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: size, weight: isActive ? .semibold : .regular))
                .foregroundStyle(isActive ? Theme.accent : Theme.ink.opacity(inactiveOpacity))
                .padding(.bottom, 2)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(Theme.accent)
                        .frame(height: 1.5)
                        .opacity(isActive ? 1 : 0)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Compact time

extension Date {
    /// List-row age: "now", "12m", "2h", "3d", "2w" — the quietest form
    /// that still answers "how fresh is this?".
    func compactAge(relativeTo now: Date = .now) -> String {
        let seconds = max(0, now.timeIntervalSince(self))
        let minutes = Int(seconds / 60)
        if minutes < 1 { return "now" }
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h" }
        let days = hours / 24
        if days < 7 { return "\(days)d" }
        let weeks = days / 7
        if weeks < 5 { return "\(weeks)w" }
        let months = days / 30
        if months < 12 { return "\(months)mo" }
        return "\(months / 12)y"
    }
}
