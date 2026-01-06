#!/bin/bash
set -e

# Omni Workshop Script
# Runs setup and/or demo steps to a specified checkpoint
#
# Usage:
#   ./workshop.sh                    # Show available checkpoints
#   ./workshop.sh setup              # Run all setup steps (1-7)
#   ./workshop.sh demo               # Run all demo steps (assumes setup complete)
#   ./workshop.sh all                # Run complete workshop (setup + demo)
#   ./workshop.sh --to <checkpoint>  # Run from current state to checkpoint
#   ./workshop.sh --step <step>      # Run a single step only
#   ./workshop.sh --test             # Run full workshop with verification
#
# Checkpoints:
#   setup-1  Gateway API CRDs
#   setup-2  Gloo Gateway v2
#   setup-3  Ingress Gateway
#   setup-4  Trust Configuration
#   setup-5  Gloo Operator + Istio
#   setup-6  Gloo Management Plane
#   setup-7  Cluster Registration
#   demo-1   Onboarding (deploy + mesh)
#   demo-2   mTLS & Cluster Peering
#   demo-3   Observability
#   demo-4   Global Services
#   demo-5   Canary & Rate Limiting

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

#######################################
# Logging
#######################################

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()    { echo -e "\n${GREEN}==>${NC} ${YELLOW}$1${NC}"; }
log_checkpoint() { echo -e "\n${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; echo -e "${CYAN}CHECKPOINT: $1${NC}"; echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"; }

#######################################
# Environment
#######################################

load_environment() {
    if [[ -f "$REPO_ROOT/env.sh" ]]; then
        source "$REPO_ROOT/env.sh"
        log_info "Loaded environment from env.sh"
    else
        log_error "env.sh not found. Please create it with required variables."
        exit 1
    fi

    # Set defaults
    export GLOO_VERSION="${GLOO_VERSION:-2.11.0}"
    export ISTIO_VERSION="${ISTIO_VERSION:-1.28.1}"
    export GATEWAY_API_VERSION="${GATEWAY_API_VERSION:-v1.4.0}"
    export GLOO_GATEWAY_VERSION="${GLOO_GATEWAY_VERSION:-2.0.1}"
    export GLOO_OPERATOR_VERSION="${GLOO_OPERATOR_VERSION:-0.4.2}"
}

validate_prerequisites() {
    local missing=()

    [[ -z "$CLUSTER1" ]] && missing+=("CLUSTER1")
    [[ -z "$CLUSTER2" ]] && missing+=("CLUSTER2")
    [[ -z "$GLOO_GATEWAY_LICENSE_KEY" ]] && missing+=("GLOO_GATEWAY_LICENSE_KEY")
    [[ -z "$GLOO_MESH_LICENSE_KEY" ]] && missing+=("GLOO_MESH_LICENSE_KEY")

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required variables: ${missing[*]}"
        exit 1
    fi

    kubectl --context "$CLUSTER1" cluster-info > /dev/null 2>&1 || { log_error "Cannot connect to $CLUSTER1"; exit 1; }
    kubectl --context "$CLUSTER2" cluster-info > /dev/null 2>&1 || { log_error "Cannot connect to $CLUSTER2"; exit 1; }

    log_success "Prerequisites validated"
}

#######################################
# Helper Functions
#######################################

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

wait_for_pods() {
    local context=$1
    local namespace=$2
    local label=$3
    local timeout=${4:-120}

    log_info "Waiting for pods with label $label in $namespace..."
    for ((i=1; i<=timeout; i+=5)); do
        local ready=$(kubectl --context "$context" get pods -n "$namespace" -l "$label" -o jsonpath='{.items[*].status.phase}' 2>/dev/null | tr ' ' '\n' | grep -c Running || echo 0)
        local total=$(kubectl --context "$context" get pods -n "$namespace" -l "$label" --no-headers 2>/dev/null | wc -l)
        if [[ "$ready" -gt 0 && "$ready" -eq "$total" ]]; then
            return 0
        fi
        sleep 5
    done
    log_warn "Timeout waiting for pods"
    return 1
}

apply_yaml() {
    local context=$1
    local yaml=$2

    echo "$yaml" | kubectl --context="$context" apply -f -
}

get_gloo_ip() {
    kubectl get svc -n gloo-system http --context "$CLUSTER1" \
        -o jsonpath="{.status.loadBalancer.ingress[0]['hostname','ip']}" 2>/dev/null
}

#######################################
# SETUP STEPS
#######################################

setup_1_gateway_api_crds() {
    log_checkpoint "setup-1: Gateway API CRDs"

    kubectl --context "$CLUSTER1" apply -f \
        "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"

    log_success "Gateway API CRDs installed"
}

setup_2_gloo_gateway() {
    log_checkpoint "setup-2: Gloo Gateway v2"

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

setup_3_ingress_gateway() {
    log_checkpoint "setup-3: Ingress Gateway"

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
        export GLOO_IP="$ip"
    else
        log_warn "Gateway IP not yet assigned, continuing..."
    fi
}

setup_4_trust() {
    log_checkpoint "setup-4: Trust Configuration (Shared Root CA)"

    for context in "$CLUSTER1" "$CLUSTER2"; do
        kubectl --context="$context" create ns istio-system 2>/dev/null || true
        kubectl --context="$context" create ns istio-gateways 2>/dev/null || true
    done

    local clusters=("cluster1:$CLUSTER1" "cluster2:$CLUSTER2")

    for entry in "${clusters[@]}"; do
        local name="${entry%%:*}"
        local context="${entry##*:}"
        local cert_dir="$SCRIPT_DIR/certs/$name"

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

setup_5_gloo_operator_istio() {
    log_checkpoint "setup-5: Gloo Operator + Istio Ambient"

    log_info "Installing Gloo Operator on both clusters..."
    for context in "$CLUSTER1" "$CLUSTER2"; do
        helm upgrade --install --kube-context="$context" gloo-operator \
            oci://us-docker.pkg.dev/solo-public/gloo-operator-helm/gloo-operator \
            --version "$GLOO_OPERATOR_VERSION" \
            -n gloo-mesh \
            --create-namespace \
            --set manager.env.SOLO_ISTIO_LICENSE_KEY="$GLOO_MESH_LICENSE_KEY" &
    done
    wait

    log_info "Waiting for Gloo Operator pods..."
    wait_for_deployment "$CLUSTER1" "gloo-mesh" "gloo-operator"
    wait_for_deployment "$CLUSTER2" "gloo-mesh" "gloo-operator"

    log_info "Deploying Istio via ServiceMeshController..."

    apply_yaml "$CLUSTER1" "
apiVersion: operator.gloo.solo.io/v1
kind: ServiceMeshController
metadata:
  name: managed-istio
  namespace: gloo-mesh
spec:
  cluster: cluster1
  network: cluster1
  dataplaneMode: Ambient
  installNamespace: istio-system
  version: ${ISTIO_VERSION}
"

    apply_yaml "$CLUSTER2" "
apiVersion: operator.gloo.solo.io/v1
kind: ServiceMeshController
metadata:
  name: managed-istio
  namespace: gloo-mesh
spec:
  cluster: cluster2
  network: cluster2
  dataplaneMode: Ambient
  installNamespace: istio-system
  version: ${ISTIO_VERSION}
"

    log_info "Waiting for Istio components..."
    wait_for_istio_ready

    log_success "Gloo Operator + Istio Ambient installed"
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

setup_6_gloo_platform() {
    log_checkpoint "setup-6: Gloo Management Plane"

    helm repo add gloo-platform https://storage.googleapis.com/gloo-platform/helm-charts 2>/dev/null || true
    helm repo update

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

setup_7_register_cluster2() {
    log_checkpoint "setup-7: Register Cluster2"

    local telemetry_address=$(kubectl get svc -n gloo-mesh gloo-telemetry-gateway \
        --context "$CLUSTER1" \
        -o jsonpath="{.status.loadBalancer.ingress[0]['hostname','ip']}"):4317

    log_info "Telemetry Gateway: $telemetry_address"

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
# DEMO STEPS
#######################################

demo_1_onboarding() {
    log_checkpoint "demo-1: Onboarding Application"

    export GLOO_IP=$(get_gloo_ip)
    log_info "Gloo Gateway IP: $GLOO_IP"

    # Deploy Bookinfo
    log_info "Deploying Bookinfo on both clusters..."
    for context in "$CLUSTER1" "$CLUSTER2"; do
        kubectl --context "$context" create ns bookinfo 2>/dev/null || true
        kubectl --context "$context" apply -n bookinfo \
            -f https://raw.githubusercontent.com/LutzLange/bookinfo/main/platform/kube/bookinfo-otel.yaml
    done

    log_info "Waiting for Bookinfo pods..."
    wait_for_pods "$CLUSTER1" "bookinfo" "app=productpage" 120
    wait_for_pods "$CLUSTER2" "bookinfo" "app=productpage" 120

    # Expose via Ingress
    log_info "Creating HTTPRoute for productpage..."
    apply_yaml "$CLUSTER1" '
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: bookinfo-gg
  namespace: bookinfo
spec:
  parentRefs:
  - name: http
    namespace: gloo-system
  rules:
  - matches:
    - path:
        type: Exact
        value: /productpage
    - path:
        type: PathPrefix
        value: /static
    - path:
        type: Exact
        value: /login
    - path:
        type: Exact
        value: /logout
    backendRefs:
    - name: productpage
      port: 9080
'

    # Add to mesh
    log_info "Adding bookinfo to mesh..."
    kubectl --context "$CLUSTER1" label namespace bookinfo istio.io/dataplane-mode=ambient --overwrite
    kubectl --context "$CLUSTER2" label namespace bookinfo istio.io/dataplane-mode=ambient --overwrite

    log_success "Bookinfo deployed and added to mesh"
    log_info "Test: curl http://$GLOO_IP/productpage"
}

demo_2_mtls_peering() {
    log_checkpoint "demo-2: mTLS & Cluster Peering"

    local istioctl="${ISTIOCTL:-$HOME/.istioctl/bin/istioctl}"

    # Deploy east-west gateways
    log_info "Deploying east-west gateways..."
    "$istioctl" --context="$CLUSTER1" multicluster expose -n istio-gateways
    "$istioctl" --context="$CLUSTER2" multicluster expose -n istio-gateways

    # Wait for LoadBalancer IPs
    log_info "Waiting for east-west gateway IPs..."
    wait_for_loadbalancer "$CLUSTER1" "istio-gateways" "istio-eastwest" 30 || true
    wait_for_loadbalancer "$CLUSTER2" "istio-gateways" "istio-eastwest" 30 || true

    # Link clusters
    log_info "Linking clusters..."
    "$istioctl" multicluster link --contexts="$CLUSTER1,$CLUSTER2" -n istio-gateways

    # Add gloo-system to mesh
    log_info "Adding gloo-system to mesh..."
    kubectl --context "$CLUSTER1" label namespace gloo-system istio.io/dataplane-mode=ambient --overwrite

    # Verify
    log_info "Verifying cluster peering..."
    kubectl --context "$CLUSTER1" get gateways -n istio-gateways

    log_success "Clusters peered with mTLS"
}

demo_3_observability() {
    log_checkpoint "demo-3: Observability"

    export GLOO_IP=$(get_gloo_ip)

    log_info "Generating traffic for traces..."
    for i in {1..10}; do
        curl -s "http://$GLOO_IP/productpage" > /dev/null || true
        sleep 1
    done

    log_success "Traffic generated. View in Gloo UI:"
    log_info "  kubectl --context $CLUSTER1 port-forward -n gloo-mesh svc/gloo-mesh-ui 8090:8090"
    log_info "  open http://localhost:8090"
}

demo_4_global_services() {
    log_checkpoint "demo-4: Global Service Failover"

    export GLOO_IP=$(get_gloo_ip)

    # Enable global services
    log_info "Enabling global services..."
    for context in "$CLUSTER1" "$CLUSTER2"; do
        kubectl --context "$context" -n bookinfo label service productpage solo.io/service-scope=global --overwrite
        kubectl --context "$context" -n bookinfo annotate service productpage networking.istio.io/traffic-distribution=Any --overwrite
    done

    # Update ingress to use global hostname
    log_info "Updating HTTPRoute to use global hostname..."
    apply_yaml "$CLUSTER1" '
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: bookinfo-gg
  namespace: bookinfo
spec:
  parentRefs:
  - name: http
    namespace: gloo-system
  rules:
  - matches:
    - path:
        type: Exact
        value: /productpage
    - path:
        type: PathPrefix
        value: /static
    - path:
        type: Exact
        value: /login
    - path:
        type: Exact
        value: /logout
    backendRefs:
    - kind: Hostname
      group: networking.istio.io
      name: productpage.bookinfo.mesh.internal
      port: 9080
'

    log_success "Global services configured"
    log_info "Test failover:"
    log_info "  1. curl http://$GLOO_IP/productpage (works)"
    log_info "  2. kubectl --context $CLUSTER1 scale deploy productpage-v1 -n bookinfo --replicas=0"
    log_info "  3. curl http://$GLOO_IP/productpage (still works - served from cluster2)"
}

demo_5_canary_ratelimit() {
    log_checkpoint "demo-5: Canary Deployments & Rate Limiting"

    export GLOO_IP=$(get_gloo_ip)

    # Deploy waypoints
    log_info "Deploying waypoints..."
    for ctx in "$CLUSTER1" "$CLUSTER2"; do
        apply_yaml "$ctx" '
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: waypoint
  namespace: bookinfo
spec:
  gatewayClassName: istio-waypoint
  listeners:
  - name: mesh
    port: 15008
    protocol: HBONE
'
        kubectl --context "$ctx" label svc reviews -n bookinfo istio.io/use-waypoint=waypoint --overwrite
    done

    # Wait for waypoints
    log_info "Waiting for waypoint proxies..."
    wait_for_pods "$CLUSTER1" "bookinfo" "gateway.networking.k8s.io/gateway-name=waypoint" 60 || true
    wait_for_pods "$CLUSTER2" "bookinfo" "gateway.networking.k8s.io/gateway-name=waypoint" 60 || true

    # Enable tracing on waypoints
    log_info "Enabling tracing on waypoints..."
    for ctx in "$CLUSTER1" "$CLUSTER2"; do
        apply_yaml "$ctx" '
apiVersion: telemetry.istio.io/v1
kind: Telemetry
metadata:
  name: tracing-waypoint
  namespace: bookinfo
spec:
  targetRefs:
  - kind: Gateway
    name: waypoint
    group: gateway.networking.k8s.io
  tracing:
  - providers:
    - name: otel-tracing
    randomSamplingPercentage: 100
'
    done

    # Canary routing
    log_info "Configuring canary routing (jason -> reviews-v2)..."
    for ctx in "$CLUSTER1" "$CLUSTER2"; do
        apply_yaml "$ctx" '
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: reviews
  namespace: bookinfo
spec:
  parentRefs:
  - group: ""
    kind: Service
    name: reviews
    port: 9080
  rules:
  - matches:
    - headers:
      - name: end-user
        value: jason
    backendRefs:
    - name: reviews-v2
      port: 9080
  - backendRefs:
    - name: reviews-v1
      port: 9080
'
    done

    # Rate limiting
    log_info "Applying rate limit policy..."
    apply_yaml "$CLUSTER1" '
apiVersion: gloo.solo.io/v1alpha1
kind: GlooTrafficPolicy
metadata:
  name: productpage-ratelimit
  namespace: bookinfo
spec:
  targetRefs:
  - group: gateway.networking.k8s.io
    kind: HTTPRoute
    name: bookinfo-gg
  rateLimit:
    local:
      tokenBucket:
        maxTokens: 5
        tokensPerFill: 5
        fillInterval: 60s
'

    log_success "Canary routing and rate limiting configured"
    log_info "Test canary:"
    log_info "  - Without login: reviews-v1 (no stars)"
    log_info "  - Login as 'jason': reviews-v2 (black stars)"
    log_info "Test rate limit:"
    log_info "  for i in {1..10}; do curl -s -o /dev/null -w '%{http_code}\n' http://$GLOO_IP/productpage; done"
}

#######################################
# VERIFICATION
#######################################

verify_setup() {
    log_step "Verifying Setup"

    echo ""
    log_info "Cluster Status:"
    kubectl --context "$CLUSTER1" get kubernetesclusters -n gloo-mesh

    echo ""
    log_info "GatewayClasses:"
    kubectl --context "$CLUSTER1" get gatewayclasses

    echo ""
    log_info "Gloo Gateway pods:"
    kubectl --context "$CLUSTER1" get pods -n gloo-system

    echo ""
    log_info "Istio pods (cluster1):"
    kubectl --context "$CLUSTER1" get pods -n istio-system
}

verify_demo() {
    log_step "Verifying Demo"

    export GLOO_IP=$(get_gloo_ip)

    echo ""
    log_info "Testing productpage access..."
    local status=$(curl -s -o /dev/null -w "%{http_code}" "http://$GLOO_IP/productpage" 2>/dev/null || echo "000")
    if [[ "$status" == "200" ]]; then
        log_success "Productpage accessible (HTTP $status)"
    else
        log_warn "Productpage returned HTTP $status"
    fi

    echo ""
    log_info "Bookinfo pods (cluster1):"
    kubectl --context "$CLUSTER1" get pods -n bookinfo

    echo ""
    log_info "Bookinfo pods (cluster2):"
    kubectl --context "$CLUSTER2" get pods -n bookinfo

    echo ""
    log_info "East-West gateways:"
    kubectl --context "$CLUSTER1" get gateways -n istio-gateways 2>/dev/null || echo "  Not configured yet"

    echo ""
    log_info "Waypoints:"
    kubectl --context "$CLUSTER1" get gateways -n bookinfo 2>/dev/null || echo "  Not configured yet"
}

test_all() {
    log_step "Running Full Workshop Test"

    # Run setup
    run_setup

    # Run demo
    run_demo

    # Verify everything
    verify_setup
    verify_demo

    # Test canary routing
    log_info "Testing canary routing..."
    local default_pod=$(kubectl --context "$CLUSTER1" exec -n bookinfo deploy/productpage-v1 -c productpage -- \
        curl -s reviews:9080/reviews/0 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('podname','unknown'))" 2>/dev/null || echo "error")
    local jason_pod=$(kubectl --context "$CLUSTER1" exec -n bookinfo deploy/productpage-v1 -c productpage -- \
        curl -s -H "end-user: jason" reviews:9080/reviews/0 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('podname','unknown'))" 2>/dev/null || echo "error")

    if [[ "$default_pod" == *"v1"* ]]; then
        log_success "Default routing to v1: $default_pod"
    else
        log_warn "Default routing check: $default_pod"
    fi

    if [[ "$jason_pod" == *"v2"* ]]; then
        log_success "Jason routing to v2: $jason_pod"
    else
        log_warn "Jason routing check: $jason_pod"
    fi

    # Test rate limiting
    log_info "Testing rate limiting..."
    local success=0
    local ratelimited=0
    for i in {1..10}; do
        local code=$(curl -s -o /dev/null -w "%{http_code}" "http://$GLOO_IP/productpage" 2>/dev/null)
        if [[ "$code" == "200" ]]; then
            ((success++))
        elif [[ "$code" == "429" ]]; then
            ((ratelimited++))
        fi
    done
    log_info "Rate limit test: $success successful, $ratelimited rate-limited"

    log_success "Full workshop test complete!"
}

#######################################
# RUN FUNCTIONS
#######################################

run_setup() {
    setup_1_gateway_api_crds
    setup_2_gloo_gateway
    setup_3_ingress_gateway
    setup_4_trust
    setup_5_gloo_operator_istio
    setup_6_gloo_platform
    setup_7_register_cluster2
    verify_setup
}

run_demo() {
    demo_1_onboarding
    demo_2_mtls_peering
    demo_3_observability
    demo_4_global_services
    demo_5_canary_ratelimit
    verify_demo
}

run_to_checkpoint() {
    local target=$1
    local checkpoints=(
        "setup-1" "setup-2" "setup-3" "setup-4" "setup-5" "setup-6" "setup-7"
        "demo-1" "demo-2" "demo-3" "demo-4" "demo-5"
    )
    local functions=(
        "setup_1_gateway_api_crds" "setup_2_gloo_gateway" "setup_3_ingress_gateway"
        "setup_4_trust" "setup_5_gloo_operator_istio" "setup_6_gloo_platform" "setup_7_register_cluster2"
        "demo_1_onboarding" "demo_2_mtls_peering" "demo_3_observability"
        "demo_4_global_services" "demo_5_canary_ratelimit"
    )

    local found=0
    for i in "${!checkpoints[@]}"; do
        ${functions[$i]}
        if [[ "${checkpoints[$i]}" == "$target" ]]; then
            found=1
            break
        fi
    done

    if [[ $found -eq 0 ]]; then
        log_error "Unknown checkpoint: $target"
        exit 1
    fi
}

run_step() {
    local step=$1
    case "$step" in
        setup-1) setup_1_gateway_api_crds ;;
        setup-2) setup_2_gloo_gateway ;;
        setup-3) setup_3_ingress_gateway ;;
        setup-4) setup_4_trust ;;
        setup-5) setup_5_gloo_operator_istio ;;
        setup-6) setup_6_gloo_platform ;;
        setup-7) setup_7_register_cluster2 ;;
        demo-1)  demo_1_onboarding ;;
        demo-2)  demo_2_mtls_peering ;;
        demo-3)  demo_3_observability ;;
        demo-4)  demo_4_global_services ;;
        demo-5)  demo_5_canary_ratelimit ;;
        *) log_error "Unknown step: $step"; exit 1 ;;
    esac
}

show_help() {
    cat << 'EOF'
Omni Workshop Script - Setup and Demo Automation

Usage:
  ./workshop.sh                    Show this help
  ./workshop.sh setup              Run all setup steps (1-7)
  ./workshop.sh demo               Run all demo steps (1-5)
  ./workshop.sh all                Run complete workshop (setup + demo)
  ./workshop.sh --to <checkpoint>  Run from start to checkpoint
  ./workshop.sh --step <step>      Run a single step only
  ./workshop.sh --test             Run full workshop with verification

Checkpoints:
  Setup Steps:
    setup-1    Gateway API CRDs
    setup-2    Gloo Gateway v2
    setup-3    Ingress Gateway
    setup-4    Trust Configuration (cacerts)
    setup-5    Gloo Operator + Istio Ambient
    setup-6    Gloo Management Plane
    setup-7    Cluster2 Registration

  Demo Steps:
    demo-1     Onboarding (deploy Bookinfo, add to mesh)
    demo-2     mTLS & Cluster Peering
    demo-3     Observability (generate traffic)
    demo-4     Global Services (multi-cluster failover)
    demo-5     Canary Routing & Rate Limiting

Examples:
  ./workshop.sh --to setup-5       Run setup through Istio installation
  ./workshop.sh --to demo-2        Run setup + demo through cluster peering
  ./workshop.sh --step demo-4      Run only the global services step
  ./workshop.sh --test             Full automated test run

EOF
}

#######################################
# MAIN
#######################################

main() {
    case "${1:-}" in
        setup)
            load_environment
            validate_prerequisites
            run_setup
            ;;
        demo)
            load_environment
            validate_prerequisites
            run_demo
            ;;
        all)
            load_environment
            validate_prerequisites
            run_setup
            run_demo
            ;;
        --to)
            load_environment
            validate_prerequisites
            run_to_checkpoint "${2:-}"
            ;;
        --step)
            load_environment
            validate_prerequisites
            run_step "${2:-}"
            ;;
        --test)
            load_environment
            validate_prerequisites
            test_all
            ;;
        --help|-h|"")
            show_help
            ;;
        *)
            log_error "Unknown command: $1"
            show_help
            exit 1
            ;;
    esac
}

main "$@"
