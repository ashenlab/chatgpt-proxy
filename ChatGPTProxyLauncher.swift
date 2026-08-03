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
    var chatGPTAppPath: String = "/Applications/ChatGPT.app"
    var proxies: [ProxyConfig] = []
    var httpBridgeHost: String = "127.0.0.1"
    var httpBridgePort: String = "28083"
    var bypassItems: [String] = []
}

struct ManagedSessionSnapshot {
    let chatGPTAppPath: String
    let proxyName: String
    let proxyHost: String
    let proxyPort: String
    let authenticationEnabled: Bool
    let bridgeEnabled: Bool
    let bridgeHost: String
    let bridgePort: String
    let bypassItems: [String]
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
    let sessionStateURL: URL

    init(bundleURL: URL) {
        self.bundleURL = bundleURL
        resourcesURL = bundleURL.appendingPathComponent("Contents/Resources")
        legacyProjectURL = bundleURL.deletingLastPathComponent()
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        supportURL = appSupport.appendingPathComponent("ChatGPT Proxy", isDirectory: true)
        configURL = supportURL.appendingPathComponent("chatgpt-proxy.conf")
        exampleConfigURL = resourcesURL.appendingPathComponent("chatgpt-proxy.conf.example")
        scriptURL = resourcesURL.appendingPathComponent("chatgpt-proxy-launch.sh")
        sessionStateURL = supportURL.appendingPathComponent("managed-session.state")
        migrateLegacyConfigIfNeeded()
        secureStoredFiles()
    }

    private func migrateLegacyConfigIfNeeded() {
        let fm = FileManager.default
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        if !fm.fileExists(atPath: supportURL.path) {
            try? fm.createDirectory(
                at: supportURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
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

    private func secureStoredFiles() {
        let fm = FileManager.default
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: supportURL.path)
        for url in [configURL, sessionStateURL, supportURL.appendingPathComponent("chatgpt-proxy-debug.log")] {
            if fm.fileExists(atPath: url.path) {
                try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
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
            chatGPTAppPath: parseScalar(values["CHATGPT_APP_PATH"] ?? "\"/Applications/ChatGPT.app\""),
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
        lines.append("# ChatGPT application bundle. Paths containing spaces are supported.")
        lines.append("CHATGPT_APP_PATH=\(quote(config.chatGPTAppPath))")
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
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
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
            .replacingOccurrences(of: "$", with: "\\$")
            .replacingOccurrences(of: "`", with: "\\`")
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

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
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
    private let versionLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let languageMenu = NSPopUpButton()
    private let applicationMenuItem = NSMenuItem()
    private let quitApplicationMenuItem = NSMenuItem()
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
    private let inspectStatusButton = NSButton()
    private let launchButton = NSButton()
    private let statusLabel = NSTextField(labelWithString: "")
    private var usernameRow: NSGridRow?
    private var passwordRow: NSGridRow?
    private var launchProcess: Process?
    private var managedSessionSnapshot: ManagedSessionSnapshot?
    private var suppressTerminationForRelaunch = false
    private var terminationRequested = false
    private var automaticTerminationDisabled = false
    private var statusWindow: NSWindow?
    private var statusReport = ""
    private let automaticTerminationReason = "Managing the active ChatGPT proxy session"

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        config = store.load()
        buildMainMenu()
        buildWindow()
        reloadAll()
        window.center()
        showConfigurationWindow(reloadConfiguration: false)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        launchProcess == nil
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        dismissStatusWindow()
        guard launchProcess?.isRunning == true else {
            enableAutomaticTerminationIfNeeded()
            return .terminateNow
        }
        guard !terminationRequested else {
            return .terminateLater
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = tr("quitProxyTitle")
        alert.informativeText = tr("quitProxyInfo")
        alert.addButton(withTitle: tr("quitBoth"))
        alert.addButton(withTitle: tr("cancel"))
        alert.window.level = .modalPanel
        alert.window.collectionBehavior.insert(.moveToActiveSpace)
        NSApp.activate(ignoringOtherApps: true)
        if let screen = NSScreen.main {
            let visibleFrame = screen.visibleFrame
            let alertSize = alert.window.frame.size
            alert.window.setFrameOrigin(NSPoint(
                x: visibleFrame.midX - alertSize.width / 2,
                y: visibleFrame.midY - alertSize.height / 2
            ))
        } else {
            alert.window.center()
        }
        alert.window.makeKeyAndOrderFront(nil)
        alert.window.orderFrontRegardless()
        guard alert.runModal() == .alertFirstButtonReturn else {
            return .terminateCancel
        }

        terminationRequested = true
        suppressTerminationForRelaunch = false
        for app in runningChatGPTApps() {
            app.terminate()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self, self.terminationRequested, self.launchProcess?.isRunning == true else {
                return
            }
            self.terminationRequested = false
            NSApp.reply(toApplicationShouldTerminate: false)
            self.showError(self.tr("quitFailedTitle"), self.tr("quitFailedInfo"))
        }
        return .terminateLater
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        if !window.isVisible {
            showConfigurationWindow()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showConfigurationWindow()
        return true
    }

    private func showConfigurationWindow(reloadConfiguration: Bool = true) {
        if reloadConfiguration {
            config = store.load()
            reloadAll()
        }
        launchButton.isEnabled = launchProcess == nil || !runningChatGPTApps().isEmpty
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
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
            "quitFailedInfo": "ChatGPT did not quit within a few seconds. Please quit it manually, then launch again.",
            "cleanupFailed": "The previous proxy session is still cleaning up. Wait a moment, then try again.",
            "quitProxyTitle": "Quit ChatGPT Proxy?",
            "quitProxyInfo": "ChatGPT is currently running through ChatGPT Proxy. Quitting will also close ChatGPT and stop this proxy session.",
            "quitBoth": "Quit Both",
            "quitApplication": "Quit ChatGPT Proxy",
            "inspectStatus": "Current Status",
            "statusTitle": "ChatGPT Proxy Status",
            "close": "Close",
            "copy": "Copy"
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
            "quitFailedInfo": "ChatGPT 在几秒内没有退出。请手动退出后再启动。",
            "cleanupFailed": "上一次代理会话仍在清理中。请稍候片刻再重试。",
            "quitProxyTitle": "退出 ChatGPT Proxy？",
            "quitProxyInfo": "ChatGPT 当前正通过 ChatGPT Proxy 运行。继续退出将同时关闭 ChatGPT，并结束本次代理会话。",
            "quitBoth": "同时退出",
            "quitApplication": "退出 ChatGPT Proxy",
            "inspectStatus": "当前状态",
            "statusTitle": "ChatGPT Proxy 当前状态",
            "close": "关闭",
            "copy": "复制"
        ]
        return (language == .english ? en : zh)[key] ?? key
    }

    private func refreshLanguage() {
        window.title = tr("title")
        applicationMenuItem.title = tr("title")
        applicationMenuItem.submenu?.title = tr("title")
        quitApplicationMenuItem.title = tr("quitApplication")
        titleLabel.stringValue = tr("title")
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        versionLabel.stringValue = version.map { "v\($0)" } ?? ""
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
        inspectStatusButton.title = tr("inspectStatus")
        launchButton.title = tr("launch")
        updateCurrentLabel()
    }

    private func buildMainMenu() {
        let mainMenu = NSMenu()
        let applicationMenu = NSMenu()
        applicationMenuItem.submenu = applicationMenu
        mainMenu.addItem(applicationMenuItem)

        quitApplicationMenuItem.target = NSApp
        quitApplicationMenuItem.action = #selector(NSApplication.terminate(_:))
        quitApplicationMenuItem.keyEquivalent = "q"
        applicationMenu.addItem(quitApplicationMenuItem)
        NSApp.mainMenu = mainMenu
    }

    private func buildWindow() {
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.moveToActiveSpace)

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
        versionLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        versionLabel.textColor = .secondaryLabelColor
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.font = .systemFont(ofSize: 13)
        subtitleLabel.lineBreakMode = .byWordWrapping
        subtitleLabel.maximumNumberOfLines = 2
        languageMenu.addItems(withTitles: ["English", "中文"])
        languageMenu.selectItem(at: language == .english ? 0 : 1)
        languageMenu.target = self
        languageMenu.action = #selector(languageChanged)
        titleRow.addArrangedSubview(titleLabel)
        titleRow.addArrangedSubview(versionLabel)
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
        inspectStatusButton.target = self
        inspectStatusButton.action = #selector(inspectStatusClicked)
        launchButton.target = self
        launchButton.action = #selector(launchClicked)
        launchButton.bezelStyle = .rounded
        launchButton.keyEquivalent = "\r"
        footer.addArrangedSubview(cancelButton)
        footer.addArrangedSubview(saveButton)
        footer.addArrangedSubview(inspectStatusButton)
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
        if launchProcess == nil {
            NSApp.terminate(nil)
        } else {
            window.orderOut(nil)
        }
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

    @objc private func inspectStatusClicked() {
        if let statusWindow, statusWindow.isVisible {
            NSApp.activate(ignoringOtherApps: true)
            statusWindow.makeKeyAndOrderFront(nil)
            statusWindow.orderFrontRegardless()
            return
        }

        let report = currentStatusReport()
        statusReport = report
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 660, height: 430))
        textView.string = report
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let closeButton = NSButton(title: tr("close"), target: self, action: #selector(closeStatusWindow(_:)))
        closeButton.keyEquivalent = "\r"
        let copyButton = NSButton(title: tr("copy"), target: self, action: #selector(copyStatusReport(_:)))
        let buttonRow = NSStackView(views: [copyButton, closeButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        let contentView = NSView()
        contentView.addSubview(scrollView)
        contentView.addSubview(buttonRow)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            scrollView.bottomAnchor.constraint(equalTo: buttonRow.topAnchor, constant: -12),
            buttonRow.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            buttonRow.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -14)
        ])

        let statusWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 520),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        statusWindow.title = tr("statusTitle")
        statusWindow.contentView = contentView
        statusWindow.isReleasedWhenClosed = false
        statusWindow.delegate = self
        statusWindow.minSize = NSSize(width: 560, height: 360)
        statusWindow.collectionBehavior.insert(.moveToActiveSpace)
        statusWindow.center()
        self.statusWindow = statusWindow
        NSApp.activate(ignoringOtherApps: true)
        statusWindow.makeKeyAndOrderFront(nil)
        statusWindow.orderFrontRegardless()
    }

    @objc private func closeStatusWindow(_ sender: Any?) {
        dismissStatusWindow()
    }

    @objc private func copyStatusReport(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(statusReport, forType: .string)
        dismissStatusWindow()
    }

    func windowWillClose(_ notification: Notification) {
        guard let closedWindow = notification.object as? NSWindow, closedWindow === statusWindow else { return }
        statusWindow = nil
        statusReport = ""
    }

    private func dismissStatusWindow() {
        statusWindow?.close()
        statusWindow = nil
        statusReport = ""
    }

    private func currentStatusReport() -> String {
        let chinese = language == .chinese
        let launcherPID = ProcessInfo.processInfo.processIdentifier
        let managedSessionRunning = launchProcess?.isRunning == true && managedSessionSnapshot != nil
        let scriptPID = managedSessionRunning ? String(launchProcess!.processIdentifier) : (chinese ? "未运行" : "Not running")
        let chatGPTPIDs = runningChatGPTApps().map { String($0.processIdentifier) }
        let chatGPTStatus: String
        if chatGPTPIDs.isEmpty {
            chatGPTStatus = chinese ? "未启动" : "Not running"
        } else if managedSessionRunning {
            chatGPTStatus = chinese
                ? "由当前 ChatGPT Proxy 启动，运行中（PID \(chatGPTPIDs.joined(separator: ", "))）"
                : "Running under the current ChatGPT Proxy session (PID \(chatGPTPIDs.joined(separator: ", ")))"
        } else {
            chatGPTStatus = chinese
                ? "运行中，但不是由当前 ChatGPT Proxy 会话启动（PID \(chatGPTPIDs.joined(separator: ", "))）"
                : "Running, but not launched by the current ChatGPT Proxy session (PID \(chatGPTPIDs.joined(separator: ", ")))"
        }
        let managedStatus = managedSessionRunning
            ? (chinese ? "运行中" : "Running")
            : (chinese ? "未运行" : "Not running")

        let snapshot = managedSessionSnapshot ?? config.proxies.first(where: { $0.id == config.activeProxy }).map {
            ManagedSessionSnapshot(
                chatGPTAppPath: config.chatGPTAppPath,
                proxyName: $0.name,
                proxyHost: $0.host,
                proxyPort: $0.port,
                authenticationEnabled: !$0.username.isEmpty || !$0.password.isEmpty,
                bridgeEnabled: $0.bridge,
                bridgeHost: config.httpBridgeHost,
                bridgePort: config.httpBridgePort,
                bypassItems: config.bypassItems
            )
        }
        let proxyName = snapshot?.proxyName ?? (chinese ? "无" : "None")
        let socksEndpoint = snapshot.map { "\($0.proxyHost):\($0.proxyPort)" } ?? (chinese ? "无" : "None")
        let bridgeEnabled = snapshot?.bridgeEnabled == true
        let authentication: String
        if snapshot?.authenticationEnabled == true {
            if bridgeEnabled {
                authentication = chinese
                    ? "已配置（凭据不显示；仅供本地 HTTP bridge 使用）"
                    : "Configured (credentials hidden; used only by the local HTTP bridge)"
            } else {
                authentication = chinese
                    ? "已配置（凭据不显示），但本次未启用 bridge；Chromium 不支持 SOCKS5 认证"
                    : "Configured (credentials hidden), but the bridge is disabled; Chromium does not support SOCKS5 authentication"
            }
        } else {
            authentication = chinese ? "未配置" : "Not configured"
        }
        let bridgeEndpoint = snapshot.map { "\($0.bridgeHost):\($0.bridgePort)" } ?? "\(config.httpBridgeHost):\(config.httpBridgePort)"
        let environmentProxy = snapshot.map {
            $0.bridgeEnabled
                ? "http://\(urlHost($0.bridgeHost)):\($0.bridgePort)"
                : "socks5h://\(urlHost($0.proxyHost)):\($0.proxyPort)"
        } ?? (chinese ? "无" : "None")
        let chromiumProxy = snapshot.map { "socks5://\(urlHost($0.proxyHost)):\($0.proxyPort)" } ?? (chinese ? "无" : "None")
        let bypass = snapshot?.bypassItems.joined(separator: ", ") ?? (chinese ? "无" : "None")
        let listener = bridgeListenerStatus(snapshot: snapshot, managedSessionRunning: managedSessionRunning, chinese: chinese)
        let sessionRecord = sessionRecordStatus(managedSessionRunning: managedSessionRunning, chinese: chinese)
        let abnormalities = abnormalStatus(chinese: chinese)
        let systemProxy = systemProxyStatus(chinese: chinese)
        let launchctlProxy = launchctlProxyStatus(chinese: chinese)

        if chinese {
            return """
            检查时间：\(DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .medium))

            【启动器与 ChatGPT】
            ChatGPT Proxy PID：\(launcherPID)
            管理会话：\(managedStatus)
            启动脚本 PID：\(scriptPID)
            ChatGPT：\(chatGPTStatus)
            ChatGPT App 路径：\(snapshot?.chatGPTAppPath ?? config.chatGPTAppPath)

            \(managedSessionRunning ? "【本次受管会话的代理配置】" : "【当前选择的代理配置（尚未应用）】")
            配置名称：\(proxyName)
            上游 SOCKS5：\(socksEndpoint)
            SOCKS5 认证：\(authentication)
            Chromium --proxy-server：\(chromiumProxy)
            HTTP_PROXY / HTTPS_PROXY / ALL_PROXY：\(environmentProxy)
            本地 HTTP bridge：\(bridgeEnabled ? "已启用（\(bridgeEndpoint)）" : "未启用")
            直连排除：\(bypass)

            【本地监听状态】
            \(listener)

            【会话记录】
            \(sessionRecord)

            【异常信息】
            \(abnormalities)

            【本机全局状态（只读检查）】
            系统代理：
            \(systemProxy)

            launchctl 全局代理变量：
            \(launchctlProxy)

            【ChatGPT Proxy 的修改范围】
            系统 HTTP/HTTPS/SOCKS 代理：未修改
            全局 launchctl 环境：未修改
            VPN：未修改
            DNS：未修改
            其他应用的代理环境：未修改

            说明：上面的“系统代理”和“launchctl 全局代理变量”仅供核对当前系统实际状态，不代表这些设置由 ChatGPT Proxy 创建，也不会仅因它们已启用就列为 ChatGPT Proxy 异常。ChatGPT Proxy 不写入这些位置。
            """
        }

        return """
        Checked: \(DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .medium))

        [Launcher and ChatGPT]
        ChatGPT Proxy PID: \(launcherPID)
        Managed session: \(managedStatus)
        Launch script PID: \(scriptPID)
        ChatGPT: \(chatGPTStatus)
        ChatGPT App path: \(snapshot?.chatGPTAppPath ?? config.chatGPTAppPath)

        \(managedSessionRunning ? "[Proxy settings for this managed session]" : "[Currently selected proxy settings (not applied)]")
        Profile: \(proxyName)
        Upstream SOCKS5: \(socksEndpoint)
        SOCKS5 authentication: \(authentication)
        Chromium --proxy-server: \(chromiumProxy)
        HTTP_PROXY / HTTPS_PROXY / ALL_PROXY: \(environmentProxy)
        Local HTTP bridge: \(bridgeEnabled ? "Enabled (\(bridgeEndpoint))" : "Disabled")
        Direct-connect bypasses: \(bypass)

        [Local listener status]
        \(listener)

        [Session record]
        \(sessionRecord)

        [Abnormalities]
        \(abnormalities)

        [Machine-wide state (read-only checks)]
        System proxies:
        \(systemProxy)

        Global launchctl proxy variables:
        \(launchctlProxy)

        [Changes made by ChatGPT Proxy]
        System HTTP/HTTPS/SOCKS proxies: Not modified
        Global launchctl environment: Not modified
        VPN: Not modified
        DNS: Not modified
        Proxy environments of other apps: Not modified

        Note: the system-proxy and launchctl sections are read-only views of the current machine state. Their presence does not mean ChatGPT Proxy created them, and enabled values are not treated as ChatGPT Proxy abnormalities by themselves. ChatGPT Proxy does not write to those locations.
        """
    }

    private func urlHost(_ host: String) -> String {
        if host.hasPrefix("[") && host.hasSuffix("]") { return host }
        return host.contains(":") ? "[\(host)]" : host
    }

    private func bridgeListenerStatus(snapshot: ManagedSessionSnapshot?, managedSessionRunning: Bool, chinese: Bool) -> String {
        let port = snapshot?.bridgePort ?? config.httpBridgePort
        let host = snapshot?.bridgeHost ?? config.httpBridgeHost
        guard Int(port) != nil else {
            return chinese ? "异常：Bridge 端口无效：\(port)" : "Abnormal: invalid bridge port: \(port)"
        }
        let output = commandOutput("/usr/sbin/lsof", ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let bridgeEnabled = snapshot?.bridgeEnabled == true
        let currentScriptPID = launchProcess?.isRunning == true ? launchProcess?.processIdentifier : nil
        let bridgePath = store.resourcesURL.appendingPathComponent("chatgpt-socks-http-bridge").path
        let managedBridge = proxyOwnedProcesses().first {
            $0.command.hasPrefix(bridgePath) && $0.ppid == currentScriptPID
        }

        if !managedSessionRunning, output.isEmpty {
            return chinese
                ? "正常：当前未启动受管 ChatGPT 会话，不需要 HTTP bridge 监听。"
                : "Normal: no managed ChatGPT session is running, so no HTTP bridge listener is required."
        }
        if !managedSessionRunning {
            return chinese
                ? "提示：当前没有受管 ChatGPT 会话；配置的 bridge 端口 \(host):\(port) 已被进程监听。该监听不一定来自 ChatGPT Proxy，但以后启用 bridge 时可能发生端口冲突：\n\(output)"
                : "Notice: no managed ChatGPT session is running, but the configured bridge port \(host):\(port) has a listener. It may not belong to ChatGPT Proxy, but could cause a port conflict when the bridge is enabled later:\n\(output)"
        }
        if bridgeEnabled, let managedBridge, !output.isEmpty {
            return chinese
                ? "正常：当前受管 HTTP bridge（PID \(managedBridge.pid)）正在监听 \(host):\(port)。"
                : "Normal: the managed HTTP bridge (PID \(managedBridge.pid)) is listening on \(host):\(port)."
        }
        if bridgeEnabled, output.isEmpty {
            return chinese
                ? "异常：本次会话启用了 HTTP bridge，但 \(host):\(port) 没有监听进程。"
                : "Abnormal: HTTP bridge is enabled for this session, but no process is listening on \(host):\(port)."
        }
        if bridgeEnabled {
            return chinese
                ? "异常：\(host):\(port) 已被非当前受管 bridge 的进程监听：\n\(output)"
                : "Abnormal: \(host):\(port) is owned by a process other than the currently managed bridge:\n\(output)"
        }
        if output.isEmpty {
            return chinese
                ? "正常：本次会话未启用 HTTP bridge，\(host):\(port) 没有监听。"
                : "Normal: HTTP bridge is disabled for this session and \(host):\(port) has no listener."
        }
        return chinese
            ? "提示：本次会话未启用 HTTP bridge；\(host):\(port) 的现有监听不属于本次会话，也不会被本次会话使用：\n\(output)"
            : "Notice: HTTP bridge is disabled for this session. The existing listener on \(host):\(port) does not belong to this session and is not used by it:\n\(output)"
    }

    private func sessionRecordStatus(managedSessionRunning: Bool, chinese: Bool) -> String {
        let state = managedSessionState()
        guard let recordedPIDText = state["script_pid"],
              let recordedPID = Int32(recordedPIDText) else {
            return chinese ? "没有受管会话记录。" : "No managed-session record."
        }

        let scriptPath = store.scriptURL.path
        let bridgePath = store.resourcesURL.appendingPathComponent("chatgpt-socks-http-bridge").path
        let currentScriptPID = launchProcess?.isRunning == true ? launchProcess?.processIdentifier : nil
        let processes = proxyOwnedProcesses()
        let matchingProcess = recordedPID == currentScriptPID || processes.contains {
            $0.pid == recordedPID && isLaunchScriptCommand($0.command, scriptPath: scriptPath)
        }
        if managedSessionRunning && matchingProcess {
            return chinese
                ? "当前受管会话记录正常（启动脚本 PID \(recordedPID)）。"
                : "The current managed-session record is normal (launch script PID \(recordedPID))."
        }

        let recordedBridgePID = state["bridge_pid"].flatMap(Int32.init)
        let recordedChatGPTPID = state["chatgpt_pid"].flatMap(Int32.init)
        let bridgeStillRunning = recordedBridgePID.map { bridgePID in
            processes.contains { $0.pid == bridgePID && $0.command.hasPrefix(bridgePath) }
        } ?? false
        let runningChatGPTPIDs = Set(runningChatGPTApps().map(\.processIdentifier))
        let chatGPTStillRunning = recordedChatGPTPID.map(runningChatGPTPIDs.contains) ?? false
        if matchingProcess || bridgeStillRunning || chatGPTStillRunning {
            return chinese
                ? "上次会话记录仍对应正在运行的相关进程，详情请查看“异常信息”。"
                : "The previous-session record still refers to a related running process. See Abnormalities for details."
        }

        let bridgePID = recordedBridgePID.map(String.init) ?? "-"
        let chatGPTPID = recordedChatGPTPID.map(String.init) ?? "-"
        let endpoint = [state["bridge_host"], state["bridge_port"]].compactMap { $0 }.joined(separator: ":")
        return chinese
            ? "上次会话留有状态记录（脚本 PID \(recordedPID)，bridge PID \(bridgePID)，ChatGPT PID \(chatGPTPID)，监听 \(endpoint.isEmpty ? "-" : endpoint)），但相关受管进程已经结束；该记录不影响当前系统，也不属于异常。"
            : "A previous-session state record remains (script PID \(recordedPID), bridge PID \(bridgePID), ChatGPT PID \(chatGPTPID), listener \(endpoint.isEmpty ? "-" : endpoint)), but its managed processes have ended. The record does not affect the current system and is not an abnormality."
    }

    private func abnormalStatus(chinese: Bool) -> String {
        let processes = proxyOwnedProcesses()
        let scriptPath = store.scriptURL.path
        let bridgePath = store.resourcesURL.appendingPathComponent("chatgpt-socks-http-bridge").path
        let currentScriptPID = launchProcess?.isRunning == true ? launchProcess?.processIdentifier : nil
        let scriptProcesses = processes.filter {
            isLaunchScriptCommand($0.command, scriptPath: scriptPath)
        }
        let bridgeProcesses = processes.filter { $0.command.hasPrefix(bridgePath) }
        var scriptPIDs = Set(scriptProcesses.map(\.pid))
        if let currentScriptPID {
            scriptPIDs.insert(currentScriptPID)
        }
        var findings: [String] = []

        for process in scriptProcesses where process.pid != currentScriptPID {
            findings.append(chinese
                ? "发现当前启动器之外的 ChatGPT Proxy 启动脚本：PID \(process.pid)，PPID \(process.ppid)。"
                : "Additional ChatGPT Proxy launch script: PID \(process.pid), PPID \(process.ppid).")
        }
        for process in bridgeProcesses where !scriptPIDs.contains(process.ppid) {
            findings.append(chinese
                ? "发现未由有效 ChatGPT Proxy 启动脚本管理的 HTTP bridge：PID \(process.pid)，PPID \(process.ppid)，路径 \(bridgePath)。"
                : "HTTP bridge without a valid ChatGPT Proxy launch script: PID \(process.pid), PPID \(process.ppid), path \(bridgePath).")
        }

        let state = managedSessionState()
        if let recordedPIDText = state["script_pid"],
           let recordedPID = Int32(recordedPIDText) {
            let matchingProcess = recordedPID == currentScriptPID || processes.contains {
                $0.pid == recordedPID && isLaunchScriptCommand($0.command, scriptPath: scriptPath)
            }
            let runningChatGPTPIDs = Set(runningChatGPTApps().map(\.processIdentifier))
            if !matchingProcess,
               let recordedChatGPTPID = state["chatgpt_pid"].flatMap(Int32.init),
               runningChatGPTPIDs.contains(recordedChatGPTPID) {
                findings.append(chinese
                    ? "发现之前由 ChatGPT Proxy 启动的 ChatGPT 仍在运行（PID \(recordedChatGPTPID)），但对应启动脚本 PID \(recordedPID) 已结束。"
                    : "ChatGPT from a previous managed session is still running (PID \(recordedChatGPTPID)), but its launch script PID \(recordedPID) has ended.")
            }
        }

        return findings.isEmpty
            ? (chinese ? "未发现 ChatGPT Proxy 异常。" : "No ChatGPT Proxy abnormalities detected.")
            : findings.joined(separator: "\n")
    }

    private func isLaunchScriptCommand(_ command: String, scriptPath: String) -> Bool {
        command == scriptPath || command.contains(" \(scriptPath)")
    }

    private func managedSessionState() -> [String: String] {
        guard let content = try? String(contentsOf: store.sessionStateURL, encoding: .utf8) else {
            return [:]
        }
        var values: [String: String] = [:]
        for line in content.split(separator: "\n") {
            guard let separator = line.firstIndex(of: "=") else { continue }
            values[String(line[..<separator])] = String(line[line.index(after: separator)...])
        }
        return values
    }

    private func proxyOwnedProcesses() -> [(pid: Int32, ppid: Int32, command: String)] {
        commandOutput("/bin/ps", ["-axo", "pid=,ppid=,command="])
            .split(separator: "\n")
            .compactMap { line in
                let fields = line.split(maxSplits: 2, whereSeparator: \.isWhitespace)
                guard fields.count == 3,
                      let pid = Int32(fields[0]),
                      let ppid = Int32(fields[1]) else {
                    return nil
                }
                return (pid: pid, ppid: ppid, command: String(fields[2]))
            }
    }

    private func systemProxyStatus(chinese: Bool) -> String {
        let output = commandOutput("/usr/sbin/scutil", ["--proxy"])
        let keys = ["HTTPEnable", "HTTPProxy", "HTTPPort", "HTTPSEnable", "HTTPSProxy", "HTTPSPort", "SOCKSEnable", "SOCKSProxy", "SOCKSPort"]
        let lines = output.split(separator: "\n").map(String.init).filter { line in
            keys.contains { line.contains($0) }
        }
        let enabled = lines.contains { $0.contains("Enable : 1") }
        if !enabled {
            return chinese ? "HTTP / HTTPS / SOCKS 均未启用。" : "HTTP / HTTPS / SOCKS are all disabled."
        }
        return lines.joined(separator: "\n")
    }

    private func launchctlProxyStatus(chinese: Bool) -> String {
        let keys = ["HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy"]
        let values = keys.compactMap { key -> String? in
            let value = commandOutput("/bin/launchctl", ["getenv", key])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : "\(key)=\(redactedProxyValue(value))"
        }
        return values.isEmpty
            ? (chinese ? "未设置。" : "Not set.")
            : values.joined(separator: "\n")
    }

    private func redactedProxyValue(_ value: String) -> String {
        guard let schemeRange = value.range(of: "://"),
              let atIndex = value[schemeRange.upperBound...].firstIndex(of: "@") else {
            return value
        }
        return String(value[..<schemeRange.upperBound]) + "***@" + String(value[value.index(after: atIndex)...])
    }

    private func commandOutput(_ executable: String, _ arguments: [String]) -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }

    @objc private func launchClicked() {
        saveFieldsToSelectedProxy()
        guard validateConfig() else { return }
        do {
            try store.save(config)
            let replacingManagedSession = launchProcess != nil
            suppressTerminationForRelaunch = replacingManagedSession
            if !handleRunningChatGPTIfNeeded() {
                suppressTerminationForRelaunch = false
                return
            }
            if replacingManagedSession {
                let deadline = Date().addingTimeInterval(6)
                while launchProcess != nil, Date() < deadline {
                    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
                }
                suppressTerminationForRelaunch = false
                guard launchProcess == nil else {
                    showError(tr("unableLaunch"), tr("cleanupFailed"))
                    return
                }
            }
            try launchChatGPT(waitForBridgeRelease: replacingManagedSession)
            launchButton.isEnabled = false
            window.orderOut(nil)
        } catch {
            suppressTerminationForRelaunch = false
            launchButton.isEnabled = true
            showError(tr("unableLaunch"), error.localizedDescription)
        }
    }

    private func clearStatus() {
        statusLabel.stringValue = ""
    }

    private func runningChatGPTApps() -> [NSRunningApplication] {
        let expectedPath = ((managedSessionSnapshot?.chatGPTAppPath ?? config.chatGPTAppPath) as NSString).standardizingPath
        return NSWorkspace.shared.runningApplications.filter { app in
            if app.processIdentifier == ProcessInfo.processInfo.processIdentifier {
                return false
            }
            if let bundlePath = app.bundleURL?.path {
                return (bundlePath as NSString).standardizingPath == expectedPath
            }
            return app.localizedName == "ChatGPT" && app.bundleURL == nil
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

    private func launchChatGPT(waitForBridgeRelease: Bool) throws {
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
        env["CHATGPT_PROXY_WAIT_FOR_BRIDGE_RELEASE"] = waitForBridgeRelease ? "1" : "0"
        process.environment = env
        process.terminationHandler = { [weak self] terminatedProcess in
            DispatchQueue.main.async {
                guard let self else { return }
                guard self.launchProcess === terminatedProcess else { return }
                self.launchProcess = nil
                self.managedSessionSnapshot = nil
                self.enableAutomaticTerminationIfNeeded()
                if self.terminationRequested {
                    self.terminationRequested = false
                    NSApp.reply(toApplicationShouldTerminate: true)
                } else if !self.suppressTerminationForRelaunch {
                    NSApp.terminate(nil)
                }
            }
        }
        disableAutomaticTerminationIfNeeded()
        do {
            try process.run()
        } catch {
            enableAutomaticTerminationIfNeeded()
            throw error
        }
        launchProcess = process
        if let proxy = config.proxies.first(where: { $0.id == config.activeProxy }) {
            managedSessionSnapshot = ManagedSessionSnapshot(
                chatGPTAppPath: config.chatGPTAppPath,
                proxyName: proxy.name,
                proxyHost: proxy.host,
                proxyPort: proxy.port,
                authenticationEnabled: !proxy.username.isEmpty || !proxy.password.isEmpty,
                bridgeEnabled: proxy.bridge,
                bridgeHost: config.httpBridgeHost,
                bridgePort: config.httpBridgePort,
                bypassItems: config.bypassItems
            )
        }
    }

    private func disableAutomaticTerminationIfNeeded() {
        guard !automaticTerminationDisabled else { return }
        ProcessInfo.processInfo.disableAutomaticTermination(automaticTerminationReason)
        automaticTerminationDisabled = true
    }

    private func enableAutomaticTerminationIfNeeded() {
        guard automaticTerminationDisabled else { return }
        ProcessInfo.processInfo.enableAutomaticTermination(automaticTerminationReason)
        automaticTerminationDisabled = false
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
