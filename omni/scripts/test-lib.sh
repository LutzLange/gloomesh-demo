#!/bin/bash

# ================================================
# test-lib.sh - Shared functions for test scripts
# ================================================
#
# This library provides common functions used by test scripts.
# Source this file at the beginning of your test script:
#
#   SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
#   source "$SCRIPT_DIR/test-lib.sh"
#

# ================================================
# Colors for output
# ================================================
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# ================================================
# Test results tracking
# ================================================
declare -a TEST_RESULTS
TESTS_PASSED=0
TESTS_FAILED=0

# ================================================
# Setup Progress/Checkpoint System
# ================================================
CURRENT_STEP=""
START_FROM_STEP=""
STOP_AFTER_STEP=""
RESET_PROGRESS=false
LIST_STEPS=false

# Check if a step has been completed
step_completed() {
    local step="$1"
    if [ -z "$COMPLETED_STEPS" ]; then
        return 1
    fi
    [[ ",$COMPLETED_STEPS," == *",$step,"* ]]
}

# Mark a step as completed (appends to progress file)
mark_step_complete() {
    local step="$1"
    local progress_file="${PROGRESS_FILE:-/tmp/omni-test-progress}"

    if step_completed "$step"; then
        return 0  # Already marked
    fi

    if [ -z "$COMPLETED_STEPS" ]; then
        COMPLETED_STEPS="$step"
    else
        COMPLETED_STEPS="${COMPLETED_STEPS},${step}"
    fi

    # Update progress file
    echo "COMPLETED_STEPS=\"${COMPLETED_STEPS}\"" > "$progress_file"
}

# Load progress from file
load_progress() {
    local progress_file="${PROGRESS_FILE:-/tmp/omni-test-progress}"
    if [ -f "$progress_file" ]; then
        source "$progress_file"
        log_info "Loaded progress: $COMPLETED_STEPS"
    fi
}

# Clear all progress
clear_progress() {
    local progress_file="${PROGRESS_FILE:-/tmp/omni-test-progress}"
    COMPLETED_STEPS=""
    rm -f "$progress_file"
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

    # If step already completed (and not reset), skip it
    if step_completed "$step" && [ "$RESET_PROGRESS" != true ]; then
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
        # Check if we should stop here
        if should_stop_after "$step_name"; then
            log_info "Stopping after step: $step_name (as requested)"
            return 2  # Special return code to signal stop
        fi
        return 0
    fi

    # Run the step function
    if $step_function; then
        mark_step_complete "$step_name"

        # Check if we should stop after this step
        if should_stop_after "$step_name"; then
            log_info "Stopping after step: $step_name (as requested)"
            return 2  # Special return code to signal stop
        fi
        return 0
    else
        log_error "Step '$step_name' failed"
        log_error "To retry from this step, run: $0 -c $CONFIG_FILE -s $step_name"
        return 1
    fi
}

# List all steps and their status
list_steps() {
    local steps=("$@")

    echo ""
    echo "=============================================="
    echo "         WORKSHOP STEPS STATUS"
    echo "=============================================="
    echo ""
    printf "%-5s %-30s %-12s\n" "NUM" "STEP NAME" "STATUS"
    echo "----------------------------------------------"

    local num=1
    for step in "${steps[@]}"; do
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
    echo "  $0 -c $CONFIG_FILE -s <step_name>"
    echo ""
    echo "To stop after a specific step:"
    echo "  $0 -c $CONFIG_FILE --stop-after <step_name>"
    echo ""
    echo "To reset progress and start fresh:"
    echo "  $0 -c $CONFIG_FILE --reset"
    echo ""
}

# Get step name by number from array
get_step_by_number() {
    local num="$1"
    shift
    local steps=("$@")

    if [[ "$num" =~ ^[0-9]+$ ]] && [ "$num" -ge 1 ] && [ "$num" -le "${#steps[@]}" ]; then
        echo "${steps[$((num-1))]}"
    else
        echo "$num"  # Return as-is if not a number
    fi
}

# ================================================
# Logging Functions
# ================================================
log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_step() { echo -e "\n${BLUE}==>${NC} ${YELLOW}$1${NC}"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_test() { echo -e "${BLUE}[TEST]${NC} $1"; }
log_pass() { echo -e "${GREEN}[PASS]${NC} $1"; }
log_fail() { echo -e "${RED}[FAIL]${NC} $1"; }

# ================================================
# Test Recording Functions
# ================================================
record_test() {
    local name="$1"
    local expected="$2"
    local actual="$3"
    local status="$4"  # PASS or FAIL

    TEST_RESULTS+=("$name|$expected|$actual|$status")

    if [ "$status" = "PASS" ]; then
        ((TESTS_PASSED++))
        log_pass "$name"
    else
        ((TESTS_FAILED++))
        log_fail "$name"
        log_error "  Expected: $expected"
        log_error "  Actual:   $actual"
    fi
}

print_test_summary() {
    echo ""
    echo "=============================================="
    echo "               TEST SUMMARY"
    echo "=============================================="
    echo ""
    printf "%-45s %-10s\n" "TEST NAME" "STATUS"
    echo "----------------------------------------------"

    for result in "${TEST_RESULTS[@]}"; do
        IFS='|' read -r name expected actual status <<< "$result"
        if [ "$status" = "PASS" ]; then
            printf "%-45s ${GREEN}%-10s${NC}\n" "$name" "$status"
        else
            printf "%-45s ${RED}%-10s${NC}\n" "$name" "$status"
        fi
    done

    echo "----------------------------------------------"
    echo ""
    echo "Total: $((TESTS_PASSED + TESTS_FAILED)) | Passed: $TESTS_PASSED | Failed: $TESTS_FAILED"
    echo ""

    if [ $TESTS_FAILED -eq 0 ]; then
        log_info "All tests passed!"
        return 0
    else
        log_error "$TESTS_FAILED test(s) failed"
        return 1
    fi
}

# ================================================
# Wait Functions
# ================================================
wait_for_pods() {
    local context="$1"
    local namespace="$2"
    local label="$3"
    local timeout="${4:-120s}"

    log_info "Waiting for pods with label $label in $namespace..."
    kubectl --context "$context" wait --for=condition=Ready pods -n "$namespace" -l "$label" --timeout="$timeout"
}

wait_for_deployment() {
    local context="$1"
    local namespace="$2"
    local deployment="$3"
    local timeout="${4:-120s}"

    log_info "Waiting for deployment $deployment in $namespace..."
    kubectl --context "$context" rollout status deployment/"$deployment" -n "$namespace" --timeout="$timeout"
}

wait_for_loadbalancer() {
    local context="$1"
    local namespace="$2"
    local service="$3"
    local max_attempts="${4:-60}"

    log_info "Waiting for LoadBalancer IP on $service..."
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

# ================================================
# HTTP Test Functions
# ================================================
test_http_endpoint() {
    local url="$1"
    local expected_code="${2:-200}"
    local test_name="${3:-HTTP test}"
    local max_retries="${4:-3}"

    log_test "$test_name"

    local code
    local i
    for ((i=1; i<=max_retries; i++)); do
        code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$url" 2>/dev/null)
        if [ "$code" = "$expected_code" ]; then
            record_test "$test_name" "HTTP $expected_code" "HTTP $code" "PASS"
            return 0
        fi
        if [ $i -lt $max_retries ]; then
            sleep 2
        fi
    done

    record_test "$test_name" "HTTP $expected_code" "HTTP $code" "FAIL"
    return 1
}

test_http_contains() {
    local url="$1"
    local pattern="$2"
    local test_name="${3:-HTTP content test}"
    local max_retries="${4:-3}"

    log_test "$test_name"

    local response
    local i
    for ((i=1; i<=max_retries; i++)); do
        response=$(curl -s --max-time 10 "$url" 2>/dev/null)
        if echo "$response" | grep -q "$pattern"; then
            record_test "$test_name" "Contains: $pattern" "Found pattern" "PASS"
            return 0
        fi
        if [ $i -lt $max_retries ]; then
            sleep 2
        fi
    done

    record_test "$test_name" "Contains: $pattern" "Pattern not found" "FAIL"
    return 1
}

# ================================================
# Kubernetes Test Functions
# ================================================
test_pods_running() {
    local context="$1"
    local namespace="$2"
    local label="$3"
    local expected_count="${4:-1}"
    local test_name="${5:-Pods running}"

    log_test "$test_name"

    local count
    count=$(kubectl --context "$context" get pods -n "$namespace" -l "$label" \
        --no-headers 2>/dev/null | grep -c "Running" || echo "0")
    # Ensure count is a single integer (remove any whitespace/newlines)
    count=$(echo "$count" | tr -d '[:space:]')
    count=${count:-0}

    if [ "$count" -ge "$expected_count" ]; then
        record_test "$test_name" ">=$expected_count running" "$count running" "PASS"
        return 0
    else
        record_test "$test_name" ">=$expected_count running" "$count running" "FAIL"
        return 1
    fi
}

test_service_exists() {
    local context="$1"
    local namespace="$2"
    local service="$3"
    local test_name="${4:-Service exists}"

    log_test "$test_name"

    if kubectl --context "$context" get svc -n "$namespace" "$service" &>/dev/null; then
        record_test "$test_name" "Service exists" "Found" "PASS"
        return 0
    else
        record_test "$test_name" "Service exists" "Not found" "FAIL"
        return 1
    fi
}
