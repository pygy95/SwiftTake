// MARK: - PanoramaBandTile
//
// One saved panorama, in the band under the camera grid.
//
// Full width and its own aspect ratio. Everything above it is a square-ish
// cell of a 4:3 photo; this is a 5:1 or 12:1 strip and pretending otherwise
// would make the one thing the user just built the hardest thing on screen
// to see.

import SwiftUI
import ImageIO

struct PanoramaBandTile: View {
    let panorama: QuickTakeSerialManager.SavedPanorama
    let isClassicTheme: Bool
    var onOpen: () -> Void
    var onRevealInFinder: () -> Void

    @State private var image: NSImage?
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .caption2) private var qualityBadgeSize: CGFloat = 9

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: onOpen) {
                ZStack {
                    if let image {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            // The strip is read off disk and downsampled, so it
                            // lands a beat after the tile does. Fading it in
                            // stops that beat reading as a flash.
                            .transition(.opacity)
                    } else {
                        Rectangle()
                            .fill(isClassicTheme ? AnyShapeStyle(AppTheme.platinumFace)
                                                 : AnyShapeStyle(Color.secondary.opacity(0.12)))
                            .frame(height: 90)
                            .overlay(ProgressView().controlSize(.small))
                    }
                }
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: isClassicTheme ? 0 : 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: isClassicTheme ? 0 : 8, style: .continuous)
                        .strokeBorder(isClassicTheme ? AppTheme.platinumShadow.opacity(0.7)
                                                     : Color.primary.opacity(hovering ? 0.22 : 0.08),
                                      lineWidth: 1)
                }
                .shadow(color: .black.opacity(isClassicTheme ? 0 : (hovering ? 0.18 : 0.08)),
                        radius: hovering ? 10 : 4, y: hovering ? 4 : 2)
                // Reduce Motion: skip the hover lift; the border/shadow change
                // above still shows the hover state without any movement.
                .scaleEffect(reduceMotion ? 1 : (hovering ? 1.004 : 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open panorama, \(panorama.caption)")

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("Panorama")
                Text("·").foregroundStyle(.tertiary)
                Text(panorama.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 12)
                // What the save actually wrote. The panorama goes to disk
                // in three forms — the flat picture, interactive browser
                // viewer, and immersive still — and without this the
                // other two are invisible unless the user opens the folder.
                if !panorama.formats.isEmpty {
                    Text(panorama.formatsCaption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .padding(.trailing, 4)
                }
                if let isHQ = panorama.sourceIsHQ {
                    if isHQ {
                        HQBadgeView()
                    } else {
                        Text("SQ")
                            .font(.system(size: qualityBadgeSize, weight: .bold, design: .rounded))
                            .foregroundColor(.secondary)
                            .classicHelp("Standard Quality")
                    }
                }
                Button(action: onRevealInFinder) {
                    Text(Image(systemName: "folder.fill"))
                        .foregroundColor(.accentColor)
                        .font(.caption2)
                }
                .buttonStyle(PressableScaleButtonStyle(pressedScale: 0.9, pressedOpacity: 0.85, shadowRadius: 2))
                .classicHelp("Show in Finder")
                .accessibilityLabel("Show panorama in Finder")
                Text(Image(systemName: "checkmark.circle.fill"))
                    .foregroundColor(.green)
                    .font(.caption2)
                    .accessibilityLabel("Saved")
            }
            .font(isClassicTheme ? Font.classic(11) : .caption)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.16), value: hovering)
        .accessibilityElement(children: .contain)
        .task(id: panorama.image) { await load() }
    }

    private func load() async {
        let url = panorama.image
        // `scopeRoot` is the bookmark-gated folder the save itself claimed
        // scope on, when present — re-acquire it for
        // this reload the same way the save acquired it originally.
        let scope: DestinationScope? = panorama.scopeRoot.map(URLDestinationScope.init)
        let work = Task.detached(priority: .utility) { () -> CGImage? in
            guard !Task.isCancelled else { return nil }
            // Downsampled: the strip on disk can be 12 frames wide, and the
            // band shows it a few hundred points across.
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 2400,
                kCGImageSourceCreateThumbnailWithTransform: true]
            let cg: CGImage? = { () -> CGImage? in
                func decode() -> CGImage? {
                    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
                    return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
                }
                guard let scope else { return decode() }
                return withDestinationScope(scope, decode)
            }()
            return cg
        }
        let cg = await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
        guard !Task.isCancelled, let cg else { return }
        let ns = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        withAnimation(.easeIn(duration: 0.25)) { image = ns }
    }
}
