#!/bin/bash
# free5GC + UERANSIM — quick health check (non-blocking)
set -u

NS=free5gc
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'

pass() { echo -e "  ${GREEN}✔${NC}  $*"; PASSED=$((PASSED+1)); }
fail() { echo -e "  ${RED}✗${NC}  $*"; FAILED=$((FAILED+1)); }
warn() { echo -e "  ${YELLOW}⚠${NC}  $*"; WARNED=$((WARNED+1)); }

PASSED=0; FAILED=0; WARNED=0

echo -e "\n${BOLD}free5GC Health Check${NC}"
echo "────────────────────────────────────"

# 1. Minikube
if minikube status 2>/dev/null | grep -q "Running"; then
    pass "Minikube running  ($(minikube ip 2>/dev/null))"
else
    fail "Minikube not running"
    echo -e "\n  ${RED}✗  Cannot continue — start minikube first${NC}\n"; exit 1
fi

# 2. Pods
RUNNING=$(kubectl get pods -n $NS --no-headers 2>/dev/null | awk '$3=="Running"' | wc -l)
TOTAL=$(kubectl get pods -n $NS --no-headers 2>/dev/null | wc -l)
NOT_OK=$(kubectl get pods -n $NS --no-headers 2>/dev/null | awk '$3!="Running" && $3!="Completed"' | wc -l)
if [[ $NOT_OK -eq 0 ]]; then
    pass "Pods: $RUNNING/$TOTAL Running"
else
    fail "Pods: $RUNNING/$TOTAL Running — $(kubectl get pods -n $NS --no-headers 2>/dev/null | awk '$3!="Running" && $3!="Completed" {print $1"("$3")"}' | tr '\n' ' ')"
fi

# 3. gNB registered with AMF
GNB_POD=$(kubectl get pod -n $NS -l component=gnb -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if kubectl logs -n $NS "$GNB_POD" --tail=500 2>/dev/null | grep -q "NG Setup procedure is successful"; then
    pass "gNB NG Setup successful"
else
    fail "gNB not registered with AMF"
fi

# 4. PFCP association (SMF ↔ UPF)
UPF_POD=$(kubectl get pod -n $NS -l nf=upf -o jsonpath='{.items[0].metadata.name}' 2>/dev/null | head -1)
ASSOC=$(kubectl logs -n $NS "$UPF_POD" 2>/dev/null | grep "New node" | tail -1)
if [[ -n "$ASSOC" ]]; then
    SMF_IP=$(echo "$ASSOC" | grep -oP 'CPNodeID:[0-9.]+' | cut -d: -f2)
    SESSIONS=$(kubectl logs -n $NS "$UPF_POD" 2>/dev/null | grep -c "New session")
    pass "PFCP: SMF $SMF_IP associated  |  $SESSIONS session(s)"
else
    fail "No PFCP association — SMF/UPF not connected"
fi

# 5. UE tunnels up
UE_POD=$(kubectl get pod -n $NS -l component=ue -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
TUN_COUNT=$(kubectl exec -n $NS "$UE_POD" -- ip addr 2>/dev/null | grep -c "uesimtun[0-9]:" || true)
if [[ $TUN_COUNT -gt 0 ]]; then
    TUN_IPS=$(kubectl exec -n $NS "$UE_POD" -- ip addr 2>/dev/null \
        | awk '/inet 10\.1\./{split($2,a,"/"); printf a[1]" "}')
    pass "$TUN_COUNT UE tunnel(s): $TUN_IPS"
else
    fail "No uesimtun interfaces — PDU sessions not established"
fi

# 6. Internet via uesimtun0
RESULT=$(kubectl exec -n $NS "$UE_POD" -- \
    ping -I uesimtun0 -c 4 -W 3 8.8.8.8 2>/dev/null \
    | grep -oP '\d+ received' | awk '{print $1}')
if [[ "${RESULT:-0}" -gt 0 ]]; then
    pass "Internet reachable via uesimtun0 (8.8.8.8)"
else
    warn "ping 8.8.8.8 via uesimtun0 failed"
fi

# ── Summary ───────────────────────────────────────────────
echo "────────────────────────────────────"
echo -e "  ${GREEN}Passed${NC} $PASSED  ${YELLOW}Warned${NC} $WARNED  ${RED}Failed${NC} $FAILED"
echo ""
if [[ $FAILED -eq 0 ]]; then
    echo -e "  ${GREEN}${BOLD}✔  Core network healthy${NC}"
else
    echo -e "  ${RED}${BOLD}✗  $FAILED check(s) failed${NC}"
fi
echo -e "  WebUI → ${BOLD}http://$(minikube ip 2>/dev/null):30500${NC}  (admin / free5gc)\n"
