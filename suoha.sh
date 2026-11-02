#!/usr/bin/env bash
# Suoha 2.2 - Xray (VLESS + Trojan over WebSocket) + Cloudflare Tunnel
# Supported: Debian/Ubuntu (systemd), Alpine (OpenRC)
# Subscription is served only on localhost and exposed through a random secret URL path.

set -Eeuo pipefail
IFS=$'\n\t'

VERSION="2.2.0"
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
XRAY_BACKUP_DIR="$BASE/backup/xray"
XRAY_RELEASE_API="https://api.github.com/repos/XTLS/Xray-core/releases/latest"

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
    apt-get install -y curl unzip python3 ca-certificates openssl tar gzip procps qrencode
    INIT="systemd"
    command -v systemctl >/dev/null 2>&1 || die "当前系统没有 systemd，无法安装服务"
  else
    apk update
    apk add --no-cache bash curl unzip python3 ca-certificates openssl coreutils procps qrencode
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
        import re
        if name not in ('sub.txt', 'clash.yaml', 'qr.html') and not re.fullmatch(r'qr/[A-Za-z0-9._-]+\.svg', name):
            self.send_error(404); return
        self.path = '/' + name
        super().do_GET()
    def log_message(self, fmt, *args): pass
http.server.ThreadingHTTPServer(('127.0.0.1', port), Handler).serve_forever()
PY_SUB
  chmod 700 "$BASE/sub_server.py"
}

# Build a private QR portal. Individual VLESS/Trojan QR codes contain standard
# share URIs; subscription QR codes contain import URLs for compatible clients.
ensure_qrencode(){
  command -v qrencode >/dev/null 2>&1 && return 0
  info "安装二维码生成工具 qrencode..."
  if [[ "$OS_FAMILY" == debian ]]; then apt-get update; apt-get install -y qrencode
  else apk add --no-cache qrencode
  fi
  command -v qrencode >/dev/null 2>&1 || die "qrencode 安装失败，无法生成二维码"
}

write_qr_portal(){
  local host="$1" subbase="https://$1/s/$SUB_TOKEN"
  ensure_qrencode
  python3 - "$DATA/nodes.txt" "$WWW" "$subbase" "$VERSION" <<'PY_QR'
import html, pathlib, subprocess, sys, urllib.parse
nodes_file, www_dir, subbase, version = sys.argv[1:]
www = pathlib.Path(www_dir)
qrdir = www / 'qr'
qrdir.mkdir(parents=True, exist_ok=True)
nodes = [x.strip() for x in pathlib.Path(nodes_file).read_text().splitlines() if x.strip()]
if not nodes:
    raise SystemExit('节点列表为空，不能生成二维码')
def make_qr(name, value):
    target = qrdir / name
    subprocess.run(['qrencode', '-t', 'SVG', '-l', 'M', '-m', '2', '-o', str(target), value], check=True)
    return 'qr/' + name

def card(title, subtitle, image, value, copy_label):
    return (f'<article class="card"><h2>{html.escape(title)}</h2><p>{html.escape(subtitle)}</p>'
            f'<img src="{html.escape(image)}" alt="{html.escape(title)} QR code">'
            f'<a href="{html.escape(value, quote=True)}">打开链接</a>'
            f'<button type="button" data-copy="{html.escape(value, quote=True)}">复制{html.escape(copy_label)}</button></article>')

parts = []
standard = subbase + '/sub.txt'
clash = subbase + '/clash.yaml'
parts.append(card('通用订阅（VLESS / Trojan）', '支持订阅 URL 导入的客户端', make_qr('subscription-standard.svg', standard), standard, '订阅链接'))
parts.append(card('Clash / Mihomo 订阅', '适用于 Clash Meta / Mihomo，以及支持 Mihomo 订阅的 Karing、ClashMi', make_qr('subscription-mihomo.svg', clash), clash, '订阅链接'))
for idx, uri in enumerate(nodes, 1):
    scheme = urllib.parse.urlsplit(uri).scheme.upper()
    label = urllib.parse.unquote(urllib.parse.urlsplit(uri).fragment) or f'{scheme} 节点 {idx}'
    parts.append(card(label, f'{scheme} 单节点分享码；使用客户端的扫码导入功能', make_qr(f'node-{idx:02d}.svg', uri), uri, '节点链接'))

page = '''<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="robots" content="noindex,nofollow"><title>Suoha 节点二维码</title><style>*{box-sizing:border-box}body{margin:0;background:#f4f6fa;color:#182230;font:16px/1.5 system-ui,sans-serif}.wrap{max-width:1050px;margin:auto;padding:24px 16px 48px}h1{font-size:26px}.hint,.foot{color:#637083}.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(230px,1fr));gap:16px}.card{background:white;border:1px solid #dce3ec;border-radius:14px;padding:16px;overflow-wrap:anywhere}.card h2{font-size:17px}.card p{font-size:13px;color:#637083;min-height:38px}.card img{display:block;width:min(100%,230px);height:auto;margin:8px auto 14px}.card a,.card button{display:inline-block;margin:4px;padding:8px 11px;border:1px solid #cbd5e1;border-radius:8px;background:white;color:#164e9a;text-decoration:none;cursor:pointer}.foot{font-size:12px;margin-top:22px}</style></head><body><main class="wrap"><h1>Suoha 节点二维码</h1><p class="hint">v2rayNG、v2rayN、Shadowrocket、NekoBox、Hiddify：优先扫描对应的 VLESS / Trojan 单节点码。Clash Meta / Mihomo：使用 Clash / Mihomo 订阅码，通过“从 URL 导入”添加。Karing、ClashMi：优先使用订阅码；也可尝试扫描单节点码，具体取决于客户端版本及扫码入口。</p><section class="grid">''' + ''.join(parts) + '''</section><p class="foot">Suoha ''' + html.escape(version) + ''' · 含私密节点凭据，请勿公开转发。</p></main><script>document.querySelectorAll('[data-copy]').forEach(b=>b.addEventListener('click',async()=>{try{await navigator.clipboard.writeText(b.dataset.copy);b.textContent='已复制'}catch(e){b.textContent='请长按链接复制'}}));</script></body></html>'''
(www / 'qr.html').write_text(page, encoding='utf-8')
PY_QR
  chmod 600 "$WWW/qr.html" "$WWW"/qr/*.svg
  # Keep the QR portal directly after the Clash/Mihomo subscription,
  # before service parameters or Quick Tunnel notes. Rebuild in place so
  # repeated QR regeneration never creates duplicate entries.
  if [[ -f "$DATA/links.txt" ]]; then
    python3 - "$DATA/links.txt" "$host" "$SUB_TOKEN" <<'PY_LINKS'
import pathlib, re, sys
path = pathlib.Path(sys.argv[1])
host, token = sys.argv[2], sys.argv[3]
lines = path.read_text(encoding='utf-8').splitlines()

# Remove any previous QR portal entry, regardless of its old position.
clean = []
skip_url = False
for line in lines:
    if line.strip() == '[二维码扫码页面]:':
        skip_url = True
        continue
    if skip_url:
        if line.strip().startswith('https://') and '/qr.html' in line:
            skip_url = False
            continue
        skip_url = False
    if re.fullmatch(r'https://[^/]+/s/[^/]+/qr\.html', line.strip()):
        continue
    clean.append(line)

# Insert immediately after the Clash/Mihomo subscription URL.
try:
    heading = next(i for i, line in enumerate(clean)
                   if line.strip() == '[Clash / Mihomo 订阅链接]:')
except StopIteration:
    raise SystemExit('找不到 Clash / Mihomo 订阅链接标题，未修改链接文件')

url_index = next((i for i in range(heading + 1, len(clean))
                  if clean[i].strip().startswith('https://')), None)
if url_index is None:
    raise SystemExit('找不到 Clash / Mihomo 订阅 URL，未修改链接文件')

qr_block = ['', '[二维码扫码页面]:',
            f'https://{host}/s/{token}/qr.html']
clean[url_index + 1:url_index + 1] = qr_block
path.write_text('\n'.join(clean).rstrip() + '\n', encoding='utf-8')
PY_LINKS
  fi
  chmod 600 "$DATA/links.txt"
  ok "二维码页面已生成：$WWW/qr.html"
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

# Xray updater: only replaces /opt/suoha/bin/xray. Existing config, UUID,
# ports, paths, subscriptions and Cloudflare Tunnel are deliberately untouched.
xray_current_version(){
  [[ -x "$BIN/xray" ]] || { echo "未安装"; return 1; }
  "$BIN/xray" version 2>/dev/null | head -n1 | sed -E 's/^[^0-9]*([0-9]+\.[0-9]+\.[0-9]+).*/v\1/'
}

xray_asset_for_arch(){
  case "$(uname -m)" in
    x86_64|amd64) printf '%s' 'Xray-linux-64.zip' ;;
    aarch64|arm64) printf '%s' 'Xray-linux-arm64-v8a.zip' ;;
    armv7l|armv7) printf '%s' 'Xray-linux-arm32-v7a.zip' ;;
    i386|i686) printf '%s' 'Xray-linux-32.zip' ;;
    *) die "当前 CPU 架构不受 Xray 更新器支持：$(uname -m)" ;;
  esac
}

xray_release_metadata(){
  local json_file="$1" asset="$2"
  python3 - "$json_file" "$asset" <<'PY_META'
import json,sys
obj=json.load(open(sys.argv[1],encoding='utf-8'))
if obj.get('draft') or obj.get('prerelease'):
    raise SystemExit('GitHub 返回的版本不是正式稳定版')
assets={a.get('name'):a for a in obj.get('assets',[])}
a=assets.get(sys.argv[2])
if not a:
    raise SystemExit('Release 缺少当前架构资产：'+sys.argv[2])
digest=a.get('digest') or ''
if not digest.startswith('sha256:'):
    raise SystemExit('GitHub Release API 未提供该资产的 SHA256 digest；为安全起见停止更新')
print(obj.get('tag_name',''))
print(a.get('browser_download_url',''))
print(digest.split(':',1)[1].lower())
PY_META
}

xray_fetch_release(){
  local tmp="$1" asset="$2" metadata
  curl -fsSL --retry 3 --connect-timeout 10 --max-time 60 \
    -H 'Accept: application/vnd.github+json' -H 'X-GitHub-Api-Version: 2022-11-28' \
    -H 'User-Agent: Suoha-Xray-Updater' "$XRAY_RELEASE_API" -o "$tmp/release.json"
  metadata="$(xray_release_metadata "$tmp/release.json" "$asset")" || return 1
  XRAY_REMOTE_TAG="$(printf '%s\n' "$metadata" | sed -n '1p')"
  XRAY_ASSET_URL="$(printf '%s\n' "$metadata" | sed -n '2p')"
  XRAY_EXPECTED_SHA="$(printf '%s\n' "$metadata" | sed -n '3p')"
  [[ "$XRAY_REMOTE_TAG" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]] || { err "Release 版本号格式异常：$XRAY_REMOTE_TAG"; return 1; }
  [[ "$XRAY_ASSET_URL" == https://github.com/XTLS/Xray-core/releases/download/* ]] || { err "下载地址不是 XTLS 官方 Release 地址"; return 1; }
}

xray_check_update(){
  local tmp asset current
  tmp="$(mktemp -d)" || return 1
  asset="$(xray_asset_for_arch)"
  if ! xray_fetch_release "$tmp" "$asset"; then rm -rf "$tmp"; return 1; fi
  current="$(xray_current_version || true)"
  echo "当前 Xray：${current:-未知}"
  echo "最新稳定版：$XRAY_REMOTE_TAG"
  echo "架构资产：$asset"
  if [[ "${current#v}" == "${XRAY_REMOTE_TAG#v}" ]]; then ok "Xray 已是最新稳定版"; else info "发现可用更新：${current:-未知} -> $XRAY_REMOTE_TAG"; fi
  rm -rf "$tmp"
}

xray_service_is_active(){
  if [[ "$INIT" == systemd ]]; then
    systemctl is-active --quiet suoha-xray.service
  else
    rc-service suoha-xray status >/dev/null 2>&1
  fi
}

xray_restart_and_verify(){
  if [[ "$INIT" == systemd ]]; then
    systemctl restart suoha-xray.service || return 1
    sleep 2
    systemctl is-active --quiet suoha-xray.service || return 1
  else
    rc-service suoha-xray restart || return 1
    sleep 2
    rc-service suoha-xray status >/dev/null 2>&1 || return 1
  fi
  "$BIN/xray" run -test -config "$CONF/xray.json" >/dev/null 2>&1 || return 1
  return 0
}

xray_keep_backups(){
  [[ -d "$XRAY_BACKUP_DIR" ]] || return 0
  python3 - "$XRAY_BACKUP_DIR" <<'PY_CLEAN'
import os,sys
root=sys.argv[1]
files=[os.path.join(root,n) for n in os.listdir(root) if n.startswith('xray-') and os.path.isfile(os.path.join(root,n))]
files.sort(key=lambda p: os.path.getmtime(p), reverse=True)
for path in files[5:]:
    try: os.remove(path)
    except OSError: pass
PY_CLEAN
}

xray_update(){
  local tmp asset current staged backup was_active
  [[ -x "$BIN/xray" ]] || die "未找到当前 Xray：$BIN/xray"
  [[ -s "$CONF/xray.json" ]] || die "未找到 Xray 配置：$CONF/xray.json"
  "$BIN/xray" run -test -config "$CONF/xray.json" >/dev/null || die "当前配置测试失败，拒绝升级"
  was_active=0; xray_service_is_active && was_active=1
  [[ "$was_active" == 1 ]] || die "Xray 服务当前未运行。请先启动服务，再执行在线更新"

  tmp="$(mktemp -d)" || die "无法创建临时目录"
  asset="$(xray_asset_for_arch)"
  info "查询 XTLS/Xray-core 最新正式稳定版..."
  if ! xray_fetch_release "$tmp" "$asset"; then rm -rf "$tmp"; die "获取官方版本信息或 SHA256 校验信息失败"; fi
  current="$(xray_current_version || true)"
  echo "当前版本：${current:-未知}；目标版本：$XRAY_REMOTE_TAG"
  if [[ "${current#v}" == "${XRAY_REMOTE_TAG#v}" ]]; then rm -rf "$tmp"; ok "当前已是最新版本，无需更新"; return 0; fi
  read -r -p "确认将 Xray 更新到 $XRAY_REMOTE_TAG？[y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]] || { rm -rf "$tmp"; info "已取消更新"; return 0; }

  info "下载官方资产：$asset"
  curl -fL --retry 3 --connect-timeout 10 --max-time 300 "$XRAY_ASSET_URL" -o "$tmp/xray.zip" || { rm -rf "$tmp"; die "Xray 下载失败，现有版本未改变"; }
  local actual_sha
  actual_sha="$(sha256sum "$tmp/xray.zip" | awk '{print tolower($1)}')"
  [[ "$actual_sha" == "$XRAY_EXPECTED_SHA" ]] || { rm -rf "$tmp"; die "SHA256 校验失败，拒绝安装下载文件"; }
  unzip -tq "$tmp/xray.zip" >/dev/null || { rm -rf "$tmp"; die "Xray ZIP 完整性检查失败"; }
  mkdir -p "$tmp/extract"
  unzip -oq "$tmp/xray.zip" xray -d "$tmp/extract" || { rm -rf "$tmp"; die "无法从压缩包提取 xray"; }
  staged="$tmp/extract/xray"
  [[ -s "$staged" ]] || { rm -rf "$tmp"; die "下载包中没有有效 xray 文件"; }
  chmod 0755 "$staged"
  "$staged" version >/dev/null 2>&1 || { rm -rf "$tmp"; die "新 Xray 二进制无法执行"; }
  "$staged" run -test -config "$CONF/xray.json" >/dev/null || { rm -rf "$tmp"; die "新 Xray 无法通过现有配置测试，拒绝替换"; }

  install -d -m 0700 "$XRAY_BACKUP_DIR"
  backup="$XRAY_BACKUP_DIR/xray-$(date +%Y%m%d-%H%M%S)-${current#v}"
  cp -a "$BIN/xray" "$backup" || { rm -rf "$tmp"; die "备份当前 Xray 失败，拒绝更新"; }
  chmod 0700 "$XRAY_BACKUP_DIR"; chmod 0700 "$backup"
  info "备份完成：$backup"
  install -m 0755 "$staged" "$BIN/xray.new" || { rm -rf "$tmp"; die "写入新二进制失败，旧版本未改变"; }
  mv -f "$BIN/xray.new" "$BIN/xray"
  if xray_restart_and_verify; then
    local installed_version
    installed_version="$(xray_current_version || true)"
    rm -rf "$tmp"
    xray_keep_backups
    ok "Xray 更新成功：${current:-未知} -> ${installed_version:-$XRAY_REMOTE_TAG}"
    info "Xray 服务已重启并通过配置/运行状态检查；节点、订阅和 Tunnel 配置未改动"
    return 0
  fi

  err "新版本启动或健康检查失败，正在自动回滚..."
  install -m 0755 "$backup" "$BIN/xray.rollback"
  mv -f "$BIN/xray.rollback" "$BIN/xray"
  if xray_restart_and_verify; then
    rm -rf "$tmp"
    err "更新失败，已自动恢复到 $current；原服务已恢复运行"
    return 1
  fi
  rm -rf "$tmp"
  err "自动回滚后服务仍未通过检查，请查看 suoha-xray 日志；旧二进制备份保留在：$backup"
  return 1
}

xray_rollback(){
  local backup current
  [[ -d "$XRAY_BACKUP_DIR" ]] || die "没有找到 Xray 备份目录"
  backup="$(python3 - "$XRAY_BACKUP_DIR" <<'PY_LATEST'
import os,sys
root=sys.argv[1]
files=[os.path.join(root,n) for n in os.listdir(root) if n.startswith('xray-') and os.path.isfile(os.path.join(root,n))]
files.sort(key=lambda p: os.path.getmtime(p), reverse=True)
print(files[0] if files else '')
PY_LATEST
  )"
  [[ -n "$backup" && -s "$backup" ]] || die "没有可用的 Xray 备份"
  "$backup" version >/dev/null 2>&1 || die "备份文件无法执行，拒绝回滚"
  "$backup" run -test -config "$CONF/xray.json" >/dev/null || die "备份版本无法通过当前配置测试，拒绝回滚"
  xray_service_is_active || die "Xray 服务当前未运行，请先启动服务再回滚"
  current="$(xray_current_version || true)"
  read -r -p "确认回滚到 $("$backup" version 2>/dev/null | head -n1)？[y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]] || { info "已取消回滚"; return 0; }
  tmp="$BIN/xray.rollback"
  cp -a "$BIN/xray" "$XRAY_BACKUP_DIR/xray-before-rollback-$(date +%Y%m%d-%H%M%S)" || die "无法备份当前版本"
  install -m 0755 "$backup" "$tmp"
  mv -f "$tmp" "$BIN/xray"
  if xray_restart_and_verify; then ok "Xray 已从 ${current:-当前版本} 回滚至 $(xray_current_version)"; else err "回滚后健康检查失败，请检查服务日志和备份文件"; return 1; fi
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
     path: ^/s/$SUB_TOKEN/(sub\.txt|clash\.yaml|qr\.html|qr/[A-Za-z0-9._-]+\.svg)$
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
  write_qr_portal "$DOMAIN"
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
  write_qr_portal "$d3"
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

regenerate_qr_portal(){
  load_state
  write_sub_server
  local host
  if [[ "$MODE" == fixed ]]; then
    host="$DOMAIN"
    write_fixed_tunnel_config
  else
    host="$(python3 - "$DATA/links.txt" <<'PY_HOST'
import re,sys
try: data=open(sys.argv[1], encoding='utf-8').read()
except OSError: raise SystemExit(1)
m=re.search(r'https://([A-Za-z0-9.-]+\.trycloudflare\.com)/s/', data)
if not m: raise SystemExit(1)
print(m.group(1))
PY_HOST
)" || die "无法从现有 Quick Tunnel 链接识别订阅域名；请先重启 Quick Tunnel 服务"
  fi
  write_qr_portal "$host"
  service_action restart suoha-sub
  if [[ "$MODE" == fixed ]]; then service_action restart suoha-cloudflared; fi
  ok "二维码页面已更新，订阅服务已重启"
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
    echo "7. 查看 Xray 当前版本"
    echo "8. 检查 Xray 最新稳定版"
    echo "9. 更新 Xray（自动备份 / 校验 / 失败回滚）"
    echo "10. 回滚到最近一次 Xray 备份"
    echo "11. 重新生成节点二维码和订阅二维码"
    echo "0. 退出"
    read -r -p "请选择：" c
    case "$c" in
      1) [[ -f "$DATA/links.txt" ]] && cat "$DATA/links.txt" || warn "尚无链接文件" ;;
      2) show_status ;;
      3) restart_services ;;
      4) stop_services ;;
      5) load_state; service_enable_start suoha-xray; service_enable_start suoha-sub; if [[ "$MODE" == fixed ]]; then service_enable_start suoha-cloudflared; else service_enable_start suoha-quick; fi ;;
      6) uninstall_app; return ;;
      7) echo "当前 Xray：$(xray_current_version || echo 未安装)" ;;
      8) xray_check_update || warn "检查更新失败，请检查网络或 GitHub API 状态" ;;
      9) xray_update || warn "Xray 更新未完成；如已触发自动回滚，请检查服务日志" ;;
      10) xray_rollback || warn "Xray 回滚未完成，请检查服务日志" ;;
      11) regenerate_qr_portal || warn "二维码生成或服务重载失败，请检查日志" ;;
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

# Safely deploy this script as the manager of an existing Suoha installation.
# Only the manager script and command symlink are changed; state/config/data/services remain intact.
if [[ "${1:-}" == "--upgrade-manager" ]]; then
  require_root
  os_detect
  [[ -s "$STATE" ]] || die "未发现现有 Suoha 安装状态：$STATE"
  INIT="$( [[ "$OS_FAMILY" == debian ]] && echo systemd || echo openrc )"
  if [[ "$(readlink -f "$0" 2>/dev/null || true)" != "$(readlink -f "$MANAGER" 2>/dev/null || true)" ]]; then
    install -d -m 0755 "$BASE"
    install -m 0700 "$0" "$MANAGER"
  fi
  ln -sf "$MANAGER" /usr/local/bin/suoha
  load_state
  ok "Suoha 管理脚本已升级至 $VERSION；现有配置、节点、订阅及 Tunnel 均未修改"
  manager_menu
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
