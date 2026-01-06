# CLAUDE.md - Project Guidelines for Claude Code

## Project Context

This repository contains the **Omni Workshop** - a Solo.io Gloo Platform + Istio Ambient Service Mesh demonstration designed for presales engineering. The workshop consists of:

> **Important**: Check `STATUS.md` for current workshop status, known issues, and last successful test run before starting work.

- **Setup scripts**: Prepare GKE/Kubernetes infrastructure with Gloo Gateway, Gloo Platform, and Istio Ambient
- **Test scripts**: Automated end-to-end testing that validates the entire workshop flow
- **Markdown guide**: Step-by-step instructions (`omni.md`) users follow manually

**Critical Requirement**: Setup scripts, test scripts, and the Markdown guide MUST remain synchronized. Any command in the Markdown guide should be runnable, and the test scripts should execute the same operations.

---

## Working Methodology

### The Plan-Verify-Execute-Evaluate Cycle

When working on any task in this repository, follow this systematic approach:

#### 1. PLAN - Understand Before Acting
- Read relevant existing code before proposing changes
- Identify all files that will be affected
- Check how similar functionality is implemented elsewhere in the codebase
- Document the plan explicitly before executing

#### 2. VERIFY - Validate the Plan
- Cross-reference with existing patterns in `test-lib.sh`
- Ensure the approach maintains idempotency
- Verify the plan doesn't break the checkpoint system
- Check that environment variable conventions are followed

#### 3. EXECUTE - Implement Incrementally
- Make one logical change at a time
- Test each change before proceeding
- Keep changes minimal and focused

#### 4. EVALUATE - Assess Results
- Run the script to verify it works
- Check for edge cases (script restart, missing env vars, etc.)
- Verify logging output is clear and helpful

#### 5. RE-PLAN - Iterate if Needed
- If issues are found, understand the root cause
- Adjust the approach based on learnings
- Document what was learned for future reference

---

## Architecture Overview

The Omni workshop deploys a two-cluster Gloo Platform environment:

| Cluster | Role | Components |
|---------|------|------------|
| CLUSTER1 | Management + Workload | Gloo Gateway v2, Gloo Platform (mgmt server, UI, Jaeger, Prometheus), Istio Ambient, Bookinfo |
| CLUSTER2 | Workload Only | Gloo Agent, Istio Ambient, Bookinfo |

### Key Technologies

| Component | Version | Purpose |
|-----------|---------|---------|
| Gateway API | v1.4.0 | Kubernetes Gateway API CRDs |
| Gloo Gateway | 2.0.1 | North-South ingress, API Gateway |
| Gloo Operator | 0.4.2 | Istio lifecycle management |
| Istio (Solo) | 1.28.1 | Ambient mesh (ztunnel + waypoints) |
| Gloo Platform | 2.11.0 | Multi-cluster management, observability |

---

## File Organization

```
omni/
├── CLAUDE.md              # This file - project guidelines
├── STATUS.md              # Workshop status, issues, test history
├── omni.md                # Main workshop guide (user-facing)
├── env.sh                 # Environment configuration (not tracked)
├── certs/                 # TLS certificates for shared trust
│   ├── cluster1/          # Cluster1 intermediate CA
│   └── cluster2/          # Cluster2 intermediate CA
└── scripts/
    ├── setup.sh           # Full environment setup
    ├── workshop.sh        # Interactive workshop runner
    ├── test-workshop.sh   # End-to-end test automation
    ├── test-lib.sh        # Shared test library functions
    └── cleanup.sh         # GKE cluster deletion
```

### Environment Configuration

The `env.sh` file contains required variables:

```bash
export CLUSTER1=<kubectl-context-1>     # e.g., lutzl-cluster1
export CLUSTER2=<kubectl-context-2>     # e.g., lutzl-cluster2
export GKE_ZONE1=<gke-zone>             # e.g., europe-west3-a
export GKE_ZONE2=<gke-zone>             # e.g., europe-west2-a
export GLOO_GATEWAY_LICENSE_KEY=<key>
export GLOO_MESH_LICENSE_KEY=<key>
export ISTIOCTL=/path/to/istioctl       # Solo distribution
export ISTIO_VERSION=1.28.1
export GLOO_VERSION=2.11.0
```

---

## Workshop Checkpoints

The workshop is organized into setup and demo checkpoints:

### Setup Steps (setup.sh / workshop.sh)

| Checkpoint | Description |
|------------|-------------|
| setup-1 | Install Gateway API CRDs |
| setup-2 | Install Gloo Gateway v2 |
| setup-3 | Create Ingress Gateway |
| setup-4 | Configure Trust (shared root CA) |
| setup-5 | Install Gloo Operator + Istio Ambient |
| setup-6 | Install Gloo Management Plane |
| setup-7 | Register Cluster2 |

### Demo Steps (workshop.sh / test-workshop.sh)

| Checkpoint | Description |
|------------|-------------|
| demo-1 | Onboarding: Deploy Bookinfo, add to mesh |
| demo-2 | mTLS & Cluster Peering |
| demo-3 | Observability (traffic generation) |
| demo-4 | Global Services (multi-cluster failover) |
| demo-5 | Canary Routing & Rate Limiting |

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

#### 3. Idempotency

Every operation MUST be safe to run multiple times:

```bash
# Pattern 1: Check before create
if kubectl --context "$CLUSTER1" get ns bookinfo &>/dev/null; then
    log_info "Namespace already exists, skipping"
else
    kubectl --context "$CLUSTER1" create ns bookinfo
fi

# Pattern 2: Suppress expected errors
kubectl --context "$CLUSTER1" create ns bookinfo 2>/dev/null || true

# Pattern 3: Use apply instead of create
kubectl --context "$CLUSTER1" apply -f manifest.yaml

# Pattern 4: Use --ignore-not-found for deletions
kubectl delete pod "$POD" --ignore-not-found
```

#### 4. Progress Tracking (test-workshop.sh)

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
test_http_endpoint "http://example.com" "200" "Test name" [retries]
test_http_contains "http://example.com" "pattern" "Test name" [retries]

# Pod status tests
test_pods_running "$CLUSTER1" "namespace" "label" [count] "Test name"
test_service_exists "$CLUSTER1" "namespace" "service" "Test name"

# Wait helpers
wait_for_pods "$CLUSTER1" "namespace" "label" [timeout]
wait_for_deployment "$CLUSTER1" "namespace" "deployment" [timeout]
wait_for_loadbalancer "$CLUSTER1" "namespace" "service" [max_attempts]
```

---

## Common Patterns Reference

### Kubernetes Operations

```bash
# Check cluster connectivity
kubectl --context "$CLUSTER1" cluster-info > /dev/null 2>&1

# Wait for deployment rollout
kubectl --context "$CLUSTER1" rollout status deployment/"$NAME" -n "$NS" --timeout=300s

# Wait for pods ready
kubectl --context "$CLUSTER1" wait --for=condition=Ready pod -l "$LABEL" -n "$NS" --timeout=300s

# Get LoadBalancer IP
kubectl get svc -n "$NS" "$SVC" --context "$CLUSTER1" \
    -o jsonpath="{.status.loadBalancer.ingress[0]['hostname','ip']}"
```

### Helm Operations

```bash
# Install with idempotency
helm upgrade --install release-name chart \
    --kube-context "$CLUSTER1" \
    -n namespace \
    --create-namespace \
    --version "$VERSION"
```

### Multi-Cluster Operations

```bash
# Peer clusters with istioctl
$ISTIOCTL --context="$CLUSTER1" multicluster expose -n istio-gateways
$ISTIOCTL multicluster link --contexts="$CLUSTER1,$CLUSTER2" -n istio-gateways

# Check peering status
$ISTIOCTL --context="$CLUSTER1" multicluster check --verbose
```

---

## Documentation Synchronization

### The Three-Way Contract

1. **Markdown Guide** (`omni.md`): User-facing step-by-step instructions
2. **Test Script** (`test-workshop.sh`): Automated validation of the same steps
3. **Workshop Script** (`workshop.sh`): Interactive runner for demos

**Rule**: If you change any command in `omni.md`, update the corresponding function in `test-workshop.sh` and `workshop.sh`. Keep all three in sync.

### Markdown Structure

Follow this pattern in `omni.md`:

~~~markdown
## Part N: Section Title

### Step N.X: Action Description

Brief explanation of what this step accomplishes.

```bash
# Command to run
kubectl --context ${CLUSTER1} apply -f manifest.yaml
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
- **Solo.io docs**: https://docs.solo.io/gloo-mesh-core/main/ambient/
- **Key concepts**: ztunnel (L4 proxy), waypoint proxies (L7), HBONE protocol

### Gloo Gateway v2
- **Docs**: https://docs.solo.io/gateway/latest/
- **Gateway API**: https://gateway-api.sigs.k8s.io/

### Gloo Platform
- **Docs**: https://docs.solo.io/gloo-mesh-enterprise/latest/
- **Multi-cluster**: https://docs.solo.io/gloo-mesh-enterprise/latest/setup/

### GKE / gcloud
- **Docs**: https://cloud.google.com/kubernetes-engine/docs
- **gcloud CLI**: https://cloud.google.com/sdk/gcloud

---

## Anti-Patterns to Avoid

### DO NOT:

1. **Hardcode cluster names** - Always use `$CLUSTER1` and `$CLUSTER2`
2. **Skip existence checks** - Always verify before create/delete
3. **Use silent failures** - Log what's happening
4. **Break the three-way contract** - Keep `omni.md`, `workshop.sh`, and `test-workshop.sh` in sync
5. **Use `set -e` without thought** - It can break step resumption; handle errors explicitly
6. **Assume fresh environment** - Scripts may run on partially-configured systems
7. **Use interactive commands** - No `git rebase -i`, `vim`, etc.
8. **Forget multi-cluster context** - Always specify `--context` for kubectl commands

### DO:

1. **Read existing code first** - Understand patterns before changing
2. **Test incrementally** - Run after each change
3. **Provide context in logs** - Users should understand what's happening
4. **Make cleanup reversible** - Warn before destructive operations
5. **Use both clusters** - Most operations need to run on both CLUSTER1 and CLUSTER2

---

## Debugging Guidelines

When a script fails:

1. Check which step failed in the output
2. Examine environment variables: `echo $CLUSTER1 $CLUSTER2`
3. Verify cluster connectivity: `kubectl --context $CLUSTER1 cluster-info`
4. Check pod status: `kubectl --context $CLUSTER1 get pods -A`
5. Check logs: `kubectl --context $CLUSTER1 logs -n <namespace> -l <label>`
6. For multi-cluster issues: `$ISTIOCTL multicluster check --verbose`

---

## Quality Checklist

Before considering any script change complete:

- [ ] Config file support (`-c`) works
- [ ] Script is idempotent (safe to re-run)
- [ ] Logging is clear and color-coded
- [ ] Error messages are actionable
- [ ] Related `omni.md` documentation is updated
- [ ] `test-workshop.sh` validates the same flow
- [ ] `workshop.sh` includes the same steps
- [ ] Works on both CLUSTER1 and CLUSTER2

---

## Status Tracking (STATUS.md)

The `STATUS.md` file tracks operational status and must be kept current.

### When to Update STATUS.md

1. **After running tests**: Record results in test history, update "Last Successful Test Run" if all passed
2. **When discovering issues**: Add to "Open Issues" with severity, description, workaround
3. **When resolving issues**: Move to "Resolved Issues" with resolution details
4. **When changing versions**: Update the "Current Environment" table

### After a Test Run

```bash
# Run tests
./scripts/test-workshop.sh -c env.sh

# Then update STATUS.md with:
# - Date, tester, cluster names
# - Tests passed/failed count
# - Any new issues discovered
# - Move to "Last Successful Test Run" if ALL tests passed
```

### Issue Tracking Format

```markdown
| ID | Severity | Component | Description | Workaround | Reported |
|----|----------|-----------|-------------|------------|----------|
| OMNI-001 | High | setup.sh | Cluster peering fails on first run | Run peer_clusters step twice | 2026-01-05 |
```

---

## Key Files Reference

| File | Purpose |
|------|---------|
| `STATUS.md` | **CHECK FIRST** - Current status, known issues, test history |
| `scripts/test-lib.sh` | **READ THIS** - All shared functions |
| `env.sh` | Environment configuration (create from template) |
| `omni.md` | User-facing workshop guide |
| `scripts/workshop.sh` | Interactive workshop runner |
| `scripts/test-workshop.sh` | Automated end-to-end tests |
| `scripts/setup.sh` | Full environment setup |
| `scripts/cleanup.sh` | GKE cluster deletion |

---

## Communication Style

When explaining changes or asking questions:

1. Be specific about which files and line numbers
2. Reference existing patterns: "Following the pattern in test-lib.sh:XXX"
3. Explain the "why" not just the "what"
4. Provide complete, runnable examples
5. Note any documentation that needs updating
