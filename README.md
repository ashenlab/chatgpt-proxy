# ChatGPT Proxy

[English](#english) | 简体中文

一个原生 macOS 启动器，让 **ChatGPT Desktop** 仅通过指定的 SOCKS5 代理访问网络。它不会修改系统代理、不会开启全局 VPN，也不需要额外的分流软件。

## 为什么使用它？

有些网络环境中，ChatGPT Desktop 需要代理才能正常登录、对话或访问插件市场。系统全局代理、VPN 或分流软件会影响整台机器的流量，可能让国内服务、DNS、路由或其他应用出现不必要的延迟和异常。

ChatGPT Proxy 只在启动 ChatGPT 时注入代理环境变量与 Chromium 代理参数。ChatGPT 走指定 SOCKS5 代理，机器上的其他应用继续按原来的网络路径访问。

## 功能

- 仅代理 ChatGPT Desktop，不改动系统网络设置。
- 可保存多个 SOCKS5 配置，支持用户名/密码认证。
- 可配置直连排除项，包括本机、局域网、域名、IP 和 CIDR。
- 可选本地 HTTP CONNECT bridge，改善部分内部 HTTP 客户端对 SOCKS5 支持不完整造成的对话或插件市场异常。
- 原生 AppKit 界面，支持英文/中文快速切换。
- 当 ChatGPT 已运行时提示退出并重新启动，避免代理配置未真正生效。

## 要求

- macOS 10.13 或更高版本。
- 已安装新版 ChatGPT Desktop，路径为 `/Applications/ChatGPT.app`。
- 可用的 SOCKS5 服务端；认证为可选项。

旧版 `/Applications/Codex.app` 不受支持。

## 安装与使用

1. 从 [Releases](../../releases) 下载 `ChatGPT.Proxy.app.zip`。
2. 解压后，把 `ChatGPT Proxy.app` 拖到 `/Applications`。从旧版升级时，可在确认新版本正常后删除旧的 `Codex Proxy.app`。
3. 打开 `ChatGPT Proxy.app`，首次运行时按 macOS 提示允许本地网络访问。
4. 在 `Proxies` 中填写 SOCKS5 主机、端口和可选认证信息；按需启用 `Use local HTTP bridge`。
5. 在 `Bypass` 中填写应直接连接的主机、域名、IP 或 CIDR。
6. 点击 `Save` 仅保存配置，或点击 `Launch ChatGPT` 保存并以当前配置启动 ChatGPT。

配置只在 ChatGPT 启动时读取。若 ChatGPT 已在运行，推荐选择 `Quit and Relaunch`，以确保当前代理生效。

## HTTP bridge

正常情况下，ChatGPT 的 Chromium 网络请求可直接使用 SOCKS5。部分内部 HTTP 客户端对 SOCKS5 环境变量的支持不完整时，可能出现登录正常但对话、内部请求或插件市场超时/加载不完整的情况。

为对应代理启用 `Use local HTTP bridge` 后，启动器只在本机 `127.0.0.1` 上临时启动一个 HTTP CONNECT bridge，再将流量转发至该 SOCKS5 服务器。bridge 会随 ChatGPT 进程结束而停止；启动器不会改动系统 HTTP 代理。

## 配置与隐私

本地配置位于：

```text
~/Library/Application Support/ChatGPT Proxy/chatgpt-proxy.conf
```

首次从旧版启动器升级时，会自动复制旧的本地配置到新目录。该迁移仅用于保留你的配置；启动器不会再启动旧版 Codex Desktop。

真实配置可能含有代理地址、内网规则和认证信息。请勿提交或分享它；仓库只提供公开的 [chatgpt-proxy.conf.example](chatgpt-proxy.conf.example) 模板。

默认直连排除项包含 `localhost`、回环地址、`.local`、私有 IPv4 网段与常见本地 IPv6 网段。所有排除项均可在界面中修改或删除。

## 项目结构

- `ChatGPTProxyLauncher.swift`：原生 AppKit 启动器。
- `chatgpt-proxy-launch.sh`：启动 ChatGPT 并注入代理参数。
- `socks-http-bridge.mjs`：本地 HTTP CONNECT 到 SOCKS5 的桥接程序。
- `chatgpt-proxy.conf.example`：公开配置模板。

## 构建

发布包已包含可直接使用的应用。源码使用系统 Swift/AppKit；bridge 会优先使用 ChatGPT Desktop 内置的 Node，因此不要求安装 Node 或其他第三方依赖。

## English

ChatGPT Proxy is a native macOS launcher that starts **ChatGPT Desktop** with per-app SOCKS5 proxy settings. It does not change the system proxy, enable a global VPN, or route other applications through split-tunneling software.

It supports multiple SOCKS5 profiles, optional username/password authentication, editable bypass rules, a local HTTP CONNECT bridge, and English/Chinese UI switching. The launcher targets `/Applications/ChatGPT.app` only; legacy `Codex.app` is not supported.

Download `ChatGPT.Proxy.app.zip` from [Releases](../../releases), move the app to `/Applications`, configure a proxy, then choose **Launch ChatGPT**. Your private configuration is stored at:

```text
~/Library/Application Support/ChatGPT Proxy/chatgpt-proxy.conf
```

Do not publish that file. The repository contains only the safe [configuration template](chatgpt-proxy.conf.example).
