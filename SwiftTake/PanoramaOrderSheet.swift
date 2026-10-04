// MARK: - Panorama order sheet
//
// Sits between file selection (chooser or drop) and the composer.
//
// A gallery selection never sees this. Camera slot order is capture
// order, so picking photos 4 through 8 picks a run: they are already a
// sequence and could not have been picked otherwise. The one unknown is
// direction, and the stitcher measures that by fitting both and keeping
// the better — asking would be asking the user to confirm something the
// app is more certain about than they are.
//
// Files from Finder have no such guarantee. Filenames usually encode
// capture time, so name order is a good default, but files get renamed,
// gathered from two folders, exported out of sequence. Hence this.
//
// Automatic previews filename order; Manual enables rearranging. Both modes
// keep the photos readable and the horizontal strip scrollable.

import SwiftUI
import UniformTypeIdentifiers

struct PanoramaOrderSheet: View {
    /// Files as Finder handed them over, already sorted by name.
    let urls: [URL]
    let isClassicTheme: Bool
    let capturedData: [URL: Data]?
    /// Automatic returns the original sequence; Manual returns the arranged sequence.
    let onConfirm: ([URL]) -> Void
    let onCancel: () -> Void

    @State private var order: [URL]
    @State private var automatic = true
    @State private var thumbs: [URL: CGImage] = [:]
    @State private var dragging: URL?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(urls: [URL], isClassicTheme: Bool, capturedData: [URL: Data]? = nil,
         onConfirm: @escaping ([URL]) -> Void, onCancel: @escaping () -> Void) {
        self.urls = urls
        self.isClassicTheme = isClassicTheme
        self.capturedData = capturedData
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        _order = State(initialValue: urls)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            orderingControls
            photoStrip
            Spacer(minLength: 12)
            footer
        }
        .padding(.top, isClassicTheme ? ClassicTitleBar.height : 0)
        .frame(width: 820)
        .fixedSize(horizontal: false, vertical: true)
        .background(isClassicTheme ? AnyShapeStyle(AppTheme.platinumFace) : AnyShapeStyle(.background))
        .task { await loadThumbnails() }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Arrange Photos")
                .font(isClassicTheme ? .classic(20, weight: .bold) : .title2.weight(.semibold))
            Text("Review the sequence before making your panorama.")
                .font(isClassicTheme ? .classic(12) : .callout)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 32)
        .padding(.top, 28)
        .padding(.bottom, 20)
    }

    // MARK: Ordering

    private var orderingControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Photo Order")
                    .font(isClassicTheme ? .classic(12, weight: .bold) : .headline)
                Spacer()
                Group {
                    if isClassicTheme {
                        HStack(spacing: 8) {
                            classicModeButton("Automatic", value: true)
                            classicModeButton("Manual", value: false)
                        }
                    } else {
                        Picker("Photo Order", selection: $automatic) {
                            Text("Automatic").tag(true)
                            Text("Manual").tag(false)
                        }
                        .pickerStyle(.segmented).labelsHidden()
                    }
                }
                .frame(width: 240)
            }
            HStack(spacing: 12) {
                Text(automatic
                     ? "Uses filename order and detects the pan direction."
                     : "Arrange photos from left to right. Drag a photo to move it.")
                    .font(isClassicTheme ? .classic(11) : .callout)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button("Reverse Order") { order.reverse() }
                    .modifier(SecondaryButtonModifier())
                    .controlSize(.small)
                    .opacity(automatic ? 0 : 1)
                    .disabled(automatic)
                    .accessibilityHidden(automatic)
                    .help("Reverse the manual photo sequence")
            }
        }
        .padding(.horizontal, 32)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: automatic)
        .onChange(of: automatic) { dragging = nil }
    }

    private func classicModeButton(_ title: String, value: Bool) -> some View {
        Button { automatic = value } label: {
            Text(title).font(.classic(12, weight: .semibold))
                .foregroundStyle(AppTheme.platinumText)
                .frame(maxWidth: .infinity).padding(.vertical, 6)
                .background(ClassicSquareSurface(pressed: automatic == value))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(automatic == value ? .isSelected : [])
        .accessibilityLabel("\(title) photo order")
    }

    // MARK: Photos

    private var photoStrip: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Fit when they fit, scroll when they cannot — and SAY SO when
            // they cannot.
            //
            // This used to be a fixed 180pt tile that always scrolled. Five
            // photos come to 970pt in a sheet with ~756 to spare, so the
            // fourth was sliced in half and the fifth was off the edge
            // entirely — under a header that says "5 photos from Finder".
            // macOS hides overlay scrollbars until you actually scroll, so
            // nothing on screen suggested the rest existed.
            //
            // Tiles now divide the available width, floored at 96 so a
            // sixteen-frame pan does not shrink into unreadable chips; past
            // that it scrolls, and the trailing fade is what admits there is
            // more. Fading only when it overflows keeps the common case
            // clean rather than permanently dimming an edge for no reason.
            GeometryReader { geo in
                let spacing: CGFloat = 14
                let fitted = (geo.size.width - spacing * CGFloat(max(0, order.count - 1)))
                    / CGFloat(max(1, order.count))
                let tile = min(180, max(96, fitted))
                let overflows = fitted < 96

                ScrollView(.horizontal, showsIndicators: true) {
                    HStack(spacing: spacing) {
                        ForEach(Array((automatic ? urls : order).enumerated()), id: \.element) { position, url in
                            if automatic {
                                thumb(url, position: position, width: tile)
                            } else {
                                thumb(url, position: position, width: tile)
                                    .onDrag {
                                        dragging = url
                                        return NSItemProvider(object: url.lastPathComponent as NSString)
                                    }
                                    .onDrop(of: [.text], delegate: ReorderDrop(
                                        item: url, order: $order, dragging: $dragging))
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .mask(alignment: .leading) {
                    if overflows {
                        LinearGradient(
                            stops: [.init(color: .black, location: 0),
                                    .init(color: .black, location: 0.93),
                                    .init(color: .clear, location: 1)],
                            startPoint: .leading, endPoint: .trailing)
                    } else {
                        Rectangle()
                    }
                }
            }
            .frame(height: thumbnailStripHeight)
        }
        .padding(.horizontal, 32)
        .padding(.top, 22)

    }

    private var thumbnailStripHeight: CGFloat {
        let availableWidth: CGFloat = 820 - 64
        let tileWidth = min(180, max(96,
            (availableWidth - 14 * CGFloat(max(0, order.count - 1))) / CGFloat(max(1, order.count))))
        return tileWidth * 0.75 + 38
    }

    private func thumb(_ url: URL, position: Int, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topLeading) {
                Group {
                    if let cg = thumbs[url] {
                        Image(decorative: cg, scale: 1).resizable().scaledToFill()
                    } else {
                        Rectangle().fill(.quaternary)
                    }
                }
                // 4:3, the shape every QuickTake frame is.
                .frame(width: width, height: width * 0.75)
                .clipShape(RoundedRectangle(cornerRadius: isClassicTheme ? 0 : 8, style: .continuous))

                Text("\(position + 1)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.black.opacity(0.55), in: Capsule())
                    .padding(8)
            }
            Text(url.deletingPathExtension().lastPathComponent)
                .font(isClassicTheme ? .classic(9) : .caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: width, alignment: .leading)
        }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: isClassicTheme ? 20 : 12) {
                Text("\(urls.count) photos")
                    .font(isClassicTheme ? .classic(12, weight: .bold) : .headline)
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .modifier(SecondaryButtonModifier())
                Button("Make Panorama") { onConfirm(automatic ? urls : order) }
                    .keyboardShortcut(.defaultAction)
                    .modifier(PrimaryButtonModifier())
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 18)
        }
    }

    // MARK: Thumbnails

    /// Small, and off the main actor. A .qtk has to go through the decoder
    /// to become a picture at all, which is why these are loaded rather
    /// than handed straight to `Image`.
    private func loadThumbnails() async {
        for url in urls {
            if Task.isCancelled { return }
            let cg: CGImage? = await Task.detached(priority: .utility) {
                let data: Data
                if let capturedData {
                    guard let captured = capturedData[url] else { return nil }
                    data = captured
                } else {
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    guard let read = try? Data(contentsOf: url) else { return nil }
                    data = read
                }
                if url.pathExtension.lowercased() == "qtk" {
                    return QTKDecoder().decode(data: data, enhanced: false,
                                               hdrEnabled: false, hdrHeadroom: 1.5)?
                        .cgImage(forProposedRect: nil, context: nil, hints: nil)
                }
                guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
                return CGImageSourceCreateThumbnailAtIndex(src, 0, [
                    kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                    kCGImageSourceThumbnailMaxPixelSize: 360
                ] as CFDictionary)
            }.value
            if let cg { thumbs[url] = cg }
        }
    }
}

/// Reorder-on-hover. The dragged item moves as the pointer passes others,
/// so the strip always shows the arrangement that would result from
/// letting go — no gap to interpret, no drop target to aim at.
private struct ReorderDrop: DropDelegate {
    let item: URL
    @Binding var order: [URL]
    @Binding var dragging: URL?

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != item,
              let from = order.firstIndex(of: dragging),
              let to = order.firstIndex(of: item) else { return }
        withAnimation(.easeInOut(duration: 0.18)) {
            order.move(fromOffsets: IndexSet(integer: from),
                       toOffset: to > from ? to + 1 : to)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool { dragging = nil; return true }
}
