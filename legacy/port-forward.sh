#!/usr/bin/env bash
set -Eeuo pipefail

# 端口转发管理（Debian / Ubuntu，iptables + netfilter-persistent）
# 全交互菜单：可随时添加、删除、查看，规则自动持久化。
#
#   bash port-forward.sh        进入菜单
#   bash port-forward.sh list   只看规则
#   bash port-forward.sh -h     帮助

STATE="/etc/port-forward.rules"
SYSCTL_CONF="/etc/sysctl.d/99-port-forward.conf"
SELF="$(readlink -f "$0" 2>/dev/null || echo "$0")"

if [[ -t 1 ]]; then
  C_OK=$'\033[32m'; C_ERR=$'\033[31m'; C_DIM=$'\033[2m'; C_B=$'\033[1m'; C_0=$'\033[0m'
else
  C_OK=""; C_ERR=""; C_DIM=""; C_B=""; C_0=""
fi

ok()   { printf '%s%s%s\n' "$C_OK" "$*" "$C_0"; }
err()  { printf '%s%s%s\n' "$C_ERR" "$*" "$C_0"; }
dim()  { printf '%s%s%s\n' "$C_DIM" "$*" "$C_0"; }
hr()   { printf '%s\n' "--------------------------------------------"; }

die() { err "错误：$*"; exit 1; }

[[ ${EUID} -eq 0 ]] || die "请使用 root 运行。"

if ! command -v iptables >/dev/null 2>&1; then
  echo "正在安装 iptables..."
  apt-get update -y >/dev/null 2>&1 || true
  apt-get install -y iptables >/dev/null 2>&1 || die "安装 iptables 失败。"
fi

[[ -f "$STATE" ]] || : > "$STATE"
chmod 600 "$STATE"

# ---------------- 基础工具 ----------------

rule_count() {
  local n
  n="$(grep -c '[^[:space:]]' "$STATE" 2>/dev/null || true)"
  printf '%s' "${n:-0}"
}

pf_args() {  # proto lport mode tip tport -> 填充 AR_ARGS
  AR_ARGS=(-p "$1" --dport "$2" -m comment --comment "pf:$1:$2->$4:$5")
  if [[ "$3" == "local" ]]; then
    AR_ARGS+=(-j REDIRECT --to-ports "$5")
  else
    AR_ARGS+=(-j DNAT --to-destination "$4:$5")
  fi
}

pf_fwd() {  # add|del proto tip tport —— 放行/清理 FORWARD 链
  local act="$1" p="$2" tip="$3" tport="$4"
  local -a A B
  A=(-d "$tip" -p "$p" --dport "$tport" -j ACCEPT)
  B=(-s "$tip" -p "$p" --sport "$tport" -j ACCEPT)
  if [[ "$act" == "add" ]]; then
    iptables -w -C FORWARD "${A[@]}" 2>/dev/null || iptables -w -A FORWARD "${A[@]}"
    iptables -w -C FORWARD "${B[@]}" 2>/dev/null || iptables -w -A FORWARD "${B[@]}"
  else
    if iptables -w -C FORWARD "${A[@]}" 2>/dev/null; then iptables -w -D FORWARD "${A[@]}"; fi
    if iptables -w -C FORWARD "${B[@]}" 2>/dev/null; then iptables -w -D FORWARD "${B[@]}"; fi
  fi
}

pf_save() {
  if ! command -v netfilter-persistent >/dev/null 2>&1; then
    echo "正在安装 iptables-persistent（让规则重启后不丢）..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent >/dev/null 2>&1 || true
  fi
  if command -v netfilter-persistent >/dev/null 2>&1; then
    if netfilter-persistent save >/dev/null 2>&1; then
      ok "规则已保存，重启后依然有效。"
    else
      err "警告：规则保存失败，重启后可能丢失。"
    fi
  else
    err "警告：没有 iptables-persistent，重启后规则会丢失。"
  fi
}

pf_ufw_hint() {  # lport proto
  if command -v ufw >/dev/null 2>&1 &&
     ufw status 2>/dev/null | grep -q "Status: active"; then
    err "注意：本机 ufw 已启用，请执行 ufw allow $1/tcp"
    [[ "${2:-}" == "both" ]] && err "  以及 ufw allow $1/udp"
  fi
}

pause_key() {
  echo
  read -rp "按回车返回菜单..." _ || true
}

# ---------------- 查看 ----------------

pf_list() {
  echo
  if [[ ! -s "$STATE" ]]; then
    dim "当前没有任何端口转发规则。"
    return 0
  fi

  printf '%s\n' "当前端口转发规则："
  local i=0 lport proto mode target ts tip tport p st
  while IFS='|' read -r lport proto mode target ts; do
    [[ -n "$lport" ]] || continue
    i=$((i + 1))

    tip="${target%:*}"
    tport="${target##*:}"
    p="$proto"
    [[ "$proto" == "both" ]] && p="tcp"

    pf_args "$p" "$lport" "$mode" "$tip" "$tport"
    if iptables -w -t nat -C PREROUTING "${AR_ARGS[@]}" 2>/dev/null; then
      st="${C_OK}生效${C_0}"
    else
      st="${C_ERR}规则缺失${C_0}"
    fi

    if [[ "$mode" == "local" ]]; then
      printf '  %d) 对外 %s/%s  ->  %s  [本机]   %b   %s\n' \
        "$i" "$lport" "$proto" "$target" "$st" "$ts"
    else
      printf '  %d) 对外 %s/%s  ->  %s  [跨机]   %b   %s\n' \
        "$i" "$lport" "$proto" "$target" "$st" "$ts"
    fi
  done < "$STATE"
  echo
  dim "实际内核规则：iptables -t nat -L PREROUTING -n -v"
}

# ---------------- 添加 ----------------

pf_add() {
  local lport proto tip tport mode pub p ans
  local protos=()

  echo
  echo "== 添加转发规则 =="
  echo "对外端口 = 别人访问你时用的端口；落地端口 = 后面那台机器实际监听的端口"
  echo

  read -rp "对外端口: " lport || return 1
  [[ "$lport" =~ ^[0-9]+$ ]] || { err "端口必须是数字。"; return 1; }
  lport="$((10#$lport))"
  (( lport >= 1 && lport <= 65535 )) || { err "端口范围 1-65535。"; return 1; }

  read -rp "协议 [tcp/udp/both]（回车=tcp）: " proto || return 1
  proto="${proto:-tcp}"
  case "$proto" in
    tcp|udp) protos=("$proto") ;;
    both)    protos=(tcp udp) ;;
    *)       err "协议只能是 tcp / udp / both。"; return 1 ;;
  esac

  read -rp "落地服务器 IP（同机转发直接回车）: " tip || return 1
  tip="${tip:-127.0.0.1}"

  read -rp "落地服务器上监听的端口: " tport || return 1
  [[ "$tport" =~ ^[0-9]+$ ]] || { err "端口必须是数字。"; return 1; }
  tport="$((10#$tport))"
  (( tport >= 1 && tport <= 65535 )) || { err "端口范围 1-65535。"; return 1; }

  if [[ "$tip" == "127.0.0.1" || "$tip" == "localhost" || "$tip" == "::1" ]] ||
     [[ " $(hostname -I 2>/dev/null || true) " == *" $tip "* ]]; then
    mode="local"
  else
    mode="remote"
  fi

  if [[ "$mode" == "local" && "$lport" == "$tport" ]]; then
    err "对外端口和落地端口相同，不需要转发。"
    return 1
  fi

  if [[ "$mode" == "remote" ]]; then
    pub="$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
    if [[ -n "$pub" && "$tip" == "$pub" ]]; then
      err "注意：$tip 是本机公网 IP，转发到自己的公网 IP 会因 NAT 回环不通。"
      dim "      同机转发请直接回车（用 127.0.0.1）。"
      return 1
    fi
    echo
    dim "正在探测 $tip:$tport ..."
    if timeout 5 bash -c "echo > /dev/tcp/$tip/$tport" 2>/dev/null; then
      ok "落地端口可达。"
    else
      err "从本机连 $tip:$tport 失败。"
      dim "落地机要监听 0.0.0.0，且其安全组/防火墙要允许本机访问这个端口。"
      read -rp "仍然继续添加？[y/N]: " ans || return 1
      [[ "$ans" =~ ^[Yy]$ ]] || { dim "已取消。"; return 1; }
    fi
  fi

  if [[ -n "$(ss -H -ltn "sport = :$lport" 2>/dev/null)" ]]; then
    err "注意：本机已有服务在监听 $lport，转发会抢走这些连接。"
    read -rp "仍然继续？[y/N]: " ans || return 1
    [[ "$ans" =~ ^[Yy]$ ]] || { dim "已取消。"; return 1; }
  fi

  for p in "${protos[@]}"; do
    pf_args "$p" "$lport" "$mode" "$tip" "$tport"
    if iptables -w -t nat -C PREROUTING "${AR_ARGS[@]}" 2>/dev/null; then
      dim "已存在，跳过：$p  $lport -> $tip:$tport"
      continue
    fi
    iptables -w -t nat -A PREROUTING "${AR_ARGS[@]}"
    ok "已添加：$p  $lport -> $tip:$tport"
  done

  if [[ "$mode" == "remote" ]]; then
    echo 'net.ipv4.ip_forward=1' > "$SYSCTL_CONF"
    sysctl --system >/dev/null 2>&1 || true
    if [[ "$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)" != "1" ]]; then
      err "警告：ip_forward 没开起来，跨机转发不会生效。"
    fi
    for p in "${protos[@]}"; do
      if ! iptables -w -t nat -C POSTROUTING -d "$tip" -p "$p" --dport "$tport" -j MASQUERADE 2>/dev/null; then
        iptables -w -t nat -A POSTROUTING -d "$tip" -p "$p" --dport "$tport" -j MASQUERADE
        dim "已添加回程 SNAT：$p  $tip:$tport"
      fi
      pf_fwd add "$p" "$tip" "$tport"
    done
    dim "已放行 FORWARD 链（装了 Docker/ufw 时必需）。"
  fi

  printf '%s|%s|%s|%s:%s|%s\n' \
    "$lport" "$proto" "$mode" "$tip" "$tport" "$(date '+%Y-%m-%d %H:%M')" >> "$STATE"

  pf_save
  pf_ufw_hint "$lport" "$proto"

  echo
  if [[ "$mode" == "local" ]]; then
    ok "完成：对外 $lport/$proto -> 本机 $tip:$tport"
  else
    ok "完成：对外 $lport/$proto -> $tip:$tport（跨机中转）"
    dim "安全组要放行两处：中转机放行 $lport，落地机放行 $tport 并允许来自本机。"
  fi
  dim "客户端如果连的是 443，把链接里的地址改成本机 IP、端口改成 $lport，其余不变。"
}

# ---------------- 删除 ----------------

pf_remove_line() {  # 一行规则  force
  local line="$1" force="${2:-0}"
  local lport proto mode target ts tip tport p shared
  local protos=()

  IFS='|' read -r lport proto mode target ts <<< "$line"
  [[ -n "$lport" ]] || return 0
  tip="${target%:*}"
  tport="${target##*:}"

  case "$proto" in
    both) protos=(tcp udp) ;;
    *)    protos=("$proto") ;;
  esac

  for p in "${protos[@]}"; do
    pf_args "$p" "$lport" "$mode" "$tip" "$tport"
    if iptables -w -t nat -C PREROUTING "${AR_ARGS[@]}" 2>/dev/null; then
      iptables -w -t nat -D PREROUTING "${AR_ARGS[@]}"
    fi
    if [[ "$mode" == "remote" ]]; then
      shared=0
      if [[ "$force" != "1" ]]; then
        if grep -F -v -x -- "$line" "$STATE" 2>/dev/null | grep -qF "|${target}|"; then
          shared=1
        fi
      fi
      if (( shared == 0 )); then
        if iptables -w -t nat -C POSTROUTING -d "$tip" -p "$p" --dport "$tport" -j MASQUERADE 2>/dev/null; then
          iptables -w -t nat -D POSTROUTING -d "$tip" -p "$p" --dport "$tport" -j MASQUERADE
        fi
        pf_fwd del "$p" "$tip" "$tport"
      else
        dim "目标 $target 还有其它规则在用，保留回程 SNAT。"
      fi
    fi
  done

  ok "已删除：对外 ${lport}/${proto} -> ${target}"
}

pf_del_one() {
  echo
  if [[ ! -s "$STATE" ]]; then
    dim "没有可删除的规则。"
    return 0
  fi

  pf_list
  local idx total line
  total="$(rule_count)"
  read -rp "要删除的序号（回车取消）: " idx || return 0
  [[ -z "$idx" ]] && { dim "已取消。"; return 0; }
  [[ "$idx" =~ ^[0-9]+$ ]] || { err "请输入数字序号。"; return 1; }
  idx="$((10#$idx))"
  (( idx >= 1 && idx <= total )) || { err "序号超出范围（1-$total）。"; return 1; }

  line="$(sed -n "${idx}p" "$STATE")"
  [[ -n "$line" ]] || { err "没有第 $idx 条规则。"; return 1; }

  pf_remove_line "$line" 0
  sed -i "${idx}d" "$STATE"
  pf_save
}

pf_del_all() {
  echo
  local total
  total="$(rule_count)"
  if [[ "$total" == "0" ]]; then
    dim "没有可删除的规则。"
    return 0
  fi

  pf_list
  local ans line
  read -rp "确认删除全部 $total 条规则？输入 yes 确认: " ans || return 0
  [[ "$ans" == "yes" ]] || { dim "已取消。"; return 0; }

  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    pf_remove_line "$line" 1
  done < "$STATE"

  : > "$STATE"
  pf_save
  ok "已清空全部规则。"
}

# ---------------- 排错 ----------------

pf_show_raw() {
  echo
  echo "== NAT 表 PREROUTING =="
  iptables -w -t nat -L PREROUTING -n -v --line-numbers 2>/dev/null || true
  echo
  echo "== NAT 表 POSTROUTING =="
  iptables -w -t nat -L POSTROUTING -n -v --line-numbers 2>/dev/null || true
  echo
  echo "== ip_forward =="
  cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || true
}

# ---------------- 主菜单 ----------------

show_menu() {
  echo
  hr
  printf ' 端口转发管理   现有规则：%s 条\n' "$(rule_count)"
  hr
  echo "  1) 查看规则"
  echo "  2) 添加规则"
  echo "  3) 删除某一条"
  echo "  4) 删除全部"
  echo "  5) 查看 iptables 原始规则（排错）"
  echo "  6) 退出"
  hr
}

main_menu() {
  local choice
  while true; do
    show_menu
    if ! read -rp "请选择 [1-6]: " choice; then
      echo
      break
    fi
    case "$choice" in
      1) pf_list;        pause_key ;;
      2) pf_add;         pause_key ;;
      3) pf_del_one;     pause_key ;;
      4) pf_del_all;     pause_key ;;
      5) pf_show_raw;    pause_key ;;
      6|q|Q|exit)        break ;;
      "")                ;;
      *) err "无效选项：$choice" ;;
    esac
  done
  echo
  dim "已退出。规则仍然生效，可随时再运行本脚本管理。"
}

# ---------------- 入口 ----------------

case "${1:-}" in
  "")      main_menu ;;
  list)    pf_list ;;
  -h|--help)
    echo "用法："
    echo "  bash $SELF         进入交互菜单（推荐）"
    echo "  bash $SELF list    直接列出规则"
    echo
    echo "规则保存在 $STATE，重启后由 netfilter-persistent 自动恢复。"
    ;;
  *)
    err "未知参数：$1（用 -h 查看用法）"
    exit 1
    ;;
esac
