#!/bin/bash
# =========================================================
#  Nano Probe v1.2(Enhanced)

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

    if ! command -v python3 &> /dev/null; then
        error "Python3 安装失败，请检查网络或手动安装 python3 后再运行脚本。"
    fi
    success "Python3 环境已就绪。"
}

# --- 嵌入式 Python 客户端 ---
read -r -d '' CLIENT_PY << 'EOF'
import time, json, urllib.request, os, socket, subprocess, sys

class Collector:
    def __init__(self, server_url, key, node_name, targets_raw):
        self.url = server_url
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
        except: return {"ip": "Unknown", "region": "Unknown"}

    def _get_os(self):
        try:
            with open('/etc/os-release') as f:
                for l in f:
                    if 'PRETTY_NAME' in l: return l.split('"')[1].replace("GNU/Linux", "").replace("Linux", "").strip()
        except: return "Linux"

    def _get_net_bytes(self):
        try:
            with open('/proc/net/dev') as f:
                lines = f.readlines()[2:]
            t_in, t_out = 0, 0
            for l in lines:
                if 'lo:' in l: continue
                p = l.split()
                if len(p)>9: t_in += int(p[1]); t_out += int(p[9])
            return t_in, t_out
        except: return 0,0

    def _get_stats(self):
        with open('/proc/stat') as f:
            l = f.readline().split()[1:5]
            u, n, s, i = map(float, l)
        with open('/proc/meminfo') as f:
            m = {l.split(':')[0]: int(l.split(':')[1].split()[0]) for l in f.readlines()[:12]}
        mem_t, mem_a = m['MemTotal']//1024, m.get('MemAvailable', m['MemFree'])//1024
        st = os.statvfs('/')
        disk_t = (st.f_blocks * st.f_frsize) // (1024**3)
        disk_f = (st.f_bfree * st.f_frsize) // (1024**3)
        cur_in, cur_out = self._get_net_bytes()
        dt = time.time() - self.prev_time
        si, so = (cur_in-self.prev_net[0])/dt/1024, (cur_out-self.prev_net[1])/dt/1024
        self.prev_net, self.prev_time = (cur_in, cur_out), time.time()
        tcp = len(open('/proc/net/tcp').readlines()) - 1
        udp = len(open('/proc/net/udp').readlines()) - 1
        with open('/proc/uptime') as f: up = int(float(f.readline().split()[0]))
        pings = {}
        for name, ip in self.targets:
            try:
                out = subprocess.check_output(f"ping -c 1 -W 1 {ip} | grep 'time='", shell=True).decode()
                pings[name] = float(out.split('time=')[1].split()[0])
            except: pings[name] = -1.0
        return {
            "name": self.node_name, "key": self.key, "os": self.os_ver, "ip": self.geo_info['ip'], "region": self.geo_info['region'],
            "cpu": 100 - int(i/(u+n+s+i)*100), "mem_p": round((1-mem_a/mem_t)*100, 1), "mem_u": round(mem_t-mem_a), "mem_t": round(mem_t),
            "disk_p": round((1-disk_f/disk_t)*100, 1), "disk_u": round(disk_t-disk_f, 1), "disk_t": round(disk_t, 1),
            "net_in": round(si, 1), "net_out": round(so, 1), "tcp": tcp, "udp": udp,
            "traff_out": round(cur_out/1024**3, 2), "uptime": up, "pings": pings, "t": int(time.time())
        }

    def run(self):
        while True:
            try:
                d = json.dumps(self._get_stats()).encode()
                urllib.request.urlopen(urllib.request.Request(self.url, data=d), timeout=5)
            except: pass
            time.sleep(3)

if __name__ == "__main__":
    Collector(sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]).run()
EOF

# --- 嵌入式 Python 服务端 ---
read -r -d '' SERVER_PY << 'EOF'
import http.server, json, time, sys
nodes = {}
PORT = int(sys.argv[1]); KEY = sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args): return
    def do_GET(self):
        if self.path == '/':
            self.send_response(200); self.end_headers(); self.wfile.write(HTML.encode())
        elif self.path == '/data':
            self.send_response(200); self.send_header('Content-Type','application/json'); self.end_headers()
            self.wfile.write(json.dumps(nodes).encode())
    def do_POST(self):
        try:
            l = int(self.headers['Content-Length'])
            d = json.loads(self.rfile.read(l).decode())
            if d.get('key') != KEY: self.send_response(403); self.end_headers(); return
            if d.get('action') == 'delete':
                if d.get('name') in nodes: del nodes[d['name']]
                self.send_response(200); self.end_headers(); return
            name = d['name']
            if name not in nodes: nodes[name] = d; nodes[name]['history'] = {}
            hour = time.localtime().tm_hour
            for target, val in d['pings'].items():
                if target not in nodes[name]['history']: nodes[name]['history'][target] = [None]*24
                nodes[name]['history'][target][hour] = val
            hist = nodes[name]['history']; nodes[name] = d; nodes[name]['history'] = hist
            self.send_response(200); self.end_headers()
        except: self.send_response(400); self.end_headers()

HTML = """
<!DOCTYPE html><html><head><meta charset="utf-8"><title>Nano Probe</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<link href="https://cdn.staticfile.org/twitter-bootstrap/5.1.3/css/bootstrap.min.css" rel="stylesheet">
<style>
    body { background: #f4f6f9; font-size: 11px; font-family: -apple-system,BlinkMacSystemFont,sans-serif; }
    .container { max-width: 1400px; }
    .node-card { border: none; border-radius: 6px; box-shadow: 0 1px 4px rgba(0,0,0,0.05); background: #fff; padding: 10px !important; margin-bottom: 2px; }
    .progress { height: 3px; margin-bottom: 5px; background: #eee; border-radius: 2px; }
    .prog-label { display: flex; justify-content: space-between; margin-bottom: 1px; color: #666; font-size: 10px; }
    .heatmap-row { display: flex; align-items: center; margin-top: 3px; padding-top: 3px; border-top: 1px solid #fcfcfc; }
    .heatmap-info { width: 95px; flex-shrink: 0; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; line-height: 1.1; }
    .heatmap-grid { display: flex; gap: 1px; flex-grow: 1; align-items: center; }
    .box { flex: 1; height: 10px; border-radius: 1.5px; background: #eee; min-width: 4px; }
    .lv-0 { background: #2ecc71; } .lv-1 { background: #f1c40f; } .lv-2 { background: #e67e22; } .lv-3 { background: #e74c3c; }
    .del-btn { cursor: pointer; color: #ddd; padding-left: 5px; transition: 0.2s; } .del-btn:hover { color: #e74c3c; }
    .control-bar { background: #fff; padding: 10px 15px; border-radius: 8px; box-shadow: 0 1px 3px rgba(0,0,0,0.05); margin-bottom: 15px; }
    .group-header { padding: 4px 12px; background: #eaedf0; border-radius: 4px; font-weight: bold; margin: 12px 0 6px 0; font-size: 11px; color: #444; }
    .list-item { padding: 8px !important; display: flex; flex-direction: column; justify-content: center; }
    .list-info-line { display: flex; justify-content: space-between; align-items: center; margin-bottom: 4px; border-bottom: 1px solid #f9f9f9; padding-bottom: 4px; }
</style></head><body>
<div class="container py-3">
    <div class="control-bar d-flex flex-wrap justify-content-between align-items-center gap-3">
        <div class="fw-bold fs-6">Nano Probe</div>
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
    function setView(v) { currentView = v; document.getElementById('v-card').classList.toggle('active', v==='card'); document.getElementById('v-list').classList.toggle('active', v==='list'); update(); }
    function setGroup(g) { currentGroup = g; document.getElementById('g-none').classList.toggle('active', g==='none'); document.getElementById('g-region').classList.toggle('active', g==='region'); update(); }
    async function deleteNode(name) { const k = prompt("输入通信密钥:"); if(!k) return; const r = await fetch('/',{method:'POST',body:JSON.stringify({action:'delete',name:name,key:k})}); if(r.ok) update(); else alert("验证失败"); }
    function getLv(v){ if(v===null||v<0) return ''; if(v<50) return 'lv-0'; if(v<150) return 'lv-1'; if(v<300) return 'lv-2'; return 'lv-3'; }
    function fUp(s){ return s<86400 ? (s/3600).toFixed(1)+'h' : (s/86400).toFixed(1)+'d'; }
    function renderHeatRow(histMap, pings) {
        let html = '';
        for(let t in histMap) {
            let h = histMap[t]; let cur = pings[t]>0 ? pings[t].toFixed(0) : 'E';
            html += `<div class="heatmap-row">
                <div class="heatmap-info text-muted"><b>${t}</b> ${cur}ms</div>
                <div class="heatmap-grid">${h.map((v,i)=>`<div class="box ${getLv(v)}" title="${i}:00 | ${v?v+'ms':'N/A'}"></div>`).join('')}</div>
            </div>`;
        }
        return html;
    }
    function renderNode(n, mode) {
        const online = (Date.now()/1000 - n.t) < 30;
        if(mode === 'card') {
            return `<div class="col-lg-3 col-md-6"><div class="card node-card">
                <div class="d-flex justify-content-between align-items-center mb-1"><span class="fw-bold text-truncate" style="max-width:140px">${n.name}<span class="del-btn" onclick="deleteNode('${n.name}')">×</span></span><span class="${online?'text-success':'text-danger'}">●</span></div>
                <div class="text-muted mb-2" style="font-size:9px;line-height:1">${n.os} | ${n.ip} | ${n.region}</div>
                <div class="prog-label"><span>CPU ${n.cpu}%</span><span>UP:${fUp(n.uptime)}</span></div>
                <div class="progress"><div class="progress-bar" style="width:${n.cpu}%"></div></div>
                <div class="prog-label"><span>MEM ${n.mem_p}%</span><span>${(n.mem_u/1024).toFixed(1)}/${(n.mem_t/1024).toFixed(1)}G</span></div>
                <div class="progress"><div class="progress-bar bg-success" style="width:${n.mem_p}%"></div></div>
                <div class="prog-label"><span>DISK ${n.disk_p}%</span><span>${n.disk_u}/${n.disk_t}G</span></div>
                <div class="progress"><div class="progress-bar bg-warning" style="width:${n.disk_p}%"></div></div>
                <div class="d-flex justify-content-between text-muted" style="font-size:9px"><span>↑${n.net_out}K ↓${n.net_in}K</span><span>${n.traff_out}G</span></div>
                ${renderHeatRow(n.history, n.pings)}
            </div></div>`;
        } else {
            return `<div class="col-lg-6 col-12"><div class="card node-card list-item">
                <div class="list-info-line">
                    <span class="fw-bold" style="width:110px"><span class="${online?'text-success':'text-danger'}">●</span> ${n.name}</span>
                    <span class="text-muted" style="width:80px">CPU:${n.cpu}%</span>
                    <span class="text-muted" style="width:130px">RAM:${(n.mem_u/1024).toFixed(1)}/${(n.mem_t/1024).toFixed(1)}G</span>
                    <span class="text-muted" style="width:60px">UP:${fUp(n.uptime)}</span>
                    <span class="del-btn" onclick="deleteNode('${n.name}')">×</span>
                </div>
                ${renderHeatRow(n.history, n.pings)}
            </div></div>`;
        }
    }
    async function update(){
        const data = await (await fetch('/data')).json();
        const app = document.getElementById('app');
        let html = '';
        if(currentGroup === 'none') {
            html = `<div class="row g-2">`;
            for(let id in data) html += renderNode(data[id], currentView);
            html += `</div>`;
        } else {
            const groups = {};
            for(let id in data) { let r = data[id].region; if(!groups[r]) groups[r]=[]; groups[r].push(data[id]); }
            for(let g in groups) {
                html += `<div class="group-header">📍 ${g} (${groups[g].length})</div><div class="row g-2">`;
                groups[g].forEach(n => html += renderNode(n, currentView));
                html += `</div>`;
            }
        }
        app.innerHTML = html;
    }
    setInterval(update, 3000); update();
</script></body></html>
"""
http.server.HTTPServer(('0.0.0.0', PORT), H).serve_forever()
EOF

# --- 菜单逻辑 ---

install_server() {
    check_python
    systemctl stop monitor_server &>/dev/null
    read -p "面板端口 (默认 8080): " s_port; s_port=${s_port:-8080}
    read -p "通信密钥 (默认 admin): " s_key; s_key=${s_key:-admin}
    echo "$SERVER_PY" > /usr/local/bin/monitor_server.py
    cat <<EOF > /etc/systemd/system/monitor_server.service
[Unit]
Description=Monitor Server
After=network.target
[Service]
ExecStart=/usr/bin/python3 /usr/local/bin/monitor_server.py $s_port $s_key
Restart=always
User=root
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload && systemctl enable --now monitor_server
    success "服务端部署成功: http://$(curl -s ifconfig.me):$s_port"
}

install_client() {
    check_python
    systemctl stop monitor_client &>/dev/null
    read -p "服务端 IP: " c_ip; read -p "端口: " c_port; c_port=${c_port:-8080}
    read -p "密钥: " c_key; c_key=${c_key:-admin}
    read -p "节点名: " c_name; read -p "目标 (谷歌,8.8.8.8|江苏电信,218.2.2.2): " c_t
    c_t=${c_t:-谷歌,8.8.8.8|江苏电信,218.2.2.2}
    echo "$CLIENT_PY" > /usr/local/bin/monitor_client.py
    cat <<EOF > /etc/systemd/system/monitor_client.service
[Unit]
Description=Monitor Client
After=network.target
[Service]
ExecStart=/usr/bin/python3 /usr/local/bin/monitor_client.py "http://$c_ip:$c_port" "$c_key" "$c_name" "$c_t"
Restart=always
User=root
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload && systemctl enable --now monitor_client
    success "客户端部署成功并已启动！"
}

clear
echo -e "${BLUE}=== Nano Probe ===${PLAIN}"
echo "1. 安装/覆盖 服务端"
echo "2. 安装/覆盖 客户端"
echo "3. 卸载"
echo "0. 退出"
read -p "请选择: " op
case $op in
    1) install_server ;;
    2) install_client ;;
    3) systemctl stop monitor_server monitor_client; rm -f /etc/systemd/system/monitor_* /usr/local/bin/monitor_*; success "已卸载" ;;
    *) exit 0 ;;
esac
