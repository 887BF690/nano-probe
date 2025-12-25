#!/bin/bash
# =========================================================
#  Nano Probe v1.1
# =========================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
PLAIN='\033[0m'

[[ $EUID -ne 0 ]] && echo -e "${RED}❌ 请以 root 运行${PLAIN}" && exit 1

prepare_env() {
    echo -e "${CYAN}正在初始化环境...${PLAIN}"
    systemctl stop probe_server probe_client 2>/dev/null
    
    if command -v apt-get >/dev/null; then
        apt-get update -y && apt-get install -y python3 python3-pip python3-venv curl gawk procps net-tools iputils-ping iproute2
    elif command -v yum >/dev/null; then
        yum install -y python3 python3-pip curl gawk procps-ng net-tools iputils iproute
    fi
    
    rm -rf /usr/local/bin/probe_venv
    python3 -m venv /usr/local/bin/probe_venv
    /usr/local/bin/probe_venv/bin/pip install --upgrade pip --quiet
    /usr/local/bin/probe_venv/bin/pip install fastapi uvicorn websockets python-multipart --quiet
}

# --- 服务端安装 ---
install_server() {
    prepare_env
    read -p "服务端端口 (默认 8080): " port
    port=${port:-8080}
    read -p "通信密钥 (Secret): " secret
    secret=${secret:-123456}

    touch /usr/local/bin/probe_history.json
    chmod 666 /usr/local/bin/probe_history.json

    cat <<EOF > /usr/local/bin/probe_server.py
import asyncio, json, time, os
from fastapi import FastAPI, WebSocket, Request, Header, HTTPException
from fastapi.responses import HTMLResponse

app = FastAPI()
nodes = {}
history_log = {}
HISTORY_FILE = "/usr/local/bin/probe_history.json"
HTML_FILE = "/usr/local/bin/probe_index.html"
SECRET = "$secret"

if os.path.exists(HISTORY_FILE):
    try:
        with open(HISTORY_FILE, "r", encoding="utf-8") as f:
            history_log = json.load(f)
    except: history_log = {}

def get_slot_data(data_list, now):
    slots = [[] for _ in range(48)]
    for ts, val in data_list:
        idx = (now - ts) // 1800
        if 0 <= idx < 48: slots[idx].append(val)
    return [round(sum(s)/len(s), 1) if s else -1 for s in slots]

class ConnectionManager:
    def __init__(self): self.active_connections = []
    async def connect(self, ws): await ws.accept(); self.active_connections.append(ws)
    def disconnect(self, ws): 
        if ws in self.active_connections: self.active_connections.remove(ws)
    async def broadcast(self, msg):
        for conn in self.active_connections:
            try: await conn.send_text(msg)
            except: continue

manager = ConnectionManager()

@app.post("/report")
async def report(request: Request, auth: str = Header(None)):
    if auth != SECRET: raise HTTPException(status_code=403)
    try:
        data = await request.json()
        name = data.get("name")
        now = int(time.time())
        data["ts"] = now * 1000
        nodes[name] = data
        if name not in history_log: history_log[name] = {"cpu": [], "ping": {}}
        if not history_log[name]["cpu"] or (now - history_log[name]["cpu"][-1][0] >= 300):
            history_log[name]["cpu"].append((now, data.get("cpu", 0)))
            for t, v in data.get("ping", {}).items():
                if t not in history_log[name]["ping"]: history_log[name]["ping"][t] = []
                history_log[name]["ping"][t].append((now, v))
            history_log[name]["cpu"] = [x for x in history_log[name]["cpu"] if x[0] > now - 86400]
            for t in history_log[name]["ping"]:
                history_log[name]["ping"][t] = [x for x in history_log[name]["ping"][t] if x[0] > now - 86400]
            with open(HISTORY_FILE, "w") as f: json.dump(history_log, f)
        await manager.broadcast(json.dumps({
            "type": "update", "node": data,
            "history": {
                "cpu": get_slot_data(history_log[name]["cpu"], now),
                "ping": {t: get_slot_data(history_log[name]["ping"][t], now) for t in history_log[name]["ping"]}
            }
        }))
        return "ok"
    except: return "error"

@app.delete("/node/{name}")
async def delete_node(name: str, auth: str = Header(None)):
    if auth != SECRET: raise HTTPException(status_code=403)
    if name in nodes: del nodes[name]
    if name in history_log:
        del history_log[name]
        with open(HISTORY_FILE, "w") as f: json.dump(history_log, f)
    await manager.broadcast(json.dumps({"type": "delete", "name": name}))
    return "ok"

@app.websocket("/ws")
async def websocket_endpoint(ws: WebSocket):
    await manager.connect(ws)
    now = int(time.time())
    h_all = {n: {"cpu": get_slot_data(history_log[n]["cpu"], now), "ping": {t: get_slot_data(history_log[n]["ping"][t], now) for t in history_log[n]["ping"]}} for n in nodes if n in history_log}
    await ws.send_text(json.dumps({"type": "init", "nodes": nodes, "history": h_all, "now": now}))
    try:
        while True: await ws.receive_text()
    except: manager.disconnect(ws)

@app.get("/")
async def index():
    if os.path.exists(HTML_FILE):
        with open(HTML_FILE, "r") as f: return HTMLResponse(content=f.read())
    return "HTML file not found"

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=$port)
EOF

    # 2. HTML 前端 (已修复离线判定时间，优化稳定性)
    cat <<'EOF' > /usr/local/bin/probe_index.html
<!DOCTYPE html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Nano Probe v1.1</title>
<style>
:root { --bg: #f8fafc; --card: #ffffff; --text: #0f172a; --sub: #64748b; --border: #e2e8f0; --accent: #3b82f6; --green: #10b981; --red: #f43f5e; --orange: #f59e0b; --heat-empty: #e2e8f0; }
[data-theme='dark'] { --bg: #0f172a; --card: #1e293b; --text: #f1f5f9; --sub: #94a3b8; --border: #334155; --heat-empty: #334155; }
body { font-family: -apple-system, system-ui, sans-serif; background: var(--bg); color: var(--text); margin: 0; padding: 10px; transition: 0.2s; }
.header { max-width: 1400px; margin: 0 auto 10px; display: flex; justify-content: space-between; align-items: center; }
.btn-group { display: flex; gap: 4px; }
.btn { background: var(--card); border: 1px solid var(--border); color: var(--text); padding: 4px 8px; border-radius: 6px; cursor: pointer; font-size: 11px; font-weight: 500; }
.btn.active { background: var(--accent); color: white; border-color: var(--accent); }
.btn-del { color: var(--sub); border: none; background: transparent; cursor: pointer; font-size: 14px; transition: 0.2s; }
.btn-del:hover { color: var(--red); transform: scale(1.2); }
.grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(275px, 1fr)); gap: 8px; max-width: 1400px; margin: 0 auto; }
.card { background: var(--card); border: 1px solid var(--border); border-radius: 10px; padding: 10px; box-shadow: 0 1px 2px rgba(0,0,0,0.05); }
.list-view { max-width: 1400px; margin: 0 auto; background: var(--card); border-radius: 10px; border: 1px solid var(--border); overflow-x: auto; }
table { width: 100%; border-collapse: collapse; font-size: 12px; min-width: 900px; }
th { text-align: left; padding: 10px; border-bottom: 2px solid var(--border); color: var(--sub); }
td { padding: 8px 10px; border-bottom: 1px solid var(--border); }
.status-dot { width: 8px; height: 8px; border-radius: 50%; display: inline-block; margin-right: 5px; }
.online { background: var(--green); box-shadow: 0 0 6px var(--green); }
.offline { background: var(--red); }
.bar-bg { height: 5px; background: var(--heat-empty); border-radius: 3px; overflow: hidden; margin: 3px 0 6px 0; }
.bar-fill { height: 100%; transition: width 0.4s; }
.row { font-size: 11px; margin: 1px 0; display: flex; justify-content: space-between; align-items: center; }
.row b { font-family: ui-monospace, monospace; font-size: 12px; }
.heatmap-row { display: flex; justify-content: space-between; align-items: center; margin-top: 5px; padding-top: 3px; border-top: 1px dotted var(--border); }
.heatmap-label { font-size: 10px; color: var(--sub); max-width: 90px; overflow: hidden; }
.heatmap { display: flex; gap: 2px; }
.heat-col { display: flex; flex-direction: column; gap: 2px; }
.heat-dot { width: 5px; height: 5px; border-radius: 50%; background: var(--heat-empty); }
.group-title { grid-column: 1 / -1; font-size: 13px; font-weight: bold; padding: 8px 0 2px; color: var(--accent); display: flex; align-items: center; gap: 5px; }
</style></head>
<body>
    <div class="header">
        <h4 style="margin:0">📡 Nano Probe <small id="st" style="color:var(--sub);font-weight:normal"></small></h4>
        <div class="btn-group">
            <button class="btn" id="btn-grid" onclick="setView('grid')">卡片</button>
            <button class="btn" id="btn-list" onclick="setView('list')">列表</button>
            <button class="btn" id="btn-group" onclick="toggleGroup()">分组: <span id="group-st"></span></button>
            <button class="btn" onclick="toggleTheme()">🌗</button>
        </div>
    </div>
    <div id="app"></div>
<script>
    let nodes = {}, historyMap = {}, serverTime = Date.now()/1000;
    let viewMode = localStorage.getItem('v') || 'grid';
    let groupMode = localStorage.getItem('g') === 'true';
    // 调整离线判定时间为30秒，避免频繁掉线
    const OFFLINE_THRESHOLD = 30000;

    function setView(v) { viewMode = v; localStorage.setItem('v', v); render(); }
    function toggleGroup() { groupMode = !groupMode; localStorage.setItem('g', groupMode); render(); }
    function toggleTheme() { 
        const t = document.documentElement.getAttribute('data-theme') === 'dark' ? 'light' : 'dark';
        document.documentElement.setAttribute('data-theme', t); localStorage.setItem('t', t);
    }
    if(localStorage.getItem('t')) document.documentElement.setAttribute('data-theme', localStorage.getItem('t'));

    function maskIP(ip) {
        if(!ip) return '*.*.*.*';
        let p = ip.split('.'); return p.length!==4 ? ip : `${p[0]}.${p[1]}.*.*`;
    }

    async function deleteNode(name) {
        if(!confirm(`确认彻底移除 [${name}]？`)) return;
        const secret = prompt("请输入管理密钥:");
        if(!secret) return;
        try { const res = await fetch(`/node/${name}`, { method: 'DELETE', headers: { 'Auth': secret } }); } catch(e) {}
    }

    function connect() {
        const protocol = location.protocol === 'https:' ? 'wss:' : 'ws:';
        const ws = new WebSocket(`${protocol}//${location.host}/ws`);
        ws.onopen = () => document.getElementById('st').textContent = '● Live';
        ws.onmessage = (e) => {
            const d = JSON.parse(e.data);
            if(d.type === 'init'){ nodes = d.nodes; historyMap = d.history; serverTime = d.now; }
            else if(d.type === 'update'){ nodes[d.node.name] = d.node; if(d.history) historyMap[d.node.name] = d.history; }
            else if(d.type === 'delete'){ delete nodes[d.name]; }
            render();
        };
        ws.onclose = () => { 
            document.getElementById('st').textContent = '● Disconnected';
            setTimeout(connect, 3000); 
        };
    }

    const buildHeatmap = (data, type, label, cur) => {
        let cols = ''; const safe = data || Array(48).fill(-1);
        for(let i=0; i<24; i++){
            const tIdx = 47-(i*2+1), bIdx = 47-(i*2);
            const vT = safe[tIdx], vB = safe[bIdx];
            const color = (v) => v < 0 ? 'var(--heat-empty)' : (v<(type==='cpu'?30:50)?'#10b981':(v<(type==='cpu'?70:150)?'#f59e0b':'#f43f5e'));
            cols += `<div class="heat-col"><div class="heat-dot" style="background:${color(vT)}" title="${vT<0?'无数据':vT+(type==='cpu'?'%':'ms')}"></div><div class="heat-dot" style="background:${color(vB)}" title="${vB<0?'无数据':vB+(type==='cpu'?'%':'ms')}"></div></div>`;
        }
        return `<div class="heatmap-row"><span class="heatmap-label">${label} <b>${cur!==undefined?Math.round(cur):''}</b></span><div class="heatmap">${cols}</div></div>`;
    };

    function render() {
        const app = document.getElementById('app');
        document.getElementById('btn-grid').className = `btn ${viewMode==='grid'?'active':''}`;
        document.getElementById('btn-list').className = `btn ${viewMode==='list'?'active':''}`;
        document.getElementById('group-st').textContent = groupMode ? '开' : '关';
        const sorted = Object.values(nodes).sort((a,b) => a.name.localeCompare(b.name));
        
        if(viewMode === 'list') {
            let html = '<div class="list-view"><table><tr><th>节点</th><th>地区</th><th>运行时长</th><th>CPU</th><th>内存</th><th>硬盘</th><th>流量速率/总计</th><th>连接(T/U)</th><th>IP地址</th><th></th></tr>';
            let lastG = '';
            sorted.forEach(n => {
                // 使用调整后的离线阈值判定
                const online = (Date.now()-n.ts) < OFFLINE_THRESHOLD;
                if(groupMode && n.region !== lastG) {
                    lastG = n.region || 'Unknown';
                    html += `<tr class="list-group-row"><td colspan="10">📍 ${lastG}</td></tr>`;
                }
                html += `<tr>
                    <td><span class="status-dot ${online?'online':'offline'}"></span>${n.name}</td>
                    <td>${n.region || '-'}</td>
                    <td>${n.uptime || '-'}</td>
                    <td>${n.cpu}%</td><td>${n.mem_u}/${n.mem_t}</td><td>${n.disk_u}/${n.disk_t}</td>
                    <td><small>↓${n.rx} ↑${n.tx}<br>Σ ↓${n.t_rx} ↑${n.t_tx}</small></td>
                    <td>${n.tcp || 0} / ${n.udp || 0}</td>
                    <td>${maskIP(n.ip)}</td>
                    <td><button class="btn-del" onclick="deleteNode('${n.name}')">🗑️</button></td>
                </tr>`;
            });
            app.innerHTML = html + '</table></div>'; return;
        }

        let html = '<div class="grid">'; let lastG = '';
        sorted.forEach(n => {
            // 使用调整后的离线阈值判定
            const online = (Date.now()-n.ts) < OFFLINE_THRESHOLD;
            if(groupMode && n.region !== lastG) {
                lastG = n.region || 'Unknown';
                html += `<div class="group-title">📍 ${lastG}</div>`;
            }
            const h = historyMap[n.name] || {cpu:[], ping:{}};
            let h_html = buildHeatmap(h.cpu, 'cpu', 'CPU');
            Object.keys(n.ping || {}).forEach(p => { h_html += buildHeatmap(h.ping[p], 'ping', p.split(',')[0], n.ping[p]); });
            html += `<div class="card" style="opacity:${online?1:0.6}">
                <div class="row"><b><span class="status-dot ${online?'online':'offline'}"></span>${n.name}</b> <small style="color:var(--sub);font-size:10px">${maskIP(n.ip)}</small></div>
                <div class="row" style="margin-bottom:4px"><span style="color:var(--sub)">${n.os}</span><span style="color:var(--accent)">${n.region||''}</span></div>
                <div class="row"><span>在线</span><b>${n.uptime || '-'}</b></div>
                <div class="row"><span>连接</span><b>TCP: ${n.tcp || 0} | UDP: ${n.udp || 0}</b></div>
                <div class="row" style="margin-top:4px"><span>CPU</span><b>${n.cpu}%</b></div><div class="bar-bg"><div class="bar-fill" style="width:${n.cpu}%;background:var(--green)"></div></div>
                <div class="row"><span>内存</span><b>${n.mem_u}/${n.mem_t}</b></div><div class="bar-bg"><div class="bar-fill" style="width:${n.mem_p}%;background:var(--accent)"></div></div>
                <div class="row"><span>硬盘</span><b>${n.disk_u}/${n.disk_t}</b></div><div class="bar-bg"><div class="bar-fill" style="width:${n.disk_p}%;background:var(--orange)"></div></div>
                <div class="row"><span>当前速率</span><b>↓${n.rx} | ↑${n.tx}</b></div>
                <div class="row" style="color:var(--sub);margin-top:-2px"><span>累积流量</span><b>↓${n.t_rx} | ↑${n.t_tx}</b></div>
                ${h_html}
            </div>`;
        });
        app.innerHTML = html + '</div>';
    }
    // 定时刷新，确保节点状态准确
    setInterval(render, 5000);
    connect();
</script></body></html>
EOF

    cat <<EOF > /etc/systemd/system/probe_server.service
[Unit]
Description=Nano Probe Server v1.1
After=network.target
[Service]
ExecStart=/usr/local/bin/probe_venv/bin/python3 /usr/local/bin/probe_server.py
Restart=always
RestartSec=3
User=root
WorkingDirectory=/usr/local/bin
[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload && systemctl enable probe_server && systemctl restart probe_server
    echo -e "${GREEN}✅ 服务端安装完成！端口: ${port}${PLAIN}"
}

# --- 客户端安装 ---
install_client() {
    read -p "服务端 IP: " s_ip
    read -p "服务端端口: " s_port
    read -p "节点名称: " name
    read -p "通信密钥 (Secret): " secret
    read -p "延时检测 (名称,IP|名称2,IP2): " ping_targets
    ping_targets=${ping_targets:-"Google,8.8.8.8"}

    cat <<EOF > /usr/local/bin/probe_client.sh
#!/bin/bash
# Nano Probe Client v1.1
SERVER_URL="http://${s_ip}:${s_port}/report"
SECRET="${secret}"
NAME="${name}"
PING_TARGETS='${ping_targets}'
# 增加上报间隔，每5秒上报一次，降低服务器压力
REPORT_INTERVAL=5

exec 2> /tmp/probe_client.err

get_ip_info() {
    local cache="/tmp/probe_ip.cache"
    if [[ ! -f \$cache ]] || [[ \$(find \$cache -mmin +1440 2>/dev/null) ]]; then
        curl -4 -s --max-time 10 https://ipapi.co/json/ > \$cache 2>/dev/null
    fi
    IP=\$(grep '"ip"' \$cache | cut -d'"' -f4)
    REGION=\$(grep '"country_name"' \$cache | cut -d'"' -f4)
    IP=\${IP:-"0.0.0.0"}
    REGION=\${REGION:-"Unknown"}
}

calc_bytes() {
    local val=\${1:-0}
    awk -v b="\$val" 'BEGIN {
        if(b<1024) printf "%dB", b;
        else if(b<1048576) printf "%.1fK", b/1024;
        else if(b<1073741824) printf "%.1fM", b/1048576;
        else if(b<1099511627776) printf "%.1fG", b/1073741824;
        else printf "%.2fT", b/1099511627776;
    }'
}

# 初始化累计变量
prev_rx=\$(awk 'NR>2 {r+=\$2} END {print (r?r:0)}' /proc/net/dev 2>/dev/null || echo 0)
prev_tx=\$(awk 'NR>2 {t+=\$10} END {print (t?t:0)}' /proc/net/dev 2>/dev/null || echo 0)
prev_time=\$(date +%s%3N)

while true; do
    get_ip_info
    OS=\$(cat /etc/os-release 2>/dev/null | grep "^PRETTY_NAME" | cut -d'"' -f2 | tr -d '"')
    OS=\${OS:-"Linux"}
    
    # 增加: Uptime 采集
    UPTIME=\$(awk '{d=int(\$1/86400); h=int((\$1%86400)/3600); m=int((\$1%3600)/60); if(d>0) printf "%dd %dh", d, h; else if(h>0) printf "%dh %dm", h, m; else printf "%dm", m}' /proc/uptime)
    
    # 修复: UDP连接数统计逻辑
    TCP_CONN=\$(ss -ant | grep -c ESTAB || echo 0)
    UDP_CONN=\$(ss -anu | wc -l || echo 0)
    # 过滤掉ss命令自身的表头，修正UDP连接数
    UDP_CONN=\$((UDP_CONN - 1))
    [ \$UDP_CONN -lt 0 ] && UDP_CONN=0

    # ========== 修复：CPU统计逻辑（兼容所有Linux系统） ==========
    get_cpu_stats() {
        local stats=(\$(grep '^cpu ' /proc/stat))
        # stats[0] = cpu, stats[1]=user, stats[2]=nice, stats[3]=system, stats[4]=idle, stats[5]=iowait
        local user=\${stats[1]}
        local nice=\${stats[2]}
        local system=\${stats[3]}
        local idle=\${stats[4]}
        local iowait=\${stats[5]}
        # 总时间 = user + nice + system + idle + iowait + 其他（irq/sirq/steal等）
        local total=\$((user + nice + system + idle + iowait + \${stats[6]:-0} + \${stats[7]:-0} + \${stats[8]:-0}))
        local idle_total=\$((idle + iowait))
        echo "\$total \$idle_total"
    }

    # 获取第一次CPU状态
    read t1 i1 < <(get_cpu_stats)
    sleep 1
    # 获取第二次CPU状态
    read t2 i2 < <(get_cpu_stats)

    # 计算CPU使用率
    total_delta=\$((t2 - t1))
    idle_delta=\$((i2 - i1))
    cpu_usage=0
    if [ "\$total_delta" -gt 0 ]; then
        cpu_usage=\$(( 100 * (total_delta - idle_delta) / total_delta ))
    fi
    # ========== CPU统计逻辑修复结束 ==========

    mem_t_kb=\$(grep MemTotal /proc/meminfo | awk '{print \$2}' || echo 0)
    mem_a_kb=\$(grep MemAvailable /proc/meminfo | awk '{print \$2}' || echo 0)
    mem_u_kb=\$((mem_t_kb - mem_a_kb))
    [ "\$mem_t_kb" -le 0 ] && mem_p=0 || mem_p=\$((100 * mem_u_kb / mem_t_kb))
    mem_u_fmt=\$(calc_bytes \$((mem_u_kb*1024))); mem_t_fmt=\$(calc_bytes \$((mem_t_kb*1024)))
    
    disk_info=\$(df -k / 2>/dev/null | awk 'NR==2')
    disk_t_kb=\$(echo \$disk_info | awk '{print \$2}' || echo 0)
    disk_u_kb=\$(echo \$disk_info | awk '{print \$3}' || echo 0)
    disk_p=\$(echo \$disk_info | awk '{print \$5}' | tr -d '%' || echo 0)
    disk_u_fmt=\$(calc_bytes \$((disk_u_kb*1024))); disk_t_fmt=\$(calc_bytes \$((disk_t_kb*1024)))
    
    now_time=\$(date +%s%3N)
    curr_rx=\$(awk 'NR>2 {r+=\$2} END {print (r?r:0)}' /proc/net/dev 2>/dev/null || echo 0)
    curr_tx=\$(awk 'NR>2 {t+=\$10} END {print (t?t:0)}' /proc/net/dev 2>/dev/null || echo 0)
    interval=\$((now_time - prev_time))
    
    if [ "\$interval" -le 0 ]; then rx_s=0; tx_s=0; else
        rx_s=\$(( (curr_rx - prev_rx) * 1000 / interval ))
        tx_s=\$(( (curr_tx - prev_tx) * 1000 / interval ))
    fi
    prev_rx=\$curr_rx; prev_tx=\$curr_tx; prev_time=\$now_time
    
    p_json="{"
    IFS='|'
    for pt in \$PING_TARGETS; do
        tn=\$(echo \$pt | cut -d',' -f1); tip=\$(echo \$pt | cut -d',' -f2)
        ms=\$(ping -c 1 -W 1 \$tip 2>/dev/null | grep 'time=' | awk -F'time=' '{print \$2}' | cut -d' ' -f1 || echo 999)
        # 修复ping值格式问题，确保是数字类型
        ms=\$(echo \$ms | awk -F'.' '{print \$1}')
        [ -z "\$ms" ] && ms=999
        p_json+="\"\$pt\":\$ms,"
    done
    p_json="\${p_json%,}}"
    
    JSON=\$(printf '{"name":"%s","os":"%s","ip":"%s","region":"%s","uptime":"%s","tcp":%d,"udp":%d,"cpu":%d,"mem_p":%d,"mem_u":"%s","mem_t":"%s","disk_p":%d,"disk_u":"%s","disk_t":"%s","rx":"%s","tx":"%s","t_rx":"%s","t_tx":"%s","ping":%s}' \
        "\$NAME" "\$OS" "\$IP" "\$REGION" "\$UPTIME" "\$TCP_CONN" "\$UDP_CONN" "\$cpu_usage" "\$mem_p" "\$mem_u_fmt" "\$mem_t_fmt" "\$disk_p" "\$disk_u_fmt" "\$disk_t_fmt" "\$(calc_bytes \$rx_s)" "\$(calc_bytes \$tx_s)" "\$(calc_bytes \$curr_rx)" "\$(calc_bytes \$curr_tx)" "\$p_json")
    
    # 发送上报请求
    curl -s -X POST -H "Content-Type: application/json" -H "Auth: \$SECRET" -d "\$JSON" "\$SERVER_URL" > /dev/null
    
    # 等待上报间隔，降低服务器压力
    sleep \$REPORT_INTERVAL
done
EOF

    chmod +x /usr/local/bin/probe_client.sh
    cat <<EOF > /etc/systemd/system/probe_client.service
[Unit]
Description=Nano Probe Client v1.1
After=network.target
[Service]
ExecStart=/bin/bash /usr/local/bin/probe_client.sh
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload && systemctl enable probe_client && systemctl restart probe_client
    echo -e "${GREEN}✅ 客户端 v1.1 安装完成！${PLAIN}"
}

# --- 主菜单 ---
clear
echo -e "${CYAN}Nano Probe v1.1  ${PLAIN}"
echo "----------------------------------------"
echo "1. 安装/更新 服务端"
echo "2. 安装/更新 客户端"
echo "3. 卸载"
echo "----------------------------------------"
read -p "选择: " choice
case "$choice" in
    1) install_server ;;
    2) install_client ;;
    3) systemctl stop probe_server probe_client 2>/dev/null; rm -rf /usr/local/bin/probe_* /etc/systemd/system/probe_*; echo "已卸载";;
    *) exit 0 ;;
esac
