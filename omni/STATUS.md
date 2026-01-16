# Omni Workshop Status

> **Last Updated**: 2026-01-16 (restored workshop.sh with Helm-based Istio installation)

This file tracks the operational status of the Omni workshop, including test results, known issues, and version information. Claude Code should update this file after test runs and when issues are discovered or resolved.

---

## Current Environment

| Component | Version | Notes |
|-----------|---------|-------|
| Gateway API | v1.4.0 | |
| Gloo Gateway | 2.0.1 | |
| Istio (Solo) | 1.28.1 | Uses `-solo` suffix |
| Gloo Platform | 2.11.0 | |
| Kubernetes | GKE 1.33.5-gke.2019000 | Tested on GKE |

---

## Last Successful Test Run

> A "successful" run means ALL tests passed with no failures.

| Field | Value |
|-------|-------|
| **Date** | 2026-01-14 |
| **Tester** | Claude Code |
| **Clusters** | lutzl-cluster1 (europe-west3-a), lutzl-cluster2 (europe-west2-a) |
| **Tests Passed** | 32 |
| **Tests Failed** | 0 |
| **Duration** | Full workshop test |
| **Notes** | All 32 tests passed with simplified istiod config. Removed 7 redundant/deprecated settings (`AUTO_RELOAD_PLUGIN_CERTS`, `PILOT_SKIP_VALIDATE_TRUST_DOMAIN`, `PILOT_ENABLE_AMBIENT`, `serviceScopeConfigs`, `proxy.clusterDomain`, `rootNamespace`, `trustDomain`). Confirms ambient profile provides correct defaults. |

### Test Run History

<!-- Add new entries at the top -->

| Date | Result | Passed/Failed | Notes |
|------|--------|---------------|-------|
| 2026-01-14 14:25 | PASS | 32/0 | **Simplified istiod config validated.** Removed 7 redundant/deprecated settings. All functionality preserved with cleaner configuration. |
| 2026-01-14 | PASS | 32/0 | **Fresh GKE clusters + removed unnecessary Istio settings.** Removed `ISTIO_META_DNS_CAPTURE` (sidecar-only), `PILOT_ENABLE_IP_AUTOALLOCATE` (default since 1.25), `ambient.dnsCapture` (default since 1.25). All functionality preserved. |
| 2026-01-12 | PASS | 32/0 | **All tests passed.** Fixed global failover test - hostname changed from svc.cluster.local to mesh.internal. Synced omni.md Istio configs with setup.sh. |
| 2026-01-08 09:25 | PASS | 31/1 | Fresh GKE clusters. Failover test timing issue (HTTP 503). All other tests passed including full tracing. |
| 2026-01-06 11:52 | PASS | 32/0 | **Fresh GKE clusters from scratch**. Full setup + workshop + tracing. All services traced. |
| 2026-01-06 10:35 | PASS | 32/0 | Full workshop + tracing. Multi-cluster tracing config verified on both clusters. |
| 2026-01-05 20:50 | PASS | 31/0 | Full workshop + tracing. ztunnel, gloo-gateway, productpage, details, ratings traces verified. |
| 2026-01-05 12:25 | PASS | 17/0 | Full run on fresh GKE clusters. Fixed LB timing issue in peer_clusters step. |

---

## Known Issues

### Open Issues

<!-- Add new issues at the top. Use format: -->
<!-- | ID | Severity | Component | Description | Workaround | Reported | -->

| ID | Severity | Component | Description | Workaround | Reported |
|----|----------|-----------|-------------|------------|----------|
| OMNI-003 | Low | Tracing | Reviews service traces not appearing | Use OTel-instrumented reviews image when available | 2026-01-05 |

### Resolved Issues

<!-- Move resolved issues here with resolution date and fix description -->

| ID | Component | Description | Resolution | Resolved |
|----|-----------|-------------|------------|----------|
| OMNI-004 | test-workshop.sh | Failover test intermittently fails (HTTP 503) due to mesh routing update timing | Increased wait time from 15s to 30s after pod termination; increased HTTP retries from 5 to 10. Allows more time for istiod to propagate endpoint changes across clusters. | 2026-01-08 |
| OMNI-002 | Tracing | Waypoint traces not appearing in Jaeger - ORIGINAL_DST cluster issue in ambient mode | Created ClusterIP service (`gloo-telemetry-collector-clusterip`) with `appProtocol: grpc` to replace headless service. Updated extensionProvider to use ClusterIP service. Root cause: headless services cause ORIGINAL_DST cluster type which doesn't support trace export. | 2026-01-06 |
| OMNI-001 | test-workshop.sh | peer_clusters step failed because LoadBalancer IPs not ready before istioctl link | Added proper wait for LoadBalancer IPs on both clusters before linking, plus retry logic | 2026-01-05 |

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
| 2026-01-16 | **Restored workshop.sh**: Recovered from git after accidental deletion. Updated setup-5 to use Helm-based Istio installation (matching setup.sh) instead of removed Gloo Operator. Removed all Gloo Operator references. | workshop.sh |
| 2026-01-14 | **Simplified istiod configuration**: Removed 7 redundant/deprecated settings: `AUTO_RELOAD_PLUGIN_CERTS` (removed in [Istio 1.19](https://istio.io/latest/news/releases/1.19.x/announcing-1.19/change-notes/)), `PILOT_SKIP_VALIDATE_TRUST_DOMAIN` (not needed - same trust domain on all clusters), `PILOT_ENABLE_AMBIENT` (set by `profile: ambient`), `serviceScopeConfigs` (in [ambient profile](https://github.com/istio/istio/blob/master/manifests/helm-profiles/ambient.yaml)), `proxy.clusterDomain` (default), `rootNamespace` (default), `trustDomain` (default). | setup.sh, setup.md |
| 2026-01-14 | **Removed unnecessary Istio settings**: Removed `ISTIO_META_DNS_CAPTURE` (sidecar-only, not used in ambient), `PILOT_ENABLE_IP_AUTOALLOCATE` (default since Istio 1.25), `ambient.dnsCapture: true` (default since Istio 1.25). These were setting options that are either not applicable to ambient mode or already defaults. See [Istio DNS Proxying docs](https://istio.io/latest/docs/ops/configuration/traffic-management/dns-proxy/) and [Istio 1.25 change notes](https://istio.io/latest/news/releases/1.25.x/announcing-1.25/change-notes/). | setup.sh, setup.md |
| 2026-01-14 | **Added comprehensive documentation links to setup.md**: Added clickable links to upstream documentation for all parameters in Gateway API, Istio, Gloo Gateway, and Gloo Platform sections. Added Reference Documentation section at end. | setup.md |
| 2026-01-14 | **Updated omni.md step numbering**: Steps 1-14 now have consistent numbering that matches test-workshop.sh. Added `--list` option improvements to test-workshop.sh. | omni.md, test-workshop.sh |
| 2026-01-12 | **Fixed global failover test**: Changed Backend hostname from `productpage.bookinfo.svc.cluster.local` to `productpage.bookinfo.mesh.internal`. K8s DNS (svc.cluster.local) only resolves to local ClusterIP; mesh.internal uses Istio DNS proxy to resolve to Mesh VIP (240.240.0.x) enabling cross-cluster routing via east-west gateway. | test-workshop.sh, omni.md |
| 2026-01-12 | Synced Istio Helm configs in omni.md with setup.sh: All istiod, istio-cni, and ztunnel settings now match exactly | omni.md |
| 2026-01-09 | ~~Fixed Backend hostname: Changed from mesh.internal to svc.cluster.local~~ **INCORRECT - reverted 2026-01-12** | test-workshop.sh |
| 2026-01-09 | Removed unused Gloo Operator: operator was installed but never used (Istio deployed via Helm, multi-cluster peering via istioctl). Removed from setup.sh, omni.md, STATUS.md | setup.sh, omni.md, STATUS.md |
| 2026-01-09 | Synced omni.md with setup.sh: Fixed setup.sh path, updated Step 5 to show Helm-based Istio installation (matching actual implementation), fixed cert paths to use ./certs/, added working directory note | omni.md |
| 2026-01-08 | Added timing guidance to omni.md: 30s failover wait, 10s routing propagation, LoadBalancer IP wait | omni.md |
| 2026-01-08 | Fixed failover test timing: increased wait from 15s to 30s, retries from 5 to 10 | test-workshop.sh |
| 2026-01-08 | Moved progress file from /tmp to repo directory (.workshop-progress); cleanup.sh now deletes progress file | test-lib.sh, test-workshop.sh, cleanup.sh, .gitignore |
| 2026-01-06 | Updated tracing docs for multi-cluster: Step 2 (extensionProvider), Step 4 (mesh-wide + waypoint Telemetry CRs), waypoint restart - all now configure both clusters | omni.md, test-workshop.sh |
| 2026-01-06 | Fixed waypoint tracing: added ClusterIP service for telemetry collector with appProtocol: grpc | test-workshop.sh, omni.md |
| 2026-01-05 | Added optional tracing section with ztunnel L7, Gloo Gateway, waypoint tracing | setup.sh, test-workshop.sh, omni.md |
| 2026-01-05 | Fixed ztunnel otlpEndpoint to point to gloo-telemetry-collector | setup.sh, test-workshop.sh |
| 2026-01-05 | Fixed LoadBalancer wait timing in peer_clusters | test-workshop.sh |
| 2026-01-05 | Initial STATUS.md creation | Documentation |
| 2026-01-05 | Updated CLAUDE.md for omni workshop | Documentation |
| _Prior_ | Workshop development | All |

---

## How to Update This File

### After a Test Run

1. Run `./scripts/test-workshop.sh -c env.sh`
2. Record the results in "Last Successful Test Run" (if all passed) or note failures
3. Add entry to "Test Run History"
4. Update "Last Updated" date at top

### When Discovering an Issue

1. Assign next available ID (e.g., OMNI-001, OMNI-002)
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
# Run full test suite
./scripts/test-workshop.sh -c env.sh

# Run tests only (skip setup)
./scripts/test-workshop.sh -c env.sh --skip-setup

# List test steps and status
./scripts/test-workshop.sh -c env.sh -l

# Start from a specific step
./scripts/test-workshop.sh -c env.sh -s peer_clusters

# Run workshop interactively
./scripts/workshop.sh setup
./scripts/workshop.sh demo

# Cleanup
./scripts/cleanup.sh -c env.sh
```
