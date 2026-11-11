import AppKit
import WebKit
import UniformTypeIdentifiers

final class DesklandFolderSchemeHandler: NSObject, WKURLSchemeHandler {
    let rootDirectory: URL

    init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory.standardizedFileURL.resolvingSymlinksInPath()
    }

    private func isInsideRoot(_ url: URL) -> Bool {
        let rootPath = rootDirectory.path
        let path = url.path
        return path == rootPath || path.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        var relPath = url.path
        while relPath.hasPrefix("/") { relPath.removeFirst() }
        if relPath.isEmpty { relPath = "index.html" }

        let targetURL = rootDirectory.appendingPathComponent(relPath).standardizedFileURL.resolvingSymlinksInPath()
        guard isInsideRoot(targetURL),
              let data = try? Data(contentsOf: targetURL) else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }

        let ext = targetURL.pathExtension.lowercased()
        let mime: String = {
            switch ext {
            case "html", "htm": return "text/html; charset=utf-8"
            case "js", "mjs": return "text/javascript; charset=utf-8"
            case "css": return "text/css; charset=utf-8"
            case "json": return "application/json; charset=utf-8"
            case "webp": return "image/webp"
            case "png": return "image/png"
            case "jpg", "jpeg": return "image/jpeg"
            case "svg": return "image/svg+xml"
            default:
                return UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
            }
        }()

        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": mime,
                "Content-Length": "\(data.count)",
                "Access-Control-Allow-Origin": "*"
            ]
        )!
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}
}

@MainActor
final class DesklandWebThemeView: NSView, WKScriptMessageHandler {
    private var webView: WKWebView?
    private var isReady = false
    private var currentFolder: String = ""
    private var currentPage: String = ""

    private var pendingParams: [String: Double] = [:]
    private var pendingSeed: Int = 421337
    private var pendingObstacles: [IconObstacle] = []
    private var pendingBottomInset: Float = 72
    private var pendingPaused: Bool = false
    let isPreview: Bool

    init(frame frameRect: NSRect, isPreview: Bool = false) {
        self.isPreview = isPreview
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    isolated deinit {
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "deskland")
    }

    func loadExternalTheme(folderPath: String, page: String) {
        guard folderPath != currentFolder || page != currentPage else { return }
        currentFolder = folderPath
        currentPage = page
        isReady = false

        teardownWebView()

        let cfg = WKWebViewConfiguration()
        cfg.setURLSchemeHandler(DesklandFolderSchemeHandler(rootDirectory: URL(fileURLWithPath: folderPath)), forURLScheme: "deskland")

        let ucc = WKUserContentController()
        let bridgeJS = """
        (function() {
          window.__dlListeners = [];
          window.chrome = window.chrome || {};
          window.chrome.webview = {
            postMessage: function(msg) {
              try {
                var payload = typeof msg === 'string' ? msg : JSON.stringify(msg);
                window.webkit.messageHandlers.deskland.postMessage(payload);
              } catch (e) {}
            },
            addEventListener: function(type, fn) {
              if (type === 'message' && typeof fn === 'function') window.__dlListeners.push(fn);
            }
          };
          window.__dlDeliver = function(obj) {
            var ev = { data: obj };
            for (var i = 0; i < window.__dlListeners.length; i++) {
              try { window.__dlListeners[i](ev); } catch (e) {}
            }
            window.dispatchEvent(new MessageEvent('message', { data: obj }));
          };
        })();
        """
        ucc.addUserScript(WKUserScript(source: bridgeJS, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        ucc.add(self, name: "deskland")
        cfg.userContentController = ucc

        let wv = WKWebView(frame: bounds, configuration: cfg)
        wv.autoresizingMask = [.width, .height]
        wv.setValue(false, forKey: "drawsBackground")
        addSubview(wv)
        self.webView = wv

        let query = isPreview ? "preview=1" : "wallpaper=1"
        if let url = URL(string: "deskland://app.local/\(page)?\(query)") {
            wv.load(URLRequest(url: url))
        }
    }

    func teardownWebView() {
        if let wv = webView {
            wv.configuration.userContentController.removeScriptMessageHandler(forName: "deskland")
            wv.stopLoading()
            wv.removeFromSuperview()
            webView = nil
        }
        isReady = false
    }

    func sendSettings(params: [String: Double], seed: Int) {
        pendingParams = params
        pendingSeed = seed
        guard isReady else { return }
        var values: [String: Any] = ["seed": seed]
        for (k, v) in params { values[k] = v }
        deliver(["type": "settings", "values": values])
    }

    func sendObstacles(_ obstacles: [IconObstacle], bottomInset: Float) {
        pendingObstacles = obstacles
        pendingBottomInset = bottomInset
        guard isReady else { return }
        let scale = Float(window?.backingScaleFactor ?? 2.0)
        let iconsArr: [[String: Any]] = obstacles.map {
            [
                "x": Int(($0.x * scale).rounded()),
                "y": Int(($0.y * scale).rounded()),
                "w": Int(($0.w * scale).rounded()),
                "h": Int(($0.h * scale).rounded())
            ]
        }
        deliver([
            "type": "icons",
            "w": Int((Float(bounds.width) * scale).rounded()),
            "h": Int((Float(bounds.height) * scale).rounded()),
            "taskbar": Int((bottomInset * scale).rounded()),
            "icons": iconsArr
        ])
    }

    func sendPaused(_ paused: Bool) {
        pendingPaused = paused
        guard isReady else { return }
        deliver(["type": "pause", "paused": paused])
    }

    private func deliver(_ dict: [String: Any]) {
        guard let webView,
              let jsonData = try? JSONSerialization.data(withJSONObject: dict),
              let jsonStr = String(data: jsonData, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.__dlDeliver && window.__dlDeliver(\(jsonStr));", completionHandler: nil)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let bodyStr = message.body as? String,
              let data = bodyStr.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }
        if type == "ready" {
            isReady = true
            sendSettings(params: pendingParams, seed: pendingSeed)
            sendObstacles(pendingObstacles, bottomInset: pendingBottomInset)
            sendPaused(pendingPaused)
        }
    }
}
