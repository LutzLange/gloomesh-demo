#!/bin/bash
# Ambient Mesh Workshop - Interactive Demo Runner
# Single-cluster demo with Istio Gateway for ingress

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test-lib.sh"

#######################################
# Configuration
#######################################

CONFIG_FILE=""
START_FROM_STEP=1
LIST_STEPS=false

usage() {
    cat << 'EOF'
Ambient Mesh Workshop - Interactive Demo Runner

This script runs through the workshop demo steps interactively, pausing at
each step with explanations. Perfect for live demos and presentations.

Usage:
  ./workshop.sh -c env.sh              # Run all steps interactively
  ./workshop.sh -c env.sh --step 3     # Start from step 3
  ./workshop.sh -c env.sh --list       # List all steps

Options:
  -c, --config FILE   Load configuration from FILE
  --step N            Start from step N (1-9)
  --list, -l          List all steps
  -h, --help          Show this help message

Steps:
  1. Deploy Bookinfo           - Deploy sample application
  2. Expose via Gateway        - Create HTTPRoute for ingress
  3. Add to Mesh               - Label namespace for ambient mesh
  4. Verify mTLS               - Check encrypted traffic
  5. Observability             - View access logs
  6. Deploy Waypoint           - Add L7 proxy for traffic management
  7. Canary Routing            - Header-based routing to reviews-v2
  8. Traffic Shifting          - Weighted routing 80/20 split
  9. Configure Tracing         - Set up distributed tracing (requires Gloo Platform)
EOF
    exit 0
}

list_steps() {
    echo ""
    echo "Ambient Mesh Workshop Steps"
    echo "==========================="
    echo ""
    echo "  1. Deploy Bookinfo        - Deploy sample microservices application"
    echo "  2. Expose via Gateway     - Create HTTPRoute to expose productpage"
    echo "  3. Add to Mesh            - Label namespace for ambient mesh (mTLS enabled)"
    echo "  4. Verify mTLS            - Verify encrypted traffic via ztunnel"
    echo "  5. Observability          - View access logs and generate traffic"
    echo "  6. Deploy Waypoint        - Deploy waypoint proxy for L7 features"
    echo "  7. Canary Routing         - Route user 'jason' to reviews-v2"
    echo "  8. Traffic Shifting       - 80/20 split between v1 and v3"
    echo "  9. Configure Tracing      - Distributed tracing with Jaeger (requires Gloo Platform)"
    echo ""
    echo "Usage: ./workshop.sh -c env.sh --step <N>"
    echo ""
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
        --step)
            START_FROM_STEP="$2"
            shift 2
            ;;
        --list|-l)
            LIST_STEPS=true
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

# Handle --list before config validation
if [[ "$LIST_STEPS" == "true" ]]; then
    list_steps
fi

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

# Get Gateway IP
get_gateway_ip() {
    # Get IP from Gateway resource status (preferred)
    local ip=$(kubectl get gateway -n istio-ingress istio-ingressgateway -o jsonpath='{.status.addresses[0].value}' 2>/dev/null)
    if [[ -n "$ip" ]]; then
        echo "$ip"
        return
    fi
    # Fallback to service
    kubectl get svc -n istio-ingress istio-ingress -o jsonpath="{.status.loadBalancer.ingress[0]['hostname','ip']}" 2>/dev/null
}

#######################################
# Demo Steps
#######################################

step_1_deploy_bookinfo() {
    print_header "Step 1: Deploy Bookinfo"

    print_tip "Using OTel-instrumented Bookinfo for distributed tracing support."

    pause_for_presenter "Press Enter to deploy Bookinfo..."

    echo "Creating namespace and deploying application..."
    kubectl create ns bookinfo 2>/dev/null || true
    # Use OTel-instrumented Bookinfo for distributed tracing
    kubectl apply -n bookinfo -f https://raw.githubusercontent.com/LutzLange/bookinfo/main/platform/kube/bookinfo-otel.yaml

    echo ""
    echo "Waiting for pods to be ready..."
    kubectl wait --for=condition=Ready pod -l app=productpage -n bookinfo --timeout=120s
    kubectl wait --for=condition=Ready pod -l app=reviews -n bookinfo --timeout=120s

    echo ""
    kubectl get pods -n bookinfo

    log_success "Bookinfo deployed"
    pause_for_presenter
}

step_2_expose_ingress() {
    print_header "Step 2: Expose via Istio Gateway"

    local gateway_ip=$(get_gateway_ip)
    print_tip "Gateway IP: $gateway_ip"

    pause_for_presenter "Press Enter to create HTTPRoute..."

    kubectl apply -f - <<EOYAML
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: bookinfo
  namespace: bookinfo
spec:
  parentRefs:
  - name: istio-ingressgateway
    namespace: istio-ingress
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
    - path:
        type: PathPrefix
        value: /api/v1/products
    backendRefs:
    - name: productpage
      port: 9080
EOYAML

    echo ""
    echo "Testing access (application is NOT in mesh yet)..."
    sleep 2
    curl -s "http://${gateway_ip}/productpage" | grep -o "<title>.*</title>"

    echo ""
    echo -e "${BLUE}Open in browser:${NC} http://${gateway_ip}/productpage"

    log_success "HTTPRoute created"
    pause_for_presenter
}

step_3_add_to_mesh() {
    print_header "Step 3: Add to Ambient Mesh"

    print_tip "With ambient mesh, one label enables mTLS for the entire namespace - no sidecars, no restarts."

    pause_for_presenter "Press Enter to add bookinfo to the mesh..."

    kubectl label namespace bookinfo istio.io/dataplane-mode=ambient --overwrite

    echo ""
    echo "The namespace is now part of the mesh!"
    echo ""
    echo "Checking ztunnel has picked up the workloads..."
    sleep 3
    kubectl logs -n istio-system -l app=ztunnel --tail=5 | grep -i bookinfo || echo "Waiting for ztunnel logs..."

    log_success "Bookinfo added to mesh"
    pause_for_presenter
}

step_4_verify_mtls() {
    print_header "Step 4: Verify mTLS Encryption"

    local gateway_ip=$(get_gateway_ip)
    print_tip "All traffic between services is now encrypted with mTLS."

    pause_for_presenter "Press Enter to verify mTLS..."

    echo "Generating traffic..."
    for i in {1..3}; do
        curl -s "http://${gateway_ip}/productpage" > /dev/null
    done

    echo ""
    echo "Checking ztunnel logs for encrypted traffic (HBONE protocol)..."
    kubectl logs -n istio-system -l app=ztunnel --tail=30 | grep -E "inbound|outbound|HBONE" | head -10 || echo "Check logs manually"

    echo ""
    echo "Adding ingress gateway to mesh for end-to-end mTLS..."
    kubectl label namespace istio-ingress istio.io/dataplane-mode=ambient --overwrite

    log_success "mTLS verified"
    pause_for_presenter
}

step_5_observability() {
    print_header "Step 5: Observability"

    local gateway_ip=$(get_gateway_ip)
    print_tip "View access logs and metrics without sidecars."

    pause_for_presenter "Press Enter to generate traffic and view logs..."

    echo "Generating traffic..."
    for i in {1..5}; do
        curl -s "http://${gateway_ip}/productpage" > /dev/null
        echo "Request $i sent"
        sleep 0.5
    done

    echo ""
    echo "Viewing access logs from ztunnel..."
    kubectl logs -n istio-system -l app=ztunnel --tail=20 | grep -E "GET|POST" | head -10

    log_success "Observability demonstrated"
    pause_for_presenter
}

step_6_deploy_waypoint() {
    print_header "Step 6: Deploy Waypoint Proxy"

    print_tip "Waypoints enable L7 traffic management: canary routing, header-based routing, etc."

    pause_for_presenter "Press Enter to deploy waypoint..."

    echo "Configuring namespace to use waypoint..."
    kubectl label namespace bookinfo istio.io/use-waypoint=waypoint --overwrite

    echo ""
    echo "Creating waypoint gateway..."
    kubectl apply -f - <<EOYAML
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
EOYAML

    echo ""
    echo "Waiting for waypoint to be ready..."
    kubectl wait --for=condition=Programmed gateway/waypoint -n bookinfo --timeout=60s

    echo ""
    echo "Creating version-specific services for routing..."
    kubectl apply -f - <<EOYAML
apiVersion: v1
kind: Service
metadata:
  name: reviews-v1
  namespace: bookinfo
spec:
  selector:
    app: reviews
    version: v1
  ports:
  - port: 9080
    name: http
---
apiVersion: v1
kind: Service
metadata:
  name: reviews-v2
  namespace: bookinfo
spec:
  selector:
    app: reviews
    version: v2
  ports:
  - port: 9080
    name: http
---
apiVersion: v1
kind: Service
metadata:
  name: reviews-v3
  namespace: bookinfo
spec:
  selector:
    app: reviews
    version: v3
  ports:
  - port: 9080
    name: http
EOYAML

    echo ""
    kubectl get gateway waypoint -n bookinfo

    log_success "Waypoint deployed"
    pause_for_presenter
}

step_7_canary_routing() {
    print_header "Step 7: Canary Routing"

    local gateway_ip=$(get_gateway_ip)
    print_tip "Route user 'jason' to reviews-v2 (black stars), others to reviews-v1 (no stars)."

    pause_for_presenter "Press Enter to configure canary routing..."

    echo "Attaching waypoint to reviews service..."
    kubectl label svc reviews -n bookinfo istio.io/use-waypoint=waypoint --overwrite

    echo ""
    echo "Creating HTTPRoute for canary..."
    kubectl apply -f - <<EOYAML
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
EOYAML

    echo ""
    echo "Waiting for routing rules to propagate..."
    sleep 10

    echo ""
    echo "Testing canary routing..."
    echo ""
    echo "Default (no header) - should get reviews-v1 (no color):"
    kubectl exec -n bookinfo deploy/ratings-v1 -- curl -s reviews:9080/reviews/0 2>/dev/null | grep -o '"color"[^,]*' || echo "No color (reviews-v1)"

    echo ""
    echo "User 'jason' (with header) - should get reviews-v2 (black stars):"
    kubectl exec -n bookinfo deploy/ratings-v1 -- curl -s -H "end-user: jason" reviews:9080/reviews/0 2>/dev/null | grep -o '"color"[^,]*'

    echo ""
    echo -e "${BLUE}Test in browser:${NC}"
    echo "  1. Open http://${gateway_ip}/productpage"
    echo "  2. Without login: No stars (reviews-v1)"
    echo "  3. Login as 'jason': Black stars (reviews-v2)"

    log_success "Canary routing configured"
    pause_for_presenter
}

step_8_traffic_shifting() {
    print_header "Step 8: Traffic Shifting"

    local gateway_ip=$(get_gateway_ip)
    print_tip "Gradually shift traffic from reviews-v1 to reviews-v3 (red stars)."

    pause_for_presenter "Press Enter to configure 80/20 traffic split..."

    kubectl apply -f - <<EOYAML
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
  - backendRefs:
    - name: reviews-v1
      port: 9080
      weight: 80
    - name: reviews-v3
      port: 9080
      weight: 20
EOYAML

    echo ""
    echo "Traffic split: 80% reviews-v1, 20% reviews-v3"
    echo ""
    echo "Testing traffic distribution (10 requests)..."
    for i in {1..10}; do
        result=$(kubectl exec -n bookinfo deploy/ratings-v1 -- curl -s reviews:9080/reviews/0 2>/dev/null | grep -o '"color"[^,]*' || echo "no-color")
        echo "Request $i: $result"
    done

    echo ""
    echo -e "${BLUE}Refresh the browser multiple times to see the shift:${NC}"
    echo "  http://${gateway_ip}/productpage"

    log_success "Traffic shifting configured"
    pause_for_presenter
}

step_9_configure_tracing() {
    print_header "Step 9: Configure Distributed Tracing (Optional)"

    print_tip "Tracing requires Gloo Platform with Jaeger. Skip this step if not installed."

    # Check if Gloo Platform is installed
    if ! kubectl get ns gloo-mesh &>/dev/null; then
        log_warn "Gloo Platform not installed - skipping tracing configuration"
        echo ""
        echo "To enable tracing, install Gloo Platform with:"
        echo "  export GLOO_MESH_LICENSE_KEY=<your-key>"
        echo "  ./scripts/setup.sh -c env.sh"
        pause_for_presenter
        return 0
    fi

    pause_for_presenter "Press Enter to configure distributed tracing..."

    echo "Step 1: Configure ztunnel distributed tracing..."
    kubectl patch configmap istio-ztunnel -n istio-system --type merge -p '{
      "data": {
        "l7_config.yaml": "accessLog:\n  enabled: true\n  skipConnectionLog: false\ndistributedTracing:\n  enabled: true\n  otlpEndpoint: http://gloo-telemetry-collector.gloo-mesh:4317\nenabled: true\nmetrics:\n  enabled: true\n"
      }
    }' 2>/dev/null || echo "  (ztunnel config may already be set)"

    echo ""
    echo "Step 2: Create ClusterIP service for telemetry collector..."
    kubectl apply -f - <<EOYAML
apiVersion: v1
kind: Service
metadata:
  name: gloo-telemetry-collector-clusterip
  namespace: gloo-mesh
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
    appProtocol: grpc
  - name: otlp-http
    port: 4318
    targetPort: 4318
EOYAML

    echo ""
    echo "Step 3: Add extension provider to Istio mesh config..."
    CURRENT_MESH=$(kubectl get configmap istio -n istio-system -o jsonpath='{.data.mesh}')

    if ! echo "$CURRENT_MESH" | grep -q "gloo-telemetry-collector-clusterip"; then
        NEW_MESH="${CURRENT_MESH}
extensionProviders:
- name: otel-tracing
  opentelemetry:
    service: gloo-telemetry-collector-clusterip.gloo-mesh.svc.cluster.local
    port: 4317"

        kubectl patch configmap istio -n istio-system \
            --type merge -p "{\"data\":{\"mesh\":$(echo "$NEW_MESH" | jq -Rs .)}}"

        echo "Restarting istiod..."
        kubectl rollout restart deployment/istiod -n istio-system
        kubectl rollout status deployment/istiod -n istio-system --timeout=120s
    else
        echo "  Extension provider already configured"
    fi

    echo ""
    echo "Step 4: Create Telemetry resources..."
    kubectl apply -f - <<EOYAML
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
---
apiVersion: telemetry.istio.io/v1
kind: Telemetry
metadata:
  name: tracing-gateway
  namespace: istio-ingress
spec:
  targetRefs:
  - kind: Gateway
    name: istio-ingressgateway
    group: gateway.networking.k8s.io
  tracing:
  - providers:
    - name: otel-tracing
    randomSamplingPercentage: 100
---
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
EOYAML

    echo ""
    echo "Step 5: Restart components to apply tracing config..."
    echo "Restarting Istio Gateway (trace initiator)..."
    kubectl rollout restart deploy -n istio-ingress
    kubectl rollout status deploy/istio-ingressgateway-istio -n istio-ingress --timeout=120s
    echo "Restarting ztunnel and waypoint..."
    kubectl rollout restart daemonset/ztunnel -n istio-system
    kubectl rollout restart deployment/waypoint -n bookinfo 2>/dev/null || true
    kubectl rollout status daemonset/ztunnel -n istio-system --timeout=120s

    echo ""
    local gateway_ip=$(get_gateway_ip)
    echo "Generating traffic to create traces..."
    for i in {1..5}; do
        curl -s "http://${gateway_ip}/productpage" > /dev/null
        echo "Request $i sent"
        sleep 1
    done

    echo ""
    echo -e "${BLUE}View traces in Gloo Platform UI:${NC}"
    echo "  kubectl port-forward -n gloo-mesh svc/gloo-mesh-ui 8090:8090"
    echo "  Open http://localhost:8090 -> Tracing"
    echo ""
    echo "Select service 'productpage.bookinfo' or 'waypoint.bookinfo' and click 'Find Traces'"

    log_success "Distributed tracing configured"
    pause_for_presenter
}

#######################################
# Step Runner
#######################################

# Array of all steps
STEPS=(
    "step_1_deploy_bookinfo"
    "step_2_expose_ingress"
    "step_3_add_to_mesh"
    "step_4_verify_mtls"
    "step_5_observability"
    "step_6_deploy_waypoint"
    "step_7_canary_routing"
    "step_8_traffic_shifting"
    "step_9_configure_tracing"
)

STEP_NAMES=(
    "Deploy Bookinfo"
    "Expose via Istio Gateway"
    "Add to Ambient Mesh"
    "Verify mTLS"
    "Observability"
    "Deploy Waypoint"
    "Canary Routing"
    "Traffic Shifting"
    "Configure Tracing (Optional)"
)

run_from_step() {
    local start=$1

    if [[ $start -lt 1 || $start -gt ${#STEPS[@]} ]]; then
        log_error "Invalid step number: $start (valid: 1-${#STEPS[@]})"
        exit 1
    fi

    for i in "${!STEPS[@]}"; do
        local step_num=$((i + 1))
        if [[ $step_num -ge $start ]]; then
            log_info "Running step $step_num: ${STEP_NAMES[$i]}"
            ${STEPS[$i]}
        fi
    done
}

#######################################
# Main
#######################################

main() {
    print_header "Ambient Mesh Workshop"

    log_info "Checking cluster connectivity..."
    if ! kubectl cluster-info &>/dev/null; then
        log_error "Cannot connect to cluster. Check your kubeconfig."
        exit 1
    fi

    local gateway_ip=$(get_gateway_ip)
    if [[ -z "$gateway_ip" ]]; then
        log_error "Istio Gateway not found. Run setup.sh first."
        exit 1
    fi

    echo ""
    echo "Gateway IP: $gateway_ip"
    echo ""

    echo "Workshop Steps:"
    for i in "${!STEP_NAMES[@]}"; do
        local step_num=$((i + 1))
        if [[ $step_num -lt $START_FROM_STEP ]]; then
            echo -e "  ${step_num}. ${STEP_NAMES[$i]} ${YELLOW}(skipped)${NC}"
        else
            echo "  ${step_num}. ${STEP_NAMES[$i]}"
        fi
    done
    echo ""

    if [[ $START_FROM_STEP -gt 1 ]]; then
        log_info "Starting from step $START_FROM_STEP"
    fi

    pause_for_presenter "Press Enter to start the workshop..."

    run_from_step "$START_FROM_STEP"

    print_header "Workshop Complete"

    echo "Summary of what was demonstrated:"
    echo "  - Zero-disruption mesh onboarding with namespace label"
    echo "  - Automatic mTLS encryption"
    echo "  - L7 observability without sidecars"
    echo "  - Waypoint proxies for L7 traffic management"
    echo "  - Canary routing with HTTPRoute"
    echo "  - Traffic shifting between versions"
    echo ""
    echo "For cleanup: ./scripts/cleanup.sh -c env.sh"
}

main "$@"
