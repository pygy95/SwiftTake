// MARK: - ShortcutsList
//
// The shortcuts cheatsheet, rendered by the Settings ▸ Shortcuts pane.
// Help ▸ Keyboard Shortcuts (⌘/) deep-links to that pane via
// `SettingsDeepLink` rather than opening a window of its own.

import SwiftUI

/// Every shortcut SwiftTake understands, grouped by area. Pure content —
/// the host provides scrolling, background, and window chrome.
struct ShortcutsList: View {

    @Environment(\.isClassicTheme) private var isClassicTheme

    // MARK: Data model

    private struct Shortcut: Identifiable {
        let id = UUID()
        /// Whitespace-separated tokens. Each token becomes one keycap —
        /// e.g. `"⇧ ⌘ I"` renders as three caps in a row.
        let keys: String
        let action: String
    }

    private struct Section: Identifiable {
        let id = UUID()
        let title: String
        let shortcuts: [Shortcut]
    }

    // Kept in sync with the real command definitions — AppCommands.swift for
    // the menu bar, and the gallery's own key handling in ContentView.swift —
    // rather than aspirational copy. Every row below was checked against one
    // of those two sources.
    private let sections: [Section] = [
        Section(title: "Camera", shortcuts: [
            Shortcut(keys: "⌘ K",   action: "Connect to camera"),
            Shortcut(keys: "⇧ ⌘ K", action: "Disconnect camera"),
            Shortcut(keys: "⇧ ⌘ I", action: "Import photos (selection, or all)"),
            Shortcut(keys: "⌘ R",   action: "Refresh camera info"),
            Shortcut(keys: "⌃ ⌘ R", action: "Reload gallery (full rebuild)"),
            Shortcut(keys: "⇧ ⌘ C", action: "Open Camera Controls window"),
            Shortcut(keys: "⌘ ⌫",   action: "Erase all photos on camera"),
        ]),
        Section(title: "Gallery", shortcuts: [
            Shortcut(keys: "␣",            action: "QuickLook the focused photo"),
            Shortcut(keys: "Double‑click",  action: "Open in QuickLook (imports first if needed)"),
            Shortcut(keys: "↑ ↓ ← →",      action: "Move focus between thumbnails"),
            Shortcut(keys: "⇧ + arrow",    action: "Extend selection to the new focus"),
            Shortcut(keys: "⌘ A",          action: "Select all photos"),
            Shortcut(keys: "⇧ ⌘ A",        action: "Deselect all"),
            Shortcut(keys: "Esc",          action: "Clear selection"),
            Shortcut(keys: "⌘ +",          action: "Zoom in"),
            Shortcut(keys: "⌘ -",          action: "Zoom out"),
            Shortcut(keys: "⌘ 0",          action: "Reset zoom"),
            Shortcut(keys: "Drag",         action: "Drag a photo out to Finder, Mail, or Photos"),
        ]),
        Section(title: "Windows", shortcuts: [
            Shortcut(keys: "⌘ ,", action: "Settings"),
            Shortcut(keys: "⌘ /", action: "Keyboard Shortcuts (this pane)"),
            Shortcut(keys: "⌘ W", action: "Close window"),
        ]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            ForEach(Array(sections.enumerated()), id: \.element.id) { idx, section in
                sectionView(section)
                if idx < sections.count - 1 {
                    Divider()
                        .opacity(0.4)
                }
            }
        }
    }

    // MARK: Section

    @ViewBuilder
    private func sectionView(_ section: Section) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(section.title.uppercased())
                .font(isClassicTheme ? .classic(11, weight: .semibold) : .caption.weight(.semibold))
                .tracking(1.0)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 10) {
                ForEach(section.shortcuts) { shortcut in
                    HStack(alignment: .firstTextBaseline, spacing: 16) {
                        keycapRow(for: shortcut.keys)
                            .frame(width: 132, alignment: .leading)
                        Text(shortcut.action)
                            .font(isClassicTheme ? .classic(12) : .callout)
                            .foregroundStyle(.primary)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    // MARK: Keycap row — splits the keys string and lays out caps in line

    @ViewBuilder
    private func keycapRow(for keys: String) -> some View {
        let tokens = keys.split(separator: " ").map(String.init)
        HStack(spacing: 4) {
            ForEach(Array(tokens.enumerated()), id: \.offset) { _, token in
                Keycap(token: token)
            }
        }
    }

    // MARK: Single keycap

    private struct Keycap: View {
        @Environment(\.isClassicTheme) private var isClassicTheme
        let token: String

        /// Width is auto-sized for letters / symbols, but generous
        /// enough for word tokens like "Drag" or "Right-click" to read
        /// cleanly without forcing every cap to share the same width.
        private var minWidth: CGFloat {
            // Very rough heuristic: short tokens get a square-ish cap,
            // longer tokens grow with their content.
            token.count <= 1 ? 28 : 0
        }

        var body: some View {
            if isClassicTheme {
                Text(token)
                    .font(.classic(12.5, weight: .semibold))
                    .foregroundStyle(AppTheme.platinumText)
                    .padding(.horizontal, 8)
                    .frame(minWidth: minWidth, minHeight: 26)
                    .classicBevel(cornerRadius: 6)
            } else {
                Text(token)
                    .font(.system(size: 12.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 8)
                    .frame(minWidth: minWidth, minHeight: 26)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.secondary.opacity(0.14))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(Color.secondary.opacity(0.28), lineWidth: 0.5)
                    )
            }
        }
    }
}
