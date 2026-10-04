// MARK: - PanoramaComposerSheet
//
// The composer, presented over the main window rather than in a window of
// its own.
//
// Why a sheet. A panorama is made OUT of the photos that are selected in
// the gallery behind it, and a separate window severs that connection the
// moment it opens — it lands wherever the window server last put it, it
// has to be managed, and nothing on screen says which photos it came
// from. A sheet is attached to the thing it came from, gives the wide
// canvas the image needs, and has one obvious way out. The standalone
// window stays as a fallback entry point (see `PanoramaWindowView`).
//
// The sheet is deliberately BIG. The whole judgement being made here is
// "is this panorama right", and that cannot be made in a column.

import SwiftUI

// MARK: - Phase

/// What a running stitch is doing.
///
/// Reported per STAGE rather than as one bar across the whole job,
/// because the stages differ by orders of magnitude: a frame decodes in
/// tens of milliseconds, a single pair match takes seconds. One bar would
/// sprint through the first tenth and then sit still for a minute, which
/// is exactly the shape of a hung app. Naming the stage costs a line and
/// reads faster than a percentage.
enum PanoramaPhase: Equatable {
    /// Frames read from disk (or the camera) and decoded at the current Look.
    case decoding(done: Int, total: Int)
    /// Overlaps measured. `total` counts pair MATCHES, not frames — the
    /// frame order is decided by measurement, so both orderings are
    /// fitted in full and one more match tests for a full rotation.
    case aligning(done: Int, total: Int)
    /// Projection and feature recovery have a data-dependent number of attempts.
    case refining
    /// Gain, seam-find and pyramid blend. A single pass with no honest
    /// sub-count, so it shows as indeterminate rather than inventing one.
    case blending

    var title: String {
        switch self {
        // "Decoding" was the machine's word for it. Most of that phase is
        // READING — off the camera at wire speed, or off disk for a Finder
        // selection — and the decode is the fast part at the end. "Reading"
        // is also true of both sources, which "Importing" would not be: the
        // Finder path imports nothing.
        case .decoding:  return "Reading photos"
        case .aligning:  return "Measuring the overlaps"
        case .refining:  return "Refining the alignment"
        case .blending:  return "Blending the seams"
        }
    }

    var detail: String {
        switch self {
        case .decoding(let done, let total):
            return "Photo \(min(done + 1, total)) of \(total)"
        case .aligning(let done, let total):
            // The count is the one number that explains why this stage is
            // the slow one, and why a bigger set is slower than it looks.
            return "\(done) of \(total) overlaps measured"
        case .refining:
            return "Checking details across the photos"
        case .blending:
            return "Almost there"
        }
    }

    /// Nil where there is nothing honest to count.
    var fraction: Double? {
        switch self {
        case .decoding(let done, let total),
             .aligning(let done, let total):
            return total > 0 ? Double(done) / Double(total) : 0
        case .refining, .blending:
            return nil
        }
    }
}

// MARK: - Sheet

struct PanoramaComposerSheet: View {
    @EnvironmentObject private var serialManager: QuickTakeSerialManager
    @Environment(\.isClassicTheme) private var isClassicTheme

    var body: some View {
        PanoramaComposerBody(onClose: { serialManager.dismissPanoramaComposer() })
            // Sheets have no native title-bar inset. The Classic chrome is
            // mounted over the sheet's frame, so reserve its band explicitly
            // inside the fixed size instead of letting it cover the header.
            .padding(.top, isClassicTheme ? ClassicTitleBar.height : 0)
            // Reserve room for the adjustment tools; the preview fills the
            // remainder without introducing a vertically scrolling editor.
            .frame(width: preferredSize.width, height: preferredSize.height)
            // Painted OUT HERE, after the frame, and again inside.
            //
            // The composer paints its own background, but that fill sits
            // INSIDE this frame — so whenever the sheet ends up taller than
            // the content (the 380 floor, or a short strip), the difference
            // was unpainted and the sheet's own near-white showed through as
            // a band along the bottom. Filling behind the frame covers
            // whatever the sheet actually measures, in either theme.
            //
            // The SAME token as the states inside paint with. It used to be
            // `NSColor.windowBackgroundColor` here and SwiftUI's semantic
            // `.background` within, which are two different greys in dark
            // mode — so the very band this fill exists to hide became
            // visible again, just in a different colour. One sheet, one
            // ground.
            .background(isClassicTheme
                        ? AnyShapeStyle(AppTheme.platinumFace)
                        : AnyShapeStyle(.background))
    }

    private var preferredSize: CGSize {
        // GeometryReader has no useful intrinsic size. Give the sheet an
        // actual window-fitting size instead of letting it choose its minimum.
        let host = NSApp.keyWindow?.sheetParent ?? NSApp.keyWindow
        let screen = host?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
        let widthLimit = max(760, (screen?.width ?? 1440) - 80)
        let heightLimit = max(480, (screen?.height ?? 900) - 100)
        return CGSize(width: min(widthLimit, min(1100, max(760, (host?.contentLayoutRect.width ?? 1164) - 64))),
                      height: min(heightLimit, min(680, max(480, (host?.contentLayoutRect.height ?? 720) - 40))))
    }

}

// MARK: - States

/// The composer's three states, shared by the sheet and the standalone
/// window so the two surfaces cannot drift apart.
struct PanoramaComposerBody: View {
    @EnvironmentObject private var serialManager: QuickTakeSerialManager
    @Environment(\.isClassicTheme) private var isClassicTheme
    /// Supplied by the sheet only. A window has a close box already.
    var onClose: (() -> Void)? = nil

    var body: some View {
        Group {
            if let reason = serialManager.panoramaFailure {
                PanoramaFailurePane(reason: reason,
                                    isClassicTheme: isClassicTheme,
                                    stops: $serialManager.panoramaQuickPanStops,
                                    onDismiss: { serialManager.dismissPanoramaComposer() },
                                    onQuickPan: serialManager.canRetryQuickPan
                                        ? { stops in serialManager.retryPanoramaWithQuickPan(stops: stops) } : nil)
            } else if let composition = serialManager.panorama {
                PanoramaComposer(composition: composition,
                                 isClassicTheme: isClassicTheme,
                                 onClose: onClose,
                                 onSave: {
                                     guard await serialManager.savePanorama() != nil,
                                           serialManager.panorama === composition else { return }
                                     serialManager.dismissPanoramaComposer(keepingMessage: true)
                                 })
            } else if let phase = serialManager.panoramaPhase {
                PanoramaProgressPane(phase: phase,
                                     isClassicTheme: isClassicTheme,
                                     onCancel: { serialManager.dismissPanoramaComposer() })
            } else {
                PanoramaEmptyState()
                    .background(isClassicTheme
                                ? AnyShapeStyle(AppTheme.platinumFace)
                                : AnyShapeStyle(.background))
            }
        }
    }
}

// MARK: - Failure

/// Presents a stitch failure within the existing panorama sheet, keeping
/// the explanation and available retry actions together.
private struct PanoramaFailurePane: View {
    let reason: String
    let isClassicTheme: Bool
    /// Owned by the manager (`panoramaQuickPanStops`), not local state: a
    /// failed assisted retry returns to this same pane, and the chosen
    /// spacing must survive that round trip so correcting a wrong guess
    /// doesn't also forget it. Reset to 16 by the manager at every genuine
    /// new-job boundary — never shared across unrelated panoramas.
    @Binding var stops: Int
    var onDismiss: () -> Void
    /// Non-nil when a QuickPan-style retry is offered; takes the declared
    /// stops-per-revolution chosen below.
    var onQuickPan: ((Int) -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 12) {
                Image(systemName: "pano.badge.play")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(.tertiary)
                    .symbolRenderingMode(.hierarchical)

                Text("These photos wouldn't join up")
                    .font(isClassicTheme ? .classic(14, weight: .bold) : .headline)

                Text(reason)
                    .font(isClassicTheme ? .classic(11) : .callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                Text(onQuickPan != nil
                     ? "Shot on a tripod head with regular click-stops? SwiftTake can estimate joins where there's too little image detail. Use at least 6 consecutive shots, with no skipped stops or repeated starting position — most overlaps must still carry enough evidence to confirm the spacing."
                     : "Use consecutive photos with shared detail in each overlap. Blank walls and nearby objects can make alignment unreliable.")
                    .font(isClassicTheme ? .classic(11) : .caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)

                if onQuickPan != nil {
                    TripodSpacingPicker(stops: $stops, isClassicTheme: isClassicTheme)
                        .padding(.top, 4)
                }
            }
            .frame(maxWidth: 420)
            Spacer()

            Divider().opacity(0.5)
            HStack {
                Spacer()
                Button("Done", action: onDismiss)
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.bordered)
                if let onQuickPan {
                    Button("Use Tripod Spacing") { onQuickPan(stops) }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 32)
        .background(isClassicTheme
                    ? AnyShapeStyle(AppTheme.platinumFace)
                    : AnyShapeStyle(.background))
    }
}

/// "Stops per turn" selector for the QuickPan-style retry: the original
/// 16-stop QuickPan plus the other supplied KiWi+ discs (12/14/18/20), and a
/// stepper for any other consecutive-detent rig within the resource limit.
/// Classic swaps the native menu for `ClassicPopUpButton`, matching every
/// other themed dropdown in the app (see `SettingsView`).
private struct TripodSpacingPicker: View {
    @Binding var stops: Int
    let isClassicTheme: Bool

    /// Independent of `stops`'s numeric value — deriving it from
    /// `!presets.contains(stops)` instead made the Stepper disappear the
    /// moment a custom value was dialled onto a preset number (e.g. 24 down
    /// to 20), trapping the user above it with no way back down to 19.
    @State private var customMode: Bool

    init(stops: Binding<Int>, isClassicTheme: Bool) {
        _stops = stops
        self.isClassicTheme = isClassicTheme
        _customMode = State(initialValue: !Self.presets.contains(stops.wrappedValue))
    }

    private static let presets = [12, 14, 16, 18, 20]
    /// Sentinel outside the valid 6...32 range, used only to mark the
    /// "Custom…" menu row — never written to `stops` itself.
    private static let customTag = -1

    private var menuSelection: Int { customMode ? Self.customTag : stops }

    private func label(_ value: Int) -> String {
        value == 16 ? "16 (QuickPan)" : "\(value)"
    }

    private func degreesText(_ stops: Int) -> String {
        let degrees = 360.0 / Double(stops)
        return degrees == degrees.rounded()
            ? String(format: "%.0f°", degrees)
            : String(format: "%.1f°", degrees)
    }

    /// Pure menu-selection effect, kept separate from view state so the
    /// transition itself (not just today's rendering) can be checked by
    /// inspection: a preset always leaves custom mode; "Custom…" enters it,
    /// seeding 24 only when custom mode wasn't already active.
    static func applyingMenuSelection(_ value: Int, currentStops: Int, currentlyCustom: Bool) -> (stops: Int, custom: Bool) {
        guard value != customTag else {
            return currentlyCustom ? (currentStops, true) : (24, true)
        }
        return (value, false)
    }

    private func selectMenuValue(_ value: Int) {
        let result = Self.applyingMenuSelection(value, currentStops: stops, currentlyCustom: customMode)
        stops = result.stops
        customMode = result.custom
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Tripod Spacing")
                    .font(isClassicTheme ? .classic(11, weight: .bold) : .subheadline.weight(.medium))
                Spacer(minLength: 8)
                if isClassicTheme {
                    ClassicPopUpButton(
                        selection: Binding(get: { menuSelection }, set: selectMenuValue),
                        options: Self.presets.map { ($0, label($0)) } + [(Self.customTag, "Custom…")])
                } else {
                    Picker("Tripod Spacing", selection: Binding(get: { menuSelection }, set: selectMenuValue)) {
                        ForEach(Self.presets, id: \.self) { Text(label($0)).tag($0) }
                        Text("Custom…").tag(Self.customTag)
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                }
            }
            if customMode {
                Stepper(value: $stops, in: PanoramaStitcher.quickPanStopsRange) {
                    Text("\(stops) stops per turn")
                        .font(isClassicTheme ? .classic(11) : .callout)
                }
                .controlSize(.small)
            }
            Text(provenanceText)
                .font(isClassicTheme ? .classic(10) : .caption2)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Tripod spacing")
        .accessibilityValue("\(stops) stops per turn, \(degreesText(stops)) between shots")
    }

    /// Truthful regardless of ring: only the 16-stop case is the original
    /// QuickPan disc, so only it is named that way.
    private var provenanceText: String {
        let angle = degreesText(stops)
        return stops == 16 ? "\(angle) between shots · original QuickPan spacing" : "\(angle) between shots"
    }
}

// MARK: - Progress

/// The waiting state. Four frames take around eight seconds and the cost
/// grows with the number of pairs, so a sixteen-frame set is a minute or
/// more — long enough that silence reads as a hang, and long enough that
/// a way out is not optional.
private struct PanoramaProgressPane: View {
    let phase: PanoramaPhase
    let isClassicTheme: Bool
    var onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 14) {
                Image(systemName: "pano")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(.tertiary)

                Text(phase.title)
                    .font(isClassicTheme ? .classic(14, weight: .bold) : .headline)
                    // No cross-fade between stages: the three run in a
                    // fixed order and a dissolve on a line that changes
                    // three times reads as flicker.
                    .animation(nil, value: phase)

                PanoramaProgressBar(fraction: phase.fraction, isClassicTheme: isClassicTheme)
                    .frame(width: 280, height: isClassicTheme ? 12 : 6)

                Text(phase.detail)
                    .font(isClassicTheme ? .classic(11) : .caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Spacer()

            Divider().opacity(0.5)

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .modifier(SecondaryButtonModifier())
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(isClassicTheme
                    ? AnyShapeStyle(AppTheme.platinumFace)
                    : AnyShapeStyle(.background))
    }
}

/// Determinate where there is something to count, the OS 9 barber pole /
/// system spinner where there is not. Matches the gallery's loading bar
/// so the app has one progress look, not two.
private struct PanoramaProgressBar: View {
    let fraction: Double?
    let isClassicTheme: Bool

    var body: some View {
        if let fraction {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: isClassicTheme ? 2 : 3)
                        .fill(isClassicTheme
                              ? AnyShapeStyle(Color.white)
                              : AnyShapeStyle(Color.secondary.opacity(0.2)))
                        .overlay {
                            if isClassicTheme {
                                RoundedRectangle(cornerRadius: 2)
                                    .strokeBorder(AppTheme.platinumShadow.opacity(0.7), lineWidth: 1)
                            }
                        }
                    RoundedRectangle(cornerRadius: isClassicTheme ? 2 : 3)
                        .fill(isClassicTheme
                              ? AnyShapeStyle(LinearGradient(
                                  colors: [Color(red: 0.42, green: 0.56, blue: 0.86),
                                           Color(red: 0.20, green: 0.33, blue: 0.64)],
                                  startPoint: .top, endPoint: .bottom))
                              // The 90s stripes, same as the import and
                              // thumbnail-loading bars. A stitch is a wait
                              // of the same kind as an import, so it gets
                              // the same bar rather than a plain accent
                              // fill that belongs to no era in particular.
                              : AnyShapeStyle(AppTheme.apple90sStripes))
                        .frame(width: geo.size.width * fraction)
                        // Tween across the gap between ticks. A pair match
                        // is seconds, so an un-animated bar would jump
                        // once and then look stopped.
                        .animation(.linear(duration: 0.35), value: fraction)
                }
            }
        } else if isClassicTheme {
            ClassicBarberPole()
        } else {
            ProgressView().progressViewStyle(.linear)
        }
    }
}
