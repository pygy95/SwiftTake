// A saved panorama opens in a gallery overlay with interactive exploration
// and a whole-image overview. Done, Escape and click-away dismiss it.

import SwiftUI
import ImageIO

struct PanoramaViewer: View {
    let panorama: QuickTakeSerialManager.SavedPanorama
    let isClassicTheme: Bool
    var onClose: () -> Void

    @State private var previewImage: CGImage?
    @State private var exploring = true
    @State private var loadFailed = false
    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Click-away. Dimmed only slightly: the gallery behind
                // stays legible, because the panorama is ABOUT those
                // photos and hiding them would lose the connection.
                Rectangle()
                    .fill(.black.opacity(0.28))
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onClose)

                panel(in: geo.size)
                    .scaleEffect(appeared ? 1 : 0.97)
                    .opacity(appeared ? 1 : 0)
            }
        }
        .task(id: panorama.id) { await load() }
        .onAppear {
            withAnimation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.86)) { appeared = true }
        }
        // Escape is handled by the gallery, which owns the key window's
        // focus — an overlay that is not in the focus chain never receives
        // `onExitCommand`, so claiming it here would only look like it
        // worked. See ContentView's handler.
    }

    // MARK: Sizing
    //
    // Keep both modes readable within the window. Overview scrolls wide
    // images instead of shrinking the panel to the strip's aspect ratio.

    private func imageWidth(in size: CGSize) -> CGFloat {
        max(280, min(size.width - 96, 980))
    }

    @ViewBuilder
    private func panel(in size: CGSize) -> some View {
        let w = imageWidth(in: size)
        let h = min(520, max(240, size.height - 220))

        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Panorama")
                        .font(isClassicTheme ? .classic(14, weight: .bold) : .headline)
                    Text(panorama.caption)
                        .font(isClassicTheme ? .classic(11) : .subheadline)
                        .foregroundStyle(.secondary)
                    if let note = panorama.alignmentNote {
                        Text(note)
                            .font(isClassicTheme ? .classic(11) : .caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                PanoramaViewPicker(exploring: $exploring, isClassicTheme: isClassicTheme)
                .disabled(previewImage == nil)
                Button("Done", action: onClose)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Group {
                if let previewImage {
                    // Both modes stay mounted and simply cross-fade: an
                    // if/else swap would tear down and rebuild the WebView
                    // every toggle, flashing blank while it reloads.
                    ZStack {
                        PanoramaOverview(image: previewImage, isClassicTheme: isClassicTheme)
                            .opacity(exploring ? 0 : 1)
                            .allowsHitTesting(!exploring)
                            .disabled(exploring)
                            .accessibilityHidden(exploring)
                        InteractivePanoramaPreview(image: previewImage, sweepDegrees: panorama.sweepDegrees,
                                                    isClassicTheme: isClassicTheme, isActive: exploring, onClose: onClose)
                            .opacity(exploring ? 1 : 0)
                            .allowsHitTesting(exploring)
                            .accessibilityHidden(!exploring)
                    }
                    .frame(width: w, height: h)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: exploring)
                } else if loadFailed {
                    Text("This panorama could not be opened. Check that its saved image is still available.")
                        .foregroundStyle(.secondary).frame(width: w, height: h)
                } else {
                    ProgressView().controlSize(.small).frame(width: w, height: h)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: isClassicTheme ? 0 : 6, style: .continuous))
            .padding(.horizontal, 18)
            .padding(.bottom, 18)
        }
        .fixedSize()
        .background {
            if isClassicTheme {
                // Platinum, not glass — OS 9 had no translucency, and a
                // frosted panel inside a Platinum window is the two-apps
                // look this theme exists to avoid.
                Rectangle().fill(AppTheme.platinumFace)
                    .overlay(Rectangle().strokeBorder(AppTheme.platinumFrame, lineWidth: 1))
                    .shadow(color: .black.opacity(0.3), radius: 10, y: 6)
            } else {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.regularMaterial)
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(.white.opacity(0.12), lineWidth: 1))
                    .shadow(color: .black.opacity(0.34), radius: 30, y: 14)
            }
        }
    }

    private func load() async {
        previewImage = nil
        loadFailed = false
        let url = panorama.image
        let root = panorama.scopeRoot
        let loaded = await Task.detached(priority: .userInitiated) { () -> CGImage? in
            let access = root?.startAccessingSecurityScopedResource() ?? false
            defer { if access { root?.stopAccessingSecurityScopedResource() } }
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            return CGImageSourceCreateImageAtIndex(source, 0, nil)
        }.value
        guard !Task.isCancelled else { return }
        previewImage = loaded
        loadFailed = loaded == nil
    }
}

/// A readable flat view shared by the composer and saved panoramas. Fit is
/// optional; the default fills the available height and scrolls horizontally.
struct PanoramaOverview: View {
    let image: CGImage
    let isClassicTheme: Bool
    var focusedPhoto: Int? = nil
    var photoCenters: [Double] = []
    var selectedPhoto: Int? = nil
    var selectedRegions: [CGRect] = []
    var movingPhoto: CGImage? = nil
    var selectionRequest = 0
    var onSelectPhoto: ((CGPoint) -> Void)? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var scrollPosition = ScrollPosition(edge: .leading)
    @State private var fitsEntire = false
    @State private var zoom = 1.0
    @State private var fitZoom = 1.0
    @State private var scrollOffset = CGPoint.zero
    @GestureState private var isPinching = false
    @State private var pinchStart: (zoom: Double, imagePoint: CGPoint, viewPoint: CGPoint)?

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                let height = max(1, geometry.size.height)
                let width = height * CGFloat(image.width) / CGFloat(image.height)
                let scale = min(geometry.size.width / CGFloat(image.width), height / CGFloat(image.height))
                ScrollView([.horizontal, .vertical]) {
                    panorama(width: fitsEntire ? CGFloat(image.width) * scale : width * zoom,
                             height: fitsEntire ? CGFloat(image.height) * scale : height * zoom)
                }
                .scrollPosition($scrollPosition)
                .simultaneousGesture(MagnifyGesture()
                    .updating($isPinching) { _, active, _ in active = true }
                    .onChanged { value in
                        if pinchStart == nil {
                            let startZoom = fitsEntire ? fitZoom : zoom
                            let viewPoint = CGPoint(x: value.startAnchor.x * geometry.size.width,
                                                    y: value.startAnchor.y * geometry.size.height)
                            let content = CGSize(width: width * startZoom, height: height * startZoom)
                            let imagePoint = CGPoint(
                                x: min(1, max(0, (scrollOffset.x + viewPoint.x - max(0, (geometry.size.width - content.width) / 2)) / content.width)),
                                y: min(1, max(0, (scrollOffset.y + viewPoint.y - max(0, (geometry.size.height - content.height) / 2)) / content.height)))
                            pinchStart = (startZoom, imagePoint, viewPoint)
                        }
                        guard let pinchStart else { return }
                        fitsEntire = false
                        zoom = min(3, max(fitZoom, pinchStart.zoom * value.magnification))
                        anchorPinch(viewport: geometry.size, content: CGSize(width: width * zoom, height: height * zoom))
                    }
                    .onEnded { _ in pinchStart = nil })
                .onChange(of: isPinching) { _, active in
                    if !active { pinchStart = nil }
                }
                .onChange(of: min(1, scale * CGFloat(image.height) / height), initial: true) { _, minimum in
                    fitZoom = max(0.001, minimum)
                    zoom = max(fitZoom, zoom)
                }
                .onScrollGeometryChange(for: CGPoint.self) { $0.contentOffset } action: { _, offset in
                    scrollOffset = CGPoint(x: max(0, offset.x), y: max(0, offset.y))
                }
                .defaultScrollAnchor(.center, for: .alignment)
                .task(id: selectionRequest) {
                    guard focusedPhoto != nil else { return }
                    if fitsEntire || zoom < 1 {
                        // Keep the scroll view mounted; its size change below
                        // centres only after the full-height image is laid out.
                        fitsEntire = false
                        zoom = max(1, zoom)
                    } else {
                        centreSelection(viewport: geometry.size, contentWidth: width * zoom, contentHeight: height * zoom)
                    }
                }
                .onScrollGeometryChange(for: CGSize.self) { $0.contentSize } action: { _, size in
                    if pinchStart != nil {
                        anchorPinch(viewport: geometry.size, content: size)
                    } else if !fitsEntire, focusedPhoto != nil {
                        centreSelection(viewport: geometry.size, contentWidth: size.width, contentHeight: size.height)
                    }
                }
            }
            .background(.black.opacity(0.9))
            PanoramaControlBar(zoom: $zoom, range: fitZoom...3, showsZoom: !fitsEntire,
                               zoomLabel: "Overview zoom", isClassicTheme: isClassicTheme) {
                Button {
                    if fitsEntire { zoom = 1 }
                    fitsEntire.toggle()
                } label: {
                    Label(fitsEntire ? "Fill" : "Fit", systemImage: fitsEntire
                          ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left")
                }
                .help(fitsEntire ? "Fill the preview height" : "Fit the entire panorama")
                .accessibilityLabel(fitsEntire ? "Fill preview height" : "Fit entire panorama")
            }
        }
    }

    private func anchorPinch(viewport: CGSize, content: CGSize) {
        guard let pinchStart else { return }
        let x = min(max(0, content.width * pinchStart.imagePoint.x - pinchStart.viewPoint.x),
                    max(0, content.width - viewport.width))
        let y = min(max(0, content.height * pinchStart.imagePoint.y - pinchStart.viewPoint.y),
                    max(0, content.height - viewport.height))
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { scrollPosition.scrollTo(x: x, y: y) }
    }

    private func centreSelection(viewport: CGSize, contentWidth: CGFloat, contentHeight: CGFloat) {
        guard let focusedPhoto, photoCenters.indices.contains(focusedPhoto) else { return }
        // Concrete image coordinates avoid invisible overlay anchors resolving
        // to the entire panorama. Edge photos stop at the scrollable bounds.
        let x = min(max(0, contentWidth * photoCenters[focusedPhoto] - viewport.width / 2),
                    max(0, contentWidth - viewport.width))
        let y = max(0, (contentHeight - viewport.height) / 2)
        withAnimation(reduceMotion ? nil : .spring(response: 0.55, dampingFraction: 0.82)) {
            scrollPosition.scrollTo(x: x, y: y)
        }
    }

    private func panorama(width: CGFloat, height: CGFloat) -> some View {
        Image(decorative: image, scale: 1).resizable()
            .frame(width: width, height: height)
            .overlay(alignment: .topLeading) {
                ZStack(alignment: .topLeading) {
                    ForEach(selectedRegions.indices, id: \.self) { index in
                        let region = selectedRegions[index]
                        let rect = CGRect(x: region.minX * width, y: region.minY * height,
                                          width: region.width * width, height: region.height * height)
                        let visible = rect.intersection(CGRect(x: 0, y: 0, width: width, height: height))
                        if let movingPhoto {
                            Image(decorative: movingPhoto, scale: 1).resizable()
                                .frame(width: rect.width, height: rect.height)
                                .offset(x: rect.minX, y: rect.minY)
                        }
                        PanoramaSelectionSurface(isClassicTheme: isClassicTheme, selection: selectedPhoto) {
                            // Re-present the exact displayed pixels above the
                            // glass, as Copland does. Offsets keep them registered
                            // with the panorama throughout the selection glide.
                            ZStack(alignment: .topLeading) {
                                Image(decorative: image, scale: 1).resizable()
                                    .frame(width: width, height: height)
                                    .offset(x: -visible.minX, y: -visible.minY)
                                if let movingPhoto {
                                    Image(decorative: movingPhoto, scale: 1).resizable()
                                        .frame(width: rect.width, height: rect.height)
                                        .offset(x: rect.minX - visible.minX, y: rect.minY - visible.minY)
                                }
                            }
                            .frame(width: max(0, visible.width), height: max(0, visible.height), alignment: .topLeading)
                            .clipped()
                        }
                            .frame(width: max(0, visible.width), height: max(0, visible.height))
                            .offset(x: visible.minX, y: visible.minY)
                        if let selectedPhoto {
                            Text("Photo \(selectedPhoto + 1)")
                                .font(isClassicTheme ? .classic(11, weight: .bold) : .caption.weight(.semibold))
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .modifier(PanoramaSelectionBadge(isClassicTheme: isClassicTheme))
                                .offset(x: visible.minX + 8, y: visible.minY + 8)
                        }
                    }
                }
                .frame(width: width, height: height, alignment: .topLeading)
                .clipped().allowsHitTesting(false).accessibilityHidden(true)
                .animation(reduceMotion ? nil : .spring(response: 0.55, dampingFraction: 0.82), value: selectedPhoto)
            }
            .contentShape(Rectangle())
            .onTapGesture { location in
                guard width > 0, height > 0 else { return }
                onSelectPhoto?(CGPoint(x: location.x / width, y: location.y / height))
            }
    }
}

/// Shared native chrome keeps Overview and Explore visually consistent.
struct PanoramaControlBar<Leading: View>: View {
    @Binding var zoom: Double
    let range: ClosedRange<Double>
    var showsZoom = true
    let zoomLabel: String
    let isClassicTheme: Bool
    @ViewBuilder var leading: () -> Leading

    var body: some View {
        HStack(spacing: 10) {
            leading()
            Spacer(minLength: 8)
            if showsZoom {
                Image(systemName: "minus.magnifyingglass").accessibilityHidden(true)
                Slider(value: $zoom, in: range).frame(width: 90)
                    .accessibilityLabel(zoomLabel)
                Image(systemName: "plus.magnifyingglass").accessibilityHidden(true)
            }
        }
        .overlay {
            GeometryReader { geometry in
                if geometry.size.width >= 540 {
                    Text("Scroll to explore · Pinch to zoom")
                        .font(isClassicTheme ? .classic(10) : .caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .allowsHitTesting(false)
                }
            }
            .allowsHitTesting(false)
        }
        .controlSize(.small)
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(isClassicTheme ? AnyShapeStyle(AppTheme.platinumFace) : AnyShapeStyle(.bar))
    }
}

/// The same two views in both themes, using Platinum push surfaces in Classic.
struct PanoramaViewPicker: View {
    @Binding var exploring: Bool
    let isClassicTheme: Bool

    var body: some View {
        Group {
            if isClassicTheme {
                HStack(spacing: 8) {
                    classicButton("Overview", value: false)
                    classicButton("Explore", value: true)
                }
            } else {
                PanoramaModeSegments(exploring: $exploring)
                    .frame(height: 32)
            }
        }
        .frame(width: isClassicTheme ? 188 : 196).fixedSize(horizontal: false, vertical: true)
    }

    private func classicButton(_ title: String, value: Bool) -> some View {
        Button { exploring = value } label: {
            Text(title).font(.classic(12, weight: .semibold))
                .foregroundStyle(AppTheme.platinumText)
                .frame(maxWidth: .infinity).padding(.vertical, 6)
                .background(ClassicSquareSurface(pressed: exploring == value))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(exploring == value ? .isSelected : [])
        .help("Show \(title.lowercased())")
    }
}

/// Use AppKit's capsule segmented control so selection tracking and its
/// animation stay native, like the Help window's toolbar picker.
private struct PanoramaModeSegments: NSViewRepresentable {
    @Binding var exploring: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeCoordinator() -> Coordinator { Coordinator(exploring: $exploring) }

    func makeNSView(context: Context) -> NSGlassEffectView {
        let control = NSSegmentedControl(labels: ["Overview", "Explore"], trackingMode: .selectOne,
                                         target: context.coordinator, action: #selector(Coordinator.select(_:)))
        control.borderShape = .capsule
        control.controlSize = .large
        control.segmentDistribution = .fillEqually
        control.setAccessibilityLabel("Panorama view")
        let glass = NSGlassEffectView()
        glass.cornerRadius = 18
        glass.effectIsInteractive = true
        glass.contentView = control
        return glass
    }

    func updateNSView(_ glass: NSGlassEffectView, context: Context) {
        guard let control = glass.contentView as? NSSegmentedControl else { return }
        context.coordinator.exploring = $exploring
        control.isEnabled = isEnabled
        let selection = exploring ? 1 : 0
        if control.selectedSegment != selection { control.selectedSegment = selection }
    }

    final class Coordinator: NSObject {
        var exploring: Binding<Bool>
        init(exploring: Binding<Bool>) { self.exploring = exploring }
        @objc func select(_ sender: NSSegmentedControl) { exploring.wrappedValue = sender.selectedSegment == 1 }
    }
}



/// Copland's clear bubble with sharp photo detail above it. Only a narrow
/// feathered edge reveals the glass; the alignment detail remains readable.
struct PanoramaSelectionSurface<Detail: View>: View {
    let isClassicTheme: Bool
    let selection: Int?
    @ViewBuilder let detail: Detail
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if isClassicTheme {
            Rectangle().strokeBorder(AppTheme.platinumLight, lineWidth: 4)
                .overlay(Rectangle().strokeBorder(AppTheme.platinumHighlight, lineWidth: 2))
        } else if reduceTransparency {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.accentColor, lineWidth: 2)
        } else {
            GeometryReader { geometry in
                let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
                let edge = max(3, min(12, min(geometry.size.width, geometry.size.height) * 0.06))
                let reduceMotionSnapshot = reduceMotion
                ZStack {
                    Color.clear
                        .glassEffect(.clear, in: shape)
                        .overlay(shape.strokeBorder(.white.opacity(0.16), lineWidth: 1))
                        .clipShape(shape)
                        .keyframeAnimator(initialValue: CGFloat.zero, trigger: selection) { glass, stretch in
                            // A bounded ripple in the glass, never in the photo.
                            // Long jumps receive the same small settling motion.
                            let edgeScale = min(1, min(geometry.size.width, geometry.size.height) / 40)
                            let amount = reduceMotionSnapshot ? 0 : stretch * edgeScale
                            glass.scaleEffect(x: 1 + amount / max(1, geometry.size.width),
                                              y: 1 - amount / max(1, geometry.size.height))
                        } keyframes: { _ in
                            CubicKeyframe(4, duration: 0.12)
                            CubicKeyframe(-2, duration: 0.12)
                            CubicKeyframe(0.6, duration: 0.10)
                            CubicKeyframe(0, duration: 0.14)
                        }
                    detail
                        .clipShape(shape)
                        .mask(shape.inset(by: edge).fill(.black).blur(radius: edge * 0.9))
                }

            }
        }
    }
}

private struct PanoramaSelectionBadge: ViewModifier {
    let isClassicTheme: Bool

    func body(content: Content) -> some View {
        if isClassicTheme {
            content.foregroundStyle(AppTheme.platinumText)
                .background(AppTheme.platinumFace)
                .classicBevel(cornerRadius: 0)
        } else {
            content.glassEffect(.regular.tint(Color.accentColor.opacity(0.12)), in: Capsule())
        }
    }
}

struct PanoramaThumbnailSelection: View {
    let isClassicTheme: Bool

    var body: some View {
        if isClassicTheme {
            Rectangle().fill(AppTheme.platinumHighlight.opacity(0.15))
                .overlay(Rectangle().strokeBorder(AppTheme.platinumHighlight, lineWidth: 2))
        } else {
            Color.clear.glassEffect(.clear.tint(Color.accentColor.opacity(0.12)),
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}
