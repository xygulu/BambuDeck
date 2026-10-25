import AVFoundation
import SwiftUI

/// iOS 壳：整个 App 就是一个 WKWebView，显示 Mac 上 BambuDeck 的网页控制台。
///
/// 业务逻辑一行都不在这里。打印机状态、摄像头 MJPEG、暂停/继续/停止、换盘，
/// 全部由网页发 HTTP/WebSocket 给 Mac 上的 app；Bambu Connect 的界面自动化
/// 也仍然在 Mac 上执行。壳只做四件事：
///   1. 记住 Mac 的地址和访问令牌；
///   2. 全屏显示页面；
///   3. 补上 WKWebView 不实现就会失效的 JS 弹窗（confirm 二次确认）；
///   4. 连不上时给一个能改地址的界面。
@main
struct DeckShellApp: App {
    init() {
        // 页面里摄像头的 `<audio>` 走这个音频会话。默认的 ambient 分类
        // 会被手机侧面的静音开关静掉 —— 手机上「一直没声音」有一半是它。
        // playback 分类不受静音开关影响, mixWithOthers 让它和别的 App
        // (音乐、播客) 共存, 不会一开监控就把人家的声音打断。
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? session.setActive(true)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
