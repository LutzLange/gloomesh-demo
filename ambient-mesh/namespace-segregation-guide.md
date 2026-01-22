# Namespace Segregation & Policy Enforcement in Istio Ambient Mesh

A comprehensive guide covering ingress options, L4 vs L7 policy enforcement, and namespace isolation patterns.

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Understanding L4 vs L7 Policy Enforcement](#understanding-l4-vs-l7-policy-enforcement)
3. [Part 1: Namespace Segregation with Istio Ingress Gateway](#part-1-namespace-segregation-with-istio-ingress-gateway)
4. [Part 2: Why Gloo Gateway v2 (kgateway-based)](#part-2-why-gloo-gateway-v2-kgateway-based)
5. [Comparison Summary](#comparison-summary)
6. [Recommendations](#recommendations)

---

## Architecture Overview

### Istio Ambient Mesh Components

Ambient mesh splits the data plane into two layers:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  External Traffic                                                            │
│       │                                                                      │
│       ▼                                                                      │
│  ┌─────────────────────────────────────────────────────────────────────────┐│
│  │  INGRESS LAYER (choose one)                                             ││
│  │  ┌─────────────────────┐    OR    ┌─────────────────────┐              ││
│  │  │  Istio Ingress GW   │          │  Gloo Gateway v2    │              ││
│  │  │  (Envoy)            │          │  (Envoy/kgateway)   │              ││
│  │  │  gatewayClass:istio │          │  gatewayClass:      │              ││
│  │  │                     │          │  gloo-gateway-v2    │              ││
│  │  └─────────────────────┘          └─────────────────────┘              ││
│  └─────────────────────────────────────────────────────────────────────────┘│
│       │                                                                      │
│       ▼                                                                      │
│  ┌─────────────────────────────────────────────────────────────────────────┐│
│  │  L4 LAYER: ztunnel (per-node DaemonSet)                                 ││
│  │  • Automatic mTLS (HBONE protocol)                                      ││
│  │  • SPIFFE identity for every workload                                   ││
│  │  • L4 AuthorizationPolicy enforcement                                   ││
│  │  • TCP metrics and connection logging                                   ││
│  └─────────────────────────────────────────────────────────────────────────┘│
│       │                                                                      │
│       ▼ (optional, if waypoint configured)                                  │
│  ┌─────────────────────────────────────────────────────────────────────────┐│
│  │  L7 LAYER: Waypoint Proxy (per-namespace or per-service)                ││
│  │  • HTTP routing, retries, timeouts                                      ││
│  │  • L7 AuthorizationPolicy (methods, paths, headers)                     ││
│  │  • Rate limiting, fault injection                                       ││
│  │  • HTTP metrics, access logging, tracing                                ││
│  └─────────────────────────────────────────────────────────────────────────┘│
│       │                                                                      │
│       ▼                                                                      │
│  ┌─────────────────────────────────────────────────────────────────────────┐│
│  │  WORKLOAD                                                               ││
│  └─────────────────────────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────────────────────┘
```

### Key Insight: All Components are Envoy-Based

| Component | Data Plane | Control Plane | Configuration API |
|-----------|------------|---------------|-------------------|
| Istio Ingress Gateway | Envoy Proxy | istiod | Gateway API, VirtualService |
| Gloo Gateway v2 | Envoy Proxy | Gloo controller | Gateway API, GlooTrafficPolicy |
| Waypoint Proxy | Envoy Proxy | istiod | Gateway API, AuthorizationPolicy |
| ztunnel | Rust (not Envoy) | istiod | AuthorizationPolicy (L4 only) |

---

## Understanding L4 vs L7 Policy Enforcement

### L4 (Transport Layer) - Enforced by ztunnel

**What it sees:**
- Source/destination IP addresses
- Source/destination ports
- TCP connection metadata
- Workload identity (SPIFFE principal)
- Namespace of source/destination

**What it cannot see:**
- HTTP method (GET, POST, etc.)
- URL path (/api/users)
- HTTP headers (Authorization, Content-Type)
- Request/response body

**L4 AuthorizationPolicy Example:**
```yaml
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: allow-from-trusted-namespaces
  namespace: bookinfo
spec:
  selector:
    matchLabels:
      app: productpage
  action: ALLOW
  rules:
  - from:
    - source:
        namespaces: ["frontend", "api-gateway"]  # L4: namespace-based
    - source:
        principals:                               # L4: identity-based
        - "cluster.local/ns/monitoring/sa/prometheus"
  - to:
    - operation:
        ports: ["9080"]                          # L4: port-based
```

### L7 (Application Layer) - Enforced by Waypoint or Ingress Gateway

**What it sees (in addition to L4):**
- HTTP method
- URL path and query parameters
- HTTP headers
- Host header
- JWT claims (with RequestAuthentication)

**L7 AuthorizationPolicy Example:**
```yaml
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: api-access-control
  namespace: bookinfo
spec:
  targetRefs:
  - kind: Service
    name: productpage
  action: ALLOW
  rules:
  - from:
    - source:
        namespaces: ["frontend"]
    to:
    - operation:
        methods: ["GET"]                         # L7: HTTP method
        paths: ["/api/*", "/health"]             # L7: URL path
  - from:
    - source:
        namespaces: ["admin"]
    to:
    - operation:
        methods: ["GET", "POST", "DELETE"]
        paths: ["/admin/*"]
        headers:
          x-admin-token:                         # L7: HTTP header
          - "secret-token"
```

### When to Use Each Layer

| Use Case | Layer | Reason |
|----------|-------|--------|
| Namespace isolation | L4 | Simple identity-based rules, low overhead |
| Block all traffic except from specific services | L4 | Doesn't need HTTP parsing |
| mTLS enforcement | L4 | PeerAuthentication at ztunnel |
| Rate limiting by endpoint | L7 | Needs path information |
| API method restrictions (GET vs POST) | L7 | Needs HTTP parsing |
| JWT/OAuth validation | L7 | Needs header inspection |
| Canary routing by header | L7 | Needs header inspection |

---

## Part 1: Namespace Segregation with Istio Ingress Gateway

### What is Istio Ingress Gateway?

Istio Ingress Gateway is an Envoy-based ingress controller managed by istiod. It's included with Istio and provides:

- Native mesh integration (automatic mTLS to backends)
- Gateway API support (the Kubernetes standard)
- AuthorizationPolicy enforcement directly on the gateway
- No additional license required

### Deploying Istio Ingress Gateway with Gateway API

```yaml
# Gateway resource - this creates the ingress gateway pod
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: main-gateway
  namespace: istio-system
spec:
  gatewayClassName: istio    # Uses Istio's gateway controller
  listeners:
  - name: http
    port: 80
    protocol: HTTP
    allowedRoutes:
      namespaces:
        from: All            # Allow HTTPRoutes from any namespace
---
# HTTPRoute to expose a service
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: bookinfo-route
  namespace: bookinfo
spec:
  parentRefs:
  - name: main-gateway
    namespace: istio-system
  hostnames:
  - "bookinfo.example.com"
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /
    backendRefs:
    - name: productpage
      port: 9080
```

### Critical: Ingress Gateway to Waypoint Routing

**Default behavior:** Istio Ingress Gateway sends traffic directly to the backend, bypassing the waypoint.

This is because the ingress gateway implements HBONE natively and routes to destinations directly without going through ztunnel's interception.

**To force traffic through waypoint**, add this label to the destination Service:

```bash
kubectl label service productpage -n bookinfo istio.io/ingress-use-waypoint=true
```

### Policy Enforcement Options with Istio Ingress Gateway

#### Option A: Policies on the Ingress Gateway (L7 at Edge)

Apply AuthorizationPolicy directly to the gateway for edge enforcement:

```yaml
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: gateway-ip-allowlist
  namespace: istio-system
spec:
  targetRef:
    kind: Gateway
    group: gateway.networking.k8s.io
    name: main-gateway
  action: ALLOW
  rules:
  - from:
    - source:
        ipBlocks: ["10.0.0.0/8", "192.168.1.0/24"]  # Corporate IPs
    to:
    - operation:
        methods: ["GET", "POST"]
        paths: ["/api/*"]
---
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: gateway-deny-admin
  namespace: istio-system
spec:
  targetRef:
    kind: Gateway
    group: gateway.networking.k8s.io
    name: main-gateway
  action: DENY
  rules:
  - to:
    - operation:
        paths: ["/admin/*", "*/actuator/*"]  # Block admin endpoints at edge
```

#### Option B: L4 at ztunnel + L7 at Waypoint (Defense in Depth)

This provides layered security with policies at multiple enforcement points:

**Step 1: Enable ingress-to-waypoint routing**
```bash
kubectl label service productpage -n bookinfo istio.io/ingress-use-waypoint=true
```

**Step 2: L4 policy at ztunnel (namespace segregation)**
```yaml
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: productpage-l4
  namespace: bookinfo
spec:
  selector:
    matchLabels:
      app: productpage
  action: ALLOW
  rules:
  - from:
    - source:
        principals:
        # Allow ingress gateway identity
        - "cluster.local/ns/istio-system/sa/main-gateway-istio"
        # Allow waypoint identity (for L7 processing)
        - "cluster.local/ns/bookinfo/sa/waypoint"
        # Allow other in-mesh services
        - "cluster.local/ns/bookinfo/sa/reviews"
```

**Step 3: L7 policy at waypoint**
```yaml
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: productpage-l7
  namespace: bookinfo
spec:
  targetRefs:
  - kind: Service
    name: productpage
  action: ALLOW
  rules:
  - from:
    - source:
        namespaces: ["istio-system"]  # From ingress
    to:
    - operation:
        methods: ["GET"]
        paths: ["/productpage", "/static/*", "/health"]
  - from:
    - source:
        namespaces: ["bookinfo"]      # Internal services
    to:
    - operation:
        methods: ["GET", "POST"]
```

### Complete Namespace Segregation Example with Istio Ingress Gateway

**Scenario:** Two tenants (tenant-a, tenant-b) must be isolated from each other but accessible via ingress.

```yaml
# 1. Deploy waypoint for tenant-a namespace
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: waypoint
  namespace: tenant-a
spec:
  gatewayClassName: istio-waypoint
  listeners:
  - name: mesh
    port: 15008
    protocol: HBONE
---
# 2. Label namespace to use waypoint
# kubectl label namespace tenant-a istio.io/use-waypoint=waypoint

# 3. Label services to receive ingress through waypoint
# kubectl label service app-a -n tenant-a istio.io/ingress-use-waypoint=true

# 4. PeerAuthentication - require mTLS (block plaintext)
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: strict-mtls
  namespace: tenant-a
spec:
  mtls:
    mode: STRICT
---
# 5. L4 policy - namespace isolation at ztunnel
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: tenant-a-l4-isolation
  namespace: tenant-a
spec:
  action: ALLOW
  rules:
  - from:
    - source:
        namespaces:
        - "tenant-a"           # Same tenant
        - "istio-system"       # Ingress gateway
        - "istio-gateways"     # East-west gateway (multi-cluster)
---
# 6. L7 policy - fine-grained access control at waypoint
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: tenant-a-l7-api
  namespace: tenant-a
spec:
  targetRefs:
  - kind: Service
    name: app-a
  action: ALLOW
  rules:
  - from:
    - source:
        namespaces: ["istio-system"]  # External via ingress
    to:
    - operation:
        methods: ["GET", "POST"]
        paths: ["/api/*"]
  - from:
    - source:
        namespaces: ["tenant-a"]      # Internal tenant traffic
    to:
    - operation:
        methods: ["GET", "POST", "PUT", "DELETE"]
```

### Verification Commands

```bash
# Check policy binding status
kubectl get authorizationpolicy -n tenant-a -o yaml | grep -A10 "status:"

# Test from allowed namespace
kubectl exec -n istio-system deploy/main-gateway-istio -- \
  curl -s http://app-a.tenant-a:8080/api/health

# Test from blocked namespace (should fail)
kubectl exec -n tenant-b deploy/curl -- \
  curl -s http://app-a.tenant-a:8080/api/health
# Expected: RBAC: access denied

# Check ztunnel logs for denials
kubectl logs -n istio-system -l app=ztunnel | grep -E "RBAC|denied"
```

---

## Part 2: Why Gloo Gateway v2 (kgateway-based)

### What is Gloo Gateway v2?

Gloo Gateway v2 is Solo.io's enterprise API gateway built on **kgateway** (formerly Gloo Edge), which is itself built on Envoy. It provides:

- Full Gateway API compatibility
- Enterprise features beyond Istio's capabilities
- Unified control for north-south and east-west traffic
- Professional support and FIPS-validated images

### Advantages Over Istio Ingress Gateway

| Feature | Istio Ingress Gateway | Gloo Gateway v2 |
|---------|----------------------|-----------------|
| **Rate Limiting** | Basic (via EnvoyFilter, alpha) | Native GlooTrafficPolicy (production-ready) |
| **External Auth** | Via ext_authz (manual config) | Native ExtAuth integration |
| **OAuth/OIDC** | Manual configuration | Built-in OIDC provider |
| **JWT Validation** | RequestAuthentication | Native + enhanced claims routing |
| **WAF** | Not included | ModSecurity integration available |
| **API Key Auth** | Not included | Native support |
| **Transformations** | EnvoyFilter (fragile) | Native request/response transformation |
| **Developer Portal** | Not included | Optional add-on |
| **Support** | Community | 24/7 Enterprise support |
| **FIPS Compliance** | Solo.io distribution only | Included |

### When to Choose Gloo Gateway v2

Choose Gloo Gateway when you need:

1. **Production-grade rate limiting** without managing Redis separately
2. **OAuth/OIDC integration** at the gateway level
3. **Request transformation** (header manipulation, body transformation)
4. **Enterprise support** with SLAs
5. **Unified gateway** for both ingress and waypoint functionality
6. **WAF capabilities** for OWASP protection

### Deploying Gloo Gateway v2

```yaml
# Gateway using Gloo Gateway v2
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: http
  namespace: gloo-system
spec:
  gatewayClassName: gloo-gateway-v2   # Gloo's gateway class
  listeners:
  - name: http
    port: 80
    protocol: HTTP
    allowedRoutes:
      namespaces:
        from: All
```

### Critical: Static Backend Pattern for Waypoint Integration

Unlike Istio Ingress Gateway, Gloo Gateway uses Endpoint Discovery Service (EDS) by default, which routes directly to pod IPs. This bypasses the Service VIP and therefore bypasses waypoint.

**Solution:** Use a Static Backend to force traffic through the Service VIP:

```yaml
# Static Backend - forces traffic through Service VIP → waypoint
apiVersion: gateway.kgateway.dev/v1alpha1
kind: Backend
metadata:
  name: productpage-vip
  namespace: bookinfo
spec:
  type: Static
  static:
    hosts:
    - host: productpage.bookinfo.svc.cluster.local  # Service DNS, not pod IP
      port: 9080
---
# HTTPRoute references the Static Backend
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: bookinfo-route
  namespace: bookinfo
spec:
  parentRefs:
  - name: http
    namespace: gloo-system
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /productpage
    backendRefs:
    - name: productpage-vip
      kind: Backend
      group: gateway.kgateway.dev  # Reference Backend, not Service
```

### Adding Gloo Gateway to the Mesh

For full mTLS integration, add the Gloo Gateway namespace to the ambient mesh:

```bash
kubectl label namespace gloo-system istio.io/dataplane-mode=ambient
```

This ensures:
- Traffic from Gloo Gateway goes through ztunnel
- mTLS is established between gateway and backend
- Policies can reference Gloo Gateway's identity

### Policy Enforcement with Gloo Gateway v2

#### L4 Policy at ztunnel (Namespace Segregation)

Same as with Istio Ingress Gateway:

```yaml
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: productpage-l4
  namespace: bookinfo
spec:
  selector:
    matchLabels:
      app: productpage
  action: ALLOW
  rules:
  - from:
    - source:
        namespaces:
        - "gloo-system"      # Gloo Gateway
        - "bookinfo"         # Internal
        - "istio-gateways"   # East-west (multi-cluster)
```

#### L7 Policy at Waypoint

Same AuthorizationPolicy syntax:

```yaml
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: productpage-l7
  namespace: bookinfo
spec:
  targetRefs:
  - kind: Service
    name: productpage
  action: ALLOW
  rules:
  - from:
    - source:
        namespaces: ["gloo-system"]
    to:
    - operation:
        methods: ["GET"]
        paths: ["/productpage", "/static/*"]
```

#### Enterprise Features: Rate Limiting with GlooTrafficPolicy

```yaml
apiVersion: gloo.solo.io/v1alpha1
kind: GlooTrafficPolicy
metadata:
  name: productpage-ratelimit
  namespace: bookinfo
spec:
  targetRefs:
  - group: gateway.networking.k8s.io
    kind: HTTPRoute
    name: bookinfo-route
  rateLimit:
    local:
      tokenBucket:
        maxTokens: 100
        tokensPerFill: 100
        fillInterval: 60s
```

#### Enterprise Features: External Authentication

```yaml
apiVersion: gateway.kgateway.dev/v1alpha1
kind: AuthConfig
metadata:
  name: oauth-config
  namespace: gloo-system
spec:
  configs:
  - oauth2:
      oidcAuthorizationCode:
        appUrl: https://myapp.example.com
        callbackPath: /callback
        clientId: my-client-id
        clientSecretRef:
          name: oauth-secret
          namespace: gloo-system
        issuerUrl: https://auth.example.com
        scopes:
        - openid
        - profile
```

### Complete Namespace Segregation Example with Gloo Gateway

```yaml
# 1. Static Backend for each tenant service
apiVersion: gateway.kgateway.dev/v1alpha1
kind: Backend
metadata:
  name: tenant-a-app-vip
  namespace: tenant-a
spec:
  type: Static
  static:
    hosts:
    - host: app-a.tenant-a.svc.cluster.local
      port: 8080
---
# 2. HTTPRoute with tenant-specific path prefix
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: tenant-a-route
  namespace: tenant-a
spec:
  parentRefs:
  - name: http
    namespace: gloo-system
  hostnames:
  - "tenant-a.example.com"
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /
    backendRefs:
    - name: tenant-a-app-vip
      kind: Backend
      group: gateway.kgateway.dev
---
# 3. Waypoint for tenant-a
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: waypoint
  namespace: tenant-a
spec:
  gatewayClassName: istio-waypoint
  listeners:
  - name: mesh
    port: 15008
    protocol: HBONE
---
# 4. PeerAuthentication - STRICT mTLS
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: strict-mtls
  namespace: tenant-a
spec:
  mtls:
    mode: STRICT
---
# 5. L4 policy at ztunnel
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: tenant-a-l4
  namespace: tenant-a
spec:
  action: ALLOW
  rules:
  - from:
    - source:
        namespaces:
        - "tenant-a"
        - "gloo-system"
        - "istio-gateways"
---
# 6. L7 policy at waypoint
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: tenant-a-l7
  namespace: tenant-a
spec:
  targetRefs:
  - kind: Service
    name: app-a
  action: ALLOW
  rules:
  - from:
    - source:
        namespaces: ["gloo-system"]
    to:
    - operation:
        methods: ["GET", "POST"]
        paths: ["/api/*"]
  - from:
    - source:
        namespaces: ["tenant-a"]
---
# 7. Rate limiting at gateway (Gloo-specific)
apiVersion: gloo.solo.io/v1alpha1
kind: GlooTrafficPolicy
metadata:
  name: tenant-a-ratelimit
  namespace: tenant-a
spec:
  targetRefs:
  - group: gateway.networking.k8s.io
    kind: HTTPRoute
    name: tenant-a-route
  rateLimit:
    local:
      tokenBucket:
        maxTokens: 1000
        tokensPerFill: 1000
        fillInterval: 60s
```

---

## Comparison Summary

### Feature Comparison

| Capability | Istio Ingress Gateway | Gloo Gateway v2 |
|------------|----------------------|-----------------|
| **L4 Policy Enforcement** | ✅ Via ztunnel | ✅ Via ztunnel |
| **L7 Policy Enforcement** | ✅ On gateway + waypoint | ✅ On gateway + waypoint |
| **Waypoint Integration** | Label on Service | Static Backend pattern |
| **Rate Limiting** | ❌ Requires EnvoyFilter | ✅ Native GlooTrafficPolicy |
| **OAuth/OIDC** | ❌ Manual ext_authz | ✅ Native integration |
| **JWT Validation** | ✅ RequestAuthentication | ✅ Enhanced |
| **Request Transformation** | ❌ EnvoyFilter (fragile) | ✅ Native |
| **WAF** | ❌ Not included | ✅ ModSecurity |
| **License** | Free (OSS) | Commercial |
| **Support** | Community | Enterprise 24/7 |

### Traffic Flow Comparison

**Istio Ingress Gateway:**
```
Client → Istio Gateway → [ztunnel] → Waypoint → [ztunnel] → Pod
                         (if labeled with istio.io/ingress-use-waypoint)
```

**Gloo Gateway v2:**
```
Client → Gloo Gateway → ztunnel → Waypoint → ztunnel → Pod
         (Static Backend forces Service VIP routing)
```

### Configuration Complexity

| Task | Istio Ingress Gateway | Gloo Gateway v2 |
|------|----------------------|-----------------|
| Basic ingress | Simple | Simple |
| mTLS to backend | Automatic | Automatic (with namespace label) |
| Waypoint routing | Label on Service | Static Backend required |
| Rate limiting | Complex (EnvoyFilter) | Simple (GlooTrafficPolicy) |
| OAuth | Complex (ext_authz) | Simple (AuthConfig) |

---

## Recommendations

### Choose Istio Ingress Gateway When:

- Budget is constrained (free, OSS)
- Basic L4/L7 policies are sufficient
- Team has Istio expertise
- No need for advanced API gateway features
- Simple rate limiting not required at ingress

### Choose Gloo Gateway v2 When:

- Need production-grade rate limiting
- Require OAuth/OIDC at the gateway
- Need request/response transformation
- Want unified observability (Gloo Platform UI)
- Require enterprise support
- Multi-cluster management is important
- WAF/security features needed
- Replacing NGINX Ingress with similar enterprise features

### Hybrid Approach

You can use both:
- **Gloo Gateway** for external-facing APIs with enterprise features
- **Istio Ingress Gateway** for internal services or simpler use cases

Both integrate seamlessly with the ambient mesh and waypoint proxies.

---

## Appendix: Quick Reference Commands

### Namespace Setup

```bash
# Add namespace to ambient mesh
kubectl label namespace <ns> istio.io/dataplane-mode=ambient

# Configure namespace to use waypoint
kubectl label namespace <ns> istio.io/use-waypoint=waypoint

# Enable ingress-to-waypoint routing (Istio Gateway)
kubectl label service <svc> -n <ns> istio.io/ingress-use-waypoint=true
```

### Verification

```bash
# Check ztunnel is handling traffic
kubectl logs -n istio-system -l app=ztunnel | grep <namespace>

# Check policy binding to waypoint
kubectl get authorizationpolicy -n <ns> -o yaml | grep -A5 "status:"

# Check waypoint is running
kubectl get pods -n <ns> -l gateway.networking.k8s.io/gateway-name=waypoint

# Test policy enforcement
kubectl exec -n <allowed-ns> deploy/curl -- curl -s http://<svc>.<ns>:8080
```

### Troubleshooting

```bash
# Check for RBAC denials in ztunnel
kubectl logs -n istio-system -l app=ztunnel | grep "RBAC"

# Check waypoint logs
kubectl logs -n <ns> -l gateway.networking.k8s.io/gateway-name=waypoint

# Verify mTLS is enforced
istioctl proxy-config secret -n <ns> deploy/<workload>
```
