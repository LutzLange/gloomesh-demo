# Ambient Mesh Workshop Status

> **Last Updated**: 2026-01-22

This file tracks the operational status of the Ambient Mesh workshop, including test results, known issues, and version information.

---

## Current Environment

| Component | Version | Notes |
|-----------|---------|-------|
| Gateway API | v1.4.0 | |
| Istio (Solo) | 1.28.1 | Uses `-solo` suffix |
| Gloo Platform | 2.11.0 | Management UI, Jaeger, Prometheus |
| Kubernetes | 1.33.5-gke | Tested on GKE |

### Optional Components

| Component | Version | Notes |
|-----------|---------|-------|
| Gloo Gateway | 2.0.1 | Enterprise API Gateway |

---

## Last Successful Test Run

> A "successful" run means ALL steps completed with no failures.

| Field | Value |
|-------|-------|
| **Date** | 2026-01-22 |
| **Tester** | Claude Code |
| **Cluster** | ambient-demo (GKE europe-west3-a) |
| **Tests** | 13/13 passed |
| **Notes** | Full end-to-end validation after version-specific services fix |

### Test Run History

<!-- Add new entries at the top -->

| Date | Result | Notes |
|------|--------|-------|
| 2026-01-22 | 13/13 PASS | Initial test run. Fixed version-specific services (reviews-v1/v2/v3) for canary routing and traffic shifting. |

---

## Known Issues

### Open Issues

<!-- Add new issues at the top. Use format: -->
<!-- | ID | Severity | Component | Description | Workaround | Reported | -->

| ID | Severity | Component | Description | Workaround | Reported |
|----|----------|-----------|-------------|------------|----------|
| - | - | - | No known issues yet | - | - |

### Resolved Issues

<!-- Move resolved issues here with resolution date and fix description -->

| ID | Component | Description | Resolution | Resolved |
|----|-----------|-------------|------------|----------|
| AMB-001 | waypoint routing | Canary routing and traffic shifting failed because version-specific services (reviews-v1/v2/v3) were missing. Default Bookinfo only has one "reviews" service. | Added creation of reviews-v1, reviews-v2, reviews-v3 services in waypoint deployment step. | 2026-01-22 |

---

## Issue Severity Levels

| Level | Description |
|-------|-------------|
| **Critical** | Blocks workshop completely, no workaround |
| **High** | Major functionality broken, workaround exists |
| **Medium** | Feature degraded but workshop can continue |
| **Low** | Minor issue, cosmetic, or edge case |

---

## Version History

<!-- Track significant changes to the workshop -->

| Date | Change | Components Affected |
|------|--------|---------------------|
| 2026-01-22 | **Distributed Tracing**: Added optional tracing configuration (step 9). Configures ztunnel, waypoint, and mesh-wide tracing via Gloo telemetry collector and Jaeger. Run by test scripts by default. | test-workshop.sh, workshop.sh, ambient-mesh.md |
| 2026-01-22 | **Gloo Platform UI**: Added Gloo Platform (Management UI) installation as setup step 5. Includes Jaeger tracing, Prometheus metrics, and Insights Engine. | setup.sh, setup.md, ambient-mesh.md, env.sh |
| 2026-01-22 | **Version-specific services fix**: Added reviews-v1/v2/v3 services for canary routing and traffic shifting. Fixed Gateway IP detection to use Gateway resource status. | workshop.sh, test-workshop.sh, ambient-mesh.md |
| 2026-01-22 | **Step tracking system**: Added `--step`, `--list`, `--reset` options. Added `--create-cluster` and `--delete-cluster` flags. | setup.sh, workshop.sh, test-workshop.sh, cleanup.sh |
| 2026-01-22 | **Initial workshop creation**: Simplified single-cluster Istio Ambient workshop. Istio Gateway for default ingress, Gloo Gateway moved to optional section. | All |

---

## How to Update This File

### After a Test Run

1. Run through the workshop steps
2. Record the results in "Last Successful Test Run" (if all steps passed)
3. Add entry to "Test Run History"
4. Update "Last Updated" date at top

### When Discovering an Issue

1. Assign next available ID (e.g., AMB-001, AMB-002)
2. Add to "Open Issues" table with severity, component, description
3. Note any workaround
4. Update "Last Updated" date

### When Resolving an Issue

1. Move issue from "Open Issues" to "Resolved Issues"
2. Add resolution description and date
3. Update "Last Updated" date

---

## Quick Commands

```bash
# Source environment
source env.sh

# Verify cluster connectivity
kubectl cluster-info

# Check Istio components
kubectl get pods -n istio-system

# Check GatewayClasses available
kubectl get gatewayclasses

# Get Istio Gateway IP (from Gateway resource status)
kubectl get gateway -n istio-ingress istio-ingressgateway -o jsonpath='{.status.addresses[0].value}'

# Fallback: Get IP from service
kubectl get svc -n istio-ingress istio-ingress -o jsonpath="{.status.loadBalancer.ingress[0]['hostname','ip']}"
```

---

## Script Commands

```bash
# Run full automated setup
./scripts/setup.sh -c env.sh

# Run interactive workshop demo
./scripts/workshop.sh -c env.sh

# Run automated end-to-end tests
./scripts/test-workshop.sh -c env.sh

# Run from specific step (after previous run)
./scripts/test-workshop.sh -c env.sh -r

# Cleanup cluster resources
./scripts/cleanup.sh -c env.sh

# Cleanup without confirmation prompt
./scripts/cleanup.sh -c env.sh -y
```

### Script Options

| Script | Options | Description |
|--------|---------|-------------|
| `setup.sh` | `-c FILE` | Load config from FILE |
| | `-p PLATFORM` | Platform: gke, eks, aks, kind (default: gke) |
| | `--create-cluster` | Create GKE cluster if it doesn't exist |
| | `-h` | Show help |
| `workshop.sh` | `-c FILE` | Load config from FILE |
| | `--step N` | Start from step N (1-9) |
| | `--list, -l` | List all steps |
| | `-h` | Show help |
| `test-workshop.sh` | `-c FILE` | Load config from FILE |
| | `-r, --resume` | Resume from last completed step |
| | `--reset` | Reset progress and start from beginning |
| | `-h` | Show help |
| `cleanup.sh` | `-c FILE` | Load config from FILE |
| | `--full` | Full cleanup including Istio and Gateway API |
| | `--delete-cluster` | Delete GKE cluster (requires CLUSTER, GKE_ZONE) |
| | `-y, --yes` | Skip confirmation prompt |
| | `-h` | Show help |
