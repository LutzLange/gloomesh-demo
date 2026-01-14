# Omni Workshop Manual Setup Guide

This guide provides step-by-step manual setup instructions for the Omni Workshop environment. Each command is separated for easy copying and includes explanations of what it does and why.

> **Prefer automated setup?** Run `./scripts/setup.sh -c env.sh` instead. This guide is for users who want to understand each step in detail or need to troubleshoot specific components.

---

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [Environment Configuration](#environment-configuration)
3. [Step 1: Install Gateway API CRDs](#step-1-install-gateway-api-crds)
4. [Step 2: Install Gloo Gateway v2](#step-2-install-gloo-gateway-v2)
5. [Step 3: Create Gateway for Ingress](#step-3-create-gateway-for-ingress)
6. [Step 4: Configure Trust (Shared Root CA)](#step-4-configure-trust-shared-root-ca)
7. [Step 5: Install Istio Ambient](#step-5-install-istio-ambient)
8. [Step 6: Install Gloo Management Plane](#step-6-install-gloo-management-plane)
9. [Step 7: Register Cluster2](#step-7-register-cluster2-as-workload-cluster)
10. [Verify Setup](#verify-setup)

---

## Prerequisites

Before starting, ensure you have the following tools installed:

| Tool | Version | Purpose |
|------|---------|---------|
| `kubectl` | 1.28+ | Kubernetes CLI |
| `helm` | 3.x | Package manager for Kubernetes |
| `curl` | any | Download tools and test endpoints |
| `jq` | any | JSON processing (optional but helpful) |

You'll need access to two Kubernetes clusters. The workshop supports:
- **GKE** (Google Kubernetes Engine) - recommended
- **EKS** (Amazon Elastic Kubernetes Service)
- **Kind** or other local clusters (for testing only)

---

## Environment Configuration

### Create Your Configuration File

Create an `env.sh` file in the `omni/` directory with your cluster details:

```bash
cat > env.sh << 'EOF'
# Cluster kubectl contexts
export CLUSTER1=<your-cluster1-context>   # e.g., lutzl-cluster1
export CLUSTER2=<your-cluster2-context>   # e.g., lutzl-cluster2

# Component versions
export ISTIO_VERSION=1.28.1
export GLOO_VERSION=2.11.0

# License keys (obtain from Solo.io)
export GLOO_GATEWAY_LICENSE_KEY=<your-gateway-key>
export GLOO_MESH_LICENSE_KEY=<your-mesh-key>

# Solo istioctl path (will be set after installation)
export ISTIOCTL=/home/$USER/.istioctl/bin/istioctl
EOF
```

### Load the Environment

Source your configuration before running any commands:

```bash
source env.sh
```

### Verify Cluster Connectivity

Check that kubectl can connect to both clusters:

```bash
kubectl --context ${CLUSTER1} cluster-info
```

```bash
kubectl --context ${CLUSTER2} cluster-info
```

Both commands should show cluster endpoint information. If you see connection errors, verify your kubeconfig contexts are correct.

---

## Step 1: Install Gateway API CRDs

**What this does:** Installs the [Kubernetes Gateway API](https://gateway-api.sigs.k8s.io/) Custom Resource Definitions (CRDs). The Gateway API is the next-generation Kubernetes ingress specification, replacing the older Ingress resources with more expressive routing capabilities.

**Why this is needed:** Both Gloo Gateway and Istio Ambient use Gateway API for traffic management. The CRDs must be installed before any [Gateway](https://gateway-api.sigs.k8s.io/api-types/gateway/) or [HTTPRoute](https://gateway-api.sigs.k8s.io/api-types/httproute/) resources can be created.

**Why v1.4.0:** This version includes stable support for [GatewayClass](https://gateway-api.sigs.k8s.io/api-types/gatewayclass/), Gateway, and HTTPRoute resources. It also includes the HBONE protocol listener type used by Istio waypoints.

Install on **Cluster 1**:

```bash
kubectl --context ${CLUSTER1} apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.4.0/standard-install.yaml
```

Install on **Cluster 2**:

```bash
kubectl --context ${CLUSTER2} apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.4.0/standard-install.yaml
```

> **Note:** We install on both clusters because Cluster 2 will need Gateway API for east-west gateway configuration during multi-cluster peering.

### Verify CRD Installation

```bash
kubectl --context ${CLUSTER1} get crds | grep gateway
```

Expected output should include:
- `gateways.gateway.networking.k8s.io`
- `httproutes.gateway.networking.k8s.io`
- `gatewayclasses.gateway.networking.k8s.io`

---

## Step 2: Install Gloo Gateway v2

**What this does:** Deploys [Solo.io's Gloo Gateway v2](https://docs.solo.io/gateway/latest/), an enterprise API gateway built on Envoy proxy. It provides north-south ingress with advanced features like authentication, rate limiting, and traffic policies.

**Why Gloo Gateway v2:** Unlike traditional API gateways, Gloo Gateway is Kubernetes-native and uses the [Gateway API specification](https://gateway-api.sigs.k8s.io/). It integrates seamlessly with Istio service mesh for unified north-south and east-west traffic management.

### Install Gloo Gateway CRDs

First, install the [Custom Resource Definitions](https://docs.solo.io/gateway/2.0.x/reference/helm/gloo-gateway-crds/):

```bash
helm upgrade -i --create-namespace --namespace gloo-system \
  --kube-context ${CLUSTER1} \
  --version 2.0.1 \
  gloo-gateway-crds oci://us-docker.pkg.dev/solo-public/gloo-gateway/charts/gloo-gateway-crds
```

> **What [`helm upgrade -i`](https://helm.sh/docs/helm/helm_upgrade/) does:** The `-i` flag means "install if not present, upgrade if exists." This makes the command idempotent - safe to run multiple times.

### Install Gloo Gateway

Now install the [gateway controller](https://docs.solo.io/gateway/2.0.x/reference/helm/gloo-gateway/) itself:

```bash
helm upgrade -i -n gloo-system gloo-gateway \
  oci://us-docker.pkg.dev/solo-public/gloo-gateway/charts/gloo-gateway \
  --kube-context ${CLUSTER1} \
  --version 2.0.1 \
  --set licensing.glooGatewayLicenseKey=$GLOO_GATEWAY_LICENSE_KEY
```

| Helm Value | Purpose |
|------------|---------|
| [`licensing.glooGatewayLicenseKey`](https://docs.solo.io/gateway/2.0.x/reference/helm/gloo-gateway/#licensing) | Enterprise license key for Gloo Gateway features |

### Wait for Deployment

The gateway controller needs time to start. Wait for the deployment to be ready:

```bash
kubectl --context ${CLUSTER1} rollout status deployment/gloo-gateway -n gloo-system --timeout=120s
```

### Verify Installation

```bash
kubectl --context ${CLUSTER1} get pods -n gloo-system
```

You should see the `gloo-gateway-*` pod in Running state.

---

## Step 3: Create Gateway for Ingress

**What this does:** Creates a [Gateway resource](https://gateway-api.sigs.k8s.io/api-types/gateway/) that tells Gloo Gateway to provision a LoadBalancer service listening on port 80. This is your entry point for external traffic.

### Create the Gateway Resource

```bash
kubectl --context=${CLUSTER1} apply -f - <<EOF
kind: Gateway
apiVersion: gateway.networking.k8s.io/v1
metadata:
  name: http
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

### Configuration Explained

| Field | Value | Purpose |
|-------|-------|---------|
| [`gatewayClassName`](https://gateway-api.sigs.k8s.io/api-types/gatewayclass/) | `gloo-gateway-v2` | Selects Gloo Gateway as the controller for this Gateway |
| [`listeners[].protocol`](https://gateway-api.sigs.k8s.io/reference/spec/#gateway.networking.k8s.io/v1.ProtocolType) | `HTTP` | Protocol type. Options: `HTTP`, `HTTPS`, `TLS`, `TCP`, `UDP` |
| [`listeners[].port`](https://gateway-api.sigs.k8s.io/reference/spec/#gateway.networking.k8s.io/v1.Listener) | `80` | Port number exposed on the LoadBalancer |
| [`allowedRoutes.namespaces.from`](https://gateway-api.sigs.k8s.io/reference/spec/#gateway.networking.k8s.io/v1.AllowedRoutes) | `All` | Which namespaces can attach routes. Options: `All`, `Same`, `Selector` |

> ⚠️ **Security Note:** Setting `allowedRoutes.namespaces.from: All` allows any namespace to attach HTTPRoutes to this gateway. In production multi-tenant environments, consider using `Selector` with specific namespace labels to restrict access.

### Wait for LoadBalancer IP

Cloud providers take 1-3 minutes to provision a LoadBalancer. Wait for the external IP:

```bash
kubectl --context ${CLUSTER1} get svc -n gloo-system http -w
```

Press `Ctrl+C` once you see an IP address in the `EXTERNAL-IP` column. If you see `<pending>`, keep waiting.

### Export the Gateway IP

Once the IP is assigned, export it for use in later steps:

```bash
export GLOO_IP=$(kubectl get svc -n gloo-system http --context $CLUSTER1 -o jsonpath="{.status.loadBalancer.ingress[0]['hostname','ip']}")
echo "Gloo Gateway IP: $GLOO_IP"
```

> **Keep this terminal open** or re-run this export command in new terminals. The `GLOO_IP` variable is needed for testing.

---

## Step 4: Configure Trust (Shared Root CA)

**What this does:** Installs intermediate CA certificates on both clusters, all signed by the same root CA. This enables mTLS communication between services across clusters using [Istio's plug-in CA feature](https://istio.io/latest/docs/tasks/security/cert-management/plugin-ca-cert/).

**Why this matters:** For multi-cluster mTLS to work, all clusters must trust each other's certificates. By using a shared root CA with per-cluster intermediate CAs, we establish a common [trust domain](https://istio.io/latest/docs/reference/glossary/#trust-domain) while allowing each cluster to issue its own workload certificates.

> ⚠️ **Critical for Multi-Cluster:** If each cluster uses its own self-signed CA (the default), cross-cluster mTLS will fail with `CERTIFICATE_VERIFY_FAILED` errors. The shared root CA is **required** for multi-cluster communication.

### How the Certificates Were Generated

The certificates in `certs/` follow [Istio's plug-in CA guide](https://istio.io/latest/docs/tasks/security/cert-management/plugin-ca-cert/). The structure is:

```
Root CA (root-cert.pem) - Shared, kept offline
├── Cluster1 Intermediate CA (cluster1/ca-cert.pem)
│   └── Signs workload certificates for Cluster1
└── Cluster2 Intermediate CA (cluster2/ca-cert.pem)
    └── Signs workload certificates for Cluster2
```

To regenerate certificates (if needed):

```bash
# Generate root CA (do this once, keep secure)
make -f istio.io/tools/certs/Makefile.selfsigned.mk root-ca

# Generate intermediate CAs for each cluster
make -f istio.io/tools/certs/Makefile.selfsigned.mk cluster1-cacerts
make -f istio.io/tools/certs/Makefile.selfsigned.mk cluster2-cacerts
```

### Create Namespaces

First, create the required Istio namespaces on both clusters:

```bash
kubectl --context=${CLUSTER1} create ns istio-system 2>/dev/null || true
kubectl --context=${CLUSTER1} create ns istio-gateways 2>/dev/null || true
```

```bash
kubectl --context=${CLUSTER2} create ns istio-system 2>/dev/null || true
kubectl --context=${CLUSTER2} create ns istio-gateways 2>/dev/null || true
```

> **Note:** The `|| true` suffix prevents errors if the namespace already exists.

### Install Certificates on Cluster 1

The certificates are pre-generated in the `certs/` directory. Install the Cluster 1 intermediate CA as a Kubernetes secret named [`cacerts`](https://istio.io/latest/docs/tasks/security/cert-management/plugin-ca-cert/#plug-in-certificates-and-key-into-the-cluster):

```bash
kubectl --context=${CLUSTER1} create secret generic cacerts -n istio-system \
  --from-file=./certs/cluster1/ca-cert.pem \
  --from-file=./certs/cluster1/ca-key.pem \
  --from-file=./certs/cluster1/root-cert.pem \
  --from-file=./certs/cluster1/cert-chain.pem
```

| File | Purpose |
|------|---------|
| `ca-cert.pem` | Intermediate CA certificate for this cluster |
| `ca-key.pem` | Private key for the intermediate CA |
| `root-cert.pem` | Root CA certificate (same across all clusters) |
| `cert-chain.pem` | Full certificate chain from intermediate to root |

> **Important:** Run this command from the `omni/` directory where the `certs/` folder is located. The secret **must** be named `cacerts` - Istio looks for this specific name.

### Install Certificates on Cluster 2

Install the Cluster 2 intermediate CA:

```bash
kubectl --context=${CLUSTER2} create secret generic cacerts -n istio-system \
  --from-file=./certs/cluster2/ca-cert.pem \
  --from-file=./certs/cluster2/ca-key.pem \
  --from-file=./certs/cluster2/root-cert.pem \
  --from-file=./certs/cluster2/cert-chain.pem
```

---

## Step 5: Install Istio Ambient

**What this does:** Deploys [Istio Ambient Mesh](https://istio.io/latest/docs/ambient/) on both clusters. Ambient is Istio's sidecarless architecture that uses:
- **[ztunnel](https://istio.io/latest/docs/ambient/overview/#ztunnel):** A per-node proxy that handles L4 mTLS encryption for all pod traffic
- **[Waypoint proxies](https://istio.io/latest/docs/ambient/overview/#waypoint-proxies):** Optional L7 proxies for advanced traffic policies (deployed per-namespace)

**Why Ambient vs Sidecar:**
- **No sidecar overhead:** Up to 92% cost reduction vs traditional sidecars
- **No application restarts:** Add mesh capabilities with a namespace label
- **L7 when needed:** Waypoints provide L7 features only where required

### Set Istio Environment Variables

These variables configure the [Solo.io Istio distribution](https://docs.solo.io/gloo-mesh-enterprise/main/istio/):

```bash
export HELM_REPO="us-docker.pkg.dev/soloio-img/istio-helm"
export ISTIO_IMAGE="${ISTIO_VERSION}-solo"
export ISTIO_HUB="us-docker.pkg.dev/soloio-img/istio"
```

> **Why Solo.io distribution?** Solo's Istio includes enterprise features like L7 telemetry in ztunnel (without waypoints), FIPS-validated images, and 24/7 support. The `-solo` suffix identifies these builds. See the [Solo.io Istio documentation](https://docs.solo.io/gloo-mesh-enterprise/main/istio/manual/manual_deploy/).

---

### Install Istio on Cluster 1

The Istio installation involves four components. Each must be installed in order.

#### 5.1a: Get K8s API Server IP (Cluster 1)

Ztunnel needs to allow traffic to the Kubernetes API server to pass through without mTLS:

```bash
K8S_API_IP=$(kubectl --context ${CLUSTER1} get svc kubernetes -o jsonpath='{.spec.clusterIP}')
echo "Cluster 1 K8s API IP: $K8S_API_IP"
```

#### 5.1b: Create ResourceQuota for GKE (Cluster 1)

GKE requires a ResourceQuota for pods using system-critical PriorityClasses:

```bash
kubectl --context ${CLUSTER1} apply -f - <<EOF
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

> **Why this is needed:** On GKE, the istio-cni DaemonSet uses `system-node-critical` priority. Without this quota, pod creation fails.

#### 5.1c: Add Network Topology Label (Cluster 1)

Label the namespace for [multi-cluster network identification](https://istio.io/latest/docs/setup/install/multicluster/multi-primary_multi-network/):

```bash
kubectl --context ${CLUSTER1} label namespace istio-system topology.istio.io/network=cluster1 --overwrite
```

> **Why this label?** The [`topology.istio.io/network`](https://istio.io/latest/docs/reference/config/labels/) label tells Istio which network each cluster is on. Clusters on different networks communicate through east-west gateways instead of direct pod-to-pod connections.

#### 5.1d: Install Istio Base CRDs (Cluster 1)

```bash
helm upgrade --install istio-base oci://${HELM_REPO}/base \
  --namespace istio-system --kube-context ${CLUSTER1} \
  --version "${ISTIO_IMAGE}" \
  --set defaultRevision=default --set profile=ambient --wait
```

#### 5.1e: Install istiod Control Plane (Cluster 1)

This is the main Istio control plane. The configuration includes several important settings:

```bash
helm upgrade --install istiod oci://${HELM_REPO}/istiod \
  --namespace istio-system --kube-context ${CLUSTER1} \
  --version "${ISTIO_IMAGE}" --wait \
  -f - <<EOF
global:
  hub: ${ISTIO_HUB}
  tag: ${ISTIO_IMAGE}
  proxy:
    clusterDomain: cluster.local
  logAsJson: true
  network: cluster1
  meshID: mesh1
  multiCluster:
    clusterName: cluster1
meshConfig:
  accessLogFile: /dev/stdout
  rootNamespace: istio-system
  trustDomain: cluster.local
  serviceScopeConfigs:
  - scope: GLOBAL
    servicesSelector:
      matchExpressions:
      - key: istio.io/global
        operator: In
        values:
        - "true"
pilot:
  env:
    PILOT_ENABLE_AMBIENT: "true"
    PILOT_SKIP_VALIDATE_TRUST_DOMAIN: "true"
    AUTO_RELOAD_PLUGIN_CERTS: "true"
  cni:
    namespace: istio-system
    enabled: true
profile: ambient
license:
  value: ${GLOO_MESH_LICENSE_KEY}
platforms:
  peering:
    enabled: true
EOF
```

### istiod Configuration Deep Dive

| Setting | Purpose | If Changed |
|---------|---------|------------|
| [`global.network`](https://istio.io/latest/docs/setup/install/multicluster/multi-primary_multi-network/) | Unique network identifier | Clusters with different networks need east-west gateways |
| [`global.meshID`](https://istio.io/latest/docs/ops/deployment/deployment-models/#multiple-meshes) | Groups clusters into a logical mesh | All clusters sharing services **must** use the same meshID |
| [`multiCluster.clusterName`](https://istio.io/latest/docs/setup/install/multicluster/) | Unique cluster identifier | Used for service discovery and routing decisions |
| [`meshConfig.trustDomain`](https://istio.io/latest/docs/reference/glossary/#trust-domain) | [SPIFFE](https://spiffe.io/) trust domain for service identities | Affects mTLS certificate URIs (e.g., `spiffe://cluster.local/ns/default/sa/myapp`) |
| [`meshConfig.accessLogFile`](https://istio.io/latest/docs/tasks/observability/logs/access-log/) | Path for access logs | Set to `/dev/stdout` for container logging; remove for no logs |
| [`PILOT_ENABLE_AMBIENT`](https://istio.io/latest/docs/ambient/install/helm/) | Enables ambient mesh mode | Required for ztunnel-based mesh |
| [`PILOT_SKIP_VALIDATE_TRUST_DOMAIN`](https://istio.io/latest/docs/ops/common-problems/security-issues/) | Skips trust domain validation | Required when clusters have different trust configurations |
| [`AUTO_RELOAD_PLUGIN_CERTS`](https://istio.io/latest/docs/tasks/security/cert-management/plugin-ca-cert/) | Hot-reloads CA certificates | Allows cert rotation without istiod restart |
| [`serviceScopeConfigs`](https://docs.solo.io/gloo-mesh-enterprise/main/routing/global/) | Configures global service scope | Services labeled `istio.io/global=true` become multi-cluster addressable |
| [`platforms.peering.enabled`](https://docs.solo.io/gloo-mesh-enterprise/main/istio/) | Solo.io multi-cluster peering | Enables cross-cluster service discovery features |

> ⚠️ **If you change `meshID`:** All clusters in a multi-cluster mesh **must** share the same `meshID`. Using different values will prevent cross-cluster service discovery.

#### 5.1f: Install Istio CNI (Cluster 1)

The [CNI plugin](https://istio.io/latest/docs/setup/additional-setup/cni/) intercepts pod traffic and redirects it to ztunnel:

```bash
helm upgrade --install istio-cni oci://${HELM_REPO}/cni \
  --namespace istio-system --kube-context ${CLUSTER1} \
  --version "${ISTIO_IMAGE}" --wait \
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

### CNI Configuration Explained

| Setting | Purpose |
|---------|---------|
| [`excludeNamespaces`](https://istio.io/latest/docs/setup/additional-setup/cni/#excluding-namespaces) | Namespaces where CNI won't intercept traffic. `istio-system` is excluded to prevent circular dependencies; `kube-system` for system stability |
| [`global.platform`](https://istio.io/latest/docs/ambient/install/helm/) | Platform-specific configuration. Enables GKE-specific workarounds and paths |
| `cni.cniBinDir` / `cni.cniConfDir` | Platform-specific CNI paths (see table below) |

> **Note:** DNS capture (`ambient.dnsCapture`) is enabled by default in Istio 1.25+ for ambient mode. No explicit configuration needed.

**Platform-Specific CNI Paths:**

| Platform | `cniBinDir` | `cniConfDir` |
|----------|-------------|--------------|
| **GKE** | `/home/kubernetes/bin` | `/etc/cni/net.d` |
| **EKS** | `/opt/cni/bin` | `/etc/cni/net.d` |
| **AKS** | `/opt/cni/bin` | `/etc/cni/net.d` |
| **Kind/k3s** | `/opt/cni/bin` | `/etc/cni/net.d` |

#### 5.1g: Install ztunnel (Cluster 1)

Ztunnel is the per-node proxy that handles mTLS for all mesh traffic:

```bash
K8S_API_IP=$(kubectl --context ${CLUSTER1} get svc kubernetes -o jsonpath='{.spec.clusterIP}')

helm upgrade --install ztunnel oci://${HELM_REPO}/ztunnel \
  --namespace istio-system --kube-context ${CLUSTER1} \
  --version "${ISTIO_IMAGE}" --wait \
  -f - <<EOF
hub: ${ISTIO_HUB}
tag: ${ISTIO_IMAGE}
istioNamespace: istio-system
profile: ambient
network: cluster1
multiCluster:
  clusterName: cluster1
env:
  L7_ENABLED: "true"
l7Telemetry:
  enabled: true
  metrics:
    enabled: true
  accessLog:
    enabled: true
    skipConnectionLog: false
  distributedTracing:
    enabled: true
    otlpEndpoint: "http://gloo-telemetry-collector.gloo-mesh:4317"
egressPolicies:
  - matchCidrs:
    - ${K8S_API_IP}/32
    - 10.0.0.0/8
    - 172.16.0.0/12
    policy: Passthrough
  - matchCidrs:
    - 0.0.0.0/0
    - ::/0
    policy: Passthrough
EOF
```

### ztunnel Configuration Deep Dive

| Setting | Purpose |
|---------|---------|
| [`L7_ENABLED`](https://docs.solo.io/gloo-mesh-enterprise/main/observability/) | **Solo Enterprise feature:** Enables L7 visibility (HTTP method, path, status) without deploying waypoint proxies |
| [`l7Telemetry.enabled`](https://docs.solo.io/gloo-mesh-enterprise/main/observability/telemetry/) | Enables metrics, access logs, and distributed tracing from ztunnel |
| [`l7Telemetry.distributedTracing.otlpEndpoint`](https://docs.solo.io/gloo-mesh-enterprise/main/observability/traces/) | OTLP endpoint for traces. Points to Gloo Platform's telemetry collector (installed in Step 6) |
| [`egressPolicies`](https://istio.io/latest/docs/ambient/usage/waypoint/#traffic-not-through-waypoints) | Controls which traffic bypasses mTLS encryption |

### Understanding egressPolicies

The [`egressPolicies`](https://artifacthub.io/packages/helm/istio-official/ztunnel) configuration tells ztunnel which traffic should **not** be intercepted for mTLS:

```yaml
egressPolicies:
  - matchCidrs:
    - ${K8S_API_IP}/32    # Kubernetes API server
    - 10.0.0.0/8          # RFC1918 private networks (pods, services)
    - 172.16.0.0/12       # RFC1918 private networks
    policy: Passthrough
  - matchCidrs:
    - 0.0.0.0/0           # All other IPv4 traffic
    - ::/0                # All IPv6 traffic
    policy: Passthrough
```

| CIDR | Why Passthrough |
|------|-----------------|
| `${K8S_API_IP}/32` | Kubernetes API server must be accessible without mTLS for controller communication |
| `10.0.0.0/8` | Internal pod/service network traffic (varies by cluster setup) |
| `172.16.0.0/12` | Additional private network ranges used by some clusters |
| `0.0.0.0/0` | Default passthrough for traffic not explicitly handled (external egress) |

> ⚠️ **Note:** The `otlpEndpoint` points to `gloo-telemetry-collector.gloo-mesh:4317` which won't exist until Gloo Platform is installed in Step 6. Traces will be dropped until then, but this is expected.

---

### Install Istio on Cluster 2

Repeat the installation for Cluster 2 with the appropriate cluster name.

#### 5.2a: Get K8s API Server IP (Cluster 2)

```bash
K8S_API_IP=$(kubectl --context ${CLUSTER2} get svc kubernetes -o jsonpath='{.spec.clusterIP}')
echo "Cluster 2 K8s API IP: $K8S_API_IP"
```

#### 5.2b: Create ResourceQuota for GKE (Cluster 2)

```bash
kubectl --context ${CLUSTER2} apply -f - <<EOF
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

#### 5.2c: Add Network Topology Label (Cluster 2)

```bash
kubectl --context ${CLUSTER2} label namespace istio-system topology.istio.io/network=cluster2 --overwrite
```

#### 5.2d: Install Istio Base CRDs (Cluster 2)

```bash
helm upgrade --install istio-base oci://${HELM_REPO}/base \
  --namespace istio-system --kube-context ${CLUSTER2} \
  --version "${ISTIO_IMAGE}" \
  --set defaultRevision=default --set profile=ambient --wait
```

#### 5.2e: Install istiod Control Plane (Cluster 2)

```bash
helm upgrade --install istiod oci://${HELM_REPO}/istiod \
  --namespace istio-system --kube-context ${CLUSTER2} \
  --version "${ISTIO_IMAGE}" --wait \
  -f - <<EOF
global:
  hub: ${ISTIO_HUB}
  tag: ${ISTIO_IMAGE}
  proxy:
    clusterDomain: cluster.local
  logAsJson: true
  network: cluster2
  meshID: mesh1
  multiCluster:
    clusterName: cluster2
meshConfig:
  accessLogFile: /dev/stdout
  rootNamespace: istio-system
  trustDomain: cluster.local
  serviceScopeConfigs:
  - scope: GLOBAL
    servicesSelector:
      matchExpressions:
      - key: istio.io/global
        operator: In
        values:
        - "true"
pilot:
  env:
    PILOT_ENABLE_AMBIENT: "true"
    PILOT_SKIP_VALIDATE_TRUST_DOMAIN: "true"
    AUTO_RELOAD_PLUGIN_CERTS: "true"
  cni:
    namespace: istio-system
    enabled: true
profile: ambient
license:
  value: ${GLOO_MESH_LICENSE_KEY}
platforms:
  peering:
    enabled: true
EOF
```

#### 5.2f: Install Istio CNI (Cluster 2)

```bash
helm upgrade --install istio-cni oci://${HELM_REPO}/cni \
  --namespace istio-system --kube-context ${CLUSTER2} \
  --version "${ISTIO_IMAGE}" --wait \
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

#### 5.2g: Install ztunnel (Cluster 2)

```bash
K8S_API_IP=$(kubectl --context ${CLUSTER2} get svc kubernetes -o jsonpath='{.spec.clusterIP}')

helm upgrade --install ztunnel oci://${HELM_REPO}/ztunnel \
  --namespace istio-system --kube-context ${CLUSTER2} \
  --version "${ISTIO_IMAGE}" --wait \
  -f - <<EOF
hub: ${ISTIO_HUB}
tag: ${ISTIO_IMAGE}
istioNamespace: istio-system
profile: ambient
network: cluster2
multiCluster:
  clusterName: cluster2
env:
  L7_ENABLED: "true"
l7Telemetry:
  enabled: true
  metrics:
    enabled: true
  accessLog:
    enabled: true
    skipConnectionLog: false
  distributedTracing:
    enabled: true
    otlpEndpoint: "http://gloo-telemetry-collector.gloo-mesh:4317"
egressPolicies:
  - matchCidrs:
    - ${K8S_API_IP}/32
    - 10.0.0.0/8
    - 172.16.0.0/12
    policy: Passthrough
  - matchCidrs:
    - 0.0.0.0/0
    - ::/0
    policy: Passthrough
EOF
```

---

### Verify Istio Installation

Wait for all Istio components to be ready on both clusters:

```bash
kubectl --context ${CLUSTER1} get pods -n istio-system
```

```bash
kubectl --context ${CLUSTER2} get pods -n istio-system
```

Expected pods on each cluster:
- `istiod-*` - Running
- `istio-cni-node-*` (DaemonSet) - Running on each node
- `ztunnel-*` (DaemonSet) - Running on each node

> **Wait here** until all pods are Running before proceeding. This typically takes 2-3 minutes.

---

## Step 6: Install Gloo Management Plane

**What this does:** Deploys [Solo.io's Gloo Platform](https://docs.solo.io/gloo-mesh-enterprise/main/), which provides:
- **[Unified UI](https://docs.solo.io/gloo-mesh-enterprise/main/observability/ui/)** for multi-cluster observability
- **[Insights Engine](https://docs.solo.io/gloo-mesh-enterprise/main/observability/insights/)** for configuration analysis
- **[Telemetry](https://docs.solo.io/gloo-mesh-enterprise/main/observability/telemetry/)** collection and aggregation
- **[Distributed tracing](https://docs.solo.io/gloo-mesh-enterprise/main/observability/traces/)** with Jaeger

**Why Gloo Platform:** While Istio handles the data plane (traffic), Gloo Platform provides the management plane - unified visibility, configuration insights, and enterprise features across all your clusters.

### Add Helm Repository

```bash
helm repo add gloo-platform https://storage.googleapis.com/gloo-platform/helm-charts
helm repo update
```

### Adopt Existing CRDs

If Gloo Gateway was installed first, we need to transfer CRD ownership to Gloo Platform:

```bash
kubectl --context ${CLUSTER1} annotate crd authconfigs.extauth.solo.io \
  meta.helm.sh/release-name=gloo-platform-crds \
  meta.helm.sh/release-namespace=gloo-mesh \
  --overwrite
```

> **Why this annotation?** Helm tracks which release "owns" each resource. This annotation prevents conflicts when both Gloo Gateway and Gloo Platform want to manage the same CRD.

### Install Gloo Platform CRDs

```bash
helm upgrade -i gloo-platform-crds gloo-platform/gloo-platform-crds \
  -n gloo-mesh \
  --kube-context ${CLUSTER1} \
  --create-namespace \
  --version ${GLOO_VERSION}
```

### Create KubernetesCluster CR

Create the cluster registration resource **before** installing the platform. This prevents the agent from crash-looping while waiting for registration:

```bash
kubectl --context ${CLUSTER1} apply -f - <<EOF
apiVersion: admin.gloo.solo.io/v2
kind: KubernetesCluster
metadata:
  name: cluster1
  namespace: gloo-mesh
spec:
  clusterDomain: cluster.local
EOF
```

### Install Gloo Platform

This is a large installation with many components. The configuration enables:

```bash
helm upgrade -i gloo-platform gloo-platform/gloo-platform \
  -n gloo-mesh \
  --kube-context ${CLUSTER1} \
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

| Component | Purpose | Documentation |
|-----------|---------|---------------|
| [`glooMgmtServer`](https://docs.solo.io/gloo-mesh-enterprise/main/setup/installation/enterprise_installation/) | Central management server for all clusters | Coordinates configuration and policy across clusters |
| [`glooUi`](https://docs.solo.io/gloo-mesh-enterprise/main/observability/ui/) | Web-based management console | Visual dashboard at `http://localhost:8090` |
| [`glooInsightsEngine`](https://docs.solo.io/gloo-mesh-enterprise/main/observability/insights/) | Configuration analysis | Detects misconfigurations, security issues, best practice violations |
| [`glooAgent`](https://docs.solo.io/gloo-mesh-enterprise/main/setup/installation/enterprise_installation/) | Per-cluster agent | Reports to mgmt server, applies policies locally |
| [`prometheus`](https://docs.solo.io/gloo-mesh-enterprise/main/observability/metrics/) | Metrics collection | Scrapes Istio and application metrics |
| [`telemetryGateway`](https://docs.solo.io/gloo-mesh-enterprise/main/observability/telemetry/) | Remote telemetry receiver | Accepts traces/metrics from workload clusters |
| [`telemetryCollector`](https://docs.solo.io/gloo-mesh-enterprise/main/observability/telemetry/) | Telemetry aggregation | OpenTelemetry collector for traces and metrics |
| [`jaeger`](https://docs.solo.io/gloo-mesh-enterprise/main/observability/traces/) | Distributed tracing backend | View traces at UI → Tracing tab |

### Telemetry Pipeline Configuration

The Helm values include custom telemetry pipelines:

| Setting | Purpose |
|---------|---------|
| `telemetryGatewayCustomization.pipelines.traces/jaeger.enabled` | Routes incoming traces to Jaeger backend |
| `telemetryCollectorCustomization.pipelines.traces/istio.enabled` | Collects Istio-specific trace data |

### Wait for Gloo Platform

The management server takes longer to start due to its dependencies:

```bash
kubectl --context ${CLUSTER1} rollout status deployment/gloo-mesh-mgmt-server -n gloo-mesh --timeout=180s
```

### Verify Gloo Platform Installation

```bash
kubectl --context ${CLUSTER1} get pods -n gloo-mesh
```

Wait until all pods are Running. Key pods:
- `gloo-mesh-mgmt-server-*`
- `gloo-mesh-ui-*`
- `gloo-mesh-agent-*`
- `gloo-telemetry-collector-*`
- `gloo-jaeger-*`
- `prometheus-*`

---

## Step 7: Register Cluster2 as Workload Cluster

**What this does:** Registers Cluster 2 with the Gloo Platform management plane on Cluster 1 using [`meshctl cluster register`](https://docs.solo.io/gloo-mesh-enterprise/main/reference/cli/meshctl_cluster_register/). This enables:
- Unified visibility across both clusters
- Telemetry aggregation from Cluster 2
- Policy synchronization

**Why meshctl:** While manual Helm installation is possible, `meshctl` handles all the TLS certificate setup automatically, which is error-prone to do manually. See the [full CLI reference](https://docs.solo.io/gloo-mesh-enterprise/main/reference/cli/meshctl/).

### Get Telemetry Gateway Address

The telemetry gateway receives traces and metrics from remote clusters:

```bash
export TELEMETRY_GATEWAY_ADDRESS=$(kubectl get svc -n gloo-mesh gloo-telemetry-gateway --context $CLUSTER1 -o jsonpath="{.status.loadBalancer.ingress[0]['hostname','ip']}"):4317
echo "Telemetry Gateway: $TELEMETRY_GATEWAY_ADDRESS"
```

> **Wait** if you see an empty address. The LoadBalancer may take 1-2 minutes to provision.

### Install meshctl CLI

If you don't already have meshctl installed:

```bash
curl -sL https://run.solo.io/meshctl/install | GLOO_MESH_VERSION=v${GLOO_VERSION} sh -
export PATH=$HOME/.gloo-mesh/bin:$PATH
```

### Register Cluster 2

This command:
1. Creates a [KubernetesCluster CR](https://docs.solo.io/gloo-mesh-enterprise/main/reference/api/kubernetes_cluster/) on Cluster 1
2. Installs gloo-platform-crds and gloo-platform charts on Cluster 2
3. Configures TLS certificates for secure relay communication

```bash
meshctl cluster register cluster2 \
  --kubecontext $CLUSTER1 \
  --profiles gloo-mesh-agent \
  --remote-context $CLUSTER2 \
  --telemetry-server-address $TELEMETRY_GATEWAY_ADDRESS
```

### meshctl register Flags Explained

| Flag | Purpose |
|------|---------|
| [`--kubecontext`](https://docs.solo.io/gloo-mesh-enterprise/main/reference/cli/meshctl_cluster_register/) | Context of the **management cluster** (where KubernetesCluster CR is created) |
| [`--remote-context`](https://docs.solo.io/gloo-mesh-enterprise/main/reference/cli/meshctl_cluster_register/) | Context of the **workload cluster** being registered |
| [`--profiles`](https://docs.solo.io/gloo-mesh-enterprise/main/reference/cli/meshctl_cluster_register/) | Helm profiles to install. `gloo-mesh-agent` installs only the agent (no mgmt server) |
| [`--telemetry-server-address`](https://docs.solo.io/gloo-mesh-enterprise/main/reference/cli/meshctl_cluster_register/) | Address of telemetry gateway for trace/metric collection |

> **What happens behind the scenes:** meshctl copies the root CA and bootstrap token from the management cluster, then installs the Gloo agent on the workload cluster. The agent uses mTLS to securely communicate with the management server.

### Wait for Agent Connection

Give the agent time to connect to the management server:

```bash
sleep 30
```

### Verify Registration

Check that both clusters are registered and accepted:

```bash
kubectl --context ${CLUSTER1} get kubernetesclusters -n gloo-mesh
```

Expected output:
```
NAME       AGE
cluster1   10m
cluster2   1m
```

Both should show `ACCEPTED` status after a few moments.

---

## Verify Setup

### Check All Components

Run these commands to verify the complete installation:

#### Gloo Gateway (Cluster 1)

```bash
kubectl --context ${CLUSTER1} get pods -n gloo-system
```

#### Gloo Platform (Cluster 1)

```bash
kubectl --context ${CLUSTER1} get pods -n gloo-mesh
```

#### Istio (Cluster 1)

```bash
kubectl --context ${CLUSTER1} get pods -n istio-system
```

#### Gloo Platform Agent (Cluster 2)

```bash
kubectl --context ${CLUSTER2} get pods -n gloo-mesh
```

#### Istio (Cluster 2)

```bash
kubectl --context ${CLUSTER2} get pods -n istio-system
```

### Check Cluster Registration

```bash
kubectl --context ${CLUSTER1} get kubernetesclusters -n gloo-mesh
```

### Check GatewayClasses

```bash
kubectl --context ${CLUSTER1} get gatewayclasses
```

Expected output should include:
- `gloo-gateway-v2` - Gloo Gateway
- `istio` - Istio Gateway
- `istio-waypoint` - Istio Waypoint proxies
- `istio-eastwest` - Istio East-West gateways

### Access the Management UI

```bash
kubectl --context ${CLUSTER1} port-forward -n gloo-mesh svc/gloo-mesh-ui 8090:8090
```

Open http://localhost:8090 in your browser.

---

## Next Steps

Your environment is now ready for the workshop demo. Return to the [Omni Demo Guide](omni.md) to continue with:

1. **Onboarding an Application** - Deploy Bookinfo and add it to the mesh
2. **Zero-Trust Security** - Verify mTLS and peer the clusters
3. **Observability** - Explore the Gloo UI and distributed tracing
4. **Global Services** - Configure multi-cluster failover
5. **Traffic Policies** - Implement canary routing and rate limiting

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
2. Verify license keys are set correctly
3. Ensure certificates were created in step 4

#### meshctl cluster register fails

**Cause:** Network connectivity or TLS issues.

**Solution:**
1. Verify telemetry gateway IP is accessible from Cluster 2
2. Check that both clusters can reach each other
3. Try deleting and re-creating: `meshctl cluster deregister cluster2 ...`

#### Istio pods not starting

**Cause:** Missing ResourceQuota on GKE.

**Solution:** Re-run step 5.1b/5.2b to create the ResourceQuota.

---

## Reference Documentation

Quick links to upstream documentation for all components used in this workshop.

### Kubernetes Gateway API

| Resource | Documentation |
|----------|---------------|
| Gateway API Overview | [gateway-api.sigs.k8s.io](https://gateway-api.sigs.k8s.io/) |
| GatewayClass | [GatewayClass API Type](https://gateway-api.sigs.k8s.io/api-types/gatewayclass/) |
| Gateway | [Gateway API Type](https://gateway-api.sigs.k8s.io/api-types/gateway/) |
| HTTPRoute | [HTTPRoute API Type](https://gateway-api.sigs.k8s.io/api-types/httproute/) |
| API Spec Reference | [Full Spec](https://gateway-api.sigs.k8s.io/reference/spec/) |

### Istio Ambient

| Resource | Documentation |
|----------|---------------|
| Ambient Overview | [istio.io/docs/ambient](https://istio.io/latest/docs/ambient/) |
| Helm Installation | [Install with Helm](https://istio.io/latest/docs/ambient/install/helm/) |
| Multi-Cluster Setup | [Multi-Primary Different Networks](https://istio.io/latest/docs/setup/install/multicluster/multi-primary_multi-network/) |
| Plug-in CA Certificates | [Certificate Management](https://istio.io/latest/docs/tasks/security/cert-management/plugin-ca-cert/) |
| DNS Proxying | [DNS Proxy Configuration](https://istio.io/latest/docs/ops/configuration/traffic-management/dns-proxy/) |
| Trust Domain | [Glossary: Trust Domain](https://istio.io/latest/docs/reference/glossary/#trust-domain) |

### Istio Helm Charts (Artifact Hub)

| Chart | Helm Values Reference |
|-------|----------------------|
| istio-base | [base chart](https://artifacthub.io/packages/helm/istio-official/base) |
| istiod | [istiod chart](https://artifacthub.io/packages/helm/istio-official/istiod) |
| istio-cni | [cni chart](https://artifacthub.io/packages/helm/istio-official/cni) |
| ztunnel | [ztunnel chart](https://artifacthub.io/packages/helm/istio-official/ztunnel) |

### Solo.io Gloo Gateway

| Resource | Documentation |
|----------|---------------|
| Gloo Gateway Overview | [docs.solo.io/gateway](https://docs.solo.io/gateway/latest/) |
| Gloo Gateway v2 Helm | [Helm Reference](https://docs.solo.io/gateway/2.0.x/reference/helm/gloo-gateway/) |
| Gloo Gateway CRDs Helm | [CRDs Helm Reference](https://docs.solo.io/gateway/2.0.x/reference/helm/gloo-gateway-crds/) |

### Solo.io Gloo Platform

| Resource | Documentation |
|----------|---------------|
| Gloo Platform Overview | [docs.solo.io/gloo-mesh-enterprise](https://docs.solo.io/gloo-mesh-enterprise/main/) |
| Installation Guide | [Enterprise Installation](https://docs.solo.io/gloo-mesh-enterprise/main/setup/installation/enterprise_installation/) |
| Helm Values Reference | [Helm Overview](https://docs.solo.io/gloo-mesh/main/reference/helm/overview/) |
| meshctl CLI Reference | [meshctl](https://docs.solo.io/gloo-mesh-enterprise/main/reference/cli/meshctl/) |
| meshctl cluster register | [cluster register](https://docs.solo.io/gloo-mesh-enterprise/main/reference/cli/meshctl_cluster_register/) |

### Solo.io Istio Distribution

| Resource | Documentation |
|----------|---------------|
| Solo Istio Overview | [Istio Documentation](https://docs.solo.io/gloo-mesh-enterprise/main/istio/) |
| Manual Istio Deploy | [Manual Deployment](https://docs.solo.io/gloo-mesh-enterprise/main/istio/manual/manual_deploy/) |
| L7 Telemetry | [Observability](https://docs.solo.io/gloo-mesh-enterprise/main/observability/)
