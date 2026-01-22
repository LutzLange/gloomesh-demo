#!/bin/bash
# Ambient Mesh Workshop - Shared Test Library
# Simplified for single-cluster operation

#######################################
# Colors
#######################################

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

#######################################
# Logging Functions
#######################################

log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_step()    { echo -e "${YELLOW}==> $1${NC}"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }
log_test()    { echo -e "${BLUE}[TEST]${NC} $1"; }
log_pass()    { echo -e "${GREEN}[PASS]${NC} $1"; }
log_fail()    { echo -e "${RED}[FAIL]${NC} $1"; }

#######################################
# Progress Tracking
#######################################

# Get script directory and repo root
get_script_dir() {
    cd "$(dirname "${BASH_SOURCE[0]}")" && pwd
}

SCRIPT_DIR="$(get_script_dir)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
PROGRESS_FILE="${REPO_ROOT}/.workshop-progress"

# Array to track completed steps
declare -a COMPLETED_STEPS=()

load_progress() {
    if [[ -f "$PROGRESS_FILE" ]]; then
        mapfile -t COMPLETED_STEPS < "$PROGRESS_FILE"
        log_info "Loaded progress: ${#COMPLETED_STEPS[@]} steps completed"
    fi
}

save_progress() {
    printf '%s\n' "${COMPLETED_STEPS[@]}" > "$PROGRESS_FILE"
}

is_step_complete() {
    local step_name=$1
    for completed in "${COMPLETED_STEPS[@]}"; do
        if [[ "$completed" == "$step_name" ]]; then
            return 0
        fi
    done
    return 1
}

mark_step_complete() {
    local step_name=$1
    if ! is_step_complete "$step_name"; then
        COMPLETED_STEPS+=("$step_name")
        save_progress
        log_success "Step '$step_name' marked complete"
    fi
}

reset_progress() {
    COMPLETED_STEPS=()
    rm -f "$PROGRESS_FILE"
    log_info "Progress reset"
}

run_step() {
    local step_name=$1
    local step_func=$2

    if is_step_complete "$step_name"; then
        log_info "Skipping '$step_name' (already completed)"
        return 0
    fi

    log_step "Running step: $step_name"
    if $step_func; then
        mark_step_complete "$step_name"
        return 0
    else
        log_error "Step '$step_name' failed"
        return 1
    fi
}

#######################################
# Test Recording
#######################################

# Arrays for test results
declare -a TEST_NAMES=()
declare -a TEST_EXPECTED=()
declare -a TEST_ACTUAL=()
declare -a TEST_RESULTS=()

record_test() {
    local name=$1
    local expected=$2
    local actual=$3
    local result=$4

    TEST_NAMES+=("$name")
    TEST_EXPECTED+=("$expected")
    TEST_ACTUAL+=("$actual")
    TEST_RESULTS+=("$result")

    if [[ "$result" == "PASS" ]]; then
        log_pass "$name"
    else
        log_fail "$name (expected: $expected, got: $actual)"
    fi
}

print_test_summary() {
    local total=${#TEST_RESULTS[@]}
    local passed=0
    local failed=0

    for result in "${TEST_RESULTS[@]}"; do
        if [[ "$result" == "PASS" ]]; then
            ((passed++))
        else
            ((failed++))
        fi
    done

    echo ""
    echo "========================================"
    echo "Test Summary"
    echo "========================================"
    echo -e "Total:  $total"
    echo -e "Passed: ${GREEN}$passed${NC}"
    echo -e "Failed: ${RED}$failed${NC}"
    echo "========================================"

    if [[ $failed -gt 0 ]]; then
        echo ""
        echo "Failed tests:"
        for i in "${!TEST_RESULTS[@]}"; do
            if [[ "${TEST_RESULTS[$i]}" == "FAIL" ]]; then
                echo "  - ${TEST_NAMES[$i]}: expected '${TEST_EXPECTED[$i]}', got '${TEST_ACTUAL[$i]}'"
            fi
        done
        return 1
    fi
    return 0
}

#######################################
# Wait Helpers
#######################################

wait_for_pods() {
    local namespace=$1
    local label=$2
    local timeout=${3:-300}

    log_info "Waiting for pods with label '$label' in namespace '$namespace'..."
    kubectl wait --for=condition=Ready pod -l "$label" -n "$namespace" --timeout="${timeout}s" 2>/dev/null
}

wait_for_deployment() {
    local namespace=$1
    local deployment=$2
    local timeout=${3:-300}

    log_info "Waiting for deployment '$deployment' in namespace '$namespace'..."
    kubectl rollout status deployment/"$deployment" -n "$namespace" --timeout="${timeout}s"
}

wait_for_loadbalancer() {
    local namespace=$1
    local service=$2
    local max_attempts=${3:-30}

    log_info "Waiting for LoadBalancer IP for service '$service' in namespace '$namespace'..."
    local attempt=0
    while [[ $attempt -lt $max_attempts ]]; do
        local ip=$(kubectl get svc "$service" -n "$namespace" -o jsonpath="{.status.loadBalancer.ingress[0]['hostname','ip']}" 2>/dev/null)
        if [[ -n "$ip" && "$ip" != "null" ]]; then
            log_success "LoadBalancer IP: $ip"
            echo "$ip"
            return 0
        fi
        ((attempt++))
        sleep 5
    done
    log_error "Timeout waiting for LoadBalancer IP"
    return 1
}

#######################################
# Test Helpers
#######################################

test_http_endpoint() {
    local url=$1
    local expected_code=$2
    local test_name=$3
    local retries=${4:-3}

    log_test "$test_name"
    local attempt=0
    local code=""

    while [[ $attempt -lt $retries ]]; do
        code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 --max-time 10 "$url" 2>/dev/null)
        if [[ "$code" == "$expected_code" ]]; then
            record_test "$test_name" "HTTP $expected_code" "HTTP $code" "PASS"
            return 0
        fi
        ((attempt++))
        sleep 2
    done

    record_test "$test_name" "HTTP $expected_code" "HTTP $code" "FAIL"
    return 1
}

test_http_contains() {
    local url=$1
    local pattern=$2
    local test_name=$3
    local retries=${4:-3}

    log_test "$test_name"
    local attempt=0

    while [[ $attempt -lt $retries ]]; do
        local response=$(curl -s --connect-timeout 5 --max-time 10 "$url" 2>/dev/null)
        if echo "$response" | grep -q "$pattern"; then
            record_test "$test_name" "contains '$pattern'" "found" "PASS"
            return 0
        fi
        ((attempt++))
        sleep 2
    done

    record_test "$test_name" "contains '$pattern'" "not found" "FAIL"
    return 1
}

test_pods_running() {
    local namespace=$1
    local label=$2
    local expected_count=${3:-1}
    local test_name=$4

    log_test "$test_name"
    local count=$(kubectl get pods -n "$namespace" -l "$label" --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)

    if [[ $count -ge $expected_count ]]; then
        record_test "$test_name" ">=$expected_count running" "$count running" "PASS"
        return 0
    else
        record_test "$test_name" ">=$expected_count running" "$count running" "FAIL"
        return 1
    fi
}

test_service_exists() {
    local namespace=$1
    local service=$2
    local test_name=$3

    log_test "$test_name"
    if kubectl get svc "$service" -n "$namespace" &>/dev/null; then
        record_test "$test_name" "exists" "exists" "PASS"
        return 0
    else
        record_test "$test_name" "exists" "not found" "FAIL"
        return 1
    fi
}

#######################################
# Presentation Helpers
#######################################

print_header() {
    local title=$1
    echo ""
    echo "========================================"
    echo "$title"
    echo "========================================"
    echo ""
}

print_tip() {
    local tip=$1
    echo ""
    echo -e "${BLUE}TIP:${NC} $tip"
    echo ""
}

pause_for_presenter() {
    local message=${1:-"Press Enter to continue..."}
    echo ""
    read -p "$message"
}

#######################################
# Environment Validation
#######################################

validate_env() {
    local missing=()

    [[ -z "${CLUSTER:-}" ]] && missing+=("CLUSTER")

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required environment variables: ${missing[*]}"
        log_error "Use -c to specify a config file or source your env.sh first"
        return 1
    fi

    log_info "Configuration:"
    log_info "  CLUSTER: $CLUSTER"
    return 0
}

validate_cluster_connectivity() {
    log_info "Checking cluster connectivity..."
    if ! kubectl cluster-info &>/dev/null; then
        log_error "Cannot connect to cluster. Check your kubeconfig."
        return 1
    fi
    log_success "Cluster connection verified"
    return 0
}
