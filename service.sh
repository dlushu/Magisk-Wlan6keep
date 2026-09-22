#!/system/bin/sh
# ============================================================
# WiFi IPv6 Keepalive - KernelSU / Magisk module
#
# 解决的问题：
#   ColorOS/Android 熄屏后会启用 Wi-Fi "挂起优化"，驱动停止接收组播帧，
#   于是 IPv6 的 RA(ff02::1) 收不到 → SLAAC 地址过期被删
#   → 表现为「熄屏一段时间后 IPv6 丢失」。
#
# 解决办法：
#   给 wlan0 维护一个静态全局 IPv6 地址 + 默认路由。静态地址 valid_lft=forever，
#   不依赖 RA，所以熄屏也不会消失；网络一有变化就把状态重新对齐一次。
#
# 逻辑结构（三层，各司其职，只在触发层做"什么时候做"，收敛层只描述"要什么"）：
#   ① 触发层  订阅网络变化（link/address/route，IPv4+IPv6）→ 通知 reconcile
#   ② 收敛层  reconcile()：把 wlan0 对齐到「有全局 IPv6 + 有默认路由」
#   ③ 支撑层  小函数：查询状态 / 学习缓存 / 补地址 / 补路由 / 日志
# ============================================================

# ---------------- 配置 ----------------
MODDIR=${0%/*}
STATE="$MODDIR/state"
LOG="$MODDIR/run.log"
mkdir -p "$STATE" 2>/dev/null

IFACE=wlan0
HOSTPART=8888
HOSTPART_HEX=0000000000008888   # HOSTPART 的 16 位十六进制（用于识别模块自建的地址）
DEBOUNCE=3                       # 事件节流窗口（秒）：同一批网络事件只收敛一次
# 兜底值：正常情况下前缀/网关都会从系统自动学到并缓存到 state/，
# 只有系统还没提供过任何 IPv6 信息时（例如首次安装）才用到这两个值
PREFIX_DEFAULT=2408:844c:908:a4c4::
GW_DEFAULT=fe80::9683:c4ff:fee4:664d

# ---------------- 日志 ----------------
if [ -f "$LOG" ]; then
  SZ=$(wc -c < "$LOG" 2>/dev/null)
  if [ -n "$SZ" ] && [ "$SZ" -gt 131072 ]; then mv -f "$LOG" "$LOG.1"; fi
fi
log() { echo "$(date '+%m-%d %H:%M:%S') $*" >> "$LOG" 2>/dev/null; }

# ---------------- 等开机完成 ----------------
n=0
while [ "$(getprop sys.boot_completed)" != "1" ] && [ "$n" -lt 180 ]; do
  sleep 5
  n=$((n+1))
done
sleep 15
log "=== service start (boot_completed=$(getprop sys.boot_completed)) ==="

# ============================================================
# ③ 支撑层：每个函数只做一件事
# ============================================================

# ---- 状态查询 ----
# Wi-Fi 是否已连上（已拿到 IPv4）：没连上时后面的动作都没有意义
iface_ready() {
  ip -4 addr show dev "$IFACE" 2>/dev/null | grep -q 'inet '
}
# wlan0 当前是否已经有全局 IPv6 地址（RA 给的、或模块自己补的都算）
has_global_v6() {
  ip -6 addr show dev "$IFACE" 2>/dev/null | grep -q 'scope global'
}

# ---- 学习：把系统的真实信息缓存下来（有就记，没有就跳过） ----
# 前缀：取 wlan0 现有全局地址的前 64 位；跳过模块自建的静态地址，避免"自我确认"
learn_prefix() {
  H=$(awk -v d="$IFACE" -v host="$HOSTPART_HEX" '
        $6==d && $4=="00" {
          if (substr($1,17,16) == host) next
          print substr($1,1,16); exit
        }' /proc/net/if_inet6 2>/dev/null)
  [ -z "$H" ] && return 0
  P=$(echo "$H" | sed 's/\(....\)/\1:/g; s/:$//' | sed 's/$/::/')
  [ "$P" = "$(cat "$STATE/prefix" 2>/dev/null)" ] && return 0
  echo "$P" > "$STATE/prefix"
  log "learn prefix: $P"
  return 0
}
# 作废前缀缓存：只在「掉线 / 正在重连」时调用。
# 因为换了网络后旧前缀不可信（可能是另一个 Wi-Fi 的前缀），等新网络拿到 RA 再重新学，
# 避免用上一个网络的前缀补出一个不可路由的地址。
# 注意：熄屏不会掉线（IPv4 一直在），所以不会触发这里，核心场景不受影响。
forget_prefix() {
  [ -f "$STATE/prefix" ] || return 0
  rm -f "$STATE/prefix"
  log "offline -> drop cached prefix"
  return 0
}
# 网关：邻居表里带 router 标记的链路本地地址
learn_gateway() {
  G=$(ip -6 neigh show dev "$IFACE" 2>/dev/null | grep -w router | awk '{print $1}' | grep '^fe80:' | head -n1)
  [ -z "$G" ] && return 0
  [ "$G" = "$(cat "$STATE/gateway" 2>/dev/null)" ] && return 0
  echo "$G" > "$STATE/gateway"
  log "learn gateway: $G"
  return 0
}

# ---- 取值：缓存优先，缺失时退回兜底值 ----
current_prefix() {
  P=$(cat "$STATE/prefix" 2>/dev/null)
  [ -z "$P" ] && P="$PREFIX_DEFAULT"
  echo "$P"
}
current_gateway() {
  G=$(cat "$STATE/gateway" 2>/dev/null)
  [ -z "$G" ] && G="$GW_DEFAULT"
  echo "$G"
}

# ---- 对齐：缺什么补什么（幂等，重复调用结果一致） ----
ensure_addr() {
  P=$(current_prefix)
  [ -z "$P" ] && return 0
  A="${P}${HOSTPART}"
  ip -6 addr add "${A}/64" dev "$IFACE" 2>/dev/null && log "ADD addr $A"
  return 0
}
ensure_route() {
  P=$(current_prefix)
  G=$(current_gateway)
  [ -z "$P" ] && return 0

  # 关键：只在「确实缺失/不一致」时才写。
  # 无条件 replace 会让内核每次都广播 RTM_NEWROUTE，而本模块自己也监听 route 事件，
  # 于是形成"自己触发自己"的自激循环，持续抖动路由表（会打断 Tailscale 等组件的
  # 端点发现）。所以这里改为先查后写。
  if ! ip -6 route show "${P}/64" dev "$IFACE" table "$IFACE" 2>/dev/null | grep -q .; then
    ip -6 route add "${P}/64" dev "$IFACE" table "$IFACE" 2>/dev/null
  fi

  [ -z "$G" ] && return 0

  if ! ip -6 route show default dev "$IFACE" table "$IFACE" 2>/dev/null | grep -q "via $G"; then
    ip -6 route add default via "$G" dev "$IFACE" table "$IFACE" 2>/dev/null \
      && log "ADD route default via $G (table $IFACE)"
  fi
  if ! ip -6 route show default dev "$IFACE" 2>/dev/null | grep -q "via $G"; then
    ip -6 route add default via "$G" dev "$IFACE" 2>/dev/null
  fi
  return 0
}

# ============================================================
# ② 收敛层：把 wlan0 对齐到期望状态「有全局 IPv6 + 有默认路由」
#    期望状态就是下面这几行的字面意思；函数幂等，随时调用都安全
# ============================================================
reconcile() {
  iface_ready || { forget_prefix; return 0; }   # 掉线/重连中 → 旧前缀作废，本轮到此为止
  learn_prefix                    # 有真实前缀 → 更新缓存
  learn_gateway                   # 有路由器信息 → 更新缓存
  has_global_v6  || ensure_addr    # 缺地址 → 补静态地址
  ensure_route                     # 缺路由 → 补默认路由
  return 0
}

# ============================================================
# ① 触发层：把「网络变化」变成「调用 reconcile」
#    - 订阅 link + address + route（IPv4/IPv6 全含），覆盖：
#      Wi-Fi 关联/断开、拿到 IPv4、RA 来/走、地址或路由增删
#    - 不加 dev 过滤：实测 `ip monitor dev X` 按 ifindex 过滤，而 Wi-Fi 重连
#      会让 wlan0 以新 ifindex 重建，监听会静默失效（不报错、也收不到事件）
#    - 结构：外层只负责"监听断了就重连"，内层只负责"收到事件就收敛"
# ============================================================
on_network_change() {
  case "$1" in
    *"$IFACE"*) ;;              # 只关心 wlan0 的变化
    *) return 0 ;;
  esac
  NOW=$(date +%s)
  [ $((NOW - LAST_ACT)) -lt "$DEBOUNCE" ] && return 0   # 节流：同一批事件只收敛一次
  LAST_ACT=$NOW
  reconcile
}

LAST_ACT=0
while true; do
  reconcile                                             # 开始监听前先对齐一次
  ip monitor link address route 2>/dev/null | while read -r evt; do
    on_network_change "$evt"
  done
  sleep 5                                               # 监听中断 → 稍后重连
done
