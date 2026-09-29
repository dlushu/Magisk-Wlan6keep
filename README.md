# Magisk-Wlan6keep — 熄屏保活 Wi-Fi IPv6（KernelSU / Magisk 模块）

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
① 触发层   ip monitor link address route（链路 + IPv4/IPv6 的地址/路由事件）
              └─ 按接口名过滤 + 3 秒节流  →  调用 reconcile
              └─ MONITOR_WINDOW 周期兜底：单次监听最长 60 秒，到点主动断开重连，
                 即使 netlink 事件被丢掉，也会周期性醒来收敛一次

② 收敛层   reconcile()：期望状态 = wlan0「有可用的全局 IPv6 + 有默认路由」
              ├─ iface_ready()      未连上 Wi-Fi → 直接返回
              ├─ learn_gateway()    返回「换没换网关」→ 换了就拆地址 + 作废前缀（确定性事件）
              ├─ learn_prefix()     从 /proc 学真前缀（真地址优先，自建地址仅作候补）
              ├─ real_global_v6()   系统已给真地址 → 拆掉多余静态地址，保留缓存 + 补路由
              ├─ 只能吃缓存前缀     → 补静态地址 + 路由（息屏救场）
              │                     ├─ probe_report()   收集可达性证据（单次失败不判决）
              │                     └─ probe_verdict()  强证据（连续 N 次 + 跨 T 时间）
              │                                          → 拆地址 + 作废前缀
              └─ 都没有              → 绝不猜前缀，静待 RA

③ 支撑层   单职责小函数 + 日志
```

几个关键设计点：

- **监听不加 `dev` 过滤**：`ip monitor dev X` 是按 ifindex 过滤的，而 Wi-Fi 重连会让 `wlan0` 以
  **新的 ifindex** 重建，此时监听既不退出也不报错，却再也收不到事件（静默失效）。
  因此改为「订阅全部事件 + 按接口名过滤」。
- **监听不带 `-6`**：同时订阅 IPv4 事件。手机连上 Wi-Fi 时通常是**先拿到 IPv4、之后才有 RA**；
  若只听 IPv6，则「刚连上 Wi-Fi 且收不到 RA」时根本没有任何事件能唤醒模块。
- **`ip` / `ping6` 一律用绝对路径**：KernelSU 用 `ASH_STANDALONE=1 /data/adb/ksu/bin/busybox
  sh service.sh` 拉起本脚本，而 busybox sh 的 standalone 模式会**优先命中它自带的 applet**——
  `ip` 被解析成 busybox 的精简实现，**即使 `PATH` 里明明有 `/system/bin/ip` 也一样被遮蔽**（实测
  确认）。由此引出两个静默故障：`ip monitor` 没有这个子命令 → 秒退，主循环退化成每 5 秒空转；
  `ip -6 addr add … nodad` 不认 `nodad` → 报 `'nodad' is garbage` 后失败，若被 `2>/dev/null` 吞掉，
  地址就永远补不上、日志里只剩 `probe failed`。所以脚本里用 `IP=/system/bin/ip`、
  `PING6=/system/bin/ping6` 两个常量，所有调用走绝对路径（绝对路径不参与 applet 匹配）。
- **`ensure_route()` 先查后写**：若无条件执行 `ip route replace`，内核每次都会广播
  `RTM_NEWROUTE`；而模块自己也监听 route 事件 → 形成**自激循环**，持续抖动路由表。
  这曾导致 **Tailscale 端点发现被反复打断、只能走 DERP 中继无法直连**，务必保持「先查后写」。
- **绝不硬编码兜底前缀**：早期版本在学不到前缀时退回一个写死的 `PREFIX_DEFAULT`，而
  `learn_prefix()` 又会跳过模块自建的地址以「避免自我确认」；一旦自建地址成了 wlan0 上唯一的
  全局地址，就永远学不到前缀，只能一路退回硬编码值，把设备锁死在早已失效的旧前缀上。
  现在改成：前缀只从系统学到（包括从模块自己之前补的那个地址上读前缀），学不到就不补地址。
- **前缀作废要「强证据」**：网关（路由器）变了，就说明换了网络或换了路由器，旧前缀必然不属于
  当前链路——此时才拆掉静态地址并作废前缀。**宁可明确没有 IPv6，也不要留一个骗人的假地址**：
  假地址会让 `netcheck` 报 `v6os=true` 而实际 `v6=false`，Tailscale 会当成可用端点对外宣告，
  比没有还糟。
- **保守失效判定，兜住「网关没变但 ISP 换了前缀」**：同一个路由器轮换 PD 前缀时网关不变，
  上面那条判据不触发，模块就会一直拿旧前缀补地址（假地址）。所以再加一道兜底：
  `probe_report()` 只在失败时**累积证据**，只有「连续 `PROBE_FAIL_LIMIT` 次失败 **且** 这串
  失败跨越 `PROBE_FAIL_WINDOW`」这种强证据，才由 `probe_verdict()` 判死并拆地址 + 作废前缀。
  **单次失败绝不判死**——早期版本正是拿单次失败判死，而失败成因太多（息屏挂起丢包、刚补的
  地址还在 DAD、系统那条 RA 默认路由已随地址一起消失……），一次误判就删掉好地址、永久忘记
  前缀，从此再不工作。三道护栏：地址刚补上后有 `ADDR_GRACE` 观察期不计入；地址补失败
  （`Cannot assign requested address`）时干脆不探测；探测一旦通过就把证据清零。
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
zip -r Magisk-Wlan6keep.zip module.prop service.sh
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
| `PROBE_TARGET` | `2400:3200::1` | 探测目标（公网 IPv6，任何可用地址都行） |
| `PROBE_COUNT` | `3` | 探测包数（单包会因链路偶发丢包，多打两个日志更可信） |
| `PROBE_TIMEOUT` | `2` | 每个探测包的超时（秒） |
| `PROBE_INTERVAL` | `300` | 探测节流窗口（秒）：两次探测至少隔这么久，避免反复打外网 |
| `MONITOR_WINDOW` | `60` | 单次监听的最长时间（秒）：到点主动断开重连，作为「事件丢了」的周期兜底 |
| `PROBE_FAIL_LIMIT` | `3` | 保守失效判定：连续失败达到这个次数才考虑判死（单次失败绝不判死） |
| `PROBE_FAIL_WINDOW` | `900` | 保守失效判定：这串失败还必须跨越这么久（秒），避免踩到一段短时抖动 |
| `ADDR_GRACE` | `60` | 地址刚补上后的观察期（秒）：期间探测失败不计入（DAD / 路由未就绪） |

不再有 `PREFIX_DEFAULT` / `GW_DEFAULT`：前缀只从系统学到，学不到就不补地址。
前缀作废有两条判据：**网关变化**（确定性事件，立刻作废）与**保守失效判定**（连续
`PROBE_FAIL_LIMIT` 次探测失败且跨越 `PROBE_FAIL_WINDOW`，见「关键设计点」）。

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

日志里出现的 `ADD addr …` / `ADD route …` 表示模块**补过一次**；`DEL addr …` 表示拆掉了静态
地址（系统给了真地址，换了网关，或判定了前缀已死）；`learn prefix` / `learn gateway` 表示学到
了新的前缀/网关；`probe ok` / `probe failed` 记可达性，连续失败会累积证据（`streak n/N`），
攒够强证据后由 `verdict:` 那条判定前缀已死。

## 排查：前缀变了，模块没跟上

典型现象：ISP 轮换了 PD 前缀，模块还在用旧前缀补地址，日志里 `probe failed` 反复刷。
模块现在会自己判定并**诚实退回「没有 IPv6」**，但**不会自动学会新前缀**（原因见「已知边界」），
所以这一步的目标是人工把新前缀喂给它。

```sh
# ① 看日志：probe failed 反复出现 = 典型的假地址（旧前缀）
su -c 'tail -20 /data/adb/modules/wlan6keep/run.log'

# ② 看内核有没有收到过 RA：为空 = 内核从没收到 RA（本类机型的常态）
su -c 'ip -6 route show | grep "proto ra"'

# ③ 手机侧催一次 RS 并抓包（两个窗口）
su -c 'tcpdump -i wlan0 -n -e icmp6'                       # 窗口 A
su -c 'echo 1 > /proc/sys/net/ipv6/conf/wlan0/disable_ipv6; \
       sleep 3; echo 0 > /proc/sys/net/ipv6/conf/wlan0/disable_ipv6'   # 窗口 B：催 RS
# 手机侧看不到 RA（连组播都没有）→ 看 ④

# ④ 确认是「组播被 Wi-Fi 固件丢掉」而不是路由器没发
su -c 'ip -s link show wlan0'          # 看 RX 的 mcast 计数：长期为 0 即是
su -c 'dumpsys wifi | grep -i multicast'   # Multicast Locks held: 为空
# 想坐实路由器在发：在路由器上同时抓 `tcpdump -i br-lan -n -vvv "icmp6 and ip6[40] == 134"`，
# 应能看到 RA 正带着新前缀发往 ff02::1
```

**人工 seed 新前缀**（当前唯一可行的恢复路径）：模块会在下个事件周期（≤ `MONITOR_WINDOW` 60 秒）
自己把地址补上。

```sh
# state/prefix      = 前缀的文本形式，每组补足 4 位、以 :: 结尾
# state/prefix_hex  = 前 64 位的 16 位十六进制（去掉冒号），用于存在性判断
su -c 'printf "%s\n" "2408:844c:090c:083e::" > /data/adb/modules/wlan6keep/state/prefix'
su -c 'printf "%s\n" "2408844c090c083e"   > /data/adb/modules/wlan6keep/state/prefix_hex'
# 顺手清掉旧前缀留下的探测证据，免得攒够次数立刻把新前缀判死
su -c 'rm -f /data/adb/modules/wlan6keep/state/probe_ts \
              /data/adb/modules/wlan6keep/state/probe_fail_cnt \
              /data/adb/modules/wlan6keep/state/probe_fail_since'

# 触发一次收敛并确认（也可直接等 MONITOR_WINDOW 兜底）
su -c 'ip -6 addr show dev wlan0 | grep 8888'    # 应看到 <prefix>::8888
su -c 'ping6 -c 3 -I 2408:844c:090c:083e::8888 2400:3200::1'   # 应通
```

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
- **换前缀后不会自动学回新前缀**：网关变化或保守失效判定会拆掉静态地址并作废前缀，但此后
  必须重新学到新前缀才能恢复，而「学到」依赖系统收到 RA —— 本机收不到 RA（见下条），
  所以实际只能人工 seed。模块也**没有可用的催 RA 路径**：Android 上无 `ndisc6`/`rdisc6`
  （`disable_ipv6` 1→0 能逼内核发 RS，实测路由器也立刻回了 RA，但回的是组播，本机收不到）。
  这是当前最大短板；
- **同一路由器换 PD 前缀：会诚实地退回「没有 IPv6」，但不会自动学回**：网关没变时，靠
  「连续 N 次探测失败 + 跨 T 时间」的保守失效判定拆地址、作废前缀（见「关键设计点」），
  而不是继续拿旧前缀糊一个假地址。恢复正常仍需 RA 或人工 seed；
- **有些机型收不到任何 IPv6 组播，因而永远学不到 RA**（真机实测：一加 PLC110 / ColorOS）。
  2026-09-29 在手机侧与路由器侧**同时抓包**定位到的事实：

  - 路由器**一直在正确通告新前缀**：每 10~25 秒一次，源 `fe80::…`，目标 `ff02::1`，
    PIO 是该前缀的 `/64` 且带 A 标志、router lifetime 3600s，还带 RDNSS；手机每发一次 RS
    （`link/address/route` 事件或 `disable_ipv6` 1→0 都会触发）路由器都立刻回一个 RA；
  - 手机内核**确实加入了** `ff02::1`（`ip maddr show dev wlan0` 里同时有 `33:33:00:00:00:01`
    与 `inet6 ff02::1`），但驱动计数器**长期为 0**（开机 7.4 小时后 `ip -s link show wlan0`
    的 `RX mcast` 仍是 0），`dumpsys wifi` 里 `rxMulticast 0 / icmp6Ra 0`、
    `Multicast Locks held:` 为空 —— 组播帧在**进入内核之前就被 Wi-Fi 固件/HAL 丢掉**了
    （Android 只在有应用持有 `WifiMulticastLock` 时才放行组播）；
  - 同一台 AP 上另一台无线客户端能正常 SLAAC 到该前缀 ⇒ **不是 AP、也不是路由器的问题**，
    是这台手机自己的 Wi-Fi 栈。

  结论：这类机型**永远学不到 RA**，不会有 SLAAC 地址，静态地址是唯一的 IPv6 来源，
  代价是前缀**只能靠缓存**（ISP 换前缀后要人工 seed，步骤见下节）。自查：
  `su -c 'ip -s link show wlan0'` 看 `mcast` 是否长期为 0，或
  `su -c 'dumpsys wifi | grep -i multicast'` 看是否没持有 MulticastLock；
- **「让路由器用单播回 RA」在本拓扑下走不通**（2026-09-29 查证）：单播 RA 只有 odhcpd 的
  `ra=server` 模式才会回 —— 源码里 `handle_icmpv6()` 只对 `MODE_SERVER` 调
  `send_router_advert(iface, &from->sin6_addr)`；`ra=relay` 模式收到 RS 只是向上游转发 RS，
  上来的 RA 一律由 `forward_router_advertisement()` 发往 `ff02::1`（`ALL_IPV6_NODES` 写死）。
  本机所处网络的 LAN 恰好就是 `ra=relay`，所以「单播 RA」这条路由器的固有行为给不了。要改
  `ra=server`，br-lan 上得有该前缀的全局地址，而上游是**用 RA 下发前缀、没有 DHCPv6-PD**，
  br-lan 并没有这个地址 —— 意味着还要再写个守护脚本随上游前缀变化给 br-lan 配地址，
  影响面是整个局域网的 IPv6，得不偿失；
- **换网关的检测有窗口**：网关缓存来自邻居表，邻居项会随 `gc_stale_time` 老化，
  短时内可能读不到新网关，此时最长要等下一次网络事件才会纠正；
- **兜底是周期性的，但不是即时的**：`MONITOR_WINDOW`（默认 60 秒）会在没有事件时主动重连监听并
  收敛一次，覆盖「netlink 事件被内核丢弃」的极端情况；但收敛最快也要等这一个窗口，不是秒级。

## 许可

MIT
