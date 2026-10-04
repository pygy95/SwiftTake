import SwiftUI
import Combine
import WebKit

/// Uses the same projection as the portable export, without opening a browser
/// or giving WebKit access to the user's photo folder.
struct InteractivePanoramaPreview: View {
    let image: CGImage
    let sweepDegrees: Double
    var isClassicTheme: Bool = false
    var isActive: Bool = true
    var onClose: (() -> Void)? = nil
    @State private var document: String?
    @State private var loadedRequest: Request?
    @State private var failed = false
    @State private var ready = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var controls = PanoramaExploreControls()

    private struct Request: Equatable {
        let image: ObjectIdentifier
        let sweep: Double
    }

    private var request: Request {
        Request(image: ObjectIdentifier(image), sweep: sweepDegrees)
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
              Color.black
              // Keep the image visible until WebKit has loaded the document.
              Image(decorative: image, scale: 1).resizable().scaledToFit()
              if failed {
                  Text("Interactive preview unavailable. The complete panorama is shown.")
                      .font(.caption).foregroundStyle(.white)
                      .padding(.horizontal, 10).padding(.vertical, 6)
                      .background(.black.opacity(0.55), in: Capsule())
                      .padding()
              } else if let document, loadedRequest == request {
                  PanoramaWebView(document: document, isActive: isActive, controls: controls, onClose: onClose,
                                  onReady: { ready = true }, onFailure: { failed = true; controls.available = false })
                      .opacity(ready ? 1 : 0)
                      .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: ready)
              } else {
                  ProgressView().tint(.white)
              }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            PanoramaControlBar(zoom: Binding(get: { controls.zoom }, set: controls.setZoom),
                               range: 1...4, zoomLabel: "Explore zoom", isClassicTheme: isClassicTheme) {
                Button(action: controls.reset) { Label("Reset", systemImage: "arrow.counterclockwise") }
                    .help("Reset the view and zoom")
            }
            .disabled(!ready || !controls.available || !isActive)
        }
        .task(id: isActive ? request : nil) {
            guard isActive, loadedRequest != request || document == nil else { return }
            let requested = request
            document = nil
            failed = false
            ready = false
            controls.available = false
            let image = image, sweep = sweepDegrees
            let work = Task.detached(priority: .userInitiated) {
                try InteractivePanoramaWriter.document(panorama: image, sweepDegrees: sweep, embedded: true)
            }
            do {
                let html = try await withTaskCancellationHandler {
                    try await work.value
                } onCancel: { work.cancel() }
                try Task.checkCancellation()
                loadedRequest = requested
                document = html
            } catch is CancellationError {
                // Dismissal or a newer render superseded this preview.
            } catch {
                if !Task.isCancelled { failed = true }
            }
        }
    }
}

/// A small bridge for native controls. WebKit remains the source of zoom truth
/// so pinches, wheel input and the slider cannot drift out of sync.
private final class PanoramaExploreControls: ObservableObject {
    @Published var zoom = 1.0
    @Published var available = false
    weak var webView: WKWebView?

    func setZoom(_ value: Double) {
        guard available, value.isFinite else { return }
        zoom = min(4, max(1, value))
        webView?.evaluateJavaScript("window.swiftTakePanorama?.setZoom(\(zoom))", completionHandler: nil)
    }

    func reset() {
        guard available else { return }
        webView?.evaluateJavaScript("window.swiftTakePanorama?.reset()", completionHandler: nil)
    }
}

private struct PanoramaWebView: NSViewRepresentable {
    let document: String
    let isActive: Bool
    let controls: PanoramaExploreControls
    var onClose: (() -> Void)?
    var onReady: () -> Void
    var onFailure: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(controls: controls, onClose: onClose, onReady: onReady, onFailure: onFailure) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(context.coordinator, name: "dismissPanorama")
        configuration.userContentController.add(context.coordinator, name: "panoramaState")
        configuration.userContentController.addUserScript(WKUserScript(source: """
            window.swiftTakeSetActive = active => {
                document.documentElement.inert = !active;
                if (!active) {
                    document.activeElement?.blur();
                    window.dispatchEvent(new Event('blur'));
                }
            };
            document.addEventListener('keydown', e => {
                if (e.key === 'Escape' && e.isTrusted) {
                    e.preventDefault();
                    e.stopPropagation();
                    window.webkit.messageHandlers.dismissPanorama.postMessage(null);
                }
            });
            """, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let view = WKWebView(frame: .zero, configuration: configuration)
        controls.webView = view
        view.navigationDelegate = context.coordinator
        view.underPageBackgroundColor = .black
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.onClose = onClose
        context.coordinator.onFailure = onFailure
        context.coordinator.onReady = onReady
        if context.coordinator.isActive != isActive {
            context.coordinator.isActive = isActive
            if !isActive, let responder = view.window?.firstResponder as? NSView,
               responder === view || responder.isDescendant(of: view) {
                view.window?.makeFirstResponder(nil)
            }
            context.coordinator.updateActivity(view)
        }
        guard context.coordinator.document != document else { return }
        context.coordinator.document = document
        context.coordinator.navigation = view.loadHTMLString(document, baseURL: nil)
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        view.stopLoading()
        view.navigationDelegate = nil
        view.configuration.userContentController.removeScriptMessageHandler(forName: "dismissPanorama")
        view.configuration.userContentController.removeScriptMessageHandler(forName: "panoramaState")
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let controls: PanoramaExploreControls
        var document: String?
        var navigation: WKNavigation?
        var isActive = true
        var onReady: () -> Void
        var onClose: (() -> Void)?
        var onFailure: () -> Void

        init(controls: PanoramaExploreControls, onClose: (() -> Void)?, onReady: @escaping () -> Void, onFailure: @escaping () -> Void) {
            self.controls = controls
            self.onClose = onClose
            self.onReady = onReady
            self.onFailure = onFailure
        }

        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame else { return }
            if isActive, message.name == "dismissPanorama" { onClose?() }
            if message.name == "panoramaState", let state = message.body as? [String: Any],
               let zoom = state["zoom"] as? Double, zoom.isFinite, (1...4).contains(zoom),
               let available = state["available"] as? Bool {
                if controls.zoom != zoom { controls.zoom = zoom }
                if controls.available != available { controls.available = available }
            }
        }

        func updateActivity(_ webView: WKWebView) {
            webView.evaluateJavaScript("window.swiftTakeSetActive?.(\(isActive ? "true" : "false"))", completionHandler: nil)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard navigation === self.navigation else { return }
            updateActivity(webView)
            onReady()
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // All image data is inline. Navigation must remain in this preview.
            decisionHandler(action.request.url?.absoluteString == "about:blank" ? .allow : .cancel)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            guard navigation === self.navigation, (error as NSError).code != NSURLErrorCancelled else { return }
            onFailure()
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            guard navigation === self.navigation, (error as NSError).code != NSURLErrorCancelled else { return }
            onFailure()
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { onFailure() }
    }
}
