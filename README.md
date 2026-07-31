# ChatGPT Proxy

[English](#english) | 简体中文

一个原生 macOS 启动器，让 **ChatGPT Desktop** 按所选 SOCKS5 代理和直连排除规则访问网络。它不会修改系统代理、不会开启全局 VPN，也不需要额外的分流软件。

## 为什么使用它？

有些网络环境中，ChatGPT Desktop 需要代理才能正常登录、对话或访问插件市场。系统全局代理、VPN 或分流软件会影响整台机器的流量，可能让国内服务、DNS、路由或其他应用出现不必要的延迟和异常。

ChatGPT Proxy 只在启动 ChatGPT 时注入代理环境变量与 Chromium 代理参数。除配置的直连排除项外，ChatGPT 中遵循这些设置的网络请求会使用所选代理；机器上的其他应用继续按原来的网络路径访问。

## 功能

- 仅代理 ChatGPT Desktop，不改动系统网络设置。
- 可保存多个 SOCKS5 配置；原生 bridge 支持 SOCKS5 用户名/密码认证，但 Chromium 直连 SOCKS5 不支持认证（见下方限制）。
- 可配置直连排除项，包括本机、局域网、域名、IP 和 CIDR。
- 可选本地 HTTP CONNECT bridge，改善部分内部 HTTP 客户端对 SOCKS5 支持不完整造成的对话或插件市场异常。
- 原生 AppKit 界面，支持英文/中文快速切换。
- 界面直接显示当前应用版本号，便于确认本机与 Release 版本一致。
- 当 ChatGPT 已运行时提示退出并重新启动，避免代理配置未真正生效。

## 要求

- Apple Silicon Mac（当前发布包为 `arm64`）。
- macOS 12 或更高版本，与当前 ChatGPT Desktop 的最低系统要求一致。
- 已安装新版 ChatGPT Desktop。默认路径为 `/Applications/ChatGPT.app`；其他位置可通过 `CHATGPT_APP_PATH` 配置。
- 可用的 SOCKS5 服务端。要完整代理 ChatGPT，建议使用无需认证的 SOCKS5；用户名/密码仅能可靠用于经过本地 bridge 的内部客户端。

旧版 `/Applications/Codex.app` 不受支持。

## 安装与使用

1. 从 [Releases](../../releases) 下载最新的 macOS 应用 ZIP。
2. 解压后，把 `ChatGPT Proxy.app` 拖到 `/Applications`。从旧版升级时，可在确认新版本正常后删除旧的 `Codex Proxy.app`。
3. 打开 `ChatGPT Proxy.app`。只有 SOCKS5 服务器位于当前 Mac 直接连接的局域网时，才需要按 macOS 提示允许本地网络访问。
4. 在 `Proxies` 中填写 SOCKS5 主机和端口；按需启用 `Use local HTTP bridge`。认证信息只适用于经过 bridge 的客户端，不能让 Chromium 支持带认证的 SOCKS5。
5. 在 `Bypass` 中填写应直接连接的主机、域名、IP 或 CIDR。
6. 点击 `Save` 仅保存配置，或点击 `Launch ChatGPT` 保存并以当前配置启动 ChatGPT。

配置只在 ChatGPT 启动时读取。若 ChatGPT 已在运行，推荐选择 `Quit and Relaunch`，以确保当前代理生效。新进程启动前，启动器会在确认 ChatGPT 主进程已退出后清理未随主进程结束的 helper，避免旧 app-server 或网络状态被下一次启动复用。

## HTTP bridge

正常情况下，ChatGPT 的 Chromium 网络请求可直接使用 SOCKS5。部分内部 HTTP 客户端对 SOCKS5 环境变量的支持不完整时，可能出现登录正常但对话、内部请求或插件市场超时/加载不完整的情况。

认证限制：根据 [Chromium 官方代理文档](https://chromium.googlesource.com/chromium/src/+/HEAD/net/docs/proxy.md)，Chrome/Chromium 不支持 SOCKSv5 认证。当前 Chromium 参数直接连接所选上游 SOCKS5，因此配置中的用户名/密码只会被本地 HTTP bridge 用于它所转发的内部请求，不能保证 Chromium 流量通过带认证的 SOCKS5。若要完整代理 ChatGPT，请使用无需认证的 SOCKS5 服务端。

为对应代理启用 `Use local HTTP bridge` 后，启动器只在回环地址上临时启动一个原生 HTTP CONNECT bridge（新配置默认是 `127.0.0.1:28083`），再将流量转发至该 SOCKS5 服务器。bridge 随启动器一同打包，不依赖 ChatGPT.app 内部 Node 或机器上另行安装的运行时；因此其本地网络访问稳定归属 `ChatGPT Proxy`。ChatGPT 仅继承本次启动进程的代理环境和 Chromium 参数，启动器不会调用 `launchctl`、不会写入全局 GUI 代理环境，也不会改动系统 HTTP 代理。启动 ChatGPT 后，启动器会隐藏窗口并在后台保持运行，以便 macOS 正确维持 bridge 的本地网络权限身份；点击程序坞中的 ChatGPT Proxy 可重新打开配置窗口并切换代理，启动器会等待旧 bridge 释放监听端口后再重新启动。bridge 和启动器会随本次 ChatGPT 主进程结束而退出；通过程序坞、左上角应用菜单或 `⌘Q` 手动退出启动器时，如果其管理的 ChatGPT 仍在运行，会先提示确认，确认后同时结束 ChatGPT 并清理 bridge，避免留下失效的代理环境。配置端口被其他程序持续占用时会明确报错，不会抢占端口或静默递增并产生多个监听。配置窗口中的“当前状态”按钮可查看启动器与 ChatGPT 进程、本地监听、本次代理变量和直连规则，并只读核对系统代理与全局 `launchctl` 代理变量。预期的当前 bridge 监听会明确标记为“正常”；只有未由有效启动脚本管理的 bridge、额外启动脚本、仍对应存活相关进程的旧会话记录或监听所有者不匹配等情况才会列入“异常信息”。从 2.1.5 build 22 起，启动器会维护临时受管会话所有权记录，正常退出时自动删除。无法确认来源的系统值不会被标记为 ChatGPT Proxy 异常。

bridge 对连接建立和 SOCKS5 握手设置 15 秒超时，并将同时处理的连接限制为 128 个。已经建立的正常长连接不使用短时空闲超时，不会影响 Voice、视频或 Codex 长任务。

ChatGPT 通过 macOS LaunchServices 以自身应用身份启动，同时只接收本次会话的代理环境和 Chromium 参数。录屏与系统录音、麦克风、摄像头、自动化等 ChatGPT 功能权限均由 ChatGPT 自己申请；ChatGPT Proxy 不声明或申请这些权限。Proxy 只可能在直接连接局域网 SOCKS5 时需要“本地网络”权限。

只有当 SOCKS5 服务器通过当前 Mac 的 Wi-Fi 或以太网直接位于同一局域网时，macOS 15 及以上版本才可能要求在 `系统设置 > 隐私与安全性 > 本地网络` 中允许 ChatGPT Proxy。公网 IPv4、全球单播 IPv6、`127.0.0.1`/`localhost`，以及经 VPN 路由而不是本地链路到达的代理通常不需要这项权限。本地 HTTP bridge 自身只监听回环地址；触发权限的是 bridge 向局域网 SOCKS5 服务器发起的连接。

“当前状态”会区分 ChatGPT 未启动、由当前 ChatGPT Proxy 会话启动，以及已运行但并非由当前会话启动三种情况。没有启动受管会话时，不需要 bridge 监听，当前选择的代理配置会明确标记为“尚未应用”，不会被误报为异常。异常退出后可能留下仅用于诊断的上次会话状态文件；如果其中记录的脚本、bridge 和 ChatGPT 都已结束，状态页会将它显示为无影响的“会话记录”，而不是异常。只有相关进程或监听仍然存在时才会列入“异常信息”。

启动器会在打开 ChatGPT 前通过 bridge 做一次真实连接测试；失败时不会继续打开一个无法显示账户、额度、对话或插件市场的窗口。直接局域网 SOCKS5 的失败通常应检查 ChatGPT Proxy 的本地网络权限、SOCKS5 服务和上游链路。临时签名版本升级后，macOS 偶尔可能再次要求确认此权限；旧版迁移用户还可能看到 `CodexProxyLauncher` 名称。

## 配置与隐私

本地配置位于：

```text
~/Library/Application Support/ChatGPT Proxy/chatgpt-proxy.conf
```

首次从旧版启动器升级时，会自动复制旧的本地配置到新目录。该迁移仅用于保留你的配置；启动器不会再启动旧版 Codex Desktop。

真实配置可能含有代理地址、内网规则和认证信息。请勿提交或分享它；仓库只提供公开的 [chatgpt-proxy.conf.example](chatgpt-proxy.conf.example) 模板。

启动器会将该目录权限设置为 `700`，并将配置、会话记录、临时 PID 文件和诊断日志设置为 `600`；升级后首次启动会自动收紧旧版本创建文件的权限。界面保存的 `$`、反引号、引号和反斜杠会安全转义，避免配置被 Shell 错误展开。

ChatGPT 默认从 `/Applications/ChatGPT.app` 启动。如果安装在其他位置，请退出当前 ChatGPT Proxy 会话，然后在 `chatgpt-proxy.conf` 中设置 `.app` 包的完整路径：

```sh
CHATGPT_APP_PATH="/Users/your-name/Applications/ChatGPT.app"
```

路径可以包含空格。配置界面保存代理设置时会保留此项；重新启动 ChatGPT Proxy 后生效。“当前状态”报告会显示本次会话实际使用的 ChatGPT App 路径。

默认直连排除项包含 `localhost`、回环地址、`.local`、私有 IPv4 网段与常见本地 IPv6 网段。所有排除项均可在界面中修改或删除。

## 项目结构

- `ChatGPTProxyLauncher.swift`：原生 AppKit 启动器。
- `ChatGPTLaunchHelper.swift`：通过 macOS LaunchServices 以 ChatGPT 自身权限身份启动并跟踪 ChatGPT。
- `chatgpt-proxy-launch.sh`：管理 bridge、会话状态和代理参数，并调用原生 LaunchServices helper。
- `NativeSocksHTTPBridge.c`：随应用打包的本地 HTTP CONNECT 到 SOCKS5 bridge。
- `build-app.sh`：只使用 macOS 自带的 clang、Swift 与图标工具构建 `.app`。
- `chatgpt-proxy.conf.example`：公开配置模板。

## 构建

发布包已包含可直接使用的应用。源码只使用 macOS 自带的 Swift/AppKit 与 clang；bridge 是打包的原生可执行文件，不要求安装 Node 或其他第三方依赖。

构建应用：

```sh
./build-app.sh
```

产物位于 `.build/ChatGPT Proxy.app`。Swift 模块缓存写入系统临时目录，不会在项目的 `.build` 中持续累积。构建脚本会检查 AppKit 启动器、LaunchServices helper 和 bridge 三个原生可执行文件的最低系统版本均为 macOS 12。当前 GitHub Release 和本地构建均使用临时签名；首次启动或更新后，直接连接局域网 SOCKS5 时 macOS 可能再次请求本地网络授权。

bridge 的离线集成测试只使用本机回环端口和模拟 SOCKS5 服务，不访问外网。测试本身需要开发机提供 Node；应用运行不需要 Node：

```sh
node tests/bridge.test.mjs
```

## English

ChatGPT Proxy is a native macOS launcher that starts **ChatGPT Desktop** with per-app SOCKS5 proxy settings and configurable direct-connect bypasses. It does not change the system proxy, enable a global VPN, or route other applications through split-tunneling software. Only ChatGPT receives these settings; other applications keep their existing network behavior.

### Features

- Per-app SOCKS5 proxying for ChatGPT Desktop only.
- Multiple proxy profiles. The native bridge supports SOCKS5 username/password authentication, but Chromium cannot authenticate to SOCKS5 directly; see the limitation below.
- Editable direct-connect bypass rules for hosts, domains, IP addresses, and CIDRs.
- Optional local HTTP CONNECT bridge for internal clients with incomplete SOCKS5 support.
- English/Chinese UI switching and a prompt to quit and relaunch ChatGPT when needed.
- The current app version is shown directly in the launcher UI.

### Requirements

- An Apple Silicon Mac (the current release is `arm64`).
- macOS 12 or later, matching the current ChatGPT Desktop minimum requirement.
- The current ChatGPT Desktop app. The default path is `/Applications/ChatGPT.app`; use `CHATGPT_APP_PATH` for another location.
- A reachable SOCKS5 server. Use an unauthenticated SOCKS5 server to cover all ChatGPT traffic; credentials are reliable only for internal clients routed through the local bridge.

Legacy `/Applications/Codex.app` is not supported.

### Install and Use

1. Download the latest macOS app ZIP from [Releases](../../releases).
2. Unzip it and move `ChatGPT Proxy.app` to `/Applications`.
3. Open the app. Local Network access is only needed when the SOCKS5 server is directly reachable on the Mac's current LAN.
4. Add a SOCKS5 host and port under **Proxies**. Enable **Use local HTTP bridge** when appropriate. Credentials apply only to bridge-routed clients and do not add SOCKS5 authentication support to Chromium.
5. Add addresses that must connect directly under **Bypass**.
6. Choose **Save** to keep the configuration, or **Launch ChatGPT** to save and start ChatGPT with the selected proxy.

Proxy settings apply only when ChatGPT starts. If ChatGPT is already running, choose **Quit and Relaunch** to ensure the new settings take effect. Before starting the new process, the launcher confirms that the ChatGPT main process has exited and removes leftover ChatGPT helpers not managed by the current session so an old app-server or network state cannot be reused.

When upgrading from the previous Codex Proxy launcher, verify the new app first and then remove the old `Codex Proxy.app` from `/Applications` if desired. Your previous local configuration is migrated automatically once.

### Local HTTP Bridge

Most Chromium traffic can use SOCKS5 directly. Some internal HTTP clients may not honor SOCKS5 environment variables consistently, which can result in successful login but failed chats, internal requests, or a partially loaded plugin marketplace.

Authentication limitation: [Chromium's official proxy documentation](https://chromium.googlesource.com/chromium/src/+/HEAD/net/docs/proxy.md) states that Chrome/Chromium does not support SOCKSv5 authentication. The Chromium proxy argument currently connects directly to the selected upstream SOCKS5 server, so configured credentials are used only by the local HTTP bridge for the internal requests it forwards. They cannot make Chromium traffic work through an authenticated SOCKS5 server. Use an unauthenticated SOCKS5 server when all ChatGPT traffic must be covered.

For that proxy profile, enable **Use local HTTP bridge**. The launcher temporarily opens a native HTTP CONNECT bridge on a loopback address (`127.0.0.1:28083` by default for new configurations) and forwards it to the selected SOCKS5 server. The bridge is bundled with ChatGPT Proxy, rather than using ChatGPT.app's private Node runtime, so its local-network access is consistently attributed to ChatGPT Proxy. ChatGPT receives proxy environment variables and Chromium arguments only through the process started for that launch. The launcher never calls `launchctl`, writes global GUI proxy variables, or changes the system HTTP proxy. After starting ChatGPT, the launcher hides its window and remains alive in the background so macOS can retain the bridge's Local Network identity correctly. Click ChatGPT Proxy in the Dock to reopen its configuration window and switch proxies; the launcher waits for the previous bridge listener to release its port before relaunching. The bridge and launcher exit when that ChatGPT main process ends. When manually quitting the launcher from the Dock, the application menu, or `⌘Q` while its managed ChatGPT instance is still running, the launcher asks for confirmation before quitting ChatGPT and cleaning up the bridge, avoiding a stale proxy environment. If another program continues to hold the configured port, startup fails explicitly rather than taking over the port or silently opening additional listeners. The **Current Status** button reports the managed launcher and ChatGPT processes, the local listener, session-scoped proxy variables and bypasses, plus read-only checks for system proxies and global `launchctl` proxy variables. The expected managed bridge listener is explicitly labeled **Normal**; only bridges without a valid managing launch script, extra launch scripts, stale session records, or listener ownership mismatches appear under **Abnormalities**. Starting with 2.1.5 build 22, a temporary managed-session ownership record is removed after clean shutdown. System values with uncertain ownership are never labeled as ChatGPT Proxy abnormalities.

Connection setup and SOCKS5 negotiation have a 15-second timeout and the bridge accepts at most 128 concurrent tunnels. Established long-lived tunnels do not use a short idle timeout, so Voice, video, and long Codex tasks are unaffected.

ChatGPT is launched through macOS LaunchServices under its own application identity while receiving proxy environment variables and Chromium arguments only for that session. ChatGPT itself requests permissions for screen and system-audio recording, microphone, camera, Automation, and similar features; ChatGPT Proxy neither declares nor requests those permissions. The Proxy may need Local Network permission only when connecting directly to a LAN SOCKS5 server.

Local Network permission is only relevant when the SOCKS5 server is directly reachable on the same Wi-Fi or Ethernet LAN. Public IPv4 addresses, globally routable IPv6 addresses, `127.0.0.1`/`localhost`, and proxies reached through a VPN rather than the local link normally do not require it. The HTTP bridge itself listens only on loopback; the permission applies to its outbound connection to a LAN SOCKS5 server.

**Current Status** distinguishes ChatGPT not running, running under the current managed session, and running independently of the current ChatGPT Proxy session. When no managed session has been launched, no bridge listener is required and the selected proxy profile is explicitly labeled as not applied instead of being reported as abnormal. An unexpected exit may leave a previous-session state file used only for diagnostics. If its recorded launch script, bridge, and ChatGPT processes have all ended, the status page presents it as a harmless **Session record**, not an abnormality. It is listed under **Abnormalities** only when a related process or listener is still active.

On macOS 15 or later, allow ChatGPT Proxy under **System Settings > Privacy & Security > Local Network** when that LAN case applies. Before opening ChatGPT, the launcher performs a real request through the bridge. If that check fails, it stops before opening a window that cannot load account details, chats, or plugins. For a direct LAN SOCKS5 server, check ChatGPT Proxy's Local Network permission, the SOCKS5 service, and its upstream path. Ad hoc signed builds may require this permission again after an update; users migrating from older builds may also see a legacy `CodexProxyLauncher` entry.

### Build

The AppKit launcher, LaunchServices helper, and bridge use only macOS-provided toolchains:

```sh
./build-app.sh
```

The output is `.build/ChatGPT Proxy.app`. Swift module caches are stored in the system temporary directory instead of accumulating under the project `.build` directory. The build verifies that the AppKit launcher, LaunchServices helper, and bridge all target macOS 12. The current GitHub Release and local builds use ad hoc signing, so macOS may request Local Network access again after an update or rebuild when the SOCKS5 server is directly reachable on the LAN.

### Privacy and Configuration

Your private configuration is stored at:

```text
~/Library/Application Support/ChatGPT Proxy/chatgpt-proxy.conf
```

It may contain proxy endpoints, bypass rules, and credentials. Do not publish it. This repository contains only the safe [configuration template](chatgpt-proxy.conf.example).

The launcher sets the directory mode to `700` and the configuration, session record, temporary PID file, and diagnostic log modes to `600`. The first launch after upgrading also tightens permissions on files created by older versions. Dollar signs, backticks, quotes, and backslashes saved through the UI are escaped so the shell cannot expand them as configuration code.

ChatGPT launches from `/Applications/ChatGPT.app` by default. If it is installed elsewhere, quit the current ChatGPT Proxy session and set the full `.app` bundle path in `chatgpt-proxy.conf`:

```sh
CHATGPT_APP_PATH="/Users/your-name/Applications/ChatGPT.app"
```

Spaces are supported. Saving proxy settings in the launcher preserves this value; restart ChatGPT Proxy to apply it. The **Current Status** report shows the ChatGPT App path used by the managed session.

The default bypass list contains localhost, loopback addresses, `.local`, private IPv4 ranges, and common local IPv6 ranges. Every bypass item can be changed or removed in the app.

The offline bridge integration test uses only loopback ports and a mock SOCKS5 server; it does not access the internet. The test itself needs Node on the development machine, but the app does not:

```sh
node tests/bridge.test.mjs
```
