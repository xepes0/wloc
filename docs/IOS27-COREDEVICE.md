# WLOC iOS 27 CoreDevice 路线

> 状态：实验性架构，尚未宣称真机可用。目标是不再依赖 `gs-loc.apple.com` MITM。

## 目标约束

新版路线以这些约束为设计目标：

- iOS 27 正式版；
- 不安装 Roam Control / Locus 一类额外定位 IPA；
- 不插 USB；
- 不依赖电脑与 iPhone 位于同一局域网；
- 可以安装并启用 LocalDevVPN；
- 继续复用 WLOC 的网页选点、链接解析、坐标系转换、收藏和快捷指令入口。

## 旧链路只保留为 legacy backend

旧 WLOC：

```text
网页
  -> gs-loc.apple.com/wloc-settings/save
  -> 代理脚本保存 wloc_settings
  -> MITM /clls/wloc 响应
  -> locationd 消费修改后的网络定位
```

iOS 27 CoreDevice 页面不得自动回退到这条链路，避免“网页显示成功但系统定位没有变化”的假阳性。

## 新链路

Roam-Control 已验证的目标协议路径仍然是：

```text
RemotePairing
  -> pair verify
  -> TLS-PSK tunnel
  -> RSD
  -> DVT RemoteServer
  -> LocationSimulation.set(latitude, longitude)
```

恢复真实位置使用 `LocationSimulation.clear()`。

真正变化的是**谁执行这套协议**。

### 最初方案：Browser Transport（不再作为主路线）

Safari 没有 raw TCP socket 和 Bonjour/mDNS browse API。即使 LocalDevVPN 把 `10.7.0.1` 反射回设备自身，网页仍不能直接和 RemotePairing 服务对话。为了补这个缺口而在浏览器里重写 `idevice` + WASM + WebSocket/TCP bridge，工程复杂度太高。

### 当前主路线：WLOC-enabled LocalDevVPN

LocalDevVPN 当前 App 已经注册 `localdevvpn://` URL Scheme，而且本身就是 10.7.0.1 device tunnel 的提供者。因此新版 WLOC 改成：

```text
WLOC Web
  -> localdevvpn://wloc/set?...       # 选点/控制
  -> WLOC-enabled LocalDevVPN         # Native CoreDevice engine
  -> 10.7.0.1 device tunnel
  -> RemotePairing
  -> RSD
  -> DVT
  -> LocationSimulation
```

这让 Safari 只负责 UI 和命令，不需要 raw TCP，也不需要持有 pairing record。

**注意：当前原版/App Store LocalDevVPN 尚未实现 `wloc` host；需要集成 WLOC bridge 的构建。**

完整 URL contract 和 LocalDevVPN 集成说明见 `docs/LOCALDEVVPN-WLOC-BRIDGE.md`。

## Bridge v1

固定操作：

```text
localdevvpn://wloc/pair
localdevvpn://wloc/set
localdevvpn://wloc/clear
localdevvpn://wloc/status
```

所有请求带：

```text
v=1
request=<随机 request id>
callback=<HTTPS WLOC callback>
```

`set` 额外带：

```text
latitude=<WGS84>
longitude=<WGS84>
```

App 完成后只回传窄状态：

```text
status=ok|error
code=<固定错误码，可选>
```

Pairing record、AltIRK、UDID、PSK、原始错误、CoreDevice service 身份不得放 URL。

## 安全边界

以下内容必须只保存在设备本地执行环境，不得写入 Cloudflare Worker、日志、Analytics 或 callback URL：

- Remote Pairing record；
- AltIRK；
- TLS-PSK / encryption key；
- 设备配对私钥；
- 未脱敏的 CoreDevice 身份信息。

Worker 继续只承担静态页面、地图链接解析和不含配对秘密的能力描述。

## 当前代码状态

`ios27-coredevice` 分支已经有：

- `/ios27` 独立入口；
- 与旧 `SAVE_API` 完全解耦；
- `localdevvpn://wloc/pair|set|clear|status` 前端；
- request id + HTTPS callback；
- callback request 校验；
- `/api/ios27/capabilities`；
- `bridge/localdevvpn/WLOCBridgeProtocol.swift` URL 解析参考；
- `docs/LOCALDEVVPN-WLOC-BRIDGE.md` LocalDevVPN 集成契约；
- CI 回归测试，确保新页面不偷偷恢复旧保存代码。

## 接下来真正要做的事

### Phase 2A — WLOC-enabled LocalDevVPN PoC

在 LocalDevVPN App target 中实现：

1. 扩展 `.onOpenURL`，处理 host `wloc`；
2. `status` 能 callback；
3. `pair` 复现 Roam-Control 的 on-device pairing；
4. pairing record 只存本机 Keychain；
5. `set` 开启/确认 LocalDevVPN 后发现 `_remotepairing._tcp.`；
6. pair verify → TLS-PSK → RSD → DVT；
7. `LocationSimulation.set()`；
8. `clear()`；
9. callback 返回固定状态码。

### Phase 2B — 生命周期

第一版 CoreDevice engine 先跑在主 App 进程，因为它与 Roam-Control 已验证结构最接近。真机验证切回 Safari 后 session 是否会因 suspend 中断。

如果会中断，再二选一：

- 使用 background CoreLocation keepalive；
- 验证 CoreDevice engine 是否能安全迁到 PacketTunnelProvider 长驻运行。

不能未经真机测试就假定 Network Extension 对自己的 `10.7.0.1` socket 会正常回环。

### Phase 3 — 接回完整 WLOC UI

等 `pair/set/clear` 真机闭环成立后，把旧页面的地图、收藏、搜索和快捷指令接到同一个 deep-link bridge，不再保留手输坐标作为主入口。

## 当前判定

剩余阻塞已经不再是“Safari 怎么拿 raw TCP”，而是一个更小、可验证的问题：

> **能否把已知可行的 Roam-Control CoreDevice engine 集成进 LocalDevVPN，并在 iOS 27 正式版上保持定位 session。**

这个问题一旦打通，就满足“不装单独定位 App、不 USB、不依赖同 LAN”的目标；用户侧只需要一个 WLOC-enabled LocalDevVPN。
