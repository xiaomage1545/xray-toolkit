#!/usr/bin/env bash
set -Eeuo pipefail

# 只给现有 Xray 配置追加一个 SOCKS5 入站，已有的 REALITY 等入站原样保留。
#
#   bash add-socks5.sh            追加 SOCKS5（若已存在则直接退出，不重复添加）
#   bash add-socks5.sh --replace  删掉已有的 SOCKS5，重新生成端口和账号

CONFIG="/usr/local/etc/xray/config.json"
XRAY_BIN="/usr/local/bin/xray"
SELF="$(readlink -f "$0" 2>/dev/null || echo "$0")"

die() {
  echo "错误：$*" >&2
  exit 1
}

REPLACE=0
case "${1:-}" in
  "")        REPLACE=0 ;;
  --replace) REPLACE=1 ;;
  -h|--help)
    echo "用法："
    echo "  bash $SELF            追加 SOCKS5（已存在则退出）"
    echo "  bash $SELF --replace  重新生成 SOCKS5（先删旧的）"
    exit 0
    ;;
  *) die "未知参数：$1（可用 --replace / --help）" ;;
esac

[[ ${EUID} -eq 0 ]] || die "请使用 root 运行。"
[[ -x "$XRAY_BIN" ]] || die "找不到 $XRAY_BIN，请先运行 install-xray-reality.sh。"
[[ -f "$CONFIG" ]] || die "找不到 $CONFIG，请先运行 install-xray-reality.sh。"

if ! command -v jq >/dev/null 2>&1; then
  echo "正在安装 jq..."
  apt-get update -y >/dev/null 2>&1 || true
  apt-get install -y jq >/dev/null 2>&1 ||
    die "安装 jq 失败，请手动执行：apt-get install -y jq"
fi

EXISTING="$(jq -r '[(.inbounds // [])[] | select(.protocol == "socks")] | length' "$CONFIG" 2>/dev/null)" ||
  die "无法解析 $CONFIG（可能不是合法 JSON）。"

if [[ "$EXISTING" != "0" && "$REPLACE" != "1" ]]; then
  echo "配置里已经存在 SOCKS5 入站，为避免重复，本次不做任何修改："
  jq -r '(.inbounds // [])[] | select(.protocol == "socks")
         | "  端口 " + (.port | tostring)
           + "   用户名 " + (.settings.accounts[0].user // "-")' "$CONFIG"
  echo
  echo "想换一套端口和账号，请用：bash $SELF --replace"
  exit 1
fi

PORT=""
for _ in $(seq 1 500); do
  CAND="$(shuf -i 20000-60000 -n 1)"
  if [[ -z "$(ss -H -ltn "sport = :$CAND" 2>/dev/null)" ]]; then
    PORT="$CAND"
    break
  fi
done
[[ -n "$PORT" ]] || die "无法找到空闲端口。"

USER_NAME="$(openssl rand -base64 32 | LC_ALL=C tr -dc 'A-Za-z0-9' | cut -c1-10)"
PASS_WORD="$(openssl rand -base64 32 | LC_ALL=C tr -dc 'A-Za-z0-9' | cut -c1-10)"

NEW_CONFIG="$(mktemp --suffix=.json /tmp/xray-socks.XXXXXX)"
trap 'rm -f "$NEW_CONFIG"' EXIT

jq --argjson port "$PORT" \
   --arg user "$USER_NAME" \
   --arg pass "$PASS_WORD" \
   --argjson replace "$REPLACE" '
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
' "$CONFIG" > "$NEW_CONFIG" || die "生成新配置失败。"

# 硬性检查：除 socks 以外的入站必须与原配置完全一致（保证 REALITY 链接不变）
if ! diff <(jq -S '[.inbounds[] | select(.protocol != "socks")]' "$CONFIG") \
          <(jq -S '[.inbounds[] | select(.protocol != "socks")]' "$NEW_CONFIG") >/dev/null; then
  die "安全检查未通过：已有入站发生了变化，已中止，原配置未改动。"
fi

# 先让 Xray 自己校验，通过后才落盘
if ! TEST_OUT="$("$XRAY_BIN" run -test -config "$NEW_CONFIG" 2>&1)"; then
  printf '%s\n' "$TEST_OUT"
  die "新配置校验失败，已中止，原配置未改动。"
fi

BACKUP="${CONFIG}.bak.$(date +%Y%m%d-%H%M%S)"
cp -a "$CONFIG" "$BACKUP"
install -o root -g root -m 644 "$NEW_CONFIG" "$CONFIG"
echo "原配置已备份：$BACKUP"

if ! systemctl restart xray; then
  journalctl -u xray -n 40 --no-pager || true
  cp -a "$BACKUP" "$CONFIG"
  systemctl restart xray || true
  die "Xray 启动失败，已回滚原配置。"
fi

sleep 2

if ! systemctl is-active --quiet xray; then
  journalctl -u xray -n 40 --no-pager || true
  cp -a "$BACKUP" "$CONFIG"
  systemctl restart xray || true
  die "Xray 没有正常运行，已回滚原配置。"
fi

if command -v ufw >/dev/null 2>&1 &&
   ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw allow "$PORT/tcp" || true
  ufw allow "$PORT/udp" || true
fi

SERVER_ADDR="$(curl -4 -fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)"
if [[ -z "$SERVER_ADDR" ]]; then
  read -rp "无法自动获取公网 IP，请输入服务器 IP: " SERVER_ADDR
fi
[[ -n "$SERVER_ADDR" ]] || die "服务器地址不能为空。"

HOST="$SERVER_ADDR"
if [[ "$SERVER_ADDR" == *:* && "$SERVER_ADDR" != \[*\] ]]; then
  HOST="[$SERVER_ADDR]"
fi

LINK="socks5h://${USER_NAME}:${PASS_WORD}@${HOST}:${PORT}#Xray-SOCKS5-${PORT}"

echo
echo "========================================"
echo "          SOCKS5 已添加"
echo "========================================"
echo "SOCKS5"
echo "地址: $SERVER_ADDR"
echo "端口: $PORT"
echo "用户名: $USER_NAME"
echo "密码: $PASS_WORD"
echo "链接: $LINK"
echo
echo "原有的 REALITY 入站没有被改动，之前的链接继续有效。"
echo "查看全部链接：xray-links"
echo "还需在服务商安全组开放 TCP $PORT（需要 UDP 转发再开 UDP）。"
echo
