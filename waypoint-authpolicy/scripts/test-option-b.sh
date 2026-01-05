#!/bin/bash
set -e
set -o pipefail

# ================================================
# test-option-b.sh - Tenant Self-Service AuthorizationPolicy Test
# ================================================
#
# Tests Option B: Tenant policies in workload namespaces with targetRefs
#
# Scenario:
#   - Platform team manages tenant-a-baseline (waypoint only, NO policies)
#   - Tenants create their own namespaces (tenant-a-ns1, tenant-a-ns2)
#   - Tenants create AuthorizationPolicies in THEIR namespaces
#   - Policies use targetRefs to Services and auto-attach to waypoint
#
# Structure:
#   gloo-system/        - Gloo Gateway (ingress)
#   tenant-a-baseline/  - waypoint proxy (platform managed, NO policies)
#   tenant-a-ns1/       - httpbin + tenant-created policies
#   tenant-a-ns2/       - sleep (intra-tenant caller)
#   tenant-b-ns1/       - sleep (cross-tenant caller)
#
# Key validation:
#   1. Policy created in tenant namespace attaches to waypoint
#   2. Policy status shows "bound to tenant-a-baseline/waypoint"
#   3. Tenant can allow specific sources without platform involvement
#
# Usage:
#   ./test-option-b.sh -c env.sh                    # Run full setup + tests
#   ./test-option-b.sh -c env.sh --tests-only       # Run tests only
#   ./test-option-b.sh -c env.sh --cleanup          # Delete test namespaces
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

step_completed() {
    local step="$1"
    if [ -z "$COMPLETED_STEPS" ]; then
        return 1
    fi
    [[ ",$COMPLETED_STEPS," == *",$step,"* ]]
}

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

    echo "COMPLETED_STEPS=\"${COMPLETED_STEPS}\"" > "$PROGRESS_FILE"
    log_info "Checkpoint saved: $step"
}

load_progress() {
    if [ -f "$PROGRESS_FILE" ]; then
        source "$PROGRESS_FILE"
        if [ -n "$COMPLETED_STEPS" ]; then
            log_info "Loaded progress: $COMPLETED_STEPS"
        fi
    fi
}

clear_progress() {
    COMPLETED_STEPS=""
    rm -f "$PROGRESS_FILE"
    log_info "Progress cleared"
}

should_run_step() {
    local step="$1"

    if [ -n "$START_FROM_STEP" ]; then
        if [ "$step" = "$START_FROM_STEP" ]; then
            START_FROM_STEP=""
            return 0
        fi
        log_info "Skipping step: $step (starting from $START_FROM_STEP)"
        return 1
    fi

    if step_completed "$step"; then
        log_info "Skipping step: $step (already completed)"
        return 1
    fi

    return 0
}

should_stop_after() {
    local step="$1"
    if [ -n "$STOP_AFTER_STEP" ] && [ "$step" = "$STOP_AFTER_STEP" ]; then
        return 0
    fi
    return 1
}

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

    if [ -z "$CONFIG_FILE" ]; then
        log_error "Config file required: -c <config_file>"
        usage
    fi

    if [ ! -f "$CONFIG_FILE" ]; then
        log_error "Config file not found: $CONFIG_FILE"
        exit 1
    fi

    local config_basename=$(basename "$CONFIG_FILE" .sh)
    export PROGRESS_FILE="/tmp/test-option-b-progress-${config_basename}"

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

    local missing=()
    [[ -z "${CLUSTER1:-}" ]] && missing+=("CLUSTER1")
    [[ -z "${GLOO_GATEWAY_LICENSE_KEY:-}" ]] && missing+=("GLOO_GATEWAY_LICENSE_KEY")
    [[ -z "${GLOO_MESH_LICENSE_KEY:-}" ]] && missing+=("GLOO_MESH_LICENSE_KEY")
    [[ -z "${HUB:-}" ]] && missing+=("HUB")
    [[ -z "${ISTIO_TAG:-}" ]] && missing+=("ISTIO_TAG")

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required variables: ${missing[*]}"
        exit 1
    fi

    export ISTIO_VERSION="${ISTIO_VERSION:-${ISTIO_TAG}}"
    export GLOO_GATEWAY_VERSION="${GLOO_GATEWAY_VERSION:-2.0.1}"
    export GATEWAY_API_VERSION="${GATEWAY_API_VERSION:-v1.2.1}"

    if ! kubectl --context "$CLUSTER1" cluster-info &>/dev/null; then
        log_error "Cannot connect to cluster: $CLUSTER1"
        exit 1
    fi

    log_info "Cluster: $CLUSTER1"
    log_info "Istio version: $ISTIO_VERSION"
    log_info "Gloo Gateway version: $GLOO_GATEWAY_VERSION"
}

# ================================================
# Setup Step Functions
# ================================================

do_install_gateway_api_crds() {
    log_step "1. Installing Gateway API CRDs"

    kubectl --context "$CLUSTER1" apply -f \
        "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"

    log_info "Gateway API CRDs installed"
}

do_install_gloo_gateway() {
    log_step "2. Installing Gloo Gateway"

    helm upgrade -i --create-namespace --namespace gloo-system \
        --kube-context "$CLUSTER1" \
        --version "$GLOO_GATEWAY_VERSION" \
        gloo-gateway-crds oci://us-docker.pkg.dev/solo-public/gloo-gateway/charts/gloo-gateway-crds

    helm upgrade -i -n gloo-system gloo-gateway \
        oci://us-docker.pkg.dev/solo-public/gloo-gateway/charts/gloo-gateway \
        --kube-context "$CLUSTER1" \
        --version "$GLOO_GATEWAY_VERSION" \
        --set licensing.glooGatewayLicenseKey="$GLOO_GATEWAY_LICENSE_KEY"

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

    log_info "Waiting for LoadBalancer IP..."
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
    log_step "4. Installing Istio Ambient"

    local ISTIOCTL="${ISTIOCTL:-$HOME/.istioctl/bin/istioctl}"
    if [ ! -f "$ISTIOCTL" ]; then
        log_error "istioctl not found at: $ISTIOCTL"
        return 1
    fi

    kubectl --context "$CLUSTER1" create ns istio-system 2>/dev/null || true

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

    kubectl --context "$CLUSTER1" rollout status deployment/istiod -n istio-system --timeout=120s
    kubectl --context "$CLUSTER1" rollout status daemonset/ztunnel -n istio-system --timeout=120s
    kubectl --context "$CLUSTER1" rollout status daemonset/istio-cni-node -n istio-system --timeout=120s

    log_info "Istio Ambient installed"
}

do_add_gloo_gateway_to_mesh() {
    log_step "5. Adding Gloo Gateway to ambient mesh"

    kubectl --context "$CLUSTER1" label ns gloo-system istio.io/dataplane-mode=ambient --overwrite

    local gateway_deployment="http"
    for i in {1..60}; do
        if kubectl --context "$CLUSTER1" get deployment/$gateway_deployment -n gloo-system &>/dev/null; then
            break
        fi
        sleep 2
    done

    kubectl --context "$CLUSTER1" rollout restart deployment/$gateway_deployment -n gloo-system
    kubectl --context "$CLUSTER1" rollout status deployment/$gateway_deployment -n gloo-system --timeout=120s

    log_info "Gloo Gateway added to mesh"
}

do_create_tenant_namespaces() {
    log_step "6. Creating tenant namespaces"

    # Platform managed: tenant-a-baseline (waypoint only)
    kubectl --context "$CLUSTER1" create ns tenant-a-baseline 2>/dev/null || true

    # Tenant A namespaces (self-service)
    kubectl --context "$CLUSTER1" create ns tenant-a-ns1 2>/dev/null || true
    kubectl --context "$CLUSTER1" create ns tenant-a-ns2 2>/dev/null || true

    # Tenant B namespace (cross-tenant test)
    kubectl --context "$CLUSTER1" create ns tenant-b-ns1 2>/dev/null || true

    # Add all to ambient mesh
    for ns in tenant-a-baseline tenant-a-ns1 tenant-a-ns2 tenant-b-ns1; do
        kubectl --context "$CLUSTER1" label ns "$ns" istio.io/dataplane-mode=ambient --overwrite
        log_info "Added $ns to ambient mesh"
    done

    # Configure tenant-a namespaces to use waypoint from tenant-a-baseline
    for ns in tenant-a-ns1 tenant-a-ns2; do
        kubectl --context "$CLUSTER1" label ns "$ns" \
            istio.io/use-waypoint=waypoint \
            istio.io/use-waypoint-namespace=tenant-a-baseline \
            istio.io/ingress-use-waypoint=true \
            --overwrite
        log_info "$ns configured to use waypoint from tenant-a-baseline"
    done
}

do_deploy_waypoint() {
    log_step "7. Deploying waypoint in tenant-a-baseline (platform managed)"

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

    log_info "Waiting for waypoint pod..."
    for i in {1..60}; do
        local phase=$(kubectl --context "$CLUSTER1" get pods -n tenant-a-baseline \
            -l gateway.networking.k8s.io/gateway-name=waypoint \
            -o jsonpath='{.items[0].status.phase}' 2>/dev/null || true)
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

    # httpbin in tenant-a-ns1
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

    # sleep in tenant-a-ns2 (intra-tenant caller)
    log_info "Deploying sleep in tenant-a-ns2 (intra-tenant)..."
    kubectl --context "$CLUSTER1" apply -n tenant-a-ns2 -f - <<EOF
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

    # sleep in tenant-b-ns1 (cross-tenant caller)
    log_info "Deploying sleep in tenant-b-ns1 (cross-tenant)..."
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
    kubectl --context "$CLUSTER1" rollout status deployment/sleep -n tenant-a-ns2 --timeout=120s
    kubectl --context "$CLUSTER1" rollout status deployment/sleep -n tenant-b-ns1 --timeout=120s
}

do_create_httpbin_route() {
    log_step "9. Creating HTTPRoute for httpbin ingress"

    # Static Backend to route via Service VIP (critical for RBAC enforcement)
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

    log_info "HTTPRoute created"
}

# ================================================
# Run Setup Steps
# ================================================
run_setup_steps() {
    local rc

    run_step "install_gateway_api_crds" do_install_gateway_api_crds; rc=$?
    [ $rc -eq 1 ] && return 1; [ $rc -eq 2 ] && return 0

    run_step "install_gloo_gateway" do_install_gloo_gateway; rc=$?
    [ $rc -eq 1 ] && return 1; [ $rc -eq 2 ] && return 0

    run_step "create_ingress_gateway" do_create_ingress_gateway; rc=$?
    [ $rc -eq 1 ] && return 1; [ $rc -eq 2 ] && return 0

    run_step "install_istio_ambient" do_install_istio_ambient; rc=$?
    [ $rc -eq 1 ] && return 1; [ $rc -eq 2 ] && return 0

    run_step "add_gloo_gateway_to_mesh" do_add_gloo_gateway_to_mesh; rc=$?
    [ $rc -eq 1 ] && return 1; [ $rc -eq 2 ] && return 0

    run_step "create_tenant_namespaces" do_create_tenant_namespaces; rc=$?
    [ $rc -eq 1 ] && return 1; [ $rc -eq 2 ] && return 0

    run_step "deploy_waypoint" do_deploy_waypoint; rc=$?
    [ $rc -eq 1 ] && return 1; [ $rc -eq 2 ] && return 0

    run_step "deploy_workloads" do_deploy_workloads; rc=$?
    [ $rc -eq 1 ] && return 1; [ $rc -eq 2 ] && return 0

    run_step "create_httpbin_route" do_create_httpbin_route; rc=$?
    [ $rc -eq 1 ] && return 1; [ $rc -eq 2 ] && return 0

    log_info "All setup steps completed!"
    return 0
}

# ================================================
# Test Helper Functions
# ================================================

call_httpbin_from() {
    local from_ns="$1"
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

check_policy_bound_to_waypoint() {
    local policy_name="$1"
    local policy_ns="$2"

    local status
    status=$(kubectl --context "$CLUSTER1" get authorizationpolicy "$policy_name" -n "$policy_ns" \
        -o jsonpath='{.status.conditions[?(@.type=="WaypointAccepted")].status}' 2>/dev/null || echo "")

    if [[ "$status" == "True" ]]; then
        local message
        message=$(kubectl --context "$CLUSTER1" get authorizationpolicy "$policy_name" -n "$policy_ns" \
            -o jsonpath='{.status.conditions[?(@.type=="WaypointAccepted")].message}' 2>/dev/null || echo "")
        log_pass "Policy '$policy_name' bound to waypoint: $message"
        return 0
    else
        log_fail "Policy '$policy_name' NOT bound to waypoint (status: $status)"
        return 1
    fi
}

cleanup_policies() {
    kubectl --context "$CLUSTER1" delete authorizationpolicy --all -n tenant-a-ns1 2>/dev/null || true
    kubectl --context "$CLUSTER1" delete authorizationpolicy --all -n tenant-a-ns2 2>/dev/null || true
    kubectl --context "$CLUSTER1" delete authorizationpolicy --all -n tenant-a-baseline 2>/dev/null || true
    sleep 8
}

# ================================================
# Option B Test Functions
# ================================================

test_baseline_no_policy() {
    log_step "Test 1: Baseline - No policy (permissive default)"

    cleanup_policies

    log_info "With no policies, all traffic should be ALLOWED"

    local result_intra=$(call_httpbin_from tenant-a-ns2)
    record_test "Intra-tenant (tenant-a-ns2 -> httpbin): Permissive" "200" "$result_intra"

    local result_cross=$(call_httpbin_from tenant-b-ns1)
    record_test "Cross-tenant (tenant-b-ns1 -> httpbin): Permissive" "200" "$result_cross"

    local result_ingress=$(call_httpbin_ingress)
    record_test "Ingress (Gloo Gateway -> httpbin): Permissive" "200" "$result_ingress"
}

test_tenant_creates_allow_policy() {
    log_step "Test 2: Tenant creates ALLOW policy in their namespace"

    log_info "Tenant creates policy in tenant-a-ns1 targeting their httpbin Service"
    log_info "This tests the key Option B behavior: policy auto-attaches to waypoint"

    kubectl --context "$CLUSTER1" apply -f - <<EOF
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: httpbin-allow
  namespace: tenant-a-ns1
spec:
  targetRefs:
  - kind: Service
    group: ""
    name: httpbin
  action: ALLOW
  rules:
  # Allow intra-tenant traffic from tenant-a-ns2
  - from:
    - source:
        namespaces:
        - "tenant-a-ns2"
  # Allow ingress from Gloo Gateway
  - from:
    - source:
        principals:
        - "cluster.local/ns/gloo-system/sa/http"
EOF

    log_info "Waiting for policy to propagate..."
    sleep 8
}

test_policy_attachment() {
    log_step "Test 3: Verify policy attachment to waypoint"

    log_info "Checking if tenant-created policy is bound to platform waypoint..."

    if check_policy_bound_to_waypoint "httpbin-allow" "tenant-a-ns1"; then
        ((++TESTS_PASSED)) || true
    else
        ((++TESTS_FAILED)) || true
    fi
}

test_allowed_sources() {
    log_step "Test 4: Test allowed sources"

    log_info "Intra-tenant (tenant-a-ns2) should be ALLOWED"
    local result_intra=$(call_httpbin_from tenant-a-ns2)
    record_test "Intra-tenant (tenant-a-ns2 -> httpbin): Allowed by policy" "200" "$result_intra"

    log_info "Ingress (Gloo Gateway) should be ALLOWED"
    local result_ingress=$(call_httpbin_ingress)
    record_test "Ingress (Gloo Gateway -> httpbin): Allowed by policy" "200" "$result_ingress"
}

test_denied_sources() {
    log_step "Test 5: Test denied sources (implicit deny)"

    log_info "Cross-tenant (tenant-b-ns1) should be DENIED (not in allow list)"
    local result_cross=$(call_httpbin_from tenant-b-ns1)
    record_test "Cross-tenant (tenant-b-ns1 -> httpbin): Denied (implicit)" "403" "$result_cross"
}

test_tenant_updates_policy() {
    log_step "Test 6: Tenant updates policy to add another source"

    log_info "Tenant adds tenant-a-ns1 to the allow list (same namespace access)"

    # First deploy sleep in tenant-a-ns1 for same-namespace test
    kubectl --context "$CLUSTER1" apply -n tenant-a-ns1 -f - <<EOF
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
    kubectl --context "$CLUSTER1" rollout status deployment/sleep -n tenant-a-ns1 --timeout=60s

    # Update policy
    kubectl --context "$CLUSTER1" apply -f - <<EOF
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: httpbin-allow
  namespace: tenant-a-ns1
spec:
  targetRefs:
  - kind: Service
    group: ""
    name: httpbin
  action: ALLOW
  rules:
  # Allow same-namespace traffic
  - from:
    - source:
        namespaces:
        - "tenant-a-ns1"
  # Allow intra-tenant traffic from tenant-a-ns2
  - from:
    - source:
        namespaces:
        - "tenant-a-ns2"
  # Allow ingress from Gloo Gateway
  - from:
    - source:
        principals:
        - "cluster.local/ns/gloo-system/sa/http"
EOF

    log_info "Waiting for policy update to propagate..."
    sleep 8

    log_info "Same-namespace (tenant-a-ns1) should now be ALLOWED"
    local result_same=$(kubectl --context "$CLUSTER1" exec -n tenant-a-ns1 deploy/sleep -c sleep -- \
        curl -s -o /dev/null -w "%{http_code}" \
        --max-time 5 \
        http://httpbin.tenant-a-ns1:8000/get 2>/dev/null || echo "000")
    record_test "Same-namespace (tenant-a-ns1 -> httpbin): Allowed after update" "200" "$result_same"
}

test_tenant_deny_override() {
    log_step "Test 7: Tenant creates DENY policy (takes precedence)"

    log_info "Tenant creates DENY policy for specific path"
    log_info "DENY policies are evaluated before ALLOW policies"

    kubectl --context "$CLUSTER1" apply -f - <<EOF
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: httpbin-deny-headers
  namespace: tenant-a-ns1
spec:
  targetRefs:
  - kind: Service
    group: ""
    name: httpbin
  action: DENY
  rules:
  - to:
    - operation:
        paths:
        - "/headers"
EOF

    log_info "Waiting for DENY policy to propagate..."
    sleep 8

    # /get should still work (ALLOW policy)
    local result_get=$(call_httpbin_from tenant-a-ns2)
    record_test "Path /get: Still allowed" "200" "$result_get"

    # /headers should be denied (DENY policy)
    local result_headers
    result_headers=$(kubectl --context "$CLUSTER1" exec -n tenant-a-ns2 deploy/sleep -c sleep -- \
        curl -s -o /dev/null -w "%{http_code}" \
        --max-time 5 \
        http://httpbin.tenant-a-ns1:8000/headers 2>/dev/null || echo "000")
    record_test "Path /headers: Denied by DENY policy" "403" "$result_headers"
}

test_multiple_tenants_independent_policies() {
    log_step "Test 8: Verify tenant policies are independent"

    log_info "Creating another service in tenant-a-ns2 with its own policy"

    # Deploy another httpbin in tenant-a-ns2
    kubectl --context "$CLUSTER1" apply -n tenant-a-ns2 -f - <<EOF
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
    kubectl --context "$CLUSTER1" rollout status deployment/httpbin -n tenant-a-ns2 --timeout=60s

    # Tenant creates independent policy for their service
    kubectl --context "$CLUSTER1" apply -f - <<EOF
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: httpbin-allow
  namespace: tenant-a-ns2
spec:
  targetRefs:
  - kind: Service
    group: ""
    name: httpbin
  action: ALLOW
  rules:
  # Only allow from tenant-a-ns1 (different from tenant-a-ns1's policy)
  - from:
    - source:
        namespaces:
        - "tenant-a-ns1"
EOF

    log_info "Waiting for policy to propagate..."
    sleep 8

    # Check policy is bound to waypoint
    if check_policy_bound_to_waypoint "httpbin-allow" "tenant-a-ns2"; then
        ((++TESTS_PASSED)) || true
    else
        ((++TESTS_FAILED)) || true
    fi

    # tenant-a-ns1 -> tenant-a-ns2/httpbin should be allowed
    local result_allowed
    result_allowed=$(kubectl --context "$CLUSTER1" exec -n tenant-a-ns1 deploy/sleep -c sleep -- \
        curl -s -o /dev/null -w "%{http_code}" \
        --max-time 5 \
        http://httpbin.tenant-a-ns2:8000/get 2>/dev/null || echo "000")
    record_test "tenant-a-ns1 -> tenant-a-ns2/httpbin: Allowed by ns2 policy" "200" "$result_allowed"

    # tenant-b-ns1 -> tenant-a-ns2/httpbin should be denied
    local result_denied
    result_denied=$(kubectl --context "$CLUSTER1" exec -n tenant-b-ns1 deploy/sleep -c sleep -- \
        curl -s -o /dev/null -w "%{http_code}" \
        --max-time 5 \
        http://httpbin.tenant-a-ns2:8000/get 2>/dev/null || echo "000")
    record_test "tenant-b-ns1 -> tenant-a-ns2/httpbin: Denied by ns2 policy" "403" "$result_denied"
}

# ================================================
# Summary
# ================================================

print_summary() {
    echo ""
    echo "=============================================="
    echo "         OPTION B TEST SUMMARY"
    echo "=============================================="
    echo ""
    echo "Passed: $TESTS_PASSED"
    echo "Failed: $TESTS_FAILED"
    echo ""

    echo "Key Findings:"
    echo "  - Tenant can create policies in their namespace"
    echo "  - Policies with targetRefs to Service auto-attach to waypoint"
    echo "  - Policy status shows 'bound to tenant-a-baseline/waypoint'"
    echo "  - Tenants can allow/deny sources independently"
    echo "  - No platform team involvement needed for policy changes"
    echo ""

    if [[ $TESTS_FAILED -eq 0 ]]; then
        log_pass "All tests passed! Option B is validated."
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

    kubectl --context "$CLUSTER1" delete ns tenant-a-baseline tenant-a-ns1 tenant-a-ns2 tenant-b-ns1 --ignore-not-found

    log_info "Cleanup complete"
}

# ================================================
# Main
# ================================================

print_header() {
    echo ""
    echo "=============================================="
    echo "   OPTION B: TENANT SELF-SERVICE TEST"
    echo "=============================================="
    echo ""
    echo "Scenario:"
    echo "  - Platform manages waypoint in tenant-a-baseline"
    echo "  - Tenants create policies in their own namespaces"
    echo "  - Policies use targetRefs to auto-attach to waypoint"
    echo ""
    log_info "Config file: $CONFIG_FILE"
    log_info "CLUSTER1: $CLUSTER1"
    echo ""
}

main() {
    parse_arguments "$@"
    load_config
    load_progress

    if [ "$LIST_STEPS" = true ]; then
        list_steps
        exit 0
    fi

    if [ "$RESET_PROGRESS" = true ]; then
        clear_progress
    fi

    if [ "$DO_CLEANUP" = true ]; then
        cleanup
        exit 0
    fi

    print_header

    if [ "$TESTS_ONLY" = true ]; then
        log_info "Tests-only mode - skipping setup steps"
        GLOO_IP=$(kubectl get svc -n gloo-system http --context "$CLUSTER1" \
            -o jsonpath="{.status.loadBalancer.ingress[0]['hostname','ip']}" 2>/dev/null || true)
        export GLOO_IP
        log_info "Using Gloo Gateway IP: $GLOO_IP"
    else
        if ! run_setup_steps; then
            log_error "Setup failed"
            exit 1
        fi

        GLOO_IP=$(kubectl get svc -n gloo-system http --context "$CLUSTER1" \
            -o jsonpath="{.status.loadBalancer.ingress[0]['hostname','ip']}" 2>/dev/null || true)
        export GLOO_IP
    fi

    # Run Option B tests
    log_step "Running Option B Tests: Tenant Self-Service AuthorizationPolicy"

    test_baseline_no_policy
    test_tenant_creates_allow_policy
    test_policy_attachment
    test_allowed_sources
    test_denied_sources
    test_tenant_updates_policy
    test_tenant_deny_override
    test_multiple_tenants_independent_policies

    print_summary
}

main "$@"
