#!/bin/bash
# ============================================================
#  Scale-Up Scenario  —  Gradual load, all UEs simultaneously
#
#  KEDA: sum(upf_gtpu_rx_bytes_per_second), threshold 500 KB/s
#  desired replicas = ceil(total / 500 000)
#
#  Calibrated (per UE through GTP-U):
#    1M → ~100 KB/s     5M → ~649 KB/s
#
#  Phase 0  │  idle                    │    0 KB/s │  1 replica
#  Phase 1  │  2 UEs  × 1 Mbit/s      │  ~200 KB/s│  1 replica (below threshold)
#  Phase 2  │  2 UEs  × 5 Mbit/s      │ ~1300 KB/s│  2–3 replicas
#  Phase 3  │  all UEs × 5 Mbit/s     │  max load │  3 replicas (max)
# ============================================================
set -u

NS=free5gc
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BOLD='\033[1m'; NC='\033[0m'

UE_POD=$(kubectl get pod -n $NS -l component=ue -o jsonpath='{.items[0].metadata.name}')
UPF_POD=$(kubectl get pod -n $NS -l nf=upf -o jsonpath='{.items[0].metadata.name}' | head -1)
IPERF_IP=$(kubectl get pod -n $NS iperf-server -o jsonpath='{.status.podIP}')

# ── Auto-heal ─────────────────────────────────────────────
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
        echo -e "${GREEN}  iperf3 installed${NC}"
    fi
}

heal_gtp() {
    local gtp_ok
    gtp_ok=$(kubectl exec -n $NS "$UE_POD" -- \
        ping -I uesimtun0 -c 3 -W 3 8.8.8.8 2>/dev/null | awk '/received/{print $4}')
    if [[ "${gtp_ok:-0}" -eq 0 ]]; then
        echo -e "${YELLOW}  GTP sessions stale — restarting SMF + UE...${NC}"
        kubectl rollout restart -n $NS \
            deployment/free5gc-free5gc-smf-smf deployment/ueransim-ue &>/dev/null
        kubectl wait --for=condition=ready pod -n $NS -l nf=smf --timeout=60s &>/dev/null
        kubectl wait --for=condition=ready pod -n $NS -l component=ue --timeout=60s &>/dev/null
        UE_POD=$(kubectl get pod -n $NS -l component=ue \
            -o jsonpath='{.items[0].metadata.name}')
        until kubectl exec -n $NS "$UE_POD" -- \
            ip addr show uesimtun0 2>/dev/null | grep -q "inet 10.1"; do sleep 2; done
        echo -e "${GREEN}  GTP sessions restored${NC}"
    fi
}

heal_gtp
ensure_iperf3 "$UE_POD"

UE_POD=$(kubectl get pod -n $NS -l component=ue -o jsonpath='{.items[0].metadata.name}')
UPF_POD=$(kubectl get pod -n $NS -l nf=upf -o jsonpath='{.items[0].metadata.name}' | head -1)

# Collect all available UE IPs
UE_IPS=()
for i in $(seq 0 9); do
    IP=$(kubectl exec -n $NS "$UE_POD" -- \
        ip addr show "uesimtun${i}" 2>/dev/null \
        | awk '/inet 10\.1\./{split($2,a,"/"); print a[1]}')
    [[ -n "$IP" ]] && UE_IPS+=("$IP")
done
NUM_UES=${#UE_IPS[@]}

# ── Helpers ───────────────────────────────────────────────
metric_kbs() {
    local VAL
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

ready_count() {
    kubectl get deployment -n $NS free5gc-free5gc-upf-upf \
        -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0"
}

status_line() {
    printf "  \e[0;36mt=%3ss\e[0m  metric: %6s KB/s  │  UPF: %s replica(s)  │  %s\n" \
        "$1" "$(metric_kbs)" "$(replicas)" "$2"
}

wait_for_replicas() {
    local target=$1
    local timeout=180 elapsed=0
    echo -n "  waiting for KEDA to reach $target replica(s)"
    while [[ $elapsed -lt $timeout ]]; do
        local r; r=$(ready_count)
        if [[ "${r:-0}" -ge "$target" ]]; then
            echo -e "  ${GREEN}✔ $r replicas at t=${elapsed}s${NC}"
            return 0
        fi
        echo -n "."
        sleep 5; elapsed=$((elapsed + 5))
    done
    echo -e "  ${YELLOW}timeout${NC}"
}

TRAFFIC_PID=""

cleanup() {
    kubectl exec -n $NS "$UE_POD" -- pkill iperf3 2>/dev/null || true
    [[ -n "${TRAFFIC_PID:-}" ]] && kill "$TRAFFIC_PID" 2>/dev/null || true
}
trap cleanup EXIT

# ── Server management ─────────────────────────────────────
kill_servers() {
    kubectl exec -n $NS iperf-server -- sh -c '
        for pid in $(ls /proc | grep -E "^[0-9]+$"); do
            cmd=$(cat /proc/$pid/cmdline 2>/dev/null | tr "\0" " ")
            echo "$cmd" | grep -q "iperf3" && kill $pid 2>/dev/null || true
        done' 2>/dev/null || true
    sleep 2
}

# Start daemon servers for ports 5201..5200+NUM, verify each is listening
start_servers() {
    local NUM=$1
    kill_servers
    local ok=0
    for i in $(seq 1 "$NUM"); do
        local port=$((5200 + i))
        for attempt in 1 2 3 4 5; do
            kubectl exec -n $NS iperf-server -- \
                iperf3 -s -p "$port" -D &>/dev/null || true
            sleep 1
            if kubectl exec -n $NS iperf-server -- \
                sh -c "ss -tlnp 2>/dev/null | grep -q ':${port}'" 2>/dev/null; then
                ok=$((ok + 1)); break
            fi
        done
    done
    echo -e "  iperf3 servers ready: ${ok}/${NUM} ports listening"
    LIVE_SERVERS=$ok
}

# ── Traffic control ───────────────────────────────────────
# start_traffic NUM_UES BW_MBIT
# Starts NUM_UES iperf3 clients simultaneously inside the UE pod,
# each bound to its own UE tunnel IP and connecting to its own port.
start_traffic() {
    local NUM=$1 BW=$2
    # Stop previous clients cleanly
    kubectl exec -n $NS "$UE_POD" -- pkill iperf3 2>/dev/null || true
    [[ -n "${TRAFFIC_PID:-}" ]] && kill "$TRAFFIC_PID" 2>/dev/null || true
    sleep 2

    local CMD=""
    local started=0
    for i in $(seq 0 $((NUM - 1))); do
        local IP="${UE_IPS[$i]:-}"
        local PORT=$((5201 + i))
        [[ -z "$IP" ]] && continue
        CMD="${CMD}iperf3 -c $IPERF_IP -p $PORT -B $IP -b ${BW}M -t 86400 \
>/dev/null 2>&1 & "
        started=$((started + 1))
    done
    [[ $started -eq 0 ]] && { echo -e "${RED}  no UE IPs — skipping${NC}"; return; }
    CMD="${CMD}wait"

    # Single exec holds all clients — one PID to kill them all
    kubectl exec -n $NS "$UE_POD" -- sh -c "$CMD" &
    TRAFFIC_PID=$!
    echo -e "  started ${started} iperf3 client(s) simultaneously"
}

stop_traffic() {
    kubectl exec -n $NS "$UE_POD" -- pkill iperf3 2>/dev/null || true
    [[ -n "${TRAFFIC_PID:-}" ]] && kill "$TRAFFIC_PID" 2>/dev/null || true
    TRAFFIC_PID=""
    sleep 3
}

LIVE_SERVERS=0

# ── Header ────────────────────────────────────────────────
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║     Scale-Up Scenario  —  free5GC UPF    ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════╝${NC}"
echo ""
echo -e "  iperf server : $IPERF_IP"
echo -e "  UE tunnels   : ${NUM_UES} active  (${UE_IPS[*]})"
echo -e "  threshold    : 500 KB/s  →  ceil(total/500) replicas"
echo ""
echo -e "  ${YELLOW}Grafana:${NC} http://$(minikube ip):30300/d/upf-autoscale?refresh=5s"
echo ""

kubectl scale deployment -n $NS free5gc-free5gc-upf-upf --replicas=1 &>/dev/null
sleep 3

# ── Phase 0: Idle ─────────────────────────────────────────
echo -e "${BOLD}▶ Phase 0  │  Idle${NC}"
echo -e "  starting servers for all ${NUM_UES} UEs..."
start_servers "$NUM_UES"
echo -e "  expected: 1 replica, 0 KB/s"
for t in 5 10 15; do sleep 5; status_line $t "idle"; done
echo ""

# ── Phase 1: 2 UEs × 1M — stay below threshold ───────────
echo -e "${BOLD}▶ Phase 1  │  2 UEs × 1 Mbit/s  →  ~200 KB/s${NC}"
echo -e "  expected: 1 replica  (below 500 KB/s)"
start_traffic 2 1
for t in 5 10 15 20 25 30; do sleep 5; status_line $t "2 UEs @ 1M"; done
echo ""

# ── Phase 2: 2 UEs × 5M — trigger 2-3 replicas ───────────
echo -e "${BOLD}▶ Phase 2  │  2 UEs × 5 Mbit/s  →  ~1300 KB/s${NC}"
echo -e "  expected: KEDA scales (>500 KB/s threshold)"
start_traffic 2 5
wait_for_replicas 2
echo -e "  holding to observe stable state..."
for t in 5 10 15 20 25 30; do sleep 5; status_line $t "2 UEs @ 5M"; done
echo ""

# ── Phase 3: ALL UEs × 5M — max load, 3 replicas ─────────
echo -e "${BOLD}▶ Phase 3  │  ALL ${NUM_UES} UEs × 5 Mbit/s  →  max load${NC}"
echo -e "  expected: KEDA scales to 3 replicas (max)"
start_traffic "$NUM_UES" 5
wait_for_replicas 3
echo -e "  holding to observe stable state at max replicas..."
for t in 5 10 15 20 25 30 35 40; do sleep 5; status_line $t "all UEs @ 5M"; done
echo ""

# ── Final ─────────────────────────────────────────────────
stop_traffic
echo -e "${BOLD}══ Scale-Up Complete ══════════════════════${NC}"
echo -e "  Final replicas : $(replicas)"
echo -e "  Final metric   : $(metric_kbs) KB/s"
for p in $(kubectl get pods -n $NS -l nf=upf --no-headers 2>/dev/null \
            | awk '{print $1}'); do
    N4=$(kubectl exec -n $NS "$p" -c upf -- \
        ip -4 addr show n4 2>/dev/null \
        | awk '/inet /{split($2,a,"/"); print a[1]}')
    echo -e "    ${GREEN}✔${NC}  $p  N4=${N4}"
done
echo ""
echo -e "  ${YELLOW}Run ./scale-down.sh to return to 1 replica${NC}"
echo ""
