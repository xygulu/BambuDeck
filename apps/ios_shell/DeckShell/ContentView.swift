import SwiftUI

/// 与网页控制台同一套配色（assets/web/hub_page.html 的 :root）。
enum Palette {
    static let bg = Color(red: 0x0f / 255, green: 0x11 / 255, blue: 0x15 / 255)
    static let surface = Color(red: 0x17 / 255, green: 0x1a / 255, blue: 0x21 / 255)
    static let line = Color(red: 0x26 / 255, green: 0x2b / 255, blue: 0x36 / 255)
    static let text = Color(red: 0xe7 / 255, green: 0xea / 255, blue: 0xf0 / 255)
    static let dim = Color(red: 0x8b / 255, green: 0x93 / 255, blue: 0xa3 / 255)
    static let accent = Color(red: 0x2f / 255, green: 0x81 / 255, blue: 0xf7 / 255)
    static let err = Color(red: 0xf8 / 255, green: 0x51 / 255, blue: 0x49 / 255)
}

struct ContentView: View {
    /// 局域网 / 外网自动选路；选中的线路变了，下面的 WebView 会换 URL 重载。
    @StateObject private var router = ServerRouter()
    @State private var failure: String?
    @State private var reload = 0
    @State private var editing = false
    @Environment(\.scenePhase) private var phase

    var body: some View {
        Group {
            if let cfg = router.config, cfg.isConfigured, let base = router.base {
                console(cfg, base)
            } else {
                SetupView(initial: router.config, isSheet: false) { cfg in
                    failure = nil
                    reload += 1
                    router.save(cfg)
                }
            }
        }
        .preferredColorScheme(.dark)
        // 冷启动先用上次走通的线路打开；这次探测完如果该换线路，会自动重载。
        .task { router.resolve() }
        // 从后台回来可能已经换了 Wi-Fi（地铁到家、公司到路上）。
        .onChange(of: phase) { next in
            if next == .active { router.resolve() }
        }
    }

    private func console(_ cfg: ServerConfig, _ base: String) -> some View {
        ZStack(alignment: .bottomTrailing) {
            page(cfg, base)
            // 选路那 2 秒里别闪错误页。
            if let text = failure, !router.resolving {
                FailureView(message: text,
                            host: ServerConfig.hostLabel(base),
                            routeLine: routeLine,
                            onRetry: retry,
                            onEdit: { editing = true })
            }
            serverCapsule(cfg, base)
        }
        .background(Palette.bg)
    }

    @ViewBuilder
    private func page(_ cfg: ServerConfig, _ base: String) -> some View {
        if let url = cfg.consoleURL(base: base) {
            WebView(url: url,
                    reloadSignal: reload,
                    onFailure: { msg in
                        failure = msg
                        // 可能只是离开了家里的 Wi-Fi：让 router 试另一条线路。
                        router.notePageFailure()
                    },
                    onLoaded: { failure = nil })
                .ignoresSafeArea(edges: .bottom)
        }
    }

    private func retry() {
        failure = nil
        reload += 1
        router.resolve()
    }

    /// 右下角胶囊 = 当前线路 + 地址，点开改地址/令牌。
    private func serverCapsule(_ cfg: ServerConfig, _ base: String) -> some View {
        let route = router.route
        return Button {
            editing = true
        } label: {
            HStack(spacing: 5) {
                Image(systemName: route?.symbol ?? "gearshape.fill")
                    .font(.system(size: 10, weight: .semibold))
                Text(route?.title ?? "服务器")
                    .font(.system(size: 11, weight: .medium))
                Text(ServerConfig.displayAddress(base))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 12)
            .frame(height: 34)
            .frame(maxWidth: 240)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
        }
        .opacity(0.8)
        .accessibilityLabel("服务器：\(route?.title ?? "") \(ServerConfig.displayAddress(base))")
        .accessibilityHint("修改局域网和外网地址、访问令牌")
        .padding(.trailing, 14)
        .padding(.bottom, 24)
        .sheet(isPresented: $editing) {
            SetupView(initial: cfg, isSheet: true) { next in
                failure = nil
                reload += 1
                router.save(next)
            } onClear: {
                failure = nil
                router.clear()
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
    }

    private var routeLine: String {
        if router.reachable {
            return "当前线路：\(router.route?.title ?? "—")"
        }
        let n = router.config?.configuredRoutes.count ?? 0
        return n > 1 ? "局域网和外网地址都不通" : "配置的地址连不上"
    }
}

/// 连不上时的兜底：说清楚哪儿不对，并给两条出路。
struct FailureView: View {
    let message: String
    let host: String
    let routeLine: String
    let onRetry: () -> Void
    let onEdit: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Palette.err)
            Text("连不上 \(host)")
                .font(.headline)
                .foregroundStyle(Palette.text)
            Text(message)
                .font(.footnote)
                .foregroundStyle(Palette.dim)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text(routeLine)
                .font(.caption2)
                .foregroundStyle(Palette.dim.opacity(0.85))
            HStack(spacing: 10) {
                Button("重试", action: onRetry)
                    .buttonStyle(.borderedProminent)
                    .tint(Palette.accent)
                Button("改地址", action: onEdit)
                    .buttonStyle(.bordered)
                    .tint(Palette.dim)
            }
            .font(.subheadline.weight(.semibold))
        }
        .padding(20)
        .frame(maxWidth: 320)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Palette.line, lineWidth: 1))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.bg.opacity(0.96))
    }
}

/// 两条地址 + 令牌。首次启动和「改地址」共用。
struct SetupView: View {
    let initial: ServerConfig?
    let isSheet: Bool
    let onConnect: (ServerConfig) -> Void
    var onClear: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var lan: String
    @State private var remote: String
    @State private var token: String
    @State private var busy = false
    @State private var note: Note?

    private struct Note {
        let ok: Bool
        let text: String
    }

    init(initial: ServerConfig?, isSheet: Bool,
         onConnect: @escaping (ServerConfig) -> Void,
         onClear: (() -> Void)? = nil) {
        self.initial = initial
        self.isSheet = isSheet
        self.onConnect = onConnect
        self.onClear = onClear
        _lan = State(initialValue: initial?.lan ?? "")
        _remote = State(initialValue: initial?.remote ?? "")
        _token = State(initialValue: initial?.token ?? "")
    }

    var body: some View {
        ZStack {
            Palette.bg.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    field(title: "局域网地址（和 Mac 同一 Wi-Fi）",
                          hint: "例如 192.168.1.10:8787，可以留空",
                          text: $lan,
                          keyboard: .URL)
                    field(title: "外网地址（不在同一 Wi-Fi）",
                          hint: "例如 deck.example.com:8787 或 https://xxx.trycloudflare.com，可以留空",
                          text: $remote,
                          keyboard: .URL)
                    Text("两个都填：同一 Wi-Fi 自动用局域网，出门自动切外网。只填一个就固定用它。")
                        .font(.caption2)
                        .foregroundStyle(Palette.dim.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                    field(title: "访问令牌",
                          hint: "Mac 的设置 → 网页访问 里复制",
                          text: $token,
                          keyboard: .default)
                    if let note {
                        Label(note.text, systemImage: note.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(note.ok ? Color.green : Palette.err)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    actions
                    tips
                }
                .padding(20)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(isSheet ? "服务器" : "BambuDeck")
                .font(.system(size: isSheet ? 24 : 30, weight: .bold, design: .rounded))
                .foregroundStyle(Palette.text)
            Text(isSheet
                 ? "改完点「保存并重连」。地址和令牌不对会连不上，可以先「测试一下」。"
                 : "这个 App 不自己连打印机。它显示 Mac 上的控制台页面，所有动作都在那台 Mac 上执行。")
                .font(.footnote)
                .foregroundStyle(Palette.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func field(title: String, hint: String, text: Binding<String>,
                       keyboard: UIKeyboardType) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Palette.dim)
            TextField("", text: text)
                .keyboardType(keyboard)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(Palette.text)
                .padding(.horizontal, 12)
                .padding(.vertical, 11)
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.line, lineWidth: 1))
            Text(hint)
                .font(.caption2)
                .foregroundStyle(Palette.dim.opacity(0.8))
        }
    }

    private var actions: some View {
        VStack(spacing: 10) {
            Button {
                connect()
            } label: {
                Text(isSheet ? "保存并重连" : "连接")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .tint(Palette.accent)
            .disabled(draft.isConfigured == false)

            Button {
                test()
            } label: {
                HStack(spacing: 6) {
                    if busy { ProgressView().controlSize(.small) }
                    Text(busy ? "正在连接…" : "先测试一下")
                }
                .font(.footnote.weight(.medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            }
            .buttonStyle(.bordered)
            .tint(Palette.dim)
            .disabled(busy || draft.isConfigured == false)

            if isSheet {
                HStack {
                    Button("取消") { dismiss() }
                        .font(.footnote)
                        .foregroundStyle(Palette.dim)
                    Spacer()
                    if onClear != nil {
                        Button("清除服务器", role: .destructive) {
                            onClear?()
                            dismiss()
                        }
                        .font(.footnote)
                    }
                }
                .padding(.top, 4)
            }
        }
    }

    private var tips: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("连不上时先看这三处")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Palette.dim)
            bullet("Mac 上的 BambuDeck 开着，设置里的「网页访问」是打开的")
            bullet("手机和 Mac 在同一个 Wi-Fi，Mac 的 IP 没变（不在同一个时应该切到外网地址）")
            bullet("iPhone 设置 → 隐私与安全性 → 本地网络 里允许了 BambuDeck")
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surface.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("·").foregroundStyle(Palette.dim)
            Text(text)
                .font(.caption)
                .foregroundStyle(Palette.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var draft: ServerConfig {
        ServerConfig(lan: lan, remote: remote, token: token)
    }

    private func connect() {
        let cfg = draft
        guard cfg.isConfigured else {
            note = Note(ok: false, text: "至少填一个地址，像这样：192.168.1.10:8787")
            return
        }
        cfg.save()
        onConnect(cfg)
        if isSheet { dismiss() }
    }

    /// 两条线路都读一次 /api/state：200 说明地址和令牌都对，401 说明令牌错。
    private func test() {
        let cfg = draft
        let routes = cfg.configuredRoutes
        guard !routes.isEmpty else {
            note = Note(ok: false, text: "至少填一个地址，像这样：192.168.1.10:8787")
            return
        }
        busy = true
        note = nil
        Task {
            var lines: [(ServerRoute, Bool, String)] = []
            await withTaskGroup(of: (ServerRoute, Bool, String).self) { group in
                for r in routes {
                    group.addTask { await Self.probe(cfg, r) }
                }
                for await item in group { lines.append(item) }
            }
            lines.sort {
                (ServerRoute.allCases.firstIndex(of: $0.0) ?? 0)
                    < (ServerRoute.allCases.firstIndex(of: $1.0) ?? 0)
            }
            let text = lines.map { item in
                let addr = cfg.base(item.0).map(ServerConfig.displayAddress) ?? "—"
                return "\(item.0.title) \(addr)：\(item.2)"
            }.joined(separator: "\n")
            let result = Note(ok: lines.contains { $0.1 }, text: text)
            await MainActor.run {
                busy = false
                note = result
            }
        }
    }

    private static func probe(_ cfg: ServerConfig, _ route: ServerRoute)
        async -> (ServerRoute, Bool, String) {
        guard let b = cfg.base(route), let url = cfg.stateURL(base: b) else {
            return (route, false, "没填地址")
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 6
        req.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 401 {
                return (route, false, "令牌不对（401）")
            }
            if code == 200,
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let list = obj["printers"] as? [Any] {
                return (route, true, "通了，读到 \(list.count) 台打印机")
            }
            return (route, false, "HTTP \(code)，地址对了但这不像 BambuDeck")
        } catch {
            return (route, false, "连不上：\(error.localizedDescription)")
        }
    }
}
