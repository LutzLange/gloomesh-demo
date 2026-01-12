#!/bin/bash
set -e

# Omni Demo Environment Setup Script
# This script sets up the environment for the Gloo Platform + Ambient Mesh demo
#
# Usage:
#   ./setup.sh -c /path/to/env.sh        # load config from file
#   source /path/to/env.sh && ./setup.sh # use environment variables
#
# Prerequisites:
# - helm 3.x installed
# - Either: existing clusters with kubectl contexts configured (bring your own)
# - Or: gcloud CLI configured + GKE_ZONE1/GKE_ZONE2 set (auto-create GKE clusters)
#
# Required variables:
#   CLUSTER1, CLUSTER2, GLOO_GATEWAY_LICENSE_KEY, GLOO_MESH_LICENSE_KEY
#
# Optional variables (for GKE cluster creation):
#   GKE_ZONE1, GKE_ZONE2

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

#######################################
# Logging Functions
#######################################

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()    { echo -e "\n${GREEN}==>${NC} ${YELLOW}$1${NC}"; }

#######################################
# Helper Functions
#######################################

usage() {
    echo "Usage: $0 [-c config_file] [--create-clusters] [-h]"
    echo ""
    echo "Options:"
    echo "  -c, --config FILE     Load configuration from FILE"
    echo "  --create-clusters     Create GKE clusters if they don't exist (requires GKE_ZONE1/GKE_ZONE2)"
    echo "  -h, --help            Show this help message"
    echo ""
    echo "Required variables (from config file or environment):"
    echo "  CLUSTER1, CLUSTER2, GLOO_GATEWAY_LICENSE_KEY, GLOO_MESH_LICENSE_KEY"
    echo ""
    echo "Optional variables (only with --create-clusters):"
    echo "  GKE_ZONE1, GKE_ZONE2"
    exit 0
}

load_config() {
    local config_file=$1

    if [[ ! -f "$config_file" ]]; then
        log_error "Config file not found: $config_file"
        exit 1
    fi

    source "$config_file"
    log_info "Loaded config from: $config_file"
}

set_defaults() {
    # Set defaults for optional variables
    export GLOO_VERSION="${GLOO_VERSION:-2.11.0}"
    export ISTIO_VERSION="${ISTIO_VERSION:-1.28.1}"
    export GATEWAY_API_VERSION="${GATEWAY_API_VERSION:-v1.4.0}"
    export GLOO_GATEWAY_VERSION="${GLOO_GATEWAY_VERSION:-2.0.1}"
    # Note: GKE_ZONE1/GKE_ZONE2 are optional - only needed if clusters need to be created
}

validate_environment() {
    local missing=()

    # Always required
    [[ -z "${CLUSTER1:-}" ]] && missing+=("CLUSTER1")
    [[ -z "${CLUSTER2:-}" ]] && missing+=("CLUSTER2")
    [[ -z "${GLOO_GATEWAY_LICENSE_KEY:-}" ]] && missing+=("GLOO_GATEWAY_LICENSE_KEY")
    [[ -z "${GLOO_MESH_LICENSE_KEY:-}" ]] && missing+=("GLOO_MESH_LICENSE_KEY")

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required variables: ${missing[*]}"
        log_error "Use -c to specify a config file or source your env.sh first"
        exit 1
    fi

    log_info "Environment validated"
}

validate_clusters() {
    local create_clusters=${1:-false}

    # Check cluster connectivity
    local cluster1_ok=false
    local cluster2_ok=false

    if kubectl --context "$CLUSTER1" cluster-info > /dev/null 2>&1; then
        cluster1_ok=true
        log_info "Cluster $CLUSTER1 is reachable"
    else
        log_warn "Cannot connect to $CLUSTER1"
    fi

    if kubectl --context "$CLUSTER2" cluster-info > /dev/null 2>&1; then
        cluster2_ok=true
        log_info "Cluster $CLUSTER2 is reachable"
    else
        log_warn "Cannot connect to $CLUSTER2"
    fi

    # If both clusters are reachable, we're done
    if [[ "$cluster1_ok" == "true" && "$cluster2_ok" == "true" ]]; then
        log_success "Using existing clusters"
        return 0
    fi

    # Clusters not reachable
    if [[ "$create_clusters" != "true" ]]; then
        log_error "Clusters not reachable"
        log_error ""
        log_error "Options:"
        log_error "  1. Configure kubectl contexts '$CLUSTER1' and '$CLUSTER2' for your existing clusters"
        log_error "  2. Use --create-clusters flag to create GKE clusters automatically"
        exit 1
    fi

    # Create clusters requested - check for required zone config
    if [[ -z "${GKE_ZONE1:-}" || -z "${GKE_ZONE2:-}" ]]; then
        log_error "--create-clusters requires GKE_ZONE1 and GKE_ZONE2 to be set"
        exit 1
    fi

    log_info "Creating GKE clusters..."
    create_gke_clusters

    # Verify connectivity after creation
    kubectl --context "$CLUSTER1" cluster-info > /dev/null 2>&1 || { log_error "Cannot connect to $CLUSTER1"; exit 1; }
    kubectl --context "$CLUSTER2" cluster-info > /dev/null 2>&1 || { log_error "Cannot connect to $CLUSTER2"; exit 1; }

    log_success "GKE clusters created"
}

create_gke_clusters() {
    log_step "Creating GKE Clusters"

    # Get GCP project
    local PROJECT
    PROJECT="$(gcloud config get-value project 2>/dev/null)"

    if [[ -z "$PROJECT" ]]; then
        log_error "No active gcloud project set. Run: gcloud config set project <PROJECT_ID>"
        exit 1
    fi

    log_info "Using GCP project: $PROJECT"
    log_info "Creating clusters: $CLUSTER1 ($GKE_ZONE1), $CLUSTER2 ($GKE_ZONE2)"

    # Create Cluster 1 (mgmt + workload) if it doesn't exist
    if ! gcloud container clusters describe "$CLUSTER1" --zone "$GKE_ZONE1" --project "$PROJECT" > /dev/null 2>&1; then
        log_info "Creating $CLUSTER1..."
        gcloud container clusters create "$CLUSTER1" \
            --zone "$GKE_ZONE1" \
            --num-nodes 3 \
            --machine-type e2-standard-4 \
            --enable-ip-alias \
            --workload-pool="${PROJECT}.svc.id.goog" \
            --network default
    else
        log_info "$CLUSTER1 already exists"
    fi

    # Create Cluster 2 (workload only) if it doesn't exist
    if ! gcloud container clusters describe "$CLUSTER2" --zone "$GKE_ZONE2" --project "$PROJECT" > /dev/null 2>&1; then
        log_info "Creating $CLUSTER2..."
        gcloud container clusters create "$CLUSTER2" \
            --zone "$GKE_ZONE2" \
            --num-nodes 2 \
            --machine-type e2-standard-4 \
            --enable-ip-alias \
            --workload-pool="${PROJECT}.svc.id.goog" \
            --network default
    else
        log_info "$CLUSTER2 already exists"
    fi

    # Fetch credentials
    log_info "Fetching cluster credentials..."
    gcloud container clusters get-credentials "$CLUSTER1" --zone "$GKE_ZONE1" --project "$PROJECT"
    gcloud container clusters get-credentials "$CLUSTER2" --zone "$GKE_ZONE2" --project "$PROJECT"

    # Rename kubeconfig contexts
    local OLD_CTX1="gke_${PROJECT}_${GKE_ZONE1}_${CLUSTER1}"
    local OLD_CTX2="gke_${PROJECT}_${GKE_ZONE2}_${CLUSTER2}"

    # Clean up existing target contexts first
    kubectl config delete-context "$CLUSTER1" 2>/dev/null || true
    kubectl config delete-context "$CLUSTER2" 2>/dev/null || true

    if kubectl config get-contexts "$OLD_CTX1" > /dev/null 2>&1; then
        kubectl config rename-context "$OLD_CTX1" "$CLUSTER1"
        log_info "Renamed context to $CLUSTER1"
    fi

    if kubectl config get-contexts "$OLD_CTX2" > /dev/null 2>&1; then
        kubectl config rename-context "$OLD_CTX2" "$CLUSTER2"
        log_info "Renamed context to $CLUSTER2"
    fi

    log_success "GKE clusters created and configured"
}

print_config() {
    log_info "Configuration:"
    if [[ -n "${GKE_ZONE1:-}" ]]; then
        log_info "  CLUSTER1: $CLUSTER1 (GKE zone: $GKE_ZONE1)"
    else
        log_info "  CLUSTER1: $CLUSTER1"
    fi
    if [[ -n "${GKE_ZONE2:-}" ]]; then
        log_info "  CLUSTER2: $CLUSTER2 (GKE zone: $GKE_ZONE2)"
    else
        log_info "  CLUSTER2: $CLUSTER2"
    fi
    log_info "  GLOO_VERSION: $GLOO_VERSION"
    log_info "  ISTIO_VERSION: $ISTIO_VERSION"
    log_info "  GLOO_GATEWAY_VERSION: $GLOO_GATEWAY_VERSION"
}

wait_for_deployment() {
    local context=$1
    local namespace=$2
    local deployment=$3
    local timeout=${4:-120s}

    kubectl --context "$context" rollout status deployment/"$deployment" -n "$namespace" --timeout="$timeout"
}

wait_for_loadbalancer() {
    local context=$1
    local namespace=$2
    local service=$3
    local max_attempts=${4:-60}

    for ((i=1; i<=max_attempts; i++)); do
        local ip=$(kubectl get svc -n "$namespace" "$service" --context "$context" \
            -o jsonpath="{.status.loadBalancer.ingress[0]['hostname','ip']}" 2>/dev/null)
        if [[ -n "$ip" ]]; then
            echo "$ip"
            return 0
        fi
        sleep 5
    done
    return 1
}

create_namespace_if_missing() {
    local context=$1
    local namespace=$2

    kubectl --context="$context" create ns "$namespace" 2>/dev/null || true
}

apply_yaml() {
    local context=$1
    local yaml=$2

    echo "$yaml" | kubectl --context="$context" apply -f -
}

#######################################
# Installation Functions
#######################################

install_gateway_api_crds() {
    log_step "Step 1: Installing Gateway API CRDs"

    # Install on both clusters (needed for east-west gateways on cluster2)
    for context in "$CLUSTER1" "$CLUSTER2"; do
        log_info "Installing Gateway API CRDs on $context..."
        kubectl --context "$context" apply -f \
            "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"
    done

    log_success "Gateway API CRDs installed on both clusters"
}

install_gloo_gateway() {
    log_step "Step 2: Installing Gloo Gateway v2"

    log_info "Installing Gloo Gateway CRDs..."
    helm upgrade -i --create-namespace --namespace gloo-system \
        --kube-context "$CLUSTER1" \
        --version "$GLOO_GATEWAY_VERSION" \
        gloo-gateway-crds oci://us-docker.pkg.dev/solo-public/gloo-gateway/charts/gloo-gateway-crds

    log_info "Installing Gloo Gateway..."
    helm upgrade -i -n gloo-system gloo-gateway \
        oci://us-docker.pkg.dev/solo-public/gloo-gateway/charts/gloo-gateway \
        --kube-context "$CLUSTER1" \
        --version "$GLOO_GATEWAY_VERSION" \
        --set licensing.glooGatewayLicenseKey="$GLOO_GATEWAY_LICENSE_KEY"

    log_info "Waiting for Gloo Gateway..."
    wait_for_deployment "$CLUSTER1" "gloo-system" "gloo-gateway"

    log_success "Gloo Gateway installed"
}

create_ingress_gateway() {
    log_step "Step 3: Creating Gateway for Ingress"

    apply_yaml "$CLUSTER1" '
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
'

    log_info "Waiting for LoadBalancer IP..."
    local ip=$(wait_for_loadbalancer "$CLUSTER1" "gloo-system" "http")

    if [[ -n "$ip" ]]; then
        log_success "Gateway ready with IP: $ip"
    else
        log_warn "Gateway IP not yet assigned, continuing..."
    fi
}

configure_trust() {
    log_step "Step 4: Configuring Trust (Shared Root CA)"

    # Create namespaces on both clusters
    for context in "$CLUSTER1" "$CLUSTER2"; do
        create_namespace_if_missing "$context" "istio-system"
        create_namespace_if_missing "$context" "istio-gateways"
    done

    # Create cacerts secrets
    local clusters=("cluster1:$CLUSTER1" "cluster2:$CLUSTER2")

    # Certs are in parent directory (omni/certs), not scripts/certs
    local REPO_ROOT="$(dirname "$SCRIPT_DIR")"

    for entry in "${clusters[@]}"; do
        local name="${entry%%:*}"
        local context="${entry##*:}"
        local cert_dir="$REPO_ROOT/certs/$name"

        if [[ -d "$cert_dir" ]]; then
            kubectl --context="$context" create secret generic cacerts -n istio-system \
                --from-file="$cert_dir/ca-cert.pem" \
                --from-file="$cert_dir/ca-key.pem" \
                --from-file="$cert_dir/root-cert.pem" \
                --from-file="$cert_dir/cert-chain.pem" \
                --dry-run=client -o yaml | kubectl --context="$context" apply -f -
            log_success "Created cacerts on $context"
        else
            log_warn "Certs not found at $cert_dir, skipping..."
        fi
    done
}

deploy_istio_ambient() {
    log_step "Step 5: Installing Istio Ambient"

    # Solo.io Istio Helm repository (public builds)
    local HELM_REPO="us-docker.pkg.dev/soloio-img/istio-helm"
    local ISTIO_IMAGE="${ISTIO_VERSION}-solo"
    local ISTIO_HUB="us-docker.pkg.dev/soloio-img/istio"

    # Deploy Istio components on each cluster
    for entry in "cluster1:$CLUSTER1" "cluster2:$CLUSTER2"; do
        local cluster_name="${entry%%:*}"
        local context="${entry##*:}"

        log_info "Installing Istio on $context..."

        # Get K8s API server CIDR for egressPolicies passthrough
        local K8S_API_IP
        K8S_API_IP=$(kubectl --context "$context" get svc kubernetes -o jsonpath='{.spec.clusterIP}')
        log_info "K8s API ClusterIP for $context: $K8S_API_IP"

        # Create ResourceQuota for critical pods (required for GKE)
        log_info "Creating ResourceQuota for critical pods on $context..."
        kubectl --context "$context" apply -f - <<EOF
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

        # Add network topology label for multi-cluster
        log_info "Adding network topology label for $cluster_name..."
        kubectl --context "$context" label namespace istio-system topology.istio.io/network=${cluster_name} --overwrite

        # Install base CRDs
        log_info "Installing istio-base on $context..."
        helm upgrade --install istio-base oci://${HELM_REPO}/base \
            --namespace istio-system \
            --kube-context "$context" \
            --version "${ISTIO_IMAGE}" \
            --set defaultRevision=default \
            --set profile=ambient \
            --wait

        # Install istiod control plane
        # clusterName must be unique per cluster for multi-cluster peering
        # The JWT validation is handled by Kubernetes TokenReview API, not by clusterName
        log_info "Installing istiod on $context..."
        helm upgrade --install istiod oci://${HELM_REPO}/istiod \
            --namespace istio-system \
            --kube-context "$context" \
            --version "${ISTIO_IMAGE}" \
            --wait \
            -f - <<EOF
global:
  hub: ${ISTIO_HUB}
  tag: ${ISTIO_IMAGE}
  proxy:
    clusterDomain: cluster.local
  logAsJson: true
  network: ${cluster_name}
  meshID: mesh1
  multiCluster:
    # Unique cluster name for multi-cluster identity
    clusterName: ${cluster_name}
meshConfig:
  accessLogFile: /dev/stdout
  rootNamespace: istio-system
  trustDomain: cluster.local
  defaultConfig:
    proxyMetadata:
      ISTIO_META_DNS_CAPTURE: "true"
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
    PILOT_ENABLE_IP_AUTOALLOCATE: "true"
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

        # Install istio-cni with GKE platform settings
        log_info "Installing istio-cni on $context..."
        helm upgrade --install istio-cni oci://${HELM_REPO}/cni \
            --namespace istio-system \
            --kube-context "$context" \
            --version "${ISTIO_IMAGE}" \
            --wait \
            -f - <<EOF
ambient:
  dnsCapture: true
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

        # Install ztunnel with egressPolicies for K8s API passthrough and L7 tracing
        log_info "Installing ztunnel on $context with egressPolicies and L7 tracing..."
        helm upgrade --install ztunnel oci://${HELM_REPO}/ztunnel \
            --namespace istio-system \
            --kube-context "$context" \
            --version "${ISTIO_IMAGE}" \
            --wait \
            -f - <<EOF
hub: ${ISTIO_HUB}
tag: ${ISTIO_IMAGE}
istioNamespace: istio-system
profile: ambient
network: ${cluster_name}
# Must match istiod's global.multiCluster.clusterName
multiCluster:
  clusterName: ${cluster_name}
env:
  L7_ENABLED: "true"
# L7 Telemetry configuration for Solo Enterprise ztunnel
l7Telemetry:
  enabled: true
  metrics:
    enabled: true
  accessLog:
    enabled: true
    skipConnectionLog: false
  distributedTracing:
    enabled: true
    # Point to Gloo telemetry collector for distributed tracing
    otlpEndpoint: "http://gloo-telemetry-collector.gloo-mesh:4317"
# egressPolicies to allow Passthrough to K8s API and internal services
egressPolicies:
  # Allow passthrough for Kubernetes API server (ClusterIP and internal IPs)
  - matchCidrs:
    - ${K8S_API_IP}/32
    - 10.0.0.0/8
    - 172.16.0.0/12
    policy: Passthrough
  # Default: passthrough for everything else (can be changed to Deny or Gateway)
  - matchCidrs:
    - 0.0.0.0/0
    - ::/0
    policy: Passthrough
EOF
    done

    log_info "Waiting for Istio components to be fully ready..."
    wait_for_istio_ready

    log_success "Istio Ambient running on both clusters"
}

wait_for_istio_ready() {
    for ((i=1; i<=60; i++)); do
        local istiod1=$(kubectl --context "$CLUSTER1" get pods -n istio-system -l app=istiod -o jsonpath='{.items[0].status.phase}' 2>/dev/null)
        local ztunnel1=$(kubectl --context "$CLUSTER1" get pods -n istio-system -l app=ztunnel -o jsonpath='{.items[0].status.phase}' 2>/dev/null)
        local istiod2=$(kubectl --context "$CLUSTER2" get pods -n istio-system -l app=istiod -o jsonpath='{.items[0].status.phase}' 2>/dev/null)
        local ztunnel2=$(kubectl --context "$CLUSTER2" get pods -n istio-system -l app=ztunnel -o jsonpath='{.items[0].status.phase}' 2>/dev/null)

        if [[ "$istiod1" == "Running" && "$ztunnel1" == "Running" && \
              "$istiod2" == "Running" && "$ztunnel2" == "Running" ]]; then
            return 0
        fi
        echo -n "."
        sleep 10
    done
    echo ""
    log_warn "Timeout waiting for Istio, continuing..."
}

install_gloo_platform() {
    log_step "Step 6: Installing Gloo Management Plane"

    helm repo add gloo-platform https://storage.googleapis.com/gloo-platform/helm-charts 2>/dev/null || true
    helm repo update

    # Adopt CRDs if Gloo Gateway already installed
    kubectl --context "$CLUSTER1" annotate crd authconfigs.extauth.solo.io \
        meta.helm.sh/release-name=gloo-platform-crds \
        meta.helm.sh/release-namespace=gloo-mesh \
        --overwrite 2>/dev/null || true

    log_info "Installing Gloo Platform CRDs..."
    helm upgrade -i gloo-platform-crds gloo-platform/gloo-platform-crds \
        -n gloo-mesh \
        --kube-context "$CLUSTER1" \
        --create-namespace \
        --version "$GLOO_VERSION"

    log_info "Creating KubernetesCluster CR for cluster1..."
    apply_yaml "$CLUSTER1" '
apiVersion: admin.gloo.solo.io/v2
kind: KubernetesCluster
metadata:
  name: cluster1
  namespace: gloo-mesh
spec:
  clusterDomain: cluster.local
'

    log_info "Installing Gloo Platform..."
    helm upgrade -i gloo-platform gloo-platform/gloo-platform \
        -n gloo-mesh \
        --kube-context "$CLUSTER1" \
        --version "$GLOO_VERSION" \
        --set common.cluster=cluster1 \
        --set licensing.glooMeshLicenseKey="$GLOO_MESH_LICENSE_KEY" \
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

    log_info "Waiting for Gloo Platform..."
    sleep 30
    wait_for_deployment "$CLUSTER1" "gloo-mesh" "gloo-mesh-mgmt-server" "180s"

    log_success "Gloo Management Plane installed"
}

register_cluster2() {
    log_step "Step 7: Registering Cluster2 as Workload Cluster"

    local telemetry_address=$(kubectl get svc -n gloo-mesh gloo-telemetry-gateway \
        --context "$CLUSTER1" \
        -o jsonpath="{.status.loadBalancer.ingress[0]['hostname','ip']}"):4317

    log_info "Telemetry Gateway: $telemetry_address"

    # Find or install meshctl
    local meshctl_bin=""
    if [[ -f "$HOME/.gloo-mesh/bin/meshctl" ]]; then
        meshctl_bin="$HOME/.gloo-mesh/bin/meshctl"
    elif command -v meshctl &> /dev/null; then
        meshctl_bin=$(command -v meshctl)
    else
        log_info "Installing meshctl..."
        curl -sL https://run.solo.io/meshctl/install | GLOO_MESH_VERSION=v${GLOO_VERSION} sh -
        meshctl_bin="$HOME/.gloo-mesh/bin/meshctl"
    fi

    log_info "Using meshctl to register cluster2..."
    "$meshctl_bin" cluster register cluster2 \
        --kubecontext "$CLUSTER1" \
        --profiles gloo-mesh-agent \
        --remote-context "$CLUSTER2" \
        --telemetry-server-address "$telemetry_address"

    log_success "Cluster2 registered"
}

#######################################
# Verification Functions
#######################################

verify_setup() {
    log_step "Verifying Setup"

    echo ""
    log_info "Cluster Status:"
    kubectl --context "$CLUSTER1" get kubernetesclusters -n gloo-mesh

    echo ""
    log_info "GatewayClasses on $CLUSTER1:"
    kubectl --context "$CLUSTER1" get gatewayclasses

    echo ""
    log_info "Pods on $CLUSTER1 (gloo-system):"
    kubectl --context "$CLUSTER1" get pods -n gloo-system

    echo ""
    log_info "Pods on $CLUSTER1 (gloo-mesh):"
    kubectl --context "$CLUSTER1" get pods -n gloo-mesh

    echo ""
    log_info "Pods on $CLUSTER1 (istio-system):"
    kubectl --context "$CLUSTER1" get pods -n istio-system

    echo ""
    log_info "Pods on $CLUSTER2 (gloo-mesh):"
    kubectl --context "$CLUSTER2" get pods -n gloo-mesh

    echo ""
    log_info "Pods on $CLUSTER2 (istio-system):"
    kubectl --context "$CLUSTER2" get pods -n istio-system
}

print_summary() {
    echo ""
    log_step "Setup Complete!"
    echo ""

    local gloo_ip=$(kubectl get svc -n gloo-system http --context "$CLUSTER1" \
        -o jsonpath="{.status.loadBalancer.ingress[0]['hostname','ip']}" 2>/dev/null)

    log_success "Gloo Gateway IP: $gloo_ip"
    log_success "Gloo UI: kubectl --context $CLUSTER1 port-forward -n gloo-mesh svc/gloo-mesh-ui 8090:8090"
    echo ""
    log_info "Next: Run the demo steps from the guide (deploy bookinfo, add to mesh, etc.)"
}

#######################################
# Main
#######################################

main() {
    local config_file=""
    local create_clusters=false

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -c|--config)
                config_file="$2"
                shift 2
                ;;
            --create-clusters)
                create_clusters=true
                shift
                ;;
            -h|--help)
                usage
                ;;
            *)
                log_error "Unknown option: $1"
                usage
                ;;
        esac
    done

    # Load config file if specified
    if [[ -n "$config_file" ]]; then
        load_config "$config_file"
    fi

    set_defaults
    validate_environment
    validate_clusters "$create_clusters"
    print_config

    install_gateway_api_crds
    install_gloo_gateway
    create_ingress_gateway
    configure_trust
    deploy_istio_ambient
    install_gloo_platform
    register_cluster2

    verify_setup
    print_summary
}

main "$@"
