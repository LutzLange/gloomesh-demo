#!/bin/bash
set -e
set -o pipefail

# ================================================
# setup.sh - Multi-Tenant AuthorizationPolicy Test
# ================================================
#
# Tests AuthorizationPolicy enforcement at waypoint proxy
# in a multi-tenant ambient mesh setup with Gloo Gateway ingress.
#
# Structure:
#   gloo-system/        - Gloo Gateway (ingress)
#   tenant-a-baseline/  - waypoint proxy
#   tenant-a-ns1/       - httpbin (destination)
#   tenant-b-ns1/       - sleep (source/caller)
#
# Traffic flows:
#   1. Service-to-service: sleep -> waypoint -> httpbin
#   2. Ingress: Gloo Gateway -> waypoint -> httpbin
#
# Usage:
#   ./setup.sh -c env.sh                    # Run full setup + tests
#   ./setup.sh -c env.sh -s deploy_waypoint # Start from specific step
#   ./setup.sh -c env.sh --stop-after install_istio_ambient
#   ./setup.sh -c env.sh -l                 # List all steps
#   ./setup.sh -c env.sh --reset            # Clear progress, start fresh
#   ./setup.sh -c env.sh --tests-only       # Run tests only (skip setup)
#   ./setup.sh -c env.sh --cleanup          # Delete test namespaces
#

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ================================================
# Colors
# ================================================
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log_info()  { echo -e "${BLUE}[INFO]${NC} $1"; }
log_step()  { echo -e "\n${GREEN}==>${NC} ${YELLOW}$1${NC}"; }
log_pass()  { echo -e "${GREEN}[PASS]${NC} $1"; }
log_fail()  { echo -e "${RED}[FAIL]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# ================================================
# Setup Steps Definition
# ================================================
SETUP_STEPS=(
    "install_gateway_api_crds"
    "install_gloo_gateway"
    "create_ingress_gateway"
    "install_istio_ambient"
    "add_gloo_gateway_to_mesh"
    "create_tenant_namespaces"
    "deploy_waypoint"
    "deploy_workloads"
    "create_httpbin_route"
)

# ================================================
# Progress/Checkpoint System
# ================================================
CURRENT_STEP=""
START_FROM_STEP=""
STOP_AFTER_STEP=""
COMPLETED_STEPS=""

# Check if a step has been completed
step_completed() {
    local step="$1"
    if [ -z "$COMPLETED_STEPS" ]; then
        return 1
    fi
    [[ ",$COMPLETED_STEPS," == *",$step,"* ]]
}

# Mark a step as completed
mark_step_complete() {
    local step="$1"

    if step_completed "$step"; then
        return 0
    fi

    if [ -z "$COMPLETED_STEPS" ]; then
        COMPLETED_STEPS="$step"
    else
        COMPLETED_STEPS="${COMPLETED_STEPS},${step}"
    fi

    # Update progress file
    echo "COMPLETED_STEPS=\"${COMPLETED_STEPS}\"" > "$PROGRESS_FILE"
    log_info "Checkpoint saved: $step"
}

# Load progress from file
load_progress() {
    if [ -f "$PROGRESS_FILE" ]; then
        source "$PROGRESS_FILE"
        if [ -n "$COMPLETED_STEPS" ]; then
            log_info "Loaded progress: $COMPLETED_STEPS"
        fi
    fi
}

# Clear all progress
clear_progress() {
    COMPLETED_STEPS=""
    rm -f "$PROGRESS_FILE"
    log_info "Progress cleared"
}

# Check if we should run a step
should_run_step() {
    local step="$1"

    # If starting from a specific step, skip until we reach it
    if [ -n "$START_FROM_STEP" ]; then
        if [ "$step" = "$START_FROM_STEP" ]; then
            START_FROM_STEP=""  # Found it, run this and all subsequent
            return 0
        fi
        log_info "Skipping step: $step (starting from $START_FROM_STEP)"
        return 1
    fi

    # If step already completed, skip it
    if step_completed "$step"; then
        log_info "Skipping step: $step (already completed)"
        return 1
    fi

    return 0
}

# Check if we should stop after this step
should_stop_after() {
    local step="$1"
    if [ -n "$STOP_AFTER_STEP" ] && [ "$step" = "$STOP_AFTER_STEP" ]; then
        return 0
    fi
    return 1
}

# Run a setup step with progress tracking
run_step() {
    local step_name="$1"
    local step_function="$2"

    CURRENT_STEP="$step_name"

    if ! should_run_step "$step_name"; then
        if should_stop_after "$step_name"; then
            log_info "Stopping after step: $step_name (as requested)"
            return 2
        fi
        return 0
    fi

    # Run the step function
    if $step_function; then
        mark_step_complete "$step_name"

        if should_stop_after "$step_name"; then
            log_info "Stopping after step: $step_name (as requested)"
            return 2
        fi
        return 0
    else
        log_error "Step '$step_name' failed"
        log_error "To retry from this step, run: $0 -c $CONFIG_FILE -s $step_name"
        return 1
    fi
}

# Get step name by number
get_step_by_number() {
    local num="$1"
    shift
    local steps=("$@")

    if [[ "$num" =~ ^[0-9]+$ ]] && [ "$num" -ge 1 ] && [ "$num" -le "${#steps[@]}" ]; then
        echo "${steps[$((num-1))]}"
    else
        echo "$num"
    fi
}

# List all steps and their status
list_steps() {
    echo ""
    echo "=============================================="
    echo "           SETUP STEPS STATUS"
    echo "=============================================="
    echo ""
    printf "%-5s %-30s %-12s\n" "NUM" "STEP NAME" "STATUS"
    echo "----------------------------------------------"

    local num=1
    for step in "${SETUP_STEPS[@]}"; do
        local status
        if step_completed "$step"; then
            status="${GREEN}completed${NC}"
        else
            status="${YELLOW}pending${NC}"
        fi
        printf "%-5s %-30s " "$num" "$step"
        echo -e "$status"
        ((num++))
    done

    echo "----------------------------------------------"
    echo ""
    echo "To start from a specific step:"
    echo "  $0 -c $CONFIG_FILE -s <step_name_or_number>"
    echo ""
    echo "To stop after a specific step:"
    echo "  $0 -c $CONFIG_FILE --stop-after <step_name>"
    echo ""
    echo "To reset progress and start fresh:"
    echo "  $0 -c $CONFIG_FILE --reset"
    echo ""
}

# ================================================
# Test tracking
# ================================================
TESTS_PASSED=0
TESTS_FAILED=0

record_test() {
    local name="$1"
    local expected="$2"
    local actual="$3"

    if [[ "$actual" == *"$expected"* ]]; then
        log_pass "$name (expected: $expected, got: $actual)"
        ((++TESTS_PASSED)) || true
    else
        log_fail "$name (expected: $expected, got: $actual)"
        ((++TESTS_FAILED)) || true
    fi
}

# ================================================
# Configuration
# ================================================
usage() {
    echo "Usage: $0 -c <config_file> [options]"
    echo ""
    echo "Options:"
    echo "  -c, --config FILE       Config file (required)"
    echo "  -s, --step STEP         Start from a specific step (name or number)"
    echo "  --stop-after STEP       Stop after completing a specific step"
    echo "  -l, --list              List all steps and their completion status"
    echo "  --reset                 Clear progress and start fresh"
    echo "  --tests-only            Skip setup, run tests only"
    echo "  --cleanup               Delete test namespaces"
    echo "  -h, --help              Show this help"
    echo ""
    echo "Required config variables:"
    echo "  CLUSTER1                   - Kubernetes context for the target cluster"
    echo "  GLOO_GATEWAY_LICENSE_KEY   - License key for Gloo Gateway"
    echo "  GLOO_MESH_LICENSE_KEY      - License key for Gloo Mesh"
    echo ""
    echo "Steps:"
    local num=1
    for step in "${SETUP_STEPS[@]}"; do
        printf "  %2d. %s\n" "$num" "$step"
        ((num++))
    done
    echo ""
    echo "Examples:"
    echo "  $0 -c env.sh                           # Run full setup + tests"
    echo "  $0 -c env.sh -s deploy_waypoint        # Start from waypoint step"
    echo "  $0 -c env.sh -s 8                      # Start from step 8"
    echo "  $0 -c env.sh --stop-after install_istio_ambient"
    echo "  $0 -c env.sh -l                        # Show progress"
    exit 0
}

parse_arguments() {
    CONFIG_FILE=""
    TESTS_ONLY=false
    DO_CLEANUP=false
    RESET_PROGRESS=false
    LIST_STEPS=false

    while [[ $# -gt 0 ]]; do
        case $1 in
            -c|--config)
                CONFIG_FILE="$2"
                shift 2
                ;;
            -s|--step)
                START_FROM_STEP="$2"
                shift 2
                ;;
            --stop-after)
                STOP_AFTER_STEP="$2"
                shift 2
                ;;
            -l|--list)
                LIST_STEPS=true
                shift
                ;;
            --reset)
                RESET_PROGRESS=true
                shift
                ;;
            --tests-only)
                TESTS_ONLY=true
                shift
                ;;
            --cleanup)
                DO_CLEANUP=true
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

    # Config file is required
    if [ -z "$CONFIG_FILE" ]; then
        log_error "Config file required: -c <config_file>"
        usage
    fi

    # Validate config file exists
    if [ ! -f "$CONFIG_FILE" ]; then
        log_error "Config file not found: $CONFIG_FILE"
        exit 1
    fi

    # Set progress file based on config file name
    local config_basename=$(basename "$CONFIG_FILE" .sh)
    export PROGRESS_FILE="/tmp/setup-progress-${config_basename}"

    # Convert step number to name if needed
    if [ -n "$START_FROM_STEP" ]; then
        START_FROM_STEP="$(get_step_by_number "$START_FROM_STEP" "${SETUP_STEPS[@]}")"
    fi
    if [ -n "$STOP_AFTER_STEP" ]; then
        STOP_AFTER_STEP="$(get_step_by_number "$STOP_AFTER_STEP" "${SETUP_STEPS[@]}")"
    fi
}

load_config() {
    source "$CONFIG_FILE"
    log_info "Loaded config from: $CONFIG_FILE"

    # Validate required variables
    local missing=()
    [[ -z "${CLUSTER1:-}" ]] && missing+=("CLUSTER1")
    [[ -z "${GLOO_GATEWAY_LICENSE_KEY:-}" ]] && missing+=("GLOO_GATEWAY_LICENSE_KEY")
    [[ -z "${GLOO_MESH_LICENSE_KEY:-}" ]] && missing+=("GLOO_MESH_LICENSE_KEY")
    [[ -z "${HUB:-}" ]] && missing+=("HUB")
    [[ -z "${ISTIO_TAG:-}" ]] && missing+=("ISTIO_TAG")

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required variables: ${missing[*]}"
        log_error "Example: HUB=us-docker.pkg.dev/gloo-mesh/istio-xxxxx ISTIO_TAG=1.28.1"
        exit 1
    fi

    # Defaults
    export ISTIO_VERSION="${ISTIO_VERSION:-${ISTIO_TAG}}"
    export GLOO_GATEWAY_VERSION="${GLOO_GATEWAY_VERSION:-2.0.1}"
    export GATEWAY_API_VERSION="${GATEWAY_API_VERSION:-v1.2.1}"

    # Verify cluster connectivity
    if ! kubectl --context "$CLUSTER1" cluster-info &>/dev/null; then
        log_error "Cannot connect to cluster: $CLUSTER1"
        exit 1
    fi

    log_info "Cluster: $CLUSTER1"
    log_info "Istio version: $ISTIO_VERSION"
    log_info "Gloo Gateway version: $GLOO_GATEWAY_VERSION"
}

# ================================================
# Setup Step Functions (do_*)
# ================================================

do_install_gateway_api_crds() {
    log_step "1. Installing Gateway API CRDs"

    kubectl --context "$CLUSTER1" apply -f \
        "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"

    log_info "Gateway API CRDs installed"
}

do_install_gloo_gateway() {
    log_step "2. Installing Gloo Gateway"

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
    kubectl --context "$CLUSTER1" rollout status deployment/gloo-gateway -n gloo-system --timeout=120s
}

do_create_ingress_gateway() {
    log_step "3. Creating Ingress Gateway"

    kubectl --context "$CLUSTER1" apply -f - <<EOF
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

    log_info "Waiting for LoadBalancer IP (timeout: 10 minutes)..."
    for i in {1..120}; do
        GLOO_IP=$(kubectl get svc -n gloo-system http --context "$CLUSTER1" \
            -o jsonpath="{.status.loadBalancer.ingress[0]['hostname','ip']}" 2>/dev/null || true)
        if [[ -n "$GLOO_IP" ]]; then
            echo ""
            log_info "Gloo Gateway IP: $GLOO_IP"
            export GLOO_IP
            return 0
        fi
        echo -n "."
        sleep 5
    done
    echo ""
    log_error "Timeout waiting for LoadBalancer IP"
    return 1
}

do_install_istio_ambient() {
    log_step "4. Installing Istio Ambient via istioctl"

    # Check if istioctl is available
    local ISTIOCTL="${ISTIOCTL:-$HOME/.istioctl/bin/istioctl}"
    if [ ! -f "$ISTIOCTL" ]; then
        log_error "istioctl not found at: $ISTIOCTL"
        log_error "Set ISTIOCTL environment variable to point to your istioctl binary."
        return 1
    fi

    # Verify istioctl is the Solo.io version
    local client_version
    client_version=$("$ISTIOCTL" version --short 2>/dev/null | head -1 | awk '{print $NF}')
    if [[ ! "$client_version" =~ -solo ]]; then
        log_error "istioctl is not the Solo.io distribution: $client_version"
        return 1
    fi
    log_info "Using istioctl version: $client_version"

    kubectl --context "$CLUSTER1" create ns istio-system 2>/dev/null || true

    log_info "Installing Istio Ambient..."
    cat <<EOF | "$ISTIOCTL" install --context="$CLUSTER1" -y -f -
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
spec:
  profile: ambient
  meshConfig:
    accessLogFile: /dev/stdout
  values:
    global:
      hub: ${HUB}
      tag: ${ISTIO_TAG}
    license:
      value: ${GLOO_MESH_LICENSE_KEY}
    cni:
      ambient:
        dnsCapture: true
    pilot:
      env:
        PILOT_ENABLE_ALPHA_GATEWAY_API: "true"
EOF

    if [ $? -ne 0 ]; then
        log_error "Failed to install Istio"
        return 1
    fi

    log_info "Waiting for Istio components..."
    kubectl --context "$CLUSTER1" rollout status deployment/istiod -n istio-system --timeout=120s
    kubectl --context "$CLUSTER1" rollout status daemonset/ztunnel -n istio-system --timeout=120s
    kubectl --context "$CLUSTER1" rollout status daemonset/istio-cni-node -n istio-system --timeout=120s

    log_info "Istio Ambient installed successfully"
}

do_add_gloo_gateway_to_mesh() {
    log_step "5. Adding Gloo Gateway to ambient mesh"

    kubectl --context "$CLUSTER1" label ns gloo-system istio.io/dataplane-mode=ambient --overwrite

    # The Gateway proxy deployment is named after the Gateway resource (default: "http")
    local gateway_deployment="http"

    # Wait for gateway proxy deployment to exist
    log_info "Waiting for $gateway_deployment deployment (timeout: 2 minutes)..."
    for i in {1..60}; do
        if kubectl --context "$CLUSTER1" get deployment/$gateway_deployment -n gloo-system &>/dev/null; then
            echo ""
            log_info "$gateway_deployment deployment found"
            break
        fi
        echo -n "."
        sleep 2
    done

    if ! kubectl --context "$CLUSTER1" get deployment/$gateway_deployment -n gloo-system &>/dev/null; then
        echo ""
        log_error "Timeout waiting for $gateway_deployment deployment"
        return 1
    fi

    # Restart gateway pods to pick up ztunnel
    kubectl --context "$CLUSTER1" rollout restart deployment/$gateway_deployment -n gloo-system
    kubectl --context "$CLUSTER1" rollout status deployment/$gateway_deployment -n gloo-system --timeout=120s

    log_info "Gloo Gateway added to mesh"
}

do_create_tenant_namespaces() {
    log_step "6. Creating tenant namespaces"

    # Tenant A: baseline (waypoint) + workload namespace
    kubectl --context "$CLUSTER1" create ns tenant-a-baseline 2>/dev/null || true
    kubectl --context "$CLUSTER1" create ns tenant-a-ns1 2>/dev/null || true

    # Tenant B: workload namespace
    kubectl --context "$CLUSTER1" create ns tenant-b-ns1 2>/dev/null || true

    # Add all to ambient mesh
    for ns in tenant-a-baseline tenant-a-ns1 tenant-b-ns1; do
        kubectl --context "$CLUSTER1" label ns "$ns" istio.io/dataplane-mode=ambient --overwrite
        log_info "Added $ns to ambient mesh"
    done

    # Configure tenant-a-ns1 to use waypoint from tenant-a-baseline
    # Also enable ingress traffic to route through the waypoint
    kubectl --context "$CLUSTER1" label ns tenant-a-ns1 \
        istio.io/use-waypoint=waypoint \
        istio.io/use-waypoint-namespace=tenant-a-baseline \
        istio.io/ingress-use-waypoint=true \
        --overwrite

    log_info "tenant-a-ns1 configured to use waypoint from tenant-a-baseline (including ingress)"
}

do_deploy_waypoint() {
    log_step "7. Deploying waypoint in tenant-a-baseline"

    # Cross-namespace waypoint requires allowedRoutes.namespaces.from: All
    # waypoint-for: all handles both service and workload (pod IP) traffic
    kubectl --context "$CLUSTER1" apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: waypoint
  namespace: tenant-a-baseline
  labels:
    istio.io/waypoint-for: all
spec:
  gatewayClassName: istio-waypoint
  listeners:
  - name: mesh
    port: 15008
    protocol: HBONE
    allowedRoutes:
      namespaces:
        from: All
EOF

    log_info "Waiting for waypoint pod (timeout: 2 minutes)..."
    for i in {1..60}; do
        local phase=$(kubectl --context "$CLUSTER1" get pods -n tenant-a-baseline -l gateway.networking.k8s.io/gateway-name=waypoint -o jsonpath='{.items[0].status.phase}' 2>/dev/null || true)
        if [[ "$phase" == "Running" ]]; then
            echo ""
            log_info "Waypoint ready"
            return 0
        fi
        echo -n "."
        sleep 2
    done
    echo ""
    log_error "Waypoint not ready"
    return 1
}

do_deploy_workloads() {
    log_step "8. Deploying workloads"

    log_info "Deploying httpbin in tenant-a-ns1..."
    kubectl --context "$CLUSTER1" apply -n tenant-a-ns1 -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: httpbin
---
apiVersion: v1
kind: Service
metadata:
  name: httpbin
spec:
  ports:
  - port: 8000
    targetPort: 80
    name: http
  selector:
    app: httpbin
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: httpbin
spec:
  replicas: 1
  selector:
    matchLabels:
      app: httpbin
  template:
    metadata:
      labels:
        app: httpbin
    spec:
      serviceAccountName: httpbin
      containers:
      - name: httpbin
        image: kong/httpbin:0.1.0
        ports:
        - containerPort: 80
EOF

    log_info "Deploying sleep in tenant-b-ns1..."
    kubectl --context "$CLUSTER1" apply -n tenant-b-ns1 -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: sleep
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: sleep
spec:
  replicas: 1
  selector:
    matchLabels:
      app: sleep
  template:
    metadata:
      labels:
        app: sleep
    spec:
      serviceAccountName: sleep
      containers:
      - name: sleep
        image: curlimages/curl:8.6.0
        command: ["/bin/sleep", "infinity"]
EOF

    log_info "Waiting for workloads..."
    kubectl --context "$CLUSTER1" rollout status deployment/httpbin -n tenant-a-ns1 --timeout=120s
    kubectl --context "$CLUSTER1" rollout status deployment/sleep -n tenant-b-ns1 --timeout=120s
}

do_create_httpbin_route() {
    log_step "9. Creating HTTPRoute for httpbin ingress"

    # Create a static Backend that routes to the Service VIP (not pod IPs via EDS)
    # This is critical for AuthorizationPolicy enforcement in ambient mode:
    # - EDS routing (default) sends traffic to pod IPs -> waypoint's "direct-http" chain -> NO RBAC
    # - Static Backend routes to service VIP -> waypoint's "inbound-vip" chain -> RBAC enforced
    log_info "Creating static Backend for httpbin (routes via Service VIP)"
    kubectl --context "$CLUSTER1" apply -f - <<EOF
apiVersion: gateway.kgateway.dev/v1alpha1
kind: Backend
metadata:
  name: httpbin-vip
  namespace: tenant-a-ns1
spec:
  type: Static
  static:
    hosts:
    - host: httpbin.tenant-a-ns1.svc.cluster.local
      port: 8000
EOF

    log_info "Creating HTTPRoute referencing static Backend"
    kubectl --context "$CLUSTER1" apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: httpbin
  namespace: tenant-a-ns1
spec:
  parentRefs:
  - name: http
    namespace: gloo-system
  hostnames:
  - "httpbin.example.com"
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /
    backendRefs:
    - name: httpbin-vip
      kind: Backend
      group: gateway.kgateway.dev
EOF

    log_info "HTTPRoute created for httpbin (via static Backend)"
}

# ================================================
# Run Setup Steps
# ================================================
run_setup_steps() {
    local rc

    run_step "install_gateway_api_crds" do_install_gateway_api_crds; rc=$?
    [ $rc -eq 1 ] && return 1
    [ $rc -eq 2 ] && return 0

    run_step "install_gloo_gateway" do_install_gloo_gateway; rc=$?
    [ $rc -eq 1 ] && return 1
    [ $rc -eq 2 ] && return 0

    run_step "create_ingress_gateway" do_create_ingress_gateway; rc=$?
    [ $rc -eq 1 ] && return 1
    [ $rc -eq 2 ] && return 0

    run_step "install_istio_ambient" do_install_istio_ambient; rc=$?
    [ $rc -eq 1 ] && return 1
    [ $rc -eq 2 ] && return 0

    run_step "add_gloo_gateway_to_mesh" do_add_gloo_gateway_to_mesh; rc=$?
    [ $rc -eq 1 ] && return 1
    [ $rc -eq 2 ] && return 0

    run_step "create_tenant_namespaces" do_create_tenant_namespaces; rc=$?
    [ $rc -eq 1 ] && return 1
    [ $rc -eq 2 ] && return 0

    run_step "deploy_waypoint" do_deploy_waypoint; rc=$?
    [ $rc -eq 1 ] && return 1
    [ $rc -eq 2 ] && return 0

    run_step "deploy_workloads" do_deploy_workloads; rc=$?
    [ $rc -eq 1 ] && return 1
    [ $rc -eq 2 ] && return 0

    run_step "create_httpbin_route" do_create_httpbin_route; rc=$?
    [ $rc -eq 1 ] && return 1
    [ $rc -eq 2 ] && return 0

    log_info "All setup steps completed!"
    return 0
}

# ================================================
# Test Functions
# ================================================

call_httpbin() {
    local from_ns="$1"
    local from_sa="$2"
    local expected_desc="$3"

    local result
    result=$(kubectl --context "$CLUSTER1" exec -n "$from_ns" deploy/sleep -c sleep -- \
        curl -s -o /dev/null -w "%{http_code}" \
        --max-time 5 \
        http://httpbin.tenant-a-ns1:8000/get 2>/dev/null || echo "000")

    echo "$result"
}

call_httpbin_ingress() {
    local result
    result=$(curl -s -o /dev/null -w "%{http_code}" \
        --max-time 5 \
        -H "Host: httpbin.example.com" \
        "http://${GLOO_IP}/get" 2>/dev/null || echo "000")

    echo "$result"
}

test_no_policy() {
    log_step "Test 1: No policy - should ALLOW (permissive default)"

    kubectl --context "$CLUSTER1" delete authorizationpolicy --all -n tenant-a-ns1 2>/dev/null || true
    kubectl --context "$CLUSTER1" delete authorizationpolicy --all -n tenant-a-baseline 2>/dev/null || true

    # Wait for policy deletion to propagate to waypoint (can take several seconds)
    log_info "Waiting for policy deletion to propagate..."
    sleep 8

    local result=$(call_httpbin tenant-b-ns1 sleep "no policy")
    record_test "Service-to-service: No policy (permissive)" "200" "$result"

    local ingress_result=$(call_httpbin_ingress)
    record_test "Ingress: No policy (permissive)" "200" "$ingress_result"
}

apply_deny_all() {
    log_step "Applying baseline DENY-all policy"

    kubectl --context "$CLUSTER1" apply -f - <<EOF
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: deny-all
  namespace: tenant-a-ns1
spec:
  targetRefs:
  - kind: Service
    group: ""
    name: httpbin
  action: DENY
  rules:
  - {}
EOF

    # Wait for policy to propagate to waypoint
    log_info "Waiting for policy to propagate..."
    sleep 8
}

test_deny_all() {
    log_step "Test 2: DENY-all policy - should block all traffic"

    local result=$(call_httpbin tenant-b-ns1 sleep "deny all")
    record_test "Service-to-service: DENY-all blocks traffic" "403" "$result"

    local ingress_result=$(call_httpbin_ingress)
    record_test "Ingress: DENY-all blocks traffic" "403" "$ingress_result"
}

apply_allow_tenant_b() {
    log_step "Applying ALLOW policy for tenant-b-ns1/sleep"

    kubectl --context "$CLUSTER1" delete authorizationpolicy deny-all -n tenant-a-ns1 2>/dev/null || true

    kubectl --context "$CLUSTER1" apply -f - <<EOF
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: allow-tenant-b-sleep
  namespace: tenant-a-ns1
spec:
  targetRefs:
  - kind: Service
    group: ""
    name: httpbin
  action: ALLOW
  rules:
  - from:
    - source:
        principals:
        - cluster.local/ns/tenant-b-ns1/sa/sleep
EOF

    # Wait for policy to propagate to waypoint
    log_info "Waiting for policy to propagate..."
    sleep 8
}

test_allow_tenant_b() {
    log_step "Test 3: ALLOW policy for tenant-b-ns1/sleep - should succeed"

    local result=$(call_httpbin tenant-b-ns1 sleep "allow tenant-b")
    record_test "Service-to-service: ALLOW tenant-b-ns1/sleep" "200" "$result"

    local ingress_result=$(call_httpbin_ingress)
    record_test "Ingress: Still denied (not in allow list)" "403" "$ingress_result"
}

apply_allow_with_ingress() {
    log_step "Updating ALLOW policy to include Gloo Gateway"

    kubectl --context "$CLUSTER1" apply -f - <<EOF
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: allow-tenant-b-sleep
  namespace: tenant-a-ns1
spec:
  targetRefs:
  - kind: Service
    group: ""
    name: httpbin
  action: ALLOW
  rules:
  - from:
    - source:
        principals:
        - cluster.local/ns/tenant-b-ns1/sa/sleep
        - cluster.local/ns/gloo-system/sa/http  # Gloo Gateway proxy SA
EOF

    # Wait for policy update to propagate to waypoint (updates can take longer than creates)
    log_info "Waiting for policy update to propagate..."
    sleep 8
}

test_allow_with_ingress() {
    log_step "Test 4: ALLOW policy includes Gloo Gateway - ingress should work"

    local result=$(call_httpbin tenant-b-ns1 sleep "allow with ingress")
    record_test "Service-to-service: Still allowed" "200" "$result"

    local ingress_result=$(call_httpbin_ingress)
    record_test "Ingress: Now allowed (gloo-system/http in allow list)" "200" "$ingress_result"
}

deploy_wrong_sa_pod() {
    log_step "Deploying sleep with different SA in tenant-b-ns1"

    kubectl --context "$CLUSTER1" apply -n tenant-b-ns1 -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: other-sa
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: sleep-other
spec:
  replicas: 1
  selector:
    matchLabels:
      app: sleep-other
  template:
    metadata:
      labels:
        app: sleep-other
    spec:
      serviceAccountName: other-sa
      containers:
      - name: sleep
        image: curlimages/curl:8.6.0
        command: ["/bin/sleep", "infinity"]
EOF

    kubectl --context "$CLUSTER1" rollout status deployment/sleep-other -n tenant-b-ns1 --timeout=60s
}

test_wrong_sa() {
    log_step "Test 5: Wrong SA (other-sa) - should be DENIED"

    local result
    result=$(kubectl --context "$CLUSTER1" exec -n tenant-b-ns1 deploy/sleep-other -c sleep -- \
        curl -s -o /dev/null -w "%{http_code}" \
        --max-time 5 \
        http://httpbin.tenant-a-ns1:8000/get 2>/dev/null || echo "000")

    record_test "Service-to-service: Wrong SA denied" "403" "$result"
}

test_correct_sa_still_works() {
    log_step "Test 6: Correct SA (sleep) - should still work"

    local result=$(call_httpbin tenant-b-ns1 sleep "correct sa")
    record_test "Service-to-service: Correct SA still allowed" "200" "$result"

    local ingress_result=$(call_httpbin_ingress)
    record_test "Ingress: Still allowed" "200" "$ingress_result"
}

# ================================================
# Summary
# ================================================

print_summary() {
    echo ""
    echo "=============================================="
    echo "               TEST SUMMARY"
    echo "=============================================="
    echo ""
    echo "Passed: $TESTS_PASSED"
    echo "Failed: $TESTS_FAILED"
    echo ""

    if [[ $TESTS_FAILED -eq 0 ]]; then
        log_pass "All tests passed!"
        return 0
    else
        log_fail "$TESTS_FAILED test(s) failed"
        return 1
    fi
}

# ================================================
# Cleanup
# ================================================

cleanup() {
    log_step "Cleaning up test namespaces"

    kubectl --context "$CLUSTER1" delete ns tenant-a-baseline tenant-a-ns1 tenant-b-ns1 --ignore-not-found

    log_info "Cleanup complete"
}

# ================================================
# Main
# ================================================

print_header() {
    echo ""
    echo "=============================================="
    echo "     AUTHZ POLICY TEST SETUP"
    echo "=============================================="
    echo ""
    log_info "Config file: $CONFIG_FILE"
    log_info "CLUSTER1: $CLUSTER1"
    if [ -n "$START_FROM_STEP" ]; then
        log_info "Starting from step: $START_FROM_STEP"
    fi
    if [ -n "$STOP_AFTER_STEP" ]; then
        log_info "Stopping after step: $STOP_AFTER_STEP"
    fi
    echo ""
}

main() {
    parse_arguments "$@"
    load_config
    load_progress

    # Handle --list option
    if [ "$LIST_STEPS" = true ]; then
        list_steps
        exit 0
    fi

    # Handle --reset option
    if [ "$RESET_PROGRESS" = true ]; then
        clear_progress
    fi

    # Handle --cleanup option
    if [ "$DO_CLEANUP" = true ]; then
        cleanup
        exit 0
    fi

    print_header

    if [ "$TESTS_ONLY" = true ]; then
        log_info "Tests-only mode - skipping setup steps"
        # Get GLOO_IP for tests
        GLOO_IP=$(kubectl get svc -n gloo-system http --context "$CLUSTER1" \
            -o jsonpath="{.status.loadBalancer.ingress[0]['hostname','ip']}" 2>/dev/null || true)
        export GLOO_IP
        log_info "Using Gloo Gateway IP: $GLOO_IP"
    else
        # Run setup steps
        if ! run_setup_steps; then
            log_error "Setup failed"
            log_error "To retry from last step: $0 -c $CONFIG_FILE -s $CURRENT_STEP"
            exit 1
        fi

        # Get GLOO_IP after setup
        GLOO_IP=$(kubectl get svc -n gloo-system http --context "$CLUSTER1" \
            -o jsonpath="{.status.loadBalancer.ingress[0]['hostname','ip']}" 2>/dev/null || true)
        export GLOO_IP
    fi

    # Run tests
    log_step "Running AuthorizationPolicy Tests"

    test_no_policy
    apply_deny_all
    test_deny_all
    apply_allow_tenant_b
    test_allow_tenant_b
    apply_allow_with_ingress
    test_allow_with_ingress
    deploy_wrong_sa_pod
    test_wrong_sa
    test_correct_sa_still_works

    print_summary
}

main "$@"
