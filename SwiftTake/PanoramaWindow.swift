// Shared panorama composer for the gallery sheet and standalone window.
import SwiftUI
import Combine
import CoreGraphics
import UniformTypeIdentifiers

struct PanoramaWindowView: View {
    var body: some View {
        PanoramaComposerBody().frame(minWidth: 760, idealWidth: 1100, minHeight: 480, idealHeight: 640)
    }
}

struct PanoramaComposer: View {
    @ObservedObject var composition: PanoramaComposition
    let isClassicTheme: Bool
    var onClose: (() -> Void)? = nil
    var onSave: (() async -> Void)? = nil
    @State private var exploring = false
    // Explore's WebView and PNG encode are real cost; most sessions never
    // open it. Latch true on first visit so later toggles can still
    // cross-fade without a reload — only the very first Explore pays to mount.
    @State private var exploredOnce = false
    @State private var adjusting = false
    @State private var selectedPhoto: Int?
    @State private var selectionRequest = 0
    @FocusState private var photoSelectionFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var adjustmentImage: CGImage?
    @State private var adjustmentImageID: PreviewID?

    private struct PreviewID: Equatable {
        let source: Int?
        let strip: ObjectIdentifier?
    }

    private var previewID: PreviewID {
        PreviewID(source: adjusting ? selectedPhoto : nil,
                  strip: composition.strip.map(ObjectIdentifier.init))
    }

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.height < 600
            VStack(spacing: 0) {
                if isClassicTheme {
                    header(compact: compact).fixedSize(horizontal: false, vertical: true)
                } else if let note = composition.session.alignmentNote {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                        .padding(.horizontal, 24).padding(.top, 10)
                }
                preview
                    .frame(minHeight: 110, maxHeight: .infinity)
                    .padding(.horizontal, 24)
                    .padding(.top, isClassicTheme ? 0 : 12)
                    .padding(.bottom, compact ? 8 : 16)
                    .disabled(composition.isSaving)
                if let error = composition.saveError {
                    Text(error).font(.callout).foregroundStyle(.red)
                        .lineLimit(2).help(error)
                        .padding(.horizontal, 24)
                        .accessibilityLabel("Panorama error: " + error)
                }
                if adjusting {
                    photoAdjustments(compact: compact)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(reduceMotion ? .identity : .offset(y: 12).combined(with: .opacity))
                }
                Divider().opacity(0.5)
                controls(compact: compact).fixedSize(horizontal: false, vertical: true)
            }
            // Animate the panel and the space it shares with the preview in one
            // transaction. Photo selection keeps its own, separate spring.
            .animation(adjustmentTransition, value: adjusting)
        }
        .background(isClassicTheme ? AnyShapeStyle(AppTheme.platinumFace) : AnyShapeStyle(.background))
        .background {
            if !isClassicTheme {
                PanoramaNativeToolbar(exploring: $exploring, subtitle: composition.summary,
                                      enabled: composition.strip != nil && !composition.isRendering && !composition.isSaving)
                    .frame(width: 0, height: 0)
            }
        }
        .onChange(of: exploring) { if exploring { adjusting = false; exploredOnce = true } }
        .task(id: previewID) {
            let requested = previewID
            adjustmentImage = nil
            adjustmentImageID = nil
            guard let source = requested.source else { return }
            let image = await composition.adjustmentPreview(for: source)
            guard !Task.isCancelled else { return }
            adjustmentImage = image
            adjustmentImageID = requested
        }
    }

    private func header(compact: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Panorama")
                    .font(isClassicTheme ? .classic(15, weight: .bold) : .title3.weight(.semibold))
                Text(composition.summary)
                    .font(isClassicTheme ? .classic(11) : .subheadline)
                    .foregroundStyle(.secondary).lineLimit(2).help(composition.summary)
                if let note = composition.session.alignmentNote {
                    Text(note).font(isClassicTheme ? .classic(11) : .caption)
                        .foregroundStyle(.secondary).lineLimit(2).help(note)
                }
            }
            Spacer()
            PanoramaViewPicker(exploring: $exploring, isClassicTheme: isClassicTheme)
            .disabled(composition.strip == nil || composition.isRendering || composition.isSaving)
        }
        .padding(.horizontal, 24).padding(.top, compact ? 12 : 20).padding(.bottom, compact ? 10 : 16)
    }

    private var preview: some View {
        ZStack(alignment: .topTrailing) {
            if let image = composition.strip {
                // Both modes stay mounted and cross-fade: swapping views with
                // if/else would tear down and reload the WebView every
                // toggle, flashing blank while it reloads.
                ZStack {
                    PanoramaOverview(image: image, isClassicTheme: isClassicTheme,
                                     focusedPhoto: adjusting ? selectedPhoto.flatMap { composition.session.order.firstIndex(of: $0) } : nil,
                                     photoCenters: composition.photoCenters,
                                     selectedPhoto: adjusting ? selectedPhoto : nil,
                                     selectedRegions: adjusting ? selectedPhoto.map(composition.photoRegions) ?? [] : [],
                                     movingPhoto: adjusting && composition.hasPendingPhotoAdjustments
                                        && adjustmentImageID == previewID ? adjustmentImage : nil,
                                     selectionRequest: selectionRequest,
                                     onSelectPhoto: { point in
                                         guard !composition.isSaving, let source = composition.photo(at: point) else { return }
                                         selectPhoto(source)
                                     })
                        .opacity(exploring ? 0 : 1)
                        .allowsHitTesting(!exploring)
                        .disabled(exploring)
                        .accessibilityHidden(exploring)
                    if exploredOnce {
                        InteractivePanoramaPreview(image: image,
                            sweepDegrees: composition.session.sweepDegrees ?? PanoramaPipeline.sweepEstimate(for: composition.session),
                            isClassicTheme: isClassicTheme, isActive: exploring, onClose: onClose)
                            .opacity(exploring ? 1 : 0)
                            .allowsHitTesting(exploring)
                            .accessibilityHidden(!exploring)
                    }
                }
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: exploring)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if composition.isRendering {
                Label { Text("Updating…") } icon: { ProgressView().controlSize(.small) }
                    .font(.caption).padding(8)
                    .background(isClassicTheme ? AnyShapeStyle(AppTheme.platinumFace) : AnyShapeStyle(.regularMaterial),
                                in: RoundedRectangle(cornerRadius: isClassicTheme ? 0 : 8))
                    .padding(8).accessibilityLabel("Updating panorama")
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: isClassicTheme ? 0 : 8))
    }

    private func photoAdjustments(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 12) {
            ScrollViewReader { reader in
                ScrollView(.horizontal) {
                    ZStack(alignment: .leading) {
                        // One glass surface moves below a separate foreground
                        // layer. The renderer never hosts the thumbnails or text.
                        if let source = selectedPhoto,
                           let index = composition.session.order.firstIndex(of: source) {
                            PanoramaThumbnailSelection(isClassicTheme: isClassicTheme)
                                .frame(width: 78, height: compact ? 66 : 74)
                                .offset(x: CGFloat(index) * 86)
                                .animation(selectionAnimation, value: selectedPhoto)
                                .allowsHitTesting(false).accessibilityHidden(true)
                        }
                        HStack(spacing: 8) {
                            ForEach(composition.session.order, id: \.self) { source in
                                Button { selectPhoto(source) } label: {
                                    VStack(spacing: 3) {
                                        Image(decorative: composition.thumbnails[source], scale: 1)
                                            .resizable().scaledToFit().frame(width: 66, height: compact ? 38 : 46)
                                        Text("Photo \(source + 1)\(composition.adjustments[source] == nil ? "" : " •")")
                                            .font(isClassicTheme ? .classic(10) : .caption2)
                                    }
                                    .frame(width: 78, height: compact ? 66 : 74)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .id(source)
                                .accessibilityLabel("Adjust photo \(source + 1)")
                                .accessibilityAddTraits(selectedPhoto == source ? .isSelected : [])
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .defaultScrollAnchor(.center, for: .alignment)
                .focusable().focusEffectDisabled().focused($photoSelectionFocused)
                .onKeyPress(.leftArrow) { movePhotoSelection(by: -1) }
                .onKeyPress(.rightArrow) { movePhotoSelection(by: 1) }
                .onChange(of: selectionRequest) {
                    if let selectedPhoto {
                        withAnimation(selectionAnimation) { reader.scrollTo(selectedPhoto, anchor: .center) }
                    }
                }
                .onAppear {
                    if let selectedPhoto { reader.scrollTo(selectedPhoto, anchor: .center) }
                    photoSelectionFocused = true
                }
                .accessibilityLabel("Panorama photos")
                .help("Click a photo here or in the preview. Use Left and Right Arrow to choose the previous or next photo.")
            }
            .frame(height: compact ? 74 : 84)
            if let source = selectedPhoto {
                let offset = composition.adjustment(for: source)
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Photo \(source + 1)")
                            .font(isClassicTheme ? .classic(12, weight: .bold) : .subheadline.weight(.semibold))
                        Text("\(offset.x) horizontal · \(offset.y) vertical")
                            .font(isClassicTheme ? .classic(10) : .caption2)
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                    .frame(minWidth: 150, alignment: .leading)
                    Spacer(minLength: 0)
                    HStack(spacing: 16) {
                        HStack(spacing: 4) {
                            nudgeButton("Left", symbol: "arrow.left", source: source, x: -1, y: 0, disabled: offset.x <= -20)
                            nudgeButton("Right", symbol: "arrow.right", source: source, x: 1, y: 0, disabled: offset.x >= 20)
                        }
                        Divider().frame(height: 18)
                        HStack(spacing: 4) {
                            nudgeButton("Up", symbol: "arrow.up", source: source, x: 0, y: -1, disabled: offset.y <= -20)
                            nudgeButton("Down", symbol: "arrow.down", source: source, x: 0, y: 1, disabled: offset.y >= 20)
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Photo alignment")
                    Spacer(minLength: 0)
                    Menu {
                        Button("Reset Photo") { composition.resetPhoto(source) }
                            .disabled(offset == .init())
                        Button("Reset All Photos") { composition.resetPhotos() }
                            .disabled(composition.adjustments.isEmpty)
                    } label: {
                        Label("Reset", systemImage: "arrow.counterclockwise")
                    }
                    .fixedSize()
                    .disabled(composition.adjustments.isEmpty)
                    .help("Reset this photo's alignment or all photo adjustments")
                    .frame(minWidth: 150, alignment: .trailing)
                }
                .controlSize(.small)
                .padding(.vertical, compact ? 4 : 6)
            }
        }
        .padding(.horizontal, 24).padding(.bottom, compact ? 8 : 16)
        .disabled(composition.isSaving)
    }

    private var selectionAnimation: Animation? {
        reduceMotion ? nil : .spring(response: 0.55, dampingFraction: 0.82)
    }

    private var adjustmentTransition: Animation? {
        guard !reduceMotion else { return nil }
        return isClassicTheme ? .easeInOut(duration: 0.2) : .smooth(duration: 0.32)
    }

    private func selectPhoto(_ source: Int) {
        guard !composition.isSaving else { return }
        adjusting = true
        selectedPhoto = source
        selectionRequest += 1
        photoSelectionFocused = true
    }

    private func movePhotoSelection(by delta: Int) -> KeyPress.Result {
        guard adjusting, !composition.isSaving,
              let source = selectedPhoto,
              let index = composition.session.order.firstIndex(of: source) else { return .ignored }
        let next = index + delta
        if composition.session.order.indices.contains(next) {
            selectPhoto(composition.session.order[next])
        }
        return .handled
    }

    private func nudgeButton(_ title: String, symbol: String, source: Int, x: Int, y: Int, disabled: Bool) -> some View {
        Button { composition.nudgePhoto(source, x: x, y: y) } label: {
            Image(systemName: symbol).frame(width: 16, height: 16)
        }
        .accessibilityLabel("Move photo \(source + 1) \(title.lowercased())")
        .help("Move photo \(source + 1) \(title.lowercased()) by one pixel")
        .disabled(disabled)
    }

    private func controls(compact: Bool) -> some View {
        HStack(spacing: isClassicTheme ? 20 : 12) {
            Button {
                if adjusting {
                    adjusting = false
                } else {
                    exploring = false
                    if let source = selectedPhoto ?? composition.session.order.first { selectPhoto(source) }
                }
            } label: {
                Label(adjusting ? "Done Adjusting" : "Adjust Photos",
                      systemImage: adjusting ? "checkmark" : "slider.horizontal.3")
            }
            .modifier(SecondaryButtonModifier()).fixedSize()
            .disabled(composition.strip == nil)
            if !adjusting {
                Text(composition.adjustments.isEmpty ? "Aligned automatically" : "Photo adjustments applied")
                    .font(isClassicTheme ? .classic(11) : .caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let onClose { Button("Cancel", action: onClose).keyboardShortcut(.cancelAction) }
            if onSave != nil {
                Button {
                    guard composition.canSave else { return }
                    Task { await onSave?() }
                } label: {
                    if composition.isSaving { ProgressView().controlSize(.small) }
                    else { Text("Save") }
                }
                .keyboardShortcut(.defaultAction).modifier(PrimaryButtonModifier())
                .disabled(!composition.canSave)
            }
        }
        .padding(.horizontal, 24).padding(.vertical, compact ? 10 : 16)
        .disabled(composition.isSaving)
    }
}

// MARK: - Empty state

struct PanoramaEmptyState: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No panorama yet")
                .font(.title3.weight(.semibold))
            Text("Select overlapping photos in the gallery, then choose\nEdit ▸ Stitch Panorama.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A genuine window toolbar gives the composer the same system glass selector
/// as Help. It owns only its presentation and restores the host when removed.
private struct PanoramaNativeToolbar: NSViewRepresentable {
    @Binding var exploring: Bool
    let subtitle: String
    let enabled: Bool

    func makeNSView(context: Context) -> Host { Host() }

    func updateNSView(_ host: Host, context: Context) {
        host.exploring = $exploring
        host.subtitle = subtitle
        host.enabled = enabled
        host.installIfNeeded()
        host.refresh()
    }

    static func dismantleNSView(_ host: Host, coordinator: ()) { host.uninstall() }

    final class Host: NSView, NSToolbarDelegate {
        var exploring: Binding<Bool>?
        var subtitle = ""
        var enabled = true
        private weak var owner: NSWindow?
        private var toolbar: NSToolbar?
        private var control: NSSegmentedControl?
        private var previous: Presentation?
        private let modeID = NSToolbarItem.Identifier("SwiftTake.Panorama.Mode")

        private struct Presentation {
            let toolbar: NSToolbar?
            let style: NSWindow.ToolbarStyle
            let title: String
            let subtitle: String
            let titleVisibility: NSWindow.TitleVisibility
            let wasTitled: Bool
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if owner !== window { uninstall() }
            installIfNeeded()
        }

        func installIfNeeded() {
            guard owner == nil, let window else { return }
            previous = Presentation(toolbar: window.toolbar, style: window.toolbarStyle,
                                    title: window.title, subtitle: window.subtitle,
                                    titleVisibility: window.titleVisibility,
                                    wasTitled: window.styleMask.contains(.titled))
            owner = window
            let toolbar = NSToolbar(identifier: "SwiftTake.Panorama.Toolbar")
            toolbar.delegate = self
            toolbar.displayMode = .iconOnly
            toolbar.allowsUserCustomization = false
            self.toolbar = toolbar
            window.styleMask.insert(.titled)
            window.toolbarStyle = .unified
            window.titleVisibility = .visible
            window.title = "Panorama"
            window.toolbar = toolbar
            refresh()
        }

        func refresh() {
            owner?.subtitle = subtitle
            control?.isEnabled = enabled
            let selected = exploring?.wrappedValue == true ? 1 : 0
            if control?.selectedSegment != selected { control?.selectedSegment = selected }
        }

        func uninstall() {
            defer { owner = nil; toolbar = nil; control = nil; previous = nil }
            guard let owner, let previous, owner.toolbar === toolbar else { return }
            owner.toolbar = previous.toolbar
            owner.toolbarStyle = previous.style
            owner.title = previous.title
            owner.subtitle = previous.subtitle
            owner.titleVisibility = previous.titleVisibility
            if !previous.wasTitled { owner.styleMask.remove(.titled) }
        }

        func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
            [.flexibleSpace, modeID]
        }

        func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
            toolbarDefaultItemIdentifiers(toolbar)
        }

        func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                     willBeInsertedIntoToolbar: Bool) -> NSToolbarItem? {
            guard identifier == modeID else { return nil }
            let item = NSToolbarItem(itemIdentifier: identifier)
            let control = NSSegmentedControl(labels: ["Overview", "Explore"], trackingMode: .selectOne,
                                             target: self, action: #selector(selectMode(_:)))
            control.setAccessibilityLabel("Panorama view")
            item.view = control
            self.control = control
            refresh()
            return item
        }

        @objc private func selectMode(_ sender: NSSegmentedControl) {
            exploring?.wrappedValue = sender.selectedSegment == 1
        }
    }
}
