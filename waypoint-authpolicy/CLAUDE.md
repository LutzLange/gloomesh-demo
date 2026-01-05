# CLAUDE.md - Multi-Tenant AuthorizationPolicy Test

## Problem Statement

This project tests **AuthorizationPolicy enforcement** at waypoint proxies in a multi-tenant Istio Ambient mesh setup.

### The Multi-Tenant Challenge

```
┌─────────────────────────────────────────────────────────────────────┐
│                         Platform Team Managed                        │
│  ┌─────────────────────────────────────────────────────────────┐    │
│  │  tenant-a-baseline namespace                                 │    │
│  │  ┌─────────────┐                                            │    │
│  │  │  waypoint   │  ◄── AuthorizationPolicy needed here       │    │
│  │  │   proxy     │      to allow traffic to tenant services   │    │
│  │  └─────────────┘                                            │    │
│  └─────────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────┐
│                         Tenant Self-Service                          │
│  ┌────────────────────┐  ┌────────────────────┐  ┌──────────────┐   │
│  │  tenant-a-ns1      │  │  tenant-a-ns2      │  │ tenant-a-*   │   │
│  │  ┌──────────┐      │  │  ┌──────────┐      │  │ (future ns)  │   │
│  │  │ httpbin  │      │  │  │ app-xyz  │      │  │              │   │
│  │  └──────────┘      │  │  └──────────┘      │  │              │   │
│  │  + own AuthzPolicy │  │  + own AuthzPolicy │  │              │   │
│  └────────────────────┘  └────────────────────┘  └──────────────┘   │
└─────────────────────────────────────────────────────────────────────┘
```

### Key Questions (Answered)

1. ✅ **Tenant self-service**: Can tenants define their own AuthorizationPolicies without platform team involvement?
   - **YES** - Tenants create policies in their namespaces with `targetRefs` to Service. Policies auto-attach to the cross-namespace waypoint.

2. ✅ **Cross-namespace waypoint**: How do policies work when the waypoint is in a different namespace than the workloads?
   - Policies in workload namespaces with `targetRefs` to Service automatically bind to the waypoint. Confirmed by status: `bound to tenant-a-baseline/waypoint`.

3. ❌ **Namespace wildcards**: Can we create a policy in `tenant-a-baseline` that covers ALL `tenant-a-*` namespaces (including future ones)?
   - **NO** - Wildcards are NOT supported in `source.namespaces`. Each namespace must be listed explicitly. Use Option B (tenant self-service) instead.

4. ✅ **Ingress path**: How does traffic from Gloo Gateway flow through the waypoint, and what policies are needed?
   - Gloo Gateway must route via Service VIP (not pod IP) for RBAC enforcement. Use static Backend. Ingress SA is `cluster.local/ns/gloo-system/sa/http`.

### Current Architecture

```
Traffic Flows:

  [Gloo Gateway]──────┐
  (gloo-system)       │
                      ▼
              ┌───────────────┐
              │   waypoint    │ tenant-a-baseline
              │ (L7 policies) │
              └───────┬───────┘
                      │
         ┌────────────┼────────────┐
         ▼            ▼            ▼
    ┌─────────┐  ┌─────────┐  ┌─────────┐
    │ httpbin │  │  app2   │  │  app3   │
    └─────────┘  └─────────┘  └─────────┘
    tenant-a-ns1  tenant-a-ns2  tenant-a-ns3

  [sleep pod]
  (tenant-b-ns1) ─── cross-tenant test traffic
```

---

## Project Structure

```
waypoint-authpolicy/
├── CLAUDE.md                    # This file - project context and guidelines
├── env.sh                       # Configuration (cluster context, Istio version)
├── docs/
│   └── tenant-self-service-authz-validated.md  # Validated tenant self-service approaches
└── scripts/
    ├── setup.sh                 # Setup infrastructure + run tests
    └── test-option-b.sh         # Test tenant self-service AuthorizationPolicy
```

### Configuration (env.sh)

Required variables:
```bash
export CLUSTER1="your-kube-context"           # Kubernetes context
export HUB="us-docker.pkg.dev/gloo-mesh/..."  # Solo.io Istio registry
export ISTIO_TAG="1.28.1"                     # Istio version

# These are prompted or must be set externally:
# GLOO_GATEWAY_LICENSE_KEY
# GLOO_MESH_LICENSE_KEY
```

---

## Running the Tests

```bash
# Full setup + tests
./scripts/setup.sh -c env.sh

# List steps and their status
./scripts/setup.sh -c env.sh -l

# Start from specific step
./scripts/setup.sh -c env.sh -s deploy_waypoint

# Run tests only (infrastructure already exists)
./scripts/setup.sh -c env.sh --tests-only

# Cleanup test namespaces
./scripts/setup.sh -c env.sh --cleanup
```

---

## Test Scenarios

The script tests these AuthorizationPolicy scenarios:

| Test | Policy State | Expected Result | HTTP Status |
|------|--------------|-----------------|-------------|
| 1. No policy | Permissive default | All traffic ALLOWED | 200 |
| 2. DENY-all | Explicit deny | All traffic BLOCKED | 403 |
| 3. ALLOW specific SA | Allow tenant-b-ns1/sleep | Service-to-service works, ingress blocked | 200 / 403 |
| 4. ALLOW with ingress | Add gloo-proxy-http | Both paths work | 200 |
| 5. Wrong SA | Different service account | DENIED | 403 |
| 6. Correct SA | Original sleep SA | Still works | 200 |

---

## Wildcard Matching Rules (IMPORTANT)

**⚠️ CRITICAL**: Namespace wildcards (like `tenant-a-*`) are **NOT supported** in `source.namespaces`. Each namespace must be listed explicitly.

Per [Istio AuthorizationPolicy Reference](https://istio.io/latest/docs/reference/config/security/authorization-policy/):

| Field | Wildcard Support | Notes |
|-------|------------------|-------|
| `source.namespaces` | ❌ **NO** | Must list each namespace explicitly |
| `source.serviceAccounts` | ❌ **NO** | "No form of wildcard (*) is allowed" |
| `source.principals` | ⚠️ Limited | Prefix match works, but can't wildcard SA part |
| `to.operation.paths` | ✅ YES | Prefix/suffix/presence match |
| `to.operation.methods` | ✅ YES | Prefix/suffix/presence match |

Wildcards (`abc*`, `*abc`, `*`) apply to **operation fields** (paths, methods, hosts), NOT source identity fields.

### Correct Approach: Explicit Namespace List

```yaml
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: allow-tenant-namespaces
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
        namespaces:
        - "tenant-a-ns1"   # Must list each explicitly
        - "tenant-a-ns2"
        - "tenant-a-ns3"
```

---

## ✅ Validated: Tenant Self-Service AuthorizationPolicy (Option B)

**Key Answer**: Yes, tenants CAN define their own AuthorizationPolicies without platform team involvement!

### How It Works

Tenants create policies in their namespaces with `targetRefs` pointing to their Services. Istio automatically attaches these policies to the cross-namespace waypoint.

```yaml
# Tenant creates this in tenant-a-ns1 (their namespace)
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: httpbin-allow
  namespace: tenant-a-ns1      # Tenant's namespace (NOT waypoint namespace)
spec:
  targetRefs:
  - kind: Service
    group: ""
    name: httpbin              # Tenant's service
  action: ALLOW
  rules:
  - from:
    - source:
        namespaces:
        - "tenant-a-ns1"       # Same namespace
        - "tenant-a-ns2"       # Another tenant namespace
  - from:
    - source:
        principals:
        - "cluster.local/ns/gloo-system/sa/http"  # Ingress
```

### Verification

Policy status shows attachment to the waypoint:
```yaml
status:
  conditions:
  - message: bound to tenant-a-baseline/waypoint
    reason: Accepted
    status: "True"
    type: WaypointAccepted
```

### Test Results (All 13 Tests Passed)

Run the validation script:
```bash
./scripts/test-option-b.sh -c env.sh
```

| Scenario | Expected | Result |
|----------|----------|--------|
| Policy binds to cross-namespace waypoint | Bound | ✅ |
| Allowed sources (intra-tenant) | 200 | ✅ |
| Allowed sources (ingress) | 200 | ✅ |
| Denied sources (implicit deny) | 403 | ✅ |
| DENY policy takes precedence | 403 | ✅ |
| Independent policies per service | Works | ✅ |

See `docs/tenant-self-service-authz-validated.md` for detailed analysis.

---

## Critical Finding: Gloo Gateway EDS vs Service VIP Routing

### The Problem

When Gloo Gateway routes traffic to backend services, it uses **Endpoint Discovery Service (EDS)** by default, which routes directly to **pod IPs** rather than the Kubernetes **Service VIP** (ClusterIP).

This creates a critical issue with AuthorizationPolicy enforcement in Istio Ambient:

```
┌─────────────────────────────────────────────────────────────────────┐
│                    DEFAULT (BROKEN) PATH                            │
├─────────────────────────────────────────────────────────────────────┤
│  Gloo Gateway → routes to Pod IP (10.32.1.18:80)                   │
│       ↓                                                             │
│  ztunnel → forwards to waypoint                                     │
│       ↓                                                             │
│  waypoint → destination = Pod IP → matches "direct-http" chain     │
│       ↓                                                             │
│  ❌ NO RBAC FILTER in direct-http chain!                           │
│       ↓                                                             │
│  httpbin pod (traffic allowed regardless of policy)                 │
└─────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────┐
│                    FIXED PATH (via Static Backend)                  │
├─────────────────────────────────────────────────────────────────────┤
│  Gloo Gateway → routes to Service VIP (34.118.238.241:8000)        │
│       ↓                                                             │
│  ztunnel → forwards to waypoint                                     │
│       ↓                                                             │
│  waypoint → destination = VIP → matches "inbound-vip" chain        │
│       ↓                                                             │
│  ✅ RBAC FILTER enforces AuthorizationPolicy!                      │
│       ↓                                                             │
│  httpbin pod (traffic subject to policy)                            │
└─────────────────────────────────────────────────────────────────────┘
```

### The Solution: Static Backend

Create a static Backend that routes through the Service DNS (resolves to VIP):

```yaml
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
---
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
  - backendRefs:
    - name: httpbin-vip
      kind: Backend
      group: gateway.kgateway.dev
```

### Gloo Gateway Service Account

The Gloo Gateway proxy uses the service account name derived from the Gateway resource name.
For a Gateway named `http`, the service account is `http` in `gloo-system` namespace.

```yaml
# AuthorizationPolicy to allow Gloo Gateway ingress
principals:
- cluster.local/ns/gloo-system/sa/http  # NOT gloo-proxy-http
```

### Related Issues

- [Istio #56505](https://github.com/istio/istio/issues/56505): AuthorizationPolicy scoping for waypoint-captured workload traffic
- [Istio #43576](https://github.com/istio/istio/issues/43576): AuthorizationPolicy not enforced with waypoint (original EDS issue)

---

## Anti-Patterns to Avoid

1. **Double wildcards don't work**: `cluster.local/ns/*/sa/*` is NOT supported. Use the `namespaces` field for namespace matching, not embedded wildcards in `principals`.

2. **Service accounts don't allow wildcards**: The `serviceAccounts` field requires exact matches.

3. **Don't use workloadSelector**: Use `targetRefs` instead - it's the recommended approach for attaching policies to specific services.

4. **Principals with double wildcards**: You CAN use `cluster.local/ns/tenant-a-*` (single prefix), but NOT `cluster.local/ns/tenant-a-*/sa/specific-sa` (double wildcard).

---

## Script Architecture

### Step System

The script uses a checkpoint system for resumability:

```bash
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
```

Progress is saved to `/tmp/setup-progress-<config>` and can be:
- Listed: `-l`
- Reset: `--reset`
- Resumed from: `-s <step>`

### Idempotency Patterns

```bash
# Create namespace if not exists
kubectl create ns "$NS" 2>/dev/null || true

# Delete with ignore
kubectl delete authorizationpolicy --all -n "$NS" 2>/dev/null || true

# Check before create
if kubectl get deployment/$NAME -n $NS &>/dev/null; then
    log_info "Already exists, skipping"
fi
```

### Logging

```bash
log_info "Informational message"      # Blue [INFO]
log_step "Starting step X"            # Green/Yellow banner
log_pass "Test passed"                # Green [PASS]
log_fail "Test failed"                # Red [FAIL]
log_error "Error message"             # Red [ERROR]
```

---

## Software Versions

This setup was tested with the following software versions:

| Component | Version | Notes |
|-----------|---------|-------|
| **Kubernetes** | v1.33.5-gke.1308000 | GKE cluster |
| **Istio** | 1.28.1 | Solo.io distribution (ambient profile) |
| **Gloo Gateway** | 2.0.1 | Solo.io Gloo Gateway |
| **Gateway API CRDs** | v1.2.1 | Kubernetes Gateway API |
| **kgateway Backend API** | v1alpha1 | `gateway.kgateway.dev/v1alpha1` |

### Container Images

| Component | Image |
|-----------|-------|
| istiod | `us-docker.pkg.dev/gloo-mesh/istio-594e990587b9/pilot:1.28.1-distroless` |
| ztunnel | `us-docker.pkg.dev/gloo-mesh/istio-594e990587b9/ztunnel:1.28.1-distroless` |
| waypoint | `us-docker.pkg.dev/gloo-mesh/istio-594e990587b9/proxyv2:1.28.1-distroless` |
| Gloo Gateway proxy | `us-docker.pkg.dev/solo-public/gloo-gateway/envoy-wrapper:2.0.1` |

### Test Workloads

| Workload | Image |
|----------|-------|
| httpbin | `kong/httpbin:0.1.0` |
| sleep | `curlimages/curl:8.6.0` |

---

## Reference Documentation

### Istio AuthorizationPolicy
- **Docs**: https://istio.io/latest/docs/reference/config/security/authorization-policy/
- **Ambient mode**: https://istio.io/latest/docs/ambient/usage/l7-features/
- **Version**: 1.28.1 (Solo.io distribution)

### Key Concepts

**Waypoint proxy**: L7 proxy in ambient mesh that enforces AuthorizationPolicy, handles retries, timeouts, etc.

**Cross-namespace waypoint**: Waypoint in one namespace serving workloads in another. Configured via labels:
```yaml
# On the workload namespace
istio.io/use-waypoint: waypoint
istio.io/use-waypoint-namespace: tenant-a-baseline
istio.io/ingress-use-waypoint: "true"
```

**targetRefs**: Recommended way to attach policies to specific services:
```yaml
spec:
  targetRefs:
  - kind: Service
    group: ""
    name: httpbin
```

### Gloo Gateway
- **Docs**: https://docs.solo.io/gateway/latest/
- **Version**: 2.0.1

---

## Known Issues and Notes

1. **`set -e` is used**: The script uses `set -e` for fail-fast behavior. This works with the step system because each step function either succeeds completely or fails with a clear error.

2. **Progress file location**: Progress is stored in `/tmp/`, not appended to config. This keeps the config file clean but means progress is lost on reboot.

3. **License keys**: The script expects `GLOO_GATEWAY_LICENSE_KEY` and `GLOO_MESH_LICENSE_KEY` to be set. These are not in `env.sh` for security reasons.

4. **istioctl requirement**: The script requires Solo.io's `istioctl` distribution. Set `ISTIOCTL` env var or install to `~/.istioctl/bin/istioctl`.

5. **EDS routing bypasses RBAC**: Gloo Gateway's default EDS-based routing sends traffic to pod IPs, which bypasses the waypoint's RBAC enforcement. The solution is to use a static Backend that routes through the Service DNS/VIP.

6. **Policy propagation timing**: AuthorizationPolicy changes can take 5-10 seconds to propagate to the waypoint proxy. Tests include sleep delays to account for this, but occasional flakiness may occur due to Istio's asynchronous config push model.

7. **Gloo Gateway service account**: The proxy service account is named after the Gateway resource (e.g., Gateway `http` → SA `http`), not a fixed name like `gloo-proxy-http`.

---

## Sources

- [Istio AuthorizationPolicy Reference](https://istio.io/latest/docs/reference/config/security/authorization-policy/)
- [Istio Ambient L7 Features](https://istio.io/latest/docs/ambient/usage/l7-features/)
- [AuthorizationPolicy with wildcards discussion](https://discuss.istio.io/t/authorizationpolicy-with-wildcards/9459)
- [Istio #43576 - Authz policy not enforced with waypoint](https://github.com/istio/istio/issues/43576)
- [Istio #56505 - Enable scoping AuthorizationPolicy to workload traffic](https://github.com/istio/istio/issues/56505)
- [kgateway Static Backend Documentation](https://kgateway.dev/docs/traffic-management/destination-types/backends/static/)
- [Solo.io - Authorization Policy in Ambient Mesh](https://www.solo.io/blog/a-guide-to-authorization-policy-in-ambient-mesh)
