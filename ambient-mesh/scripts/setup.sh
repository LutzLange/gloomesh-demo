#!/bin/bash
# Ambient Mesh Workshop - Automated Setup
# Single-cluster setup with Istio Gateway for ingress

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test-lib.sh"

#######################################
# Configuration
#######################################

CONFIG_FILE=""
PLATFORM="gke"  # gke, eks, aks, kind
CREATE_CLUSTER=false

usage() {
    echo "Usage: $0 [-c config_file] [-p platform] [--create-cluster]"
    echo ""
    echo "Options:"
    echo "  -c, --config FILE       Load configuration from FILE"
    echo "  -p, --platform PLATFORM Platform: gke, eks, aks, kind (default: gke)"
    echo "  --create-cluster        Create GKE cluster if it doesn't exist"
    echo "  -h, --help              Show this help message"
    echo ""
    echo "Environment variables (from config file or environment):"
    echo "  CLUSTER                 Cluster name (required for --create-cluster)"
    echo "  GKE_ZONE                GKE zone (required for --create-cluster)"
    echo "  ISTIO_VERSION           Istio version (default: 1.28.1)"
    echo "  GLOO_VERSION            Gloo Platform version (default: 2.11.0)"
    echo "  GLOO_MESH_LICENSE_KEY   Solo license key (enables Solo Istio + Gloo Platform UI)"
    echo ""
    echo "Examples:"
    echo "  $0 -c env.sh"
    echo "  $0 -c env.sh --create-cluster"
    echo "  $0 -c env.sh -p eks"
    exit 0
}

#######################################
# Parse Arguments
#######################################

while [[ $# -gt 0 ]]; do
    case $1 in
        -c|--config)
            CONFIG_FILE="$2"
            shift 2
            ;;
        -p|--platform)
            PLATFORM="$2"
            shift 2
            ;;
        --create-cluster)
            CREATE_CLUSTER=true
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

#######################################
# Load Configuration
#######################################

if [[ -n "$CONFIG_FILE" ]]; then
    if [[ ! -f "$CONFIG_FILE" ]]; then
        log_error "Config file not found: $CONFIG_FILE"
        exit 1
    fi
    source "$CONFIG_FILE"
    log_info "Loaded config from: $CONFIG_FILE"
fi

# Set defaults
ISTIO_VERSION="${ISTIO_VERSION:-1.28.1}"
GLOO_VERSION="${GLOO_VERSION:-2.11.0}"

# Determine if using Solo distribution
if [[ -n "${GLOO_MESH_LICENSE_KEY:-}" ]]; then
    USE_SOLO=true
    HELM_REPO="us-docker.pkg.dev/soloio-img/istio-helm"
    ISTIO_IMAGE="${ISTIO_VERSION}-solo"
    ISTIO_HUB="us-docker.pkg.dev/soloio-img/istio"
    log_info "Using Solo.io Istio distribution"
else
    USE_SOLO=false
    HELM_REPO="oci://docker.io/istio"
    ISTIO_IMAGE="${ISTIO_VERSION}"
    ISTIO_HUB="docker.io/istio"
    log_info "Using upstream Istio"
fi

# Platform-specific CNI paths
case "$PLATFORM" in
    gke)
        CNI_BIN_DIR="/home/kubernetes/bin"
        CNI_CONF_DIR="/etc/cni/net.d"
        PLATFORM_FLAG="gke"
        ;;
    *)
        CNI_BIN_DIR="/opt/cni/bin"
        CNI_CONF_DIR="/etc/cni/net.d"
        PLATFORM_FLAG=""
        ;;
esac

log_info "Platform: $PLATFORM"
log_info "Istio version: $ISTIO_VERSION"

#######################################
# Cluster Creation Functions
#######################################

create_gke_cluster() {
    log_step "Creating GKE Cluster"

    # Validate required variables
    if [[ -z "${CLUSTER:-}" ]]; then
        log_error "CLUSTER variable required for cluster creation"
        exit 1
    fi

    if [[ -z "${GKE_ZONE:-}" ]]; then
        log_error "GKE_ZONE variable required for cluster creation"
        exit 1
    fi

    # Get GCP project
    local PROJECT
    PROJECT="$(gcloud config get-value project 2>/dev/null)"

    if [[ -z "$PROJECT" ]]; then
        log_error "No active gcloud project set. Run: gcloud config set project <PROJECT_ID>"
        exit 1
    fi

    log_info "Using GCP project: $PROJECT"
    log_info "Creating cluster: $CLUSTER (zone: $GKE_ZONE)"

    # Create cluster if it doesn't exist
    if ! gcloud container clusters describe "$CLUSTER" --zone "$GKE_ZONE" --project "$PROJECT" > /dev/null 2>&1; then
        log_info "Creating GKE cluster $CLUSTER..."
        gcloud container clusters create "$CLUSTER" \
            --zone "$GKE_ZONE" \
            --num-nodes 3 \
            --machine-type e2-standard-4 \
            --enable-ip-alias \
            --workload-pool="${PROJECT}.svc.id.goog" \
            --network default
    else
        log_info "Cluster $CLUSTER already exists"
    fi

    # Fetch credentials
    log_info "Fetching cluster credentials..."
    gcloud container clusters get-credentials "$CLUSTER" --zone "$GKE_ZONE" --project "$PROJECT"

    # Rename kubeconfig context to simple name
    local OLD_CTX="gke_${PROJECT}_${GKE_ZONE}_${CLUSTER}"

    # Clean up existing target context first
    kubectl config delete-context "$CLUSTER" 2>/dev/null || true

    if kubectl config get-contexts "$OLD_CTX" > /dev/null 2>&1; then
        kubectl config rename-context "$OLD_CTX" "$CLUSTER"
        log_info "Renamed context to $CLUSTER"
    fi

    # Set current context
    kubectl config use-context "$CLUSTER"

    log_success "GKE cluster created and configured"
}

validate_cluster() {
    log_info "Validating cluster connectivity..."

    # Check if cluster is reachable
    if kubectl cluster-info > /dev/null 2>&1; then
        log_success "Cluster is reachable"
        return 0
    fi

    # Cluster not reachable
    if [[ "$CREATE_CLUSTER" != "true" ]]; then
        log_error "Cannot connect to cluster"
        log_error ""
        log_error "Options:"
        log_error "  1. Configure kubectl context for your existing cluster"
        log_error "  2. Use --create-cluster flag to create a GKE cluster automatically"
        log_error ""
        log_error "For GKE cluster creation, set these in your env.sh:"
        log_error "  export CLUSTER=my-cluster-name"
        log_error "  export GKE_ZONE=us-central1-a"
        exit 1
    fi

    # Create cluster requested
    create_gke_cluster
}

#######################################
# Setup Functions
#######################################

do_install_gateway_api() {
    log_step "Installing Gateway API CRDs"

    kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.4.0/standard-install.yaml

    log_info "Waiting for CRDs to be established..."
    kubectl wait --for=condition=established crd/gateways.gateway.networking.k8s.io --timeout=60s
    kubectl wait --for=condition=established crd/httproutes.gateway.networking.k8s.io --timeout=60s

    log_success "Gateway API CRDs installed"
}

do_install_istio_ambient() {
    log_step "Installing Istio Ambient"

    # Create namespace
    kubectl create ns istio-system 2>/dev/null || true

    # GKE ResourceQuota for system-critical pods
    if [[ "$PLATFORM" == "gke" ]]; then
        log_info "Creating ResourceQuota for GKE..."
        kubectl apply -f - <<EOYAML
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
EOYAML
    fi

    # Install istio-base
    log_info "Installing istio-base..."
    if [[ "$USE_SOLO" == "true" ]]; then
        helm upgrade --install istio-base "oci://${HELM_REPO}/base" \
            --namespace istio-system \
            --version "${ISTIO_IMAGE}" \
            --set defaultRevision=default \
            --set profile=ambient \
            --wait
    else
        helm upgrade --install istio-base "${HELM_REPO}/base" \
            --namespace istio-system \
            --version "${ISTIO_IMAGE}" \
            --set defaultRevision=default \
            --set profile=ambient \
            --wait
    fi

    # Install istiod
    log_info "Installing istiod..."
    local istiod_values="global:
  hub: ${ISTIO_HUB}
  tag: ${ISTIO_IMAGE}
  logAsJson: true
meshConfig:
  accessLogFile: /dev/stdout
pilot:
  cni:
    namespace: istio-system
    enabled: true
profile: ambient"

    if [[ "$USE_SOLO" == "true" && -n "${GLOO_MESH_LICENSE_KEY:-}" ]]; then
        istiod_values="${istiod_values}
license:
  value: ${GLOO_MESH_LICENSE_KEY}"
    fi

    if [[ "$USE_SOLO" == "true" ]]; then
        echo "$istiod_values" | helm upgrade --install istiod "oci://${HELM_REPO}/istiod" \
            --namespace istio-system \
            --version "${ISTIO_IMAGE}" \
            --wait \
            -f -
    else
        echo "$istiod_values" | helm upgrade --install istiod "${HELM_REPO}/istiod" \
            --namespace istio-system \
            --version "${ISTIO_IMAGE}" \
            --wait \
            -f -
    fi

    # Install CNI
    log_info "Installing istio-cni..."
    local cni_values="excludeNamespaces:
- istio-system
- kube-system
global:
  hub: ${ISTIO_HUB}
  tag: ${ISTIO_IMAGE}"

    if [[ -n "$PLATFORM_FLAG" ]]; then
        cni_values="${cni_values}
  platform: ${PLATFORM_FLAG}"
    fi

    cni_values="${cni_values}
cni:
  cniBinDir: ${CNI_BIN_DIR}
  cniConfDir: ${CNI_CONF_DIR}
profile: ambient"

    if [[ "$USE_SOLO" == "true" ]]; then
        echo "$cni_values" | helm upgrade --install istio-cni "oci://${HELM_REPO}/cni" \
            --namespace istio-system \
            --version "${ISTIO_IMAGE}" \
            --wait \
            -f -
    else
        echo "$cni_values" | helm upgrade --install istio-cni "${HELM_REPO}/cni" \
            --namespace istio-system \
            --version "${ISTIO_IMAGE}" \
            --wait \
            -f -
    fi

    # Install ztunnel
    log_info "Installing ztunnel..."
    local ztunnel_values="hub: ${ISTIO_HUB}
tag: ${ISTIO_IMAGE}
istioNamespace: istio-system
profile: ambient"

    if [[ "$USE_SOLO" == "true" ]]; then
        ztunnel_values="${ztunnel_values}
env:
  L7_ENABLED: \"true\"
l7Telemetry:
  enabled: true
  metrics:
    enabled: true
  accessLog:
    enabled: true
    skipConnectionLog: false"
    fi

    if [[ "$USE_SOLO" == "true" ]]; then
        echo "$ztunnel_values" | helm upgrade --install ztunnel "oci://${HELM_REPO}/ztunnel" \
            --namespace istio-system \
            --version "${ISTIO_IMAGE}" \
            --wait \
            -f -
    else
        echo "$ztunnel_values" | helm upgrade --install ztunnel "${HELM_REPO}/ztunnel" \
            --namespace istio-system \
            --version "${ISTIO_IMAGE}" \
            --wait \
            -f -
    fi

    log_success "Istio Ambient installed"
}

do_install_istio_gateway() {
    log_step "Installing Istio Gateway"

    # Create namespace
    kubectl create ns istio-ingress 2>/dev/null || true

    # Install gateway helm chart
    log_info "Installing istio-ingress gateway..."
    if [[ "$USE_SOLO" == "true" ]]; then
        helm upgrade --install istio-ingress "oci://${HELM_REPO}/gateway" \
            --namespace istio-ingress \
            --version "${ISTIO_IMAGE}" \
            --wait \
            --set service.type=LoadBalancer
    else
        helm upgrade --install istio-ingress "${HELM_REPO}/gateway" \
            --namespace istio-ingress \
            --version "${ISTIO_IMAGE}" \
            --wait \
            --set service.type=LoadBalancer
    fi

    # Create Gateway resource
    log_info "Creating Gateway resource..."
    kubectl apply -f - <<EOYAML
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
EOYAML

    # Wait for LoadBalancer IP
    log_info "Waiting for LoadBalancer IP..."
    local gateway_ip
    gateway_ip=$(wait_for_loadbalancer "istio-ingress" "istio-ingress" 60)

    if [[ -z "$gateway_ip" ]]; then
        log_warn "LoadBalancer IP not ready yet. Check status with:"
        log_warn "  kubectl get svc -n istio-ingress istio-ingress"
    else
        log_success "Istio Gateway installed. IP: $gateway_ip"
    fi
}

do_deploy_bookinfo() {
    log_step "Deploying Bookinfo application (OTel-instrumented)"

    kubectl create ns bookinfo 2>/dev/null || true
    # Use OTel-instrumented Bookinfo for distributed tracing
    kubectl apply -n bookinfo -f https://raw.githubusercontent.com/LutzLange/bookinfo/main/platform/kube/bookinfo-otel.yaml

    log_info "Waiting for Bookinfo pods..."
    wait_for_deployment "bookinfo" "productpage-v1" 120
    wait_for_deployment "bookinfo" "reviews-v1" 120
    wait_for_deployment "bookinfo" "ratings-v1" 120
    wait_for_deployment "bookinfo" "details-v1" 120

    log_success "Bookinfo deployed"
}

do_install_gloo_platform() {
    log_step "Installing Gloo Platform (Management UI)"

    # Check for license key
    if [[ -z "${GLOO_MESH_LICENSE_KEY:-}" ]]; then
        log_warn "GLOO_MESH_LICENSE_KEY not set - skipping Gloo Platform installation"
        log_warn "Set GLOO_MESH_LICENSE_KEY in env.sh to enable the Management UI"
        return 0
    fi

    # Add Helm repository
    log_info "Adding Gloo Platform Helm repository..."
    helm repo add gloo-platform https://storage.googleapis.com/gloo-platform/helm-charts 2>/dev/null || true
    helm repo update

    # Create namespace
    kubectl create ns gloo-mesh 2>/dev/null || true

    # Install Gloo Platform CRDs
    log_info "Installing Gloo Platform CRDs..."
    helm upgrade -i gloo-platform-crds gloo-platform/gloo-platform-crds \
        -n gloo-mesh \
        --version "$GLOO_VERSION"

    # Create KubernetesCluster CR
    log_info "Creating KubernetesCluster CR..."
    kubectl apply -f - <<EOYAML
apiVersion: admin.gloo.solo.io/v2
kind: KubernetesCluster
metadata:
  name: cluster1
  namespace: gloo-mesh
spec:
  clusterDomain: cluster.local
EOYAML

    # Install Gloo Platform with UI enabled
    log_info "Installing Gloo Platform..."
    helm upgrade -i gloo-platform gloo-platform/gloo-platform \
        -n gloo-mesh \
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

    # Wait for management server
    log_info "Waiting for Gloo Platform..."
    sleep 30
    wait_for_deployment "gloo-mesh" "gloo-mesh-mgmt-server" 180

    log_success "Gloo Platform installed"
}

#######################################
# Main
#######################################

main() {
    print_header "Ambient Mesh Workshop Setup"

    # Validate or create cluster
    validate_cluster

    echo ""

    # Run setup steps
    run_step "setup-1" do_install_gateway_api
    run_step "setup-2" do_install_istio_ambient
    run_step "setup-3" do_install_istio_gateway
    run_step "setup-4" do_deploy_bookinfo
    run_step "setup-5" do_install_gloo_platform

    echo ""
    print_header "Setup Complete"

    # Print summary
    local gateway_ip
    gateway_ip=$(kubectl get svc -n istio-ingress istio-ingress -o jsonpath="{.status.loadBalancer.ingress[0]['hostname','ip']}" 2>/dev/null || echo "")

    echo "Your environment is ready!"
    echo ""
    echo "Gateway IP: ${gateway_ip:-<pending>}"
    echo ""
    echo "To set the GATEWAY_IP environment variable:"
    echo "  export GATEWAY_IP=\$(kubectl get svc -n istio-ingress istio-ingress -o jsonpath=\"{.status.loadBalancer.ingress[0]['hostname','ip']}\")"
    echo ""

    # Check if Gloo Platform was installed
    if kubectl get ns gloo-mesh &>/dev/null; then
        echo "Gloo Management UI:"
        echo "  kubectl port-forward -n gloo-mesh svc/gloo-mesh-ui 8090:8090"
        echo "  Open: http://localhost:8090"
        echo ""
    fi

    echo "Next steps:"
    echo "  1. Run the workshop demo: ./scripts/workshop.sh -c env.sh"
    echo "  2. Run the test suite: ./scripts/test-workshop.sh -c env.sh"
}

main "$@"
