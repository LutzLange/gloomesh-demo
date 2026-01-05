# Tenant Self-Service AuthorizationPolicy Design

## Problem Statement

In a multi-tenant Istio Ambient mesh setup:

- **Platform team** manages `tenant-a-baseline` namespace (contains shared waypoint)
- **Tenant users** cannot modify `tenant-a-baseline`
- **Tenant users** can create namespaces following `tenant-a-*` convention
- **Tenant users** want to define their own AuthorizationPolicies

**Challenge**: How do we allow tenant self-service for AuthorizationPolicy while the waypoint (which enforces policies) lives in a platform-managed namespace?

```
┌─────────────────────────────────────────────────────────────────────────┐
│                    PLATFORM TEAM MANAGED                                │
│  ┌───────────────────────────────────────────────────────────────────┐  │
│  │  tenant-a-baseline                                                 │  │
│  │  ┌─────────────┐                                                  │  │
│  │  │  waypoint   │ ◄── Enforces AuthorizationPolicy                 │  │
│  │  │   proxy     │     But tenants can't create policies here!      │  │
│  │  └─────────────┘                                                  │  │
│  │                                                                    │  │
│  │  ❓ Platform policy needed to allow tenant traffic                │  │
│  └───────────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────┐
│                    TENANT SELF-SERVICE                                  │
│  ┌──────────────────┐  ┌──────────────────┐  ┌──────────────────┐      │
│  │  tenant-a-ns1    │  │  tenant-a-ns2    │  │  tenant-a-ns3    │      │
│  │  (existing)      │  │  (existing)      │  │  (future)        │      │
│  │                  │  │                  │  │                  │      │
│  │  ✅ Tenant can   │  │  ✅ Tenant can   │  │  ✅ Tenant can   │      │
│  │  create policies │  │  create policies │  │  create policies │      │
│  └──────────────────┘  └──────────────────┘  └──────────────────┘      │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## Key Questions

1. **Where should tenant policies live?** In tenant namespaces or waypoint namespace?
2. **How to cover future namespaces?** Policies created today should work for `tenant-a-ns99` created tomorrow
3. **What wildcards are supported?** Can we use `tenant-a-*` patterns?
4. **How does policy evaluation work?** When multiple policies exist across namespaces

---

## Option 1: Tenant Policies in Workload Namespaces (Recommended)

### How It Works

Tenants create AuthorizationPolicies in their own namespaces with `targetRefs` pointing to their services. Istio automatically attaches these policies to the waypoint.

```yaml
# Created by tenant in tenant-a-ns1 namespace
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: allow-my-sources
  namespace: tenant-a-ns1  # Tenant's namespace
spec:
  targetRefs:
  - kind: Service
    group: ""
    name: my-app           # Tenant's service
  action: ALLOW
  rules:
  - from:
    - source:
        namespaces:
        - "tenant-a-*"     # Allow from all tenant-a namespaces
        - "monitoring"     # Allow from monitoring namespace
```

### Policy Attachment to Waypoint

When a policy in `tenant-a-ns1` targets a Service that uses the waypoint in `tenant-a-baseline`, Istio automatically attaches the policy to the waypoint:

```
AuthorizationPolicy (tenant-a-ns1)
    │
    │ targetRefs: Service/my-app
    │
    ▼
Service my-app (tenant-a-ns1)
    │
    │ uses waypoint via namespace labels
    │
    ▼
Waypoint (tenant-a-baseline)
    │
    └── Policy attached here and enforced
```

### Verification

Check the policy status shows it's bound to the waypoint:

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

### Pros
- ✅ True tenant self-service
- ✅ No platform team involvement for policy changes
- ✅ Policies scoped to tenant's services
- ✅ Clear ownership (policy in same namespace as service)

### Cons
- ⚠️ Requires namespace labels to be set correctly
- ⚠️ Each service needs its own policy (or use namespace-wide selector)

---

## Option 2: Platform Baseline Policy with Namespace Wildcards

### How It Works

Platform team creates a baseline policy in `tenant-a-baseline` that allows traffic from ALL `tenant-a-*` namespaces. This acts as a "permit intra-tenant traffic" rule.

```yaml
# Created by platform team in tenant-a-baseline
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: allow-tenant-a-intra-traffic
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
        - "tenant-a-*"    # Wildcard covers all tenant-a namespaces
```

### Wildcard Support in Istio

Per [Istio documentation](https://istio.io/latest/docs/reference/config/security/authorization-policy/), these patterns are supported:

| Field | Wildcard Support | Example |
|-------|------------------|---------|
| `source.namespaces` | ✅ Prefix (`abc*`), Suffix (`*abc`), Presence (`*`) | `tenant-a-*` |
| `source.principals` | ✅ Prefix only in namespace part | `cluster.local/ns/tenant-a-*` |
| `source.serviceAccounts` | ❌ Exact match only | N/A |

### Example: Allow All Tenant Traffic

```yaml
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: baseline-allow-tenant-a
  namespace: tenant-a-baseline
spec:
  targetRefs:
  - kind: Gateway
    group: gateway.networking.k8s.io
    name: waypoint
  action: ALLOW
  rules:
  # Allow traffic from any tenant-a namespace
  - from:
    - source:
        namespaces:
        - "tenant-a-*"
  # Allow traffic from platform services (monitoring, ingress)
  - from:
    - source:
        principals:
        - "cluster.local/ns/gloo-system/sa/http"
        - "cluster.local/ns/monitoring/sa/prometheus"
```

### Pros
- ✅ Covers all current and future `tenant-a-*` namespaces
- ✅ Single policy for entire tenant
- ✅ Platform team controls baseline security

### Cons
- ⚠️ Tenants cannot restrict access further (all tenant namespaces can talk to all services)
- ⚠️ Coarse-grained (namespace level, not service level)
- ⚠️ Requires platform team to update for new ingress sources

---

## Option 3: Layered Policies (Platform Baseline + Tenant Overrides)

### How It Works

Combine platform baseline with tenant-specific policies. Use Istio's policy evaluation rules:

1. **DENY policies** are evaluated first
2. **ALLOW policies** are evaluated second
3. If any ALLOW matches, traffic is permitted
4. If no policy exists, default is ALLOW (ambient mesh)

```
┌─────────────────────────────────────────────────────────────────────┐
│                    POLICY EVALUATION ORDER                          │
├─────────────────────────────────────────────────────────────────────┤
│  1. DENY policies (any namespace)     → If match, DENY             │
│  2. ALLOW policies (any namespace)    → If match, ALLOW            │
│  3. No matching policy                → Default ALLOW              │
└─────────────────────────────────────────────────────────────────────┘
```

### Platform Baseline (tenant-a-baseline)

```yaml
# Platform: Allow all intra-tenant traffic by default
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: baseline-allow-intra-tenant
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
        - "tenant-a-*"
  - from:
    - source:
        principals:
        - "cluster.local/ns/gloo-system/sa/http"  # Ingress
```

### Tenant Override (tenant-a-ns1)

```yaml
# Tenant: Restrict access to specific service
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: deny-cross-namespace
  namespace: tenant-a-ns1
spec:
  targetRefs:
  - kind: Service
    group: ""
    name: sensitive-app
  action: DENY
  rules:
  - from:
    - source:
        notNamespaces:
        - "tenant-a-ns1"  # Deny if NOT from same namespace
```

### Pros
- ✅ Platform provides secure baseline
- ✅ Tenants can restrict further with DENY policies
- ✅ Flexible layering

### Cons
- ⚠️ Complex policy interaction
- ⚠️ Tenants can only DENY, not create new ALLOW paths
- ⚠️ Debugging policy issues is harder

---

## Option 4: Label-Based Namespace Selection

### How It Works

Instead of relying on naming conventions (`tenant-a-*`), use namespace labels for policy selection.

### Namespace Labeling

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: tenant-a-ns1
  labels:
    tenant: "a"
    environment: "prod"
    istio.io/dataplane-mode: ambient
    istio.io/use-waypoint: waypoint
    istio.io/use-waypoint-namespace: tenant-a-baseline
```

### Policy Using Labels (Future Istio Feature)

> **Note**: As of Istio 1.28, `source.namespaces` supports wildcards but NOT label selectors. This is a potential future enhancement.

```yaml
# HYPOTHETICAL - Not currently supported
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: allow-tenant-a-by-label
  namespace: tenant-a-baseline
spec:
  targetRefs:
  - kind: Gateway
    name: waypoint
  action: ALLOW
  rules:
  - from:
    - source:
        namespaceSelector:           # NOT SUPPORTED YET
          matchLabels:
            tenant: "a"
```

### Current Workaround

Use namespace naming convention with wildcards:

```yaml
rules:
- from:
  - source:
      namespaces:
      - "tenant-a-*"  # Works today
```

---

## Option 5: Service-Level Policies with Principal Wildcards

### How It Works

Tenants create policies targeting their services and use principal wildcards to allow traffic from any service account in their tenant namespaces.

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
    name: my-app
  action: ALLOW
  rules:
  - from:
    - source:
        principals:
        - "cluster.local/ns/tenant-a-*"  # Any SA from tenant-a-* namespaces
```

### Principal Wildcard Rules

| Pattern | Valid? | Matches |
|---------|--------|---------|
| `cluster.local/ns/tenant-a-*` | ✅ | Any SA in any `tenant-a-*` namespace |
| `cluster.local/ns/*/sa/app` | ❌ | Not supported (double wildcard) |
| `cluster.local/ns/tenant-a-ns1/sa/*` | ❌ | Not supported |
| `*/ns/tenant-a-ns1/sa/app` | ❌ | Not supported |

### Pros
- ✅ Works with current Istio
- ✅ Tenant self-service
- ✅ Covers future namespaces

### Cons
- ⚠️ Cannot restrict to specific service accounts
- ⚠️ Any workload in `tenant-a-*` can access

---

## Recommended Architecture

### For Maximum Tenant Self-Service

```
┌─────────────────────────────────────────────────────────────────────────┐
│  tenant-a-baseline (Platform Managed)                                   │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │  Waypoint Proxy                                                  │   │
│  │                                                                  │   │
│  │  Platform Baseline Policy:                                       │   │
│  │  - ALLOW from tenant-a-* namespaces                             │   │
│  │  - ALLOW from gloo-system/http (ingress)                        │   │
│  │  - ALLOW from monitoring/* (observability)                       │   │
│  └─────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────┐
│  tenant-a-ns1 (Tenant Managed)                                          │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │  Tenant Policy Options:                                          │   │
│  │                                                                  │   │
│  │  1. Fine-grained ALLOW:                                         │   │
│  │     - Allow specific external services                          │   │
│  │     - Allow specific namespaces beyond tenant-a-*               │   │
│  │                                                                  │   │
│  │  2. Restrictive DENY:                                           │   │
│  │     - Deny access from certain tenant-a-* namespaces            │   │
│  │     - Deny specific paths or methods                            │   │
│  └─────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────┘
```

### Platform Team Responsibilities

1. Create and maintain `tenant-a-baseline` namespace
2. Deploy shared waypoint proxy
3. Create baseline AuthorizationPolicy allowing:
   - Intra-tenant traffic (`tenant-a-*`)
   - Ingress traffic (Gloo Gateway)
   - Monitoring/observability traffic
4. Set up namespace labeling requirements

### Tenant Responsibilities

1. Create namespaces following `tenant-a-*` convention
2. Apply required labels for waypoint usage
3. Create service-specific AuthorizationPolicies in their namespaces
4. Use DENY policies to restrict access beyond baseline

---

## Implementation Example

### Step 1: Platform Creates Baseline Policy

```yaml
# platform-baseline.yaml
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: tenant-a-baseline-allow
  namespace: tenant-a-baseline
spec:
  targetRefs:
  - kind: Gateway
    group: gateway.networking.k8s.io
    name: waypoint
  action: ALLOW
  rules:
  # Allow all intra-tenant traffic
  - from:
    - source:
        namespaces:
        - "tenant-a-*"
  # Allow ingress from Gloo Gateway
  - from:
    - source:
        principals:
        - "cluster.local/ns/gloo-system/sa/http"
  # Allow monitoring
  - from:
    - source:
        namespaces:
        - "monitoring"
        - "istio-system"
```

### Step 2: Tenant Creates Their Namespace

```yaml
# tenant-namespace.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: tenant-a-ns1
  labels:
    tenant: "a"
    istio.io/dataplane-mode: ambient
    istio.io/use-waypoint: waypoint
    istio.io/use-waypoint-namespace: tenant-a-baseline
    istio.io/ingress-use-waypoint: "true"
```

### Step 3: Tenant Deploys Service (No Policy Needed for Basic Access)

With the platform baseline, tenant services are automatically accessible from:
- Other `tenant-a-*` namespaces
- Gloo Gateway ingress
- Monitoring systems

### Step 4: Tenant Adds Restrictions (Optional)

```yaml
# tenant-deny-policy.yaml
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: deny-other-tenants
  namespace: tenant-a-ns1
spec:
  targetRefs:
  - kind: Service
    group: ""
    name: internal-only-service
  action: DENY
  rules:
  # Deny access from tenant-a-ns2 specifically
  - from:
    - source:
        namespaces:
        - "tenant-a-ns2"
```

---

## Testing the Configuration

### Test 1: Intra-Tenant Access (Should Work)

```bash
# From tenant-a-ns2, access service in tenant-a-ns1
kubectl exec -n tenant-a-ns2 deploy/sleep -- \
  curl -s http://my-app.tenant-a-ns1:8080/
# Expected: 200 OK
```

### Test 2: Cross-Tenant Access (Should Be Denied)

```bash
# From tenant-b-ns1, access service in tenant-a-ns1
kubectl exec -n tenant-b-ns1 deploy/sleep -- \
  curl -s http://my-app.tenant-a-ns1:8080/
# Expected: 403 Forbidden (if no cross-tenant policy exists)
```

### Test 3: Ingress Access (Should Work)

```bash
# Via Gloo Gateway
curl -H "Host: my-app.example.com" http://$GLOO_IP/
# Expected: 200 OK
```

### Test 4: Future Namespace (Should Work Without Policy Updates)

```bash
# Create new namespace
kubectl create ns tenant-a-ns99
kubectl label ns tenant-a-ns99 \
  istio.io/dataplane-mode=ambient \
  istio.io/use-waypoint=waypoint \
  istio.io/use-waypoint-namespace=tenant-a-baseline

# Deploy workload and test - should work immediately
# No platform policy update needed!
```

---

## Summary

| Approach | Self-Service | Future Namespaces | Granularity | Complexity |
|----------|--------------|-------------------|-------------|------------|
| **Option 1**: Tenant policies in workload NS | ✅ Full | ✅ Automatic | Fine | Low |
| **Option 2**: Platform baseline with wildcards | ❌ Limited | ✅ Automatic | Coarse | Low |
| **Option 3**: Layered policies | ✅ Partial | ✅ Automatic | Fine | High |
| **Option 4**: Label-based selection | ❌ Future | ✅ With labels | Fine | Medium |
| **Option 5**: Principal wildcards | ✅ Full | ✅ Automatic | Medium | Low |

**Recommended**: Combine **Option 2** (platform baseline) with **Option 1** (tenant policies in workload namespaces) for the best balance of security, self-service, and simplicity.

---

## References

- [Istio AuthorizationPolicy Reference](https://istio.io/latest/docs/reference/config/security/authorization-policy/)
- [Istio Ambient L7 Features](https://istio.io/latest/docs/ambient/usage/l7-features/)
- [Istio Security Best Practices](https://istio.io/latest/docs/ops/best-practices/security/)
- [Solo.io Guide to Authorization Policy in Ambient Mesh](https://www.solo.io/blog/a-guide-to-authorization-policy-in-ambient-mesh)
