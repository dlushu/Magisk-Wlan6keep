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

② 收敛层   reconcile()：期望状态 = wlan0「有全局 IPv6 + 有默认路由」
              ├─ iface_ready()      未连上 Wi-Fi → 作废旧前缀缓存后返回
              ├─ learn_prefix()     有真实前缀 → 更新缓存
              ├─ learn_gateway()    有路由器信息 → 更新缓存
              ├─ has_global_v6 || ensure_addr()   缺地址 → 补静态地址
              └─ ensure_route()     缺路由 → 补默认路由（先查后写）

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
- **掉线作废旧前缀**：换网络后旧前缀不可信，避免用上一个网络的前缀补出一个不可路由的地址；
  熄屏不会掉线，因此不影响核心场景。

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
| `HOSTPART_HEX` | `0000000000008888` | 上者的 16 位十六进制（用于识别模块自建地址） |
| `DEBOUNCE` | `3` | 事件节流窗口（秒） |
| `PREFIX_DEFAULT` | `2408:844c:908:a4c4::` | 兜底前缀（正常会从系统自动学习，仅首次安装时用到） |
| `GW_DEFAULT` | `fe80::9683:c4ff:fee4:664d` | 兜底网关（同上） |

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
- ISP 更换 IPv6 前缀后会重新学习，但**旧前缀的静态地址不会自动移除**；
- 无定时兜底：极端情况下（netlink 事件被内核丢弃）需等下一个事件触发。

## 许可

MIT
