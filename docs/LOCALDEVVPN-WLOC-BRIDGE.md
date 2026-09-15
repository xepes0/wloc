# WLOC-enabled LocalDevVPN Bridge

> 状态：实现契约已固定，LocalDevVPN 集成尚未完成真机构建。

## 为什么改成这个方向

Safari 没有 raw TCP socket，也没有 Bonjour/mDNS browse API。即使 LocalDevVPN 已经把 `10.7.0.1` 反射回设备自身，网页仍然不能直接和 RemotePairing/RSD/DVT 对话。

LocalDevVPN 当前的 PacketTunnelProvider 已经提供了我们需要的 device tunnel 基础：默认 interface 是 `10.7.1.1/32`，peer 是 `10.7.0.1/32`，进入 tunnel 的 IPv4 packet 会交换 source/destination 后写回设备。新版 WLOC 不再试图让 Safari 重写整套 `idevice` 协议，而是把 CoreDevice 执行端放进一个 WLOC-enabled LocalDevVPN build。

目标链路：

```text
WLOC Web
  -> localdevvpn://wloc/set?...         (URL Scheme)
  -> LocalDevVPN app
  -> LocalDevVPN 10.7.0.1 tunnel
  -> RemotePairing
  -> TLS-PSK / RSD
  -> DVT RemoteServer
  -> LocationSimulation.set()
```

恢复：

```text
WLOC Web
  -> localdevvpn://wloc/clear
  -> LocationSimulation.clear()
```

这样不需要 USB、电脑或同一局域网，也不要求 Safari 获得 raw TCP。

## 现有 LocalDevVPN 可以复用什么

现有 LocalDevVPN 已经注册 `localdevvpn://` URL Scheme，并在 SwiftUI `.onOpenURL` 中处理 `enable` / `disable`。WLOC bridge 只需要把相同 handler 扩展为 host `wloc`：

- `localdevvpn://wloc/pair`
- `localdevvpn://wloc/set`
- `localdevvpn://wloc/clear`
- `localdevvpn://wloc/status`

参考解析代码见 `bridge/localdevvpn/WLOCBridgeProtocol.swift`。

## URL Bridge v1

所有请求都必须包含：

- `v=1`
- `request=<随机 request id>`
- `callback=<HTTPS WLOC 页面地址>`

### Pair

```text
localdevvpn://wloc/pair?v=1&request=...&callback=...
```

LocalDevVPN 应：

1. 创建一份新的 RPPairing host record；
2. 启动本机 TCP listener；
3. 发布 `_remotepairing-pairable-host._tcp.` Bonjour service；
4. 引导用户进入 iOS 27 的 Pair with Host；
5. 完成 SRP/Remote Pairing；
6. 将 pairing record 安全存储在本机；
7. callback 返回 `status=ok`。

Roam-Control 当前实现已经证明这种 on-device pairing 流程可行。不要把 pairing record 放进 callback、URL、Cloudflare 或 analytics。

### Set

```text
localdevvpn://wloc/set?v=1&request=...&callback=...&latitude=34.052235&longitude=-118.243683
```

LocalDevVPN 应：

1. 校验坐标；
2. 确认已有本机 pairing record；
3. 启动/确认 LocalDevVPN tunnel；
4. 发现 `_remotepairing._tcp.`；
5. 用 pairing record 的 AltIRK 校验 `identifier/authTag`；
6. pair verify；
7. 创建安全 tunnel，执行 RSD handshake；
8. 打开 DVT RemoteServer；
9. `LocationSimulation.set(latitude, longitude)`；
10. 保持 session；
11. callback 返回 `status=ok`。

### Clear

```text
localdevvpn://wloc/clear?v=1&request=...&callback=...
```

必须调用 `LocationSimulation.clear()` 并明确等待设备确认，然后再返回成功。

### Status

```text
localdevvpn://wloc/status?v=1&request=...&callback=...
```

只返回窄状态码，例如：

- `ready`
- `not_paired`
- `tunnel_off`
- `session_active`
- `session_inactive`

不要把 UDID、pairing identifier、端口、AltIRK 或原始错误字符串塞进 URL。

## Callback

App 完成请求后打开原始 HTTPS callback，并添加：

```text
status=ok|error
code=<固定错误码，可选>
```

WLOC 页面已经带 `request` 和 `op`，并会校验返回的 request id。

建议错误码固定为有限集合：

```text
not_paired
pairing_failed
local_network_denied
tunnel_failed
service_not_found
pair_verify_failed
rsd_failed
dvt_failed
location_rejected
clear_failed
background_unavailable
```

不要把 `Error.localizedDescription` 原样放进 callback URL。

## CoreDevice engine 放在哪里

第一版不要过早锁死在 PacketTunnelProvider。

### A. 主 App 进程（优先 PoC）

优点：

- 与 Roam-Control 已验证结构最接近；
- `NetService` browse/publish、Keychain、UI 引导都容易实现；
- 可直接验证 `10.7.0.1` + RemotePairing + DVT 是否工作。

缺点：Safari 回来后主 App 可能被 iOS suspend。第一版只需要验证 `set/clear` 与 session 生命周期；若 suspend 会结束模拟，再进入下一阶段。

### B. 主 App + background location keepalive

Roam-Control 使用低精度 CoreLocation updates 保持 app 活跃，DVT 仍是唯一模拟位置来源。这个方案需要 `location` background mode 和系统定位授权，会增加权限成本，但行为已经有可参考实现。

### C. PacketTunnelProvider 内持续执行 CoreDevice

理论上最漂亮，因为 VPN extension 在 tunnel 开启时持续运行。但必须真机验证：Network Extension 自己创建到 `10.7.0.1` 的 socket 是否会走/绕过自己的 packet tunnel，以及是否会造成自引用路由。未验证前不要把它作为唯一实现。

## 配对数据安全

必须仅本机保存：

- RPPairing record
- AltIRK
- host private material
- TLS-PSK / derived encryption key
- device identity

推荐 Keychain。若 Network Extension 后续需要 pairing record，可以在主 App 每次命令启动时通过受控 provider message 传入内存，不要为了方便先把 pairing record 放进 `providerConfiguration`。

## 真机验证顺序

1. WLOC-enabled LocalDevVPN 能处理 `localdevvpn://wloc/status` 并 callback；
2. `pair` 能在同一台 iPhone 完成 Pair with Host；
3. 开启 LocalDevVPN 后能发现 `_remotepairing._tcp.`；
4. `set` 能在 iOS 27 正式版改变 Maps / CoreLocation 报告位置；
5. 切回 Safari 后观察 session 是否持续 30 秒、2 分钟、锁屏后是否持续；
6. `clear` 恢复真实位置；
7. Wi-Fi 与蜂窝分别验证；
8. 再决定 keepalive 或 PacketTunnelProvider host。

## 不做的事情

- 不回退 `gs-loc.apple.com` MITM；
- 不把 pairing record 上传 Worker；
- 不让网页假装成功；
- 不依赖 USB；
- 不依赖电脑和 iPhone 同 LAN；
- 不在未经验证前声称原版/App Store LocalDevVPN 已支持 WLOC bridge。
