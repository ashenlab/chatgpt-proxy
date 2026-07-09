# Codex Proxy

一个 macOS 小启动器，用来让 Codex Desktop 只通过你指定的 SOCKS5 代理访问网络，而不修改系统代理、不开启全局 VPN，也不要求安装额外的分流软件。

## 项目目的

在一些网络环境下，Codex Desktop 需要通过海外代理才能正常登录、对话或访问插件市场。常见做法是打开系统全局代理、VPN，或者使用分流软件接管整机流量，但这些方式可能带来副作用：

- 其他国内网站或应用也被代理，访问变慢或异常。
- 系统 DNS、路由、证书、规则匹配被额外软件影响。
- 分流规则需要维护，且不同软件对系统流量的接管方式不完全透明。
- 调试 Codex 网络问题时，很难确认请求到底走了哪条链路。

这个项目的目标是把影响范围收窄到 Codex 本身：启动器只给 Codex 进程注入代理环境变量和 Chromium 启动参数，让 Codex 通过指定 SOCKS5 代理访问网络，机器上的其他软件仍然保持原来的网络行为。

## 优点

- 只影响 Codex Desktop，不改变系统全局代理。
- 不需要开启全局 VPN，也不依赖复杂分流软件。
- 支持多个 SOCKS5 代理配置。
- 支持本地 HTTP CONNECT bridge，改善某些内部 HTTP 客户端对 SOCKS5 支持不完整导致的问题，例如插件市场加载异常。
- 支持配置直连排除列表，例如本机地址、局域网地址、内网域名。
- 支持英文/中文界面快速切换，默认英文。
- 如果 Codex 已经在运行，会提示选择“退出并重启”“仍然启动”或“取消”，避免代理配置看起来变了但旧进程没有生效。
- 配置文件本地保存，私有配置默认不会进入 git。

## 文件说明

- `Codex Proxy.app`：原生 macOS 启动器界面。
- `CodexProxyLauncher.swift`：启动器 UI 源码。
- `codex-proxy-launch.sh`：实际启动 Codex 并注入代理参数的脚本。
- `socks-http-bridge.mjs`：本地 HTTP CONNECT 到 SOCKS5 的转发桥。
- `CodexProxyIcon.png`：原创生成的图标源图，不包含第三方品牌标志。
- `codex-proxy.conf.example`：公开配置模板。
- `codex-proxy.conf`：你的本地私有配置，已被 `.gitignore` 忽略。

## 使用方法

1. 复制配置模板：

   ```sh
   cp codex-proxy.conf.example codex-proxy.conf
   ```

2. 打开 `Codex Proxy.app`。
3. 在 `Proxies` 页面配置代理名称、SOCKS5 host、端口，以及是否启用 HTTP bridge。
4. 在 `Bypass` 页面配置不走代理的地址、域名、IP 或 CIDR。
5. 点击 `Save` 保存配置，或点击 `Launch Codex` 保存配置并启动 Codex。

`Use local HTTP bridge` 旁边的 `?` 按钮会解释这个选项的用途。简单来说，如果登录正常，但对话、app-server 请求或插件市场加载异常，可以尝试开启它。

界面里的修改会先保存在窗口内存中。`Save` 会写入 `codex-proxy.conf` 但不启动 Codex；`Launch Codex` 会先保存，再按当前配置启动 Codex；`Cancel` 会退出启动器，未保存的修改不会写入配置文件。

如果 Codex 已经在运行，启动器会提示你是否退出当前 Codex 并用新的代理配置重新启动。代理环境变量和 Chromium 代理参数只在进程启动时生效，因此修改配置后建议选择退出并重启。

如果 `codex-proxy.conf` 不存在，启动脚本会尽量从 `codex-proxy.conf.example` 自动创建一份。

## Codex 已经运行时

如果点击 `Launch Codex` 时检测到 Codex 已经在运行，启动器会显示三个选项：

- `Quit and Relaunch`：推荐。先温和退出正在运行的 Codex，再用当前代理配置重新启动，最能确保代理生效。
- `Launch Anyway`：不退出旧 Codex，仍然尝试启动。macOS 或 Codex 可能只是激活已有窗口，也可能创建第二个进程，因此新代理配置不一定会接管你正在使用的窗口。
- `Cancel`：取消启动。

日常使用建议选择 `Quit and Relaunch`。

## When Codex Is Already Running

If Codex is already running, `Quit and Relaunch` is recommended because proxy settings only apply when the Codex process starts. `Launch Anyway` may only activate the existing window or create a second process, so the selected proxy may not take effect.

## 配置建议

如果 Codex 登录正常，但对话或插件市场超时，可以尝试为对应代理开启 `Use local HTTP bridge`。这会让 `HTTP_PROXY`、`HTTPS_PROXY`、`ALL_PROXY` 指向本地 HTTP bridge，再由 bridge 转发到 SOCKS5 代理。

常见直连排除项包括：

```text
localhost
127.0.0.1
::1
*.local
10.0.0.0/8
172.16.0.0/12
192.168.0.0/16
fc00::/7
fe80::/10
```

## 隐私与配置文件

真实代理配置保存在本机的 `codex-proxy.conf` 中，可能包含私有代理地址、内网域名或个人网络信息。这个文件已被 `.gitignore` 忽略，仓库只提供 `codex-proxy.conf.example` 作为公开模板。

## 构建

这个 App 是单文件 AppKit 程序，可以用系统自带 Swift 编译器重新构建，不需要第三方依赖：

```sh
mkdir -p .build/clang-module-cache
CLANG_MODULE_CACHE_PATH=.build/clang-module-cache \
  swiftc -framework Cocoa CodexProxyLauncher.swift \
  -o "Codex Proxy.app/Contents/MacOS/CodexProxyLauncher"
```

## English

Codex Proxy is a small macOS launcher for starting Codex Desktop with per-app proxy settings. It lets Codex use a SOCKS5 proxy without changing the system proxy, enabling a global VPN, or routing other applications through proxy/splitting software.

It supports multiple SOCKS5 profiles, an optional local HTTP CONNECT bridge, an editable bypass list, English/Chinese UI switching, and a prompt for relaunching Codex when it is already running.

Use `codex-proxy.conf.example` as the public template. Keep your real `codex-proxy.conf` private.
