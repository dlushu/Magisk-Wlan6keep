# wlan6keep — 熄屏保活 Wi-Fi IPv6（KernelSU / Magisk 模块）

ColorOS / Android 熄屏后会丢掉 IPv6？本模块用「静态地址 + 事件驱动自愈」把它按住。

## 解决的问题

Android（ColorOS 等）在**屏幕关闭**后会启用 Wi-Fi「挂起优化」（`mSuspendOptimizationsEnabled`），
驱动随之停止接收**组播帧**，于是：

- IPv6 的 **RA**（路由通告，发往 `ff02::1`）收不到 → SLAAC 地址得不到续期 → **地址过期被删**；
- **NDP**（邻居发现，solicited-node 组播）也一起失效 → 即使地址还在，对方也无法回包给你。

表现就是常见的「**熄屏一段时间后 IPv6 丢失，亮屏几十秒又回来**」。
（IPv4 不受影响，因此 Tailscale / adb 等纯单播业务在熄屏时依然正常。）

## 解决思路

为 `wlan0` 维护一个**静态全局 IPv6 地址 + 默认路由**：

- 静态地址 `valid_lft = forever`，**不依赖 RA**，所以熄屏也不会消失；
- 网络一有变化（链路 / 地址 / 路由事件）就把状态重新对齐一次，**秒级自愈**。

## 逻辑结构（三层，各司其职）

```
① 触发层   ip monitor address route（IPv4 + IPv6 的地址/路由事件）
              └─ 按接口名过滤 + 3 秒节流  →  调用 reconcile

② 收敛层   reconcile()：期望状态 = wlan0「有可用的全局 IPv6 + 有默认路由」
              ├─ iface_ready()      未连上 Wi-Fi → 直接返回
              ├─ learn_prefix()     从 /proc 学真前缀（真地址优先，自建地址仅作候补）
              ├─ learn_gateway()    有路由器信息 → 更新缓存
              ├─ real_global_v6()   系统已给真地址 → 拆掉多余静态地址，保留缓存 + 补路由
              ├─ probe_ok()         只能吃缓存前缀 → 用该前缀的地址探测公网
              │                     ├─ 通   → 补静态地址 + 路由（息屏救场）
              │                     └─ 不通 → drop_self_addr() + forget_prefix()
              └─ 都没有              → 绝不猜前缀，静待 RA

③ 支撑层   单职责小函数 + 日志
```

几个关键设计点：

- **监听不加 `dev` 过滤**：`ip monitor dev X` 是按 ifindex 过滤的，而 Wi-Fi 重连会让 `wlan0` 以
  **新的 ifindex** 重建，此时监听既不退出也不报错，却再也收不到事件（静默失效）。
  因此改为「订阅全部事件 + 按接口名过滤」。
- **监听不带 `-6`**：同时订阅 IPv4 事件。手机连上 Wi-Fi 时通常是**先拿到 IPv4、之后才有 RA**；
  若只听 IPv6，则「刚连上 Wi-Fi 且收不到 RA」时根本没有任何事件能唤醒模块。
- **`ensure_route()` 先查后写**：若无条件执行 `ip route replace`，内核每次都会广播
  `RTM_NEWROUTE`；而模块自己也监听 route 事件 → 形成**自激循环**，持续抖动路由表。
  这曾导致 **Tailscale 端点发现被反复打断、只能走 DERP 中继无法直连**，务必保持「先查后写」。
- **绝不硬编码兜底前缀**：早期版本在学不到前缀时退回一个写死的 `PREFIX_DEFAULT`，而
  `learn_prefix()` 又会跳过模块自建的地址以「避免自我确认」；一旦自建地址成了 wlan0 上唯一的
  全局地址，就永远学不到前缀，只能一路退回硬编码值，把设备锁死在早已失效的旧前缀上。
  现在改成：前缀只从系统学到（包括从模块自己之前补的那个地址上读前缀），学不到就不补地址。
- **用探测代替猜测**：缓存前缀是否还活着，只有一个可靠判据——拿它去 ping 一个公网 IPv6。
  通就继续用（息屏收不到 RA 但前缀没变，正是模块要救的场景）；不通就说明 ISP 换了前缀，
  立刻拆掉静态地址并忘掉该前缀。**宁可明确没有 IPv6，也不要留一个骗人的假地址**：假地址会让
  `netcheck` 报 `v6os=true` 而实际 `v6=false`，Tailscale 会当成可用端点对外宣告，比没有还糟。
- **不在 `ip addr show` 与 `/proc` 之间比字符串**：两者的 IPv6 文本形式不同（内核会省掉每组的前导零，
  `908` 与 `0908` 是同一个前缀）。早期实现拿"从地址文本反推的前缀"和"从 /proc 分组得到的前缀"
  做等值比较，结果永远不相等，会陷入「删掉 → 补上 → 再删掉」的抖动。
  现在前缀只由 `learn_prefix()` 从 `/proc` 单一来源写入，判断"要不要拆静态地址"也不再看前缀，
  而是看「系统有没有真地址」。

## 安装

环境要求：KernelSU（或 Magisk）+ root。

```sh
# 方式一：用 KernelSU / Magisk 管理器安装 release 里的 zip
# 方式二：克隆后自行打包
zip -r wlan6keep.zip module.prop service.sh
```

安装后**重启生效**（模块在 `late_start` 阶段自动启动）。

## 配置

`service.sh` 顶部：

| 变量 | 默认值 | 说明 |
|---|---|---|
| `IFACE` | `wlan0` | 目标网卡 |
| `HOSTPART` | `8888` | 静态地址主机段 → `<prefix>::8888` |
| `SELF_SUFFIX` | `:8888` | 从文本地址里认出模块自建地址用的后缀 |
| `DEBOUNCE` | `3` | 事件节流窗口（秒） |
| `PROBE_TARGET` | `2400:3200::1` | 前缀有效性探测目标（公网 IPv6，任何可用地址都行） |
| `PROBE_COUNT` | `3` | 探测包数（单包会因链路偶发丢包误判） |
| `PROBE_TIMEOUT` | `2` | 每个探测包的超时（秒） |
| `PROBE_INTERVAL` | `300` | 探测通过后的信任期（秒），期间不再重复打网 |

不再有 `PREFIX_DEFAULT` / `GW_DEFAULT`：前缀只从系统学到，学不到就不补地址。

## 运行状态与日志

```sh
# 运行日志
cat /data/adb/modules/wlan6keep/run.log
# 学到的前缀 / 网关缓存
cat /data/adb/modules/wlan6keep/state/*
# 当前地址与路由
ip -6 addr show wlan0
ip -6 route show table wlan0
```

日志里出现的 `ADD addr …` / `ADD route …` 表示模块**补过一次**；`learn prefix` / `learn gateway`
表示学到了新的前缀/网关；`offline -> drop cached prefix` 表示检测到掉线、旧前缀已作废。

## 排查：模块与其他网络组件（如 Tailscale）冲突

模块会修改 `wlan0` 的地址与路由，若它**过于频繁地写路由表**，会打断其他组件的网络监控
（典型症状：Tailscale 只能走 DERP、无法直连）。快速自查：

```sh
# 若这个数字在短时间内快速增长，说明有东西在频繁改路由
su -c 'grep -c "monitor: RTM_NEWROUTE" /data/adb/tailscale/run/tailscaled.log'
```

本模块的 `ensure_route()` 采用「先查后写」，正常情况下不会产生持续抖动。

## 已知边界

- 熄屏时系统的挂起优化依然存在（SLAAC 地址照旧会丢），模块只是用**静态地址**顶住；
- **外部主动访问手机**：当对端邻居缓存过期、需要重新做 NDP 时可能失败（对方发的是组播 NS）；
  手机**主动出站**不受影响；
- **换前缀后无法自愈到「有 IPv6」**：探测发现旧前缀已死会拆掉静态地址，但此后必须等系统
  重新收到 RA（亮屏 / Wi-Fi 重连）才会再学新前缀。Android 上没有 `ndisc6`/`rdisc6`，
  模块**没法主动发 RS 去催 RA**，这是当前最大短板；
- **有些机型根本收不到 RA**（真机实测：一加 PLC110 / ColorOS）。`tcpdump -i wlan0` 抓 30 秒，
  来自其他主机的组播帧**一条都没有**（RA、mDNS、MLD 查询全无），本机自己发的组播能抓到——
  说明 Wi-Fi 固件只放行 solicited-node 组播（`33:33:ff:xx:xx:xx`），不放行通用 IPv6 组播
  `33:33:00:00:00:01`（`ff02::1`，RA 的目标地址）。这类机型**永远学不到 RA**，
  也就永远不会有 SLAAC 地址，静态地址是唯一的 IPv6 来源；
  代价是前缀**只能靠缓存**，ISP 换前缀后模块会（正确地）拆掉死地址并忘掉前缀，
  此后需要人工把新前缀写进 `state/prefix` + `state/prefix_hex` 才能恢复。
  判断本机有没有这个毛病：`su -c 'ping6 -c 3 ff02::2%wlan0'`，
  若只回路由器而**从没出现过 SLAAC 地址**，基本就是了；
- **检测有窗口**：探测受 `PROBE_INTERVAL` 节流，前缀变化后最长一个周期内可能仍在使用已失效的
  前缀（此时表现为「有地址但出不去」）；
- 无定时兜底：极端情况下（netlink 事件被内核丢弃）需等下一个事件触发。

## 许可

MIT
