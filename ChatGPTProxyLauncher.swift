import Cocoa

struct ProxyConfig {
    var id: String
    var name: String
    var host: String
    var port: String
    var username: String
    var password: String
    var bridge: Bool
}

struct LauncherConfig {
    var activeProxy: String = "lan"
    var proxies: [ProxyConfig] = []
    var httpBridgeHost: String = "127.0.0.1"
    var httpBridgePort: String = "28083"
    var bypassItems: [String] = []
}

enum AppLanguage: String {
    case english = "en"
    case chinese = "zh"
}

final class ConfigStore {
    let bundleURL: URL
    let resourcesURL: URL
    let supportURL: URL
    let legacyProjectURL: URL
    let configURL: URL
    let exampleConfigURL: URL
    let scriptURL: URL

    init(bundleURL: URL) {
        self.bundleURL = bundleURL
        resourcesURL = bundleURL.appendingPathComponent("Contents/Resources")
        legacyProjectURL = bundleURL.deletingLastPathComponent()
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        supportURL = appSupport.appendingPathComponent("ChatGPT Proxy", isDirectory: true)
        configURL = supportURL.appendingPathComponent("chatgpt-proxy.conf")
        exampleConfigURL = resourcesURL.appendingPathComponent("chatgpt-proxy.conf.example")
        scriptURL = resourcesURL.appendingPathComponent("chatgpt-proxy-launch.sh")
        migrateLegacyConfigIfNeeded()
    }

    private func migrateLegacyConfigIfNeeded() {
        let fm = FileManager.default
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        if !fm.fileExists(atPath: supportURL.path) {
            try? fm.createDirectory(at: supportURL, withIntermediateDirectories: true)
        }
        guard !fm.fileExists(atPath: configURL.path) else { return }

        let oldSupportURLs = [
            appSupport.appendingPathComponent("Codex Proxy", isDirectory: true).appendingPathComponent("codex-proxy.conf"),
            appSupport.appendingPathComponent("Codex Proxy Launcher", isDirectory: true).appendingPathComponent("codex-proxy.conf")
        ]
        for oldSupportConfigURL in oldSupportURLs where fm.fileExists(atPath: oldSupportConfigURL.path) {
            try? fm.copyItem(at: oldSupportConfigURL, to: configURL)
            return
        }

        let legacyConfigURL = legacyProjectURL.appendingPathComponent("chatgpt-proxy.conf")
        if fm.fileExists(atPath: legacyConfigURL.path) {
            try? fm.copyItem(at: legacyConfigURL, to: configURL)
            return
        }

        if fm.fileExists(atPath: exampleConfigURL.path) {
            try? fm.copyItem(at: exampleConfigURL, to: configURL)
        }
    }

    func load() -> LauncherConfig {
        guard let text = try? String(contentsOf: configURL, encoding: .utf8) else {
            return defaultConfig()
        }

        var values: [String: String] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            guard let equal = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[..<equal])
            let raw = String(trimmed[trimmed.index(after: equal)...])
            values[key] = raw
        }

        let ids = parseArray(values["PROXY_IDS"] ?? "")
        var proxies: [ProxyConfig] = []
        for id in ids {
            let key = id.uppercased()
            proxies.append(ProxyConfig(
                id: id,
                name: parseScalar(values["PROXY_\(key)_NAME"] ?? "\"\(id)\""),
                host: parseScalar(values["PROXY_\(key)_HOST"] ?? "\"\""),
                port: parseScalar(values["PROXY_\(key)_PORT"] ?? "\"1080\""),
                username: parseScalar(values["PROXY_\(key)_USERNAME"] ?? "\"\""),
                password: parseScalar(values["PROXY_\(key)_PASSWORD"] ?? "\"\""),
                bridge: parseScalar(values["PROXY_\(key)_HTTP_BRIDGE"] ?? "\"0\"") == "1"
            ))
        }

        if proxies.isEmpty {
            proxies = defaultConfig().proxies
        }

        let bypass = parseArray(values["BYPASS_ITEMS"] ?? "")
        let active = parseScalar(values["ACTIVE_PROXY"] ?? "\"\(proxies[0].id)\"")

        return LauncherConfig(
            activeProxy: proxies.contains(where: { $0.id == active }) ? active : proxies[0].id,
            proxies: proxies,
            httpBridgeHost: parseScalar(values["HTTP_BRIDGE_HOST"] ?? "\"127.0.0.1\""),
            httpBridgePort: parseScalar(values["HTTP_BRIDGE_PORT"] ?? "\"28083\""),
            bypassItems: bypass.isEmpty ? defaultBypassItems() : bypass
        )
    }

    func save(_ config: LauncherConfig) throws {
        let proxyIDs = config.proxies.map(\.id).joined(separator: " ")
        var lines: [String] = []
        lines.append("# Active proxy id. Edit through ChatGPT Proxy, or update this file manually.")
        lines.append("ACTIVE_PROXY=\(quote(config.activeProxy))")
        lines.append("")
        lines.append("# Configured SOCKS5 proxies.")
        lines.append("PROXY_IDS=(\(proxyIDs))")
        for proxy in config.proxies {
            let key = proxy.id.uppercased()
            lines.append("PROXY_\(key)_NAME=\(quote(proxy.name))")
            lines.append("PROXY_\(key)_HOST=\(quote(proxy.host))")
            lines.append("PROXY_\(key)_PORT=\(quote(proxy.port))")
            lines.append("PROXY_\(key)_USERNAME=\(quote(proxy.username))")
            lines.append("PROXY_\(key)_PASSWORD=\(quote(proxy.password))")
            lines.append("PROXY_\(key)_HTTP_BRIDGE=\(quote(proxy.bridge ? "1" : "0"))")
            lines.append("")
        }
        lines.append("# Local HTTP CONNECT bridge used when a proxy enables HTTP bridge mode.")
        lines.append("HTTP_BRIDGE_HOST=\(quote(config.httpBridgeHost))")
        lines.append("HTTP_BRIDGE_PORT=\(quote(config.httpBridgePort))")
        lines.append("")
        lines.append("# Hosts, domains, IPs, or CIDRs that should connect directly.")
        lines.append("# This starts with local/LAN defaults, but every item is editable in the launcher.")
        lines.append("BYPASS_ITEMS=(\(config.bypassItems.map(quote).joined(separator: " ")))")
        try lines.joined(separator: "\n").appending("\n").write(to: configURL, atomically: true, encoding: .utf8)
    }

    func defaultConfig() -> LauncherConfig {
        LauncherConfig(
            activeProxy: "local",
            proxies: [
                ProxyConfig(id: "local", name: "Local SOCKS", host: "127.0.0.1", port: "1080", username: "", password: "", bridge: true),
                ProxyConfig(id: "remote", name: "Remote SOCKS", host: "proxy.example.com", port: "1080", username: "", password: "", bridge: true)
            ],
            bypassItems: defaultBypassItems()
        )
    }

    func defaultBypassItems() -> [String] {
        [
            "localhost", "127.0.0.1", "::1", "*.local", "local",
            "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16",
            "169.254.0.0/16", "fc00::/7", "fe80::/10"
        ]
    }

    func generatedID(for name: String, existing: [ProxyConfig]) -> String {
        let lower = name.lowercased()
        var result = ""
        var previousWasUnderscore = false
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789")
        for scalar in lower.unicodeScalars {
            if allowed.contains(scalar) {
                result.append(String(scalar))
                previousWasUnderscore = false
            } else if !previousWasUnderscore {
                result.append("_")
                previousWasUnderscore = true
            }
        }
        result = result.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        if result.isEmpty { result = "proxy" }
        var candidate = result
        var suffix = 2
        let existingIDs = Set(existing.map(\.id))
        while existingIDs.contains(candidate) {
            candidate = "\(result)_\(suffix)"
            suffix += 1
        }
        return candidate
    }

    private func quote(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private func parseScalar(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("\""), trimmed.hasSuffix("\""), trimmed.count >= 2 {
            let inner = trimmed.dropFirst().dropLast()
            return unescape(String(inner))
        }
        return trimmed
    }

    private func parseArray(_ raw: String) -> [String] {
        var text = raw.trimmingCharacters(in: .whitespaces)
        guard text.hasPrefix("("), text.hasSuffix(")") else { return [] }
        text.removeFirst()
        text.removeLast()

        var items: [String] = []
        var current = ""
        var inQuote = false
        var escaping = false

        for char in text {
            if escaping {
                current.append(char)
                escaping = false
            } else if char == "\\" {
                escaping = true
            } else if char == "\"" {
                inQuote.toggle()
            } else if char.isWhitespace && !inQuote {
                if !current.isEmpty {
                    items.append(current)
                    current = ""
                }
            } else {
                current.append(char)
            }
        }
        if !current.isEmpty { items.append(current) }
        return items
    }

    private func unescape(_ value: String) -> String {
        var result = ""
        var escaping = false
        for char in value {
            if escaping {
                result.append(char)
                escaping = false
            } else if char == "\\" {
                escaping = true
            } else {
                result.append(char)
            }
        }
        return result
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private lazy var store = ConfigStore(bundleURL: Bundle.main.bundleURL)
    private var config = LauncherConfig()
    private var language = AppLanguage(rawValue: UserDefaults.standard.string(forKey: "AppLanguage") ?? "en") ?? .english

    private let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 820, height: 610),
        styleMask: [.titled, .closable, .miniaturizable],
        backing: .buffered,
        defer: false
    )

    private let proxyTable = NSTableView()
    private let bypassTable = NSTableView()
    private let nameField = NSTextField()
    private let hostField = NSTextField()
    private let portField = NSTextField()
    private let usernameField = NSTextField()
    private let passwordField = NSSecureTextField()
    private let authCheck = NSButton(checkboxWithTitle: "Use authentication", target: nil, action: nil)
    private let bridgeCheck = NSButton(checkboxWithTitle: "Use local HTTP bridge", target: nil, action: nil)
    private let bridgeHelpButton = NSButton()
    private let currentLabel = NSTextField(labelWithString: "")
    private let bridgeHostField = NSTextField()
    private let bridgePortField = NSTextField()
    private var editingProxyID: String?
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let languageMenu = NSPopUpButton()
    private let proxyTabItem = NSTabViewItem(identifier: "proxies")
    private let bypassTabItem = NSTabViewItem(identifier: "bypass")
    private let setCurrentButton = NSButton()
    private let proxyDetailsLabel = NSTextField(labelWithString: "")
    private let nameLabel = NSTextField(labelWithString: "")
    private let hostLabel = NSTextField(labelWithString: "")
    private let portLabel = NSTextField(labelWithString: "")
    private let usernameLabel = NSTextField(labelWithString: "")
    private let passwordLabel = NSTextField(labelWithString: "")
    private let bridgeHostLabel = NSTextField(labelWithString: "")
    private let bridgePortLabel = NSTextField(labelWithString: "")
    private let addBypassButton = NSButton()
    private let removeBypassButton = NSButton()
    private let resetBypassButton = NSButton()
    private let cancelButton = NSButton()
    private let saveButton = NSButton()
    private let launchButton = NSButton()
    private let statusLabel = NSTextField(labelWithString: "")
    private var usernameRow: NSGridRow?
    private var passwordRow: NSGridRow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        config = store.load()
        buildWindow()
        reloadAll()
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func tr(_ key: String) -> String {
        let en: [String: String] = [
            "title": "ChatGPT Proxy",
            "subtitle": "Choose a proxy, tune direct-connect bypasses, then launch ChatGPT.",
            "language": "Language",
            "proxies": "Proxies",
            "bypass": "Bypass",
            "setCurrent": "Set Current",
            "proxyDetails": "Proxy Details",
            "name": "Name",
            "socksHost": "SOCKS Host",
            "socksPort": "SOCKS Port",
            "username": "Username",
            "password": "Password",
            "useAuth": "Use authentication",
            "bridgeHost": "Bridge Host",
            "bridgePort": "Bridge Port",
            "useBridge": "Use local HTTP bridge",
            "bridgeHelpTitle": "What is the HTTP bridge?",
            "bridgeHelp": "Some internal clients may not handle SOCKS5 proxy settings reliably. The local HTTP bridge exposes an HTTP CONNECT proxy on 127.0.0.1, then forwards traffic to the selected SOCKS5 proxy.\n\nEnable it if login works but chats, app-server requests, or the plugin marketplace time out or load partially.",
            "add": "Add",
            "remove": "Remove",
            "resetDefaults": "Reset Defaults",
            "cancel": "Cancel",
            "save": "Save",
            "launch": "Launch ChatGPT",
            "current": "Current",
            "none": "None",
            "saved": "Saved.",
            "addBypassTitle": "Add Bypass",
            "addBypassInfo": "Enter a host, domain, wildcard domain, IP, or CIDR.",
            "proxyNameRequired": "Proxy name is required",
            "proxyNameRequiredInfo": "Each proxy needs a name.",
            "proxyNamesUnique": "Proxy names must be unique",
            "proxyNamesUniqueInfo": "Rename the duplicate proxy before launching.",
            "proxyHostRequired": "Proxy host is required",
            "proxyHostRequiredInfo": "%@ needs a SOCKS host.",
            "proxyPortInvalid": "Proxy port is invalid",
            "proxyPortInvalidInfo": "%@ needs a SOCKS port from 1 to 65535.",
            "bridgeHostInvalid": "Bridge host is invalid",
            "bridgeHostInvalidInfo": "Use a loopback host: 127.0.0.1, localhost, or ::1.",
            "bridgePortInvalid": "Bridge port is invalid",
            "bridgePortInvalidInfo": "Use a bridge port from 1 to 65535.",
            "unableLaunch": "Unable to launch ChatGPT",
            "missingScript": "Cannot find executable script:\n%@",
            "alreadyRunningTitle": "ChatGPT is already running",
            "alreadyRunningInfo": "Proxy changes only apply when ChatGPT starts.\n\nQuit the running ChatGPT and relaunch with the selected proxy, or cancel and keep the current session.",
            "quitRelaunch": "Quit and Relaunch",
            "quitFailedTitle": "ChatGPT is still running",
            "quitFailedInfo": "ChatGPT did not quit within a few seconds. Please quit it manually, then launch again."
        ]
        let zh: [String: String] = [
            "title": "ChatGPT Proxy",
            "subtitle": "选择代理、配置直连排除项，然后启动 ChatGPT。",
            "language": "语言",
            "proxies": "代理",
            "bypass": "直连排除",
            "setCurrent": "设为当前",
            "proxyDetails": "代理详情",
            "name": "名称",
            "socksHost": "SOCKS 主机",
            "socksPort": "SOCKS 端口",
            "username": "用户名",
            "password": "密码",
            "useAuth": "需要认证",
            "bridgeHost": "Bridge 主机",
            "bridgePort": "Bridge 端口",
            "useBridge": "启用本地 HTTP bridge",
            "bridgeHelpTitle": "HTTP bridge 是什么？",
            "bridgeHelp": "有些内部 HTTP 客户端对 SOCKS5 代理支持不够稳定。本地 HTTP bridge 会在 127.0.0.1 提供一个 HTTP CONNECT 代理，再转发到你选择的 SOCKS5 代理。\n\n如果登录正常，但对话、app-server 请求或插件市场超时/加载不完整，可以开启它。",
            "add": "添加",
            "remove": "删除",
            "resetDefaults": "恢复默认",
            "cancel": "取消",
            "save": "保存",
            "launch": "启动 ChatGPT",
            "current": "当前",
            "none": "无",
            "saved": "已保存。",
            "addBypassTitle": "添加直连排除",
            "addBypassInfo": "输入主机名、域名、通配域名、IP 或 CIDR。",
            "proxyNameRequired": "代理名称不能为空",
            "proxyNameRequiredInfo": "每个代理都需要一个名称。",
            "proxyNamesUnique": "代理名称不能重复",
            "proxyNamesUniqueInfo": "请先重命名重复的代理。",
            "proxyHostRequired": "代理主机不能为空",
            "proxyHostRequiredInfo": "%@ 需要 SOCKS 主机地址。",
            "proxyPortInvalid": "代理端口无效",
            "proxyPortInvalidInfo": "%@ 需要 1 到 65535 之间的 SOCKS 端口。",
            "bridgeHostInvalid": "Bridge 主机无效",
            "bridgeHostInvalidInfo": "请使用回环主机：127.0.0.1、localhost 或 ::1。",
            "bridgePortInvalid": "Bridge 端口无效",
            "bridgePortInvalidInfo": "请输入 1 到 65535 之间的 Bridge 端口。",
            "unableLaunch": "无法启动 ChatGPT",
            "missingScript": "找不到可执行脚本：\n%@",
            "alreadyRunningTitle": "ChatGPT 已经在运行",
            "alreadyRunningInfo": "代理配置只会在 ChatGPT 启动时生效。\n\n请退出正在运行的 ChatGPT，并用当前代理配置重新启动；或取消并保留当前会话。",
            "quitRelaunch": "退出并重启",
            "quitFailedTitle": "ChatGPT 仍在运行",
            "quitFailedInfo": "ChatGPT 在几秒内没有退出。请手动退出后再启动。"
        ]
        return (language == .english ? en : zh)[key] ?? key
    }

    private func refreshLanguage() {
        window.title = tr("title")
        titleLabel.stringValue = tr("title")
        subtitleLabel.stringValue = tr("subtitle")
        proxyTabItem.label = tr("proxies")
        bypassTabItem.label = tr("bypass")
        setCurrentButton.title = tr("setCurrent")
        proxyDetailsLabel.stringValue = tr("proxyDetails")
        nameLabel.stringValue = tr("name")
        hostLabel.stringValue = tr("socksHost")
        portLabel.stringValue = tr("socksPort")
        usernameLabel.stringValue = tr("username")
        passwordLabel.stringValue = tr("password")
        authCheck.title = tr("useAuth")
        bridgeHostLabel.stringValue = tr("bridgeHost")
        bridgePortLabel.stringValue = tr("bridgePort")
        bridgeCheck.title = tr("useBridge")
        bridgeHelpButton.toolTip = tr("bridgeHelpTitle")
        addBypassButton.title = tr("add")
        removeBypassButton.title = tr("remove")
        resetBypassButton.title = tr("resetDefaults")
        cancelButton.title = tr("cancel")
        saveButton.title = tr("save")
        launchButton.title = tr("launch")
        updateCurrentLabel()
    }

    private func buildWindow() {
        let root = NSStackView()
        root.orientation = .vertical
        root.spacing = 12
        root.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 16, right: 20)
        root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = root

        let titleRow = NSStackView()
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = 12
        titleLabel.font = .systemFont(ofSize: 22, weight: .semibold)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.font = .systemFont(ofSize: 13)
        subtitleLabel.lineBreakMode = .byWordWrapping
        subtitleLabel.maximumNumberOfLines = 2
        languageMenu.addItems(withTitles: ["English", "中文"])
        languageMenu.selectItem(at: language == .english ? 0 : 1)
        languageMenu.target = self
        languageMenu.action = #selector(languageChanged)
        titleRow.addArrangedSubview(titleLabel)
        titleRow.addArrangedSubview(NSView())
        titleRow.addArrangedSubview(languageMenu)
        root.addArrangedSubview(titleRow)
        root.addArrangedSubview(subtitleLabel)

        let tabs = NSTabView()
        tabs.translatesAutoresizingMaskIntoConstraints = false
        proxyTabItem.view = proxyPane()
        bypassTabItem.view = bypassPane()
        tabs.addTabViewItem(proxyTabItem)
        tabs.addTabViewItem(bypassTabItem)
        root.addArrangedSubview(tabs)
        tabs.heightAnchor.constraint(equalToConstant: 460).isActive = true

        let footer = NSStackView()
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 10
        currentLabel.textColor = .secondaryLabelColor
        footer.addArrangedSubview(currentLabel)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 12)
        footer.addArrangedSubview(statusLabel)
        footer.addArrangedSubview(NSView())
        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked)
        saveButton.target = self
        saveButton.action = #selector(saveClicked)
        launchButton.target = self
        launchButton.action = #selector(launchClicked)
        launchButton.bezelStyle = .rounded
        launchButton.keyEquivalent = "\r"
        footer.addArrangedSubview(cancelButton)
        footer.addArrangedSubview(saveButton)
        footer.addArrangedSubview(launchButton)
        root.addArrangedSubview(footer)
        refreshLanguage()
    }

    private func proxyPane() -> NSView {
        let container = NSStackView()
        container.orientation = .horizontal
        container.spacing = 16
        container.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)

        proxyTable.headerView = nil
        proxyTable.delegate = self
        proxyTable.dataSource = self
        proxyTable.usesAlternatingRowBackgroundColors = true
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("proxy"))
        column.width = 290
        proxyTable.addTableColumn(column)
        proxyTable.target = self
        proxyTable.action = #selector(proxySelectionChanged)

        let proxyScroll = NSScrollView()
        proxyScroll.documentView = proxyTable
        proxyScroll.hasVerticalScroller = true
        proxyScroll.borderType = .bezelBorder
        proxyScroll.widthAnchor.constraint(equalToConstant: 310).isActive = true

        let left = NSStackView()
        left.orientation = .vertical
        left.spacing = 10
        left.addArrangedSubview(proxyScroll)
        proxyScroll.heightAnchor.constraint(equalToConstant: 292).isActive = true
        let proxyButtons = NSStackView()
        proxyButtons.orientation = .horizontal
        proxyButtons.spacing = 8
        proxyButtons.addArrangedSubview(NSButton(title: "+", target: self, action: #selector(addProxy)))
        proxyButtons.addArrangedSubview(NSButton(title: "-", target: self, action: #selector(removeProxy)))
        setCurrentButton.target = self
        setCurrentButton.action = #selector(setCurrentProxy)
        proxyButtons.addArrangedSubview(setCurrentButton)
        left.addArrangedSubview(proxyButtons)
        container.addArrangedSubview(left)

        let bridgeRow = NSStackView()
        bridgeRow.orientation = .horizontal
        bridgeRow.alignment = .centerY
        bridgeRow.spacing = 8
        bridgeRow.addArrangedSubview(bridgeCheck)
        bridgeHelpButton.title = "?"
        bridgeHelpButton.bezelStyle = .circular
        bridgeHelpButton.font = .systemFont(ofSize: 11, weight: .medium)
        bridgeHelpButton.setButtonType(.momentaryPushIn)
        bridgeHelpButton.target = self
        bridgeHelpButton.action = #selector(showBridgeHelp)
        bridgeRow.addArrangedSubview(bridgeHelpButton)
        bridgeHelpButton.widthAnchor.constraint(equalToConstant: 18).isActive = true
        bridgeHelpButton.heightAnchor.constraint(equalToConstant: 18).isActive = true
        bridgeRow.addArrangedSubview(NSView())

        let form = NSGridView(views: [
            [nameLabel, nameField],
            [hostLabel, hostField],
            [portLabel, portField],
            [NSView(), authCheck],
            [usernameLabel, usernameField],
            [passwordLabel, passwordField],
            [bridgeHostLabel, bridgeHostField],
            [bridgePortLabel, bridgePortField],
            [NSView(), bridgeRow]
        ])
        usernameRow = form.row(at: 4)
        passwordRow = form.row(at: 5)
        for field in [nameLabel, hostLabel, portLabel, usernameLabel, passwordLabel, bridgeHostLabel, bridgePortLabel] {
            field.textColor = .secondaryLabelColor
        }
        form.column(at: 0).xPlacement = .trailing
        form.column(at: 1).width = 330
        form.rowSpacing = 10
        form.columnSpacing = 10
        for field in [nameField, hostField, portField, usernameField, passwordField, bridgeHostField, bridgePortField] {
            field.target = self
            field.action = #selector(fieldsChanged)
        }
        authCheck.target = self
        authCheck.action = #selector(authToggled)
        bridgeCheck.target = self
        bridgeCheck.action = #selector(fieldsChanged)
        updateAuthRows()

        let right = NSStackView()
        right.orientation = .vertical
        right.spacing = 14
        proxyDetailsLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        right.addArrangedSubview(proxyDetailsLabel)
        right.addArrangedSubview(form)
        right.addArrangedSubview(NSView())
        container.addArrangedSubview(right)
        return container
    }

    private func bypassPane() -> NSView {
        let container = NSStackView()
        container.orientation = .vertical
        container.spacing = 10
        container.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)

        bypassTable.headerView = nil
        bypassTable.delegate = self
        bypassTable.dataSource = self
        bypassTable.usesAlternatingRowBackgroundColors = true
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("bypass"))
        column.width = 720
        bypassTable.addTableColumn(column)

        let scroll = NSScrollView()
        scroll.documentView = bypassTable
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        container.addArrangedSubview(scroll)
        scroll.heightAnchor.constraint(equalToConstant: 292).isActive = true

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 8
        addBypassButton.target = self
        addBypassButton.action = #selector(addBypass)
        removeBypassButton.target = self
        removeBypassButton.action = #selector(removeBypass)
        resetBypassButton.target = self
        resetBypassButton.action = #selector(resetBypass)
        buttons.addArrangedSubview(addBypassButton)
        buttons.addArrangedSubview(removeBypassButton)
        buttons.addArrangedSubview(resetBypassButton)
        buttons.addArrangedSubview(NSView())
        container.addArrangedSubview(buttons)
        return container
    }

    private func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.textColor = .secondaryLabelColor
        return field
    }

    private func reloadAll() {
        proxyTable.reloadData()
        bypassTable.reloadData()
        if let index = config.proxies.firstIndex(where: { $0.id == config.activeProxy }) {
            proxyTable.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        } else if !config.proxies.isEmpty {
            proxyTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        loadSelectedProxy()
        updateCurrentLabel()
    }

    private func updateCurrentLabel() {
        let proxy = config.proxies.first { $0.id == config.activeProxy }
        currentLabel.stringValue = "\(tr("current")): \(proxy?.name ?? tr("none"))"
    }

    private func loadSelectedProxy() {
        let row = proxyTable.selectedRow
        guard row >= 0, row < config.proxies.count else { return }
        let proxy = config.proxies[row]
        editingProxyID = proxy.id
        nameField.stringValue = proxy.name
        hostField.stringValue = proxy.host
        portField.stringValue = proxy.port
        usernameField.stringValue = proxy.username
        passwordField.stringValue = proxy.password
        authCheck.state = (proxy.username.isEmpty && proxy.password.isEmpty) ? .off : .on
        updateAuthRows()
        bridgeCheck.state = proxy.bridge ? .on : .off
        bridgeHostField.stringValue = config.httpBridgeHost
        bridgePortField.stringValue = config.httpBridgePort
    }

    private func saveFieldsToSelectedProxy() {
        if let editingProxyID {
            saveFields(to: editingProxyID)
            return
        }
        let row = proxyTable.selectedRow
        guard row >= 0, row < config.proxies.count else { return }
        saveFields(to: config.proxies[row].id)
    }

    private func saveFields(to proxyID: String) {
        let row = proxyTable.selectedRow
        guard let index = config.proxies.firstIndex(where: { $0.id == proxyID }) else { return }
        config.proxies[index].name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        config.proxies[index].host = hostField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        config.proxies[index].port = portField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if authCheck.state == .on {
            config.proxies[index].username = usernameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            config.proxies[index].password = passwordField.stringValue
        } else {
            config.proxies[index].username = ""
            config.proxies[index].password = ""
        }
        config.proxies[index].bridge = bridgeCheck.state == .on
        config.httpBridgeHost = bridgeHostField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        config.httpBridgePort = bridgePortField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        proxyTable.reloadData()
        if row >= 0 {
            proxyTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        updateCurrentLabel()
    }

    @objc private func proxySelectionChanged() {
        if let editingProxyID {
            saveFields(to: editingProxyID)
        }
        loadSelectedProxy()
    }

    @objc private func languageChanged() {
        language = languageMenu.indexOfSelectedItem == 0 ? .english : .chinese
        UserDefaults.standard.set(language.rawValue, forKey: "AppLanguage")
        refreshLanguage()
    }

    @objc private func showBridgeHelp() {
        let alert = NSAlert()
        alert.messageText = tr("bridgeHelpTitle")
        alert.informativeText = tr("bridgeHelp")
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func updateAuthRows() {
        let visible = authCheck.state == .on
        usernameRow?.isHidden = !visible
        passwordRow?.isHidden = !visible
    }

    @objc private func authToggled() {
        if authCheck.state != .on {
            usernameField.stringValue = ""
            passwordField.stringValue = ""
        }
        updateAuthRows()
        fieldsChanged()
    }

    @objc private func fieldsChanged() {
        saveFieldsToSelectedProxy()
        clearStatus()
    }

    @objc private func addProxy() {
        saveFieldsToSelectedProxy()
        let baseName = uniqueProxyName("New Proxy")
        let id = store.generatedID(for: baseName, existing: config.proxies)
        config.proxies.append(ProxyConfig(id: id, name: baseName, host: "127.0.0.1", port: "1080", username: "", password: "", bridge: true))
        config.activeProxy = id
        reloadAll()
        clearStatus()
    }

    @objc private func removeProxy() {
        let row = proxyTable.selectedRow
        guard row >= 0, row < config.proxies.count, config.proxies.count > 1 else { return }
        let removed = config.proxies.remove(at: row)
        editingProxyID = nil
        if config.activeProxy == removed.id {
            config.activeProxy = config.proxies[0].id
        }
        reloadAll()
        clearStatus()
    }

    @objc private func setCurrentProxy() {
        saveFieldsToSelectedProxy()
        let row = proxyTable.selectedRow
        guard row >= 0, row < config.proxies.count else { return }
        config.activeProxy = config.proxies[row].id
        updateCurrentLabel()
        clearStatus()
    }

    @objc private func addBypass() {
        let alert = NSAlert()
        alert.messageText = tr("addBypassTitle")
        alert.informativeText = tr("addBypassInfo")
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        alert.accessoryView = input
        alert.addButton(withTitle: tr("add"))
        alert.addButton(withTitle: tr("cancel"))
        if alert.runModal() == .alertFirstButtonReturn {
            let value = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                config.bypassItems.append(value)
                bypassTable.reloadData()
                clearStatus()
            }
        }
    }

    @objc private func removeBypass() {
        let row = bypassTable.selectedRow
        guard row >= 0, row < config.bypassItems.count else { return }
        config.bypassItems.remove(at: row)
        bypassTable.reloadData()
        clearStatus()
    }

    @objc private func resetBypass() {
        config.bypassItems = store.defaultBypassItems()
        bypassTable.reloadData()
        clearStatus()
    }

    @objc private func cancelClicked() {
        NSApp.terminate(nil)
    }

    @objc private func saveClicked() {
        saveFieldsToSelectedProxy()
        guard validateConfig() else { return }
        do {
            try store.save(config)
            statusLabel.stringValue = tr("saved")
        } catch {
            showError(tr("unableLaunch"), error.localizedDescription)
        }
    }

    @objc private func launchClicked() {
        saveFieldsToSelectedProxy()
        guard validateConfig() else { return }
        do {
            try store.save(config)
            if !handleRunningChatGPTIfNeeded() {
                return
            }
            try launchChatGPT()
            NSApp.terminate(nil)
        } catch {
            showError(tr("unableLaunch"), error.localizedDescription)
        }
    }

    private func clearStatus() {
        statusLabel.stringValue = ""
    }

    private func runningChatGPTApps() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { app in
            if app.processIdentifier == ProcessInfo.processInfo.processIdentifier {
                return false
            }
            if app.bundleURL?.lastPathComponent == "ChatGPT.app" {
                return true
            }
            return app.localizedName == "ChatGPT"
        }
    }

    private func handleRunningChatGPTIfNeeded() -> Bool {
        let runningApps = runningChatGPTApps()
        if runningApps.isEmpty { return true }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = tr("alreadyRunningTitle")
        alert.informativeText = tr("alreadyRunningInfo")
        alert.addButton(withTitle: tr("quitRelaunch"))
        alert.addButton(withTitle: tr("cancel"))

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            for app in runningApps {
                app.terminate()
            }
            let deadline = Date().addingTimeInterval(6)
            while Date() < deadline {
                if runningChatGPTApps().isEmpty {
                    return true
                }
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.2))
            }
            showError(tr("quitFailedTitle"), tr("quitFailedInfo"))
            return false
        default:
            return false
        }
    }

    private func launchChatGPT() throws {
        guard FileManager.default.isExecutableFile(atPath: store.scriptURL.path) else {
            throw NSError(domain: "ChatGPTProxyLauncher", code: 1, userInfo: [
                NSLocalizedDescriptionKey: String(format: tr("missingScript"), store.scriptURL.path)
            ])
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [store.scriptURL.path]
        var env = ProcessInfo.processInfo.environment
        env["CHATGPT_PROXY_SKIP_UI"] = "1"
        process.environment = env
        try process.run()
    }

    private func validateConfig() -> Bool {
        let names = config.proxies.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) }
        if names.contains("") {
            showError(tr("proxyNameRequired"), tr("proxyNameRequiredInfo"))
            return false
        }
        if Set(names).count != names.count {
            showError(tr("proxyNamesUnique"), tr("proxyNamesUniqueInfo"))
            return false
        }
        for proxy in config.proxies {
            if proxy.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                showError(tr("proxyHostRequired"), String(format: tr("proxyHostRequiredInfo"), proxy.name))
                return false
            }
            guard let port = Int(proxy.port), (1...65535).contains(port) else {
                showError(tr("proxyPortInvalid"), String(format: tr("proxyPortInvalidInfo"), proxy.name))
                return false
            }
        }
        if config.proxies.contains(where: \.bridge) {
            let bridgeHost = config.httpBridgeHost.trimmingCharacters(in: .whitespacesAndNewlines)
            if !["127.0.0.1", "localhost", "::1"].contains(bridgeHost) {
                showError(tr("bridgeHostInvalid"), tr("bridgeHostInvalidInfo"))
                return false
            }
            guard let bridgePort = Int(config.httpBridgePort), (1...65535).contains(bridgePort) else {
                showError(tr("bridgePortInvalid"), tr("bridgePortInvalidInfo"))
                return false
            }
        }
        return true
    }

    private func uniqueProxyName(_ base: String) -> String {
        let names = Set(config.proxies.map(\.name))
        if !names.contains(base) { return base }
        var index = 2
        while names.contains("\(base) \(index)") {
            index += 1
        }
        return "\(base) \(index)"
    }

    private func showError(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        if tableView == proxyTable { return config.proxies.count }
        return config.bypassItems.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("cell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView ?? NSTableCellView()
        cell.identifier = identifier
        let textField = cell.textField ?? NSTextField(labelWithString: "")
        textField.lineBreakMode = .byTruncatingTail
        textField.translatesAutoresizingMaskIntoConstraints = false
        if cell.textField == nil {
            cell.addSubview(textField)
            cell.textField = textField
            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        }

        if tableView == proxyTable {
            let proxy = config.proxies[row]
            let marker = proxy.id == config.activeProxy ? "● " : "  "
            let bridge = proxy.bridge ? "bridge" : "socks"
            let auth = proxy.username.isEmpty && proxy.password.isEmpty ? "" : " auth"
            textField.stringValue = "\(marker)\(proxy.name)   \(proxy.host):\(proxy.port)   \(bridge)\(auth)"
        } else {
            textField.stringValue = config.bypassItems[row]
        }
        return cell
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
