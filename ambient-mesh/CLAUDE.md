# CLAUDE.md - Project Guidelines for Claude Code

## Project Context

This repository contains the **Ambient Mesh Workshop** - an Istio Ambient Service Mesh demonstration designed for presales engineering. The workshop demonstrates a single-cluster setup with:

> **Important**: Check `STATUS.md` for current workshop status, known issues, and last successful test run before starting work.

- **Setup guide**: Step-by-step instructions (`setup.md`) for preparing the environment
- **Workshop guide**: Main demo flow (`ambient-mesh.md`) users follow
- **Optional extensions**: Gloo Gateway v2 integration for enterprise features

**Key Design Decisions**:
- **Single cluster** - Simplified for faster demos and easier setup
- **Istio Gateway** for ingress (default) - Standard Kubernetes Gateway API
- **Gloo Gateway v2** (optional) - Enterprise API Gateway features

---

## Architecture Overview

The workshop deploys a single-cluster Istio Ambient environment:

| Component | Purpose |
|-----------|---------|
| Istio Ambient | Service mesh (ztunnel + waypoints) |
| Istio Gateway | North-South ingress (Gateway API) |
| Bookinfo | Sample application |

### Key Technologies

| Component | Version | Purpose |
|-----------|---------|---------|
| Gateway API | v1.4.0 | Kubernetes Gateway API CRDs |
| Istio (Solo) | 1.28.1 | Ambient mesh (ztunnel + waypoints) |

### Optional Components

| Component | Version | Purpose |
|-----------|---------|---------|
| Gloo Gateway | 2.0.1 | Enterprise API Gateway (auth, rate limiting) |

---

## File Organization

```
ambient-mesh/
├── CLAUDE.md              # This file - project guidelines
├── STATUS.md              # Workshop status, issues, test history
├── ambient-mesh.md        # Main workshop guide (user-facing)
├── setup.md               # Manual setup instructions
├── env.sh                 # Environment configuration (not tracked)
└── scripts/
    ├── test-lib.sh        # Shared test library functions
    ├── setup.sh           # Automated environment setup
    ├── workshop.sh        # Interactive workshop runner
    ├── test-workshop.sh   # End-to-end test automation
    └── cleanup.sh         # Cluster cleanup
```

### Environment Configuration

The `env.sh` file contains required variables:

```bash
export CLUSTER=<kubectl-context>        # e.g., my-cluster
export ISTIO_VERSION=1.28.1

# Optional: For Gloo Gateway section
export GLOO_GATEWAY_LICENSE_KEY=<key>

# Optional: For Solo Istio distribution
export GLOO_MESH_LICENSE_KEY=<key>
export ISTIOCTL=/path/to/istioctl       # Solo distribution
```

---

## Workshop Sections

### Core Workshop (ambient-mesh.md)

| Section | Description |
|---------|-------------|
| Setup | Install Gateway API, Istio Ambient, Istio Gateway |
| Part 1 | Onboarding: Deploy Bookinfo, add to mesh |
| Part 2 | Zero-Trust Security: mTLS verification |
| Part 3 | Observability: Metrics and access logs |
| Part 4 | Traffic Management: Waypoints and canary routing |

### Optional Section

| Section | Description |
|---------|-------------|
| Gloo Gateway | Enterprise API Gateway with rate limiting |

---

## Workshop Checkpoints

The workshop is organized into setup and demo checkpoints:

### Setup Steps (setup.sh)

| Checkpoint | Description |
|------------|-------------|
| setup-1 | Install Gateway API CRDs |
| setup-2 | Install Istio Ambient (base, istiod, cni, ztunnel) |
| setup-3 | Install Istio Gateway |
| setup-4 | Deploy Bookinfo application |

### Demo Steps (test-workshop.sh)

| Checkpoint | Description |
|------------|-------------|
| demo-1 | Add Bookinfo to mesh |
| demo-2 | Verify mTLS encryption |
| demo-3 | Observability (traffic generation) |
| demo-4 | Deploy waypoint proxy |
| demo-5 | Configure canary routing |

---

## Script Standards

### Required Script Features

#### 1. Configuration Support (`-c` option)

```bash
CONFIG_FILE=""

while [[ $# -gt 0 ]]; do
    case $1 in
        -c|--config)
            CONFIG_FILE="$2"
            shift 2
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

if [[ -n "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
fi
```

#### 2. Consistent Logging

Use the logging functions from `test-lib.sh`:

```bash
log_info "Informational message"      # Blue [INFO]
log_success "Success message"         # Green [SUCCESS]
log_step "Starting step X"            # Yellow with ==> prefix
log_warn "Warning message"            # Yellow [WARN]
log_error "Error message"             # Red [ERROR]
log_test "Running test Y"             # Blue [TEST]
log_pass "Test passed"                # Green [PASS]
log_fail "Test failed"                # Red [FAIL]
```

#### 3. Progress Tracking (test-workshop.sh)

The test script tracks progress using `test-lib.sh` functions:

```bash
source "$SCRIPT_DIR/test-lib.sh"

# Load previous progress
load_progress

# Run a step with tracking
run_step "step_name" do_step_function

# Mark step complete
mark_step_complete "step_name"
```

### Idempotency

Every operation MUST be safe to run multiple times:

```bash
# Pattern 1: Check before create
if kubectl get ns bookinfo &>/dev/null; then
    echo "Namespace already exists, skipping"
else
    kubectl create ns bookinfo
fi

# Pattern 2: Suppress expected errors
kubectl create ns bookinfo 2>/dev/null || true

# Pattern 3: Use apply instead of create
kubectl apply -f manifest.yaml

# Pattern 4: Use --ignore-not-found for deletions
kubectl delete pod "$POD" --ignore-not-found
```

---

## Test Framework Usage

### Recording Test Results

```bash
# In test functions, use record_test()
test_connectivity() {
    local code=$(curl -s -o /dev/null -w "%{http_code}" "$URL")

    if [ "$code" = "200" ]; then
        record_test "Connectivity Test" "HTTP 200" "HTTP $code" "PASS"
    else
        record_test "Connectivity Test" "HTTP 200" "HTTP $code" "FAIL"
    fi
}
```

### Test Summary

Always call `print_test_summary` at the end:

```bash
run_verification_tests
print_test_summary
exit $?
```

### Available Test Helpers

```bash
# HTTP endpoint tests
test_http_endpoint "$URL" "200" "Test name" [retries]
test_http_contains "$URL" "pattern" "Test name" [retries]

# Pod status tests
test_pods_running "namespace" "label" [count] "Test name"
test_service_exists "namespace" "service" "Test name"

# Wait helpers
wait_for_pods "namespace" "label" [timeout]
wait_for_deployment "namespace" "deployment" [timeout]
wait_for_loadbalancer "namespace" "service" [max_attempts]
```

---

## Common Patterns Reference

### Kubernetes Operations

```bash
# Check cluster connectivity
kubectl cluster-info > /dev/null 2>&1

# Wait for deployment rollout
kubectl rollout status deployment/"$NAME" -n "$NS" --timeout=300s

# Wait for pods ready
kubectl wait --for=condition=Ready pod -l "$LABEL" -n "$NS" --timeout=300s

# Get LoadBalancer IP
kubectl get svc -n "$NS" "$SVC" \
    -o jsonpath="{.status.loadBalancer.ingress[0]['hostname','ip']}"
```

### Helm Operations

```bash
# Install with idempotency
helm upgrade --install release-name chart \
    -n namespace \
    --create-namespace \
    --version "$VERSION"
```

---

## Documentation Synchronization

### The Three-Way Contract

1. **Workshop Guide** (`ambient-mesh.md`): User-facing step-by-step instructions
2. **Test Script** (`test-workshop.sh`): Automated validation of the same steps
3. **Workshop Script** (`workshop.sh`): Interactive runner for demos

**Rule**: If you change any command in `ambient-mesh.md`, update the corresponding function in `test-workshop.sh` and `workshop.sh`. Keep all three in sync.

### Markdown Structure

Follow this pattern:

~~~markdown
## Part N: Section Title

### Step N.X: Action Description

Brief explanation of what this step accomplishes.

```bash
# Command to run
kubectl apply -f manifest.yaml
```

Expected output or verification:
```
expected output here
```
~~~

---

## Software Version Documentation

When working with these technologies, reference the correct documentation:

### Istio Ambient Mode
- **Primary docs**: https://istio.io/latest/docs/ambient/
- **Key concepts**: ztunnel (L4 proxy), waypoint proxies (L7), HBONE protocol

### Kubernetes Gateway API
- **Docs**: https://gateway-api.sigs.k8s.io/

### Gloo Gateway v2 (Optional)
- **Docs**: https://docs.solo.io/gateway/latest/

---

## Anti-Patterns to Avoid

### DO NOT:

1. **Hardcode cluster names** - Always use `$CLUSTER` variable
2. **Skip existence checks** - Always verify before create/delete
3. **Use silent failures** - Log what's happening
4. **Use `set -e` without thought** - Handle errors explicitly
5. **Assume fresh environment** - Scripts may run on partially-configured systems
6. **Use interactive commands** - No `git rebase -i`, `vim`, etc.

### DO:

1. **Read existing code first** - Understand patterns before changing
2. **Test incrementally** - Run after each change
3. **Provide context in logs** - Users should understand what's happening
4. **Make cleanup reversible** - Warn before destructive operations

---

## Debugging Guidelines

When something fails:

1. Check which step failed in the output
2. Examine environment variables: `echo $CLUSTER`
3. Verify cluster connectivity: `kubectl cluster-info`
4. Check pod status: `kubectl get pods -A`
5. Check logs: `kubectl logs -n <namespace> -l <label>`

---

## Quality Checklist

Before considering any change complete:

- [ ] Script is idempotent (safe to re-run)
- [ ] Logging is clear
- [ ] Error messages are actionable
- [ ] Related documentation is updated
- [ ] Works with different cluster names

---

## Status Tracking (STATUS.md)

The `STATUS.md` file tracks operational status and must be kept current.

### When to Update STATUS.md

1. **After running tests**: Record results in test history
2. **When discovering issues**: Add to "Open Issues" with severity, description, workaround
3. **When resolving issues**: Move to "Resolved Issues" with resolution details
4. **When changing versions**: Update the "Current Environment" table

---

## Key Files Reference

| File | Purpose |
|------|---------|
| `STATUS.md` | **CHECK FIRST** - Current status, known issues, test history |
| `scripts/test-lib.sh` | **READ THIS** - All shared test functions |
| `env.sh` | Environment configuration (create from template) |
| `ambient-mesh.md` | User-facing workshop guide |
| `setup.md` | Detailed manual setup instructions |
| `scripts/workshop.sh` | Interactive workshop runner |
| `scripts/test-workshop.sh` | Automated end-to-end tests |
| `scripts/setup.sh` | Full environment setup |
| `scripts/cleanup.sh` | Cluster cleanup |

---

## Communication Style

When explaining changes or asking questions:

1. Be specific about which files and line numbers
2. Explain the "why" not just the "what"
3. Provide complete, runnable examples
4. Note any documentation that needs updating
