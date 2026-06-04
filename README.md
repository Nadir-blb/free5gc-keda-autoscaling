# free5GC + UERANSIM + KEDA Autoscaling on Kubernetes

A complete deployment of a **5G SA core network** (free5GC v3.3.0) on a single-node Kubernetes cluster (minikube), with **elastic horizontal autoscaling of the UPF** driven by real GTP-U throughput metrics via KEDA and Prometheus.

## What this does

- Deploys all 11 free5GC Network Functions on Kubernetes using Helm
- Configures Multus CNI + whereabouts IPAM for proper 5G interface isolation (N2/N3/N4/N6)
- Simulates 1 gNB and 10 simultaneous UEs using UERANSIM (5G-AKA auth, PDU sessions, GTP-U tunnels)
- Exposes a custom GTP-U throughput metric via a Python sidecar on the UPF
- Uses KEDA to scale UPF replicas 1 → 2 → 3 based on traffic load
- Visualises everything in Grafana

## Requirements

### Hardware
| Component | Minimum |
|---|---|
| OS | Ubuntu 22.04 LTS |
| CPU | 8 cores (x86_64) |
| RAM | 16 GB |
| Disk | 30 GB free (SSD recommended) |

### Software to install

```bash
# Docker
sudo apt-get install -y ca-certificates curl gnupg
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list
sudo apt-get update && sudo apt-get install -y docker-ce docker-ce-cli containerd.io
sudo usermod -aG docker $USER   # then log out and back in

# kubectl
curl -LO "https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl

# minikube
curl -LO https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64
sudo install minikube-linux-amd64 /usr/local/bin/minikube

# Helm
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
```

---

## Step 1 — Load the GTP-U kernel module

The UPF requires the `gtp5g` module to create GTP-U tunnels.

```bash
sudo apt-get install -y git make gcc linux-headers-$(uname -r)
git clone https://github.com/free5gc/gtp5g.git
cd gtp5g && make && sudo make install
sudo modprobe gtp5g
lsmod | grep gtp5g        # verify
cd ..
```

To make it persistent across reboots:
```bash
echo "gtp5g" | sudo tee /etc/modules-load.d/gtp5g.conf
```

---

## Step 2 — Start minikube

```bash
minikube start \
  --driver=docker \
  --cpus=6 \
  --memory=10g \
  --disk-size=30g
```

Verify:
```bash
minikube status
kubectl get nodes
```

---

## Step 3 — Install Multus CNI (thick)

Multus enables multiple network interfaces per pod — required for 5G N2/N3/N4/N6 interfaces.

```bash
kubectl apply -f https://raw.githubusercontent.com/k8snetworkplumbingwg/multus-cni/master/deployments/multus-daemonset-thick.yml
kubectl rollout status daemonset -n kube-system kube-multus-ds --timeout=60s
```

---

## Step 4 — Install whereabouts IPAM

whereabouts provides dynamic IP pools for Multus — required so multiple UPF replicas each get a unique N3/N4/N6 address.

```bash
kubectl apply -f https://raw.githubusercontent.com/k8snetworkplumbingwg/whereabouts/master/doc/crds/whereabouts.cni.cncf.io_ippools.yaml
kubectl apply -f https://raw.githubusercontent.com/k8snetworkplumbingwg/whereabouts/master/doc/crds/whereabouts.cni.cncf.io_overlappingrangeipreservations.yaml
```

Deploy the whereabouts DaemonSet:
```bash
kubectl apply -f k8s/whereabouts-daemonset.yaml
kubectl rollout status daemonset -n kube-system whereabouts --timeout=90s
```

---

## Step 5 — Deploy free5GC

Add the Helm chart repo:
```bash
helm repo add towards5gs https://raw.githubusercontent.com/Orange-OpenSource/towards5gs-helm/main/repo/
helm repo update
```

Deploy with the provided values (maps all 5G interfaces to `eth0` for single-NIC minikube):
```bash
kubectl create namespace free5gc
helm install free5gc towards5gs/free5gc -n free5gc -f helm/free5gc-values.yaml --timeout 5m
```

Wait for all pods:
```bash
kubectl wait --for=condition=ready pod -n free5gc --all --timeout=300s
kubectl get pods -n free5gc
```

Expected: **14 pods Running** (11 NFs + gNB + UE + MongoDB).

---

## Step 6 — Apply the UPF routing patch

The default chart uses a static N6 gateway that does not exist in a single-NIC minikube setup. A wrapper script patches this at pod start-up:

```bash
UPF_CM=$(kubectl get configmap -n free5gc -l nf=upf -o name | head -1)
kubectl patch $UPF_CM -n free5gc --type=merge \
  -p "{\"data\":{\"wrapper.sh\":$(cat scripts/upf-wrapper.sh | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')}}"
kubectl rollout restart deployment -n free5gc -l nf=upf
kubectl rollout status deployment -n free5gc -l nf=upf --timeout=90s
```

The patch makes the UPF detect its own eth0 gateway at startup and route UE traffic through it with NAT masquerade — making internet reachable through GTP-U tunnels.

---

## Step 7 — Apply the whereabouts NAD patch

Switch the UPF's N3/N4/N6 NetworkAttachmentDefinitions from static IPs to whereabouts pools so replicas can scale:

```bash
bash scripts/patch-nads.sh
```

Remove the static IP annotations from the UPF deployment:
```bash
kubectl patch deployment -n free5gc $(kubectl get deploy -n free5gc -l nf=upf -o name | head -1) \
  --type=json -p '[{"op":"replace","path":"/spec/template/metadata/annotations/k8s.v1.cni.cncf.io~1networks",
  "value":"[{\"name\":\"n3network-free5gc-free5gc-upf\",\"interface\":\"n3\"},{\"name\":\"n6network-free5gc-free5gc-upf\",\"interface\":\"n6\"},{\"name\":\"n4network-free5gc-free5gc-upf\",\"interface\":\"n4\"}]"}]'
kubectl rollout restart deployment -n free5gc -l nf=upf
```

---

## Step 8 — Register subscribers

Connect to the WebUI at `http://$(minikube ip):30500` (credentials: `admin` / `free5gc`) and add subscribers, **or** use the MongoDB script for bulk registration:

```bash
MONGO=$(kubectl get pod -n free5gc -l app.kubernetes.io/name=mongodb \
        -o jsonpath='{.items[0].metadata.name}')

# Register 11 subscribers (IMSIs 208930000000003 – 208930000000013)
kubectl exec -n free5gc $MONGO -- mongo free5gc --quiet --eval "
  var base = 208930000000003;
  for (var i = 0; i < 11; i++) {
    var imsi = 'imsi-' + (base + i);
    var cols = [
      'subscriptionData.authenticationData.authenticationSubscription',
      'subscriptionData.provisionedData.amData',
      'subscriptionData.provisionedData.smData',
      'subscriptionData.provisionedData.smfSelectionSubscriptionData',
      'policyData.ues.amData',
      'policyData.ues.smData'
    ];
    var src = db['subscriptionData.authenticationData.authenticationSubscription'].findOne();
    if (!src) { print('No template subscriber found'); quit(1); }
    cols.forEach(function(c) {
      var doc = db[c].findOne({ueId: src.ueId});
      if (doc) { delete doc._id; doc.ueId = imsi; db[c].insertOne(doc); }
    });
    print('registered: ' + imsi);
  }
"
```

To add a **single new subscriber** at any time (clone from an existing one):
```bash
kubectl exec -n free5gc $MONGO -- mongo free5gc --quiet --eval '
  var src = "imsi-208930000000013";
  var dst = "imsi-208930000000014";
  var cols = [
    "subscriptionData.authenticationData.authenticationSubscription",
    "subscriptionData.provisionedData.amData",
    "subscriptionData.provisionedData.smData",
    "subscriptionData.provisionedData.smfSelectionSubscriptionData",
    "policyData.ues.amData",
    "policyData.ues.smData"
  ];
  cols.forEach(function(c) {
    var doc = db[c].findOne({ ueId: src });
    if (doc) { delete doc._id; doc.ueId = dst; db[c].insertOne(doc); print("inserted: " + c); }
  });
'
```

No NF restart required — UDM queries MongoDB at registration time.

---

## Step 9 — Validate the core network

Run the health check:
```bash
bash scripts/free5gc-check.sh
```

Expected output:
```
✔  Minikube running
✔  Pods: 14/14 Running
✔  gNB NG Setup successful
✔  PFCP: SMF associated  |  10 session(s)
✔  10 UE tunnel(s): 10.1.0.1 ... 10.1.0.10
✔  Internet reachable via uesimtun0 (8.8.8.8)
✔  Core network healthy
```

---

## Step 10 — Deploy monitoring (Prometheus + Grafana)

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
helm install kube-prom prometheus-community/kube-prometheus-stack \
  --namespace monitoring --create-namespace \
  -f helm/prometheus-values.yaml --timeout 5m
kubectl wait --for=condition=ready pod -n monitoring -l app.kubernetes.io/name=prometheus --timeout=120s
```

Grafana is available at `http://$(minikube ip):30300` — credentials: `admin` / `free5gc`.

---

## Step 11 — Add the GTP-U metrics exporter to UPF

The exporter reads `/proc/net/dev` on the `upfgtp` interface and exposes `upf_gtpu_rx_bytes_per_second` and `upf_gtpu_tx_bytes_per_second` as Prometheus metrics.

```bash
# Create ConfigMap with the exporter
kubectl create configmap -n free5gc upf-exporter --from-file=exporter.py=scripts/upf-exporter.py

# Patch UPF deployment to add sidecar + expose metrics Service
kubectl apply -f k8s/upf-metrics-service.yaml
kubectl apply -f k8s/upf-metrics-servicemonitor.yaml
kubectl patch deployment -n free5gc $(kubectl get deploy -n free5gc -l nf=upf -o name) \
  --type=json --patch-file=k8s/upf-sidecar-patch.json
kubectl rollout status deployment -n free5gc -l nf=upf --timeout=90s
```

Verify the exporter is working:
```bash
UPF_POD=$(kubectl get pod -n free5gc -l nf=upf -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n free5gc $UPF_POD -c metrics-exporter -- \
  python3 -c "import urllib.request; print(urllib.request.urlopen('http://localhost:9090/metrics').read().decode())"
```

---

## Step 12 — Deploy KEDA

```bash
helm repo add kedacore https://kedacore.github.io/charts
helm repo update
helm install keda kedacore/keda --namespace keda --create-namespace --timeout 3m
kubectl wait --for=condition=ready pod -n keda -l app=keda-operator --timeout=120s
```

Apply the ScaledObject (triggers UPF scale-out when GTP-U RX > 500 KB/s):
```bash
kubectl apply -f k8s/upf-scaledobject.yaml
kubectl get scaledobject -n free5gc upf-throughput-scaler
```

Expected: `READY=True`.

---

## Step 13 — Import Grafana dashboard

```bash
GRAFANA="http://$(minikube ip):30300"
# Wait for Grafana to be ready
until curl -s $GRAFANA/api/health | grep -q '"database":"ok"'; do sleep 5; done

# Create Prometheus datasource
curl -s -u admin:free5gc -X POST $GRAFANA/api/datasources \
  -H "Content-Type: application/json" \
  -d '{"name":"Prometheus","type":"prometheus",
       "url":"http://kube-prom-kube-prometheus-prometheus.monitoring.svc.cluster.local:9090",
       "access":"proxy","isDefault":true}'

# Import dashboard
curl -s -u admin:free5gc -X POST $GRAFANA/api/dashboards/import \
  -H "Content-Type: application/json" \
  -d "{\"dashboard\":$(cat grafana/upf-dashboard.json),\"overwrite\":true,\"folderId\":0}"
```

Dashboard URL: `http://$(minikube ip):30300/d/upf-autoscale?refresh=5s`

---

## Running the autoscaling scenarios

### Check readiness first
```bash
bash scripts/autoscale-ready.sh
```

### Scale-up scenario (1 → 2 → 3 UPF replicas)
```bash
bash scripts/scale-up.sh
```

Traffic profile:
- Phase 1: 2 UEs × 1 Mbit/s → ~260 KB/s → **1 replica** (below threshold)
- Phase 2: 2 UEs × 5 Mbit/s → ~1300 KB/s → **3 replicas** (KEDA triggers)
- Phase 3: 4 UEs × 5 Mbit/s → ~2600 KB/s → **3 replicas** (max)

### Scale-down scenario (3 → 1 UPF replicas)
```bash
bash scripts/scale-down.sh
```

Traffic profile:
- Phase 0: 3 UEs × 5 Mbit/s → ~1950 KB/s → **3 replicas**
- Phase 1: 2 UEs × 5 Mbit/s → ~1300 KB/s → **1 replica** (KEDA scales down)
- Phase 2: 2 UEs × 1 Mbit/s → ~260 KB/s → **1 replica**
- Phase 3: idle → **1 replica** (minimum)

Watch Grafana at `http://$(minikube ip):30300/d/upf-autoscale?refresh=5s` while the scenarios run.

---

## Repository structure

```
.
├── scripts/
│   ├── free5gc-check.sh        # Core network health check (non-blocking)
│   ├── autoscale-ready.sh      # Autoscaling readiness check
│   ├── scale-up.sh             # Gradual scale-up scenario
│   ├── scale-down.sh           # Gradual scale-down scenario
│   ├── upf-exporter.py         # GTP-U Prometheus metrics exporter (sidecar)
│   ├── upf-wrapper.sh          # UPF startup wrapper (dynamic N6 gateway)
│   └── patch-nads.sh           # Patch NADs to use whereabouts IPAM
├── helm/
│   ├── free5gc-values.yaml     # Helm override for single-NIC minikube
│   └── prometheus-values.yaml  # Prometheus + Grafana Helm values
├── k8s/
│   ├── whereabouts-daemonset.yaml
│   ├── upf-metrics-service.yaml
│   ├── upf-metrics-servicemonitor.yaml
│   ├── upf-sidecar-patch.json
│   └── upf-scaledobject.yaml
├── grafana/
│   └── upf-dashboard.json      # Grafana dashboard (4 panels)
└── README.md
```

---

## Validated results

| Test | Metric | Direction | Time |
|---|---|---|---|
| 2 UEs × 5 Mbit/s | ~1300 KB/s | 1 → 3 replicas | ~10 s |
| Reduce to 2 UEs × 1 Mbit/s | ~260 KB/s | 3 → 1 replica | ~15 s |
| Idle | 0 KB/s | stays at 1 | — |
| Max throughput (4 UEs × 5M) | ~2600 KB/s | 3 replicas | sustained |

Each UPF replica gets a unique N4 IP from the whereabouts pool (10.100.50.241 / .242 / .243), and its own PFCP association with the SMF.

---

## Troubleshooting

**Multus pod is Completed after restart** — force-delete it so it restarts:
```bash
kubectl delete pod -n kube-system -l app=multus --force
```

**UPF has no secondary interfaces** — Multus was down when the pod started. Restart the UPF:
```bash
kubectl rollout restart deployment -n free5gc -l nf=upf
```

**No uesimtun interfaces** — PDU sessions stale after restart. Restart UE and SMF:
```bash
kubectl rollout restart deployment -n free5gc ueransim-ue
kubectl rollout restart deployment -n free5gc -l nf=smf
```

**KEDA metric always 0** — check the exporter sidecar:
```bash
kubectl logs -n free5gc $(kubectl get pod -n free5gc -l nf=upf -o jsonpath='{.items[0].metadata.name}') -c metrics-exporter
```
