#!/bin/bash
# ============================================================
#  Scale-Up Scenario  —  Gradual load increase from multiple UEs
#
#  Calibrated bandwidth per UE (measured through GTP-U tunnel):
#    2M  → ~183 KB/s at UPF
#    3M  → ~389 KB/s at UPF
#    5M  → ~649 KB/s at UPF
#    8M  → ~1200 KB/s at UPF
#
#  Phase 0  │  idle              │  0 KB/s    │  1 replica
#  Phase 1  │  2 UEs × 1 Mbit/s  │  ~200 KB/s │  1 replica  (below 500 KB/s)
#  Phase 2  │  2 UEs × 5 Mbit/s  │  ~1300 KB/s│  2 replicas
#  Phase 3  │  3 UEs × 5 Mbit/s  │  ~1950 KB/s│  3 replicas
# ============================================================
set -u

NS=free5gc
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

UE_POD=$(kubectl get pod -n $NS -l component=ue -o jsonpath='{.items[0].metadata.name}')
UPF_POD=$(kubectl get pod -n $NS -l nf=upf -o jsonpath='{.items[0].metadata.name}' | head -1)
IPERF_IP=$(kubectl get pod -n $NS iperf-server -o jsonpath='{.status.podIP}')

# ── Auto-heal: ensure iperf3 installed and GTP sessions alive ─
ensure_iperf3() {
    local pod=$1
    if ! kubectl exec -n $NS "$pod" -- which iperf3 &>/dev/null; then
        echo -e "${YELLOW}  iperf3 missing — installing...${NC}"
        for deb in libiperf0_3.1.3-1_amd64.deb iperf3_3.1.3-1_amd64.deb; do
            [[ ! -f /tmp/$deb ]] && wget -q -P /tmp \
                "http://archive.ubuntu.com/ubuntu/pool/universe/i/iperf3/$deb"
            kubectl cp /tmp/$deb $NS/$pod:/tmp/$deb
        done
        kubectl exec -n $NS "$pod" -- \
            dpkg -i /tmp/libiperf0_3.1.3-1_amd64.deb /tmp/iperf3_3.1.3-1_amd64.deb &>/dev/null
        echo -e "${GREEN}  iperf3 ready${NC}"
    fi
}

heal_gtp() {
    local gtp_ok
    gtp_ok=$(kubectl exec -n $NS "$UE_POD" -- \
        ping -I uesimtun0 -c 3 -W 3 8.8.8.8 2>/dev/null | awk '/received/{print $4}')
    if [[ "${gtp_ok:-0}" -eq 0 ]]; then
        echo -e "${YELLOW}  GTP sessions stale — restarting SMF + UE...${NC}"
        kubectl rollout restart -n $NS deployment/free5gc-free5gc-smf-smf deployment/ueransim-ue &>/dev/null
        kubectl wait --for=condition=ready pod -n $NS -l nf=smf --timeout=60s &>/dev/null
        kubectl wait --for=condition=ready pod -n $NS -l component=ue --timeout=60s &>/dev/null
        UE_POD=$(kubectl get pod -n $NS -l component=ue -o jsonpath='{.items[0].metadata.name}')
        until kubectl exec -n $NS "$UE_POD" -- ip addr show uesimtun0 2>/dev/null | grep -q "inet 10.1"; do sleep 2; done
        echo -e "${GREEN}  GTP sessions restored${NC}"
    fi
}

heal_gtp
ensure_iperf3 "$UE_POD"
# Refresh pod names after potential restart
UE_POD=$(kubectl get pod -n $NS -l component=ue -o jsonpath='{.items[0].metadata.name}')
UPF_POD=$(kubectl get pod -n $NS -l nf=upf -o jsonpath='{.items[0].metadata.name}' | head -1)

# Collect UE IPs
UE_IPS=()
for i in $(seq 0 9); do
    IP=$(kubectl exec -n $NS "$UE_POD" -- ip addr show "uesimtun${i}" 2>/dev/null \
        | awk '/inet 10\.1\./{split($2,a,"/"); print a[1]}')
    [[ -n "$IP" ]] && UE_IPS+=("$IP")
done

# ── Helpers ───────────────────────────────────────────────
metric_kbs() {
    VAL=$(kubectl exec -n $NS "$UPF_POD" -c metrics-exporter -- \
        python3 -c "
import urllib.request
r = urllib.request.urlopen('http://localhost:9090/metrics')
for l in r:
    l = l.decode().strip()
    if 'rx_bytes_per_second' in l and '#' not in l: print(l.split()[-1])
" 2>/dev/null)
    python3 -c "print(f'{float(${VAL:-0})/1000:.0f}')" 2>/dev/null || echo "0"
}

replicas() {
    kubectl get deployment -n $NS free5gc-free5gc-upf-upf \
        -o jsonpath='{.status.readyReplicas}/{.spec.replicas}' 2>/dev/null
}

status_line() {
    printf "  \e[0;36mt=%3ss\e[0m  metric: %6s KB/s  │  UPF: %s replica(s)  │  %s\n" \
        "$1" "$(metric_kbs)" "$(replicas)" "$2"
}

# Track all background traffic PIDs
TRAFFIC_PID=""
SERVER_PIDS=()

cleanup() {
    kubectl exec -n $NS "$UE_POD" -- pkill iperf3 2>/dev/null || true
    [[ -n "${TRAFFIC_PID:-}" ]] && kill "$TRAFFIC_PID" 2>/dev/null || true
    [[ ${#SERVER_PIDS[@]} -gt 0 ]] && kill "${SERVER_PIDS[@]}" 2>/dev/null || true
}
trap cleanup EXIT

# Start persistent iperf3 servers (one per port)
start_servers() {
    kubectl exec -n $NS iperf-server -- sh -c "killall iperf3 2>/dev/null || true"; sleep 1
    for port in 5201 5202 5203 5204; do
        kubectl exec -n $NS iperf-server -- iperf3 -s -p "$port" &>/dev/null &
        SERVER_PIDS+=($!)
    done
    sleep 2
}

# Run N iperf3 clients inside UE pod via single kubectl exec shell
# All clients start/stop atomically — single PID to manage
start_traffic() {
    local NUM=$1 BW=$2
    # Kill any running iperf3 first (clean slate)
    kubectl exec -n $NS "$UE_POD" -- pkill iperf3 2>/dev/null || true
    [[ -n "${TRAFFIC_PID:-}" ]] && kill "$TRAFFIC_PID" 2>/dev/null || true
    sleep 2
    # Build sh -c command: all iperf3 clients backgrounded + wait
    local CMD=""
    for i in $(seq 0 $((NUM - 1))); do
        local IP="${UE_IPS[$i]:-}"; local PORT=$((5201 + i))
        [[ -z "$IP" ]] && continue
        CMD="${CMD}iperf3 -c $IPERF_IP -p $PORT -B $IP -b ${BW}M -t 86400 >/dev/null 2>&1 & "
    done
    CMD="${CMD}wait"
    # Single kubectl exec holds all clients — kill this PID to stop all
    kubectl exec -n $NS "$UE_POD" -- sh -c "$CMD" &
    TRAFFIC_PID=$!
}

stop_traffic() {
    kubectl exec -n $NS "$UE_POD" -- pkill iperf3 2>/dev/null || true
    [[ -n "${TRAFFIC_PID:-}" ]] && kill "$TRAFFIC_PID" 2>/dev/null || true
    TRAFFIC_PID=""
    sleep 3
}

# ── Header ────────────────────────────────────────────────
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║     Scale-Up Scenario  —  free5GC UPF    ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════╝${NC}"
echo ""
echo -e "  iperf server : $IPERF_IP"
echo -e "  UE tunnels   : ${#UE_IPS[@]} active (${UE_IPS[*]})"
echo -e "  threshold    : 500 KB/s per replica"
echo ""
echo -e "  ${YELLOW}Grafana:${NC} http://$(minikube ip):30300/d/upf-autoscale?refresh=5s"
echo ""

# Ensure baseline and start servers
kubectl scale deployment -n $NS free5gc-free5gc-upf-upf --replicas=1 &>/dev/null
start_servers

# ── Phase 0: Idle baseline ────────────────────────────────
echo -e "${BOLD}▶ Phase 0  │  Idle (no traffic)${NC}"
echo -e "  expected: 1 replica  │  metric: 0 KB/s"
for t in 5 10 15; do sleep 5; status_line $t "idle"; done
echo ""

# ── Phase 1: 2 UEs × 2 Mbit/s ≈ 366 KB/s ────────────────
echo -e "${BOLD}▶ Phase 1  │  2 UEs × 1 Mbit/s  →  ~200 KB/s${NC}"
echo -e "  expected: stays at 1 replica  (below 500 KB/s threshold)"
start_traffic 2 1
for t in 5 10 15 20 25 30; do sleep 5; status_line $t "2 UEs @ 1M"; done
echo ""

# ── Phase 2: 2 UEs × 5 Mbit/s ≈ 1300 KB/s ───────────────
echo -e "${BOLD}▶ Phase 2  │  2 UEs × 5 Mbit/s  →  ~1300 KB/s${NC}"
echo -e "  expected: scale to 2 replicas"
start_traffic 2 5
for t in 5 10 15 20 25 30 35 40; do sleep 5; status_line $t "2 UEs @ 5M"; done
echo ""

# ── Phase 3: 4 UEs × 5 Mbit/s ───────────────────────────
echo -e "${BOLD}▶ Phase 3  │  4 UEs × 5 Mbit/s  →  ~2600 KB/s${NC}"
echo -e "  expected: scale to 3 replicas"
# Start new traffic BEFORE stopping old — avoids metric gap and spurious scale-down
start_traffic 4 5
for t in 5 10 15 20 25 30 35 40; do sleep 5; status_line $t "4 UEs @ 5M"; done
echo ""

# ── Final state ──────────────────────────────────────────
stop_traffic
echo -e "${BOLD}══ Scale-Up Complete ══════════════════════${NC}"
echo -e "  Final replicas : $(replicas)"
echo -e "  Final metric   : $(metric_kbs) KB/s"
for p in $(kubectl get pods -n $NS -l nf=upf --no-headers 2>/dev/null | awk '{print $1}'); do
    N4=$(kubectl exec -n $NS "$p" -c upf -- ip -4 addr show n4 2>/dev/null \
        | awk '/inet /{split($2,a,"/"); print a[1]}')
    echo -e "    ${GREEN}✔${NC}  $p  N4: $N4"
done
echo ""
echo -e "  ${YELLOW}Run scale-down.sh to return to 1 replica${NC}"
echo ""
