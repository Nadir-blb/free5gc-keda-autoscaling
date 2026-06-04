#!/bin/bash
# ============================================================
#  Scale-Down Scenario  —  Gradual load decrease from multiple UEs
#
#  Phase 0  │  3 UEs × 5 Mbit/s  │  ~1950 KB/s│  3 replicas (starts here)
#  Phase 1  │  2 UEs × 5 Mbit/s  │  ~1300 KB/s│  2 replicas
#  Phase 2  │  2 UEs × 1 Mbit/s  │  ~200 KB/s │  1 replica  (below 500 KB/s)
#  Phase 3  │  idle              │  0 KB/s    │  1 replica  (min)
# ============================================================
set -u

NS=free5gc
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

UE_POD=$(kubectl get pod -n $NS -l component=ue -o jsonpath='{.items[0].metadata.name}')
UPF_POD=$(kubectl get pod -n $NS -l nf=upf -o jsonpath='{.items[0].metadata.name}' | head -1)
IPERF_IP=$(kubectl get pod -n $NS iperf-server -o jsonpath='{.status.podIP}')

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

TRAFFIC_PID=""
SERVER_PIDS=()

cleanup() {
    kubectl exec -n $NS "$UE_POD" -- pkill iperf3 2>/dev/null || true
    [[ -n "${TRAFFIC_PID:-}" ]] && kill "$TRAFFIC_PID" 2>/dev/null || true
    [[ ${#SERVER_PIDS[@]} -gt 0 ]] && kill "${SERVER_PIDS[@]}" 2>/dev/null || true
}
trap cleanup EXIT

start_servers() {
    kubectl exec -n $NS iperf-server -- sh -c "killall iperf3 2>/dev/null || true"; sleep 1
    for port in 5201 5202 5203 5204; do
        kubectl exec -n $NS iperf-server -- iperf3 -s -p "$port" &>/dev/null &
        SERVER_PIDS+=($!)
    done
    sleep 2
}

start_traffic() {
    local NUM=$1 BW=$2
    kubectl exec -n $NS "$UE_POD" -- pkill iperf3 2>/dev/null || true
    [[ -n "${TRAFFIC_PID:-}" ]] && kill "$TRAFFIC_PID" 2>/dev/null || true
    sleep 2
    local CMD=""
    for i in $(seq 0 $((NUM - 1))); do
        local IP="${UE_IPS[$i]:-}"; local PORT=$((5201 + i))
        [[ -z "$IP" ]] && continue
        CMD="${CMD}iperf3 -c $IPERF_IP -p $PORT -B $IP -b ${BW}M -t 86400 >/dev/null 2>&1 & "
    done
    CMD="${CMD}wait"
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
echo -e "${BOLD}║    Scale-Down Scenario  —  free5GC UPF   ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════╝${NC}"
echo ""
echo -e "  iperf server : $IPERF_IP"
echo -e "  UE tunnels   : ${#UE_IPS[@]} active (${UE_IPS[*]})"
echo -e "  threshold    : 500 KB/s per replica"
echo ""
echo -e "  ${YELLOW}Grafana:${NC} http://$(minikube ip):30300/d/upf-autoscale?refresh=5s"
echo ""

start_servers

# If not already at 3 replicas, ramp up first
CURRENT=$(kubectl get deployment -n $NS free5gc-free5gc-upf-upf \
    -o jsonpath='{.spec.replicas}' 2>/dev/null)
if [[ "$CURRENT" != "3" ]]; then
    echo -e "${YELLOW}  UPF is at $CURRENT replica(s) — ramping up to 3 first...${NC}"
    start_traffic 3 5
    echo -n "  waiting for 3 replicas"
    until kubectl get deployment -n $NS free5gc-free5gc-upf-upf \
        -o jsonpath='{.spec.replicas}' 2>/dev/null | grep -q "^3$"; do
        echo -n "."; sleep 5
    done
    until kubectl get deployment -n $NS free5gc-free5gc-upf-upf \
        -o jsonpath='{.status.readyReplicas}' 2>/dev/null | grep -q "^3$"; do
        echo -n "."; sleep 5
    done
    echo -e "  ${GREEN}✔${NC} 3 replicas ready\n"
    stop_traffic
fi

# ── Phase 0: Full load ────────────────────────────────────
echo -e "${BOLD}▶ Phase 0  │  4 UEs × 5 Mbit/s  →  ~2600 KB/s  (max load)${NC}"
echo -e "  expected: 3 replicas"
start_traffic 3 5
for t in 5 10 15 20 25 30; do sleep 5; status_line $t "3 UEs @ 5M"; done
echo ""

# ── Phase 1: 2 UEs × 5 Mbit/s ≈ 1300 KB/s ───────────────
echo -e "${BOLD}▶ Phase 1  │  2 UEs × 5 Mbit/s  →  ~1300 KB/s  (reduced)${NC}"
echo -e "  expected: scale to 2 replicas"
start_traffic 2 5
for t in 5 10 15 20 25 30 35 40; do sleep 5; status_line $t "2 UEs @ 5M"; done
echo ""

# ── Phase 2: 2 UEs × 2 Mbit/s ≈ 366 KB/s ────────────────
echo -e "${BOLD}▶ Phase 2  │  2 UEs × 1 Mbit/s  →  ~200 KB/s  (low load)${NC}"
echo -e "  expected: scale to 1 replica (below 500 KB/s)"
start_traffic 2 1
for t in 5 10 15 20 25 30 35 40; do sleep 5; status_line $t "2 UEs @ 1M"; done
echo ""

# ── Phase 3: Idle ─────────────────────────────────────────
stop_traffic
echo -e "${BOLD}▶ Phase 3  │  Idle (no traffic)${NC}"
echo -e "  expected: stays at 1 replica (minimum)"
for t in 5 10 15 20 25 30; do sleep 5; status_line $t "idle"; done
echo ""

# ── Final state ──────────────────────────────────────────
echo -e "${BOLD}══ Scale-Down Complete ════════════════════${NC}"
echo -e "  Final replicas : $(replicas)"
echo -e "  Final metric   : $(metric_kbs) KB/s"
echo -e "\n  ${GREEN}${BOLD}✔  Back to baseline — system ready${NC}\n"
