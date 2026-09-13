#!/usr/bin/env bash
# =============================================================================
# v2ray.sh — V2Fly v5 + Caddy 2（VMess + WebSocket + TLS）一键安装与管理
#
# 用法（在服务器上以 root 运行）:
#   bash <(curl -fsSL https://raw.githubusercontent.com/hillghost86/v2ray-auto-setup/main/v2ray.sh)
#   curl -fsSL .../v2ray.sh | bash -s -- install
#   支持的子命令: install | update | status | show | uninstall
#
# 两种前端模式（安装时选择，存在 .env 的 FRONT 里）:
#   caddy  脚本自带 Caddy 占 80/443，自动申请证书（默认）
#   nginx  机器上已有 Nginx（宝塔面板等）占着 80/443：只跑 V2Ray，端口绑在
#          127.0.0.1:2333，证书和 443 交给 Nginx，由用户在 Nginx 里反代过来
#
# 文件位置:
#   /root/v2ray-stack/.env          域名、UUID、路径、前端模式、镜像版本（脚本与 compose 共用）
#   /root/v2ray-stack/compose.yaml  容器定义（V2Ray 与 Caddy 配置内嵌其中）
#   Docker 数据卷 caddy_data         HTTPS 证书（仅 caddy 模式）
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
# 只把 cleanup 挂在 EXIT 上。INT / TERM 若直接调 cleanup，处理完会从被打断的
# 地方继续往下跑——按了 Ctrl-C 却照样把安装做完。改成主动 exit，由 EXIT 统一清理
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

mktmp() { local d; d=$(mktemp -d); TMP_DIRS+=("$d"); printf '%s' "$d"; }

# ---------------------------------------------------------------------------
# 状态
# ---------------------------------------------------------------------------
load_env() {
  DOMAIN="" UUID="" WS_PATH="" CDN="no" FRONT="caddy" V2FLY_TAG="latest" CADDY_TAG="2"
  if [[ -f $ENV_FILE ]]; then
    # shellcheck disable=SC1090
    source "$ENV_FILE"
  fi
  : "${V2FLY_TAG:=latest}" "${CADDY_TAG:=2}"
  # 旧版 .env 没有 FRONT，等价于 caddy 模式
  [[ $FRONT == nginx ]] || FRONT=caddy
}

save_env() {
  mkdir -p "$STACK_DIR"
  cat > "$ENV_FILE" <<EOF
DOMAIN=$DOMAIN
UUID=$UUID
WS_PATH=$WS_PATH
CDN=$CDN
FRONT=$FRONT
V2FLY_TAG=$V2FLY_TAG
CADDY_TAG=$CADDY_TAG
EOF
  chmod 600 "$ENV_FILE"
}

container_running() { [[ -n "$(docker ps -q --filter "name=^$1\$" 2>/dev/null)" ]]; }

# ---------------------------------------------------------------------------
# 环境准备
# ---------------------------------------------------------------------------
# 所有子命令都要 root：配置在 /root/v2ray-stack 下（.env 是 600，里面的 UUID
# 等同密码），Docker、apt、systemd、80/443 端口也都要。放在 main() 里统一拦，
# 比在各个子命令里分别调更难漏——尤其是无参数进菜单时，menu() 第一行就是
# load_env，非 root 下有可能连报错都来不及打就被 set -e 终止
need_root() {
  [[ $EUID -eq 0 ]] || die "需要 root 运行。配置在 /root/v2ray-stack 下，普通用户读不到。
  请用: sudo -i 切到 root，或 curl -fsSL <脚本地址> | sudo bash -s -- ${1:-install}"
}

preflight() {
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

show_dns() {
  local resolved
  PUBLIC_IP=$(public_ip)
  resolved=$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ' || true)
  echo "本机公网 IP:   $PUBLIC_IP"
  echo "域名当前解析: ${resolved:-（解析失败）}"
  check_ipv6
}

check_domain() {
  step "检查域名 $DOMAIN 是否指向本机"
  local ip token dir got
  show_dns
  ip=$PUBLIC_IP

  port_in_use 80 && die "80 端口被占用，无法检查。先查明占用程序：ss -tlnp | grep ':80 '
  如果占用的是宝塔面板或其他 Nginx，请重新运行安装，前端模式选「已有 Nginx」"

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

  # 前端模式。首次安装时如果 443 已经被别的程序占着（宝塔面板之类），
  # 默认就选 nginx，免得用户选了 caddy 再撞到端口冲突
  local def=$FRONT
  if [[ ! -f $ENV_FILE ]] && port_in_use 443 && ! container_running caddy; then
    ylw "检测到 443 端口已被其他程序占用（宝塔面板 / Nginx？），默认选择「已有 Nginx」模式"
    def=nginx
  fi
  echo "HTTPS 由谁负责："
  echo "  1) 脚本自带 Caddy，自动申请证书（需要 80、443 端口空闲）"
  echo "  2) 已有 Nginx（宝塔面板等）：只跑 V2Ray，证书和 443 交给 Nginx，需要你加一段反代"
  while :; do
    case "$(ask "请选择" "$([[ $def == nginx ]] && echo 2 || echo 1)")" in
      1) FRONT=caddy; break ;;
      2) FRONT=nginx; break ;;
      *) red "请输入 1 或 2" ;;
    esac
  done

  DOMAIN_CHANGED=no
  [[ "$d" != "$DOMAIN" ]] && DOMAIN_CHANGED=yes
  DOMAIN=$d UUID=${u,,} WS_PATH=$p

  echo
  echo "  域名:  $DOMAIN"
  echo "  UUID:  $UUID"
  echo "  路径:  $WS_PATH"
  echo "  CDN:   $CDN"
  if [[ $FRONT == nginx ]]; then
    echo "  前端:  已有 Nginx（宝塔），V2Ray 监听 127.0.0.1:2333"
    echo "  镜像:  v2fly/v2fly-core:$V2FLY_TAG"
  else
    echo "  前端:  Caddy 自动证书"
    echo "  镜像:  v2fly/v2fly-core:$V2FLY_TAG , caddy:$CADDY_TAG"
  fi
  confirm "确认以上配置？" y || exit 1
}

# compose.yaml 按模式拼装：V2Ray 服务和它的配置两种模式都有；Caddy 服务、
# Caddyfile、证书卷只在 caddy 模式写入。nginx 模式下 V2Ray 的 2333 端口发布到
# 127.0.0.1，由宿主机上的 Nginx 反代，外网直接碰不到
write_compose() {
  mkdir -p "$STACK_DIR"
  {
    cat <<'EOF'
# 由 v2ray.sh 生成。域名、UUID、路径、前端模式、镜像版本读取同目录的 .env
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
EOF
    if [[ $FRONT == nginx ]]; then
      cat <<'EOF'
    ports:
      - "127.0.0.1:2333:2333"
EOF
    else
      cat <<'EOF'

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
EOF
    fi
    cat <<'EOF'

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
EOF
    if [[ $FRONT == caddy ]]; then
      cat <<'EOF'
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
    fi
  } > "$COMPOSE_FILE"
  compose config -q || die "compose.yaml 校验失败"
}

# nginx 模式下用户要在宝塔 / Nginx 里做的事。安装时打印，自检失败时也打印
nginx_hint() {
  step "宝塔 / Nginx 侧需要的配置"
  echo "1) 在宝塔里为 $DOMAIN 添加站点（纯静态即可），申请 SSL 证书并部署"
  echo "2) 打开该站点的「配置文件」，在 443 的 server 块里加入下面这段，保存后重载 Nginx："
  cat <<EOF

    location $WS_PATH {
        proxy_pass http://127.0.0.1:2333;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_read_timeout 300s;
    }

EOF
  echo "   不要用面板的「反向代理」功能整站反代，那会把根路径也转给 V2Ray；只加上面这个 location"
  echo "3) 证书续期由宝塔负责；路径或域名改了要同步改这段配置"
  if [[ $CDN == yes ]]; then
    echo "4) Cloudflare 侧：云朵橙色、SSL/TLS 选「完全（严格）」、WebSockets 开启"
  fi
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
# 无论哪种模式，本机 443 上都有反代（Caddy 或 Nginx），所以统一打 127.0.0.1:443
ws_ok() {
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' --http1.1 --max-time 5 \
    --resolve "$DOMAIN:443:127.0.0.1" \
    -H "Connection: Upgrade" -H "Upgrade: websocket" \
    -H "Sec-WebSocket-Version: 13" -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
    "https://$DOMAIN$WS_PATH" 2>/dev/null) || true
  [[ ${code//[[:space:]]/} == 101 ]]
}

# nginx 模式专用：绕过 Nginx 直接打 V2Ray 的 2333，把「V2Ray 没起来」和
# 「Nginx 反代 / 证书没配好」区分开，否则排查时不知道该看哪边
v2ray_ok() {
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' --http1.1 --max-time 5 \
    -H "Host: $DOMAIN" -H "Connection: Upgrade" -H "Upgrade: websocket" \
    -H "Sec-WebSocket-Version: 13" -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
    "http://127.0.0.1:2333$WS_PATH" 2>/dev/null) || true
  [[ ${code//[[:space:]]/} == 101 ]]
}

# 二、真实连接：启动一个临时 V2Ray 客户端，用当前 UUID 走一遍代理访问外网
#    能通过说明 UUID、路径、TLS 全部正确，而不只是端口通
#    caddy 模式：放进 Caddy 所在的 Docker 网络，直接连容器名 caddy
#    nginx 模式：Nginx 在宿主机上，用 host-gateway 让容器能连到宿主机的 443
e2e_ok() {
  local net dir hostport code server run_opts=()
  if [[ $FRONT == nginx ]]; then
    server=host.docker.internal
    run_opts=(--add-host "host.docker.internal:host-gateway")
  else
    net=$(docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' caddy 2>/dev/null | awk '{print $1}')
    [[ -n $net ]] || return 1
    server=caddy
    run_opts=(--network "$net")
  fi
  dir=$(mktmp); chmod 755 "$dir"
  cat > "$dir/config.json" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [{ "listen": "0.0.0.0", "port": 10808, "protocol": "socks", "settings": { "udp": false } }],
  "outbounds": [{
    "protocol": "vmess",
    "settings": { "vnext": [{ "address": "$server", "port": 443,
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
  docker run -d --name v2ray-e2e "${run_opts[@]}" -p 127.0.0.1::10808 \
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
#    这里按域名真实解析做一次 WebSocket 握手，客户端实际走的就是这条路：
#    既验边缘证书，也验 Cloudflare 的 WebSockets 开关和到源站的回程。
#    不加 -f，也不把 stderr 扔掉：失败时状态码和 curl 的原话就是线索，
#    以前只看成败、一律归咎于「多级子域」，一级子域撞上别的原因就把人带偏了。
CDN_CODE="" CDN_ERR=""
cdn_ok() {
  local out
  # 超时要给够：Cloudflare 回源连不上要等 15 秒以上才回 522，超时比它短就只能
  # 拿到 000，把「云防火墙没开 443」误判成证书或出网问题
  out=$(curl -sS -o /dev/null -w '\n%{http_code}' --http1.1 --max-time 35 \
    -H "Connection: Upgrade" -H "Upgrade: websocket" \
    -H "Sec-WebSocket-Version: 13" -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
    "https://$DOMAIN$WS_PATH" 2>&1) || true
  CDN_CODE=${out##*$'\n'}; CDN_CODE=${CDN_CODE//[[:space:]]/}
  CDN_ERR=""
  # stderr 可能有多行、末尾带换行，压成一行方便嵌进提示里
  [[ $out == *$'\n'* ]] && CDN_ERR=$(printf '%s\n' "${out%$'\n'*}" | sed '/^[[:space:]]*$/d' | paste -sd ' ')
  # 握手成功后 curl 会等隧道数据直到超时，stderr 会多一条 timeout，不算错
  [[ $CDN_CODE == 101 ]]
}

cdn_hint() {
  local dots
  red "✗ 经 Cloudflare 握手失败，但源站是好的——问题在 CDN 这一跳"
  case ${CDN_CODE:-000} in
    000)
      echo "  没拿到 HTTP 响应，curl 的原话：${CDN_ERR:-（无）}"
      dots=$(tr -cd '.' <<<"$DOMAIN" | wc -c)
      if [[ $CDN_ERR == *"(28)"* ]]; then
        # TLS 已完成、请求发出后一直没回应：边缘收到了请求，卡在回源。
        # 前面的自检打 127.0.0.1 和 Docker 网桥，都不经过云厂商防火墙，所以是绿的
        echo "  请求发出后一直没有回应：Cloudflare 边缘收到了请求，但连不上你的源站 443。"
        echo "  前面几项自检走的是本机回环和 Docker 网桥，不经过云厂商防火墙，所以照不出这个问题。"
        echo "  1) 云厂商防火墙（Lightsail 控制台里的 Networking / 安全组）是否对所有来源放行 TCP 443，"
        echo "     系统里的 ufw 和它是两回事"
        echo "  2) Cloudflare 里如果还有指向本机的 AAAA 记录，IPv6 防火墙也要放行 443，或删掉该记录"
        echo "  3) 宝塔「安全」页的端口规则是否放行 443"
      elif (( dots >= 3 )); then
        echo "  域名看起来是多级子域。免费版 Universal SSL 只签 example.com 和 *.example.com，"
        echo "  通配符不覆盖 a.b.example.com，边缘拿不出证书就直接握手失败。"
        echo "  解决: 1) 换成一级子域（推荐，如 xxx.example.com）"
        echo "        2) 云朵改灰（仅 DNS），同时把本脚本的 CDN 选项改成 no"
        echo "        3) 购买 Advanced Certificate Manager 开启 Total TLS"
      else
        echo "  域名是一级子域，通配符证书应能覆盖。常见原因："
        echo "  1) 域名刚加进 Cloudflare，Universal SSL 还在签发中（最长 24 小时）：SSL/TLS → 边缘证书 里看状态"
        echo "  2) 本机到 Cloudflare 的出网不通或超时：换台机器或手机流量访问 https://$DOMAIN 对比"
      fi
      echo "  自查: curl -sSv -o /dev/null --max-time 60 https://$DOMAIN$WS_PATH 2>&1 | tail -20"
      ;;
    200|400|404|426)
      echo "  边缘返回 HTTP $CDN_CODE 而不是 101：请求没有被当作 WebSocket 升级转到 V2Ray。"
      echo "  1) Cloudflare 网络 → WebSockets 是否开启"
      echo "  2) 路径 $WS_PATH 在源站是否真的转给了 V2Ray（本机 443 已通过，多半是 1）"
      ;;
    403|503)
      echo "  边缘返回 HTTP $CDN_CODE：多半是 Cloudflare 的 WAF / Bot Fight Mode / Under Attack 模式拦下了。"
      echo "  给路径 $WS_PATH 加一条 WAF 跳过规则，或关掉这些功能"
      ;;
    520|521|522|523|524)
      echo "  边缘返回 HTTP $CDN_CODE：Cloudflare 连不上源站。前面的自检走本机回环和 Docker 网桥，"
      echo "  不经过云厂商防火墙，所以照不出来。检查 Lightsail 控制台 / 安全组是否对所有来源放行 TCP 443"
      echo "  （系统里的 ufw 和它是两回事），Cloudflare 里有指向本机的 AAAA 记录的话 IPv6 防火墙同样要放行"
      ;;
    525|526)
      echo "  边缘返回 HTTP $CDN_CODE：Cloudflare 到源站的 TLS 失败。"
      echo "  SSL/TLS 模式选「完全（严格）」时源站证书必须有效且未过期，SNI 要能匹配 $DOMAIN"
      ;;
    530)
      echo "  边缘返回 HTTP 530：源站侧 DNS / Tunnel 错误，看 Cloudflare 的错误页里的 1xxx 子码"
      ;;
    *)
      echo "  边缘返回 HTTP $CDN_CODE${CDN_ERR:+，curl: $CDN_ERR}"
      ;;
  esac
  echo "  排查后运行本脚本选「查看运行状态」即可重测"
}

# 等 fn 返回成功，最多 n 次，每次间隔 5 秒
wait_for() {
  local fn=$1 n=$2 i
  for ((i = 0; i < n; i++)); do
    if "$fn"; then echo; return 0; fi
    printf '.'; sleep 5
  done
  echo
  return 1
}

wait_caddy() {
  step "等待证书申请和服务启动（最多 3 分钟）"
  if ! wait_for ws_ok 36; then
    red "✗ 3 分钟内没有就绪，Caddy 最近的日志："
    docker logs --tail 20 caddy 2>&1 | grep -iE 'error|obtain|challenge' || docker logs --tail 20 caddy
    return 1
  fi
  grn "✓ HTTPS 证书有效，WebSocket 握手成功"
}

wait_nginx() {
  step "等待 V2Ray 启动"
  if ! wait_for v2ray_ok 6; then
    red "✗ V2Ray 在 127.0.0.1:2333 上没有响应，最近的日志："
    docker logs --tail 20 v2ray 2>&1 | tail -20
    return 1
  fi
  grn "✓ V2Ray 已在 127.0.0.1:2333 就绪"

  step "检查 Nginx 反代和证书（经本机 443）"
  port_in_use 443 || ylw "⚠ 443 端口上没有程序在监听，宝塔站点是不是还没建？"
  if ! wait_for ws_ok 6; then
    red "✗ 经 443 握手失败。V2Ray 本身是好的，问题在 Nginx 这一跳："
    echo "  1) 站点证书是否已申请并部署（curl -vI https://$DOMAIN 看证书）"
    echo "  2) location $WS_PATH 是否已加进 443 的 server 块并重载（nginx -t && nginx -s reload）"
    echo "  3) Upgrade / Connection 头是否带上（少了会返回 200 或 400 而不是 101）"
    return 1
  fi
  grn "✓ 证书有效，Nginx → V2Ray 握手成功"
}

wait_ready() {
  if [[ $FRONT == nginx ]]; then wait_nginx || return 1; else wait_caddy || return 1; fi

  step "真实连接测试（用当前 UUID 走一遍代理）"
  if e2e_ok; then
    grn "✓ 代理连通，UUID、路径、TLS 均正确"
    [[ $CDN != yes ]] && return 0
    step "经 Cloudflare 边缘测试（客户端实际走的路径）"
    if cdn_ok; then
      grn "✓ 经 Cloudflare 边缘握手成功，客户端走的这条路是通的"
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
  local mode=${1:-auto} cols need ec ec_ok=""
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
  # 纠错等级自适应：优先 M（容错 15%，能兜住终端渲染时个别行的错位），
  # 终端装不下就退回 L（7%，二维码小 8 列左右）。宽度按真实尺寸算，不能写死
  # 80 列——ASCII 输出每模块占 2 列，ANSIUTF8 占 1 列，所以需要的列数是前者的一半
  cols=$(tput cols 2>/dev/null || echo 80)
  for ec in M L; do
    need=$(vmess_link | qrencode -l "$ec" -t ASCII 2>/dev/null \
      | awk '{ if (length($0) > m) m = length($0) } END { print int(m / 2) }' || true)
    need=${need:-0}
    (( need == 0 )) && { ec_ok=L; break; }   # 量不出来就照旧画，别把二维码整个吞掉
    (( cols >= need )) && { ec_ok=$ec; break; }
  done
  if [[ -z $ec_ok ]]; then
    ylw "二维码至少需要 $need 列，当前终端 $cols 列，已跳过。拉宽窗口后运行「显示链接」即可"
    return 0
  fi
  echo
  echo "Shadowrocket 扫码导入（显示错乱时可只用上面的链接）："
  vmess_link | qrencode -l "$ec_ok" -t ANSIUTF8
}

cmd_install() {
  preflight
  ylw "开始前请确认：Lightsail 防火墙已放行 TCP 80 和 443；域名 A 记录已指向本机静态 IP"
  load_env
  prompt_config
  install_deps
  install_docker
  open_ufw

  if [[ $FRONT == nginx ]]; then
    # 80/443 在 Nginx 手里，起不了临时网页服务，域名只能打印解析结果供人眼核对；
    # DNS 是否真的正确，由宝塔申请证书那一步来验证
    step "域名解析（nginx 模式不做 80 端口检查，DNS 由宝塔申请证书时验证）"
    show_dns
  else
    if container_running caddy && [[ $DOMAIN_CHANGED == yes ]]; then
      ylw "域名有变化，先停止 Caddy 以便检查新域名（脚本中途退出会自动恢复）"
      compose stop caddy >/dev/null
      CADDY_STOPPED=yes
    fi
    if ! container_running caddy; then
      # 从 nginx 模式切回来、或者机器上本来就有别的 web 服务时，443 也可能被占着，
      # check_domain 只查 80，这里把 443 一起拦下，免得 compose up 才报端口冲突
      port_in_use 443 && die "443 端口被占用（宝塔面板 / Nginx？）。要么停掉占用程序，要么前端模式选「已有 Nginx」"
      check_domain
    fi
  fi

  step "写入配置并启动"
  save_env
  write_compose
  compose pull -q
  # 配置内嵌在 compose.yaml 里，只改内容时 Compose 不会重建容器，
  # 会导致新 UUID / 路径不生效，所以这里强制重建。--remove-orphans 顺带处理
  # 模式切换：从 caddy 切到 nginx 时 compose.yaml 里没了 caddy 服务，旧容器会被删掉
  compose up -d --force-recreate --remove-orphans
  CADDY_STOPPED=no

  if [[ $FRONT == nginx ]]; then
    nginx_hint
    if ! confirm "宝塔 / Nginx 侧已经配置好，现在开始自检？" y; then
      cmd_show
      echo
      ylw "配置好 Nginx 反代后，运行本脚本选「查看运行状态」即可自检。"
      grn "安装完成。以后重新运行本脚本即可更新、查看状态或修改配置。"
      return 0
    fi
  fi

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
  if [[ $CDN == yes && $FRONT == caddy ]]; then
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
  if [[ $FRONT == nginx ]]; then
    echo "前端: 已有 Nginx（宝塔），V2Ray 监听 127.0.0.1:2333"
    echo "配置中的镜像标签: v2fly/v2fly-core:$V2FLY_TAG"
  else
    docker exec caddy caddy version 2>/dev/null | head -1 || true
    echo "配置中的镜像标签: v2fly/v2fly-core:$V2FLY_TAG , caddy:$CADDY_TAG"
  fi
  step "证书$([[ $FRONT == nginx ]] && echo '（由宝塔 / Nginx 管理）')"
  echo | openssl s_client -connect 127.0.0.1:443 -servername "$DOMAIN" 2>/dev/null \
    | openssl x509 -noout -issuer -enddate 2>/dev/null || red "读取证书失败"
  step "链路自检"
  if [[ $FRONT == nginx ]]; then
    if v2ray_ok; then grn "✓ V2Ray 在 127.0.0.1:2333 正常"; else red "✗ V2Ray 无响应: docker logs --tail 50 v2ray"; fi
    if ws_ok; then grn "✓ 证书和 Nginx 反代正常"; else red "✗ 经 443 握手失败: 检查站点证书和 location $WS_PATH 反代（nginx -t）"; fi
  else
    if ws_ok; then grn "✓ 证书和 WebSocket 正常"; else red "✗ WebSocket 握手失败: docker logs --tail 50 caddy"; fi
  fi
  if e2e_ok; then grn "✓ 代理连通"; else red "✗ 代理连不通: docker logs --tail 50 v2ray"; fi
  if [[ $CDN == yes ]]; then
    if cdn_ok; then grn "✓ 经 Cloudflare 边缘握手正常"; else cdn_hint; fi
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
  if [[ -n $DOMAIN ]]; then
    echo " 当前: $DOMAIN  路径 $WS_PATH  CDN $CDN  前端 $([[ $FRONT == nginx ]] && echo '已有 Nginx' || echo Caddy)"
  else
    echo " 当前: 未安装"
  fi
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
  # 每个有效子命令都先过 need_root。未知命令不用拦——那只是提示用法，
  # 非 root 也该看到「未知命令」而不是「需要 root」
  case "${1:-}" in
    install)   need_root install;   cmd_install ;;
    update)    need_root update;    cmd_update ;;
    status)    need_root status;    cmd_status ;;
    show)      need_root show;      cmd_show "${2:-auto}" ;;
    uninstall) need_root uninstall; cmd_uninstall ;;
    "")        need_root;           menu ;;
    *)         die "未知命令: $1（可用: install update status show uninstall）" ;;
  esac
}

# 直接运行时执行 main；被 source 时不执行。
# 这一行同时兼容 bash <(curl ...) 和 curl | bash 两种写法。
if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then
  main "$@"
fi
