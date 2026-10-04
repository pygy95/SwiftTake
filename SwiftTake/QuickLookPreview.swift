// MARK: - QuickLookPreview
//
// Wraps macOS's `QLPreviewPanel` so the gallery can pop up the same
// full-screen-ish QuickLook preview a Finder spacebar tap shows. The
// preview shows already-saved files (TIFF / PNG / JPEG / HEIC) — not
// the raw `.QTK` (which the OS doesn't know how to render).
//
// Singleton (`.shared`) because `QLPreviewPanel` is a process-wide
// resource. The `onIndexChanged` callback fires when the user arrows
// between previews so the gallery can keep its selection in sync.

import AppKit
import QuickLookUI
import ImageIO

final class QuickLookPreviewController: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLookPreviewController()

    private var previewItems: [(url: URL, index: UInt8)] = []
    var onIndexChanged: ((UInt8) -> Void)?
    private var indexObserver: NSKeyValueObservation?
    /// Queried LIVE each time ↑/↓ is pressed, so a row jump always uses the
    /// gallery's CURRENT column count (which changes as the user zooms or
    /// resizes the window while the preview is open).
    private var columnCountProvider: () -> Int = { 1 }

    func present(items: [(url: URL, index: UInt8)],
                 selectedIndex: Int,
                 columnCount: @escaping () -> Int) {
        previewItems = items
        self.columnCountProvider = columnCount

        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.currentPreviewItemIndex = selectedIndex
        panel.makeKeyAndOrderFront(nil)

        // Fit the panel window to the photo's aspect so it opens snug (rounded,
        // content-fit) instead of QuickLook reusing a taller remembered frame and
        // letterboxing the 4:3 image with black bars. Purely a window-frame nudge —
        // no responder-chain / first-responder changes. Re-applied once on the next
        // tick in case QuickLook restores its own frame as the image loads.
        if selectedIndex < items.count {
            let url = items[selectedIndex].url
            fitPanel(panel, to: url)
            DispatchQueue.main.async { [weak panel] in
                guard let panel else { return }
                self.fitPanel(panel, to: url)
            }
        }

        indexObserver = panel.observe(\.currentPreviewItemIndex, options: [.new]) { [weak self] panel, change in
            guard let self = self, let newIndex = change.newValue, newIndex < self.previewItems.count else { return }
            self.onIndexChanged?(self.previewItems[newIndex].index)
        }
    }

    /// Resize + centre the preview panel window to match the image's aspect, so
    /// there's no letterboxing. All QuickTake photos are 4:3, but we read the real
    /// aspect from the file to stay correct for anything else.
    private func fitPanel(_ panel: QLPreviewPanel, to url: URL) {
        var aspect: CGFloat = 4.0 / 3.0
        if let src = CGImageSourceCreateWithURL(url as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
           let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
           let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
           w > 0, h > 0 {
            aspect = CGFloat(w / h)
        }
        guard let screen = panel.screen ?? NSScreen.main else { return }
        let vis = screen.visibleFrame
        // Comfortable content width, capped so it never dominates the screen.
        let contentW = min(620, vis.width * 0.6)
        let contentH = contentW / aspect
        let titleBar: CGFloat = 28   // QuickLook's chrome strip
        let winW = contentW
        let winH = contentH + titleBar
        let frame = NSRect(x: vis.midX - winW / 2,
                           y: vis.midY - winH / 2,
                           width: winW, height: winH)
        panel.setFrame(frame, display: true, animate: false)
    }

    func dismiss() {
        indexObserver?.invalidate()
        indexObserver = nil
        QLPreviewPanel.shared()?.orderOut(nil)
        previewItems = []
        onIndexChanged = nil
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        previewItems.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        previewItems[index].url as NSURL
    }

    /// Make the preview navigate the grid, not just a 1-D filmstrip: ↑/↓ jump a
    /// full row using the gallery's LIVE column count; ←/→ fall through to
    /// QuickLook's normal prev/next.
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown, !previewItems.isEmpty else { return false }
        let columns = max(1, columnCountProvider())
        let current = panel.currentPreviewItemIndex
        let target: Int
        switch event.keyCode {
        case 126: target = current - columns   // up arrow
        case 125: target = current + columns   // down arrow
        default:  return false                 // ←/→ etc. → default QuickLook handling
        }
        let clamped = min(max(target, 0), previewItems.count - 1)
        if clamped != current { panel.currentPreviewItemIndex = clamped }
        return true
    }
}
