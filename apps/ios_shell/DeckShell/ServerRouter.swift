import Foundation
import Network

/// 局域网 / 外网两条线路的自动选路。
///
/// 启动、换网络、回前台、页面加载失败时都会重选一次：两条线路并行探测
/// （`/api/state` 只要有 HTTP 响应就算通，401 说明地址通、令牌错），
/// 局域网优先。选中的线路变了，ContentView 里的 WebView 会换 URL 重载。
///
/// 探测失败不清掉线路——保留上一次的，让页面给出具体的网络报错，
/// 而不是把用户踢回设置页。
@MainActor
final class ServerRouter: ObservableObject {
    @Published private(set) var config: ServerConfig?
    /// 当前线路；两条都不通时保留上一次。
    @Published private(set) var route: ServerRoute?
    /// 当前线路的地址（已补协议、去掉尾斜杠）。
    @Published private(set) var base: String?
    @Published private(set) var resolving = false
    /// 最近一次探测有没有任何线路通。给失败页说清楚是哪种不通。
    @Published private(set) var reachable = true

    private let monitor = NWPathMonitor()
    private var probe: Task<Void, Never>?
    private var generation = 0
    private var onWifi = true
    private var sawFirstPath = false
    private var lastStatus: NWPath.Status?

    init() {
        config = ServerConfig.load()
        if let cfg = config {
            let remembered = ServerConfig.rememberedRoute()
                .flatMap { cfg.base($0) == nil ? nil : $0 }
            let initial = remembered ?? cfg.configuredRoutes.first
            route = initial
            base = initial.flatMap { cfg.base($0) }
        }
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                self?.pathChanged(path)
            }
        }
        monitor.start(queue: DispatchQueue(label: "deck.network"))
    }

    deinit {
        monitor.cancel()
    }

    // MARK: - 对外

    /// 保存设置后调用：地址可能整个换掉，重新选路。
    func save(_ cfg: ServerConfig) {
        cfg.save()
        config = cfg
        if route.flatMap({ cfg.base($0) == nil }) ?? true {
            route = cfg.configuredRoutes.first
        }
        base = route.flatMap { cfg.base($0) }
        resolve()
    }

    func clear() {
        ServerConfig.clear()
        config = nil
        route = nil
        base = nil
        reachable = true
        resolving = false
        probe?.cancel()
        generation += 1
    }

    /// 重新探测。已经在探测就作废旧的，以最新一次为准。
    func resolve() {
        guard let cfg = config, cfg.isConfigured else { return }
        generation += 1
        let gen = generation
        let routes = cfg.configuredRoutes
        // 蜂窝网络下局域网地址没意义，别白等 2 秒探测超时。
        let candidates = onWifi ? routes : routes.filter { $0 == .remote }
        probe?.cancel()
        resolving = true
        probe = Task { [weak self] in
            var hits: [ServerRoute: Bool] = [:]
            await withTaskGroup(of: (ServerRoute, Bool).self) { group in
                for r in candidates {
                    guard let b = cfg.base(r), let url = cfg.stateURL(base: b) else { continue }
                    group.addTask { (r, await Self.reachable(url)) }
                }
                for await (r, ok) in group { hits[r] = ok }
            }
            guard let self, !Task.isCancelled, self.generation == gen else { return }
            self.finish(hits, routes: routes)
        }
    }

    /// 页面加载失败时叫一声：可能是刚离开家/刚到家，重选一次。
    func notePageFailure() {
        guard !resolving else { return }
        resolve()
    }

    // MARK: - 选路

    private func finish(_ hits: [ServerRoute: Bool], routes: [ServerRoute]) {
        resolving = false
        let winner = routes.first { hits[$0] == true }
        reachable = winner != nil
        guard let cfg = config else { return }
        if let winner {
            if winner != route || base == nil {
                route = winner
                base = cfg.base(winner)
                ServerConfig.remember(winner)
            } else {
                base = cfg.base(winner)
            }
        } else if route == nil {
            route = routes.first
            base = route.flatMap { cfg.base($0) }
        }
    }

    /// 有 HTTP 响应就算通：401 是令牌错，但地址本身是活的。
    private nonisolated static func reachable(_ url: URL) async -> Bool {
        var req = URLRequest(url: url)
        req.timeoutInterval = 2.2
        req.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            return resp is HTTPURLResponse
        } catch {
            return false
        }
    }

    // MARK: - 网络变化

    private func pathChanged(_ path: NWPath) {
        let wifi = path.usesInterfaceType(.wifi)
        let changed = lastStatus != path.status || wifi != onWifi
        onWifi = wifi
        lastStatus = path.status
        // 第一次回调只是初始状态，init 已经按缓存打开页面了。
        guard sawFirstPath else {
            sawFirstPath = true
            return
        }
        if changed { resolve() }
    }
}
