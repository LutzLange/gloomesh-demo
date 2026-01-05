# Tenant Self-Service AuthorizationPolicy - Validated Analysis

## Executive Summary

After validating against current Istio documentation, several assumptions in the original design need correction:

| Assumption | Status | Reality |
|------------|--------|---------|
| `source.namespaces` supports wildcards like `tenant-a-*` | ❌ **INVALID** | Wildcards NOT supported in `namespaces` field |
| `source.principals` supports prefix wildcards | ⚠️ **PARTIAL** | Only in specific formats, not for SA wildcards |
| `source.serviceAccounts` supports wildcards | ❌ **INVALID** | Explicitly documented as "No form of wildcard allowed" |
| Policies in workload NS auto-attach to waypoint | ✅ **VALID** | Via `targetRefs` to Service |
| Cross-namespace waypoint policy works | ✅ **VALID** | Since Istio 1.23 |

---

## Validated Findings

### 1. Wildcard Support in AuthorizationPolicy

Per [Istio AuthorizationPolicy Reference](https://istio.io/latest/docs/reference/config/security/authorization-policy/):

| Field | Wildcard Support | Notes |
|-------|------------------|-------|
| `source.namespaces` | ❌ **NO** | Must list each namespace explicitly |
| `source.serviceAccounts` | ❌ **NO** | "No form of wildcard (*) is allowed" |
| `source.principals` | ⚠️ Limited | Prefix match works on whole field, but can't wildcard SA part |
| `source.ipBlocks` | ✅ CIDR only | e.g., `10.0.0.0/8` |
| `to.operation.paths` | ✅ YES | Prefix/suffix/presence match |
| `to.operation.methods` | ✅ YES | Prefix/suffix/presence match |

**Critical**: The string match patterns (prefix `abc*`, suffix `*abc`, presence `*`) apply to **operation fields** (paths, methods, hosts), NOT to source identity fields like namespaces and serviceAccounts.

### 2. Policy Attachment to Waypoints

Per [Istio Ambient L7 Features](https://istio.io/latest/docs/ambient/usage/l7-features/):

> "For an authorization policy to be attached to a waypoint it must have a `targetRef` which refers to the waypoint, or a Service which uses that waypoint."

**Two attachment methods:**

1. **Target the Gateway directly:**
   ```yaml
   targetRefs:
   - kind: Gateway
     group: gateway.networking.k8s.io
     name: waypoint
   ```

2. **Target a Service (recommended for tenant self-service):**
   ```yaml
   targetRefs:
   - kind: Service
     group: ""
     name: my-service
   ```
   Policy auto-attaches to the waypoint that serves the Service.

### 3. Cross-Namespace Waypoint Support

Per [Configure Waypoint Proxies](https://istio.io/latest/docs/ambient/usage/waypoint/):

> "Beginning with Istio 1.23, it is possible to use waypoints in different namespaces."

**Namespace labels required:**
```yaml
labels:
  istio.io/use-waypoint: waypoint
  istio.io/use-waypoint-namespace: tenant-a-baseline
```

### 4. Policy Evaluation Order

Per [Authorization Policy Reference](https://istio.io/latest/docs/reference/config/security/authorization-policy/):

1. If ANY `CUSTOM` policy matches → delegate to extension
2. If ANY `DENY` policy matches → **DENY**
3. If NO `ALLOW` policies exist → **ALLOW** (permissive default)
4. If ANY `ALLOW` policy matches → **ALLOW**
5. Otherwise → **DENY** (implicit deny when ALLOW policies exist)

---

## Revised Options for Tenant Self-Service

Given that namespace wildcards are NOT supported, here are the viable approaches:

### Option A: Explicit Namespace Enumeration (Platform Managed)

Platform team maintains a list of all tenant namespaces in a baseline policy.

```yaml
# Platform managed - must update when new namespace created
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: allow-tenant-a-namespaces
  namespace: tenant-a-baseline
spec:
  targetRefs:
  - kind: Gateway
    group: gateway.networking.k8s.io
    name: waypoint
  action: ALLOW
  rules:
  - from:
    - source:
        namespaces:
        - "tenant-a-ns1"
        - "tenant-a-ns2"
        - "tenant-a-ns3"
        # Must add each new namespace manually!
```

**Pros:**
- Simple, well-understood
- Works with current Istio

**Cons:**
- ❌ Requires platform team update for each new namespace
- ❌ Not true self-service
- ❌ Doesn't scale

---

### Option B: Tenant Policies in Workload Namespaces (Recommended)

Tenants create policies in their own namespaces targeting their Services. Policies auto-attach to the shared waypoint.

```yaml
# Created by tenant in tenant-a-ns1
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: allow-my-sources
  namespace: tenant-a-ns1  # Tenant's namespace
spec:
  targetRefs:
  - kind: Service
    group: ""
    name: httpbin  # Tenant's service
  action: ALLOW
  rules:
  - from:
    - source:
        namespaces:
        - "tenant-a-ns1"    # Same namespace
        - "tenant-a-ns2"    # Specific other namespace
        - "gloo-system"     # Ingress
```

**How it works:**
1. Policy created in `tenant-a-ns1` with `targetRefs` pointing to Service `httpbin`
2. Service `httpbin` uses waypoint in `tenant-a-baseline` (via namespace labels)
3. Istio auto-attaches the policy to the waypoint

**Verification:**
```bash
kubectl get authorizationpolicy -n tenant-a-ns1 -o yaml
```
```yaml
status:
  conditions:
  - message: bound to tenant-a-baseline/waypoint
    reason: Accepted
    status: "True"
    type: WaypointAccepted
```

**Pros:**
- ✅ True tenant self-service
- ✅ No platform team involvement for policy changes
- ✅ Clear ownership (policy in same namespace as service)
- ✅ Works with current Istio

**Cons:**
- ⚠️ Tenants must know all namespaces they want to allow
- ⚠️ Each service needs its own policy

---

### Option C: Principal-Based with Namespace Prefix

Use `principals` field with namespace prefix matching (limited wildcard support).

```yaml
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: allow-tenant-a-principals
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
        principals:
        - "cluster.local/ns/tenant-a-ns1/*"  # ⚠️ May not work as expected
```

**Warning**: Per [Istio documentation](https://istio.io/latest/docs/reference/config/security/authorization-policy/), the principal format is `<TRUST_DOMAIN>/ns/<NAMESPACE>/sa/<SERVICE_ACCOUNT>`. Wildcard matching on partial paths is NOT clearly documented as supported.

**Testing required** to validate if `cluster.local/ns/tenant-a-*` actually works.

---

### Option D: No Restrictive Policy (Permissive Baseline)

If no `ALLOW` policies exist, Istio's default is permissive (all traffic allowed). Platform team only creates `DENY` policies for known-bad traffic.

```yaml
# Platform: Block cross-tenant traffic only
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: deny-cross-tenant
  namespace: tenant-a-baseline
spec:
  targetRefs:
  - kind: Gateway
    group: gateway.networking.k8s.io
    name: waypoint
  action: DENY
  rules:
  - from:
    - source:
        namespaces:
        - "tenant-b-*"  # ❌ Won't work - wildcards not supported!
```

**Problem**: This approach also requires explicit namespace enumeration for DENY rules.

---

### Option E: Kubernetes RBAC + Namespace Controller (Infrastructure Solution)

Instead of relying on Istio policy wildcards, implement a Kubernetes controller that:

1. Watches for new `tenant-a-*` namespaces
2. Automatically updates the baseline AuthorizationPolicy

```yaml
# Controller updates this policy when namespaces change
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: auto-managed-tenant-a
  namespace: tenant-a-baseline
  annotations:
    tenant-controller/managed: "true"
    tenant-controller/pattern: "tenant-a-*"
spec:
  # ... auto-updated by controller
```

**Pros:**
- ✅ Automatic handling of new namespaces
- ✅ Pattern-based logic in controller code
- ✅ Works with current Istio

**Cons:**
- ⚠️ Requires custom controller development
- ⚠️ Additional infrastructure component

---

### Option F: Label-Based Namespace Selection (Future Istio)

Istio may add `namespaceSelector` support in the future, similar to Kubernetes NetworkPolicy:

```yaml
# HYPOTHETICAL - Not currently supported in Istio
rules:
- from:
  - source:
      namespaceSelector:
        matchLabels:
          tenant: "a"
```

**Status**: Not available as of Istio 1.28. Track [Istio GitHub](https://github.com/istio/istio) for future enhancements.

---

## Recommended Architecture

Given the constraints, **Option B (Tenant Policies in Workload Namespaces)** combined with **Option E (Namespace Controller)** provides the best balance:

```
┌─────────────────────────────────────────────────────────────────────────┐
│  Platform Infrastructure                                                │
│  ┌───────────────────────────────────────────────────────────────────┐  │
│  │  Namespace Controller                                              │  │
│  │  - Watches for tenant-a-* namespace creation                      │  │
│  │  - Updates baseline AuthorizationPolicy in tenant-a-baseline      │  │
│  │  - Adds required labels to new namespaces                         │  │
│  └───────────────────────────────────────────────────────────────────┘  │
│                                                                         │
│  ┌───────────────────────────────────────────────────────────────────┐  │
│  │  tenant-a-baseline (Platform Managed)                              │  │
│  │  ┌─────────────┐                                                  │  │
│  │  │  Waypoint   │                                                  │  │
│  │  └─────────────┘                                                  │  │
│  │                                                                    │  │
│  │  Baseline Policy (auto-managed):                                  │  │
│  │  - ALLOW from: [tenant-a-ns1, tenant-a-ns2, ...]                 │  │
│  │  - ALLOW from: gloo-system/http                                   │  │
│  │  - ALLOW from: monitoring/*                                       │  │
│  └───────────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────┐
│  Tenant Self-Service                                                    │
│  ┌──────────────────┐  ┌──────────────────┐  ┌──────────────────┐      │
│  │  tenant-a-ns1    │  │  tenant-a-ns2    │  │  tenant-a-ns3    │      │
│  │                  │  │                  │  │  (new namespace) │      │
│  │  Tenant can:     │  │  Tenant can:     │  │                  │      │
│  │  - Add ALLOW for │  │  - Add ALLOW for │  │  Auto-added to   │      │
│  │    external svc  │  │    external svc  │  │  baseline policy │      │
│  │  - Add DENY to   │  │  - Add DENY to   │  │  by controller   │      │
│  │    restrict      │  │    restrict      │  │                  │      │
│  └──────────────────┘  └──────────────────┘  └──────────────────┘      │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## Summary Table

| Option | Self-Service | Auto New NS | Complexity | Istio Support | Validated |
|--------|--------------|-------------|------------|---------------|-----------|
| A. Explicit enumeration | ❌ | ❌ | Low | ✅ Current | N/A |
| **B. Tenant policies w/ targetRefs** | **✅** | ❌ | **Low** | **✅ Current** | **✅ TESTED** |
| C. Principal prefix match | ⚠️ Partial | ⚠️ Maybe | Medium | ⚠️ Unclear | Not tested |
| D. Permissive + DENY | ❌ | ❌ | Low | ✅ Current | N/A |
| E. Namespace controller | ✅ | ✅ | High | ✅ Current | N/A |
| F. Label selector | ✅ | ✅ | Low | ❌ Future | N/A |

---

## Option B Validation Results

**Test Date**: 2025-01-02
**Istio Version**: 1.28.1 (Solo.io distribution)
**Result**: ✅ All 13 tests passed

### Test Matrix

| Test | Description | Expected | Actual | Status |
|------|-------------|----------|--------|--------|
| 1a | Baseline: intra-tenant (no policy) | 200 | 200 | ✅ |
| 1b | Baseline: cross-tenant (no policy) | 200 | 200 | ✅ |
| 1c | Baseline: ingress (no policy) | 200 | 200 | ✅ |
| 2 | Tenant creates ALLOW policy | Created | Created | ✅ |
| 3 | Policy binds to waypoint | Bound | "bound to tenant-a-baseline/waypoint" | ✅ |
| 4a | Intra-tenant allowed by policy | 200 | 200 | ✅ |
| 4b | Ingress allowed by policy | 200 | 200 | ✅ |
| 5 | Cross-tenant implicit deny | 403 | 403 | ✅ |
| 6 | Policy update adds new source | 200 | 200 | ✅ |
| 7a | DENY policy blocks /headers | 403 | 403 | ✅ |
| 7b | ALLOW policy allows /get | 200 | 200 | ✅ |
| 8a | Second tenant's policy binds | Bound | Bound | ✅ |
| 8b | Cross-ns allowed by ns2 policy | 200 | 200 | ✅ |
| 8c | Cross-tenant denied by ns2 policy | 403 | 403 | ✅ |

### Key Findings from Testing

1. **Auto-Attachment Works**: Policies created in tenant namespaces with `targetRefs` to Service **automatically attach** to the waypoint in a different namespace (tenant-a-baseline).

2. **Status Confirmation**: Policy status explicitly shows attachment:
   ```yaml
   status:
     conditions:
     - message: bound to tenant-a-baseline/waypoint
       reason: Accepted
       status: "True"
       type: WaypointAccepted
   ```

3. **DENY Precedence**: DENY policies evaluated before ALLOW policies, enabling path-specific blocking.

4. **Independent Policies**: Each service can have its own policy with different allow rules.

5. **Implicit Deny**: When any ALLOW policy exists, unlisted sources are denied (403).

---

## References

- [Istio AuthorizationPolicy Reference](https://istio.io/latest/docs/reference/config/security/authorization-policy/)
- [Istio Ambient L7 Features](https://istio.io/latest/docs/ambient/usage/l7-features/)
- [Istio Configure Waypoint Proxies](https://istio.io/latest/docs/ambient/usage/waypoint/)
- [Solo.io - Authorization Policy in Ambient Mesh](https://www.solo.io/blog/a-guide-to-authorization-policy-in-ambient-mesh)
- [Istio #44458 - Layering AuthorizationPolicies with waypoints](https://github.com/istio/istio/issues/44458)
- [Istio #51556 - Cross-namespace policy bug](https://github.com/istio/istio/issues/51556)
