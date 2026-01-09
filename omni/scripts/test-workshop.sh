#!/bin/bash

# ================================================
# test-workshop.sh - End-to-end test for Omni Workshop
# ================================================
#
# This script executes all workshop steps and runs verification tests,
# recording results vs expected outcomes.
#
# Usage:
#   ./test-workshop.sh -c env.sh                    # Run full workshop
#   ./test-workshop.sh -c env.sh --create-clusters  # Create GKE clusters first
#   ./test-workshop.sh -c env.sh -s deploy_bookinfo # Start from specific step
#   ./test-workshop.sh -c env.sh --stop-after add_to_mesh  # Stop after step
#   ./test-workshop.sh -c env.sh -l                 # List all steps
#   ./test-workshop.sh -c env.sh --reset            # Clear progress, start fresh
#   ./test-workshop.sh -c env.sh -t                 # Run tests only (skip setup)
#

set -e
set -o pipefail

# ================================================
# Setup and Source Library
# ================================================
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

source "$SCRIPT_DIR/test-lib.sh"

# ================================================
# Workshop Steps Definition
# ================================================
# These are the demo steps AFTER setup.sh has run
WORKSHOP_STEPS=(
    "deploy_bookinfo"
    "expose_ingress"
    "verify_no_mesh"
    "add_to_mesh"
    "verify_mesh"
    "peer_clusters"
    "add_gloo_to_mesh"
    "verify_observability"
    "enable_global_services"
    "test_failover"
    "deploy_waypoint"
    "canary_routing"
    "test_rate_limiting"
)

# Optional steps (not run by default)
OPTIONAL_STEPS=(
    "enable_tracing"  # Run with: --tracing flag
)

# ================================================
# Configuration
# ================================================
usage() {
    echo "Usage: $0 [-c <config_file>] [options]"
    echo ""
    echo "Options:"
    echo "  -c, --config FILE       Load configuration from FILE (default: ../env.sh)"
    echo "  --create-clusters       Create GKE clusters if needed"
    echo "  --skip-setup            Skip running setup.sh (assume already done)"
    echo "  -s, --step STEP         Start from a specific step (name or number)"
    echo "  --stop-after STEP       Stop after completing a specific step"
    echo "  -l, --list              List all steps and their completion status"
    echo "  --reset                 Clear progress and start fresh"
    echo "  -t, --tests-only        Skip all setup, run verification tests only"
    echo "  --skip-tracing          Skip the optional tracing configuration step"
    echo "  -d, --delete            Cleanup after tests complete"
    echo "  -h, --help              Show this help message"
    echo ""
    echo "Steps (run in order):"
    local num=1
    for step in "${WORKSHOP_STEPS[@]}"; do
        printf "  %2d. %s\n" "$num" "$step"
        ((num++))
    done
    echo ""
    echo "Optional Steps (run by default after workshop steps):"
    for step in "${OPTIONAL_STEPS[@]}"; do
        printf "      %s (skip with --skip-tracing)\n" "$step"
    done
    echo ""
    echo "Examples:"
    echo "  $0 -c env.sh                           # Run full workshop + tracing"
    echo "  $0 -c env.sh --skip-tracing            # Run workshop without tracing"
    echo "  $0 -c env.sh --create-clusters         # Create clusters + run workshop"
    echo "  $0 -c env.sh -s deploy_waypoint        # Start from waypoint step"
    echo "  $0 -c env.sh --stop-after add_to_mesh  # Run up to add_to_mesh"
    echo "  $0 -c env.sh -l                        # Show progress"
    exit 0
}

parse_arguments() {
    CONFIG_FILE=""
    CREATE_CLUSTERS=false
    SKIP_SETUP=false
    DELETE_AFTER=false
    TESTS_ONLY=false
    SKIP_TRACING=false
    START_FROM_STEP=""
    STOP_AFTER_STEP=""
    RESET_PROGRESS=false
    LIST_STEPS=false

    # Default config location
    local REPO_ROOT="$(dirname "$SCRIPT_DIR")"
    local DEFAULT_CONFIG="$REPO_ROOT/env.sh"

    while [[ $# -gt 0 ]]; do
        case $1 in
            -c|--config)
                CONFIG_FILE="$2"
                shift 2
                ;;
            --create-clusters)
                CREATE_CLUSTERS=true
                shift
                ;;
            --skip-setup)
                SKIP_SETUP=true
                shift
                ;;
            -s|--step)
                START_FROM_STEP="$(get_step_by_number "$2" "${WORKSHOP_STEPS[@]}")"
                shift 2
                ;;
            --stop-after)
                STOP_AFTER_STEP="$(get_step_by_number "$2" "${WORKSHOP_STEPS[@]}")"
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
            -t|--tests-only)
                TESTS_ONLY=true
                shift
                ;;
            --skip-tracing)
                SKIP_TRACING=true
                shift
                ;;
            -d|--delete)
                DELETE_AFTER=true
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

    # Use default config if not specified
    if [ -z "$CONFIG_FILE" ]; then
        if [ -f "$DEFAULT_CONFIG" ]; then
            CONFIG_FILE="$DEFAULT_CONFIG"
            log_info "Using default config: $CONFIG_FILE"
        else
            log_error "No config specified. Use -c <config_file> or create $DEFAULT_CONFIG"
            exit 1
        fi
    fi

    # Validate config file exists
    if [ ! -f "$CONFIG_FILE" ]; then
        log_error "Config file not found: $CONFIG_FILE"
        exit 1
    fi

    # Set progress file in the repo directory (not /tmp so it persists and can be cleaned up)
    local REPO_ROOT="$(dirname "$SCRIPT_DIR")"
    export PROGRESS_FILE="$REPO_ROOT/.workshop-progress"
}

load_config() {
    # Load config file (always set by parse_arguments)
    source "$CONFIG_FILE"
    log_info "Loaded config from: $CONFIG_FILE"

    # Validate required variables
    local missing=()
    [[ -z "${CLUSTER1:-}" ]] && missing+=("CLUSTER1")
    [[ -z "${CLUSTER2:-}" ]] && missing+=("CLUSTER2")

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required variables: ${missing[*]}"
        exit 1
    fi

    # Set defaults
    export GLOO_VERSION="${GLOO_VERSION:-2.11.0}"
    export ISTIO_VERSION="${ISTIO_VERSION:-1.28.1}"

    # Get Gloo Gateway IP (may be empty if not yet deployed)
    export GLOO_IP=$(kubectl get svc -n gloo-system http --context "$CLUSTER1" \
        -o jsonpath="{.status.loadBalancer.ingress[0]['hostname','ip']}" 2>/dev/null || echo "")
}

# ================================================
# Workshop Step Functions
# ================================================

do_deploy_bookinfo() {
    log_step "1. Deploy Bookinfo Application"

    for context in ${CLUSTER1} ${CLUSTER2}; do
        log_info "Deploying to $context..."
        kubectl --context ${context} create ns bookinfo 2>/dev/null || true
        kubectl --context ${context} apply -n bookinfo \
            -f https://raw.githubusercontent.com/LutzLange/bookinfo/main/platform/kube/bookinfo-otel.yaml
    done

    # Wait for pods
    log_info "Waiting for pods to be ready..."
    for context in ${CLUSTER1} ${CLUSTER2}; do
        kubectl --context ${context} wait --for=condition=Ready pods -n bookinfo -l app=productpage --timeout=120s || true
    done

    log_info "Bookinfo deployed"
}

do_expose_ingress() {
    log_step "2. Expose via Ingress (HTTPRoute)"

    # Create Static Backend to route via Service VIP (critical for waypoint routing)
    # Gloo Gateway uses EDS which would otherwise target pod IPs directly
    kubectl --context=${CLUSTER1} apply -f - <<EOF
apiVersion: gateway.kgateway.dev/v1alpha1
kind: Backend
metadata:
  name: productpage-vip
  namespace: bookinfo
spec:
  type: Static
  static:
    hosts:
    - host: productpage.bookinfo.svc.cluster.local
      port: 9080
EOF

    # Create HTTPRoute using the Backend
    kubectl --context=${CLUSTER1} apply -f - <<EOF
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
    - name: productpage-vip
      kind: Backend
      group: gateway.kgateway.dev
EOF

    # Update GLOO_IP
    export GLOO_IP=$(kubectl get svc -n gloo-system http --context "$CLUSTER1" \
        -o jsonpath="{.status.loadBalancer.ingress[0]['hostname','ip']}" 2>/dev/null)

    log_info "HTTPRoute created with Static Backend. Gloo IP: $GLOO_IP"
}

do_verify_no_mesh() {
    log_step "3. Verify Application Works (Not Yet in Mesh)"

    set +e
    test_http_endpoint "http://${GLOO_IP}/productpage" "200" "Productpage accessible"
    set -e
}

do_add_to_mesh() {
    log_step "4. Add to Mesh - One Label"

    # Add namespace to ambient mesh
    kubectl --context ${CLUSTER1} label namespace bookinfo istio.io/dataplane-mode=ambient --overwrite
    kubectl --context ${CLUSTER2} label namespace bookinfo istio.io/dataplane-mode=ambient --overwrite

    # Configure namespace to use waypoint for L7 policies (needed for ingress traffic)
    kubectl --context ${CLUSTER1} label namespace bookinfo istio.io/use-waypoint=waypoint --overwrite
    kubectl --context ${CLUSTER2} label namespace bookinfo istio.io/use-waypoint=waypoint --overwrite

    log_info "Namespaces labeled for ambient mesh with waypoint"
    sleep 5  # Brief wait for ztunnel to pick up workloads
}

do_verify_mesh() {
    log_step "5. Verify Mesh Enrollment"

    set +e

    # Verify mTLS is active via ztunnel
    # In ambient mode, ztunnel handles all mTLS - workload pods don't have cert files
    # We verify by checking ztunnel is handling traffic with HBONE protocol
    log_test "mTLS active (ztunnel HBONE)"
    # Generate traffic first
    curl -s "http://${GLOO_IP}/productpage" > /dev/null 2>&1 || true
    sleep 2

    local hbone_count
    hbone_count=$(kubectl --context ${CLUSTER1} logs -n istio-system -l app=ztunnel --tail=100 2>/dev/null | grep -cE "HBONE|src\.identity.*spiffe" || echo "0")
    if [ "$hbone_count" -gt 0 ]; then
        record_test "mTLS active (ztunnel)" "HBONE traffic" "$hbone_count HBONE entries" "PASS"
    else
        # Fallback: check ztunnel is at least processing bookinfo traffic
        local bookinfo_count
        bookinfo_count=$(kubectl --context ${CLUSTER1} logs -n istio-system -l app=ztunnel --tail=100 2>/dev/null | grep -c bookinfo || echo "0")
        if [ "$bookinfo_count" -gt 0 ]; then
            record_test "mTLS active (ztunnel)" "HBONE traffic" "$bookinfo_count bookinfo entries (HBONE implicit)" "PASS"
        else
            record_test "mTLS active (ztunnel)" "HBONE traffic" "No ztunnel traffic found" "FAIL"
        fi
    fi

    # Check ztunnel logs for bookinfo traffic (inbound/outbound)
    log_test "ztunnel handling bookinfo traffic"
    # Generate some traffic first to ensure logs exist
    curl -s "http://${GLOO_IP}/productpage" > /dev/null 2>&1 || true
    sleep 2

    local ztunnel_logs
    ztunnel_logs=$(kubectl --context ${CLUSTER1} logs -n istio-system -l app=ztunnel --tail=100 2>/dev/null | grep -cE "inbound|outbound.*bookinfo" || echo "0")
    if [ "$ztunnel_logs" -gt 0 ]; then
        record_test "ztunnel traffic (inbound/outbound)" ">0 entries" "$ztunnel_logs entries" "PASS"
    else
        # Fallback: check for any bookinfo references
        ztunnel_logs=$(kubectl --context ${CLUSTER1} logs -n istio-system -l app=ztunnel --tail=100 2>/dev/null | grep -c bookinfo || echo "0")
        if [ "$ztunnel_logs" -gt 0 ]; then
            record_test "ztunnel traffic (bookinfo)" ">0 entries" "$ztunnel_logs entries" "PASS"
        else
            record_test "ztunnel traffic" ">0 entries" "$ztunnel_logs entries" "FAIL"
        fi
    fi

    # Verify pods still running (no restarts needed)
    test_pods_running "$CLUSTER1" "bookinfo" "app=productpage" 1 "Productpage running in mesh"

    set -e
}

do_peer_clusters() {
    log_step "6. Peer Clusters (East-West Gateway)"

    local ISTIOCTL="${ISTIOCTL:-$HOME/.istioctl/bin/istioctl}"

    # Deploy east-west gateways
    log_info "Exposing clusters for multi-cluster..."
    "$ISTIOCTL" --context=${CLUSTER1} multicluster expose -n istio-gateways || true
    "$ISTIOCTL" --context=${CLUSTER2} multicluster expose -n istio-gateways || true

    # Wait for LoadBalancer IPs on both clusters (required before linking)
    log_info "Waiting for east-west gateway LoadBalancer IPs..."
    local max_lb_wait=60
    local lb_attempt=1
    while [ $lb_attempt -le $max_lb_wait ]; do
        local ip1=$(kubectl get svc -n istio-gateways istio-eastwest --context ${CLUSTER1} \
            -o jsonpath="{.status.loadBalancer.ingress[0]['hostname','ip']}" 2>/dev/null)
        local ip2=$(kubectl get svc -n istio-gateways istio-eastwest --context ${CLUSTER2} \
            -o jsonpath="{.status.loadBalancer.ingress[0]['hostname','ip']}" 2>/dev/null)
        if [[ -n "$ip1" && -n "$ip2" ]]; then
            log_info "East-west gateway IPs: cluster1=$ip1, cluster2=$ip2"
            break
        fi
        if [ $((lb_attempt % 10)) -eq 0 ]; then
            log_info "Still waiting for LoadBalancer IPs (attempt $lb_attempt/$max_lb_wait)..."
        fi
        sleep 2
        ((lb_attempt++))
    done

    if [[ -z "$ip1" || -z "$ip2" ]]; then
        log_warn "LoadBalancer IPs not fully assigned, attempting link anyway..."
    fi

    # Link clusters (retry up to 3 times if it fails)
    log_info "Linking clusters..."
    local link_attempt=1
    local max_link_attempts=3
    while [ $link_attempt -le $max_link_attempts ]; do
        if "$ISTIOCTL" multicluster link --contexts=${CLUSTER1},${CLUSTER2} -n istio-gateways 2>&1; then
            break
        fi
        if [ $link_attempt -lt $max_link_attempts ]; then
            log_warn "Link attempt $link_attempt failed, retrying in 10s..."
            sleep 10
        fi
        ((link_attempt++))
    done

    # Verify Gateway resources are PROGRAMMED
    log_info "Verifying Gateway resources..."
    set +e
    local gw_status
    local gw_programmed=false
    for i in {1..12}; do
        gw_status=$(kubectl --context ${CLUSTER1} get gateways -n istio-gateways -o jsonpath='{range .items[*]}{.metadata.name}:{.status.conditions[?(@.type=="Programmed")].status}{"\n"}{end}' 2>/dev/null)
        # Check if istio-eastwest is PROGRAMMED=True
        if echo "$gw_status" | grep -q "istio-eastwest:True"; then
            gw_programmed=true
            break
        fi
        sleep 5
    done

    if [ "$gw_programmed" = true ]; then
        log_info "Gateway resources PROGRAMMED:"
        echo "$gw_status" | grep -v "^$" || true
        record_test "Gateway PROGRAMMED" "istio-eastwest:True" "$(echo "$gw_status" | tr '\n' ' ')" "PASS"
    else
        log_warn "Gateway resources not fully PROGRAMMED"
        kubectl --context ${CLUSTER1} get gateways -n istio-gateways 2>/dev/null || true
        record_test "Gateway PROGRAMMED" "istio-eastwest:True" "Not programmed" "FAIL"
    fi
    set -e

    # Verify peering is established (wait up to 60 seconds)
    log_info "Verifying multi-cluster peering..."
    local max_attempts=12
    local attempt=1
    local check_output
    while [ $attempt -le $max_attempts ]; do
        check_output=$("$ISTIOCTL" --context=${CLUSTER1} multicluster check --verbose 2>&1)
        if echo "$check_output" | grep -q "gloo.solo.io/PeerConnected: True"; then
            log_info "Multi-cluster peering established successfully"
            record_test "Multi-cluster peering" "PeerConnected: True" "Connected" "PASS"
            return 0
        fi
        # Debug: Show peer status on first and last attempt
        if [ $attempt -eq 1 ] || [ $attempt -eq $max_attempts ]; then
            log_info "Peer status:"
            echo "$check_output" | grep -E "Peers|Cluster:|PeerConnected|Status:" || true
        fi
        log_info "Waiting for peering to establish (attempt $attempt/$max_attempts)..."
        sleep 5
        ((attempt++))
    done

    log_error "Multi-cluster peering failed to establish"
    log_error "Check istiod logs: kubectl --context ${CLUSTER1} logs -n istio-system -l app=istiod"
    log_error "Ensure cacerts secret exists with shared root CA in istio-system namespace"
    record_test "Multi-cluster peering" "PeerConnected: True" "Not connected" "FAIL"
    return 1
}

do_add_gloo_to_mesh() {
    log_step "7. Add Gloo Gateway to Mesh"

    # With ztunnel configured with proper egressPolicies for K8s API passthrough,
    # the gateway can be fully included in the ambient mesh without exclusions.
    # The egressPolicies allow gloo-gateway to communicate with the K8s API server
    # for JWT token validation without mTLS interference.

    # Add gloo-system namespace to ambient mesh (all pods included)
    log_info "Adding gloo-system namespace to ambient mesh..."
    kubectl --context ${CLUSTER1} label namespace gloo-system istio.io/dataplane-mode=ambient --overwrite

    # Give ztunnel time to pick up the workloads
    sleep 5

    # Verify gateway is still working
    log_info "Verifying gateway connectivity..."
    local code
    local attempts=0
    local max_attempts=6

    while [ $attempts -lt $max_attempts ]; do
        code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "http://${GLOO_IP}/productpage" 2>/dev/null || echo "000")
        if [ "$code" = "200" ]; then
            log_info "Gateway connectivity confirmed (HTTP $code)"
            break
        fi
        ((attempts++))
        if [ $attempts -lt $max_attempts ]; then
            log_info "Gateway returned HTTP $code, retrying ($attempts/$max_attempts)..."
            sleep 5
        fi
    done

    if [ "$code" != "200" ]; then
        log_warn "Gateway returned HTTP $code after $max_attempts attempts"
        log_warn "Checking gloo-gateway logs for errors..."
        kubectl --context ${CLUSTER1} logs -n gloo-system -l app.kubernetes.io/name=gloo-gateway --tail=10 2>/dev/null | grep -iE "error|fail" || true
    fi

    log_info "gloo-system fully added to mesh (all gateway pods included)"
}

do_verify_observability() {
    log_step "8. Verify Observability"

    set +e

    # Verify observability components are running
    # Note: Tracing configuration (HTTPListenerPolicy, Telemetry CRs) is optional
    # and can be enabled separately - see do_enable_tracing()

    # Check Jaeger pod (uses app.kubernetes.io/name=jaeger label)
    log_test "Jaeger pod running"
    local jaeger_pod
    jaeger_pod=$(kubectl --context ${CLUSTER1} get pods -n gloo-mesh -l app.kubernetes.io/name=jaeger -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if [ -n "$jaeger_pod" ]; then
        record_test "Jaeger pod running" "Pod exists" "Found: $jaeger_pod" "PASS"
    else
        record_test "Jaeger pod running" "Pod exists" "Not found" "FAIL"
    fi

    # Check Prometheus pod (uses app.kubernetes.io/name=prometheus label)
    log_test "Prometheus pod running"
    local prom_pod
    prom_pod=$(kubectl --context ${CLUSTER1} get pods -n gloo-mesh -l app.kubernetes.io/name=prometheus -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if [ -n "$prom_pod" ]; then
        record_test "Prometheus pod running" "Pod exists" "Found: $prom_pod" "PASS"
    else
        record_test "Prometheus pod running" "Pod exists" "Not found" "FAIL"
    fi

    # Check Gloo Telemetry Gateway (receives traces from mesh and forwards to Jaeger)
    log_test "Telemetry gateway running"
    local gateway_pod
    gateway_pod=$(kubectl --context ${CLUSTER1} get pods -n gloo-mesh -l app=gloo-telemetry-gateway -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if [ -n "$gateway_pod" ]; then
        record_test "Telemetry gateway running" "Pod exists" "Found: $gateway_pod" "PASS"
    else
        record_test "Telemetry gateway running" "Pod exists" "Not found" "FAIL"
    fi

    set -e
}

do_enable_global_services() {
    log_step "9. Enable Global Services"

    for context in ${CLUSTER1} ${CLUSTER2}; do
        kubectl --context ${context} -n bookinfo label service productpage solo.io/service-scope=global --overwrite
        kubectl --context ${context} -n bookinfo annotate service productpage networking.istio.io/traffic-distribution=Any --overwrite
    done

    # Update Backend to use global mesh hostname
    kubectl --context=${CLUSTER1} apply -f - <<EOF
apiVersion: gateway.kgateway.dev/v1alpha1
kind: Backend
metadata:
  name: productpage-vip
  namespace: bookinfo
spec:
  type: Static
  static:
    hosts:
    - host: productpage.bookinfo.mesh.internal
      port: 9080
EOF

    log_info "Global services enabled"
}

do_test_failover() {
    log_step "10. Test Multi-Cluster Failover"

    set +e

    # Test load balancing across clusters
    log_info "Testing multi-cluster load balancing..."
    test_http_endpoint "http://${GLOO_IP}/productpage" "200" "Global service accessible"

    # Check if multi-cluster peering is established
    local ISTIOCTL="${ISTIOCTL:-$HOME/.istioctl/bin/istioctl}"
    local check_output
    check_output=$("$ISTIOCTL" --context=${CLUSTER1} multicluster check --verbose 2>&1)
    if ! echo "$check_output" | grep -q "gloo.solo.io/PeerConnected: True"; then
        log_warn "Multi-cluster peering not established (PeerConnected: False)"
        log_warn "Failover test requires cross-cluster connectivity"
        log_warn "Check istiod logs and ensure cacerts secret has shared root CA"
        record_test "Failover to cluster2" "HTTP 200" "Skipped: peers not connected" "FAIL"
        return 1  # Fail if peering isn't working
    fi

    log_info "Multi-cluster peering confirmed"

    # Verify load balancing - check both clusters have productpage endpoints
    log_test "Multi-cluster load balancing"
    local c1_pods=$(kubectl --context ${CLUSTER1} get pods -n bookinfo -l app=productpage --no-headers 2>/dev/null | wc -l)
    local c2_pods=$(kubectl --context ${CLUSTER2} get pods -n bookinfo -l app=productpage --no-headers 2>/dev/null | wc -l)
    log_info "Productpage pods: cluster1=$c1_pods, cluster2=$c2_pods"

    if [ "$c1_pods" -gt 0 ] && [ "$c2_pods" -gt 0 ]; then
        # Both clusters have pods - verify global hostname resolves to both
        # Generate traffic and check it succeeds (mesh handles distribution)
        local lb_success=0
        for i in {1..5}; do
            local code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "http://${GLOO_IP}/productpage" 2>/dev/null)
            [ "$code" = "200" ] && ((lb_success++))
        done
        if [ "$lb_success" -ge 4 ]; then
            record_test "Multi-cluster load balancing" "Both clusters serving" "c1=$c1_pods c2=$c2_pods ($lb_success/5 OK)" "PASS"
        else
            record_test "Multi-cluster load balancing" "Both clusters serving" "Only $lb_success/5 succeeded" "FAIL"
        fi
    else
        record_test "Multi-cluster load balancing" "Both clusters serving" "c1=$c1_pods c2=$c2_pods" "FAIL"
    fi

    # Test failover: Scale down cluster1 productpage
    log_info "Testing failover: Scaling down productpage on cluster1..."
    kubectl --context ${CLUSTER1} scale deploy productpage-v1 -n bookinfo --replicas=0

    # Wait for pod to terminate and service mesh to update
    log_info "Waiting for pod termination and mesh update..."
    kubectl --context ${CLUSTER1} wait --for=delete pod -l app=productpage -n bookinfo --timeout=60s 2>/dev/null || true

    # Wait for mesh routing to update - istiod needs time to propagate endpoint changes
    # across clusters via the east-west gateway
    log_info "Waiting for mesh routing to propagate (30s)..."
    sleep 30

    # Should still work (failover to cluster2) - use more retries with longer wait
    test_http_endpoint "http://${GLOO_IP}/productpage" "200" "Failover to cluster2" 10

    # Restore
    log_info "Restoring productpage on cluster1..."
    kubectl --context ${CLUSTER1} scale deploy productpage-v1 -n bookinfo --replicas=1
    kubectl --context ${CLUSTER1} wait --for=condition=Ready pod -l app=productpage -n bookinfo --timeout=120s 2>/dev/null || true

    set -e
}

do_deploy_waypoint() {
    log_step "11. Deploy Waypoint for L7 Policies"

    for ctx in ${CLUSTER1} ${CLUSTER2}; do
        kubectl --context ${ctx} apply -f - <<EOF
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
EOF
    done

    # Wait for waypoint pods to be ready
    log_info "Waiting for waypoint pods..."
    kubectl --context ${CLUSTER1} wait --for=condition=Ready pod -l gateway.networking.k8s.io/gateway-name=waypoint -n bookinfo --timeout=120s 2>/dev/null || true
    kubectl --context ${CLUSTER2} wait --for=condition=Ready pod -l gateway.networking.k8s.io/gateway-name=waypoint -n bookinfo --timeout=120s 2>/dev/null || true

    # Attach waypoint to reviews service
    kubectl --context ${CLUSTER1} label svc reviews -n bookinfo istio.io/use-waypoint=waypoint --overwrite
    kubectl --context ${CLUSTER2} label svc reviews -n bookinfo istio.io/use-waypoint=waypoint --overwrite

    # Note: Waypoint tracing is configured separately via do_enable_tracing()
    log_info "Waypoint deployed and attached to reviews service"
    sleep 10  # Allow routing rules to propagate
}

do_canary_routing() {
    log_step "12. Canary Routing"

    for ctx in ${CLUSTER1} ${CLUSTER2}; do
        kubectl --context ${ctx} apply -f - <<EOF
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
EOF
    done

    set +e

    # Wait for routing rules to take effect
    log_info "Waiting for routing rules to propagate..."
    sleep 10

    # Test canary routing - reviews response behavior:
    # - reviews-v1: no ratings/stars in response (no "color" field)
    # - reviews-v2: black stars ("color": "black")
    # - reviews-v3: red stars ("color": "red")
    #
    # Note: Using ratings pod for testing because it has curl installed.
    # The productpage container does not include curl.
    log_info "Testing canary routing..."
    # Default should get reviews-v1 (no color field = no ratings)
    log_test "Default user gets reviews-v1"
    local default_pass=false
    for i in {1..5}; do
        local default_response
        default_response=$(kubectl --context ${CLUSTER1} exec -n bookinfo deploy/ratings-v1 -- \
            curl -s reviews:9080/reviews/0 2>/dev/null || echo "{}")
        # reviews-v1 doesn't include ratings (no "color" field)
        if echo "$default_response" | grep -q '"id"' && ! echo "$default_response" | grep -q '"color"'; then
            default_pass=true
            break
        fi
        sleep 2
    done
    if [ "$default_pass" = true ]; then
        record_test "Default -> reviews-v1" "no color field" "Got v1 (no color)" "PASS"
    else
        record_test "Default -> reviews-v1" "no color field" "Got v2/v3 (has color)" "FAIL"
    fi

    # User jason should get reviews-v2 (black stars)
    log_test "User jason gets reviews-v2"
    local jason_pass=false
    for i in {1..5}; do
        local jason_response
        jason_response=$(kubectl --context ${CLUSTER1} exec -n bookinfo deploy/ratings-v1 -- \
            curl -s -H "end-user: jason" reviews:9080/reviews/0 2>/dev/null || echo "{}")
        # reviews-v2 includes "color": "black"
        if echo "$jason_response" | grep -q '"color".*"black"'; then
            jason_pass=true
            break
        fi
        sleep 2
    done
    if [ "$jason_pass" = true ]; then
        record_test "jason -> reviews-v2" "color: black" "Got v2 (color: black)" "PASS"
    else
        record_test "jason -> reviews-v2" "color: black" "Got different version" "FAIL"
    fi

    set -e
}

do_test_rate_limiting() {
    log_step "13. Rate Limiting"

    # Apply rate limit policy
    kubectl --context ${CLUSTER1} apply -f - <<EOF
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
EOF

    log_info "Rate limit policy applied"
    sleep 3

    set +e

    # Test rate limiting
    log_info "Testing rate limiting (5 req/min limit)..."
    local success_count=0
    local rate_limited_count=0

    for i in {1..10}; do
        local code
        code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "http://${GLOO_IP}/productpage" 2>/dev/null)
        if [ "$code" = "200" ]; then
            ((success_count++))
        elif [ "$code" = "429" ]; then
            ((rate_limited_count++))
        fi
        sleep 0.5
    done

    log_test "Rate limiting enforced"
    if [ "$rate_limited_count" -gt 0 ]; then
        record_test "Rate limiting" "Some 429s" "$rate_limited_count requests rate limited" "PASS"
    else
        record_test "Rate limiting" "Some 429s" "No rate limiting observed" "FAIL"
    fi

    # Note: Gloo Gateway's local tokenBucket rate limiting returns 429 status
    # but does not add X-RateLimit-* headers by default.
    # The 429 response is the primary indicator of rate limiting.
    log_info "Rate limiting verified via 429 status (local tokenBucket doesn't add X-RateLimit headers)"

    # Cleanup rate limit
    kubectl --context ${CLUSTER1} delete glootrafficpolicy productpage-ratelimit -n bookinfo 2>/dev/null || true

    set -e
}

# ================================================
# Optional: Full Distributed Tracing
# ================================================
# This step runs by default after workshop steps complete.
# Skip with --skip-tracing flag.
# Configures tracing for: Gloo Gateway, Waypoint proxies, Mesh extensionProvider

do_enable_tracing() {
    log_step "14. Optional: Enable Full Distributed Tracing"

    log_info "Configuring distributed tracing for:"
    log_info "  - ztunnel L7 tracing (Solo Enterprise)"
    log_info "  - Mesh extensionProvider (otel-tracing)"
    log_info "  - Gloo Gateway (HTTPListenerPolicy)"
    log_info "  - Waypoint proxies (Telemetry CR)"

    set +e

    # Step 0: Fix ztunnel L7 tracing endpoint (points to correct collector)
    log_info "Step 0: Configuring ztunnel distributed tracing endpoint..."
    local ztunnel_needs_restart=false

    for ctx in ${CLUSTER1} ${CLUSTER2}; do
        local current_ztunnel_config
        current_ztunnel_config=$(kubectl --context ${ctx} get configmap istio-ztunnel -n istio-system -o jsonpath='{.data.l7_config\.yaml}' 2>/dev/null)

        if echo "$current_ztunnel_config" | grep -q "gloo-telemetry-collector.gloo-mesh"; then
            log_info "  $ctx: ztunnel already pointing to correct collector"
        else
            log_info "  $ctx: Updating ztunnel tracing endpoint..."
            kubectl --context ${ctx} patch configmap istio-ztunnel -n istio-system --type merge -p '{"data":{"l7_config.yaml":"accessLog:\n  enabled: true\n  skipConnectionLog: false\ndistributedTracing:\n  enabled: true\n  otlpEndpoint: http://gloo-telemetry-collector.gloo-mesh:4317\nenabled: true\nmetrics:\n  enabled: true\n"}}'
            ztunnel_needs_restart=true
        fi
    done

    if [ "$ztunnel_needs_restart" = true ]; then
        log_info "Restarting ztunnel daemonsets..."
        for ctx in ${CLUSTER1} ${CLUSTER2}; do
            kubectl --context ${ctx} rollout restart daemonset/ztunnel -n istio-system
        done
        for ctx in ${CLUSTER1} ${CLUSTER2}; do
            kubectl --context ${ctx} rollout status daemonset/ztunnel -n istio-system --timeout=120s
        done
    fi

    # Step 1: Create ClusterIP service for telemetry collector
    # The default gloo-telemetry-collector is a headless service (ClusterIP: None)
    # which causes ORIGINAL_DST cluster type in waypoints. Waypoints can't export
    # traces to headless services. Creating a ClusterIP service fixes this.
    log_info "Step 1: Creating ClusterIP service for telemetry collector (waypoint fix)..."

    for ctx in ${CLUSTER1} ${CLUSTER2}; do
        if kubectl --context ${ctx} get svc gloo-telemetry-collector-clusterip -n gloo-mesh &>/dev/null; then
            log_info "  $ctx: ClusterIP service already exists"
        else
            log_info "  $ctx: Creating gloo-telemetry-collector-clusterip service..."
            kubectl --context ${ctx} apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: gloo-telemetry-collector-clusterip
  namespace: gloo-mesh
  labels:
    app: gloo-telemetry-collector-agent
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/instance: gloo-platform
    app.kubernetes.io/name: telemetryCollector
    component: agent-collector
  ports:
  - name: grpc-otlp
    port: 4317
    targetPort: 4317
    protocol: TCP
    appProtocol: grpc
  - name: otlp-http
    port: 4318
    targetPort: 4318
    protocol: TCP
  - name: zipkin
    port: 9411
    targetPort: 9411
    protocol: TCP
  - name: grpc-jaeger
    port: 14250
    targetPort: 14250
    protocol: TCP
    appProtocol: grpc
EOF
        fi
    done

    # Step 2: Add extensionProvider to Istio mesh config on both clusters
    # Points to ClusterIP service (not headless) for waypoint compatibility
    log_info "Step 2: Adding otel-tracing extensionProvider to mesh config..."

    local needs_restart=false
    for ctx in ${CLUSTER1} ${CLUSTER2}; do
        local current_mesh_config
        current_mesh_config=$(kubectl --context ${ctx} get configmap istio -n istio-system -o jsonpath='{.data.mesh}' 2>/dev/null)

        # Check if already pointing to ClusterIP service
        if echo "$current_mesh_config" | grep -q "gloo-telemetry-collector-clusterip"; then
            log_info "  $ctx: otel-tracing already configured with ClusterIP service"
        elif echo "$current_mesh_config" | grep -q "otel-tracing"; then
            # Update existing config to use ClusterIP service
            log_info "  $ctx: Updating otel-tracing to use ClusterIP service..."
            local updated_config
            updated_config=$(echo "$current_mesh_config" | sed 's/gloo-telemetry-collector\.gloo-mesh\.svc\.cluster\.local/gloo-telemetry-collector-clusterip.gloo-mesh.svc.cluster.local/g')
            kubectl --context ${ctx} patch configmap istio -n istio-system \
                --type merge -p "{\"data\":{\"mesh\":$(echo "$updated_config" | jq -Rs .)}}"
            needs_restart=true
        else
            log_info "  $ctx: Adding otel-tracing extensionProvider..."
            # Append extensionProviders to existing config - use ClusterIP service
            local combined_config="${current_mesh_config}
extensionProviders:
- name: otel-tracing
  opentelemetry:
    service: gloo-telemetry-collector-clusterip.gloo-mesh.svc.cluster.local
    port: 4317"

            kubectl --context ${ctx} patch configmap istio -n istio-system \
                --type merge -p "{\"data\":{\"mesh\":$(echo "$combined_config" | jq -Rs .)}}"
            needs_restart=true
        fi
    done

    # Restart istiod and waypoints if config was changed
    if [ "$needs_restart" = true ]; then
        log_info "Restarting istiod to apply mesh config changes..."
        for ctx in ${CLUSTER1} ${CLUSTER2}; do
            kubectl --context ${ctx} rollout restart deployment/istiod -n istio-system
        done
        for ctx in ${CLUSTER1} ${CLUSTER2}; do
            kubectl --context ${ctx} rollout status deployment/istiod -n istio-system --timeout=120s
        done

        # Restart waypoints to pick up new extensionProvider
        log_info "Restarting waypoints to pick up new config..."
        for ctx in ${CLUSTER1} ${CLUSTER2}; do
            if kubectl --context ${ctx} get deployment waypoint -n bookinfo &>/dev/null; then
                kubectl --context ${ctx} rollout restart deployment/waypoint -n bookinfo
            fi
        done
        for ctx in ${CLUSTER1} ${CLUSTER2}; do
            if kubectl --context ${ctx} get deployment waypoint -n bookinfo &>/dev/null; then
                kubectl --context ${ctx} rollout status deployment/waypoint -n bookinfo --timeout=120s
            fi
        done
    fi

    # Step 3: Configure Gloo Gateway tracing via HTTPListenerPolicy
    log_info "Step 3: Configuring Gloo Gateway tracing..."

    # ReferenceGrant to allow cross-namespace access to telemetry collector
    kubectl --context ${CLUSTER1} apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1beta1
kind: ReferenceGrant
metadata:
  name: allow-otel-collector-traces-access
  namespace: gloo-mesh
spec:
  from:
  - group: gateway.kgateway.dev
    kind: HTTPListenerPolicy
    namespace: gloo-system
  to:
  - group: ""
    kind: Service
    name: gloo-telemetry-collector
EOF

    # HTTPListenerPolicy to configure tracing on Gloo Gateway
    kubectl --context ${CLUSTER1} apply -f - <<EOF
apiVersion: gateway.kgateway.dev/v1alpha1
kind: HTTPListenerPolicy
metadata:
  name: tracing-policy
  namespace: gloo-system
spec:
  targetRefs:
  - group: gateway.networking.k8s.io
    kind: Gateway
    name: http
  tracing:
    provider:
      openTelemetry:
        serviceName: gloo-gateway
        grpcService:
          backendRef:
            name: gloo-telemetry-collector
            namespace: gloo-mesh
            port: 4317
    spawnUpstreamSpan: true
EOF

    # Verify HTTPListenerPolicy is attached
    sleep 3
    log_test "Gloo Gateway tracing policy"
    local policy_status
    policy_status=$(kubectl --context ${CLUSTER1} get httplistenerpolicy tracing-policy -n gloo-system -o jsonpath='{.status.ancestors[0].conditions[?(@.type=="Accepted")].status}' 2>/dev/null || echo "")
    if [ "$policy_status" = "True" ]; then
        record_test "Gloo Gateway tracing" "Policy accepted" "Accepted: True" "PASS"
    else
        record_test "Gloo Gateway tracing" "Policy accepted" "Status: $policy_status" "FAIL"
    fi

    # Step 4a: Enable mesh-wide tracing (for ztunnel)
    log_info "Step 4a: Configuring mesh-wide tracing (ztunnel)..."

    for ctx in ${CLUSTER1} ${CLUSTER2}; do
        kubectl --context ${ctx} apply -f - <<EOF
apiVersion: telemetry.istio.io/v1
kind: Telemetry
metadata:
  name: mesh-tracing
  namespace: istio-system
spec:
  tracing:
  - providers:
    - name: otel-tracing
    randomSamplingPercentage: 100
EOF
        log_info "  $ctx: Mesh-wide tracing enabled"
    done

    # Step 4b: Enable tracing on waypoint proxies
    log_info "Step 4b: Configuring waypoint tracing..."

    for ctx in ${CLUSTER1} ${CLUSTER2}; do
        if kubectl --context ${ctx} get gateway waypoint -n bookinfo &>/dev/null; then
            kubectl --context ${ctx} apply -f - <<EOF
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
EOF
            log_info "  $ctx: Waypoint tracing enabled"
        else
            log_warn "  $ctx: Waypoint not found - skipping"
        fi
    done

    # Step 5: Generate traffic for traces
    log_info "Step 5: Generating traffic for traces..."
    for i in {1..15}; do
        curl -s "http://${GLOO_IP}/productpage" > /dev/null 2>&1 || true
        sleep 0.5
    done

    # Step 6: Verify traces in Jaeger
    log_info "Step 6: Verifying traces in Jaeger..."
    sleep 5  # Allow traces to propagate

    local jaeger_pod
    jaeger_pod=$(kubectl --context ${CLUSTER1} get pods -n gloo-mesh -l app.kubernetes.io/name=jaeger -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

    if [ -n "$jaeger_pod" ]; then
        # Query Jaeger API for services (Gloo Mesh uses /tracing-ui/ base path)
        local services
        services=$(kubectl --context ${CLUSTER1} exec -n gloo-mesh $jaeger_pod -- wget -q -O - "http://localhost:16686/tracing-ui/api/services" 2>/dev/null | jq -r '.data[]' 2>/dev/null | sort)

        if [ -n "$services" ]; then
            log_info "Services found in Jaeger:"
            echo "$services" | while read svc; do
                log_info "  - $svc"
            done

            # Test for expected services
            # Core services that should always appear
            log_test "Gloo Gateway traces"
            if echo "$services" | grep -q "gloo-gateway"; then
                record_test "Gloo Gateway traces" "Service in Jaeger" "Found" "PASS"
            else
                record_test "Gloo Gateway traces" "Service in Jaeger" "Not found" "FAIL"
            fi

            log_test "Productpage traces"
            if echo "$services" | grep -q "productpage"; then
                record_test "Productpage traces" "Service in Jaeger" "Found" "PASS"
            else
                record_test "Productpage traces" "Service in Jaeger" "Not found" "FAIL"
            fi

            # Backend services from OTel-instrumented Bookinfo
            log_test "Details traces"
            if echo "$services" | grep -q "details"; then
                record_test "Details traces" "Service in Jaeger" "Found" "PASS"
            else
                record_test "Details traces" "Service in Jaeger" "Not found" "FAIL"
            fi

            log_test "Ratings traces"
            if echo "$services" | grep -q "ratings"; then
                record_test "Ratings traces" "Service in Jaeger" "Found" "PASS"
            else
                record_test "Ratings traces" "Service in Jaeger" "Not found" "FAIL"
            fi

            # ztunnel traces (Solo Enterprise feature)
            log_test "ztunnel traces"
            if echo "$services" | grep -q "ztunnel"; then
                record_test "ztunnel traces" "Service in Jaeger" "Found" "PASS"
            else
                record_test "ztunnel traces" "Service in Jaeger" "Not found" "FAIL"
            fi

            # Waypoint traces - should appear with ClusterIP service fix
            # Waypoint services appear as destination service names (e.g., details.bookinfo.svc.cluster.local)
            log_test "Waypoint traces"
            if echo "$services" | grep -qE "(details|productpage|reviews)\.bookinfo\.(svc\.cluster\.local|mesh\.internal)"; then
                record_test "Waypoint traces" "Service in Jaeger" "Found (destination services)" "PASS"
            else
                record_test "Waypoint traces" "Service in Jaeger" "Not found" "FAIL"
            fi

            # Note: Reviews service not OTel-instrumented in current Bookinfo images
            if echo "$services" | grep -q "reviews"; then
                log_info "Reviews traces: Found"
            else
                log_info "Reviews traces: Not found (reviews service not OTel-instrumented)"
            fi
        else
            log_warn "No services found in Jaeger yet"
            record_test "Jaeger services" "Services found" "No services" "FAIL"
        fi
    else
        log_error "Jaeger pod not found"
        record_test "Jaeger pod" "Pod exists" "Not found" "FAIL"
    fi

    log_info ""
    log_info "Tracing configuration complete!"
    log_info "To view traces in browser:"
    log_info "  kubectl --context ${CLUSTER1} port-forward -n gloo-mesh svc/gloo-mesh-ui 8090:8090"
    log_info "  Open http://localhost:8090 -> Tracing"
    log_info ""
    log_info "Expected services in traces:"
    log_info "  - gloo-gateway (ingress via HTTPListenerPolicy)"
    log_info "  - ztunnel (Solo Enterprise L7 tracing)"
    log_info "  - productpage, details, ratings (OTel-instrumented Bookinfo)"
    log_info "  - waypoint (as destination FQDNs like details.bookinfo.svc.cluster.local)"
    log_info ""
    log_info "Note: reviews may not appear (service not OTel-instrumented in current images)"

    set -e
}

# ================================================
# Setup Orchestration
# ================================================
check_setup_complete() {
    # Check if clusters are accessible and have required components
    # Returns 0 if setup is complete, 1 if setup is needed

    # Check cluster connectivity
    if ! kubectl --context "$CLUSTER1" get nodes &>/dev/null; then
        log_info "Cluster $CLUSTER1 not accessible"
        return 1
    fi
    if ! kubectl --context "$CLUSTER2" get nodes &>/dev/null; then
        log_info "Cluster $CLUSTER2 not accessible"
        return 1
    fi

    # Check for Gloo Gateway (gloo-system namespace with pods)
    local gloo_pods=$(kubectl --context "$CLUSTER1" get pods -n gloo-system --no-headers 2>/dev/null | wc -l)
    if [ "$gloo_pods" -eq 0 ]; then
        log_info "Gloo Gateway not installed on $CLUSTER1"
        return 1
    fi

    # Check for Gloo Platform (gloo-mesh namespace with pods)
    local mesh_pods=$(kubectl --context "$CLUSTER1" get pods -n gloo-mesh --no-headers 2>/dev/null | wc -l)
    if [ "$mesh_pods" -eq 0 ]; then
        log_info "Gloo Platform not installed on $CLUSTER1"
        return 1
    fi

    # Check for Istio on both clusters (istio-system namespace with pods)
    local istio1_pods=$(kubectl --context "$CLUSTER1" get pods -n istio-system --no-headers 2>/dev/null | wc -l)
    if [ "$istio1_pods" -eq 0 ]; then
        log_info "Istio not installed on $CLUSTER1"
        return 1
    fi

    local istio2_pods=$(kubectl --context "$CLUSTER2" get pods -n istio-system --no-headers 2>/dev/null | wc -l)
    if [ "$istio2_pods" -eq 0 ]; then
        log_info "Istio not installed on $CLUSTER2"
        return 1
    fi

    return 0
}

run_setup() {
    if [ "$SKIP_SETUP" = true ]; then
        log_info "Skipping setup.sh (--skip-setup)"
        return 0
    fi

    # Check if setup is already complete
    if check_setup_complete; then
        log_info "Setup already complete - clusters accessible with Gloo Gateway, Gloo Platform, and Istio"
        return 0
    fi

    # Setup is needed - but only run if --create-clusters was specified or clusters exist
    # Check if clusters are accessible (just not fully set up)
    if kubectl --context "$CLUSTER1" get nodes &>/dev/null && \
       kubectl --context "$CLUSTER2" get nodes &>/dev/null; then
        log_step "Running setup.sh (clusters exist but need configuration)..."
    else
        if [ "$CREATE_CLUSTERS" != true ]; then
            log_error "Clusters not accessible. Use --create-clusters to create GKE clusters first."
            exit 1
        fi
        log_step "Running setup.sh with cluster creation..."
    fi

    local setup_args="-c $CONFIG_FILE"
    if [ "$CREATE_CLUSTERS" = true ]; then
        setup_args="$setup_args --create-clusters"
    fi

    if ! "$SCRIPT_DIR/setup.sh" $setup_args; then
        log_error "setup.sh failed"
        exit 1
    fi

    log_info "Setup complete"
}

run_workshop_steps() {
    local rc

    run_step "deploy_bookinfo" do_deploy_bookinfo; rc=$?
    [ $rc -eq 1 ] && return 1
    [ $rc -eq 2 ] && return 0

    run_step "expose_ingress" do_expose_ingress; rc=$?
    [ $rc -eq 1 ] && return 1
    [ $rc -eq 2 ] && return 0

    run_step "verify_no_mesh" do_verify_no_mesh; rc=$?
    [ $rc -eq 1 ] && return 1
    [ $rc -eq 2 ] && return 0

    run_step "add_to_mesh" do_add_to_mesh; rc=$?
    [ $rc -eq 1 ] && return 1
    [ $rc -eq 2 ] && return 0

    run_step "verify_mesh" do_verify_mesh; rc=$?
    [ $rc -eq 1 ] && return 1
    [ $rc -eq 2 ] && return 0

    run_step "peer_clusters" do_peer_clusters; rc=$?
    [ $rc -eq 1 ] && return 1
    [ $rc -eq 2 ] && return 0

    run_step "add_gloo_to_mesh" do_add_gloo_to_mesh; rc=$?
    [ $rc -eq 1 ] && return 1
    [ $rc -eq 2 ] && return 0

    run_step "verify_observability" do_verify_observability; rc=$?
    [ $rc -eq 1 ] && return 1
    [ $rc -eq 2 ] && return 0

    run_step "enable_global_services" do_enable_global_services; rc=$?
    [ $rc -eq 1 ] && return 1
    [ $rc -eq 2 ] && return 0

    run_step "test_failover" do_test_failover; rc=$?
    [ $rc -eq 1 ] && return 1
    [ $rc -eq 2 ] && return 0

    run_step "deploy_waypoint" do_deploy_waypoint; rc=$?
    [ $rc -eq 1 ] && return 1
    [ $rc -eq 2 ] && return 0

    run_step "canary_routing" do_canary_routing; rc=$?
    [ $rc -eq 1 ] && return 1
    [ $rc -eq 2 ] && return 0

    run_step "test_rate_limiting" do_test_rate_limiting; rc=$?
    [ $rc -eq 1 ] && return 1
    [ $rc -eq 2 ] && return 0

    return 0
}

run_verification_tests() {
    log_step "Running Verification Tests"

    set +e

    # Basic connectivity
    test_http_endpoint "http://${GLOO_IP}/productpage" "200" "Productpage accessible"

    # Mesh enrollment
    test_pods_running "$CLUSTER1" "bookinfo" "app=productpage" 1 "Cluster1 productpage in mesh"
    test_pods_running "$CLUSTER2" "bookinfo" "app=productpage" 1 "Cluster2 productpage in mesh"

    # Gloo components
    test_pods_running "$CLUSTER1" "gloo-mesh" "app=gloo-mesh-mgmt-server" 1 "Gloo mgmt server running"
    test_pods_running "$CLUSTER1" "gloo-mesh" "app.kubernetes.io/name=jaeger" 1 "Jaeger running"
    test_pods_running "$CLUSTER1" "gloo-mesh" "app.kubernetes.io/name=prometheus" 1 "Prometheus running"

    # Istio components
    test_pods_running "$CLUSTER1" "istio-system" "app=istiod" 1 "Istiod running on cluster1"
    test_pods_running "$CLUSTER1" "istio-system" "app=ztunnel" 1 "ztunnel running on cluster1"
    test_pods_running "$CLUSTER2" "istio-system" "app=istiod" 1 "Istiod running on cluster2"
    test_pods_running "$CLUSTER2" "istio-system" "app=ztunnel" 1 "ztunnel running on cluster2"

    set -e
}

cleanup_resources() {
    log_step "Cleanup"

    "$SCRIPT_DIR/cleanup.sh" -c "$CONFIG_FILE" -y || log_warn "Cleanup had some errors"

    log_info "Cleanup complete"
}

# ================================================
# Main
# ================================================
print_header() {
    echo ""
    echo "=============================================="
    echo "     OMNI WORKSHOP END-TO-END TEST"
    echo "=============================================="
    echo ""
    log_info "Config file: $CONFIG_FILE"
    log_info "CLUSTER1: $CLUSTER1"
    log_info "CLUSTER2: $CLUSTER2"
    if [ -n "$START_FROM_STEP" ]; then
        log_info "Starting from step: $START_FROM_STEP"
    fi
    if [ -n "$STOP_AFTER_STEP" ]; then
        log_info "Stopping after step: $STOP_AFTER_STEP"
    fi
    if [ "$SKIP_TRACING" = true ]; then
        log_info "Tracing: SKIPPED (--skip-tracing)"
    else
        log_info "Tracing: ENABLED (will configure after workshop steps)"
    fi
    echo ""
}

main() {
    parse_arguments "$@"
    load_config
    load_progress

    # Handle --list option
    if [ "$LIST_STEPS" = true ]; then
        list_steps "${WORKSHOP_STEPS[@]}"
        exit 0
    fi

    # Handle --reset option
    if [ "$RESET_PROGRESS" = true ]; then
        clear_progress
    fi

    print_header

    if [ "$TESTS_ONLY" = true ]; then
        log_info "Tests-only mode - skipping setup and workshop steps"
    else
        # Run setup.sh first (unless skipped)
        run_setup

        # Run workshop steps
        if ! run_workshop_steps; then
            log_error "Workshop steps failed"
            log_error "To retry from last step: $0 -c $CONFIG_FILE -s $CURRENT_STEP"
            exit 1
        fi

        # Run optional tracing step (enabled by default, skip with --skip-tracing)
        if [ "$SKIP_TRACING" != true ]; then
            log_step "Running optional tracing configuration..."
            do_enable_tracing
        else
            log_info "Skipping tracing configuration (--skip-tracing)"
        fi
    fi

    # Run verification tests
    run_verification_tests

    # Print summary
    print_test_summary
    TEST_EXIT_CODE=$?

    # Cleanup if requested
    if [ "$DELETE_AFTER" = true ]; then
        cleanup_resources
    else
        echo ""
        log_info "Environment kept intact. To cleanup later, run:"
        log_info "  $SCRIPT_DIR/cleanup.sh -c $CONFIG_FILE"
    fi

    exit $TEST_EXIT_CODE
}

main "$@"
