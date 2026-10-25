import SwiftUI
import WebKit

/// WKWebView 包装。只负责加载页面并把加载失败报给 SwiftUI。
struct WebView: UIViewRepresentable {
    let url: URL
    /// 自增即重新加载（「重试」按钮用）。
    let reloadSignal: Int
    let onFailure: (String) -> Void
    let onLoaded: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let conf = WKWebViewConfiguration()
        // 摄像头是 MJPEG / 未来的 HLS，别让 WebKit 把播放手势拦了。
        conf.allowsInlineMediaPlayback = true
        conf.mediaTypesRequiringUserActionForPlayback = []
        conf.websiteDataStore = .default()
        let view = WKWebView(frame: .zero, configuration: conf)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = false
        // 页面自己处理安全区（viewport-fit=cover + env(safe-area-inset-*)），
        // 这里别再叠一层，否则底部标签栏会多出一条空白。
        view.scrollView.contentInsetAdjustmentBehavior = .never
        view.isOpaque = false
        view.backgroundColor = UIColor(red: 0x0f / 255, green: 0x11 / 255, blue: 0x15 / 255, alpha: 1)
        context.coordinator.lastReload = reloadSignal
        context.coordinator.lastURL = url
        view.load(URLRequest(url: url))
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.parent = self
        // 换服务器（地址或令牌变了）和点「重试」都要重新导航。
        let reload = context.coordinator.lastReload != reloadSignal
        let moved = context.coordinator.lastURL != url
        guard reload || moved else { return }
        context.coordinator.lastReload = reloadSignal
        context.coordinator.lastURL = url
        view.load(URLRequest(url: url))
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var parent: WebView
        var lastReload = 0
        var lastURL: URL?

        init(_ parent: WebView) {
            self.parent = parent
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.onLoaded()
        }

        func webView(_ webView: WKWebView,
                     didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) {
            report(error)
        }

        func webView(_ webView: WKWebView,
                     didFail navigation: WKNavigation!,
                     withError error: Error) {
            report(error)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            // 内存吃紧被系统回收：直接重载，页面状态由服务端推送重建。
            webView.reload()
        }

        private func report(_ error: Error) {
            let e = error as NSError
            // -999 是 WebKit 自己取消的导航（页面换地址），不是故障。
            if e.code == NSURLErrorCancelled { return }
            parent.onFailure(friendly(e))
        }

        private func friendly(_ e: NSError) -> String {
            switch e.code {
            case NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost:
                return "连不上这台 Mac。确认 Mac 上的 BambuDeck 正在运行、网页访问已打开，且手机和 Mac 在同一个 Wi-Fi。"
            case NSURLErrorTimedOut:
                return "连接超时。检查 Mac 的局域网地址有没有变（DHCP 可能换 IP）。"
            case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost:
                return "网络中断了。手机没连上 Wi-Fi？"
            case NSURLErrorAppTransportSecurityRequiresSecureConnection:
                return "系统拦了明文连接。请用 http:// 加局域网 IP。"
            default:
                return e.localizedDescription
            }
        }

        // MARK: - JS 弹窗
        //
        // 网页的「停止」「换盘」用 confirm() 做二次确认。WKWebView 不实现这三个
        // delegate 时 alert/confirm/prompt 直接返回（confirm 恒为 false），按钮
        // 看起来像点了没反应。

        func webView(_ webView: WKWebView,
                     runJavaScriptConfirmPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo,
                     completionHandler: @escaping (Bool) -> Void) {
            let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in
                completionHandler(false)
            })
            alert.addAction(UIAlertAction(title: "确定", style: .destructive) { _ in
                completionHandler(true)
            })
            present(alert, from: webView)
        }

        func webView(_ webView: WKWebView,
                     runJavaScriptAlertPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo,
                     completionHandler: @escaping () -> Void) {
            let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "好", style: .default) { _ in
                completionHandler()
            })
            present(alert, from: webView)
        }

        func webView(_ webView: WKWebView,
                     runJavaScriptTextInputPanelWithPrompt prompt: String,
                     defaultText: String?,
                     initiatedByFrame frame: WKFrameInfo,
                     completionHandler: @escaping (String?) -> Void) {
            let alert = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
            alert.addTextField { $0.text = defaultText }
            alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in
                completionHandler(nil)
            })
            alert.addAction(UIAlertAction(title: "好", style: .default) { _ in
                completionHandler(alert.textFields?.first?.text)
            })
            present(alert, from: webView)
        }

        private func present(_ alert: UIAlertController, from webView: WKWebView) {
            DispatchQueue.main.async {
                var vc = webView.window?.rootViewController
                while let next = vc?.presentedViewController { vc = next }
                vc?.present(alert, animated: true)
            }
        }
    }
}
