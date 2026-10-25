import Foundation

/// 两条线路：和 Mac 在同一个 Wi-Fi 时走局域网地址，否则走外网地址（域名/隧道）。
enum ServerRoute: String, CaseIterable {
    case lan, remote

    var title: String { self == .lan ? "局域网" : "外网" }
    var symbol: String { self == .lan ? "wifi" : "globe" }
}

/// Mac 端服务的地址与令牌，存 UserDefaults（不敏感，令牌只是局域网访问码）。
///
/// 两套地址都留着：同一 Wi-Fi 时局域网更快，出门在外自动换外网。
/// 选哪条由 `ServerRouter` 在运行时探测决定，这里只管存和拼 URL。
struct ServerConfig: Codable, Equatable {
    var lan: String
    var remote: String
    var token: String

    init(lan: String = "", remote: String = "", token: String = "") {
        self.lan = lan
        self.remote = remote
        self.token = token
    }

    private static let storageKey = "deck.server"
    private static let routeKey = "deck.server.route"

    private enum CodingKeys: String, CodingKey { case lan, remote, token }
    private enum LegacyKeys: String, CodingKey { case base, token }

    /// 1.0 只存了一个 `base`：当成局域网地址，用户再补外网地址。
    init(from decoder: Decoder) throws {
        let legacy = try decoder.container(keyedBy: LegacyKeys.self)
        let modern = try decoder.container(keyedBy: CodingKeys.self)
        token = try modern.decodeIfPresent(String.self, forKey: .token)
            ?? legacy.decodeIfPresent(String.self, forKey: .token) ?? ""
        if modern.contains(.lan) || modern.contains(.remote) {
            lan = try modern.decodeIfPresent(String.self, forKey: .lan) ?? ""
            remote = try modern.decodeIfPresent(String.self, forKey: .remote) ?? ""
        } else {
            lan = try legacy.decodeIfPresent(String.self, forKey: .base) ?? ""
            remote = ""
        }
    }

    // MARK: - 地址

    /// 用户可能只输 `192.168.1.10:8787`：补协议、去掉尾部斜杠。
    static func normalize(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        if !s.isEmpty, !s.contains("://") { s = "http://" + s }
        return s
    }

    func normalized(_ route: ServerRoute) -> String {
        Self.normalize(route == .lan ? lan : remote)
    }

    /// 这条线路填了地址才参与选路。
    func base(_ route: ServerRoute) -> String? {
        let b = normalized(route)
        return b.isEmpty ? nil : b
    }

    /// 局域网在前：两条都通时优先局域网。
    var configuredRoutes: [ServerRoute] { ServerRoute.allCases.filter { base($0) != nil } }

    var isConfigured: Bool { !configuredRoutes.isEmpty }

    /// 去掉协议和尾部斜杠（`192.168.1.10:8787`），底部胶囊上显示。
    static func displayAddress(_ base: String) -> String {
        let b = normalize(base)
        if let r = b.range(of: "://") { return String(b[r.upperBound...]) }
        return b
    }

    static func hostLabel(_ base: String) -> String {
        URL(string: normalize(base))?.host ?? displayAddress(base)
    }

    // MARK: - URL

    /// 网页地址。令牌用 query 参数交一次手，页面存进 localStorage 后自己从
    /// 地址栏抹掉（hub_page.html 的 gate 逻辑）；每次启动重新交一次，用户
    /// 不用重新输入。
    func consoleURL(base: String) -> URL? { url(base: base, path: "/") }

    /// 选路探测和设置页「测试连接」用：能读到状态就说明地址 + 令牌都对。
    func stateURL(base: String) -> URL? { url(base: base, path: "/api/state") }

    func url(base: String, path: String) -> URL? {
        let b = Self.normalize(base)
        guard !b.isEmpty, var c = URLComponents(string: b + path) else { return nil }
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { c.queryItems = [URLQueryItem(name: "token", value: t)] }
        return c.url
    }

    // MARK: - 持久化

    /// 上一次走通的线路：冷启动先用它打开，探测完再纠正，省掉 2 秒白屏。
    static func rememberedRoute() -> ServerRoute? {
        UserDefaults.standard.string(forKey: routeKey).flatMap(ServerRoute.init(rawValue:))
    }

    static func remember(_ route: ServerRoute) {
        UserDefaults.standard.set(route.rawValue, forKey: routeKey)
    }

    static func load() -> ServerConfig? {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return nil }
        return try? JSONDecoder().decode(ServerConfig.self, from: data)
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: storageKey)
        UserDefaults.standard.removeObject(forKey: routeKey)
    }
}
