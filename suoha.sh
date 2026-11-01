#!/usr/bin/env bash
# Suoha 2.0 - Xray (VLESS + Trojan over WebSocket) + Cloudflare Tunnel
# Supported: Debian/Ubuntu (systemd), Alpine (OpenRC)
# Subscription is served only on localhost and exposed through a random secret URL path.

set -Eeuo pipefail
IFS=$'\n\t'

VERSION="2.0.0"
APP="suoha"
BASE="/opt/suoha"
BIN="$BASE/bin"
CONF="$BASE/config"
DATA="$BASE/data"
LOG="$BASE/logs"
WWW="$BASE/www"
CF_HOME="/root/.cloudflared"
STATE="$BASE/state.env"
MANAGER="$BASE/suoha.sh"

RED='\033[31m'; GREEN='\033[32m'; YELLOW='\033[33m'; BLUE='\033[34m'; RESET='\033[0m'
info(){ echo -e "${BLUE}[INFO]${RESET} $*"; }
ok(){ echo -e "${GREEN}[ OK ]${RESET} $*"; }
warn(){ echo -e "${YELLOW}[WARN]${RESET} $*"; }
err(){ echo -e "${RED}[ERR ]${RESET} $*" >&2; }
die(){ err "$*"; exit 1; }

on_error(){ local rc=$?; err "脚本在第 ${BASH_LINENO[0]:-未知} 行失败，退出码：$rc"; exit "$rc"; }
trap on_error ERR

require_root(){ [[ ${EUID:-$(id -u)} -eq 0 ]] || die "请使用 root 运行：bash suoha-2.0.sh"; }

os_detect(){
  [[ -r /etc/os-release ]] || die "无法识别系统：缺少 /etc/os-release"
  . /etc/os-release
  case "${ID:-}" in
    debian|ubuntu) OS_FAMILY="debian" ;;
    alpine) OS_FAMILY="alpine" ;;
    *)
      case " ${ID_LIKE:-} " in
        *" debian "*|*" ubuntu "*) OS_FAMILY="debian" ;;
        *) die "暂不支持当前系统：${PRETTY_NAME:-${ID:-unknown}}。支持 Debian、Ubuntu、Alpine。" ;;
      esac
      ;;
  esac
}

install_deps(){
  info "安装运行依赖..."
  if [[ "$OS_FAMILY" == debian ]]; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y curl unzip python3 ca-certificates openssl tar gzip procps
    INIT="systemd"
    command -v systemctl >/dev/null 2>&1 || die "当前系统没有 systemd，无法安装服务"
  else
    apk update
    apk add --no-cache bash curl unzip python3 ca-certificates openssl coreutils procps
    INIT="openrc"
    command -v rc-service >/dev/null 2>&1 || die "Alpine 未检测到 OpenRC"
    rc-update add local default >/dev/null 2>&1 || true
  fi
  update-ca-certificates >/dev/null 2>&1 || true
}

arch_assets(){
  local arch; arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64) XRAY_ASSET="Xray-linux-64.zip"; CF_ASSET="cloudflared-linux-amd64" ;;
    aarch64|arm64) XRAY_ASSET="Xray-linux-arm64-v8a.zip"; CF_ASSET="cloudflared-linux-arm64" ;;
    armv7l|armv7) XRAY_ASSET="Xray-linux-arm32-v7a.zip"; CF_ASSET="cloudflared-linux-arm" ;;
    i386|i686) XRAY_ASSET="Xray-linux-32.zip"; CF_ASSET="cloudflared-linux-386" ;;
    *) die "暂不支持 CPU 架构：$arch" ;;
  esac
}

prepare_dirs(){
  install -d -m 0755 "$BASE" "$BIN" "$CONF" "$DATA" "$LOG" "$WWW"
  chmod 700 "$BASE" "$CONF" "$DATA" "$LOG"
  if [[ -f "$0" ]]; then
    install -m 700 "$0" "$MANAGER"
    ln -sf "$MANAGER" /usr/local/bin/suoha
  fi
}

download_assets(){
  arch_assets
  local tmp; tmp="$(mktemp -d)"
  info "下载 Xray：$XRAY_ASSET"
  curl -fL --retry 3 --connect-timeout 10 --max-time 300 \
    "https://github.com/XTLS/Xray-core/releases/latest/download/$XRAY_ASSET" -o "$tmp/xray.zip"
  unzip -tq "$tmp/xray.zip" >/dev/null
  unzip -oq "$tmp/xray.zip" xray -d "$tmp/xray"
  [[ -s "$tmp/xray/xray" ]] || die "Xray 压缩包中没有 xray 可执行文件"
  install -m 0755 "$tmp/xray/xray" "$BIN/xray"

  info "下载 Cloudflared：$CF_ASSET"
  curl -fL --retry 3 --connect-timeout 10 --max-time 300 \
    "https://github.com/cloudflare/cloudflared/releases/latest/download/$CF_ASSET" -o "$BIN/cloudflared"
  chmod 0755 "$BIN/cloudflared"
  "$BIN/xray" version | head -n 1 || true
  "$BIN/cloudflared" --version || true
  rm -rf "$tmp"
}

random_hex(){ openssl rand -hex "${1:-16}"; }
random_port(){
  python3 - <<'PY'
import socket
s=socket.socket(); s.bind(('127.0.0.1',0)); print(s.getsockname()[1]); s.close()
PY
}
port_free(){ python3 - "$1" <<'PY'
import socket,sys
s=socket.socket()
try: s.bind(('127.0.0.1',int(sys.argv[1])))
except OSError: sys.exit(1)
finally: s.close()
PY
}
new_port(){ local p; while :; do p="$(random_port)"; if port_free "$p"; then echo "$p"; return; fi; done; }

save_state(){ umask 077; cat > "$STATE" <<EOF_STATE
MODE=${MODE}
UUID=${UUID}
VLESS_PATH=${VLESS_PATH}
TROJAN_PATH=${TROJAN_PATH}
SUB_TOKEN=${SUB_TOKEN}
VLESS_PORT=${VLESS_PORT}
TROJAN_PORT=${TROJAN_PORT}
SUB_PORT=${SUB_PORT}
EDGE_IP_VERSION=${EDGE_IP_VERSION}
TUNNEL_NAME=${TUNNEL_NAME:-}
TUNNEL_ID=${TUNNEL_ID:-}
DOMAIN=${DOMAIN:-}
EOF_STATE
chmod 600 "$STATE"; }
load_state(){ [[ -f "$STATE" ]] || die "未找到安装状态，请先安装服务"; set -a; . "$STATE"; set +a; }

make_xray_config(){
  cat > "$CONF/xray.json" <<EOF_XRAY
{
  "log": {"loglevel": "warning"},
  "inbounds": [
    {"listen":"127.0.0.1","port":${VLESS_PORT},"protocol":"vless","settings":{"clients":[{"id":"${UUID}"}],"decryption":"none"},"streamSettings":{"network":"ws","wsSettings":{"path":"/${VLESS_PATH}"}}},
    {"listen":"127.0.0.1","port":${TROJAN_PORT},"protocol":"trojan","settings":{"clients":[{"password":"${UUID}"}]},"streamSettings":{"network":"ws","wsSettings":{"path":"/${TROJAN_PATH}"}}}
  ],
  "outbounds": [{"protocol":"freedom","settings":{}}]
}
EOF_XRAY
  "$BIN/xray" run -test -config "$CONF/xray.json"
}

node_tag(){
  local v="${1:-Argo_Node}"
  v="${v//[^a-zA-Z0-9_.-]/_}"
  [[ -n "$v" ]] || v="Argo_Node"
  printf '%s' "$v"
}

write_node_files(){
  local vless_server="$1" vless_sni="$2" trojan_server="$3" trojan_sni="$4" tag="$5"
  local -a domains labels names
  local d l nm
  : > "$DATA/nodes.txt"
  cat > "$DATA/clash.yaml" <<EOF_CLASH
mixed-port: 7893
allow-lan: false
mode: rule
log-level: warning
ipv6: false
proxies:
EOF_CLASH
  domains=("$vless_server" "cf.090227.xyz" "cloudflare.182682.xyz")
  labels=("默认入口" "优选cf.090227" "优选182682")
  names=()
  for i in "${!domains[@]}"; do
    d="${domains[$i]}"; l="${labels[$i]}"; nm="${tag}-VLESS-${l}"
    printf 'vless://%s@%s:443?encryption=none&security=tls&sni=%s&type=ws&host=%s&path=%%2F%s#%s\n' "$UUID" "$d" "$vless_sni" "$vless_sni" "$VLESS_PATH" "$nm" >> "$DATA/nodes.txt"
    names+=("$nm")
    cat >> "$DATA/clash.yaml" <<EOF_VLESS
  - name: "$nm"
    type: vless
    server: "$d"
    port: 443
    uuid: "$UUID"
    tls: true
    servername: "$vless_sni"
    network: ws
    ws-opts:
      path: "/$VLESS_PATH"
      headers:
        Host: "$vless_sni"
EOF_VLESS
  done
  domains=("$trojan_server" "cf.090227.xyz" "cloudflare.182682.xyz")
  labels=("默认入口" "优选cf.090227" "优选182682")
  for i in "${!domains[@]}"; do
    d="${domains[$i]}"; l="${labels[$i]}"; nm="${tag}-Trojan-${l}"
    printf 'trojan://%s@%s:443?security=tls&sni=%s&type=ws&host=%s&path=%%2F%s#%s\n' "$UUID" "$d" "$trojan_sni" "$trojan_sni" "$TROJAN_PATH" "$nm" >> "$DATA/nodes.txt"
    names+=("$nm")
    cat >> "$DATA/clash.yaml" <<EOF_TROJAN
  - name: "$nm"
    type: trojan
    server: "$d"
    port: 443
    password: "$UUID"
    sni: "$trojan_sni"
    network: ws
    ws-opts:
      path: "/$TROJAN_PATH"
      headers:
        Host: "$trojan_sni"
EOF_TROJAN
  done
  cat >> "$DATA/clash.yaml" <<'EOF_GROUP'
proxy-groups:
  - name: PROXY
    type: select
    proxies:
EOF_GROUP
  for nm in "${names[@]}"; do printf '      - "%s"\n' "$nm" >> "$DATA/clash.yaml"; done
  cat >> "$DATA/clash.yaml" <<'EOF_RULES'
rules:
  - MATCH,PROXY
EOF_RULES
  base64 < "$DATA/nodes.txt" | tr -d '\n' > "$DATA/sub.txt"
  chmod 600 "$DATA/nodes.txt" "$DATA/sub.txt" "$DATA/clash.yaml"
}

# Subscription server: bind loopback only. A random token is part of the URL path.
write_sub_server(){
  cat > "$BASE/sub_server.py" <<'PY_SUB'
#!/usr/bin/env python3
import http.server, os, sys
root, port, token = sys.argv[1], int(sys.argv[2]), sys.argv[3]
class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs): super().__init__(*args, directory=root, **kwargs)
    def do_GET(self):
        prefix = '/s/' + token + '/'
        if not self.path.startswith(prefix):
            self.send_error(404); return
        name = self.path[len(prefix):].split('?',1)[0]
        if name not in ('sub.txt','clash.yaml'):
            self.send_error(404); return
        self.path = '/' + name
        super().do_GET()
    def log_message(self, fmt, *args): pass
http.server.ThreadingHTTPServer(('127.0.0.1', port), Handler).serve_forever()
PY_SUB
  chmod 700 "$BASE/sub_server.py"
}

write_systemd_unit(){
  local unit="$1" desc="$2" execstart="$3"
  cat > "/etc/systemd/system/${unit}.service" <<EOF_UNIT
[Unit]
Description=$desc
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
ExecStart=$execstart
Restart=always
RestartSec=5
User=root
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=read-only
ReadWritePaths=$BASE $CF_HOME

[Install]
WantedBy=multi-user.target
EOF_UNIT
}

write_openrc_service(){
  local svc="$1" command_line="$2" wrapper="$BASE/run-$svc.sh"
  cat > "$wrapper" <<EOF_WRAPPER
#!/bin/sh
exec $command_line
EOF_WRAPPER
  chmod 700 "$wrapper"
  cat > "/etc/init.d/$svc" <<EOF_RC
#!/sbin/openrc-run
description="$svc"
command="/bin/sh"
command_args="$wrapper"
command_background=true
pidfile="/run/$svc.pid"
output_log="$LOG/$svc.log"
error_log="$LOG/$svc.log"

depend() { need net; }
EOF_RC
  chmod 0755 "/etc/init.d/$svc"
  rc-update add "$svc" default >/dev/null 2>&1 || true
}

install_service(){
  local svc="$1" cmd="$2"
  if [[ "$INIT" == systemd ]]; then
    write_systemd_unit "$svc" "$svc" "$cmd"
  else
    write_openrc_service "$svc" "$cmd"
  fi
}

service_action(){
  local action="$1" svc="$2"
  if [[ "$INIT" == systemd ]]; then
    systemctl daemon-reload
    systemctl "$action" "$svc.service"
  else
    rc-service "$svc" "$action" || true
  fi
}

service_enable_start(){
  local svc="$1"
  if [[ "$INIT" == systemd ]]; then systemctl daemon-reload; systemctl enable --now "$svc.service"; else rc-update add "$svc" default >/dev/null 2>&1 || true; rc-service "$svc" start; fi
}

service_stop_disable(){
  local svc="$1"
  if [[ "$INIT" == systemd ]]; then systemctl disable --now "$svc.service" >/dev/null 2>&1 || true; else rc-service "$svc" stop >/dev/null 2>&1 || true; rc-update del "$svc" default >/dev/null 2>&1 || true; fi
}

start_subscription(){
  write_sub_server
  install_service "suoha-sub" "python3 $BASE/sub_server.py $WWW $SUB_PORT $SUB_TOKEN"
  service_enable_start "suoha-sub"
}

start_xray(){
  "$BIN/xray" run -test -config "$CONF/xray.json" >/dev/null
  install_service "suoha-xray" "$BIN/xray run -config $CONF/xray.json"
  service_enable_start "suoha-xray"
}

cf_login(){
  install -d -m 0700 "$CF_HOME"
  if [[ -s "$CF_HOME/cert.pem" ]]; then
    ok "检测到 Cloudflare 授权证书：$CF_HOME/cert.pem"
    read -r -p "是否重新进行 CF 授权？[y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]] || return 0
  fi
  echo
  info "即将启动 Cloudflare 浏览器授权。请复制终端输出的 URL，在浏览器登录并选择托管域名。"
  echo
  "$BIN/cloudflared" tunnel login
  [[ -s "$CF_HOME/cert.pem" ]] || die "授权未完成：没有生成 $CF_HOME/cert.pem"
  chmod 600 "$CF_HOME/cert.pem"
  ok "Cloudflare 授权完成"
}

valid_domain(){
  local d="${1,,}"
  [[ ${#d} -le 253 && "$d" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]]
}

cf_tunnel_json(){ "$BIN/cloudflared" tunnel list --output json 2>/dev/null; }

find_tunnel_id(){
  local name="$1" json
  json="$(cf_tunnel_json)" || return 1
  python3 -c 'import json,sys; name=sys.argv[1]; data=json.load(sys.stdin); rows=data if isinstance(data,list) else data.get("tunnels",[]); [print(x.get("id") or x.get("uuid")) for x in rows if x.get("name")==name]' "$name" <<< "$json" | head -n1
}

create_or_reuse_tunnel(){
  local id cred output
  TUNNEL_NAME="suoha-$(echo "$DOMAIN" | sha256sum | cut -c1-8)"
  id="$(find_tunnel_id "$TUNNEL_NAME" || true)"
  if [[ -n "$id" && -s "$CF_HOME/$id.json" ]]; then
    TUNNEL_ID="$id"; ok "复用现有 Tunnel：$TUNNEL_NAME ($TUNNEL_ID)"
    "$BIN/cloudflared" tunnel cleanup "$TUNNEL_ID" >/dev/null 2>&1 || true
  else
    if [[ -n "$id" && ! -s "$CF_HOME/$id.json" ]]; then
      warn "发现同名 Tunnel，但本机缺少凭据；不会擅自删除远端 Tunnel。请在 Cloudflare 控制台处理旧 Tunnel，或更换域名后重试。"
      die "Tunnel 凭据缺失：$id"
    fi
    info "创建 Tunnel：$TUNNEL_NAME"
    output="$("$BIN/cloudflared" tunnel create "$TUNNEL_NAME" 2>&1)" || { printf '%s\n' "$output"; die "Tunnel 创建失败"; }
    printf '%s\n' "$output"
    id="$(printf '%s\n' "$output" | grep -Eo '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}' | tail -n1 || true)"
    [[ -n "$id" ]] || id="$(find_tunnel_id "$TUNNEL_NAME" || true)"
    [[ -n "$id" && -s "$CF_HOME/$id.json" ]] || die "Tunnel 已执行创建，但无法确认 UUID 或凭据文件"
    TUNNEL_ID="$id"
  fi
  cred="$CF_HOME/$TUNNEL_ID.json"
  [[ -s "$cred" ]] || die "Tunnel 凭据不存在：$cred"
  chmod 600 "$cred"
}

route_domain(){
  local output
  info "将 $DOMAIN 路由到 Tunnel $TUNNEL_NAME ..."
  output="$("$BIN/cloudflared" tunnel route dns --overwrite-dns "$TUNNEL_ID" "$DOMAIN" 2>&1)" || { printf '%s\n' "$output"; die "DNS 路由失败。请确认域名所属 Zone 已在本次授权中选中，并且没有权限或 DNS 冲突。"; }
  printf '%s\n' "$output"
  ok "DNS 路由命令成功"
}

write_fixed_tunnel_config(){
  cat > "$CONF/cloudflared.yml" <<EOF_CF
 tunnel: $TUNNEL_ID
 credentials-file: $CF_HOME/$TUNNEL_ID.json
 ingress:
   - hostname: $DOMAIN
     path: ^/$VLESS_PATH$
     service: http://127.0.0.1:$VLESS_PORT
   - hostname: $DOMAIN
     path: ^/$TROJAN_PATH$
     service: http://127.0.0.1:$TROJAN_PORT
   - hostname: $DOMAIN
     path: ^/s/$SUB_TOKEN/(sub\.txt|clash\.yaml)$
     service: http://127.0.0.1:$SUB_PORT
   - service: http_status:404
EOF_CF
  # Remove leading whitespace from top-level YAML keys.
  sed -i 's/^ //' "$CONF/cloudflared.yml"
  "$BIN/cloudflared" tunnel --config "$CONF/cloudflared.yml" ingress validate
}

write_urls(){
  local subbase="https://$DOMAIN/s/$SUB_TOKEN"
  cat > "$DATA/links.txt" <<EOF_LINKS
==================================================
              Suoha $VERSION 节点信息
==================================================

$(cat "$DATA/nodes.txt")

--------------------------------------------------
 订阅链接（随机令牌路径，请勿公开分享）：
--------------------------------------------------

[通用订阅链接]:
$subbase/sub.txt

[Clash / Mihomo 订阅链接]:
$subbase/clash.yaml

--------------------------------------------------
 服务运行参数：
--------------------------------------------------
- Cloudflare 域名：$DOMAIN
- Tunnel 名称：$TUNNEL_NAME
- Tunnel UUID：$TUNNEL_ID
- Xray 本地监听：127.0.0.1:$VLESS_PORT / 127.0.0.1:$TROJAN_PORT
- 订阅服务监听：127.0.0.1:$SUB_PORT
==================================================
EOF_LINKS
  chmod 600 "$DATA/links.txt"
}

install_fixed(){
  MODE="fixed"
  read -r -p "选择 cloudflared 出站 IP（4/6，默认 4）：" EDGE_IP_VERSION
  EDGE_IP_VERSION="${EDGE_IP_VERSION:-4}"
  [[ "$EDGE_IP_VERSION" == 4 || "$EDGE_IP_VERSION" == 6 ]] || die "只能输入 4 或 6"
  cf_login
  echo
  read -r -p "输入已经在此 CF 账号托管的完整域名（例如 node.example.com）：" DOMAIN
  DOMAIN="${DOMAIN,,}"
  valid_domain "$DOMAIN" || die "域名格式不正确：$DOMAIN"
  UUID="$(cat /proc/sys/kernel/random/uuid)"
  VLESS_PATH="vl-$(random_hex 8)"; TROJAN_PATH="tr-$(random_hex 8)"; SUB_TOKEN="$(random_hex 24)"
  VLESS_PORT="$(new_port)"; TROJAN_PORT="$(new_port)"; while [[ "$TROJAN_PORT" == "$VLESS_PORT" ]]; do TROJAN_PORT="$(new_port)"; done
  SUB_PORT="$(new_port)"
  create_or_reuse_tunnel
  route_domain
  make_xray_config
  write_node_files "$DOMAIN" "$DOMAIN" "$DOMAIN" "$DOMAIN" "$(node_tag "${DOMAIN%%.*}")"
  install -d -m 0700 "$WWW"; install -m 0600 "$DATA/sub.txt" "$DATA/clash.yaml" "$WWW/"
  save_state
  write_fixed_tunnel_config
  start_xray
  start_subscription
  install_service "suoha-cloudflared" "$BIN/cloudflared --protocol http2 --edge-ip-version $EDGE_IP_VERSION tunnel --config $CONF/cloudflared.yml run $TUNNEL_ID"
  service_enable_start "suoha-cloudflared"
  sleep 2
  if [[ "$INIT" == systemd ]]; then systemctl --no-pager --full status suoha-cloudflared.service | tail -n 12 || true; else rc-service suoha-cloudflared status || true; fi
  write_urls
  ok "固定域名 Tunnel 安装完成"
  cat "$DATA/links.txt"
}

wait_quick_domain(){
  local logfile="$1" pid="$2" i domain
  for i in $(seq 1 60); do
    domain="$(grep -Eo 'https://[a-zA-Z0-9.-]+\.trycloudflare\.com' "$logfile" 2>/dev/null | head -n1 | sed 's#https://##' || true)"
    [[ -n "$domain" ]] && { echo "$domain"; return 0; }
    kill -0 "$pid" 2>/dev/null || { cat "$logfile"; return 1; }
    sleep 1
  done
  cat "$logfile"; return 1
}

quick_daemon(){
  load_state
  [[ "$MODE" == quick ]] || die "quick daemon 只能用于 Quick Tunnel 模式"
  local p1 p2 p3 d1 d2 d3
  "$BIN/cloudflared" tunnel --no-autoupdate --protocol http2 --edge-ip-version "$EDGE_IP_VERSION" --url "http://127.0.0.1:$VLESS_PORT" > "$LOG/quick-vless.log" 2>&1 & p1=$!
  "$BIN/cloudflared" tunnel --no-autoupdate --protocol http2 --edge-ip-version "$EDGE_IP_VERSION" --url "http://127.0.0.1:$TROJAN_PORT" > "$LOG/quick-trojan.log" 2>&1 & p2=$!
  "$BIN/cloudflared" tunnel --no-autoupdate --protocol http2 --edge-ip-version "$EDGE_IP_VERSION" --url "http://127.0.0.1:$SUB_PORT" > "$LOG/quick-sub.log" 2>&1 & p3=$!
  trap 'kill "$p1" "$p2" "$p3" >/dev/null 2>&1 || true' EXIT INT TERM
  info "等待三个 Quick Tunnel 分配临时域名..."
  d1="$(wait_quick_domain "$LOG/quick-vless.log" "$p1")" || die "VLESS Quick Tunnel 获取域名失败"
  d2="$(wait_quick_domain "$LOG/quick-trojan.log" "$p2")" || die "Trojan Quick Tunnel 获取域名失败"
  d3="$(wait_quick_domain "$LOG/quick-sub.log" "$p3")" || die "订阅 Quick Tunnel 获取域名失败"
  write_node_files "$d1" "$d1" "$d2" "$d2" "Argo_Node"
  install -m 0600 "$DATA/sub.txt" "$DATA/clash.yaml" "$WWW/"
  cat > "$DATA/links.txt" <<EOF_Q_LINKS
==================================================
           Suoha $VERSION Quick Tunnel
==================================================

$(cat "$DATA/nodes.txt")

--------------------------------------------------
 订阅链接（临时域名，请勿公开分享）：
--------------------------------------------------

[通用订阅链接]:
https://$d3/s/$SUB_TOKEN/sub.txt

[Clash / Mihomo 订阅链接]:
https://$d3/s/$SUB_TOKEN/clash.yaml

--------------------------------------------------
 注意事项：
--------------------------------------------------
- Quick Tunnel 域名是临时域名。服务重启或 VPS 重启后，域名可能变化；本服务会自动重新获取域名并更新 links.txt、nodes.txt 和订阅文件。
- 本模式使用三个独立 Quick Tunnel，分别承载 VLESS、Trojan 和订阅。
==================================================
EOF_Q_LINKS
  chmod 600 "$DATA/links.txt"
  ok "Quick Tunnel 已建立：VLESS=$d1 Trojan=$d2 SUB=$d3"
  # Keep the three child processes alive under the service manager.
  while kill -0 "$p1" 2>/dev/null && kill -0 "$p2" 2>/dev/null && kill -0 "$p3" 2>/dev/null; do sleep 5; done
  err "至少一个 Quick Tunnel 进程退出，交由服务管理器重启"
  return 1
}

install_quick(){
  MODE="quick"
  read -r -p "选择 cloudflared 出站 IP（4/6，默认 4）：" EDGE_IP_VERSION
  EDGE_IP_VERSION="${EDGE_IP_VERSION:-4}"
  [[ "$EDGE_IP_VERSION" == 4 || "$EDGE_IP_VERSION" == 6 ]] || die "只能输入 4 或 6"
  UUID="$(cat /proc/sys/kernel/random/uuid)"
  VLESS_PATH="vl-$(random_hex 8)"; TROJAN_PATH="tr-$(random_hex 8)"; SUB_TOKEN="$(random_hex 24)"
  VLESS_PORT="$(new_port)"; TROJAN_PORT="$(new_port)"; SUB_PORT="$(new_port)"
  while [[ "$TROJAN_PORT" == "$VLESS_PORT" || "$SUB_PORT" == "$VLESS_PORT" || "$SUB_PORT" == "$TROJAN_PORT" ]]; do SUB_PORT="$(new_port)"; done
  make_xray_config
  install -d -m 0700 "$WWW"
  write_sub_server
  save_state
  start_xray
  start_subscription
  rm -f "$DATA/links.txt"
  install_service "suoha-quick" "$MANAGER --quick-daemon"
  service_enable_start "suoha-quick"
  info "等待 Quick Tunnel 完成初始化（最多 90 秒）..."
  local i
  for i in $(seq 1 180); do [[ -s "$DATA/links.txt" ]] && break; sleep 1; done
  [[ -s "$DATA/links.txt" ]] || { if [[ "$INIT" == systemd ]]; then journalctl -u suoha-quick.service -n 40 --no-pager || true; else tail -n 40 "$LOG/suoha-quick.log" 2>/dev/null || true; fi; die "Quick Tunnel 初始化超时，请检查 cloudflared 日志"; }
  ok "Quick Tunnel 安装完成"
  cat "$DATA/links.txt"
}

show_status(){
  load_state
  echo "模式：$MODE"
  [[ -n "${DOMAIN:-}" ]] && echo "域名：$DOMAIN"
  [[ -n "${TUNNEL_NAME:-}" ]] && echo "Tunnel：$TUNNEL_NAME ($TUNNEL_ID)"
  if [[ "$INIT" == systemd ]]; then
    systemctl --no-pager --full status suoha-xray.service suoha-sub.service 2>/dev/null | tail -n 30 || true
    if [[ "$MODE" == fixed ]]; then systemctl --no-pager --full status suoha-cloudflared.service 2>/dev/null | tail -n 12 || true; else systemctl --no-pager --full status suoha-quick.service 2>/dev/null | tail -n 20 || true; fi
  else
    rc-service suoha-xray status || true; rc-service suoha-sub status || true
    if [[ "$MODE" == fixed ]]; then rc-service suoha-cloudflared status || true; else rc-service suoha-quick status || true; fi
  fi
}

restart_services(){
  load_state
  service_action restart suoha-xray
  service_action restart suoha-sub
  if [[ "$MODE" == fixed ]]; then service_action restart suoha-cloudflared; else service_action restart suoha-quick; fi
  ok "服务重启命令已执行"
}

stop_services(){
  for s in suoha-cloudflared suoha-quick suoha-q-vless suoha-q-trojan suoha-q-sub suoha-sub suoha-xray; do service_stop_disable "$s"; done
  ok "Suoha 服务已停止"
}

uninstall_app(){
  warn "卸载只清理 Suoha 自己创建的服务和 /opt/suoha，不删除 $CF_HOME，不删除 Cloudflare 账号授权资料，也不删除远端 Tunnel。"
  read -r -p "确认卸载 Suoha？输入 YES 继续：" confirm
  [[ "$confirm" == YES ]] || { info "已取消卸载"; return; }
  stop_services
  if [[ "$INIT" == systemd ]]; then
    rm -f /etc/systemd/system/suoha-*.service
    systemctl daemon-reload
  else
    for s in suoha-cloudflared suoha-quick suoha-q-vless suoha-q-trojan suoha-q-sub suoha-sub suoha-xray; do rm -f "/etc/init.d/$s"; rc-update del "$s" default >/dev/null 2>&1 || true; done
  fi
  rm -f /usr/local/bin/suoha /usr/bin/suoha
  rm -rf "$BASE"
  ok "Suoha 本机文件和服务已卸载。Cloudflare 授权资料及远端 Tunnel 均已保留。"
}

manager_menu(){
  while true; do
    echo
    echo "========== Suoha $VERSION 管理 =========="
    echo "1. 查看节点和订阅链接"
    echo "2. 查看服务状态"
    echo "3. 重启服务"
    echo "4. 停止服务"
    echo "5. 启动服务"
    echo "6. 卸载 Suoha（保留 CF 授权和远端 Tunnel）"
    echo "0. 退出"
    read -r -p "请选择：" c
    case "$c" in
      1) [[ -f "$DATA/links.txt" ]] && cat "$DATA/links.txt" || warn "尚无链接文件" ;;
      2) show_status ;;
      3) restart_services ;;
      4) stop_services ;;
      5) load_state; service_enable_start suoha-xray; service_enable_start suoha-sub; if [[ "$MODE" == fixed ]]; then service_enable_start suoha-cloudflared; else service_enable_start suoha-quick; fi ;;
      6) uninstall_app; return ;;
      0) return ;;
      *) warn "无效选项" ;;
    esac
  done
}

main_menu(){
  echo "=================================================="
  echo " Suoha $VERSION - Xray + Cloudflare Tunnel"
  echo " 支持 Debian / Ubuntu / Alpine"
  echo "=================================================="
  echo "1. Quick Tunnel（临时域名，VLESS + Trojan + 订阅）"
  echo "2. 固定域名 Tunnel（手动 CF 授权 + 自定义域名）"
  echo "3. 管理已安装服务"
  echo "4. 卸载 Suoha（保留 CF 授权资料）"
  echo "0. 退出"
  read -r -p "请选择模式 [默认 1]：" mode
  mode="${mode:-1}"
  case "$mode" in
    1) prepare_dirs; download_assets; install_quick ;;
    2) prepare_dirs; download_assets; install_fixed ;;
    3) manager_menu ;;
    4) uninstall_app ;;
    0) exit 0 ;;
    *) die "无效选项" ;;
  esac
}

if [[ "${1:-}" == "--quick-daemon" ]]; then
  require_root
  os_detect
  INIT="${INIT:-$( [[ "$OS_FAMILY" == debian ]] && echo systemd || echo openrc )}"
  quick_daemon
  exit $?
fi

require_root
os_detect
install_deps
INIT="${INIT:-$( [[ "$OS_FAMILY" == debian ]] && echo systemd || echo openrc )}"
if [[ -x "$MANAGER" && -f "$STATE" ]]; then
  # The manager is the same script; keep environment and paths consistent.
  :
fi
main_menu