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
# 重要：静态地址只用「亲眼见过」的前缀，绝不硬编码兜底。
#   如果 ISP 换了 PD 前缀而模块继续用旧前缀补地址，会得到一个「看起来有 IPv6、
#   实际一个包也出不去」的假地址（netcheck 表现为 v6os=true / v6=false）。
#   Tailscale 会把这个假地址当成可用端点对外宣告，结果比「没有 IPv6」更糟——
#   没有 IPv6 时它会干脆走 v4/DERP，有假 IPv6 时它会去试一条死路。
#   所以这里用「联网探测」判定缓存前缀是否还活着，死了就立刻拆除退回无 IPv6。
#
# 逻辑结构（三层，各司其职，只在触发层做"什么时候做"，收敛层只描述"要什么"）：
#   ① 触发层  订阅网络变化（link/address/route，IPv4+IPv6）→ 通知 reconcile
#   ② 收敛层  reconcile()：把 wlan0 对齐到「有可用的全局 IPv6 + 有默认路由」
#   ③ 支撑层  小函数：查询状态 / 学习缓存 / 校验前缀 / 补地址 / 补路由 / 日志
# ============================================================

# ---------------- 配置 ----------------
MODDIR=${0%/*}
STATE="$MODDIR/state"
LOG="$MODDIR/run.log"
mkdir -p "$STATE" 2>/dev/null

IFACE=wlan0
HOSTPART=8888                    # 静态地址主机段 → <prefix>::8888
SELF_SUFFIX=":$HOSTPART"         # 用于在文本地址里认出模块自建的地址
HOSTPART_HEX=$(printf '%016x' "$HOSTPART")   # 上者的 16 位十六进制，用于在 /proc 里认出它
DEBOUNCE=3                       # 事件节流窗口（秒）：同一批网络事件只收敛一次
PROBE_TARGET=2400:3200::1        # 前缀有效性探测目标（公网 IPv6，任何可用地址都行）
PROBE_COUNT=3                    # 探测包数：单包会因链路偶发丢包误判，多打两个更稳
PROBE_TIMEOUT=2                  # 每个探测包的超时（秒）
PROBE_INTERVAL=300               # 探测通过后的信任期（秒），期间不再重复打网

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
# 系统（RA/SLAAC）给的全局地址。判据是关键字 dynamic：
#   SLAAC/临时地址一律带 dynamic，而模块用 `ip addr add` 补的地址不带。
#   这比「按主机段 :8888 猜」可靠得多——按主机段猜会误伤真实地址恰好以 ::8888 结尾的情况。
real_global_v6() {
  ip -6 addr show dev "$IFACE" scope global 2>/dev/null \
    | awk '/inet6/ && /dynamic/ {print $2}'
}
# 模块自建的全部地址（形如 <prefix>::8888/64）：非 dynamic + 主机段匹配，与前缀无关
self_addrs() {
  ip -6 addr show dev "$IFACE" scope global 2>/dev/null \
    | awk -v s="$SELF_SUFFIX" '
        /inet6/ && !/dynamic/ {
          split($2, a, "/")
          if (substr(a[1], length(a[1]) - length(s) + 1) == s) print $2
        }'
}
# 由地址文本反推它所在的前缀
prefix_of_addr() {
  P="${1%/64}"
  echo "${P%::$HOSTPART}::"
}
# 缓存前缀（文本形式，用于拼地址；也是唯一的"期望状态"）
cached_prefix() {
  cat "$STATE/prefix" 2>/dev/null
}
# 缓存前缀的规范十六进制（16 位），用于在 /proc 里做与写法无关的存在性判断
cached_prefix_hex() {
  cat "$STATE/prefix_hex" 2>/dev/null
}

# ---- 学习：把系统的真实信息缓存下来（有就记，没有就跳过） ----
# 前缀优先级：系统（RA/SLAAC）给的地址 > 模块自建地址自带的前缀。
#   前者是「刚亲眼看到系统在用这个前缀」，后者只是「这个地址当初被创建时的前缀」，
#   仍然可能已经失效——所以它只配做候补，且必须经过 probe_ok() 验证才会被拿来补地址。
#   （早期版本反过来：跳过自建地址以免"自我确认"，结果自建地址一旦成为 wlan0 上唯一的
#   全局地址就永远学不到前缀，只能一路退回硬编码兜底，把设备锁死在旧前缀上。）
learn_prefix() {
  H=$(awk -v d="$IFACE" -v host="$HOSTPART_HEX" '
        $6 != d || $4 != "00" { next }
        { h = substr($1,1,16)
          if (substr($1,17,16) == host) { if (self == "") self = h }
          else { print h; found = 1; exit } }
        END { if (!found && self != "") print self }' /proc/net/if_inet6 2>/dev/null)
  [ -z "$H" ] && return 0
  P=$(echo "$H" | sed 's/\(....\)/\1:/g; s/:$//' | sed 's/$/::/')
  if [ "$P" = "$(cached_prefix)" ] && [ "$H" = "$(cached_prefix_hex)" ]; then
    return 0                        # 文本和十六进制都一致才算没变（顺带兼容旧版只有文本的情况）
  fi
  echo "$P" > "$STATE/prefix"
  echo "$H" > "$STATE/prefix_hex"
  rm -f "$STATE/probe_ok_ts"        # 换了前缀 → 旧的探测结论作废
  log "learn prefix: $P"
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

# ---- 校验：缓存的前缀现在还活着吗 ----
# 判据只有一个：用这个前缀里的静态地址去 ping 一个公网 IPv6。
#   通   → 前缀仍然双向可达（哪怕当前收不到 RA，例如息屏组播被丢），可以继续用
#   不通 → 前缀已经失效（典型：ISP 换了 PD 前缀 / 换了网络），必须立刻作废
# 只有「系统没给真地址、只能吃缓存」时才会走到这里，所以不会常态化打网。
probe_ok() {
  P=$(cached_prefix)
  [ -z "$P" ] && return 1
  NOW=$(date +%s)
  LAST=$(cat "$STATE/probe_ok_ts" 2>/dev/null)
  if [ -n "$LAST" ] && [ $((NOW - LAST)) -lt "$PROBE_INTERVAL" ]; then
    return 0                        # 上次探测通过且还在信任期内
  fi
  A="${P}${HOSTPART}"
  if ping6 -c "$PROBE_COUNT" -W "$PROBE_TIMEOUT" -I "$A" "$PROBE_TARGET" >/dev/null 2>&1; then
    echo "$NOW" > "$STATE/probe_ok_ts"
    return 0
  fi
  log "probe FAILED for cached prefix $P"
  return 1
}

# ---- 对齐：缺什么补什么（幂等，重复调用结果一致） ----
# 存在性判断走 /proc 的规范十六进制，不做文本比较：
# `2408:844c:908:a4c4::8888` 与 `2408:844c:0908:a4c4::8888` 是同一个地址，
# 拿文本去 `ip addr show` 里 grep 会误判成"不存在"，于是每次都白跑一次 ip addr add。
ensure_addr_from() {
  P="$1"
  HX=$(cached_prefix_hex)
  if [ -n "$HX" ]; then
    awk -v d="$IFACE" -v k="${HX}${HOSTPART_HEX}" \
        '$6==d && index($1,k)==1 {found=1} END{exit !found}' \
        /proc/net/if_inet6 2>/dev/null && return 0
  fi
  ip -6 addr add "${P}${HOSTPART}/64" dev "$IFACE" 2>/dev/null \
    && log "ADD addr ${P}${HOSTPART}"
  return 0
}
ensure_route() {
  P=$(cached_prefix)
  G=$(cat "$STATE/gateway" 2>/dev/null)
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

# ---- 拆除：把模块自建的全部地址和它们的前缀路由清掉（不碰 state/） ----
# 拆的是「地址」这个动作，缓存前缀的去留由调用方决定：
#   探测失败 → 前缀已证伪，调用方会连缓存一起清掉；
#   系统已给真地址 → 缓存里是真前缀，要留着以后用。
drop_self_addr() {
  self_addrs | while read -r A; do
    [ -z "$A" ] && continue
    ip -6 addr del "$A" dev "$IFACE" 2>/dev/null && log "DEL addr $A"
    ip -6 route del "$(prefix_of_addr "$A")/64" dev "$IFACE" table "$IFACE" 2>/dev/null
  done
  return 0
}

# ---- 作废缓存前缀 ----
forget_prefix() {
  rm -f "$STATE/prefix" "$STATE/prefix_hex" "$STATE/probe_ok_ts"
  return 0
}

# ============================================================
# ② 收敛层：把 wlan0 对齐到期望状态「有可用的全局 IPv6 + 有默认路由」
#    期望状态就是下面这几行的字面意思；函数幂等，随时调用都安全
# ============================================================
reconcile() {
  iface_ready || return 0       # 没连上 Wi-Fi → 什么都不做（旧缓存留着，重连后要校验）
  learn_prefix                  # 有真实前缀 → 更新缓存
  learn_gateway                 # 有路由器信息 → 更新缓存

  # ① 系统已经给了真地址（RA/SLAAC）→ 最理想，模块的静态地址是多余的，拆掉
  #    拆之前 learn_prefix 已经把真前缀写进缓存，所以这里只清「地址」，保留缓存
  if [ -n "$(real_global_v6)" ]; then
    drop_self_addr
    rm -f "$STATE/probe_ok_ts"
    ensure_route
    return 0
  fi

  # ② 没有真地址（典型：息屏收不到 RA）→ 用缓存前缀补一个静态地址顶住
  P=$(cached_prefix)
  if [ -n "$P" ]; then
    ensure_addr_from "$P"
    if probe_ok; then
      ensure_route
    else
      # 前缀已被证伪（典型：ISP 换了 PD 前缀）→ 拆掉地址并忘掉前缀，
      # 避免「补上 → 探测失败 → 拆掉 → 下个事件又补上」的抖动。
      # 宁可明确「没有 IPv6」，也不要留一个骗人的假地址。
      drop_self_addr
      forget_prefix
    fi
    return 0
  fi

  # ③ 连缓存前缀都没有 → 绝不猜前缀，静待系统给 RA
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