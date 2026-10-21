#!/usr/bin/env bash
set -Eeuo pipefail

# Xray 工具箱：安装 / 查看链接 / 追加 SOCKS5 / 端口转发，全部收在一个菜单里
#
#   bash xray-menu.sh          进入菜单
#   bash xray-menu.sh links    直接查看链接
#   bash xray-menu.sh install  直接重装
#   bash xray-menu.sh socks    直接追加 SOCKS5
#   bash xray-menu.sh fwd      端口转发子菜单
#   bash xray-menu.sh -h       帮助

XRAY_BIN="/usr/local/bin/xray"
CONFIG="/usr/local/etc/xray/config.json"
LINKS_FILE="/root/xray-links.txt"
PF_STATE="/etc/port-forward.rules"
SYSCTL_CONF="/etc/sysctl.d/99-port-forward.conf"
SELF="$(readlink -f "$0" 2>/dev/null || echo "$0")"

# 临时文件用全局变量，保证 EXIT trap 在函数返回后仍能正确清理
TMP_INSTALLER=""
TMP_CONFIG=""
TMP_NEW=""
trap 'rm -f "${TMP_INSTALLER:-}" "${TMP_CONFIG:-}" "${TMP_NEW:-}"' EXIT

if [[ -t 1 ]]; then
  C_OK=$'\033[32m'; C_ERR=$'\033[31m'; C_DIM=$'\033[2m'; C_B=$'\033[1m'; C_0=$'\033[0m'
else
  C_OK=""; C_ERR=""; C_DIM=""; C_B=""; C_0=""
fi

ok()   { printf '%s%s%s\n' "$C_OK" "$*" "$C_0"; }
err()  { printf '%s%s%s\n' "$C_ERR" "$*" "$C_0"; }
dim()  { printf '%s%s%s\n' "$C_DIM" "$*" "$C_0"; }
hr()   { printf '%s\n' "--------------------------------------------"; }
die()  { err "错误：$*"; exit 1; }
pause_key() { echo; read -rp "按回车继续..." _ || true; }

[[ ${EUID} -eq 0 ]] || die "请使用 root 运行。"

# ============ 通用小工具 ============

port_in_use() {
  [[ -n "$(ss -H -ltn "sport = :$1" 2>/dev/null)" ]]
}

choose_random_port() {   # [$1=排除的端口]
  local exclude="${1:-}" candidate
  for _ in $(seq 1 500); do
    candidate="$(shuf -i 20000-60000 -n 1)"
    if [[ -n "$exclude" && "$candidate" == "$exclude" ]]; then
      continue
    fi
    if ! port_in_use "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

host_for_uri() {
  if [[ "$1" == *:* && "$1" != \[*\] ]]; then
    printf '[%s]' "$1"
  else
    printf '%s' "$1"
  fi
}

build_vless_link() {   # host port uuid sni pbk sid flow
  printf 'vless://%s@%s:%s?encryption=none&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&spx=%%2F&type=tcp&flow=%s#Xray-REALITY-%s' \
    "$3" "$(host_for_uri "$1")" "$2" "$4" "$5" "$6" "${7:-xtls-rprx-vision}" "$2"
}

build_socks_link() {   # host port user pass
  if [[ -n "${3:-}" ]]; then
    printf 'socks5h://%s:%s@%s:%s#Xray-SOCKS5-%s' \
      "$3" "$4" "$(host_for_uri "$1")" "$2" "$2"
  else
    printf 'socks5h://%s:%s#Xray-SOCKS5-%s' "$(host_for_uri "$1")" "$2" "$2"
  fi
}

derive_public_key() {
  [[ -x "$XRAY_BIN" && -n "${1:-}" ]] || return 0
  "$XRAY_BIN" x25519 -i "$1" 2>/dev/null |
    sed -nE 's/^(Password \(PublicKey\)|Password|Public key):[[:space:]]*//p' |
    head -n 1 || true
}

rand_str() {   # $1=长度，大小写字母+数字
  local n="${1:-10}"
  openssl rand -base64 48 | LC_ALL=C tr -dc 'A-Za-z0-9' | cut -c1-"$n"
}

get_public_ip() {
  curl -4 -fsS --max-time 8 https://api.ipify.org 2>/dev/null || true
}

ensure_jq() {
  command -v jq >/dev/null 2>&1 && return 0
  echo "正在安装 jq..."
  apt-get update -y >/dev/null 2>&1 || true
  apt-get install -y jq >/dev/null 2>&1 || { err "安装 jq 失败。"; return 1; }
}

reality_port() {
  [[ -f "$CONFIG" ]] && command -v jq >/dev/null 2>&1 || return 0
  jq -r '[.inbounds[]? | select(.streamSettings.security? == "reality") | .port] | first // ""' \
    "$CONFIG" 2>/dev/null || true
}

pf_rule_count() {
  [[ -f "$PF_STATE" ]] || { printf '0'; return 0; }
  local n
  n="$(grep -c '[^[:space:]]' "$PF_STATE" 2>/dev/null || true)"
  printf '%s' "${n:-0}"
}

# ============ 应用配置并重启（失败回滚） ============

xray_apply() {   # $1=新配置文件
  local new="$1" backup=""
  [[ -f "$new" ]] || { err "配置文件不存在：$new"; return 1; }

  if [[ -f "$CONFIG" ]]; then
    backup="${CONFIG}.bak.$(date +%Y%m%d-%H%M%S)"
    cp -a "$CONFIG" "$backup"
    dim "原配置已备份：$backup"
  fi

  install -o root -g root -m 644 "$new" "$CONFIG"
  systemctl daemon-reload
  systemctl enable xray >/dev/null 2>&1 || true

  if ! systemctl restart xray; then
    journalctl -u xray -n 40 --no-pager || true
    if [[ -n "$backup" ]]; then
      cp -a "$backup" "$CONFIG"
      systemctl restart xray || true
      err "启动失败，已回滚到原配置。"
    fi
    return 1
  fi

  sleep 2

  if ! systemctl is-active --quiet xray; then
    journalctl -u xray -n 40 --no-pager || true
    if [[ -n "$backup" ]]; then
      cp -a "$backup" "$CONFIG"
      systemctl restart xray || true
      err "服务没有正常运行，已回滚到原配置。"
    fi
    return 1
  fi

  ok "Xray 已重启，运行正常。"
  return 0
}

# ============ 1. 安装 / 重装 ============

install_reality() {
  local input_port port server_name want_socks enable_socks socks_port socks_user socks_pass
  local uuid key_output private_key public_key short_id tmp_config installer server_addr link

  echo
  echo "== 安装 / 重新安装：Xray + VLESS + REALITY =="
  echo "默认端口：随机选择 20000-60000 之间的空闲端口"
  echo

  if ! command -v apt-get >/dev/null 2>&1; then
    err "当前系统不是 Debian / Ubuntu，本脚本只支持这两者。"
    return 1
  fi

  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y curl ca-certificates openssl iproute2 coreutils jq

  read -rp "监听端口（直接回车随机选择）: " input_port || return 1
  if [[ -z "$input_port" ]]; then
    port="$(choose_random_port)" || { err "无法找到空闲端口。"; return 1; }
  else
    [[ "$input_port" =~ ^[0-9]+$ ]] || { err "端口必须是数字。"; return 1; }
    input_port="$((10#$input_port))"
    (( input_port >= 1024 && input_port <= 65535 )) || { err "端口范围 1024-65535。"; return 1; }
    if port_in_use "$input_port"; then
      err "端口 $input_port 已被占用。"
      return 1
    fi
    port="$input_port"
  fi
  echo "本次使用端口：$port"

  read -rp "REALITY 伪装域名 [www.cloudflare.com]: " server_name || return 1
  server_name="${server_name:-www.cloudflare.com}"
  [[ "$server_name" =~ ^[A-Za-z0-9.-]+$ ]] || { err "域名格式不正确。"; return 1; }

  read -rp "是否同时开启 SOCKS5（公网 + 随机账号密码）？[Y/n]: " want_socks || return 1
  enable_socks=0
  socks_port=""
  socks_user=""
  socks_pass=""
  case "${want_socks:-Y}" in
    y|Y|yes|YES)
      enable_socks=1
      socks_port="$(choose_random_port "$port")" || { err "无法找到空闲的 SOCKS5 端口。"; return 1; }
      socks_user="$(rand_str 10)"
      socks_pass="$(rand_str 10)"
      echo "SOCKS5 端口：$socks_port（账号密码安装完成后一起输出）"
      ;;
    *) dim "跳过 SOCKS5。" ;;
  esac

  for svc in x-ui xray-standalone; do
    if systemctl cat "$svc.service" >/dev/null 2>&1; then
      if systemctl is-active --quiet "$svc" || systemctl is-enabled --quiet "$svc"; then
        local answer=""
        echo
        echo "检测到旧服务：$svc"
        read -rp "是否停止并禁用 $svc？[y/N]: " answer || return 1
        if [[ "$answer" =~ ^[Yy]$ ]]; then
          systemctl disable --now "$svc" || true
        else
          err "已退出，未继续安装。"
          return 1
        fi
      fi
    fi
  done

  echo
  echo "正在安装官方 Xray-core..."
  installer="$(mktemp --suffix=.sh /tmp/xray-install.XXXXXX)"
  TMP_INSTALLER="$installer"

  if ! curl -fsSL --connect-timeout 10 --max-time 300 -o "$installer" \
       https://github.com/XTLS/Xray-install/raw/main/install-release.sh; then
    err "下载官方安装脚本失败（GitHub 可能不可达），请检查网络后重试。"
    return 1
  fi
  [[ -s "$installer" ]] || { err "官方安装脚本为空。"; return 1; }

  bash "$installer" install
  rm -f "$installer"

  [[ -x "$XRAY_BIN" ]] || { err "没有找到 Xray 程序：$XRAY_BIN"; return 1; }

  echo "正在生成 UUID 和 REALITY 密钥..."
  uuid="$("$XRAY_BIN" uuid)"
  key_output="$("$XRAY_BIN" x25519)"

  private_key="$(
    printf '%s\n' "$key_output" |
    sed -nE 's/^(PrivateKey|Private key):[[:space:]]*//p' |
    head -n 1
  )"
  public_key="$(
    printf '%s\n' "$key_output" |
    sed -nE 's/^(Password \(PublicKey\)|Password|Public key):[[:space:]]*//p' |
    head -n 1
  )"

  [[ -n "$uuid" ]] || { err "UUID 生成失败。"; return 1; }
  [[ -n "$private_key" ]] || { err "REALITY 私钥生成失败。"; return 1; }
  [[ -n "$public_key" ]] || { err "REALITY 公钥生成失败。"; return 1; }

  short_id="$(openssl rand -hex 8)"
  mkdir -p "$(dirname "$CONFIG")"
  tmp_config="$(mktemp --suffix=.json /tmp/xray-config.XXXXXX)"
  TMP_CONFIG="$tmp_config"

  {
    cat <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
EOF
    if (( enable_socks )); then
      cat <<EOF
    {
      "listen": "0.0.0.0",
      "port": $socks_port,
      "protocol": "socks",
      "settings": {
        "auth": "password",
        "accounts": [
          {
            "user": "$socks_user",
            "pass": "$socks_pass"
          }
        ],
        "udp": true
      }
    },
EOF
    fi
    cat <<EOF
    {
      "listen": "0.0.0.0",
      "port": $port,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$uuid",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "$server_name:443",
          "serverNames": [
            "$server_name"
          ],
          "privateKey": "$private_key",
          "shortIds": [
            "$short_id"
          ]
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    }
  ]
}
EOF
  } > "$tmp_config"

  echo "正在检查 Xray 配置..."
  if ! "$XRAY_BIN" run -test -config "$tmp_config"; then
    err "配置校验失败，未做任何改动。"
    return 1
  fi

  xray_apply "$tmp_config" || return 1

  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow "$port/tcp" || true
    (( enable_socks )) && { ufw allow "$socks_port/tcp" || true; ufw allow "$socks_port/udp" || true; }
  fi

  server_addr="$(get_public_ip)"
  if [[ -z "$server_addr" ]]; then
    read -rp "无法自动获取公网 IP，请输入服务器 IP 或域名: " server_addr || return 1
  fi
  [[ -n "$server_addr" ]] || { err "服务器地址不能为空。"; return 1; }

  link="$(build_vless_link "$server_addr" "$port" "$uuid" "$server_name" "$public_key" "$short_id" "xtls-rprx-vision")"

  {
    echo "# Xray links — 生成于 $(date '+%Y-%m-%d %H:%M:%S')"
    echo "# host: $server_addr"
    echo "# REALITY  端口 $port  伪装域名 $server_name"
    echo "$link"
    if (( enable_socks )); then
      echo "# SOCKS5   端口 $socks_port  用户名 $socks_user  密码 $socks_pass"
      build_socks_link "$server_addr" "$socks_port" "$socks_user" "$socks_pass"
    fi
  } > "$LINKS_FILE"
  chmod 600 "$LINKS_FILE"

  install_shortcuts

  echo
  hr
  ok "安装完成"
  hr
  echo "服务状态：$(systemctl is-active xray)"
  echo
  echo "【REALITY】VLESS + REALITY + Vision"
  echo "端口: $port/TCP"
  echo "伪装域名: $server_name"
  echo "UUID: $uuid"
  echo "公钥: $public_key"
  echo "Short ID: $short_id"
  echo "链接:"
  echo "$link"
  echo
  if (( enable_socks )); then
    echo "SOCKS5"
    echo "地址: $server_addr"
    echo "端口: $socks_port"
    echo "用户名: $socks_user"
    echo "密码: $socks_pass"
    echo "链接: $(build_socks_link "$server_addr" "$socks_port" "$socks_user" "$socks_pass")"
    echo
    dim "注意：SOCKS5 是明文协议，只能自己用。"
    echo
  fi
  dim "已保存到：$LINKS_FILE"
  if (( enable_socks )); then
    dim "安全组放行：TCP $port，以及 TCP/UDP $socks_port"
  else
    dim "安全组放行：TCP $port"
  fi
}

# ============ 2. 查看链接 ============

show_links() {
  local host="${1:-}" found=0
  local port uuid flow sni pk sid user pass pbk link

  [[ -f "$CONFIG" ]] || { err "找不到 $CONFIG，请先安装。"; return 1; }
  ensure_jq || return 1

  if [[ -z "$host" ]]; then
    host="$(get_public_ip)"
  fi
  if [[ -z "$host" && -r "$LINKS_FILE" ]]; then
    host="$(sed -n 's/^# host:[[:space:]]*//p' "$LINKS_FILE" | head -n 1)"
  fi
  [[ -n "$host" ]] || { err "无法获取公网地址，请用：bash $SELF links 你的IP"; return 1; }

  echo
  hr
  echo " 当前链接"
  hr
  echo "服务状态: $(systemctl is-active xray 2>/dev/null || echo unknown)"
  echo "公网地址: $host"

  while IFS=$'\t' read -r port uuid flow sni pk sid; do
    [[ -n "$port" ]] || continue
    found=1
    pbk="$(derive_public_key "$pk")"
    if [[ -z "$pbk" && -r "$LINKS_FILE" ]]; then
      pbk="$(sed -n 's/.*[?&]pbk=\([^&#]*\).*/\1/p' "$LINKS_FILE" | head -n 1)"
    fi
    echo
    echo "【REALITY】VLESS + REALITY + Vision"
    echo "端口: $port/TCP"
    echo "伪装域名: $sni"
    echo "UUID: $uuid"
    echo "Short ID: $sid"
    if [[ -n "$pbk" ]]; then
      echo "公钥: $pbk"
      link="$(build_vless_link "$host" "$port" "$uuid" "$sni" "$pbk" "$sid" "$flow")"
      echo "链接:"
      echo "$link"
    else
      err "公钥无法从私钥推导，链接无法生成。"
    fi
  done < <(
    jq -r '.inbounds[]?
      | select(.streamSettings.security? == "reality")
      | [ (.port | tostring),
          ((.settings.clients // .settings.users)[0].id // ""),
          ((.settings.clients // .settings.users)[0].flow // "xtls-rprx-vision"),
          (.streamSettings.realitySettings.serverNames[0] // ""),
          (.streamSettings.realitySettings.privateKey // ""),
          (.streamSettings.realitySettings.shortIds[0] // "")
        ] | @tsv' "$CONFIG" 2>/dev/null || true
  )

  while IFS=$'\t' read -r port user pass; do
    [[ -n "$port" ]] || continue
    found=1
    echo
    echo "SOCKS5"
    echo "地址: $host"
    echo "端口: $port"
    echo "用户名: ${user:--}"
    echo "密码: ${pass:--}"
    link="$(build_socks_link "$host" "$port" "$user" "$pass")"
    echo "链接: $link"
  done < <(
    jq -r '.inbounds[]?
      | select(.protocol == "socks")
      | [ (.port | tostring),
          (.settings.accounts[0].user // ""),
          (.settings.accounts[0].pass // "")
        ] | @tsv' "$CONFIG" 2>/dev/null || true
  )

  if (( found == 0 )); then
    echo
    err "没能从配置里解析出入站。"
    if [[ -r "$LINKS_FILE" ]]; then
      dim "显示上次保存的内容："
      cat "$LINKS_FILE"
    fi
  fi
  echo
}

# ============ 3. 追加 SOCKS5 ============

add_socks5() {
  local existing answer replace=0 port user pass new_config test_out server_addr link pub

  [[ -f "$CONFIG" ]] || { err "找不到 $CONFIG，请先安装。"; return 1; }
  [[ -x "$XRAY_BIN" ]] || { err "找不到 $XRAY_BIN，请先安装。"; return 1; }
  ensure_jq || return 1

  existing="$(jq -r '[(.inbounds // [])[] | select(.protocol == "socks")] | length' "$CONFIG" 2>/dev/null || echo 0)"

  if [[ "$existing" != "0" ]]; then
    echo
    dim "配置里已有 SOCKS5 入站："
    jq -r '(.inbounds // [])[] | select(.protocol == "socks")
           | "  端口 " + (.port | tostring) + "   用户名 " + (.settings.accounts[0].user // "-")' "$CONFIG"
    echo
    read -rp "替换成新的端口和账号？[y/N]: " answer || return 1
    [[ "$answer" =~ ^[Yy]$ ]] || { dim "已取消。"; return 0; }
    replace=1
  fi

  port="$(choose_random_port)" || { err "无法找到空闲端口。"; return 1; }
  user="$(rand_str 10)"
  pass="$(rand_str 10)"

  new_config="$(mktemp --suffix=.json /tmp/xray-socks.XXXXXX)"
  TMP_NEW="$new_config"

  if ! jq --argjson port "$port" --arg user "$user" --arg pass "$pass" \
       --argjson replace "$replace" '
    .inbounds = (
        ((.inbounds // [])
          | map(select((.protocol != "socks") or ($replace == 0))))
        + [{
            "listen": "0.0.0.0",
            "port": $port,
            "protocol": "socks",
            "settings": {
              "auth": "password",
              "accounts": [ { "user": $user, "pass": $pass } ],
              "udp": true
            }
          }]
    )
  ' "$CONFIG" > "$new_config"; then
    err "生成新配置失败。"
    return 1
  fi

  if ! diff <(jq -S '[.inbounds[] | select(.protocol != "socks")]' "$CONFIG") \
            <(jq -S '[.inbounds[] | select(.protocol != "socks")]' "$new_config") >/dev/null; then
    err "安全检查未通过：已有入站发生变化，已中止。"
    return 1
  fi

  if ! test_out="$("$XRAY_BIN" run -test -config "$new_config" 2>&1)"; then
    printf '%s\n' "$test_out"
    err "新配置校验失败，原配置未改动。"
    return 1
  fi

  xray_apply "$new_config" || return 1

  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow "$port/tcp" || true
    ufw allow "$port/udp" || true
  fi

  server_addr="$(get_public_ip)"
  if [[ -z "$server_addr" ]]; then
    read -rp "无法自动获取公网 IP，请输入服务器 IP: " server_addr || return 1
  fi
  [[ -n "$server_addr" ]] || { err "服务器地址不能为空。"; return 1; }

  link="$(build_socks_link "$server_addr" "$port" "$user" "$pass")"

  {
    if [[ -r "$LINKS_FILE" ]]; then
      grep -v -E '^# SOCKS5|^socks5h://' "$LINKS_FILE" 2>/dev/null || true
    fi
    printf '# SOCKS5   端口 %s  用户名 %s  密码 %s\n%s\n' \
      "$port" "$user" "$pass" "$link"
  } > "${LINKS_FILE}.new"
  install -o root -g root -m 600 "${LINKS_FILE}.new" "$LINKS_FILE"
  rm -f "${LINKS_FILE}.new"

  echo
  hr
  echo " SOCKS5 已添加（原有 REALITY 未改动）"
  hr
  echo "SOCKS5"
  echo "地址: $server_addr"
  echo "端口: $port"
  echo "用户名: $user"
  echo "密码: $pass"
  echo "链接: $link"
  echo
  dim "之前的 REALITY 链接继续有效，可用菜单 2 查看。"
  dim "安全组记得放行 TCP $port（需要 UDP 转发再加 UDP）。"
}

# ============ 4. 端口转发 ============

pf_args() {   # proto lport mode tip tport
  PF_ARGS=(-p "$1" --dport "$2" -m comment --comment "pf:$1:$2->$4:$5")
  if [[ "$3" == "local" ]]; then
    PF_ARGS+=(-j REDIRECT --to-ports "$5")
  else
    PF_ARGS+=(-j DNAT --to-destination "$4:$5")
  fi
}

pf_fwd_chain() {   # add|del proto tip tport
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
    DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent >/dev/null 2>&1 || true
  fi
  if command -v netfilter-persistent >/dev/null 2>&1; then
    netfilter-persistent save >/dev/null 2>&1 && dim "规则已持久化。" || err "警告：规则保存失败。"
  else
    err "警告：没有 iptables-persistent，重启后规则会丢失。"
  fi
}

pf_list() {
  echo
  if [[ ! -f "$PF_STATE" || ! -s "$PF_STATE" ]]; then
    dim "当前没有任何端口转发规则。"
    return 0
  fi
  echo "当前端口转发规则："
  local i=0 lport proto mode target ts tip tport p st
  while IFS='|' read -r lport proto mode target ts; do
    [[ -n "$lport" ]] || continue
    i=$((i + 1))
    tip="${target%:*}"
    tport="${target##*:}"
    p="$proto"
    [[ "$proto" == "both" ]] && p="tcp"
    pf_args "$p" "$lport" "$mode" "$tip" "$tport"
    if iptables -w -t nat -C PREROUTING "${PF_ARGS[@]}" 2>/dev/null; then
      st="${C_OK}生效${C_0}"
    else
      st="${C_ERR}缺失${C_0}"
    fi
    if [[ "$mode" == "local" ]]; then
      printf '  %d) 对外 %s/%s -> %s  [本机]  %b  %s\n' "$i" "$lport" "$proto" "$target" "$st" "$ts"
    else
      printf '  %d) 对外 %s/%s -> %s  [跨机]  %b  %s\n' "$i" "$lport" "$proto" "$target" "$st" "$ts"
    fi
  done < "$PF_STATE"
}

pf_add() {
  local lport proto tip tport mode p ans pub
  local protos=()

  if ! command -v iptables >/dev/null 2>&1; then
    apt-get update -y >/dev/null 2>&1 || true
    apt-get install -y iptables >/dev/null 2>&1 || { err "安装 iptables 失败。"; return 1; }
  fi
  [[ -f "$PF_STATE" ]] || : > "$PF_STATE"
  chmod 600 "$PF_STATE"

  echo
  echo "== 添加端口转发 =="
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
    pub="$(get_public_ip)"
    if [[ -n "$pub" && "$tip" == "$pub" ]]; then
      err "注意：$tip 是本机公网 IP，转发到自己的公网 IP 会因 NAT 回环不通。"
      return 1
    fi
    dim "正在探测 $tip:$tport ..."
    if timeout 5 bash -c "echo > /dev/tcp/$tip/$tport" 2>/dev/null; then
      ok "落地端口可达。"
    else
      err "从本机连 $tip:$tport 失败。"
      dim "落地机要监听 0.0.0.0，且其安全组允许本机访问这个端口。"
      read -rp "仍然继续？[y/N]: " ans || return 1
      [[ "$ans" =~ ^[Yy]$ ]] || { dim "已取消。"; return 1; }
    fi
  fi

  if port_in_use "$lport"; then
    err "注意：本机已有服务在监听 $lport，转发会抢走这些连接。"
    read -rp "仍然继续？[y/N]: " ans || return 1
    [[ "$ans" =~ ^[Yy]$ ]] || { dim "已取消。"; return 1; }
  fi

  for p in "${protos[@]}"; do
    pf_args "$p" "$lport" "$mode" "$tip" "$tport"
    if iptables -w -t nat -C PREROUTING "${PF_ARGS[@]}" 2>/dev/null; then
      dim "已存在，跳过：$p  $lport -> $tip:$tport"
      continue
    fi
    iptables -w -t nat -A PREROUTING "${PF_ARGS[@]}"
    ok "已添加：$p  $lport -> $tip:$tport"
  done

  if [[ "$mode" == "remote" ]]; then
    echo 'net.ipv4.ip_forward=1' > "$SYSCTL_CONF"
    sysctl --system >/dev/null 2>&1 || true
    [[ "$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)" == "1" ]] ||
      err "警告：ip_forward 没开起来，跨机转发不会生效。"
    for p in "${protos[@]}"; do
      if ! iptables -w -t nat -C POSTROUTING -d "$tip" -p "$p" --dport "$tport" -j MASQUERADE 2>/dev/null; then
        iptables -w -t nat -A POSTROUTING -d "$tip" -p "$p" --dport "$tport" -j MASQUERADE
        dim "已添加回程 SNAT：$p  $tip:$tport"
      fi
      pf_fwd_chain add "$p" "$tip" "$tport"
    done
    dim "已放行 FORWARD 链。"
  fi

  printf '%s|%s|%s|%s:%s|%s\n' \
    "$lport" "$proto" "$mode" "$tip" "$tport" "$(date '+%Y-%m-%d %H:%M')" >> "$PF_STATE"

  pf_save
  echo
  ok "完成：对外 $lport/$proto -> $tip:$tport"
  dim "安全组放行对外端口 $lport；跨机时落地机也要放行 $tport。"
}

pf_remove_line() {   # line  force
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
    if iptables -w -t nat -C PREROUTING "${PF_ARGS[@]}" 2>/dev/null; then
      iptables -w -t nat -D PREROUTING "${PF_ARGS[@]}"
    fi
    if [[ "$mode" == "remote" ]]; then
      shared=0
      if [[ "$force" != "1" ]]; then
        if grep -F -v -x -- "$line" "$PF_STATE" 2>/dev/null | grep -qF "|${target}|"; then
          shared=1
        fi
      fi
      if (( shared == 0 )); then
        if iptables -w -t nat -C POSTROUTING -d "$tip" -p "$p" --dport "$tport" -j MASQUERADE 2>/dev/null; then
          iptables -w -t nat -D POSTROUTING -d "$tip" -p "$p" --dport "$tport" -j MASQUERADE
        fi
        pf_fwd_chain del "$p" "$tip" "$tport"
      fi
    fi
  done
  ok "已删除：对外 ${lport}/${proto} -> ${target}"
}

pf_del_one() {
  local total idx line
  [[ -s "$PF_STATE" ]] || { dim "没有可删除的规则。"; return 0; }
  pf_list
  total="$(pf_rule_count)"
  read -rp "要删除的序号（回车取消）: " idx || return 0
  [[ -z "$idx" ]] && { dim "已取消。"; return 0; }
  [[ "$idx" =~ ^[0-9]+$ ]] || { err "请输入数字序号。"; return 1; }
  idx="$((10#$idx))"
  (( idx >= 1 && idx <= total )) || { err "序号超出范围。"; return 1; }
  line="$(sed -n "${idx}p" "$PF_STATE")"
  [[ -n "$line" ]] || { err "没有第 $idx 条规则。"; return 1; }
  pf_remove_line "$line" 0
  sed -i "${idx}d" "$PF_STATE"
  pf_save
}

pf_del_all() {
  local total ans line
  total="$(pf_rule_count)"
  [[ "$total" == "0" ]] && { dim "没有可删除的规则。"; return 0; }
  pf_list
  read -rp "确认删除全部 $total 条？输入 yes 确认: " ans || return 0
  [[ "$ans" == "yes" ]] || { dim "已取消。"; return 0; }
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    pf_remove_line "$line" 1
  done < "$PF_STATE"
  : > "$PF_STATE"
  pf_save
  ok "已清空全部转发规则。"
}

fwd_menu() {
  local c
  while true; do
    echo
    hr
    printf ' 端口转发   现有规则：%s 条\n' "$(pf_rule_count)"
    hr
    echo "  1) 查看规则"
    echo "  2) 添加规则"
    echo "  3) 删除某一条"
    echo "  4) 删除全部"
    echo "  5) 查看 iptables 原始规则（排错）"
    echo "  6) 返回主菜单"
    hr
    if ! read -rp "请选择 [1-6]: " c; then echo; return 0; fi
    case "$c" in
      1) pf_list; pause_key ;;
      2) pf_add; pause_key ;;
      3) pf_del_one; pause_key ;;
      4) pf_del_all; pause_key ;;
      5)
        echo
        echo "== PREROUTING =="
        iptables -w -t nat -L PREROUTING -n -v --line-numbers 2>/dev/null || true
        echo
        echo "== POSTROUTING =="
        iptables -w -t nat -L POSTROUTING -n -v --line-numbers 2>/dev/null || true
        echo
        echo "== ip_forward =="
        cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || true
        pause_key
        ;;
      6|q|Q) return 0 ;;
      "") ;;
      *) err "无效选项：$c" ;;
    esac
  done
}

# ============ 5. 状态与日志 ============

show_status() {
  echo
  hr
  echo " 服务状态"
  hr
  if [[ ! -x "$XRAY_BIN" ]]; then
    err "未安装 Xray（$XRAY_BIN 不存在）。"
    return 0
  fi
  echo "服务: $(systemctl is-active xray 2>/dev/null || echo unknown)"
  echo "开机启动: $(systemctl is-enabled xray 2>/dev/null || echo unknown)"
  echo "配置文件: $CONFIG"
  [[ -f "$CONFIG" ]] && echo "REALITY 端口: $(reality_port)"
  echo
  systemctl status xray --no-pager -l 2>/dev/null | head -n 15 || true
  echo
  dim "最近 15 行日志："
  journalctl -u xray -n 15 --no-pager 2>/dev/null || true
}

# ============ 快捷命令 ============

install_shortcuts() {
  local n
  for n in xr xray-menu xray-links; do
    ln -sf "$SELF" "/usr/local/bin/$n" 2>/dev/null || true
  done
  dim "快捷命令：xr（菜单）/ xray-menu（菜单）/ xray-links（直接看链接）"
}

# ============ 主菜单 ============

show_main_menu() {
  local st rp
  st="$(systemctl is-active xray 2>/dev/null || echo unknown)"
  rp="$(reality_port)"
  echo
  hr
  printf '            Xray 工具箱\n'
  hr
  printf ' 服务: %s' "$st"
  [[ -n "$rp" ]] && printf '    REALITY 端口: %s' "$rp"
  printf '    转发规则: %s 条\n' "$(pf_rule_count)"
  hr
  echo "  1) 安装 / 重新安装（REALITY，可选 SOCKS5）"
  echo "  2) 查看已有链接"
  echo "  3) 追加 SOCKS5（不动现有 REALITY）"
  echo "  4) 端口转发管理"
  echo "  5) 查看服务状态与日志"
  echo "  6) 退出"
  hr
}

main_menu() {
  local c
  while true; do
    show_main_menu
    if ! read -rp "请选择 [1-6]: " c; then echo; break; fi
    case "$c" in
      1) install_reality; pause_key ;;
      2) show_links; pause_key ;;
      3) add_socks5; pause_key ;;
      4) fwd_menu ;;
      5) show_status; pause_key ;;
      6|q|Q|exit) break ;;
      "") ;;
      *) err "无效选项：$c" ;;
    esac
  done
  echo
  dim "已退出。服务和规则都还在运行。"
}

usage() {
  cat <<'USAGE'
用法：
  bash xray-menu.sh            进入菜单（推荐）
  bash xray-menu.sh links      直接查看链接
  bash xray-menu.sh install    直接安装 / 重装
  bash xray-menu.sh socks      直接追加 SOCKS5
  bash xray-menu.sh fwd        端口转发子菜单

安装过一次后会有快捷命令：xr / xray-menu / xray-links
USAGE
}

# ============ 入口 ============

case "$(basename "$0")" in
  xray-links) show_links; exit 0 ;;
  pf)         fwd_menu; exit 0 ;;
esac

case "${1:-}" in
  "")        main_menu ;;
  links)     show_links ;;
  install)   install_reality ;;
  socks)     add_socks5 ;;
  fwd)       fwd_menu ;;
  shortcuts) install_shortcuts ;;
  -h|--help) usage ;;
  *)         err "未知参数：$1（用 -h 查看用法）"; exit 1 ;;
esac
