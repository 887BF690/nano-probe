# nano探针
#!/bin/bash
# =========================================================
#  Nano Probe v1.2

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PLAIN='\033[0m'

info() { echo -e "${BLUE}[INFO]${PLAIN} $1"; }
success() { echo -e "${GREEN}[SUCCESS]${PLAIN} $1"; }
warn() { echo -e "${YELLOW}[WARN]${PLAIN} $1"; }
error() { echo -e "${RED}[ERROR]${PLAIN} $1"; exit 1; }

[[ $EUID -ne 0 ]] && error "必须使用 root 权限运行！"

# --- 环境检测与自动安装 ---
check_python() {
    info "正在检查 Python3 环境..."
    if ! command -v python3 &> /dev/null; then
        warn "未检测到 Python3，正在尝试自动安装..."
        if command -v apt-get &> /dev/null; then
            apt-get update -y && apt-get install -y python3
        elif command -v yum &> /dev/null; then
            yum install -y python3 iputils
        elif command -v dnf &> /dev/null; then
            dnf install -y python3 iputils
        else
            error "无法识别包管理器，请手动安装 python3。"
        fi
    fi
    success "Python3 环境已就绪。"
}

# --- 嵌入式 Python 客户端（优化：10秒上报 + 3包平均Ping + 更健壮解析） ---
read -r -d '' CLIENT_PY << 'EOF'
import time, json, urllib.request, os, subprocess, sys, re

class Collector:
    def __init__(self, server_url, key, node_name, targets_raw):
        self.url = server_url.rstrip("/")
        self.key = key
        self.node_name = node_name
        self.targets = [t.split(',') for t in targets_raw.split('|') if ',' in t]
        self.prev_net = self._get_net_bytes()
        self.prev_time = time.time()
        self.os_ver = self._get_os()
        self.geo_info = self._get_geo()

    def _get_geo(self):
        try:
            res = urllib.request.urlopen('https://ipapi.co/json/', timeout=8).read()
            d = json.loads(res)
            raw_ip = d.get("ip", "0.0.0.0")
            mask = ".".join(raw_ip.split(".")[:2]) + ".***.***"
            return {"ip": mask, "region": d.get("country_code", "UN")}
        except:
            return {"ip": "Unknown", "region": "Unknown"}

    def _get_os(self):
        try:
            with open('/etc/os-release') as f:
                for l in f:
                    if 'PRETTY_NAME' in l:
                        return l.split('"')[1].replace("GNU/Linux", "").replace("Linux", "").strip()
        except:
            pass
        return "Linux"

    def _get_net_bytes(self):
        try:
            with open('/proc/net/dev') as f:
                lines = f.readlines()[2:]
            t_in, t_out = 0, 0
            for l in lines:
                if 'lo:' in l: continue
                p = l.split()
                if len(p) > 9:
                    t_in += int(p[1])
                    t_out += int(p[9])
            return t_in, t_out
        except:
            return 0, 0

    def _get_stats(self):
        # CPU & Mem & Disk
        try:
            with open('/proc/stat') as f:
                l = f.readline().split()[1:5]
                u, n, s, i = map(float, l)
            total_cpu = u + n + s + i
            cpu_usage = 100 - (i / total_cpu * 100) if total_cpu > 0 else 0
        except:
            cpu_usage = 0

        try:
            with open('/proc/meminfo') as f:
                m = {}
                for l in f.readlines()[:12]:
                    parts = l.split()
                    if len(parts) >= 2:
                        m[parts[0].rstrip(':')] = int(parts[1])
            mem_t = m.get('MemTotal', 0) // 1024
            mem_a = m.get('MemAvailable', m.get('MemFree', 0)) // 1024
        except:
            mem_t = mem_a = 0

        try:
            st = os.statvfs('/')
            disk_t = (st.f_blocks * st.f_frsize) // (1024**3)
            disk_f = (st.f_bfree * st.f_frsize) // (1024**3)
        except:
            disk_t = disk_f = 1

        # Network speed
        cur_in, cur_out = self._get_net_bytes()
        dt = time.time() - self.prev_time
        net_in = round((cur_in - self.prev_net[0]) / dt / 1024, 1) if dt > 0 else 0
        net_out = round((cur_out - self.prev_net[1]) / dt / 1024, 1) if dt > 0 else 0
        self.prev_net = (cur_in, cur_out)
        self.prev_time = time.time()

        # Connections & uptime
        try:
            tcp = len(open('/proc/net/tcp').readlines()) - 1
            udp = len(open('/proc/net/udp').readlines()) - 1
        except:
            tcp = udp = 0
        try:
            with open('/proc/uptime') as f:
                up = int(float(f.readline().split()[0]))
        except:
            up = 0

        # Ping (3 packets average)
        pings = {}
        for name, ip in self.targets:
            ping_val = -1.0
            try:
                out = subprocess.check_output(
                    ['ping', '-c', '3', '-W', '3', ip],
                    stderr=subprocess.STDOUT
                ).decode('utf-8', errors='ignore')

                # English rtt line
                if 'rtt' in out.lower() or 'avg' in out.lower():
                    m = re.search(r'/([0-9.]+(\.[0-9]+)?)/', out.lower())
                    if m:
                        ping_val = float(m.group(1))
                # Chinese average
                if ping_val < 0 and '平均' in out:
                    m = re.search(r'平均\s*=\s*([0-9.]+(\.[0-9]+)?)', out)
                    if m:
                        ping_val = float(m.group(1))
                # Fallback single time (rare)
                if ping_val < 0 and ('time=' in out.lower() or '时间=' in out):
                    m = re.search(r'(?:time|时间)[=<\s]*([0-9.]+)', out, re.IGNORECASE)
                    if m:
                        ping_val = float(m.group(1))
            except:
                ping_val = -1.0
            pings[name] = ping_val if ping_val > 0 else -1.0

        return {
            "name": self.node_name, "key": self.key, "os": self.os_ver,
            "ip": self.geo_info['ip'], "region": self.geo_info['region'],
            "cpu": round(cpu_usage, 1),
            "mem_p": round((1 - mem_a / mem_t) * 100, 1) if mem_t > 0 else 0,
            "mem_u": round(mem_t - mem_a), "mem_t": round(mem_t),
            "disk_p": round((1 - disk_f / disk_t) * 100, 1) if disk_t > 0 else 0,
            "disk_u": round(disk_t - disk_f, 1), "disk_t": round(disk_t, 1),
            "net_in": net_in, "net_out": net_out,
            "tcp": tcp, "udp": udp,
            "traff_out": round(cur_out / 1024**3, 2),
            "uptime": up, "pings": pings, "t": int(time.time())
        }

    def run(self):
        while True:
            try:
                data = json.dumps(self._get_stats()).encode()
                req = urllib.request.Request(self.url, data=data)
                urllib.request.urlopen(req, timeout=8)
            except:
                pass
            time.sleep(10)

if __name__ == "__main__":
    if len(sys.argv) != 5:
        print("Usage: python3 script.py <url> <key> <name> <targets>")
        sys.exit(1)
    Collector(sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]).run()
EOF

# --- 嵌入式 Python 服务端（优化：自动清理离线节点 + 更健壮） ---
read -r -d '' SERVER_PY << 'EOF'
import http.server
import socketserver
import threading
import json
import time
import sys

nodes = {}
lock = threading.Lock()
PORT = int(sys.argv[1])
KEY = sys.argv[2]
OFFLINE_TIMEOUT = 600  # 10分钟未上报视为离线并清理

class ThreadedHTTPServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True

class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args): return

    def do_GET(self):
        if self.path == '/':
            self.send_response(200)
            self.end_headers()
            self.wfile.write(HTML.encode())
        elif self.path == '/data':
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            with lock:
                self.wfile.write(json.dumps(nodes).encode())

    def do_POST(self):
        try:
            length = int(self.headers.get('Content-Length', 0))
            if length == 0:
                self.send_response(400)
                self.end_headers()
                return
            raw = self.rfile.read(length)
            d = json.loads(raw.decode('utf-8'))

            now = time.time()
            with lock:
                # 自动清理离线节点
                to_del = [k for k, v in nodes.items() if now - v.get('t', 0) > OFFLINE_TIMEOUT]
                for k in to_del:
                    del nodes[k]

                if d.get('key') != KEY:
                    self.send_response(403)
                    self.end_headers()
                    return

                if d.get('action') == 'delete':
                    name = d.get('name')
                    if name and name in nodes:
                        del nodes[name]
                    self.send_response(200)
                    self.end_headers()
                    return

                name = d['name']
                current_history = nodes[name]['history'] if name in nodes else {}
                hour = time.localtime().tm_hour
                for target, val in d.get('pings', {}).items():
                    if target not in current_history:
                        current_history[target] = [None] * 24
                    current_history[target][hour] = val if val > 0 else None

                nodes[name] = d
                nodes[name]['history'] = current_history

            self.send_response(200)
            self.end_headers()
        except:
            self.send_response(400)
            self.end_headers()

HTML = """
<!DOCTYPE html><html><head><meta charset="utf-8"><title>Nano Probe</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<link href="https://cdn.staticfile.org/twitter-bootstrap/5.3.3/css/bootstrap.min.css" rel="stylesheet">
<style>
    body { background: #f4f6f9; font-size: 11px; font-family: -apple-system,BlinkMacSystemFont,sans-serif; }
    .container { max-width: 1400px; }
    .node-card { border: none; border-radius: 8px; box-shadow: 0 1px 6px rgba(0,0,0,0.08); background: #fff; padding: 12px !important; margin-bottom: 8px; }
    .progress { height: 4px; margin-bottom: 6px; background: #eee; border-radius: 2px; }
    .prog-label { display: flex; justify-content: space-between; margin-bottom: 2px; color: #666; font-size: 10px; }
    .heatmap-row { display: flex; align-items: center; margin-top: 4px; padding-top: 4px; border-top: 1px solid #fcfcfc; }
    .heatmap-info { width: 100px; flex-shrink: 0; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; line-height: 1.2; }
    .heatmap-grid { display: flex; gap: 1.5px; flex-grow: 1; }
    .box { flex: 1; height: 12px; border-radius: 2px; background: #eee; min-width: 5px; }
    .lv-0 { background: #2ecc71; }
    .lv-1 { background: #abe338; }
    .lv-2 { background: #f1c40f; }
    .lv-3 { background: #ffcc00; }
    .lv-4 { background: #ff9900; }
    .lv-5 { background: #e67e22; }
    .lv-6 { background: #f39c12; }
    .lv-7 { background: #e74c3c; }
    .lv-8 { background: #c0392b; }
    .lv-9 { background: #8e44ad; }
    .del-btn { cursor: pointer; color: #ddd; padding-left: 6px; transition: 0.2s; } .del-btn:hover { color: #e74c3c; }
    .control-bar { background: #fff; padding: 12px 16px; border-radius: 10px; box-shadow: 0 2px 6px rgba(0,0,0,0.08); margin-bottom: 16px; }
    .group-header { padding: 6px 14px; background: #eaedf0; border-radius: 6px; font-weight: bold; margin: 14px 0 8px 0; font-size: 12px; color: #444; }
</style></head><body>
<div class="container py-4">
    <div class="control-bar d-flex flex-wrap justify-content-between align-items-center gap-3">
        <div class="fw-bold fs-5">Nano Probe</div>
        <div class="d-flex flex-wrap gap-2">
            <div class="btn-group btn-group-sm">
                <button class="btn btn-outline-primary active" id="g-none" onclick="setGroup('none')">全部</button>
                <button class="btn btn-outline-primary" id="g-region" onclick="setGroup('region')">地区</button>
            </div>
            <div class="btn-group btn-group-sm">
                <button class="btn btn-outline-secondary active" id="v-card" onclick="setView('card')">卡片</button>
                <button class="btn btn-outline-secondary" id="v-list" onclick="setView('list')">列表</button>
            </div>
        </div>
    </div>
    <div id="app"></div>
</div>
<script>
    let currentView = 'card', currentGroup = 'none';
    function setView(v) { currentView = v; ['v-card','v-list'].forEach(id=>document.getElementById(id).classList.toggle('active',id==='v-'+v)); update(); }
    function setGroup(g) { currentGroup = g; ['g-none','g-region'].forEach(id=>document.getElementById(id).classList.toggle('active',id==='g-'+g)); update(); }
    async function deleteNode(name) { 
        const k = prompt("输入通信密钥:"); 
        if(!k) return; 
        const r = await fetch('/',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({action:'delete',name:name,key:k})}); 
        if(r.ok) update(); else alert("密钥错误"); 
    }
    function getLv(v) {
        if (v === null || v === undefined || v < 0) return '';
        let level = Math.min(9, Math.floor(v / 50));
        return 'lv-' + level;
    }
    function fUp(s){
        if(s<86400) return (s/3600).toFixed(1)+'h';
        return (s/86400).toFixed(1)+'d';
    }
    function renderHeatRow(histMap, pings) {
        let html = '';
        for(let t in histMap) {
            let cur = (pings[t] !== undefined && pings[t] > 0) ? pings[t].toFixed(0)+'ms' : 'Loss';
            html += `<div class="heatmap-row">
                <div class="heatmap-info text-muted"><b>${t}</b> ${cur}</div>
                <div class="heatmap-grid">${histMap[t].map((v,i)=>`<div class="box ${getLv(v)}" title="${i}:00 | ${v !== null ? v+'ms' : 'Loss'}"></div>`).join('')}</div>
            </div>`;
        }
        return html;
    }
    function renderNode(n, mode) {
        const online = (Date.now()/1000 - n.t) < 90;
        if(mode === 'card') {
            return `<div class="col-lg-3 col-md-6 col-sm-12"><div class="card node-card">
                <div class="d-flex justify-content-between align-items-center mb-2"><span class="fw-bold text-truncate" style="max-width:150px">${n.name}<span class="del-btn" onclick="deleteNode('${n.name}')">×</span></span><span class="${online?'text-success':'text-danger'} fs-5">●</span></div>
                <div class="text-muted mb-3" style="font-size:10px">${n.os} | ${n.ip} | ${n.region}</div>
                <div class="prog-label"><span>CPU ${n.cpu}%</span><span>UP:${fUp(n.uptime)}</span></div>
                <div class="progress"><div class="progress-bar bg-info" style="width:${n.cpu}%"></div></div>
                <div class="prog-label"><span>MEM ${n.mem_p}%</span><span>${(n.mem_u/1024).toFixed(1)}/${(n.mem_t/1024).toFixed(1)}G</span></div>
                <div class="progress"><div class="progress-bar bg-success" style="width:${n.mem_p}%"></div></div>
                <div class="prog-label"><span>DISK ${n.disk_p}%</span><span>${n.disk_u}/${n.disk_t}G</span></div>
                <div class="progress"><div class="progress-bar bg-warning" style="width:${n.disk_p}%"></div></div>
                <div class="d-flex justify-content-between text-muted mt-2" style="font-size:10px"><span>↑${n.net_out}K ↓${n.net_in}K</span><span>Out:${n.traff_out}G</span></div>
                ${renderHeatRow(n.history, n.pings)}
            </div></div>`;
        } else {
            return `<div class="col-12"><div class="card node-card">
                <div class="d-flex justify-content-between align-items-center mb-2">
                    <span class="fw-bold"><span class="${online?'text-success':'text-danger'} fs-5">●</span> ${n.name}</span>
                    <span class="text-muted me-3">CPU ${n.cpu}% | RAM ${(n.mem_u/1024).toFixed(1)}/${(n.mem_t/1024).toFixed(1)}G | UP ${fUp(n.uptime)}</span>
                    <span class="del-btn" onclick="deleteNode('${n.name}')">×</span>
                </div>
                ${renderHeatRow(n.history, n.pings)}
            </div></div>`;
        }
    }
    async function update(){
        try {
            const data = await (await fetch('/data')).json();
            let html = '';
            if(currentGroup === 'none') {
                html = `<div class="row g-3">`;
                for(let id in data) html += renderNode(data[id], currentView);
                html += `</div>`;
            } else {
                const groups = {};
                for(let id in data) {
                    let r = data[id].region || 'UN';
                    if(!groups[r]) groups[r]=[];
                    groups[r].push(data[id]);
                }
                for(let g in groups) {
                    html += `<div class="group-header">📍 ${g} (${groups[g].length}节点)</div><div class="row g-3">`;
                    groups[g].forEach(n => html += renderNode(n, currentView));
                    html += `</div>`;
                }
            }
            document.getElementById('app').innerHTML = html || '<div class="text-center text-muted py-5">暂无节点数据</div>';
        } catch(e) {
            document.getElementById('app').innerHTML = '<div class="text-center text-danger py-5">加载失败</div>';
        }
    }
    setInterval(update, 5000);
    update();
</script></body></html>
"""

ThreadedHTTPServer(('0.0.0.0', PORT), H).serve_forever()
EOF

# --- 菜单逻辑 ---
install_server() {
    check_python
    systemctl stop monitor_server &>/dev/null
    read -p "面板端口 (默认 8080): " s_port; s_port=${s_port:-8080}
    read -p "通信密钥 (默认 admin，建议修改): " s_key; s_key=${s_key:-admin}
    echo "$SERVER_PY" > /usr/local/bin/monitor_server.py
    cat <<EOF > /etc/systemd/system/monitor_server.service
[Unit]
Description=Nano Probe Server
After=network.target

[Service]
ExecStart=/usr/bin/python3 /usr/local/bin/monitor_server.py $s_port $s_key
Restart=always
User=root
WorkingDirectory=/usr/local/bin

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload && systemctl enable --now monitor_server
    ip=$(curl -s ifconfig.me || echo "本地IP")
    success "服务端部署成功！访问地址: http://$ip:$s_port"
}

install_client() {
    check_python
    systemctl stop monitor_client &>/dev/null
    read -p "服务端地址 (IP或域名): " c_ip
    read -p "服务端端口 (默认 8080): " c_port; c_port=${c_port:-8080}
    read -p "通信密钥: " c_key
    read -p "节点名称: " c_name
    default_targets="谷歌,8.8.8.8|Cloudflare,1.1.1.1|北京移动,211.138.30.66|北京联通,123.123.123.123|江苏电信,218.2.2.2"
    read -p "探针目标 (格式: 名称,IP|名称,IP 默认: $default_targets): " c_t
    c_t=${c_t:-$default_targets}
    echo "$CLIENT_PY" > /usr/local/bin/monitor_client.py
    cat <<EOF > /etc/systemd/system/monitor_client.service
[Unit]
Description=Nano Probe Client
After=network.target

[Service]
ExecStart=/usr/bin/python3 /usr/local/bin/monitor_client.py "http://$c_ip:$c_port" "$c_key" "$c_name" "$c_t"
Restart=always
User=root
WorkingDirectory=/usr/local/bin

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload && systemctl enable --now monitor_client
    success "客户端部署成功并已启动！"
}

clear
echo -e "${BLUE}=== Nano Probe v1.2 (Optimized) ===${PLAIN}"
echo "1. 安装/覆盖 服务端"
echo "2. 安装/覆盖 客户端"
echo "3. 卸载所有"
echo "0. 退出"
read -p "请选择: " op
case $op in
    1) install_server ;;
    2) install_client ;;
    3) systemctl stop monitor_server monitor_client &>/dev/null
       rm -f /etc/systemd/system/monitor_* /usr/local/bin/monitor_*
       systemctl daemon-reload
       success "Nano Probe 已完全卸载" ;;
    *) exit 0 ;;
esac
