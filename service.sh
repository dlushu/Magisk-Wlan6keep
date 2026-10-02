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
#   主动发送 Router Solicitation 并解析 RA，学到当前路由器发布的全球 /64；
#   然后给 wlan0 维护一个静态全局 IPv6 地址 + 默认路由。静态地址 valid_lft=forever，
#   不依赖持续 RA，所以熄屏也不会消失；网络一有变化就把状态重新对齐一次。
#
# 重要：静态地址只用「亲眼见过」的前缀，绝不硬编码兜底。
#   如果 ISP 换了 PD 前缀而模块继续用旧前缀补地址，会得到一个「看起来有 IPv6、
#   实际一个包也出不去」的假地址（netcheck 表现为 v6os=true / v6=false）。
#   Tailscale 会把这个假地址当成可用端点对外宣告，结果比「没有 IPv6」更糟——
#   没有 IPv6 时它会干脆走 v4/DERP，有假 IPv6 时它会去试一条死路。
#   所以前缀缓存必须能作废。作废有两类判据，都要求「强证据」：
#   ① 确定性事件：网关（路由器）变了 = 换了网络或换了路由器，旧前缀必然不属于当前链路，
#      立刻拆地址 + 作废前缀；
#   ② 保守失效判定：连续 N 次联网探测失败、且这串失败跨越足够长时间（默认 3 次 / 15 分钟），
#      说明「网关没变但 ISP 换了 PD 前缀」——此时地址看着还在、实际一个包也出不去。
#   为什么不拿单次探测失败判死：探测失败的成因太多（息屏挂起丢包、刚补的地址还在 DAD、
#   系统那条 RA 路由已随地址一起消失……），一次误判就会删掉刚补好的地址、并永久忘记前缀，
#   从此再不工作。所以单次失败只写日志、只累积证据，且地址刚补上时有一段观察期不计入。
#
# 逻辑结构（三层，各司其职，只在触发层做"什么时候做"，收敛层只描述"要什么"）：
#   ① 触发层  订阅网络变化（link/address/route，IPv4+IPv6）→ 通知 reconcile
#              （外加 MONITOR_WINDOW 兜底：没事件也会周期性醒来收敛一次）
#   ② 收敛层  reconcile()：把 wlan0 对齐到「有可用的全局 IPv6 + 有默认路由」
#   ③ 支撑层  小函数：查询状态 / 学习缓存 / 探测记录 / 补地址 / 补路由 / 日志
# ============================================================

# ---------------- 配置 ----------------
MODDIR=${0%/*}
STATE="$MODDIR/state"
LOG="$MODDIR/run.log"
mkdir -p "$STATE" 2>/dev/null

IFACE=wlan0
HOSTPART=8888                    # 静态地址主机段 → <prefix>::8888
SELF_SUFFIX=":$HOSTPART"         # 用于在文本地址里认出模块自建的地址
HOSTPART_HEX=$(printf '%016s' "$HOSTPART" | tr ' ' 0)   # 上者补齐成 16 位十六进制，用于在 /proc 里认出它
DEBOUNCE=3                       # 事件节流窗口（秒）：同一批网络事件只收敛一次
PROBE_TARGET=2400:3200::1        # 探测目标（公网 IPv6，任何可用地址都行）
PROBE_COUNT=3                    # 探测包数：单包会因链路偶发丢包，多打两个日志更可信
PROBE_TIMEOUT=2                  # 每个探测包的超时（秒）
PROBE_INTERVAL=300               # 探测节流窗口（秒）：两次探测至少隔这么久，避免反复打外网
MONITOR_WINDOW=60                # 单次监听的最长时间（秒）：到点主动断开重连，作为"事件丢了"的兜底
PROBE_FAIL_LIMIT=3               # 保守失效判定：连续失败达到这个次数才考虑判死（单次失败绝不判死）
PROBE_FAIL_WINDOW=900            # 保守失效判定：这串失败还必须跨越这么久（秒），避免踩到一段短时抖动
ADDR_GRACE=60                    # 地址刚补上后的观察期（秒）：期间探测失败不计入（DAD/路由未就绪）
RS_COUNT=4                       # 一轮主动发现发送几个 Router Solicitation
RS_INTERVAL=3s                   # 同一轮内 RS 间隔
RS_WAIT=20s                      # 一轮主动发现等待 RA 的最长时间
RS_THROTTLE=300                  # 主动 RS/RA 发现的最小间隔（秒），避免频繁打扰路由器

# KernelSU 用 `ASH_STANDALONE=1 /data/adb/ksu/bin/busybox sh service.sh` 拉起本脚本，
# 而 busybox sh 的 standalone 模式会**优先命中它自带的 applet**：`ip` 被解析成 busybox 的
# 精简 ip 实现，即使 PATH 里明明有 /system/bin/ip 也一样被遮蔽（实测确认）。后果是两个
# 静默故障：`ip monitor` 没有这个子命令 → 秒退，主循环退化成每 5 秒空转；`ip -6 addr add`
# 不认 `nodad` → 报 "'nodad' is garbage" 后失败，被 2>/dev/null 吞掉，地址永远补不上。
# 所以这里所有 ip / ping6 一律用绝对路径调用（绝对路径不参与 applet 匹配）。
IP=/system/bin/ip
PING6=/system/bin/ping6
RS6="$MODDIR/bin/rs6-arm64"

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
  $IP -4 addr show dev "$IFACE" 2>/dev/null | grep -q 'inet '
}
# 系统（RA/SLAAC）给的全局地址。判据是关键字 dynamic：
#   SLAAC/临时地址一律带 dynamic，而模块用 `ip addr add` 补的地址不带。
#   这比「按主机段 :8888 猜」可靠得多——按主机段猜会误伤真实地址恰好以 ::8888 结尾的情况。
real_global_v6() {
  $IP -6 addr show dev "$IFACE" scope global 2>/dev/null \
    | awk '/inet6/ && /dynamic/ {print $2}'
}
# 模块自建的全部地址（形如 <prefix>::8888/64）：非 dynamic + 主机段匹配，与前缀无关
self_addrs() {
  $IP -6 addr show dev "$IFACE" scope global 2>/dev/null \
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
#   仍然可能已经失效——所以它只配做候补；它的去留由网关变化（确定性事件）负责。
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
  rm -f "$STATE/probe_ts" "$STATE/probe_fail_cnt" "$STATE/probe_fail_since"   # 换了前缀 → 重新探测、失败证据清零
  log "learn prefix: $P"
  return 0
}
# 网关：邻居表里带 router 标记的链路本地地址。
#   返回值是这里唯一的判决出口：0 = 没变 / 拿不到，1 = 换了网关（说明换了网络或换了路由器）
learn_gateway() {
  G=$($IP -6 neigh show dev "$IFACE" 2>/dev/null | grep -w router | awk '{print $1}' | grep '^fe80:' | head -n1)
  [ -z "$G" ] && return 0
  OLD=$(cat "$STATE/gateway" 2>/dev/null)
  [ "$G" = "$OLD" ] && return 0
  echo "$G" > "$STATE/gateway"
  log "learn gateway: $G"
  [ -n "$OLD" ] && return 1    # 旧值非空且不同 → 确实换了网关
  return 0                     # 首次记录（无旧值）→ 不算变化
}

# ---- 主动发现：发 Router Solicitation，并从 RA 的 PIO 中学习全球 /64 ----
# 只依赖内核“收到过 RA 后自己生成 dynamic 地址”在 ColorOS 上不够可靠：实测会出现
# tcpdump/raw socket 已能看到 RA，但 wlan0 长时间不出现 dynamic global address 的情况。
# rs6-arm64 是本模块自带的小型 arm64 工具：发送标准 ICMPv6 RS，并解析 RA 中的
# autonomous global /64。学到的仍然只是“当前路由器刚通过 RA 发布的前缀”；之后还要走
# 既有的公网 ping 验证和连续失败判死，不会因为主动发现而保留假地址。
prepare_ra_sysctls() {
  base=/proc/sys/net/ipv6/conf/$IFACE
  echo 0  > "$base/disable_ipv6" 2>/dev/null
  echo 2  > "$base/accept_ra" 2>/dev/null
  echo 1  > "$base/accept_ra_defrtr" 2>/dev/null
  echo 1  > "$base/accept_ra_pinfo" 2>/dev/null
  echo 1  > "$base/autoconf" 2>/dev/null
  echo -1 > "$base/router_solicitations" 2>/dev/null
}

remember_prefix() {
  P="$1"
  H="$2"
  echo "$P" > "$STATE/prefix"
  echo "$H" > "$STATE/prefix_hex"
  rm -f "$STATE/probe_ts" "$STATE/probe_fail_cnt" "$STATE/probe_fail_since"
  log "remember prefix: $P"
}

discover_prefix_via_ra() {
  [ -n "$(real_global_v6)" ] && return 0
  [ "$(getprop ro.product.cpu.abi 2>/dev/null)" = "arm64-v8a" ] || return 0
  [ -f "$RS6" ] || return 0
  chmod 755 "$RS6" 2>/dev/null

  NOW=$(date +%s)
  LAST=$(cat "$STATE/rs_ts" 2>/dev/null)
  case "$LAST" in ''|*[!0-9]*) LAST=0 ;; esac
  if [ $((NOW - LAST)) -lt "$RS_THROTTLE" ]; then
    return 0
  fi
  echo "$NOW" > "$STATE/rs_ts"
  prepare_ra_sysctls

  OUT=$("$RS6" -c "$RS_COUNT" -i "$RS_INTERVAL" -w "$RS_WAIT" "$IFACE" 2>>"$LOG")
  LINE=$(printf '%s\n' "$OUT" | grep '^RA_PREFIX ' | head -n1)
  if [ -z "$LINE" ]; then
    log "active RS: no usable global RA prefix within $RS_WAIT"
    return 0
  fi

  NH=$(printf '%s\n' "$LINE" | sed -n 's/^.* prefix_hex=\([0-9a-fA-F][0-9a-fA-F]*\).*$/\1/p')
  RG=$(printf '%s\n' "$LINE" | sed -n 's/^.* router=\([^ ]*\).*$/\1/p')
  case "$RG" in
    fe[89abAB][0-9a-fA-F]:*) ;;
    *) RG="" ;;
  esac
  case "$NH" in
    *[!0-9a-fA-F]*) NH="" ;;
  esac
  [ "${#NH}" -eq 16 ] || { log "active RS: ignore RA prefix with bad hex: $LINE"; return 0; }
  case "$NH" in
    2*|3*) ;;                       # 2000::/3 全球单播
    *) log "active RS: ignore non-global RA prefix: $NH"; return 0 ;;
  esac
  # 前缀文本统一成 /proc 的补零形式：rs6 的 Go net.IP.String() 会省略每组前导零（...90c...），
  # 而 learn_prefix() 从 /proc 得到的是补零形式（...090c...）。二者是同一个前缀，若按文本
  # 比对就会被误判成「换前缀」，从而每个 RS 周期都删地址再补地址（持续抖动）。
  NP=$(printf '%s' "$NH" | sed 's/\(....\)/\1:/g; s/:$//; s/$/::/')

  OLDGW=$(cat "$STATE/gateway" 2>/dev/null)
  if [ -n "$RG" ] && [ "$RG" != "$OLDGW" ]; then
    echo "$RG" > "$STATE/gateway"
    if [ -n "$OLDGW" ]; then
      log "active RS: RA router changes $OLDGW -> $RG"
    else
      log "active RS: RA router $RG"
    fi
  fi

  OLD=$(cached_prefix)
  OLDH=$(cached_prefix_hex)
  if [ "$NH" = "$OLDH" ]; then          # 前缀身份以十六进制为准（文本写法可能不同）
    log "active RS: RA confirms prefix $NP"
    return 0
  fi

  if [ -n "$OLD" ]; then
    log "active RS: RA changes prefix $OLD -> $NP"
  else
    log "active RS: RA discovers prefix $NP"
  fi
  drop_self_addr
  remember_prefix "$NP" "$NH"
  return 0
}

# ---- 探测：收集可达性证据（单次失败不判决，只累积证据） ----
# 用缓存前缀里的静态地址 ping 一个公网 IPv6。
#   单次失败刻意不参与判决：失败成因太多（息屏挂起丢包、地址刚加还在 DAD、系统 RA 路由已随
#   地址消失……），一旦拿它当判决，一次误判就会删掉好地址并作废前缀，反而让模块彻底失效。
#   但完全不判决也有代价：网关没变、ISP 换了前缀时，模块会一直拿旧前缀补地址，得到一个
#   「看着有 IPv6、实际一个包也出不去」的假地址（比没有更糟，Tailscale 会照 Declare 出去）。
#   折中：失败只写日志 + 累积证据；只有「连续 N 次失败 且 这串失败跨越 T 时间」这种强证据
#   才由 probe_verdict 判死，交给 reconcile 拆地址 + 作废前缀。
probe_report() {
  P=$(cached_prefix)
  [ -z "$P" ] && return 0
  NOW=$(date +%s)
  LAST=$(cat "$STATE/probe_ts" 2>/dev/null)
  if [ -n "$LAST" ] && [ $((NOW - LAST)) -lt "$PROBE_INTERVAL" ]; then
    return 0                        # 节流窗口内，不重复打网
  fi
  echo "$NOW" > "$STATE/probe_ts"
  A="${P}${HOSTPART}"
  OUT=$($PING6 -c "$PROBE_COUNT" -W "$PROBE_TIMEOUT" -I "$A" "$PROBE_TARGET" 2>&1); RC=$?
  if [ "$RC" -eq 0 ]; then
    log "probe ok for cached prefix $P"
    rm -f "$STATE/probe_fail_cnt" "$STATE/probe_fail_since"   # 通了 → 证据清零
    return 0
  fi
  # 地址刚补上（或刚开机补上）时的失败不算证据：多半是暂时状态，不是前缀的问题
  ADDED=$(cat "$STATE/addr_added_ts" 2>/dev/null)
  if [ -n "$ADDED" ] && [ $((NOW - ADDED)) -lt "$ADDR_GRACE" ]; then
    log "probe failed (rc=$RC) but ignored: address added $((NOW - ADDED))s ago (within grace)"
    return 0
  fi
  CNT=$(cat "$STATE/probe_fail_cnt" 2>/dev/null)
  case "$CNT" in ''|*[!0-9]*) CNT=0 ;; esac
  if [ "$CNT" -eq 0 ]; then
    echo "$NOW" > "$STATE/probe_fail_since"   # 这串失败从这一刻算起
  fi
  echo $((CNT + 1)) > "$STATE/probe_fail_cnt"
  log "probe failed (rc=$RC) for cached prefix $P (streak $((CNT + 1))/$PROBE_FAIL_LIMIT)"
  return 0
}

# ---- 判决：只有强证据才认定缓存前缀已死（返回 1 = 已死） ----
# 判据：连续失败次数达标，且这串失败跨越的时间也达标。两个条件缺一不可——
#   只看次数：短时抖动（连续几次丢包）就会误杀；
#   只看时长：一次失败挂很久也会误杀。
# 通过后由 reconcile 拆地址 + 作废前缀，模块回到「没有 IPv6」的诚实状态，等待新 RA/人工恢复。
probe_verdict() {
  CNT=$(cat "$STATE/probe_fail_cnt" 2>/dev/null)
  case "$CNT" in ''|*[!0-9]*) return 0 ;; esac
  [ "$CNT" -lt "$PROBE_FAIL_LIMIT" ] && return 0
  SINCE=$(cat "$STATE/probe_fail_since" 2>/dev/null)
  case "$SINCE" in ''|*[!0-9]*) return 0 ;; esac
  NOW=$(date +%s)
  [ $((NOW - SINCE)) -lt "$PROBE_FAIL_WINDOW" ] && return 0
  log "verdict: prefix $(cached_prefix) looks dead (probe failed $CNT times over $((NOW - SINCE))s) → drop addr and forget prefix"
  return 1
}

# ---- 对齐：缺什么补什么（幂等，重复调用结果一致） ----
# 返回 0 = 地址已在（原本就有，或这次补上了）；返回 1 = 补失败、地址不在。
# 调用方（reconcile）要拿这个返回值决定「能不能探测」：地址根本不在时 ping 只会报
# "Cannot assign requested address"，那种失败若被当成证据，会把好前缀误判成死的。
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
  # nodad 必须加：否则新地址在 DAD 完成前是 tentative，紧接着的 probe_report
  # 会立刻 "Cannot assign requested address" 失败，日志里全是假失败、看不出真实可达性。
  # 失败必须落日志：这一处曾经因为 `2>/dev/null` 把 busybox ip 不认 nodad 的报错吞掉，
  # 结果地址永远补不上、表面上只剩 "probe failed"，排查了很久。
  OUT=$($IP -6 addr add "${P}${HOSTPART}/64" dev "$IFACE" nodad 2>&1); RC=$?
  if [ "$RC" -eq 0 ]; then
    date +%s > "$STATE/addr_added_ts"   # 供探测观察期用：地址刚补上时不拿失败当证据
    log "ADD addr ${P}${HOSTPART}"
    return 0
  fi
  log "ADD addr FAILED (rc=$RC): $OUT"
  return 1
}
ensure_route() {
  P=$(cached_prefix)
  G=$(cat "$STATE/gateway" 2>/dev/null)
  [ -z "$P" ] && return 0

  # 关键：只在「确实缺失/不一致」时才写。
  # 无条件 replace 会让内核每次都广播 RTM_NEWROUTE，而本模块自己也监听 route 事件，
  # 于是形成"自己触发自己"的自激循环，持续抖动路由表（会打断 Tailscale 等组件的
  # 端点发现）。所以这里改为先查后写。
  if ! $IP -6 route show "${P}/64" dev "$IFACE" table "$IFACE" 2>/dev/null | grep -q .; then
    OUT=$($IP -6 route add "${P}/64" dev "$IFACE" table "$IFACE" 2>&1) \
      || log "ADD route ${P}/64 (table $IFACE) FAILED: $OUT"
  fi

  [ -z "$G" ] && return 0

  sync_default_route() {
    T=$1
    $IP -6 route show default dev "$IFACE" table "$T" 2>/dev/null \
      | sed -n 's/^default via \([^ ]*\).*$/\1/p' \
      | while read -r CUR; do
          [ -z "$CUR" ] && continue
          [ "$CUR" = "$G" ] && continue
          $IP -6 route del default via "$CUR" dev "$IFACE" table "$T" 2>/dev/null \
            && log "DEL route default via $CUR (table $T)"
        done
    if ! $IP -6 route show default dev "$IFACE" table "$T" 2>/dev/null | grep -q "via $G"; then
      OUT=$($IP -6 route add default via "$G" dev "$IFACE" table "$T" 2>&1)
      if [ $? -eq 0 ]; then
        log "ADD route default via $G (table $T)"
      else
        log "ADD route default (table $T) FAILED: $OUT"
      fi
    fi
  }

  sync_default_route "$IFACE"
  sync_default_route 254
  return 0
}

# ---- 拆除：把模块自建的全部地址和它们的前缀路由清掉（不碰 state/） ----
# 拆的是「地址」这个动作，缓存前缀的去留由调用方决定：
#   网关变化 → 前缀已确证不属于当前链路，调用方会连缓存一起清掉；
#   系统已给真地址 → 缓存里是真前缀，要留着以后用。
drop_self_addr() {
  self_addrs | while read -r A; do
    [ -z "$A" ] && continue
    $IP -6 addr del "$A" dev "$IFACE" 2>/dev/null && log "DEL addr $A"
    $IP -6 route del "$(prefix_of_addr "$A")/64" dev "$IFACE" table "$IFACE" 2>/dev/null
  done
  rm -f "$STATE/addr_added_ts"
  return 0
}

# ---- 作废缓存前缀 ----
# 连带清掉探测证据：前缀都没了，旧前缀上的失败计数不该留给下一个前缀用。
forget_prefix() {
  rm -f "$STATE/prefix" "$STATE/prefix_hex" "$STATE/probe_ts" \
        "$STATE/probe_fail_cnt" "$STATE/probe_fail_since" "$STATE/rs_ts"
  return 0
}

# ============================================================
# ② 收敛层：把 wlan0 对齐到期望状态「有可用的全局 IPv6 + 有默认路由」
#    期望状态就是下面这几行的字面意思；函数幂等，随时调用都安全
# ============================================================
reconcile() {
  iface_ready || return 0       # 没连上 Wi-Fi → 什么都不做（旧缓存留着，重连后再判）

  # 唯一的作废判据：网关变了 = 换了路由器/换了网络 → 旧前缀必然不属于当前链路，
  # 先拆干净再重新学。放在 learn_prefix 之前，避免刚学到的新前缀又被下面清掉。
  if ! learn_gateway; then
    drop_self_addr
    forget_prefix
  fi
  learn_prefix                  # 有真实前缀 → 更新缓存（换网后这里会写入新前缀）

  # ① 系统已经给了真地址（RA/SLAAC）→ 最理想，模块的静态地址是多余的，拆掉
  #    拆之前 learn_prefix 已经把真前缀写进缓存，所以这里只清「地址」，保留缓存
  if [ -n "$(real_global_v6)" ]; then
    drop_self_addr
    rm -f "$STATE/probe_ts"
    ensure_route
    return 0
  fi

  # ② 没有真地址（典型：息屏收不到 RA，或内核没有根据 RA 生成 SLAAC 地址）
  #    先主动发 RS 并直接解析 RA；这可能从“无缓存”恢复，也可能在旧前缀变化时立即切到新前缀。
  discover_prefix_via_ra

  P=$(cached_prefix)
  if [ -n "$P" ]; then
    # 只有地址确实在，探测才有意义（补失败时 ping 报的是 "Cannot assign requested address"，
    # 那种失败不是前缀的证据，不能拿来判死）
    if ensure_addr_from "$P"; then
      # 先补路由再探测：没有默认路由时 ping 连包都发不出去，日志只会是假失败
      ensure_route
      probe_report              # 只收集可达性证据（单次失败不判决）
      if ! probe_verdict; then  # 强证据（连续 N 次 + 跨 T 时间）判定前缀已死
        drop_self_addr          # 宁可不装 IPv6，也不留一个骗 Tailscale 的假地址
        forget_prefix
      fi
    fi
    return 0
  fi

  # ③ 主动 RS/RA 也没拿到前缀 → 绝不猜前缀，等待下一轮网络事件或节流窗口后重试
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
  # timeout：到点主动断开监听、重连一次。netlink 事件偶尔会丢（内核队列溢出/驱动异常），
  #   只靠事件驱动的话丢了就一直卡住；这里保证「无论有没有事件，至少每 $MONITOR_WINDOW 秒
  #   收敛一次」。reconcile 幂等且先查后写，状态正常时这一趟不产生任何写操作。
  timeout "$MONITOR_WINDOW" $IP monitor link address route 2>/dev/null | while read -r evt; do
    on_network_change "$evt"
  done
  sleep 2                                               # 监听中断 → 稍后重连
done