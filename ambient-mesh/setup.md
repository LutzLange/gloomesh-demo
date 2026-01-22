# Ambient Mesh Workshop - Setup Guide

This guide provides step-by-step manual setup instructions for the Ambient Mesh Workshop. Each command includes explanations of what it does and why.

---

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [Environment Configuration](#environment-configuration)
3. [Step 1: Install Gateway API CRDs](#step-1-install-gateway-api-crds)
4. [Step 2: Install Istio Ambient](#step-2-install-istio-ambient)
5. [Step 3: Install Istio Ingress Gateway](#step-3-install-istio-ingress-gateway)
6. [Verify Setup](#verify-setup)
7. [Step 4: Install Gloo Platform (Optional)](#step-4-install-gloo-platform-optional)
8. [Optional: Install Gloo Gateway](#optional-install-gloo-gateway)

---

## Prerequisites

Before starting, ensure you have the following tools installed:

| Tool | Version | Purpose |
|------|---------|---------|
| `kubectl` | 1.28+ | Kubernetes CLI |
| `helm` | 3.x | Package manager for Kubernetes |
| `curl` | any | Download tools and test endpoints |

You'll need access to a Kubernetes cluster. The workshop supports:
- **GKE** (Google Kubernetes Engine) - recommended
- **EKS** (Amazon Elastic Kubernetes Service)
- **AKS** (Azure Kubernetes Service)
- **Kind** or other local clusters (for testing)

---

## Environment Configuration

### Create Your Configuration File

Create an `env.sh` file with your cluster details:

```bash
cat > env.sh << 'EOF'
# Component versions
export ISTIO_VERSION=1.28.1
export GLOO_VERSION=2.11.0

# Solo license key (enables Solo Istio distribution + Gloo Platform UI)
export GLOO_MESH_LICENSE_KEY=<your-mesh-key>

# Optional: For Gloo Gateway section
export GLOO_GATEWAY_LICENSE_KEY=<your-gateway-key>
EOF
```

### Load the Environment

Source your configuration before running any commands:

```bash
source env.sh
```

### Verify Cluster Connectivity

Check that kubectl can connect to your cluster:

```bash
kubectl cluster-info
```

You should see cluster endpoint information. If you see connection errors, verify your kubeconfig is correctly configured.

---

## Step 1: Install Gateway API CRDs

**What this does:** Installs the [Kubernetes Gateway API](https://gateway-api.sigs.k8s.io/) Custom Resource Definitions (CRDs). The Gateway API is the next-generation Kubernetes ingress specification.

**Why this is needed:** Istio Ambient uses Gateway API for traffic management. The CRDs must be installed before any Gateway or HTTPRoute resources can be created.

### Install Gateway API CRDs

```bash
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.4.0/standard-install.yaml
```

### Verify CRD Installation

```bash
kubectl get crds | grep gateway
```

Expected output should include:
- `gateways.gateway.networking.k8s.io`
- `httproutes.gateway.networking.k8s.io`
- `gatewayclasses.gateway.networking.k8s.io`

---

## Step 2: Install Istio Ambient

**What this does:** Deploys [Istio Ambient Mesh](https://istio.io/latest/docs/ambient/), which uses:
- **[ztunnel](https://istio.io/latest/docs/ambient/overview/#ztunnel):** A per-node proxy for L4 mTLS encryption
- **[Waypoint proxies](https://istio.io/latest/docs/ambient/overview/#waypoint-proxies):** Optional L7 proxies for advanced traffic policies

**Why Ambient vs Sidecar:**
- **No sidecar overhead:** Significant cost reduction vs traditional sidecars
- **No application restarts:** Add mesh capabilities with a namespace label
- **L7 when needed:** Waypoints provide L7 features only where required

### Set Istio Environment Variables

Choose between **upstream Istio** (open source) or **Solo.io distribution** (enterprise features):

**Option A: Upstream Istio (Open Source)**

```bash
export HELM_REPO="oci://docker.io/istio"
export ISTIO_IMAGE="${ISTIO_VERSION}"
export ISTIO_HUB="docker.io/istio"
```

**Option B: Solo.io Distribution (Enterprise)**

The Solo.io distribution includes L7 telemetry in ztunnel without waypoints, FIPS-validated images, and enterprise support.

```bash
export HELM_REPO="us-docker.pkg.dev/soloio-img/istio-helm"
export ISTIO_IMAGE="${ISTIO_VERSION}-solo"
export ISTIO_HUB="us-docker.pkg.dev/soloio-img/istio"
```

---

### 2.1: Create Namespace

```bash
kubectl create ns istio-system 2>/dev/null || true
```

### 2.2: Create ResourceQuota for GKE (if applicable)

GKE requires a ResourceQuota for pods using system-critical PriorityClasses:

```bash
kubectl apply -f - <<EOF
apiVersion: v1
kind: ResourceQuota
metadata:
  name: gcp-critical-pods
  namespace: istio-system
spec:
  hard:
    pods: "1000"
  scopeSelector:
    matchExpressions:
    - operator: In
      scopeName: PriorityClass
      values:
      - system-node-critical
      - system-cluster-critical
EOF
```

> **Note:** Skip this step if you're not using GKE.

### 2.3: Install Istio Base CRDs

```bash
helm upgrade --install istio-base oci://${HELM_REPO}/base \
  --namespace istio-system \
  --version "${ISTIO_IMAGE}" \
  --set defaultRevision=default \
  --set profile=ambient \
  --wait
```

### 2.4: Install istiod Control Plane

**For Upstream Istio:**

```bash
helm upgrade --install istiod oci://${HELM_REPO}/istiod \
  --namespace istio-system \
  --version "${ISTIO_IMAGE}" \
  --wait \
  -f - <<EOF
global:
  hub: ${ISTIO_HUB}
  tag: ${ISTIO_IMAGE}
  logAsJson: true
meshConfig:
  accessLogFile: /dev/stdout
pilot:
  cni:
    namespace: istio-system
    enabled: true
profile: ambient
EOF
```

**For Solo.io Distribution (with license):**

```bash
helm upgrade --install istiod oci://${HELM_REPO}/istiod \
  --namespace istio-system \
  --version "${ISTIO_IMAGE}" \
  --wait \
  -f - <<EOF
global:
  hub: ${ISTIO_HUB}
  tag: ${ISTIO_IMAGE}
  logAsJson: true
meshConfig:
  accessLogFile: /dev/stdout
pilot:
  cni:
    namespace: istio-system
    enabled: true
profile: ambient
license:
  value: ${GLOO_MESH_LICENSE_KEY}
EOF
```

### istiod Configuration Explained

| Setting | Purpose |
|---------|---------|
| [`meshConfig.accessLogFile`](https://istio.io/latest/docs/tasks/observability/logs/access-log/) | Path for access logs. Set to `/dev/stdout` for container logging |
| [`profile: ambient`](https://istio.io/latest/docs/ambient/install/helm/) | Enables ambient mode with ztunnel defaults |
| [`pilot.cni.enabled`](https://istio.io/latest/docs/setup/additional-setup/cni/) | Enables CNI plugin for traffic interception |

### 2.5: Install Istio CNI

The [CNI plugin](https://istio.io/latest/docs/setup/additional-setup/cni/) intercepts pod traffic and redirects it to ztunnel.

**For GKE:**

```bash
helm upgrade --install istio-cni oci://${HELM_REPO}/cni \
  --namespace istio-system \
  --version "${ISTIO_IMAGE}" \
  --wait \
  -f - <<EOF
excludeNamespaces:
- istio-system
- kube-system
global:
  hub: ${ISTIO_HUB}
  tag: ${ISTIO_IMAGE}
  platform: gke
cni:
  cniBinDir: /home/kubernetes/bin
  cniConfDir: /etc/cni/net.d
profile: ambient
EOF
```

**For EKS/AKS/Other:**

```bash
helm upgrade --install istio-cni oci://${HELM_REPO}/cni \
  --namespace istio-system \
  --version "${ISTIO_IMAGE}" \
  --wait \
  -f - <<EOF
excludeNamespaces:
- istio-system
- kube-system
global:
  hub: ${ISTIO_HUB}
  tag: ${ISTIO_IMAGE}
cni:
  cniBinDir: /opt/cni/bin
  cniConfDir: /etc/cni/net.d
profile: ambient
EOF
```

### CNI Platform-Specific Paths

| Platform | `cniBinDir` | `cniConfDir` |
|----------|-------------|--------------|
| **GKE** | `/home/kubernetes/bin` | `/etc/cni/net.d` |
| **EKS** | `/opt/cni/bin` | `/etc/cni/net.d` |
| **AKS** | `/opt/cni/bin` | `/etc/cni/net.d` |
| **Kind/k3s** | `/opt/cni/bin` | `/etc/cni/net.d` |

### 2.6: Install ztunnel

Ztunnel is the per-node proxy that handles mTLS for all mesh traffic.

**For Upstream Istio:**

```bash
helm upgrade --install ztunnel oci://${HELM_REPO}/ztunnel \
  --namespace istio-system \
  --version "${ISTIO_IMAGE}" \
  --wait \
  -f - <<EOF
hub: ${ISTIO_HUB}
tag: ${ISTIO_IMAGE}
istioNamespace: istio-system
profile: ambient
EOF
```

**For Solo.io Distribution (with L7 telemetry):**

```bash
helm upgrade --install ztunnel oci://${HELM_REPO}/ztunnel \
  --namespace istio-system \
  --version "${ISTIO_IMAGE}" \
  --wait \
  -f - <<EOF
hub: ${ISTIO_HUB}
tag: ${ISTIO_IMAGE}
istioNamespace: istio-system
profile: ambient
env:
  L7_ENABLED: "true"
l7Telemetry:
  enabled: true
  metrics:
    enabled: true
  accessLog:
    enabled: true
    skipConnectionLog: false
EOF
```

> **Solo Enterprise Feature:** `L7_ENABLED` provides L7 visibility (HTTP method, path, status codes) without deploying waypoint proxies.

---

### Verify Istio Installation

Wait for all Istio components to be ready:

```bash
kubectl get pods -n istio-system
```

Expected pods:
- `istiod-*` - Running
- `istio-cni-node-*` (DaemonSet) - Running on each node
- `ztunnel-*` (DaemonSet) - Running on each node

---

## Step 3: Install Istio Ingress Gateway

**What this does:** Creates an Istio Gateway using the Kubernetes Gateway API. This provides north-south ingress for external traffic.

### 3.1: Create Ingress Namespace

```bash
kubectl create ns istio-ingress 2>/dev/null || true
```

### 3.2: Install Istio Gateway

```bash
helm upgrade --install istio-ingress oci://${HELM_REPO}/gateway \
  --namespace istio-ingress \
  --version "${ISTIO_IMAGE}" \
  --wait \
  -f - <<EOF
service:
  type: LoadBalancer
EOF
```

### 3.3: Create Gateway Resource

```bash
kubectl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: istio-ingressgateway
  namespace: istio-ingress
spec:
  gatewayClassName: istio
  listeners:
  - name: http
    port: 80
    protocol: HTTP
    allowedRoutes:
      namespaces:
        from: All
EOF
```

### 3.4: Wait for LoadBalancer IP

Cloud providers take 1-3 minutes to provision a LoadBalancer:

```bash
kubectl get svc -n istio-ingress istio-ingressgateway -w
```

Press `Ctrl+C` once you see an IP address in the `EXTERNAL-IP` column.

### 3.5: Export Gateway IP

```bash
export GATEWAY_IP=$(kubectl get svc -n istio-ingress istio-ingressgateway -o jsonpath="{.status.loadBalancer.ingress[0]['hostname','ip']}")
echo "Gateway IP: $GATEWAY_IP"
```

---

## Verify Setup

### Check GatewayClasses

```bash
kubectl get gatewayclasses
```

Expected output should include:
- `istio` - Istio Gateway
- `istio-waypoint` - Istio Waypoint proxies

### Check All Pods

```bash
kubectl get pods -n istio-system
kubectl get pods -n istio-ingress
```

All pods should be Running.

### Test Gateway

```bash
curl -s -o /dev/null -w "%{http_code}" http://${GATEWAY_IP}/
```

Expected: `404` (no routes configured yet - this confirms the gateway is working)

---

## Next Steps

Your environment is now ready for the workshop. Return to the [Ambient Mesh Workshop Guide](ambient-mesh.md) to continue with:

1. **Onboarding an Application** - Deploy Bookinfo and add it to the mesh
2. **Zero-Trust Security** - Verify mTLS encryption
3. **Observability** - View metrics and access logs
4. **Traffic Management** - Waypoints and canary routing

---

## Step 4: Install Gloo Platform (Optional)

**What this does:** Deploys [Solo.io's Gloo Platform](https://docs.solo.io/gloo-mesh-enterprise/main/), which provides:
- **[Unified UI](https://docs.solo.io/gloo-mesh-enterprise/main/observability/ui/)** - Visual dashboard for multi-cluster observability
- **[Insights Engine](https://docs.solo.io/gloo-mesh-enterprise/main/observability/insights/)** - Configuration analysis and recommendations
- **[Telemetry](https://docs.solo.io/gloo-mesh-enterprise/main/observability/telemetry/)** - Metrics collection and aggregation
- **[Distributed Tracing](https://docs.solo.io/gloo-mesh-enterprise/main/observability/traces/)** - Jaeger integration

**Prerequisites:** Requires `GLOO_MESH_LICENSE_KEY` to be set.

### 4.1: Add Helm Repository

```bash
helm repo add gloo-platform https://storage.googleapis.com/gloo-platform/helm-charts
helm repo update
```

### 4.2: Create Namespace

```bash
kubectl create ns gloo-mesh 2>/dev/null || true
```

### 4.3: Install Gloo Platform CRDs

```bash
helm upgrade -i gloo-platform-crds gloo-platform/gloo-platform-crds \
  -n gloo-mesh \
  --version ${GLOO_VERSION}
```

### 4.4: Create KubernetesCluster CR

```bash
kubectl apply -f - <<EOF
apiVersion: admin.gloo.solo.io/v2
kind: KubernetesCluster
metadata:
  name: cluster1
  namespace: gloo-mesh
spec:
  clusterDomain: cluster.local
EOF
```

### 4.5: Install Gloo Platform

```bash
helm upgrade -i gloo-platform gloo-platform/gloo-platform \
  -n gloo-mesh \
  --version ${GLOO_VERSION} \
  --set common.cluster=cluster1 \
  --set licensing.glooMeshLicenseKey=$GLOO_MESH_LICENSE_KEY \
  --set glooMgmtServer.enabled=true \
  --set glooUi.enabled=true \
  --set glooInsightsEngine.enabled=true \
  --set glooAgent.enabled=true \
  --set prometheus.enabled=true \
  --set telemetryGateway.enabled=true \
  --set telemetryCollector.enabled=true \
  --set jaeger.enabled=true \
  --set 'telemetryGatewayCustomization.pipelines.traces/jaeger.enabled=true' \
  --set 'telemetryCollectorCustomization.pipelines.traces/istio.enabled=true'
```

### Gloo Platform Components

| Component | Purpose |
|-----------|---------|
| `glooMgmtServer` | Central management server |
| `glooUi` | Web-based management console |
| `glooInsightsEngine` | Configuration analysis |
| `glooAgent` | Local cluster agent |
| `prometheus` | Metrics collection |
| `telemetryGateway` | Remote telemetry receiver |
| `telemetryCollector` | OpenTelemetry collector |
| `jaeger` | Distributed tracing backend |

### 4.6: Wait for Deployment

```bash
kubectl rollout status deployment/gloo-mesh-mgmt-server -n gloo-mesh --timeout=180s
```

### 4.7: Verify Installation

```bash
kubectl get pods -n gloo-mesh
```

All pods should be Running:
- `gloo-mesh-mgmt-server-*`
- `gloo-mesh-ui-*`
- `gloo-mesh-agent-*`
- `gloo-telemetry-*`
- `prometheus-*`
- `gloo-jaeger-*`

### 4.8: Access the UI

```bash
kubectl port-forward -n gloo-mesh svc/gloo-mesh-ui 8090:8090
```

Open http://localhost:8090 in your browser.

---

# Optional: Install Gloo Gateway

> This section covers Gloo Gateway v2, Solo.io's enterprise API gateway. It provides additional features like rate limiting, external auth, and advanced traffic policies.

## Prerequisites

Set the Gloo Gateway license key:

```bash
export GLOO_GATEWAY_LICENSE_KEY=<your-license-key>
```

## Install Gloo Gateway CRDs

```bash
helm upgrade -i --create-namespace --namespace gloo-system \
  --version 2.0.1 \
  gloo-gateway-crds oci://us-docker.pkg.dev/solo-public/gloo-gateway/charts/gloo-gateway-crds
```

## Install Gloo Gateway

```bash
helm upgrade -i -n gloo-system gloo-gateway \
  oci://us-docker.pkg.dev/solo-public/gloo-gateway/charts/gloo-gateway \
  --version 2.0.1 \
  --set licensing.glooGatewayLicenseKey=$GLOO_GATEWAY_LICENSE_KEY
```

| Helm Value | Purpose |
|------------|---------|
| [`licensing.glooGatewayLicenseKey`](https://docs.solo.io/gateway/2.0.x/reference/helm/gloo-gateway/#licensing) | Enterprise license key for Gloo Gateway features |

## Wait for Deployment

```bash
kubectl rollout status deployment/gloo-gateway -n gloo-system --timeout=120s
```

## Verify Installation

```bash
kubectl get pods -n gloo-system
```

You should see the `gloo-gateway-*` pod in Running state.

## Create Gloo Gateway

```bash
kubectl apply -f - <<EOF
kind: Gateway
apiVersion: gateway.networking.k8s.io/v1
metadata:
  name: gloo-gateway
  namespace: gloo-system
spec:
  gatewayClassName: gloo-gateway-v2
  listeners:
  - protocol: HTTP
    port: 80
    name: http
    allowedRoutes:
      namespaces:
        from: All
EOF
```

## Get Gloo Gateway IP

```bash
export GLOO_IP=$(kubectl get svc -n gloo-system gloo-gateway -o jsonpath="{.status.loadBalancer.ingress[0]['hostname','ip']}")
echo "Gloo Gateway IP: $GLOO_IP"
```

## Check GatewayClasses

```bash
kubectl get gatewayclasses
```

Expected output now includes:
- `gloo-gateway-v2` - Gloo Gateway
- `istio` - Istio Gateway
- `istio-waypoint` - Istio Waypoint proxies

---

## Troubleshooting

### Common Issues

#### LoadBalancer IP stuck at `<pending>`

**Cause:** Cloud provider limit or network configuration issue.

**Solution:** Check cloud provider quotas and VPC settings. On GKE, ensure the cluster has external access enabled.

#### Pods in CrashLoopBackOff

**Cause:** Usually missing secrets or configuration.

**Solution:**
1. Check pod logs: `kubectl logs <pod-name> -n <namespace>`
2. Verify license keys are set correctly (for Solo.io distribution)

#### Istio CNI pods not starting

**Cause:** Missing ResourceQuota on GKE.

**Solution:** Re-run step 2.2 to create the ResourceQuota.

#### ztunnel pods not starting

**Cause:** CNI not properly installed.

**Solution:** Verify CNI paths are correct for your platform (see CNI Platform-Specific Paths table).

---

## Reference Documentation

### Kubernetes Gateway API

| Resource | Documentation |
|----------|---------------|
| Gateway API Overview | [gateway-api.sigs.k8s.io](https://gateway-api.sigs.k8s.io/) |
| GatewayClass | [GatewayClass API Type](https://gateway-api.sigs.k8s.io/api-types/gatewayclass/) |
| Gateway | [Gateway API Type](https://gateway-api.sigs.k8s.io/api-types/gateway/) |
| HTTPRoute | [HTTPRoute API Type](https://gateway-api.sigs.k8s.io/api-types/httproute/) |

### Istio Ambient

| Resource | Documentation |
|----------|---------------|
| Ambient Overview | [istio.io/docs/ambient](https://istio.io/latest/docs/ambient/) |
| Helm Installation | [Install with Helm](https://istio.io/latest/docs/ambient/install/helm/) |
| DNS Proxying | [DNS Proxy Configuration](https://istio.io/latest/docs/ops/configuration/traffic-management/dns-proxy/) |

### Istio Helm Charts

| Chart | Helm Values Reference |
|-------|----------------------|
| istio-base | [base chart](https://artifacthub.io/packages/helm/istio-official/base) |
| istiod | [istiod chart](https://artifacthub.io/packages/helm/istio-official/istiod) |
| istio-cni | [cni chart](https://artifacthub.io/packages/helm/istio-official/cni) |
| ztunnel | [ztunnel chart](https://artifacthub.io/packages/helm/istio-official/ztunnel) |
| gateway | [gateway chart](https://artifacthub.io/packages/helm/istio-official/gateway) |

### Solo.io Gloo Platform

| Resource | Documentation |
|----------|---------------|
| Gloo Platform Overview | [docs.solo.io/gloo-mesh-enterprise](https://docs.solo.io/gloo-mesh-enterprise/main/) |
| Installation Guide | [Enterprise Installation](https://docs.solo.io/gloo-mesh-enterprise/main/setup/installation/enterprise_installation/) |
| Helm Values Reference | [Helm Overview](https://docs.solo.io/gloo-mesh/main/reference/helm/overview/) |
| UI Documentation | [Observability UI](https://docs.solo.io/gloo-mesh-enterprise/main/observability/ui/) |

### Solo.io Gloo Gateway

| Resource | Documentation |
|----------|---------------|
| Gloo Gateway Overview | [docs.solo.io/gateway](https://docs.solo.io/gateway/latest/) |
| Gloo Gateway v2 Helm | [Helm Reference](https://docs.solo.io/gateway/2.0.x/reference/helm/gloo-gateway/) |
