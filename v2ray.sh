#!/usr/bin/env bash
# =============================================================================
# v2ray.sh — V2Fly v5 + Caddy 2（VMess + WebSocket + TLS）一键安装与管理
#
# 用法（在服务器上以 root 运行）:
#   bash <(curl -fsSL https://raw.githubusercontent.com/hillghost86/v2ray-auto-setup/main/v2ray.sh)
#   curl -fsSL .../v2ray.sh | bash -s -- install
#   支持的子命令: install | update | status | show | uninstall
#
# 文件位置:
#   /root/v2ray-stack/.env          域名、UUID、路径、镜像版本（脚本与 compose 共用）
#   /root/v2ray-stack/compose.yaml  容器定义（V2Ray 与 Caddy 配置内嵌其中）
#   Docker 数据卷 caddy_data         HTTPS 证书
# =============================================================================
# 换行符自愈：Windows 格式（CRLF）会让脚本无法运行，这里自动去掉 \r 后重新执行。
# 必须先确认脚本是磁盘上的普通文件：通过 bash <(curl ...) 运行时脚本来自管道，
# 再去读它会把数据从 bash 自己手里抢走，导致脚本被截断（管道场景也不会有 CRLF）。
# 下面这行必须保持单行，行尾注释用来兜住可能存在的 \r
_s=${BASH_SOURCE[0]:-$0}; if [[ -f $_s ]] && IFS= read -r _l < "$_s" 2>/dev/null && [[ $_l == *$'\r' ]]; then _f=$(mktemp); sed 's/\r$//' "$_s" > "$_f"; exec bash "$_f" "$@"; fi; unset -v _s _l # crlf-guard

set -euo pipefail

STACK_DIR=/root/v2ray-stack
ENV_FILE="$STACK_DIR/.env"
COMPOSE_FILE="$STACK_DIR/compose.yaml"
MIN_COMPOSE=2.23.1

red()  { printf '\033[31m%s\033[0m\n' "$*"; }
grn()  { printf '\033[32m%s\033[0m\n' "$*"; }
ylw()  { printf '\033[33m%s\033[0m\n' "$*"; }
step() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
die()  { red "✗ $*"; exit 1; }

# 交互输入：优先从终端读取，兼容 bash <(curl ...) 和 curl | bash 两种写法
if { exec 3</dev/tty; } 2>/dev/null; then IN=3; else IN=0; fi

ask() {  # ask "提示" "默认值" → 输出用户输入或默认值
  local reply
  read -r -u "$IN" -p "$1${2:+ [$2]}: " reply || true
  printf '%s' "${reply:-$2}"
}

confirm() {  # confirm "提示" y|n
  local def=${2:-n} reply
  read -r -u "$IN" -p "$1 $([[ $def == y ]] && echo '[Y/n]' || echo '[y/N]'): " reply || true
  reply=${reply:-$def}
  [[ $reply =~ ^[Yy]$ ]]
}

compose() { docker compose --project-directory "$STACK_DIR" "$@"; }

# ---------------------------------------------------------------------------
# 退出时的清理：临时网页服务、临时测试容器、被停掉的 Caddy
# ---------------------------------------------------------------------------
CHECK_PID=""
CADDY_STOPPED=no
TMP_DIRS=()

cleanup() {
  # 清理不能因为某一步失败就中断：docker rm 在容器本来就不存在时会返回非 0，
  # 若保留 set -e，后面「恢复 Caddy」就被跳过了，服务会一直停着
  set +e
  [[ -n $CHECK_PID ]] && kill "$CHECK_PID" 2>/dev/null
  docker rm -f v2ray-e2e >/dev/null 2>&1
  if [[ $CADDY_STOPPED == yes ]]; then
    ylw "正在恢复 Caddy 运行…"
    compose start caddy >/dev/null 2>&1
  fi
  ((${#TMP_DIRS[@]})) && rm -rf "${TMP_DIRS[@]}"
  return 0
}
trap cleanup EXIT INT TERM

mktmp() { local d; d=$(mktemp -d); TMP_DIRS+=("$d"); printf '%s' "$d"; }

# ---------------------------------------------------------------------------
# 状态
# ---------------------------------------------------------------------------
load_env() {
  DOMAIN="" UUID="" WS_PATH="" CDN="no" V2FLY_TAG="latest" CADDY_TAG="2"
  if [[ -f $ENV_FILE ]]; then
    # shellcheck disable=SC1090
    source "$ENV_FILE"
  fi
  : "${V2FLY_TAG:=latest}" "${CADDY_TAG:=2}"
}

save_env() {
  mkdir -p "$STACK_DIR"
  cat > "$ENV_FILE" <<EOF
DOMAIN=$DOMAIN
UUID=$UUID
WS_PATH=$WS_PATH
CDN=$CDN
V2FLY_TAG=$V2FLY_TAG
CADDY_TAG=$CADDY_TAG
EOF
  chmod 600 "$ENV_FILE"
}

stack_running() { [[ -n "$(docker ps -q --filter name='^caddy$' 2>/dev/null)" ]]; }

# ---------------------------------------------------------------------------
# 环境准备
# ---------------------------------------------------------------------------
preflight() {
  [[ $EUID -eq 0 ]] || die "请先执行 sudo -i 切换到 root 再运行"
  command -v apt-get >/dev/null || die "目前只支持 Debian / Ubuntu"
  command -v systemctl >/dev/null || die "需要 systemd"
}

need_docker() {
  command -v docker >/dev/null || die "没有检测到 Docker，请先运行本脚本的「安装」"
  docker compose version >/dev/null 2>&1 || die "没有检测到 Docker Compose，请先运行本脚本的「安装」"
  docker info >/dev/null 2>&1 || die "Docker 没有运行，请执行: systemctl start docker"
}

install_deps() {
  step "安装基础依赖"
  local pkgs=() p
  for p in curl ca-certificates qrencode openssl python3; do
    dpkg -s "$p" &>/dev/null || pkgs+=("$p")
  done
  if ((${#pkgs[@]})); then
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${pkgs[@]}" >/dev/null
  fi
  grn "✓ 依赖已就绪"
}

install_docker() {
  step "安装 Docker"
  if ! command -v docker >/dev/null; then
    curl -fsSL https://get.docker.com | sh
  fi
  systemctl enable --now docker >/dev/null 2>&1
  docker compose version >/dev/null 2>&1 || DEBIAN_FRONTEND=noninteractive apt-get install -y -qq docker-compose-plugin >/dev/null
  local v
  v=$(docker compose version --short 2>/dev/null | sed 's/^v//' || true)
  [[ -n $v ]] || die "Docker Compose 安装失败"
  [[ "$(printf '%s\n%s\n' "$MIN_COMPOSE" "$v" | sort -V | head -1)" == "$MIN_COMPOSE" ]] \
    || die "Docker Compose 版本 $v 太旧，需要 $MIN_COMPOSE 以上"
  grn "✓ $(docker --version)，Compose $v"
}

public_ip() {
  curl -fsS4 --max-time 5 https://api.ipify.org 2>/dev/null \
    || curl -fsS4 --max-time 5 https://ifconfig.me 2>/dev/null || echo "未知"
}

port_in_use() { [[ -n "$(ss -Htln "sport = :$1" 2>/dev/null)" ]]; }

open_ufw() {
  if command -v ufw >/dev/null && LC_ALL=C ufw status 2>/dev/null | grep -q '^Status: active'; then
    ufw allow 80/tcp >/dev/null; ufw allow 443/tcp >/dev/null
    grn "✓ ufw 已放行 80、443"
  fi
}

# ---------------------------------------------------------------------------
# 域名检查：临时开一个网页服务，再从外部经域名访问它
# 一次验证了 DNS 解析、Lightsail 防火墙 80 端口、Cloudflare 转发是否正常
# ---------------------------------------------------------------------------
check_ipv6() {
  local aaaa local6
  aaaa=$(getent ahostsv6 "$DOMAIN" 2>/dev/null | awk '{print $1}' | grep -v '^::ffff:' | sort -u | tr '\n' ' ' || true)
  [[ -z $aaaa ]] && return 0
  local6=$(ip -6 addr show scope global 2>/dev/null | awk '/inet6/{print $2}' | cut -d/ -f1 | tr '\n' ' ' || true)
  echo "域名 IPv6 解析: $aaaa"
  if [[ $CDN == yes ]]; then
    echo "  （CDN 模式下这是 Cloudflare 的地址，正常）"
    return 0
  fi
  local a
  for a in $aaaa; do
    if [[ " $local6 " == *" $a "* ]]; then return 0; fi
  done
  ylw "⚠ 域名的 IPv6 解析（AAAA 记录）不是本机地址。本机 IPv6: ${local6:-无}"
  ylw "  建议在 DNS 里删掉这条 AAAA 记录，否则证书申请或客户端连接可能失败"
}

check_domain() {
  step "检查域名 $DOMAIN 是否指向本机"
  local ip resolved token dir got
  ip=$(public_ip)
  resolved=$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ' || true)
  echo "本机公网 IP:   $ip"
  echo "域名当前解析: ${resolved:-（解析失败）}"
  check_ipv6

  port_in_use 80 && die "80 端口被占用，无法检查。先查明占用程序：ss -tlnp | grep ':80 '"

  token=$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')
  dir=$(mktmp)
  mkdir -p "$dir/.well-known/v2ray-check"
  printf '%s' "$token" > "$dir/.well-known/v2ray-check/token"
  python3 -m http.server 80 --bind 0.0.0.0 --directory "$dir" >/dev/null 2>&1 &
  CHECK_PID=$!
  sleep 1
  got=$(curl -fsS --max-time 10 "http://$DOMAIN/.well-known/v2ray-check/token" 2>/dev/null || true)
  kill "$CHECK_PID" 2>/dev/null || true
  wait "$CHECK_PID" 2>/dev/null || true
  CHECK_PID=""

  if [[ "$got" == "$token" ]]; then
    grn "✓ 通过域名能访问到本机，可以申请证书"
    return 0
  fi

  red "✗ 通过域名访问不到本机"
  if [[ $CDN == yes ]]; then
    echo "  请检查: 1) Cloudflare 里域名的 A 记录是否指向 $ip"
    echo "          2) Lightsail 防火墙是否放行 TCP 80"
    echo "          3) Cloudflare 的「始终使用 HTTPS」是否已关闭"
  else
    echo "  请检查: 1) 域名 A 记录是否已改成 $ip（刚改的话等几分钟再试）"
    echo "          2) Lightsail 防火墙是否放行 TCP 80"
    echo "          3) 如果域名在 Cloudflare，云朵是否为灰色（仅 DNS）"
  fi
  confirm "仍然继续安装？（证书可能申请失败）" n || exit 1
}

# ---------------------------------------------------------------------------
# 配置
# ---------------------------------------------------------------------------
prompt_config() {
  step "填写配置（直接回车使用方括号里的值）"
  local d u p
  while :; do
    d=$(ask "域名" "$DOMAIN")
    [[ $d =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$ ]] && break
    red "域名格式不对，请重新输入"
  done
  while :; do
    u=$(ask "UUID（回车随机生成）" "${UUID:-$(cat /proc/sys/kernel/random/uuid)}")
    [[ $u =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] && break
    red "UUID 格式不对，请重新输入"
  done
  while :; do
    p=$(ask "WebSocket 路径（回车随机生成）" "${WS_PATH:-/$(head -c 6 /dev/urandom | od -An -tx1 | tr -d ' \n')}")
    [[ $p != /* ]] && p="/$p"
    [[ $p =~ ^/[A-Za-z0-9._~-]+$ ]] && break
    red "路径只能包含字母、数字和 . _ ~ -，请重新输入"
  done
  if confirm "是否通过 Cloudflare CDN 转发？" "$([[ $CDN == yes ]] && echo y || echo n)"; then CDN=yes; else CDN=no; fi

  DOMAIN_CHANGED=no
  [[ "$d" != "$DOMAIN" ]] && DOMAIN_CHANGED=yes
  DOMAIN=$d UUID=${u,,} WS_PATH=$p

  echo
  echo "  域名:  $DOMAIN"
  echo "  UUID:  $UUID"
  echo "  路径:  $WS_PATH"
  echo "  CDN:   $CDN"
  echo "  镜像:  v2fly/v2fly-core:$V2FLY_TAG , caddy:$CADDY_TAG"
  confirm "确认以上配置？" y || exit 1
}

write_compose() {
  mkdir -p "$STACK_DIR"
  cat > "$COMPOSE_FILE" <<'EOF'
# 由 v2ray.sh 生成。域名、UUID、路径、镜像版本读取同目录的 .env
name: v2ray

services:
  v2ray:
    image: v2fly/v2fly-core:${V2FLY_TAG}
    container_name: v2ray
    restart: unless-stopped
    command: run -c /etc/v2ray/config.json
    configs:
      - source: v2ray_config
        target: /etc/v2ray/config.json

  caddy:
    image: caddy:${CADDY_TAG}
    container_name: caddy
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    configs:
      - source: caddyfile
        target: /etc/caddy/Caddyfile
    volumes:
      - caddy_data:/data
      - caddy_config:/config
    depends_on:
      - v2ray

configs:
  v2ray_config:
    content: |
      {
        "log": { "loglevel": "warning" },
        "inbounds": [{
          "port": 2333,
          "listen": "0.0.0.0",
          "protocol": "vmess",
          "settings": { "clients": [{ "id": "${UUID}", "alterId": 0 }] },
          "streamSettings": { "network": "ws", "wsSettings": { "path": "${WS_PATH}" } }
        }],
        "outbounds": [{ "protocol": "freedom", "settings": {} }]
      }
  caddyfile:
    content: |
      ${DOMAIN} {
      	handle ${WS_PATH} {
      		reverse_proxy v2ray:2333
      	}
      	handle {
      		header Content-Type "text/html; charset=utf-8"
      		respond "<!doctype html><html><head><title>It works!</title></head><body><h1>It works!</h1></body></html>" 200
      	}
      }

volumes:
  caddy_data:
    name: caddy_data
  caddy_config:
    name: caddy_config
EOF
  compose config -q || die "compose.yaml 校验失败"
}

vmess_link() {
  local json
  json=$(printf '{"v":"2","ps":"%s","add":"%s","port":"443","id":"%s","aid":"0","scy":"auto","net":"ws","type":"none","host":"%s","path":"%s","tls":"tls","sni":"%s"}' \
    "$DOMAIN" "$DOMAIN" "$UUID" "$DOMAIN" "$WS_PATH" "$DOMAIN")
  printf 'vmess://%s' "$(printf '%s' "$json" | base64 -w0)"
}

# ---------------------------------------------------------------------------
# 自检
# ---------------------------------------------------------------------------
# 一、证书与 WebSocket：本机模拟一次握手，返回 101 说明 Caddy→V2Ray 链路正常
# Sec-WebSocket-Key 必须是 16 字节随机值的 base64（RFC 6455），V2Ray 用的
# gorilla/websocket 会校验解码后的长度，不是 16 字节一律回 400。下面用的是
# RFC 里的示例值（解码为 the sample nonce，正好 16 字节）。
# 不能用管道接 grep：握手成功后 curl 会一直等着读隧道数据，直到 --max-time
# 超时并以 28 退出，而脚本开了 pipefail，管道整体就成了失败——越成功越判失败。
ws_ok() {
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' --http1.1 --max-time 5 \
    --resolve "$DOMAIN:443:127.0.0.1" \
    -H "Connection: Upgrade" -H "Upgrade: websocket" \
    -H "Sec-WebSocket-Version: 13" -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
    "https://$DOMAIN$WS_PATH" 2>/dev/null) || true
  [[ ${code//[[:space:]]/} == 101 ]]
}

# 二、真实连接：启动一个临时 V2Ray 客户端，用当前 UUID 走一遍代理访问外网
#    能通过说明 UUID、路径、TLS 全部正确，而不只是端口通
e2e_ok() {
  local net dir hostport code
  net=$(docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' caddy 2>/dev/null | awk '{print $1}')
  [[ -n $net ]] || return 1
  dir=$(mktmp); chmod 755 "$dir"
  cat > "$dir/config.json" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [{ "listen": "0.0.0.0", "port": 10808, "protocol": "socks", "settings": { "udp": false } }],
  "outbounds": [{
    "protocol": "vmess",
    "settings": { "vnext": [{ "address": "caddy", "port": 443,
      "users": [{ "id": "$UUID", "alterId": 0, "security": "auto" }] }] },
    "streamSettings": {
      "network": "ws",
      "security": "tls",
      "tlsSettings": { "serverName": "$DOMAIN", "allowInsecure": true },
      "wsSettings": { "path": "$WS_PATH", "headers": { "Host": "$DOMAIN" } }
    }
  }]
}
EOF
  chmod 644 "$dir/config.json"
  docker rm -f v2ray-e2e >/dev/null 2>&1 || true
  docker run -d --name v2ray-e2e --network "$net" -p 127.0.0.1::10808 \
    -v "$dir/config.json:/etc/v2ray/config.json:ro" \
    "v2fly/v2fly-core:$V2FLY_TAG" run -c /etc/v2ray/config.json >/dev/null 2>&1 || return 1
  sleep 3
  hostport=$(docker port v2ray-e2e 10808/tcp 2>/dev/null | head -1 | sed 's/.*://')
  if [[ -n $hostport ]]; then
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 \
      --socks5-hostname "127.0.0.1:$hostport" http://cp.cloudflare.com/generate_204 2>/dev/null || true)
    [[ $code != 204 ]] && code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 \
      --socks5-hostname "127.0.0.1:$hostport" http://www.gstatic.com/generate_204 2>/dev/null || true)
  fi
  docker rm -f v2ray-e2e >/dev/null 2>&1 || true
  [[ ${code:-} == 204 ]]
}

# 三、CDN 边缘：上面两项都刻意绕开了 Cloudflare（ws_ok 用 --resolve 打本机，
#    e2e_ok 走 Docker 内网直连 caddy），源站再正常也照不出边缘的毛病。
#    这里按域名真实解析走一遍，客户端实际走的就是这条路。
cdn_ok() {
  curl -s -o /dev/null --max-time 10 "https://$DOMAIN/" 2>/dev/null
}

cdn_hint() {
  red "✗ 经 Cloudflare 访问失败，但源站是好的——问题在 CDN 这一跳"
  echo "  最常见原因：免费版 Universal SSL 只签 example.com 和 *.example.com，"
  echo "  通配符不覆盖 a.b.example.com 这种多级子域，边缘拿不出证书就直接握手失败。"
  echo "  自查: echo | openssl s_client -connect $DOMAIN:443 -servername $DOMAIN 2>&1 | head -5"
  echo "        出现 no peer certificate available 即是此问题"
  echo "  解决: 1) 换成一级子域（推荐，如 xxx.example.com）"
  echo "        2) 云朵改灰（仅 DNS），同时把本脚本的 CDN 选项改成 no"
  echo "        3) 购买 Advanced Certificate Manager 开启 Total TLS"
}

wait_ready() {
  step "等待证书申请和服务启动（最多 3 分钟）"
  local ok=no
  for _ in $(seq 1 36); do
    if ws_ok; then ok=yes; break; fi
    printf '.'; sleep 5
  done
  echo
  if [[ $ok != yes ]]; then
    red "✗ 3 分钟内没有就绪，Caddy 最近的日志："
    docker logs --tail 20 caddy 2>&1 | grep -iE 'error|obtain|challenge' || docker logs --tail 20 caddy
    return 1
  fi
  grn "✓ HTTPS 证书有效，WebSocket 握手成功"

  step "真实连接测试（用当前 UUID 走一遍代理）"
  if e2e_ok; then
    grn "✓ 代理连通，UUID、路径、TLS 均正确"
    [[ $CDN != yes ]] && return 0
    step "经 Cloudflare 边缘测试（客户端实际走的路径）"
    if cdn_ok; then
      grn "✓ 通过 Cloudflare 也能正常访问"
      return 0
    fi
    cdn_hint
    return 1
  fi
  red "✗ 代理连不通。端口和证书没问题，多半是 UUID 或路径没生效"
  echo "  V2Ray 日志："
  docker logs --tail 20 v2ray 2>&1 | tail -20
  return 1
}

# ---------------------------------------------------------------------------
# 子命令
# ---------------------------------------------------------------------------
cmd_show() {
  local mode=${1:-auto} cols need
  load_env
  [[ -n $DOMAIN ]] || die "还没有安装，请先运行「安装」"
  step "客户端配置"
  cat <<EOF
  地址:     $DOMAIN
  端口:     443
  UUID:     $UUID
  Alter Id: 0
  加密:     auto
  传输:     websocket
  路径:     $WS_PATH
  Host/SNI: $DOMAIN
  TLS:      开启
EOF
  echo
  echo "导入链接（v2rayN / Shadowrocket 可直接粘贴）："
  vmess_link; echo
  [[ $mode == plain ]] && return 0
  command -v qrencode >/dev/null || return 0
  # 二维码宽度取决于链接长度，不能写死 80 列。ASCII 输出每个模块占 2 列，
  # ANSIUTF8 占 1 列，所以真正需要的列数是 ASCII 宽度的一半。宽度不够时折行，
  # 图案会彻底错乱，不如直接跳过
  need=$(vmess_link | qrencode -t ASCII 2>/dev/null \
    | awk '{ if (length($0) > m) m = length($0) } END { print int(m / 2) }' || true)
  [[ ${need:-0} -gt 0 ]] || need=80   # 量不出来就退回原来的固定阈值，别把二维码整个吞掉
  cols=$(tput cols 2>/dev/null || echo 80)
  if (( cols < need )); then
    ylw "二维码需要 $need 列，当前终端 $cols 列，已跳过。拉宽窗口后运行「显示链接」即可"
    return 0
  fi
  echo
  echo "Shadowrocket 扫码导入（显示错乱时可只用上面的链接）："
  vmess_link | qrencode -t ANSIUTF8
}

cmd_install() {
  preflight
  ylw "开始前请确认：Lightsail 防火墙已放行 TCP 80 和 443；域名 A 记录已指向本机静态 IP"
  load_env
  prompt_config
  install_deps
  install_docker
  open_ufw

  if stack_running && [[ $DOMAIN_CHANGED == yes ]]; then
    ylw "域名有变化，先停止 Caddy 以便检查新域名（脚本中途退出会自动恢复）"
    compose stop caddy >/dev/null
    CADDY_STOPPED=yes
  fi
  if ! stack_running; then
    check_domain
  fi

  step "写入配置并启动"
  save_env
  write_compose
  compose pull -q
  # 配置内嵌在 compose.yaml 里，只改内容时 Compose 不会重建容器，
  # 会导致新 UUID / 路径不生效，所以这里强制重建
  compose up -d --force-recreate --remove-orphans
  CADDY_STOPPED=no

  # 自检没过也要把配置打出来：容器此时已经在跑，链接可能本来就是能用的，
  # 直接 die 掉等于让人白装一场
  if ! wait_ready; then
    echo
    ylw "自检未通过，但容器已经启动。下面是当前配置，可先自行验证；"
    ylw "排查后重新运行本脚本即可，也可以用「查看运行状态」再测一次。"
    cmd_show
    exit 1
  fi

  cmd_show
  echo
  if [[ $CDN == yes ]]; then
    ylw "Cloudflare 设置：云朵改为橙色（已代理）；SSL/TLS 模式选「完全（严格）」；网络里 WebSockets 保持开启；不要开启「始终使用 HTTPS」"
  fi
  grn "安装完成。以后重新运行本脚本即可更新、查看状态或修改配置。"
}

cmd_update() {
  preflight; need_docker
  [[ -f $COMPOSE_FILE ]] || die "还没有安装，请先运行「安装」"
  load_env
  local old_v2 old_caddy
  old_v2=$(docker inspect -f '{{.Image}}' v2ray 2>/dev/null || true)
  old_caddy=$(docker inspect -f '{{.Image}}' caddy 2>/dev/null || true)

  step "拉取最新镜像并重建容器"
  compose pull -q
  compose up -d --force-recreate --remove-orphans

  if wait_ready; then
    # 新版本没问题，再删掉旧镜像，保证升级失败时还能回退
    [[ -n $old_v2 ]] && docker rmi "$old_v2" >/dev/null 2>&1
    [[ -n $old_caddy ]] && docker rmi "$old_caddy" >/dev/null 2>&1
    cmd_status
    return 0
  fi

  red "新版本有问题"
  if [[ -n $old_v2 || -n $old_caddy ]] && confirm "是否回退到更新前的版本？" y; then
    [[ -n $old_v2 ]] && docker tag "$old_v2" v2fly/v2fly-core:rollback && V2FLY_TAG=rollback
    [[ -n $old_caddy ]] && docker tag "$old_caddy" caddy:rollback && CADDY_TAG=rollback
    save_env; write_compose
    compose up -d --force-recreate
    wait_ready && grn "✓ 已回退到更新前的版本" || red "回退后仍不正常，请查看日志"
  else
    die "更新后服务未就绪"
  fi
}

cmd_status() {
  need_docker
  [[ -f $COMPOSE_FILE ]] || die "还没有安装"
  load_env
  step "容器状态"
  compose ps --format 'table {{.Name}}\t{{.Status}}'
  step "版本"
  docker exec v2ray v2ray version 2>/dev/null | head -1 || true
  docker exec caddy caddy version 2>/dev/null | head -1 || true
  echo "配置中的镜像标签: v2fly/v2fly-core:$V2FLY_TAG , caddy:$CADDY_TAG"
  step "证书"
  echo | openssl s_client -connect 127.0.0.1:443 -servername "$DOMAIN" 2>/dev/null \
    | openssl x509 -noout -issuer -enddate 2>/dev/null || red "读取证书失败"
  step "链路自检"
  if ws_ok; then grn "✓ 证书和 WebSocket 正常"; else red "✗ WebSocket 握手失败: docker logs --tail 50 caddy"; fi
  if e2e_ok; then grn "✓ 代理连通"; else red "✗ 代理连不通: docker logs --tail 50 v2ray"; fi
  if [[ $CDN == yes ]]; then
    if cdn_ok; then grn "✓ 经 Cloudflare 边缘访问正常"; else cdn_hint; fi
  fi
}

cmd_uninstall() {
  preflight; need_docker
  [[ -f $COMPOSE_FILE ]] || die "没有找到安装"
  confirm "确认卸载 v2ray 和 caddy 容器？" n || exit 0
  compose down
  if confirm "同时删除 HTTPS 证书？（重装会重新申请）" n; then
    docker volume rm caddy_data caddy_config >/dev/null 2>&1 || true
  fi
  if confirm "同时删除配置目录 $STACK_DIR？" n; then
    rm -rf "$STACK_DIR"
  fi
  grn "已卸载。Docker 本身保留。"
}

menu() {
  load_env
  echo
  echo "======== V2Ray 管理 ========"
  if [[ -n $DOMAIN ]]; then echo " 当前: $DOMAIN  路径 $WS_PATH  CDN $CDN"; else echo " 当前: 未安装"; fi
  echo " 1) 安装 / 修改配置"
  echo " 2) 更新到最新版"
  echo " 3) 查看运行状态"
  echo " 4) 显示客户端链接和二维码"
  echo " 5) 只显示链接（不显示二维码）"
  echo " 6) 卸载"
  echo " 0) 退出"
  case "$(ask "请选择" "")" in
    1) cmd_install ;;
    2) cmd_update ;;
    3) cmd_status ;;
    4) cmd_show ;;
    5) cmd_show plain ;;
    6) cmd_uninstall ;;
    *) exit 0 ;;
  esac
}

main() {
  case "${1:-}" in
    install)   cmd_install ;;
    update)    cmd_update ;;
    status)    cmd_status ;;
    show)      cmd_show "${2:-auto}" ;;
    uninstall) cmd_uninstall ;;
    "")        menu ;;
    *)         die "未知命令: $1（可用: install update status show uninstall）" ;;
  esac
}

# 直接运行时执行 main；被 source 时不执行。
# 这一行同时兼容 bash <(curl ...) 和 curl | bash 两种写法。
if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then
  main "$@"
fi
