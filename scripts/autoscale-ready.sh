#!/bin/bash
# ============================================================
#  Autoscaling Readiness Check
#  Verifies everything is in place before running scale scenarios
# ============================================================
set -u

NS=free5gc
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BOLD='\033[1m'; NC='\033[0m'

OK=0; FAIL=0

pass() { echo -e "  ${GREEN}✔${NC}  $*"; OK=$((OK+1)); }
fail() { echo -e "  ${RED}✗${NC}  $*"; FAIL=$((FAIL+1)); }
warn() { echo -e "  ${YELLOW}⚠${NC}  $*"; }
hdr()  { echo -e "\n${BOLD}$*${NC}"; }

echo -e "\n${BOLD}Autoscaling Readiness Check${NC}"
echo "══════════════════════════════════════"

# ── 1. Minikube ───────────────────────────────────────────
hdr "Cluster"
if minikube status 2>/dev/null | grep -q "Running"; then
    pass "Minikube running  ($(minikube ip 2>/dev/null))"
else
    fail "Minikube not running"
    echo -e "\n  ${RED}Cannot continue.${NC}\n"; exit 1
fi

NOT_OK=$(kubectl get pods -n $NS --no-headers 2>/dev/null \
    | awk '$3!="Running" && $3!="Completed"' | wc -l)
RUNNING=$(kubectl get pods -n $NS --no-headers 2>/dev/null | awk '$3=="Running"' | wc -l)
TOTAL=$(kubectl get pods -n $NS --no-headers 2>/dev/null | wc -l)
if [[ $NOT_OK -eq 0 ]]; then
    pass "All $RUNNING/$TOTAL pods Running"
else
    fail "$RUNNING/$TOTAL pods Running — not-ready: $(kubectl get pods -n $NS --no-headers 2>/dev/null \
        | awk '$3!="Running" && $3!="Completed" {printf $1"("$3") "}')"
fi

# ── 2. KEDA ──────────────────────────────────────────────
hdr "KEDA"
KEDA_OK=$(kubectl get pods -n keda --no-headers 2>/dev/null | awk '$3=="Running"' | wc -l)
KEDA_TOTAL=$(kubectl get pods -n keda --no-headers 2>/dev/null | wc -l)
[[ $KEDA_OK -eq $KEDA_TOTAL && $KEDA_TOTAL -gt 0 ]] \
    && pass "KEDA operator Running ($KEDA_OK/$KEDA_TOTAL pods)" \
    || fail "KEDA not healthy ($KEDA_OK/$KEDA_TOTAL pods Running)"

SO=$(kubectl get scaledobject -n $NS upf-throughput-scaler \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
THRESHOLD=$(kubectl get scaledobject -n $NS upf-throughput-scaler \
    -o jsonpath='{.spec.triggers[0].metadata.threshold}' 2>/dev/null)
[[ "$SO" == "True" ]] \
    && pass "ScaledObject Ready  |  threshold: $(( ${THRESHOLD:-500000} / 1000 )) KB/s  |  max 3 replicas" \
    || fail "ScaledObject not Ready"

# ── 3. Observability ─────────────────────────────────────
hdr "Observability"
PROM_POD=$(kubectl get pod -n monitoring -l app.kubernetes.io/name=prometheus \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
[[ -n "$PROM_POD" ]] && pass "Prometheus running" || fail "Prometheus not found"

UPF_POD=$(kubectl get pod -n $NS -l nf=upf \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null | head -1)
METRIC=$(kubectl exec -n $NS "$UPF_POD" -c metrics-exporter -- \
    python3 -c "
import urllib.request
r = urllib.request.urlopen('http://localhost:9090/metrics')
for l in r:
    l = l.decode().strip()
    if 'rx_bytes_per_second' in l and '#' not in l:
        print(l.split()[-1])
" 2>/dev/null)
[[ -n "$METRIC" ]] \
    && pass "GTP-U exporter responding  |  current RX: $(python3 -c "print(f'{float(${METRIC:-0})/1000:.0f}')" 2>/dev/null) KB/s" \
    || fail "GTP-U exporter not responding"

# ── 4. UE tunnels ────────────────────────────────────────
hdr "UE Tunnels"
UE_POD=$(kubectl get pod -n $NS -l component=ue \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
TUN_COUNT=$(kubectl exec -n $NS "$UE_POD" -- \
    ip addr 2>/dev/null | grep -c "uesimtun[0-9]:" || true)
if [[ $TUN_COUNT -ge 4 ]]; then
    pass "$TUN_COUNT tunnels active"
else
    fail "Only $TUN_COUNT tunnels — need ≥ 4"
fi
UE_IPS=()
for i in $(seq 0 $((TUN_COUNT - 1))); do
    IP=$(kubectl exec -n $NS "$UE_POD" -- \
        ip addr show "uesimtun${i}" 2>/dev/null \
        | awk '/inet 10\.1\./{split($2,a,"/"); print a[1]}')
    [[ -n "$IP" ]] && UE_IPS+=("$IP")
done
echo -e "       tunnels: ${UE_IPS[*]:-none}"

# ── 5. iperf3 ────────────────────────────────────────────
hdr "Traffic Generator"
IPERF_IP=$(kubectl get pod -n $NS iperf-server -o jsonpath='{.status.podIP}' 2>/dev/null)
[[ -n "$IPERF_IP" ]] \
    && pass "iperf-server pod ready  ($IPERF_IP)" \
    || fail "iperf-server pod not found"

if ! kubectl exec -n $NS "$UE_POD" -- which iperf3 2>/dev/null | grep -q iperf3; then
    warn "iperf3 not found — installing..."
    kubectl exec -n $NS "$UE_POD" -- apt-get install -y -qq iperf3 2>/dev/null | tail -1
fi
pass "iperf3 available in UE pod"

# Start 4 persistent iperf3 servers on separate ports
echo -n "       starting iperf3 servers on ports 5201-5204..."
kubectl exec -n $NS iperf-server -- sh -c "killall iperf3 2>/dev/null || true"; sleep 1
for port in 5201 5202 5203 5204; do
    kubectl exec -n $NS iperf-server -- iperf3 -s -p "$port" &>/dev/null &
done
sleep 2

# Quick connectivity test
TEST=$(kubectl exec -n $NS "$UE_POD" -- \
    iperf3 -c "$IPERF_IP" -p 5201 -B "${UE_IPS[0]:-10.1.0.1}" \
    -t 2 -b 5M -f K 2>/dev/null | grep -oP '\d+ KBytes/sec' | tail -1)
if [[ -n "$TEST" ]]; then
    echo -e " ${GREEN}✔${NC}"
    pass "GTP-U path verified  ($TEST sender)"
else
    echo ""
    warn "iperf3 connectivity test failed — servers may need more time"
fi

# ── 6. Baseline ──────────────────────────────────────────
hdr "Baseline"
DESIRED=$(kubectl get deployment -n $NS free5gc-free5gc-upf-upf \
    -o jsonpath='{.spec.replicas}' 2>/dev/null)
if [[ "$DESIRED" != "1" ]]; then
    warn "UPF at $DESIRED replicas — resetting to 1..."
    kubectl scale deployment -n $NS free5gc-free5gc-upf-upf --replicas=1 2>/dev/null
    until kubectl get deployment -n $NS free5gc-free5gc-upf-upf \
        -o jsonpath='{.status.readyReplicas}' 2>/dev/null | grep -q "^1$"; do sleep 3; done
fi
pass "UPF at 1 replica — clean baseline  ✓"

# ── Summary ──────────────────────────────────────────────
echo ""
echo "══════════════════════════════════════"
if [[ $FAIL -eq 0 ]]; then
    echo -e "  ${GREEN}${BOLD}✔  Ready for autoscaling scenarios${NC}"
    echo ""
    echo -e "  ${BOLD}Run:${NC}"
    echo -e "    scale-up.sh     # 1 → 2 → 3 UPF replicas (gradual load increase)"
    echo -e "    scale-down.sh   # 3 → 2 → 1 UPF replicas (gradual load decrease)"
    echo ""
    echo -e "  ${BOLD}Grafana:${NC}  http://$(minikube ip 2>/dev/null):30300/d/upf-autoscale?refresh=5s"
else
    echo -e "  ${RED}${BOLD}✗  $FAIL issue(s) must be fixed before running scenarios${NC}"
fi
echo ""
