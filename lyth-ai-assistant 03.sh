#!/usr/bin/env bash
set -e

echo "==========================================================="
echo " Lyth AI Interface Setup Configuration"
echo "==========================================================="
read -p "Enter Target LXC ID (e.g., 300): " CTID
read -p "Enter Network Bridge (e.g., vmbr0): " NETWORK_BRIDGE
read -p "Enter Network IP (must include CIDR, e.g., dhcp or 192.168.1.100/24): " NETWORK_IP

if [[ "${NETWORK_IP,,}" != "dhcp" ]]; then
    read -p "Enter Default Gateway (e.g., 192.168.1.1): " NETWORK_GW
fi

read -p "Enter your Gemini API Key: " GEMINI_API_KEY
echo "==========================================================="

NET_CONFIG="name=eth0,bridge=${NETWORK_BRIDGE},ip=${NETWORK_IP}"
if [[ "${NETWORK_IP,,}" != "dhcp" ]]; then
    if [ -n "$NETWORK_GW" ]; then
        NET_CONFIG="name=eth0,bridge=${NETWORK_BRIDGE},ip=${NETWORK_IP},gw=${NETWORK_GW}"
    fi
fi

# Safe Storage Detection (Pipe-free)
pvesm status > /tmp/pve_status.txt
if grep -qw "local-lvm" /tmp/pve_status.txt; then
    STORAGE_POOL="local-lvm"
elif grep -qw "local-zfs" /tmp/pve_status.txt; then
    STORAGE_POOL="local-zfs"
else
    STORAGE_POOL="local"
fi

# Safe IP Detection (Pipe-free)
ip -4 route get 8.8.8.8 > /tmp/ip_route.txt
HOST_IP=$(grep -oP 'src \K\S+' /tmp/ip_route.txt)
MODEL_URL="https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/qwen2.5-0.5b-instruct-q4_k_m.gguf"

echo " Deploying Lyth AI Interface & Metrics to Proxmox"
echo " Host IP Detected: $HOST_IP"
echo " Target LXC ID: $CTID"
echo " Auto-Selected Storage: $STORAGE_POOL"
echo "==========================================================="

# ---------------------------------------------------------
# 1. HOST ENVIRONMENT SETUP (ai-metrics)
# ---------------------------------------------------------
echo -e "\n[1/6] Installing Host Dependencies & Setting up Metrics API..."
apt-get update && apt-get install -y lm-sensors smartmontools curl jq python3

mkdir -p /opt/ai-metrics
cat << 'EOF' > /opt/ai-metrics/server.py
#!/usr/bin/env python3
from http.server import BaseHTTPRequestHandler, HTTPServer
import json, subprocess, time, socket

HOST = "0.0.0.0"
PORT = 8090

def read_cpu():
    with open("/proc/stat") as f: line = f.readline()
    values = list(map(int, line.split()[1:]))
    idle = values[3] + values[4]
    return idle, sum(values)

def get_cpu_usage():
    idle1, total1 = read_cpu()
    time.sleep(0.25)
    idle2, total2 = read_cpu()
    if total2 - total1 == 0: return 0.0
    return round(100 * (1 - (idle2 - idle1) / (total2 - total1)), 1)

def get_memory():
    values = {}
    with open("/proc/meminfo") as f:
        for line in f:
            parts = line.split()
            if len(parts) >= 2: values[parts[0].rstrip(":")] = int(parts[1])
    total = values.get("MemTotal", 0)
    available = values.get("MemAvailable", 0)
    used = total - available
    return {
        "total_gb": round(total / 1024 / 1024, 2),
        "used_gb": round(used / 1024 / 1024, 2),
        "available_gb": round(available / 1024 / 1024, 2),
        "usage_percent": round((used / total) * 100, 1) if total else 0
    }

def get_disk():
    try:
        r = subprocess.run(["df", "-h", "/"], capture_output=True, text=True, timeout=5)
        parts = r.stdout.strip().splitlines()[-1].split()
        return {"filesystem": parts[0], "size": parts[1], "used": parts[2], "available": parts[3], "usage_percent": parts[4]}
    except Exception as e: return {"error": str(e)}

def get_uptime():
    with open("/proc/uptime") as f: seconds = float(f.read().split()[0])
    return {"seconds": int(seconds), "days": int(seconds // 86400), "hours": int((seconds % 86400) // 3600), "minutes": int((seconds % 3600) // 60)}

def get_network():
    r = subprocess.run(["bash", "-c", "ip -4 -br addr"], capture_output=True, text=True, timeout=5)
    return {"hostname": socket.gethostname(), "interfaces": r.stdout.strip()}

def get_temperature():
    try:
        r = subprocess.run(["sensors", "coretemp-isa-0000"], capture_output=True, text=True, timeout=5)
        if r.returncode != 0: return "Temperature unavailable"
        return r.stdout.strip()
    except Exception as e: return f"Temperature unavailable: {e}"

def get_lxc_ports():
    try:
        with open("/root/lxc-reports/lxc_ports.md", "r") as f: return f.read().strip()
    except Exception as e: return f"LXC port report unavailable: {e}"

def get_all():
    return {"hostname": socket.gethostname(), "cpu": {"usage_percent": get_cpu_usage()}, "memory": get_memory(), "disk": get_disk(), "uptime": get_uptime(), "network": get_network(), "temperature": get_temperature(), "lxc_ports": get_lxc_ports()}

class Handler(BaseHTTPRequestHandler):
    def log_message(self, format, *args): return
    def do_GET(self):
        if self.path == "/health": response = {"status": "ok"}
        elif self.path == "/metrics": response = get_all()
        else:
            self.send_response(404); self.end_headers(); return
        data = json.dumps(response).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

server = HTTPServer((HOST, PORT), Handler)
print(f"AI metrics server listening on {HOST}:{PORT}")
server.serve_forever()
EOF

chmod +x /opt/ai-metrics/server.py

cat << 'EOF' > /etc/systemd/system/ai-metrics.service
[Unit]
Description=Proxmox Host Metrics API
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /opt/ai-metrics/server.py
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now ai-metrics
echo "Host Metrics API running on Port 8090."

# ---------------------------------------------------------
# 2. LXC PROVISIONING
# ---------------------------------------------------------
echo -e "\n[2/6] Checking for existing LXC $CTID..."
if ! pct status "$CTID" >/dev/null 2>&1; then
    echo "Creating LXC $CTID (Debian 12) on storage pool: $STORAGE_POOL..."
    pveam update >/dev/null
    
    pveam available -section system > /tmp/pveam1.txt
    grep debian-12 /tmp/pveam1.txt > /tmp/pveam2.txt
    head -n 1 /tmp/pveam2.txt > /tmp/pveam3.txt
    tr -s ' ' < /tmp/pveam3.txt > /tmp/pveam4.txt
    TEMPLATE=$(cut -d' ' -f2 /tmp/pveam4.txt)
    pveam download local "$TEMPLATE" >/dev/null
    
    pct create "$CTID" "local:vztmpl/$TEMPLATE" \
        --rootfs "${STORAGE_POOL}:4" \
        --hostname "lyth-ai-interface" \
        --cores 4 \
        --memory 4096 \
        --net0 "$NET_CONFIG" \
        --unprivileged 1
        
    pct start "$CTID"
    echo "Waiting for container network to initialize..."
    sleep 15
else
    echo "LXC $CTID already exists. Reusing it."
    set +e
    pct start "$CTID" >/dev/null 2>&1
    set -e
    sleep 5
fi

# ---------------------------------------------------------
# 3. INSTALL LXC DEPENDENCIES & LLAMA.CPP
# ---------------------------------------------------------
echo -e "\n[3/6] Installing dependencies inside LXC $CTID..."
pct exec "$CTID" -- apt-get update
pct exec "$CTID" -- apt-get install -y python3 python3-flask python3-requests curl git build-essential cmake

echo -e "\n[4/6] Setting up llama.cpp & Downloading Qwen Model..."
pct exec "$CTID" -- bash -c "if [ ! -d '/opt/llama.cpp' ]; then git clone https://github.com/ggerganov/llama.cpp /opt/llama.cpp; fi"
pct exec "$CTID" -- bash -c "cd /opt/llama.cpp && cmake -B build && cmake --build build --config Release -j 4"

pct exec "$CTID" -- mkdir -p /opt/models
echo "Downloading Qwen 0.5B (this might take a minute)..."
pct exec "$CTID" -- curl -L -o /opt/models/qwen2.5-0.5b-instruct-q4_k_m.gguf "$MODEL_URL"

cat << 'EOF' > /tmp/llama.service
[Unit]
Description=Qwen 0.5B LLM Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=/opt/llama.cpp
ExecStart=/opt/llama.cpp/build/bin/llama-server -m /opt/models/qwen2.5-0.5b-instruct-q4_k_m.gguf -c 2048 -t 6 --host 0.0.0.0 --port 8080
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
pct push "$CTID" /tmp/llama.service /etc/systemd/system/llama.service

# ---------------------------------------------------------
# 4. INSTALL LYTH AI INTERFACE (Flask App with Gemini 3.5 Flash-Lite)
# ---------------------------------------------------------
echo -e "\n[5/6] Configuring Lyth AI Interface UI..."
pct exec "$CTID" -- mkdir -p /opt/ai-tools

cat << 'EOF' > /tmp/assistant.py
#!/usr/bin/env python3
from flask import Flask, request, jsonify, Response
import requests
import json

app = Flask(__name__)

GEMINI_URL = "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions"
GEMINI_API_KEY = "REPLACE_ME_API_KEY"
METRICS_URL = "http://REPLACE_ME_HOST_IP:8090/metrics"

def get_metrics():
    try:
        r = requests.get(METRICS_URL, timeout=5)
        r.raise_for_status()
        return r.json()
    except Exception as e:
        return {"error": str(e)}

def detect_tool(message):
    text = message.lower()
    if any(x in text for x in ["lxc info", "lxc ports", "container ports", "show me lxc ports", "show me lxc info", "what ports are open", "lxc port list", "container info"]): return "lxc_ports"
    if any(x in text for x in ["cpu temperature", "cpu temp", "cpu temps", "core temp", "core temps", "core temperature", "core temperatures", "how hot is the cpu", "how hot is my cpu", "processor temperature", "processor temp"]): return "temperature"
    if any(x in text for x in ["cpu usage", "cpu utilisation", "cpu utilization", "cpu load", "how hard is the cpu working", "how hard is my cpu working", "processor usage"]): return "cpu"
    if any(x in text for x in ["ram usage", "memory usage", "memory utilisation", "memory utilization", "how much ram", "how much memory", "ram am i using", "memory am i using"]): return "memory"
    if any(x in text for x in ["disk usage", "disk space", "storage space", "storage left", "disk space left", "how much storage", "how much disk"]): return "disk"
    if any(x in text for x in ["uptime", "how long has the server been up", "how long has the server been running", "how long has proxmox been running"]): return "uptime"
    if any(x in text for x in ["my ip", "ip address", "what is my ip", "what's my ip", "network interfaces", "network interface", "what interfaces are up", "what network interfaces are up"]): return "network"
    return None

@app.route("/health")
def health(): return jsonify({"status": "ok"})

@app.route("/v1/chat/completions", methods=["POST"])
def chat_completions():
    data = request.get_json(force=True)
    messages = data.get("messages", [])
    if not messages: return jsonify({"error": "No messages supplied"}), 400
    
    last_user_message = next((msg.get("content", "") for msg in reversed(messages) if msg.get("role") == "user"), "")
    tool = detect_tool(last_user_message)

    if tool:
        metrics = get_metrics()
        if "error" in metrics: return jsonify({"choices": [{"message": {"role": "assistant", "content": "Live Proxmox host metrics are unavailable: " + metrics["error"]}}]})
        
        if tool == "lxc_ports": reply = f"Here is the latest LXC port & network inventory:\n\n{metrics.get('lxc_ports', 'LXC port report unavailable.')}"
        elif tool == "cpu": reply = f"Proxmox host CPU usage is currently {metrics['cpu']['usage_percent']}%."
        elif tool == "memory": reply = f"Proxmox host RAM usage is {metrics['memory']['used_gb']} GB of {metrics['memory']['total_gb']} GB ({metrics['memory']['usage_percent']}%). {metrics['memory']['available_gb']} GB is available."
        elif tool == "temperature": reply = "Proxmox host CPU temperatures:\n" + metrics.get("temperature", "Temperature unavailable")
        elif tool == "disk": reply = f"Proxmox host root disk usage is {metrics['disk']['used']} of {metrics['disk']['size']} ({metrics['disk']['usage_percent']}). {metrics['disk']['available']} is available."
        elif tool == "uptime": reply = f"Proxmox host uptime is {metrics['uptime']['days']} days, {metrics['uptime']['hours']} hours, and {metrics['uptime']['minutes']} minutes."
        elif tool == "network": reply = f"Proxmox host: {metrics['network']['hostname']}\nNetwork interfaces:\n{metrics['network']['interfaces']}"
        else: reply = f"Live Proxmox host metric unavailable."
        
        return jsonify({"choices": [{"finish_reason": "stop", "index": 0, "message": {"role": "assistant", "content": reply}}], "object": "chat.completion", "model": "proxmox-metrics"})

    try:
        data["model"] = "gemini-3.5-flash-lite"
        headers = { "Authorization": f"Bearer {GEMINI_API_KEY}", "Content-Type": "application/json" }
        response = requests.post(GEMINI_URL, headers=headers, json=data, timeout=10) 
        
        if response.status_code != 200:
            raise Exception(f"Google API HTTP {response.status_code}: {response.text}")
            
        return Response(response.content, status=response.status_code, content_type=response.headers.get("Content-Type", "application/json"))
        
    except Exception as gemini_err:
        try:
            local_url = "http://127.0.0.1:8080/v1/chat/completions"
            data["model"] = "qwen2.5-0.5b-instruct"
            local_response = requests.post(local_url, json=data, timeout=120)
            
            if local_response.status_code != 200:
                raise Exception(f"Local API HTTP {local_response.status_code}")
                
            return Response(local_response.content, status=local_response.status_code, content_type=local_response.headers.get("Content-Type", "application/json"))
            
        except Exception as local_err:
            error_msg = f"**System Failure:**\n1. Gemini failed: {str(gemini_err)}\n2. Local Fallback failed: {str(local_err)}"
            return jsonify({"choices": [{"message": {"role": "assistant", "content": error_msg}}]})

@app.route("/")
def index():
    return r"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
<title>Lyth AI Interface Control Center</title>
<style>
  :root { --bg-main: #0f172a; --bg-card: #1e293b; --bg-bubble-user: #2563eb; --bg-bubble-ai: #334155; --text-main: #f8fafc; --text-muted: #94a3b8; --accent: #38bdf8; --border: #475569; }
  * { box-sizing: border-box; margin: 0; padding: 0; }
  html, body { height: 100%; height: 100dvh; background-color: var(--bg-main); color: var(--text-main); font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif; overflow: hidden; }
  body { display: flex; flex-direction: column; }
  header { background-color: var(--bg-card); padding: 0.875rem 1.25rem; border-bottom: 1px solid var(--border); display: flex; justify-content: space-between; align-items: center; flex-shrink: 0; }
  .brand h1 { font-size: 1rem; font-weight: 600; color: var(--text-main); }
  .status-badge { display: inline-flex; align-items: center; gap: 0.375rem; padding: 0.2rem 0.5rem; border-radius: 9999px; font-size: 0.7rem; background-color: rgba(16, 185, 129, 0.1); color: #34d399; border: 1px solid rgba(16, 185, 129, 0.2); }
  .dot { width: 6px; height: 6px; border-radius: 50%; background-color: #34d399; }
  main { flex: 1; overflow-y: auto; padding: 1rem; display: flex; flex-direction: column; gap: 1rem; width: 100%; max-width: 1000px; margin: 0 auto; padding-bottom: 130px; }
  .message-wrapper { display: flex; flex-direction: column; max-width: 95%; }
  .message-wrapper.user { align-self: flex-end; }
  .message-wrapper.assistant { align-self: flex-start; width: 100%; }
  .meta { font-size: 0.7rem; color: var(--text-muted); margin-bottom: 0.2rem; padding: 0 0.25rem; }
  .user .meta { text-align: right; }
  .bubble { padding: 0.75rem 1rem; border-radius: 12px; font-size: 0.9rem; line-height: 1.5; word-break: break-word; width: 100%; }
  .user .bubble { background-color: var(--bg-bubble-user); color: #ffffff; border-bottom-right-radius: 2px; width: fit-content; max-width: 100%; }
  .assistant .bubble { background-color: var(--bg-bubble-ai); color: var(--text-main); border-bottom-left-radius: 2px; }
  .table-container { width: 100%; overflow-x: auto; -webkit-overflow-scrolling: touch; margin: 0.5rem 0; border: 1px solid var(--border); border-radius: 6px; }
  .assistant table { border-collapse: collapse; width: 100%; min-width: 500px; font-size: 0.8rem; background-color: #0f172a; }
  .assistant th, .assistant td { border: 1px solid var(--border); padding: 0.5rem 0.625rem; text-align: left; white-space: nowrap; }
  .assistant th { background-color: #1e293b; color: var(--accent); font-weight: 600; }
  footer { position: fixed; bottom: 0; left: 0; right: 0; background-color: var(--bg-card); padding: 0.75rem 1rem; border-top: 1px solid var(--border); z-index: 100; }
  .footer-content { max-width: 1000px; margin: 0 auto; display: flex; flex-direction: column; gap: 0.5rem; }
  .quick-buttons { display: flex; gap: 0.4rem; overflow-x: auto; padding-bottom: 0.2rem; white-space: nowrap; -webkit-overflow-scrolling: touch; }
  .quick-buttons::-webkit-scrollbar { display: none; }
  .quick-btn { background-color: #334155; color: var(--accent); border: 1px solid var(--border); border-radius: 6px; padding: 0.35rem 0.65rem; font-size: 0.75rem; cursor: pointer; flex-shrink: 0; transition: background 0.2s; }
  .quick-btn:hover { background-color: #475569; }
  .input-container { display: flex; gap: 0.5rem; }
  input { flex: 1; background-color: var(--bg-main); border: 1px solid var(--border); border-radius: 8px; padding: 0.625rem 0.875rem; color: var(--text-main); font-size: 0.9rem; outline: none; }
  button.send-btn { background-color: var(--bg-bubble-user); color: white; border: none; border-radius: 8px; padding: 0.625rem 1.25rem; font-weight: 600; font-size: 0.9rem; cursor: pointer; flex-shrink: 0; }
</style>
</head>
<body>
<header>
  <div class="brand"><h1>Lyth AI Interface (Gemini)</h1></div>
  <div class="status-badge"><span class="dot"></span> Online (LXC)</div>
</header>
<main id="chat"></main>
<footer>
  <div class="footer-content">
    <div class="quick-buttons">
      <button class="quick-btn" onclick="sendQuick('CPU usage')">⚡ CPU</button>
      <button class="quick-btn" onclick="sendQuick('Memory usage')">💾 RAM</button>
      <button class="quick-btn" onclick="sendQuick('Disk usage')">💽 Disk</button>
      <button class="quick-btn" onclick="sendQuick('CPU temperature')">🌡️ Temp</button>
      <button class="quick-btn" onclick="sendQuick('Server uptime')">⏱️ Uptime</button>
      <button class="quick-btn" onclick="sendQuick('Network interfaces')">🌐 Network</button>
      <button class="quick-btn" onclick="sendQuick('LXC ports')">🔌 LXC Ports</button>
    </div>
    <div class="input-container">
      <input id="input" type="text" placeholder="Ask a question..." onkeydown="if(event.key==='Enter') sendMessage()">
      <button class="send-btn" onclick="sendMessage()">Send</button>
    </div>
  </div>
</footer>
<script>
const messages = [];
function escapeHtml(text) { return text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;"); }
function renderMarkdown(text) {
    let lines = text.split("\n"); let inTable = false; let html = "";
    let safePipe = String.fromCharCode(124);
    for (let line of lines) {
        let trimmed = line.trim();
        if (trimmed.startsWith(safePipe)) {
            if (trimmed.includes("---")) continue;
            let cells = trimmed.split(safePipe).filter((c, i, a) => i > 0 && i < a.length - 1);
            let tag = !inTable ? "th" : "td";
            if (!inTable) { html += '<div class="table-container"><table>'; inTable = true; }
            html += "<tr>" + cells.map(c => "<" + tag + ">" + escapeHtml(c.trim()) + "</" + tag + ">").join("") + "</tr>";
        } else {
            if (inTable) { html += "</table></div>"; inTable = false; }
            let formatted = escapeHtml(trimmed).replace(/\*\*(.*?)\*\*/g, '<strong>$1</strong>').replace(/`([^`]+)`/g, '<code>$1</code>');
            html += (formatted ? formatted : "<br>") + "<br>";
        }
    }
    if (inTable) html += "</table></div>"; return html;
}
function addMessage(role, text) {
    const chat = document.getElementById("chat");
    const wrapper = document.createElement("div"); wrapper.className = "message-wrapper " + role;
    const meta = document.createElement("div"); meta.className = "meta"; meta.innerText = role === "user" ? "You" : "Assistant";
    const bubble = document.createElement("div"); bubble.className = "bubble"; bubble.innerHTML = renderMarkdown(text);
    wrapper.appendChild(meta); wrapper.appendChild(bubble); chat.appendChild(wrapper); chat.scrollTop = chat.scrollHeight;
}
function sendQuick(text) {
    document.getElementById("input").value = text;
    sendMessage();
}
async function sendMessage() {
    const input = document.getElementById("input"); const text = input.value.trim(); if (!text) return;
    input.value = ""; messages.push({ role: "user", content: text }); addMessage("user", text);
    try {
        const response = await fetch("/v1/chat/completions", {
            method: "POST", headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ model: "gemini-3.5-flash-lite", messages: messages, temperature: 0.7, max_tokens: 512 })
        });
        const data = await response.json(); 
        if (data.choices && data.choices.length > 0) {
            const reply = data.choices[0].message.content;
            messages.push({ role: "assistant", content: reply }); addMessage("assistant", reply);
        } else if (data.error) {
            addMessage("assistant", "API Error: " + JSON.stringify(data.error));
        } else {
            addMessage("assistant", "Unknown response from server.");
        }
    } catch (error) { addMessage("assistant", "Error communicating with the AI server: " + error); }
}
</script>
</body>
</html>"""

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8081)
EOF

sed -i "s/REPLACE_ME_API_KEY/$GEMINI_API_KEY/g" /tmp/assistant.py
sed -i "s/REPLACE_ME_HOST_IP/$HOST_IP/g" /tmp/assistant.py
pct push "$CTID" /tmp/assistant.py /opt/ai-tools/assistant.py
pct exec "$CTID" -- chmod +x /opt/ai-tools/assistant.py

cat << 'EOF' > /tmp/ai-assistant.service
[Unit]
Description=AI Assistant Tool Bridge
After=network-online.target llama.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /opt/ai-tools/assistant.py
WorkingDirectory=/opt/ai-tools
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
pct push "$CTID" /tmp/ai-assistant.service /etc/systemd/system/ai-assistant.service

# ---------------------------------------------------------
# 5. START LXC SERVICES
# ---------------------------------------------------------
echo -e "\n[6/6] Starting LXC Services..."
pct exec "$CTID" -- systemctl daemon-reload
pct exec "$CTID" -- systemctl enable --now llama ai-assistant

pct exec "$CTID" -- ip -4 addr show eth0 > /tmp/lxc_ip_info.txt
LXC_IP=$(grep -oP '(?<=inet\s)\d+(\.\d+){3}' /tmp/lxc_ip_info.txt)

echo "==========================================================="
echo " INSTALLATION COMPLETE!"
echo "==========================================================="
echo "Host Metrics API:       http://$HOST_IP:8090/metrics"
echo "Llama Server API:       http://$LXC_IP:8080 (Running as Backup)"
echo "Lyth AI Interface:      http://$LXC_IP:8081 (Powered by Gemini 3.5 Flash-Lite)"
echo "==========================================================="