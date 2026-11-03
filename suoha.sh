#!/usr/bin/env bash
# Suoha 2.0 - Xray (VLESS + Trojan over WebSocket) + Cloudflare Tunnel
BASE="/opt/suoha"
MANAGER="/root/suoha.sh"
set -Eeuo pipefail
IFS=$'\n\t'

VERSION="2.0.0"
APP="suoha"
BIN="$BASE/bin"
CONF="$BASE/config"
DATA="$BASE/data"
LOG="$BASE/logs"
WWW="$BASE/www"
CF_HOME="/root/.cloudflared"
STATE="$BASE/state.env"

RED='\033[31m'; GREEN='\033[32m'; YELLOW='\033[33m'; BLUE='\033[34m'; RESET='\033[0m'
info(){ echo -e "${BLUE}[INFO]${RESET} $*"; }
ok(){ echo -e "${GREEN}[ OK ]${RESET} $*"; }
warn(){ echo -e "${YELLOW}[WARN]${RESET} $*"; }
err(){ echo -e "${RED}[ERR ]${RESET} $*" >&2; }
die(){ err "$*"; exit 1; }

on_error(){ local rc=$?; err "脚本失败，退出码：$rc"; exit "$rc"; }
trap on_error ERR

require_root(){ [[ ${EUID:-$(id -u)} -eq 0 ]] || die "请使用 root 运行"; }

prepare_dirs(){
  install -d -m 0755 "$BASE" "$BIN" "$CONF" "$DATA" "$LOG" "$WWW"
  install -d -m 0700 "$CF_HOME" 2>/dev/null || true
  chmod 700 "$BASE" "$CONF" "$DATA" "$LOG"
}

load_state(){ [[ -f "$STATE" ]] || die "未找到安装状态"; set -a; . "$STATE"; set +a; }

node_tag(){
  local v="${1:-Argo_Node}"
  v="${v//[^a-zA-Z0-9_.-]/_}"
  [[ -n "$v" ]] || v="Argo_Node"
  printf '%s' "$v"
}

# 12个精准节点（6个VLESS + 6个Trojan）
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

  # VLESS 6个
  domains=("$vless_server" "cf.090227.xyz" "cloudflare.182682.xyz" "www.teamviewer.com" "www.polestar.com" "www.garmin.com")
  labels=("默认入口" "优选cf.090227" "优选182682" "TeamViewer优选" "Polestar优选" "Garmin优选")
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

  # Trojan 6个
  domains=("$trojan_server" "cf.090227.xyz" "cloudflare.182682.xyz" "www.teamviewer.com" "www.polestar.com" "www.garmin.com")
  labels=("默认入口" "优选cf.090227" "优选182682" "TeamViewer优选" "Polestar优选" "Garmin优选")
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

write_sub_server(){
  cat > "$BASE/sub_server.py" <<'PY_SUB'
#!/usr/bin/env python3
import http.server, sys
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

# 优化网页：确保每个“打开”和“复制”按钮均带有完整的有效链接与事件绑定
write_qr_portal(){
  local host="$1" subbase="https://$1/s/$SUB_TOKEN"
  python3 - "$DATA/nodes.txt" "$WWW" "$subbase" "$VERSION" <<'PY_QR'
import html, pathlib, subprocess, sys, urllib.parse
nodes_file, www_dir, subbase, version = sys.argv[1:]
www = pathlib.Path(www_dir)
qrdir = www / 'qr'
qrdir.mkdir(parents=True, exist_ok=True)
nodes = [x.strip() for x in pathlib.Path(nodes_file).read_text().splitlines() if x.strip()]
def make_qr(name, value):
    target = qrdir / name
    subprocess.run(['qrencode', '-t', 'SVG', '-l', 'M', '-m', '2', '-o', str(target), value], check=True)
    return 'qr/' + name

def card(title, subtitle, image, value, copy_label):
    safe_val = html.escape(value, quote=True)
    return (f'<article class="card"><h2>{html.escape(title)}</h2><p>{html.escape(subtitle)}</p>'
            f'<img src="{html.escape(image)}" alt="{html.escape(title)} QR code">'
            f'<div class="actions"><a href="{safe_val}" target="_blank" rel="noopener">打开链接</a>'
            f'<button type="button" class="copy-btn" data-copy="{safe_val}">复制{html.escape(copy_label)}</button></div></article>')

subscription_parts = []
node_parts = []
standard = subbase + '/sub.txt'
clash = subbase + '/clash.yaml'
subscription_parts.append(card('通用订阅（VLESS / Trojan）', '支持通用订阅导入', make_qr('subscription-standard.svg', standard), standard, '订阅'))
subscription_parts.append(card('Clash / Mihomo 订阅', '适用于 Clash Meta 客户端', make_qr('subscription-mihomo.svg', clash), clash, '订阅'))
for idx, uri in enumerate(nodes, 1):
    scheme = urllib.parse.urlsplit(uri).scheme.upper()
    label = urllib.parse.unquote(urllib.parse.urlsplit(uri).fragment) or f'{scheme} 节点 {idx}'
    node_parts.append(card(label, f'{scheme} 单节点', make_qr(f'node-{idx:02d}.svg', uri), uri, '链接'))

page = '''<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Suoha 节点导航与二维码</title><style>
*{box-sizing:border-box}
body{margin:0;background:#f8fafc;color:#1e293b;font:14px/1.4 system-ui,sans-serif}
.wrap{max-width:1300px;margin:auto;padding:30px 20px 50px}
h1{font-size:24px;text-align:center;margin:0 0 20px;color:#0f172a}
.section-title{font-size:16px;margin:25px 0 10px;font-weight:600;color:#334155;border-left:4px solid #3b82f6;padding-left:8px}
.grid{display:grid;gap:14px}
.sub-grid{grid-template-columns:repeat(2,minmax(0,300px));justify-content:center;margin-bottom:15px}
.node-grid{grid-template-columns:repeat(4,minmax(0,1fr))}
.card{background:white;border:1px solid #e2e8f0;border-radius:10px;padding:12px;box-shadow:0 1px 2px rgba(0,0,0,.04);display:flex;flex-direction:column;justify-content:space-between}
.card h2{font-size:13px;margin:0 0 4px;font-weight:600;color:#0f172a;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.card p{font-size:11px;color:#64748b;margin:0 0 8px}
.card img{display:block;width:min(100%,130px);height:auto;margin:4px auto 8px}
.actions{display:flex;gap:6px;margin-top:auto}
.card a,.card button{flex:1;text-align:center;padding:5px 6px;border:1px solid #cbd5e1;border-radius:6px;background:#f8fafc;color:#2563eb;text-decoration:none;cursor:pointer;font-size:11px;font-weight:500}
.card a:hover,.card button:hover{background:#eff6ff;border-color:#3b82f6}
.card button.copied{background:#22c55e;color:white;border-color:#22c55e}
.foot{font-size:12px;text-align:center;margin-top:30px;color:#94a3b8}
@media(max-width:1024px){.node-grid{grid-template-columns:repeat(2,minmax(0,1fr))}}
@media(max-width:580px){.sub-grid,.node-grid{grid-template-columns:minmax(0,1fr)}}
</style></head><body><main class="wrap">
<h1>Suoha 节点导航与二维码</h1>
<h2 class="section-title">订阅入口</h2>
<section class="grid sub-grid">''' + ''.join(subscription_parts) + '''</section>
<h2 class="section-title">节点二维码 (共 12 节点，每行四个)</h2>
<section class="grid node-grid">''' + ''.join(node_parts) + '''</section>
<p class="foot">Suoha ''' + html.escape(version) + ''' · 专属分流架构</p>
</main><script>
document.querySelectorAll('.copy-btn').forEach(btn => {
  btn.addEventListener('click', async () => {
    const textToCopy = btn.getAttribute('data-copy');
    try {
      await navigator.clipboard.writeText(textToCopy);
      const originalText = btn.textContent;
      btn.textContent = '已复制！';
      btn.classList.add('copied');
      setTimeout(() => {
        btn.textContent = originalText;
        btn.classList.remove('copied');
      }, 2000);
    } catch (err) {
      // 兼容旧版浏览器的降级复制方案
      const textarea = document.createElement('textarea');
      textarea.value = textToCopy;
      document.body.appendChild(textarea);
      textarea.select();
      try {
        document.execCommand('copy');
        btn.textContent = '已复制！';
        btn.classList.add('copied');
        setTimeout(() => {
          btn.textContent = originalText;
          btn.classList.remove('copied');
        }, 2000);
      } catch (e) {
        alert('复制失败，请手动长按复制');
      }
      document.body.removeChild(textarea);
    }
  });
});
</script></body></html>'''
(www / 'qr.html').write_text(page, encoding='utf-8')
PY_QR
}

write_urls(){
  local subbase="https://$DOMAIN/s/$SUB_TOKEN"
  cat > "$DATA/links.txt" <<EOF_LINKS
==================================================
              Suoha $VERSION 节点信息
==================================================

$(cat "$DATA/nodes.txt")

--------------------------------------------------
 订阅链接：
--------------------------------------------------
[通用订阅链接]:
$subbase/sub.txt

[Clash / Mihomo 订阅链接]:
$subbase/clash.yaml

[二维码扫码页面]:
$subbase/qr.html
==================================================
EOF_LINKS
  chmod 600 "$DATA/links.txt"
}

regenerate_nodes_and_qr(){
  load_state
  write_node_files "$DOMAIN" "$DOMAIN" "$DOMAIN" "$DOMAIN" "$(node_tag "${DOMAIN%%.*}")"
  install -m 0600 "$DATA/sub.txt" "$DATA/clash.yaml" "$WWW/"
  write_sub_server
  write_qr_portal "$DOMAIN"
  write_urls
  ok "12个节点、订阅链接及交互式按钮页面已全部重新生成完毕！"
  cat "$DATA/links.txt"
}

manager_menu(){
  while true; do
    echo
    echo "========== Suoha $VERSION 管理 =========="
    echo "1. 查看节点和订阅链接"
    echo "11. 重新生成节点二维码和订阅二维码 (更新12节点与交互按钮)"
    echo "0. 退出"
    read -r -p "请选择：" c
    case "$c" in
      1) [[ -f "$DATA/links.txt" ]] && cat "$DATA/links.txt" || echo "尚无链接文件" ;;
      11) regenerate_nodes_and_qr ;;
      0) return ;;
      *) echo "无效选项" ;;
    esac
  done
}

manager_menu
EOF
