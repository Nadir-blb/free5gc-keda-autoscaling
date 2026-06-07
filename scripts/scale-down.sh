#!/bin/bash
# ============================================================
#  Scale-Down Scenario  —  Gradual load decrease, all UEs
#
#  Phase 0  │  all UEs × 5 Mbit/s  │  max load  │  3 replicas
#  Phase 1  │  2 UEs  × 5 Mbit/s   │ ~1300 KB/s │  2–3 replicas
#  Phase 2  │  2 UEs  × 1 Mbit/s   │  ~200 KB/s │  1 replica (below 500 KB/s)
#  Phase 3  │  idle                 │    0 KB/s  │  1 replica (min)
# ============================================================
set -u

NS=free5gc
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BOLD='\033[1m'; NC='\033[0m'

UE_POD=$(kubectl get pod -n $NS -l component=ue -o jsonpath='{.items[0].metadata.name}')
UPF_POD=$(kubectl get pod -n $NS -l nf=upf -o jsonpath='{.items[0].metadata.name}' | head -1)
IPERF_IP=$(kubectl get pod -n $NS iperf-server -o jsonpath='{.status.podIP}')

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

wait_for_replicas_down() {
    local target=$1
    local timeout=180 elapsed=0
    echo -n "  waiting for KEDA to scale down to $target replica(s)"
    while [[ $elapsed -lt $timeout ]]; do
        local r; r=$(ready_count)
        if [[ "${r:-0}" -le "$target" ]]; then
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

kill_servers() {
    kubectl exec -n $NS iperf-server -- sh -c '
        for pid in $(ls /proc | grep -E "^[0-9]+$"); do
            cmd=$(cat /proc/$pid/cmdline 2>/dev/null | tr "\0" " ")
            echo "$cmd" | grep -q "iperf3" && kill $pid 2>/dev/null || true
        done' 2>/dev/null || true
    sleep 2
}

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
}

start_traffic() {
    local NUM=$1 BW=$2
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

# ── Header ────────────────────────────────────────────────
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║    Scale-Down Scenario  —  free5GC UPF   ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════╝${NC}"
echo ""
echo -e "  iperf server : $IPERF_IP"
echo -e "  UE tunnels   : ${NUM_UES} active  (${UE_IPS[*]})"
echo -e "  threshold    : 500 KB/s  →  ceil(total/500) replicas"
echo ""
echo -e "  ${YELLOW}Grafana:${NC} http://$(minikube ip):30300/d/upf-autoscale?refresh=5s"
echo ""

start_servers "$NUM_UES"

# If not at 3 replicas yet, ramp up first
CURRENT=$(kubectl get deployment -n $NS free5gc-free5gc-upf-upf \
    -o jsonpath='{.spec.replicas}' 2>/dev/null)
if [[ "${CURRENT:-0}" -lt 3 ]]; then
    echo -e "${YELLOW}  UPF at $CURRENT replica(s) — ramping to 3 first...${NC}"
    start_traffic "$NUM_UES" 5
    echo -n "  waiting for 3 replicas"
    until [[ "$(ready_count)" -ge 3 ]]; do echo -n "."; sleep 5; done
    echo -e "  ${GREEN}✔ 3 replicas ready${NC}"
    echo ""
fi

# ── Phase 0: Max load — all UEs ───────────────────────────
echo -e "${BOLD}▶ Phase 0  │  ALL ${NUM_UES} UEs × 5 Mbit/s  (max load)${NC}"
echo -e "  expected: 3 replicas"
start_traffic "$NUM_UES" 5
for t in 5 10 15 20 25 30; do sleep 5; status_line $t "all UEs @ 5M"; done
echo ""

# ── Phase 1: 2 UEs × 5M ───────────────────────────────────
echo -e "${BOLD}▶ Phase 1  │  2 UEs × 5 Mbit/s  →  ~1300 KB/s${NC}"
echo -e "  expected: KEDA scales down to 2–3 replicas"
start_traffic 2 5
wait_for_replicas_down 2
echo -e "  holding..."
for t in 5 10 15 20 25 30 35 40; do sleep 5; status_line $t "2 UEs @ 5M"; done
echo ""

# ── Phase 2: 2 UEs × 1M — below threshold ─────────────────
echo -e "${BOLD}▶ Phase 2  │  2 UEs × 1 Mbit/s  →  ~200 KB/s${NC}"
echo -e "  expected: KEDA scales down to 1 replica (below 500 KB/s)"
start_traffic 2 1
wait_for_replicas_down 1
echo -e "  holding..."
for t in 5 10 15 20 25 30 35 40; do sleep 5; status_line $t "2 UEs @ 1M"; done
echo ""

# ── Phase 3: Idle ─────────────────────────────────────────
stop_traffic
echo -e "${BOLD}▶ Phase 3  │  Idle (no traffic)${NC}"
echo -e "  expected: stays at 1 replica (minimum)"
for t in 5 10 15 20 25 30; do sleep 5; status_line $t "idle"; done
echo ""

# ── Final ─────────────────────────────────────────────────
echo -e "${BOLD}══ Scale-Down Complete ════════════════════${NC}"
echo -e "  Final replicas : $(replicas)"
echo -e "  Final metric   : $(metric_kbs) KB/s"
echo -e "\n  ${GREEN}${BOLD}✔  Back to baseline — system ready${NC}\n"
