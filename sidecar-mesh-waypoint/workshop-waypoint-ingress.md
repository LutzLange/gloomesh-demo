# Workshop: Waypoint as a Namespace-Level Ingress API Gateway

In this workshop, you'll deploy an Istio ambient waypoint as a namespace-level internal API gateway. Clients address a single hostname per namespace, and path-based routing fans traffic out to individual backend microservices — all without hairpinning through an external ingress gateway.

You'll learn how to:
- Attach routing policies (HTTPRoute and VirtualService) to the waypoint
- Understand why the API Service pattern works (and the no-endpoint pitfall)
- Enforce **AuthorizationPolicy** at the waypoint — two-level security (caller principal check + backend-only-via-waypoint access)
- Use **VirtualService delegation** at the waypoint — proving that existing delegation chains (parent VS → child VS) work unchanged with waypoints
- Simulate Argo Rollout canary deployments by manipulating delegated VirtualServices
- **Migrate from sidecar to ambient** — complete lifecycle walkthrough with zero routing changes
- Set up **multi-cluster routing** through east-west gateway peering (requires Solo Istio license)

## Architecture Overview

```
                              Multicluster Ambient Mesh

Cluster 1                                                          Cluster 2
+--------------------------------------------------------------+   +----------------------------+
| payments-core ns (ambient + waypoint)                    |   | app ns                     |
|                                                              |   |                            |
|  +--------------------------------------------------------+  |   |  +----------------------+  |
|  | api Service                                            |<-+---+--| frontend (client)    |  |
|  | selector: gateway-name=waypoint                        |  |   |  +----------------------+  |
|  | solo.io/service-scope: global                          |  |   |    curl http://api.    F    |
|  | solo.io/service-takeover: true                         |  |   |    payments-core.svc.      |
|  |                                                        |  |   |    cluster.local/users/get |
|  +---------------------------+----------------------------+  |   +----------------------------+
|  +---------------------------+----------------------------+  |
|                              |                               |
|                              v                               |
|  +--------------------------------------------------------+  |
|  | Waypoint Proxy (Envoy L7)                              |  |
|  | /users    -> users:8080                                |  |
|  | /deposits -> deposits:8080                             |  |
|  | /savings  -> savings:8080                              |  |
|  +----------+----------------+-----------------+----------+  |
|             |                |                 |             |
|             v                v                 v             |
|         +-------+      +----------+      +--------+          |
|         | users |      | deposits |      | savings|          |
|         | :8080 |      | :8080    |      | :8080  |          |
|         +-------+      +----------+      +--------+          |
|              (ambient or sidecar)                            |
+--------------------------------------------------------------+
```


---

## Prerequisites

- Solo Enterprise for Istio 1.29+ (images at `us-docker.pkg.dev/soloio-img/istio`, charts at `us-docker.pkg.dev/soloio-img/istio-helm`)
- Single cluster is sufficient for Steps 1–8
- Step 9 (multi-cluster) requires a **Solo Istio license key** and `solo-istioctl`
- Works on kind clusters (with MetalLB for Step 9), EKS, GKE, or any Kubernetes distribution with ambient mesh support

---

## Step 1: Create the Namespace and Backend Services

Create a `payments-core` namespace with three mock microservices using `httpbin` as the backend.

```bash
kubectl create namespace payments-core
kubectl label namespace payments-core istio.io/dataplane-mode=ambient
```

Deploy three backend services:

```bash
kubectl apply -n payments-core -f - <<'EOF'
# --- users service ---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: users
---
apiVersion: v1
kind: Service
metadata:
  name: users
spec:
  ports:
  - name: http
    port: 8080
    targetPort: 8080
  selector:
    app: users
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: users
spec:
  replicas: 1
  selector:
    matchLabels:
      app: users
  template:
    metadata:
      labels:
        app: users
    spec:
      serviceAccountName: users
      containers:
      - name: httpbin
        image: mccutchen/go-httpbin
        ports:
        - containerPort: 8080
---
# --- deposits service ---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: deposits
---
apiVersion: v1
kind: Service
metadata:
  name: deposits
spec:
  ports:
  - name: http
    port: 8080
    targetPort: 8080
  selector:
    app: deposits
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: deposits
spec:
  replicas: 1
  selector:
    matchLabels:
      app: deposits
  template:
    metadata:
      labels:
        app: deposits
    spec:
      serviceAccountName: deposits
      containers:
      - name: httpbin
        image: mccutchen/go-httpbin
        ports:
        - containerPort: 8080
---
# --- savings service ---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: savings
---
apiVersion: v1
kind: Service
metadata:
  name: savings
spec:
  ports:
  - name: http
    port: 8080
    targetPort: 8080
  selector:
    app: savings
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: savings
spec:
  replicas: 1
  selector:
    matchLabels:
      app: savings
  template:
    metadata:
      labels:
        app: savings
    spec:
      serviceAccountName: savings
      containers:
      - name: httpbin
        image: mccutchen/go-httpbin
        ports:
        - containerPort: 8080
EOF
```

Wait for all pods to be running:

```bash
kubectl get pods -n payments-core -w
```

---

## Step 2: Deploy the Waypoint Proxy

Deploy a namespace-scoped waypoint and enroll the namespace to use it:

```bash
kubectl apply -n payments-core -f - <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: waypoint
spec:
  gatewayClassName: istio-waypoint
  listeners:
  - name: mesh
    port: 15008
    protocol: HBONE
EOF

# Enroll the namespace to route all service traffic through the waypoint
kubectl label namespace payments-core istio.io/use-waypoint=waypoint
```

Verify the waypoint is running:

```bash
kubectl get pods -n payments-core -l gateway.networking.k8s.io/gateway-name=waypoint
kubectl get gateway -n payments-core waypoint
```

Expected output:
```
NAME              CLASS            ADDRESS        PROGRAMMED   AGE
waypoint          istio-waypoint   10.x.x.x      True         10s
```

---

## Step 3: Create the API Entry Point

Create a Kubernetes Service called `api` that selects the waypoint proxy. This Service provides a stable hostname (`api.payments-core.svc.cluster.local`) that clients can address. The `solo.io/service-scope=global` and `solo.io/service-takeover=true` labels make this Service routable from other clusters in a multicluster ambient mesh.

```bash
kubectl apply -n payments-core -f - <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: api
  labels:
    istio.io/use-waypoint: waypoint
    istio.io/ingress-use-waypoint: "true"
    solo.io/service-scope: global
    solo.io/service-takeover: "true"
spec:
  ports:
  - name: http
    port: 80
    protocol: TCP
    targetPort: 80
  selector:
    gateway.networking.k8s.io/gateway-name: waypoint
EOF
```

```
+----------------------------------------------------------------+
| payments-core namespace                                    |
|                                                                |
| api.payments-core.svc.cluster.local                        |
| +------------------------------------------------------------+ |
| | api (Service)                                              | |
| | selector: gateway-name=waypoint                            | |
| | labels:                                                    | |
| |   solo.io/service-scope: global                            | |
| |   solo.io/service-takeover: true                           | |
| +----------------------------+-------------------------------+ |
|                              | routes to waypoint pods         |
|                              v                                 |
| +------------------------------------------------------------+ |
| | Waypoint Proxy                                             | |
| | gateway.networking.k8s.io/gateway-name=...                | |
| +------------------------------------------------------------+ |
+----------------------------------------------------------------+
```

This Service is now:
- **Addressable locally** as `api.payments-core.svc.cluster.local`
- **Addressable globally** across clusters via the `global` scope
- **Routed through the waypoint** where HTTPRoute rules are evaluated

### Why this works (and the no-endpoint pitfall)

The key insight is the selector: `gateway.networking.k8s.io/gateway-name: waypoint`. This matches the waypoint proxy pods, so the `api` Service has **real Endpoints** — the waypoint pod IPs.

Verify this:

```bash
kubectl get endpoints api -n payments-core
# NAME   ENDPOINTS          AGE
# api    10.244.0.13:80     1m

kubectl get pods -n payments-core -l gateway.networking.k8s.io/gateway-name=waypoint -o wide
# The pod IP should match the Endpoints IP above
```

This is critical because **ztunnel health-checks require healthy endpoints**. If you create a Service with no selector or a selector matching no pods, ztunnel marks the destination as unhealthy and drops all traffic.

**Labels explained:**

| Label | Purpose |
|-------|---------|
| `istio.io/use-waypoint: waypoint` | Tells mesh clients to route traffic for this Service through the named waypoint |
| `istio.io/ingress-use-waypoint: "true"` | Tells the ingress gateway to also route through the waypoint (not bypass it) |
| `solo.io/service-scope: global` | Makes this Service discoverable from other clusters in a multicluster mesh |
| `solo.io/service-takeover: "true"` | Enables remote clusters to route to this Service even without local endpoints |

---

## Step 4: Attach Routing Rules

Create an HTTPRoute to define path-based routing rules on the waypoint.

```bash
kubectl apply -n payments-core -f - <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: api-routes
spec:
  parentRefs:
  - group: ""
    kind: Service
    name: api
    port: 80
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /users
    filters:
    - type: URLRewrite
      urlRewrite:
        path:
          type: ReplacePrefixMatch
          replacePrefixMatch: /
    - type: ResponseHeaderModifier
      responseHeaderModifier:
        add:
        - name: X-Backend
          value: users
    backendRefs:
    - name: users
      port: 8080
  - matches:
    - path:
        type: PathPrefix
        value: /deposits
    filters:
    - type: URLRewrite
      urlRewrite:
        path:
          type: ReplacePrefixMatch
          replacePrefixMatch: /
    - type: ResponseHeaderModifier
      responseHeaderModifier:
        add:
        - name: X-Backend
          value: deposits
    backendRefs:
    - name: deposits
      port: 8080
  - matches:
    - path:
        type: PathPrefix
        value: /savings
    filters:
    - type: URLRewrite
      urlRewrite:
        path:
          type: ReplacePrefixMatch
          replacePrefixMatch: /
    - type: ResponseHeaderModifier
      responseHeaderModifier:
        add:
        - name: X-Backend
          value: savings
    backendRefs:
    - name: savings
      port: 8080
EOF
```

**How it works:**
```
                 HTTPRoute parentRef
                 +--------------+
                 | api          | (Service)
                 | port: 80     |
                 +------+-------+
                        |
   HTTPRoute rules evaluated at waypoint (URLRewrite strips prefix)
                        |
          +-------------+--------------+
          |             |              |
      /users/*     /deposits/*    /savings/*
      -> /*        -> /*          -> /*
          |             |              |
          v             v              v
      +-------+    +----------+    +---------+
      | users |    | deposits |    | savings |
      | :8080 |    | :8080    |    | :8080   |
      +-------+    +----------+    +---------+
```

---

## Step 5: Deploy a Client and Test

Deploy a client pod in a separate namespace:

```bash
kubectl create namespace client
kubectl label namespace client istio.io/dataplane-mode=ambient

kubectl apply -n client -f - <<'EOF'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: curl
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: curl
spec:
  replicas: 1
  selector:
    matchLabels:
      app: curl
  template:
    metadata:
      labels:
        app: curl
    spec:
      serviceAccountName: curl
      containers:
      - name: curl
        image: curlimages/curl
        command: ["sleep", "infinity"]
EOF
```

Wait for the curl pod to be ready, then test:

```bash
# Test path-based routing
kubectl exec -n client deploy/curl -- curl -s http://api.payments-core.svc.cluster.local/users/get | head -20
kubectl exec -n client deploy/curl -- curl -s http://api.payments-core.svc.cluster.local/deposits/get | head -20
kubectl exec -n client deploy/curl -- curl -s http://api.payments-core.svc.cluster.local/savings/get | head -20
```

Check the `X-Backend` response header to confirm each path routes to the correct service:

```bash
kubectl exec -n client deploy/curl -- curl -sI http://api.payments-core.svc.cluster.local/users/get 2>&1 | grep -i x-backend
# Expected: X-Backend: users

kubectl exec -n client deploy/curl -- curl -sI http://api.payments-core.svc.cluster.local/deposits/get 2>&1 | grep -i x-backend
# Expected: X-Backend: deposits

kubectl exec -n client deploy/curl -- curl -sI http://api.payments-core.svc.cluster.local/savings/get 2>&1 | grep -i x-backend
# Expected: X-Backend: savings
```

Verify traffic is flowing through the waypoint by checking its access logs:

```bash
kubectl logs -n payments-core -l gateway.networking.k8s.io/gateway-name=waypoint --tail=10
```

### Authorization Policies at the Waypoint

In a sidecar-based setup, authorization is typically applied at two levels:

1. **At the ingress gateway** — checking caller principals (who is allowed to call this API)
2. **At the backend sidecar** — ensuring only the gateway (not arbitrary mesh clients) can reach the backend pods directly

With waypoints in ambient mode, the same two-level pattern applies. AuthorizationPolicy targets the waypoint when applied to the `api` Service via `targetRefs`, and can also restrict direct access to backend services.

#### Level 1: Caller principal check at the waypoint

Create an AuthorizationPolicy that only allows the `curl` ServiceAccount from the `client` namespace to call the `api` Service. This policy is evaluated at the waypoint:

```bash
kubectl apply -n payments-core -f - <<'EOF'
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: api-authz
spec:
  targetRefs:
  - kind: Service
    group: ""
    name: api
  action: ALLOW
  rules:
  - from:
    - source:
        principals:
        - "cluster.local/ns/client/sa/curl"
EOF
```

Test from the allowed client — should succeed:

```bash
kubectl exec -n client deploy/curl -- curl -sI http://api.payments-core.svc.cluster.local/users/get 2>&1 | grep -iE "HTTP"
# Expected: HTTP/1.1 200 OK
```

Deploy a second client with a different ServiceAccount and verify it gets **denied**:

```bash
kubectl apply -n client -f - <<'EOF'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: unauthorized-client
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: unauthorized-curl
spec:
  replicas: 1
  selector:
    matchLabels:
      app: unauthorized-curl
  template:
    metadata:
      labels:
        app: unauthorized-curl
    spec:
      serviceAccountName: unauthorized-client
      containers:
      - name: curl
        image: curlimages/curl
        command: ["sleep", "infinity"]
EOF

kubectl rollout status deployment -n client unauthorized-curl --timeout=60s
```

```bash
kubectl exec -n client deploy/unauthorized-curl -- curl -sI http://api.payments-core.svc.cluster.local/users/get 2>&1 | grep -iE "HTTP"
# Expected: HTTP/1.1 403 Forbidden (RBAC: access denied)
```

The AuthorizationPolicy is enforced at the waypoint — only the `curl` ServiceAccount can access the API. Unauthorized identities are rejected before traffic reaches any backend.

#### Level 2: Backend-only-via-waypoint access

In the sidecar model, a second AuthorizationPolicy on the backend sidecar ensures only the gateway can reach the backend pods. In ambient mode, you can enforce the same pattern — restrict backends so only the waypoint's identity can access them.

> **Prerequisite:** The backend services must be associated with a waypoint for `targetRefs` to work. In Step 2, the namespace was labeled with `istio.io/use-waypoint=waypoint`, which associates all services in the namespace with the waypoint. Without this association, the policy status shows `Invalid targetRefs` and is not enforced.

Apply the AuthorizationPolicy:

```bash
kubectl apply -n payments-core -f - <<'EOF'
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: backends-via-waypoint-only
spec:
  targetRefs:
  - kind: Service
    group: ""
    name: users
  - kind: Service
    group: ""
    name: deposits
  - kind: Service
    group: ""
    name: savings
  action: ALLOW
  rules:
  - from:
    - source:
        principals:
        - "cluster.local/ns/payments-core/sa/waypoint"
EOF
```

Verify the policy is accepted (not invalid):

```bash
kubectl get authorizationpolicy backends-via-waypoint-only -n payments-core \
  -o jsonpath='{.status.conditions[0].reason}'
# Expected: Accepted
```

Verify: traffic through the API gateway (waypoint) still works:

```bash
kubectl exec -n client deploy/curl -- curl -sI http://api.payments-core.svc.cluster.local/users/get 2>&1 | grep -iE "HTTP"
# Expected: HTTP/1.1 200 OK (waypoint identity is allowed)
```

Direct access to backend services (bypassing the waypoint) is denied:

```bash
kubectl exec -n client deploy/curl -- curl -sI http://users.payments-core.svc.cluster.local:8080/get 2>&1 | grep -iE "HTTP"
# Expected: HTTP/1.1 403 Forbidden (client identity is not the waypoint)
```

This proves the same two-level authorization model works at waypoints:

```
Client (curl SA)                          Backend (users)
    |                                          ^
    |  AuthZ: only curl SA allowed             |  AuthZ: only waypoint SA allowed
    v                                          |
+--------------------------------------------------+
| Waypoint (api Service)                           |
| Principal: cluster.local/ns/.../sa/waypoint      |
+--------------------------------------------------+
```

#### Clean up authorization resources

Remove the policies and unauthorized client before continuing:

```bash
kubectl delete authorizationpolicy api-authz backends-via-waypoint-only -n payments-core
kubectl delete deploy unauthorized-curl -n client
kubectl delete sa unauthorized-client -n client
```

---

## Step 6: Switch to VirtualService Routing

HTTPRoute is the Kubernetes Gateway API native approach, but you can also use Istio VirtualService for routing through the waypoint. VirtualService offers additional capabilities like regex URI matching, retries with custom retry policies, and timeouts.

Remove the HTTPRoute and replace it with a VirtualService:

```bash
kubectl delete httproute api-routes -n payments-core
```

```bash
kubectl apply -n payments-core -f - <<'EOF'
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: api-routes
  namespace: payments-core
spec:
  hosts:
    - api.payments-core.svc.cluster.local
  http:
    - match:
        - uri:
            regex: /users($|/)(.*)
      name: users-route
      headers:
        response:
          add:
            X-Backend: users
      rewrite:
        uriRegexRewrite:
          match: /users(/|$)(.*)
          rewrite: /\2
      route:
        - destination:
            host: users.payments-core.svc.cluster.local
            port:
              number: 8080
      retries:
        attempts: 3
        retryOn: 503,retriable-status-codes,connect-failure,reset
        retryRemoteLocalities: true
      timeout: 10s
    - match:
        - uri:
            regex: /deposits($|/)(.*)
      name: deposits-route
      headers:
        response:
          add:
            X-Backend: deposits
      rewrite:
        uriRegexRewrite:
          match: /deposits(/|$)(.*)
          rewrite: /\2
      route:
        - destination:
            host: deposits.payments-core.svc.cluster.local
            port:
              number: 8080
      retries:
        attempts: 3
        retryOn: 503,retriable-status-codes,connect-failure,reset
        retryRemoteLocalities: true
      timeout: 10s
    - match:
        - uri:
            regex: /savings($|/)(.*)
      name: savings-route
      headers:
        response:
          add:
            X-Backend: savings
      rewrite:
        uriRegexRewrite:
          match: /savings(/|$)(.*)
          rewrite: /\2
      route:
        - destination:
            host: savings.payments-core.svc.cluster.local
            port:
              number: 8080
      retries:
        attempts: 3
        retryOn: 503,retriable-status-codes,connect-failure,reset
        retryRemoteLocalities: true
      timeout: 10s
EOF
```

Test that routing still works:

```bash
kubectl exec -n client deploy/curl -- curl -sI http://api.payments-core.svc.cluster.local/users/get 2>&1 | grep -iE "HTTP|x-backend"
# Expected:
# HTTP/1.1 200 OK
# x-backend: users

kubectl exec -n client deploy/curl -- curl -sI http://api.payments-core.svc.cluster.local/deposits/get 2>&1 | grep -iE "HTTP|x-backend"
# Expected:
# HTTP/1.1 200 OK
# x-backend: deposits

kubectl exec -n client deploy/curl -- curl -sI http://api.payments-core.svc.cluster.local/savings/get 2>&1 | grep -iE "HTTP|x-backend"
# Expected:
# HTTP/1.1 200 OK
# x-backend: savings
```

---

## Step 7: Migration from Sidecar to Ambient

This step walks through a complete namespace migration from sidecar-injected pods to ambient mesh, proving that the waypoint pattern and VS delegation survive the transition. This follows the same migration pattern used in [Solo's official migration workshop](https://github.com/ably77/solo-enterprise-for-istio-workshops/tree/main/istio-oss-sidecar-to-enterprise-ambient).

### Phase 1: Reset to sidecar-only mode

First, remove the ambient label, waypoint, and api Service to simulate a pre-migration state. Then enable sidecar injection.

```bash
# Remove ambient mode and waypoint enrollment
kubectl label namespace payments-core istio.io/dataplane-mode-
kubectl label namespace payments-core istio.io/use-waypoint-

# Remove the waypoint, api Service, and any routing/canary resources
kubectl delete gateway waypoint -n payments-core 2>/dev/null
kubectl delete svc api -n payments-core 2>/dev/null
kubectl delete httproute api-routes -n payments-core 2>/dev/null
kubectl delete vs api-routes api-routes-parent users-routes deposits-routes savings-routes -n payments-core 2>/dev/null
kubectl delete dr users deposits -n payments-core 2>/dev/null
kubectl delete deploy users-canary deposits-canary -n payments-core 2>/dev/null
kubectl delete sa users-canary deposits-canary -n payments-core 2>/dev/null

# Enable sidecar injection
kubectl label namespace payments-core istio-injection=enabled
```

Restart all backend pods to get sidecars injected:

```bash
kubectl rollout restart deployment -n payments-core users deposits savings
kubectl rollout status deployment -n payments-core users deposits savings --timeout=90s
```

Verify pods now show **2/2 READY** (application container + sidecar):

```bash
kubectl get pods -n payments-core
# NAME                       READY   STATUS    RESTARTS   AGE
# deposits-...               2/2     Running   0          12s
# savings-...                2/2     Running   0          12s
# users-...                  2/2     Running   0          12s
```

Test direct service access (no api gateway yet, sidecars handle mTLS):

```bash
kubectl exec -n client deploy/curl -- curl -s http://users.payments-core.svc.cluster.local:8080/get -o /dev/null -w "users: HTTP %{http_code}\n"
kubectl exec -n client deploy/curl -- curl -s http://deposits.payments-core.svc.cluster.local:8080/get -o /dev/null -w "deposits: HTTP %{http_code}\n"
kubectl exec -n client deploy/curl -- curl -s http://savings.payments-core.svc.cluster.local:8080/get -o /dev/null -w "savings: HTTP %{http_code}\n"
# All should return HTTP 200
```

### Phase 2: Deploy waypoint alongside sidecars (coexistence)

This is the key migration phase. Deploy the waypoint and api Service while sidecars are still active. Both modes coexist.

```bash
# Deploy the waypoint Gateway
kubectl apply -n payments-core -f - <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: waypoint
spec:
  gatewayClassName: istio-waypoint
  listeners:
  - name: mesh
    port: 15008
    protocol: HBONE
EOF

kubectl wait --for=condition=Programmed gateway/waypoint -n payments-core --timeout=60s

# Enroll the namespace to route service traffic through the waypoint
kubectl label namespace payments-core istio.io/use-waypoint=waypoint
```

Create the api Service:

```bash
kubectl apply -n payments-core -f - <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: api
  labels:
    istio.io/use-waypoint: waypoint
    istio.io/ingress-use-waypoint: "true"
    solo.io/service-scope: global
    solo.io/service-takeover: "true"
spec:
  ports:
  - name: http
    port: 80
    protocol: TCP
    targetPort: 80
  selector:
    gateway.networking.k8s.io/gateway-name: waypoint
EOF
```

Deploy canary versions of the backends and add `version: stable` labels to existing deployments. This sets up the full delegation stack so we can prove it survives the migration:

```bash
# Add version: stable labels to existing deployments
kubectl patch deployment users -n payments-core --type merge -p '{"spec":{"template":{"metadata":{"labels":{"version":"stable"}}}}}'
kubectl patch deployment deposits -n payments-core --type merge -p '{"spec":{"template":{"metadata":{"labels":{"version":"stable"}}}}}'

# Deploy canary versions (will get sidecars from istio-injection=enabled)
kubectl apply -n payments-core -f - <<'EOF'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: users-canary
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: users-canary
spec:
  replicas: 1
  selector:
    matchLabels:
      app: users
      version: canary
  template:
    metadata:
      labels:
        app: users
        version: canary
    spec:
      serviceAccountName: users-canary
      containers:
      - name: httpbin
        image: mccutchen/go-httpbin
        ports:
        - containerPort: 8080
        env:
        - name: HTTPBIN_HOST
          value: "users-canary:8080"
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: deposits-canary
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: deposits-canary
spec:
  replicas: 1
  selector:
    matchLabels:
      app: deposits
      version: canary
  template:
    metadata:
      labels:
        app: deposits
        version: canary
    spec:
      serviceAccountName: deposits-canary
      containers:
      - name: httpbin
        image: mccutchen/go-httpbin
        ports:
        - containerPort: 8080
        env:
        - name: HTTPBIN_HOST
          value: "deposits-canary:8080"
EOF

kubectl rollout status deployment -n payments-core users-canary deposits-canary --timeout=90s
```

Create DestinationRules for stable/canary subsets:

```bash
kubectl apply -n payments-core -f - <<'EOF'
apiVersion: networking.istio.io/v1beta1
kind: DestinationRule
metadata:
  name: users
spec:
  host: users.payments-core.svc.cluster.local
  subsets:
  - name: stable
    labels:
      version: stable
  - name: canary
    labels:
      version: canary
---
apiVersion: networking.istio.io/v1beta1
kind: DestinationRule
metadata:
  name: deposits
spec:
  host: deposits.payments-core.svc.cluster.local
  subsets:
  - name: stable
    labels:
      version: stable
  - name: canary
    labels:
      version: canary
EOF
```

Apply the **delegation chain** — parent VS (traffic management team) delegates to child VSes (developer / Argo Rollout managed):

```bash
kubectl apply -n payments-core -f - <<'EOF'
# --- Parent VS (traffic management team) ---
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: api-routes-parent
spec:
  hosts:
    - api.payments-core.svc.cluster.local
  http:
    - name: users-delegation
      match:
        - uri:
            prefix: /users
      delegate:
        name: users-routes
        namespace: payments-core
    - name: deposits-delegation
      match:
        - uri:
            prefix: /deposits
      delegate:
        name: deposits-routes
        namespace: payments-core
    - name: savings-delegation
      match:
        - uri:
            prefix: /savings
      delegate:
        name: savings-routes
        namespace: payments-core
---
# --- Child VSes (developer / Argo Rollout managed) ---
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: users-routes
spec:
  http:
    - name: users-primary
      rewrite:
        uriRegexRewrite:
          match: /users(/|$)(.*)
          rewrite: /\2
      headers:
        response:
          add:
            X-Backend: users
            X-Delegation: "child-vs"
      route:
        - destination:
            host: users.payments-core.svc.cluster.local
            port:
              number: 8080
            subset: stable
          weight: 100
        - destination:
            host: users.payments-core.svc.cluster.local
            port:
              number: 8080
            subset: canary
          weight: 0
      retries:
        attempts: 3
        retryOn: 503,retriable-status-codes,connect-failure,reset
      timeout: 10s
---
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: deposits-routes
spec:
  http:
    - name: deposits-primary
      rewrite:
        uriRegexRewrite:
          match: /deposits(/|$)(.*)
          rewrite: /\2
      headers:
        response:
          add:
            X-Backend: deposits
            X-Delegation: "child-vs"
      route:
        - destination:
            host: deposits.payments-core.svc.cluster.local
            port:
              number: 8080
            subset: stable
          weight: 100
        - destination:
            host: deposits.payments-core.svc.cluster.local
            port:
              number: 8080
            subset: canary
          weight: 0
      retries:
        attempts: 3
        retryOn: 503,retriable-status-codes,connect-failure,reset
      timeout: 10s
---
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: savings-routes
spec:
  http:
    - name: savings-primary
      rewrite:
        uriRegexRewrite:
          match: /savings(/|$)(.*)
          rewrite: /\2
      headers:
        response:
          add:
            X-Backend: savings
            X-Delegation: "child-vs"
      route:
        - destination:
            host: savings.payments-core.svc.cluster.local
            port:
              number: 8080
          weight: 100
      retries:
        attempts: 3
        retryOn: 503,retriable-status-codes,connect-failure,reset
      timeout: 10s
EOF
```

Verify: backends still show 2/2 (sidecars), canary pods also 2/2, waypoint is 1/1:

```bash
kubectl get pods -n payments-core
# NAME                        READY   STATUS    RESTARTS   AGE
# deposits-...                2/2     Running   0          45s
# deposits-canary-...         2/2     Running   0          20s
# savings-...                 2/2     Running   0          45s
# users-...                   2/2     Running   0          45s
# users-canary-...            2/2     Running   0          20s
# waypoint-...                1/1     Running   0          30s
```

Test routing through the waypoint with sidecar backends — note the `X-Delegation: child-vs` header confirming the delegation chain works:

```bash
kubectl exec -n client deploy/curl -- curl -sI http://api.payments-core.svc.cluster.local/users/get 2>&1 | grep -iE "HTTP|x-backend|x-delegation"
# HTTP/1.1 200 OK
# x-backend: users
# x-delegation: child-vs

kubectl exec -n client deploy/curl -- curl -sI http://api.payments-core.svc.cluster.local/deposits/get 2>&1 | grep -iE "HTTP|x-backend|x-delegation"
# HTTP/1.1 200 OK
# x-backend: deposits
# x-delegation: child-vs

kubectl exec -n client deploy/curl -- curl -sI http://api.payments-core.svc.cluster.local/savings/get 2>&1 | grep -iE "HTTP|x-backend|x-delegation"
# HTTP/1.1 200 OK
# x-backend: savings
# x-delegation: child-vs
```

Traffic now flows: client sidecar -> waypoint (L7 routing with delegation) -> backend sidecar -> backend pod.

This is the **coexistence phase** that Solo's migration workshop emphasizes. Both sidecar and ambient infrastructure run side by side. The waypoint proxy handles L7 routing (including the full delegation chain) while sidecars handle mTLS for the backend pods.

### Phase 3: Migrate to ambient

Following [Solo's migration pattern](https://github.com/ably77/solo-enterprise-for-istio-workshops/blob/main/istio-oss-sidecar-to-enterprise-ambient/005-migrate-namespaces.md): remove the sidecar injection label, add the ambient label, restart pods.

```bash
# 1. Remove sidecar injection
kubectl label namespace payments-core istio-injection-

# 2. Enable ambient mode
kubectl label namespace payments-core istio.io/dataplane-mode=ambient

# 3. Restart pods to drop sidecars
kubectl rollout restart deployment -n payments-core users deposits savings users-canary deposits-canary
kubectl rollout status deployment -n payments-core users deposits savings users-canary deposits-canary --timeout=90s
```

> **Why the restart?** This restart is needed **only because we're migrating FROM sidecars**. Enrolling a fresh namespace into ambient mode does NOT require pod restarts — ztunnel enrolls pods live via CNI iptables redirection.
>
> The reason sidecars require a restart: when the sidecar webhook injects a proxy at pod creation time, it adds a `sidecar.istio.io/status` annotation to the pod. Ztunnel checks for this annotation and **skips any pod that has it** — the sidecar takes precedence, no dual interception occurs. Removing the `istio-injection` label only prevents *new* pods from getting sidecars; existing pods still have the sidecar container and the annotation. The restart recreates pods without the sidecar or the annotation, so ztunnel takes over.
>
> **In production:** You don't need to run `kubectl rollout restart` explicitly. Pods migrate to ambient naturally on their next CI/CD deployment — any new pod created after the label change comes up without a sidecar and is immediately enrolled in ambient.

Verify pods now show **1/1 READY** (no more sidecars):

```bash
kubectl get pods -n payments-core
# NAME                        READY   STATUS    RESTARTS   AGE
# deposits-...                1/1     Running   0          14s
# deposits-canary-...         1/1     Running   0          14s
# savings-...                 1/1     Running   0          14s
# users-...                   1/1     Running   0          14s
# users-canary-...            1/1     Running   0          14s
# waypoint-...                1/1     Running   0          2m
```

### Phase 4: Verify everything survives the migration

**Path-based routing** — all three paths still work through the waypoint:

```bash
kubectl exec -n client deploy/curl -- curl -sI http://api.payments-core.svc.cluster.local/users/get 2>&1 | grep -iE "HTTP|x-backend|x-delegation"
# HTTP/1.1 200 OK
# x-backend: users
# x-delegation: child-vs

kubectl exec -n client deploy/curl -- curl -sI http://api.payments-core.svc.cluster.local/deposits/get 2>&1 | grep -iE "HTTP|x-backend|x-delegation"
# HTTP/1.1 200 OK
# x-backend: deposits
# x-delegation: child-vs

kubectl exec -n client deploy/curl -- curl -sI http://api.payments-core.svc.cluster.local/savings/get 2>&1 | grep -iE "HTTP|x-backend|x-delegation"
# HTTP/1.1 200 OK
# x-backend: savings
# x-delegation: child-vs
```

The `X-Delegation: child-vs` header confirms **VS delegation works after migration** — the parent VS delegates to child VSes and the merged routes are applied at the waypoint.

**Canary weight splitting** — update the child VS to send 50% traffic to canary, verify it takes effect immediately:

```bash
kubectl patch vs users-routes -n payments-core --type merge -p '
spec:
  http:
  - name: users-primary
    rewrite:
      uriRegexRewrite:
        match: /users(/|$)(.*)
        rewrite: /\2
    headers:
      response:
        add:
          X-Backend: users
          X-Delegation: child-vs
    route:
    - destination:
        host: users.payments-core.svc.cluster.local
        port:
          number: 8080
        subset: stable
      weight: 50
    - destination:
        host: users.payments-core.svc.cluster.local
        port:
          number: 8080
        subset: canary
      weight: 50
    retries:
      attempts: 3
      retryOn: 503,retriable-status-codes,connect-failure,reset
    timeout: 10s'

# Send 10 requests — expect a mix of stable and canary
for i in $(seq 1 10); do
  kubectl exec -n client deploy/curl -- curl -s http://api.payments-core.svc.cluster.local/users/get 2>&1 | grep -o '"Host": "[^"]*"'
done
```

**Header-based preview routing** — add a canary preview rule, then reset to 100% stable:

```bash
kubectl apply -n payments-core -f - <<'EOF'
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: users-routes
spec:
  http:
    - name: users-canary-preview
      match:
        - headers:
            X-Canary:
              exact: "true"
      rewrite:
        uriRegexRewrite:
          match: /users(/|$)(.*)
          rewrite: /\2
      headers:
        response:
          add:
            X-Backend: users-canary
            X-Delegation: "child-vs"
      route:
        - destination:
            host: users.payments-core.svc.cluster.local
            port:
              number: 8080
            subset: canary
          weight: 100
    - name: users-primary
      rewrite:
        uriRegexRewrite:
          match: /users(/|$)(.*)
          rewrite: /\2
      headers:
        response:
          add:
            X-Backend: users
            X-Delegation: "child-vs"
      route:
        - destination:
            host: users.payments-core.svc.cluster.local
            port:
              number: 8080
            subset: stable
          weight: 100
      retries:
        attempts: 3
        retryOn: 503,retriable-status-codes,connect-failure,reset
      timeout: 10s
EOF

# Without header → stable
kubectl exec -n client deploy/curl -- curl -sI http://api.payments-core.svc.cluster.local/users/get 2>&1 | grep -iE "x-backend"
# x-backend: users

# With canary header → canary
kubectl exec -n client deploy/curl -- curl -sI -H "X-Canary: true" http://api.payments-core.svc.cluster.local/users/get 2>&1 | grep -iE "x-backend"
# x-backend: users-canary
```

Reset the child VS to 100% stable for subsequent steps:

```bash
kubectl apply -n payments-core -f - <<'EOF'
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: users-routes
spec:
  http:
    - name: users-primary
      rewrite:
        uriRegexRewrite:
          match: /users(/|$)(.*)
          rewrite: /\2
      headers:
        response:
          add:
            X-Backend: users
            X-Delegation: "child-vs"
      route:
        - destination:
            host: users.payments-core.svc.cluster.local
            port:
              number: 8080
            subset: stable
          weight: 100
        - destination:
            host: users.payments-core.svc.cluster.local
            port:
              number: 8080
            subset: canary
          weight: 0
      retries:
        attempts: 3
        retryOn: 503,retriable-status-codes,connect-failure,reset
      timeout: 10s
EOF
```

Traffic now flows: ztunnel -> waypoint (L7 routing with delegation) -> ztunnel -> backend pod.

### Migration summary

| Phase | Namespace Label | Pods | Traffic Path |
|-------|----------------|------|-------------|
| 1. Sidecar-only | `istio-injection=enabled` | 2/2 | client sidecar -> backend sidecar |
| 2. Coexistence | `istio-injection=enabled` | 2/2 + waypoint 1/1 | client sidecar -> waypoint (delegation) -> backend sidecar |
| 3. Ambient | `istio.io/dataplane-mode=ambient` | 1/1 + waypoint 1/1 | ztunnel -> waypoint (delegation) -> ztunnel |

Key takeaway: **The VS delegation chain, Argo Rollout integration, and API hostname pattern all survive the migration unchanged.** The only changes needed are namespace labels and pod restarts — no changes to VirtualServices, HTTPRoutes, DestinationRules, or Argo Rollout configuration.

---

## Step 8: How VirtualService Delegation Works at Waypoints

Step 7 deployed the full delegation chain and proved it works. This section explains **why** it works — the control plane mechanics that make delegation transparent to waypoints.

### Why this matters

A common enterprise architecture uses a delegated VS pattern across many namespaces:

```
Parent VS (traffic management team)  →  delegates to  →  Child VS (developer, Argo Rollout managed)
```

The parent VS is bound to a namespace gateway and delegates routing to child VSes shipped with each application's Helm chart. Argo Rollout modifies the child VS for canary deployments (subset-based routing, header-based preview routing). If this delegation pattern doesn't work at waypoints, teams would need to rebuild their entire deployment pipeline.

### How delegation works under the hood

Source code analysis of the Istio control plane (`pilot/pkg/model/virtualservice.go`) confirms that delegation is a **merge-time operation**:

1. `mergeVirtualServicesIfNeeded()` runs at push context initialization — **before** any proxy-specific code
2. Root VS (with `delegate` field) and delegate VS (with empty `hosts`) are flattened into a single merged set of HTTP routes
3. Waypoints receive the already-merged routes via `SidecarScope.EgressListeners[0].VirtualServices()`
4. `getVirtualServiceForWaypoint()` in `listener_waypoint.go` selects VS by matching `hosts` against the service hostname
5. `waypointInboundRoute()` iterates the merged HTTP routes — it has no awareness of whether they were originally delegated

Both sidecars and waypoints share the same route building code path (`httproute.go` line 65: `case model.SidecarProxy, model.Waypoint:`), so there are **no waypoint-specific restrictions on delegation**.

### Architecture with delegation

```
+------------------------------------------------------------------+
| payments-core namespace                                      |
|                                                                  |
|  Parent VS (traffic mgmt team)                                  |
|  hosts: [api.payments-core.svc.cluster.local]               |
|  +---------+-------------+-------------+                        |
|  | /users  | /deposits   | /savings    |  ← path matching       |
|  |delegate:|  delegate:  |  delegate:  |  ← delegates to child  |
|  | users-  |  deposits-  |  savings-   |                        |
|  | routes  |  routes     |  routes     |                        |
|  +----+----+------+------+------+------+                        |
|       |            |            |                                |
|       v            v            v                                |
|  Child VSes (developer / Argo Rollout managed)                   |
|  +----------+ +------------+ +----------+                        |
|  | users-   | | deposits-  | | savings- |                        |
|  | routes   | | routes     | | routes   |                        |
|  | weight:  | | weight:    | | weight:  |                        |
|  | stable/  | | stable/    | | stable/  |                        |
|  | canary   | | canary     | | canary   |                        |
|  +----+-----+ +-----+------+ +----+-----+                        |
|       |              |             |        Merged at push time  |
|       v              v             v        by istiod, then      |
|  +--------------------------------------------------+           |
|  | Waypoint Proxy                                    |           |
|  | receives merged routes, unaware of delegation     |           |
|  +--------------------------------------------------+           |
+------------------------------------------------------------------+
```

### Verify the merged configuration in istiod

You can inspect the merged VirtualService as seen by istiod using `istioctl proxy-config`:

```bash
# Check the routes configured on the waypoint
istioctl proxy-config routes -n payments-core deploy/waypoint -o json | \
  jq '.[].virtualHosts[] | select(.name | contains("api")) | .routes[] | {name: .name, match: .match, route: .route}'
```

This shows the flattened (merged) routes — you'll see routes named like `users-delegation-users-primary` (root name + delegate name), confirming the delegation merge happened.

---

## Step 9: Multi-Cluster Setup and Cross-Cluster Routing

> **Prerequisites:** This step requires a valid **Solo Istio license key** (not a Gloo Mesh or Gloo license — the multicluster peering feature requires a license with `product: istio`). Without it, istiod logs will show `SKIPPING FEATURE MultiCluster due to licensing issue`. Set `$SOLO_ISTIO_LICENSE_KEY` before proceeding.

This step sets up a two-cluster ambient mesh using [Solo's multicluster peering pattern](https://github.com/ably77/solo-enterprise-for-istio-workshops/tree/main/istio-ambient-multicluster). The `api` Service on cluster 1 becomes reachable from cluster 2 via the east-west gateway.

### 9a: Create two kind clusters with MetalLB

```bash
# Create clusters (skip if using existing clusters)
kind create cluster --name cluster1
kind create cluster --name cluster2

export KUBECONTEXT_CLUSTER1=kind-cluster1
export KUBECONTEXT_CLUSTER2=kind-cluster2
```

Kind clusters need MetalLB for LoadBalancer support (east-west gateways require external IPs):

```bash
# Install MetalLB on both clusters
for ctx in $KUBECONTEXT_CLUSTER1 $KUBECONTEXT_CLUSTER2; do
  kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.9/config/manifests/metallb-native.yaml --context $ctx
  kubectl wait --for=condition=Ready pods -l app=metallb -n metallb-system --context $ctx --timeout=120s
done
```

Configure MetalLB IP pools — both kind clusters share the Docker `kind` network, so use separate IP ranges:

```bash
SUBNET=$(docker network inspect kind | python3 -c "import sys,json; configs=json.load(sys.stdin)[0]['IPAM']['Config']; print([c['Subnet'] for c in configs if '.' in c['Subnet']][0])")
BASE=$(echo $SUBNET | cut -d. -f1-2)

# Cluster 1: .255.200-.255.210
kubectl apply --context $KUBECONTEXT_CLUSTER1 -f - <<EOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: default
  namespace: metallb-system
spec:
  addresses:
  - ${BASE}.255.200-${BASE}.255.210
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: default
  namespace: metallb-system
EOF

# Cluster 2: .255.211-.255.220
kubectl apply --context $KUBECONTEXT_CLUSTER2 -f - <<EOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: default
  namespace: metallb-system
spec:
  addresses:
  - ${BASE}.255.211-${BASE}.255.220
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: default
  namespace: metallb-system
EOF
```

### 9b: Generate shared root CA

Both clusters need certificates from the same root CA for mutual TLS across the mesh:

```bash
export ISTIO_VERSION=1.29.0
curl -sL https://istio.io/downloadIstio | ISTIO_VERSION=${ISTIO_VERSION} sh -
cd istio-${ISTIO_VERSION}
mkdir -p certs && cd certs

# Generate root CA
make -f ../tools/certs/Makefile.selfsigned.mk root-ca

# Generate per-cluster intermediate certs
make -f ../tools/certs/Makefile.selfsigned.mk cluster1-cacerts
make -f ../tools/certs/Makefile.selfsigned.mk cluster2-cacerts
cd ../..
```

Install the certificates on each cluster:

```bash
for cluster in cluster1 cluster2; do
  ctx="KUBECONTEXT_$(echo $cluster | tr '[:lower:]' '[:upper:]')"
  kubectl create namespace istio-system --context ${!ctx} 2>/dev/null
  kubectl create secret generic cacerts -n istio-system --context ${!ctx} \
    --from-file=ca-cert.pem=istio-${ISTIO_VERSION}/certs/${cluster}/ca-cert.pem \
    --from-file=ca-key.pem=istio-${ISTIO_VERSION}/certs/${cluster}/ca-key.pem \
    --from-file=root-cert.pem=istio-${ISTIO_VERSION}/certs/${cluster}/root-cert.pem \
    --from-file=cert-chain.pem=istio-${ISTIO_VERSION}/certs/${cluster}/cert-chain.pem \
    --dry-run=client -o yaml | kubectl apply --context ${!ctx} -f -
done
```

### 9c: Install Solo Istio on both clusters

Install Gateway API CRDs and all Istio components on both clusters. Following [Solo's multicluster workshop](https://github.com/ably77/solo-enterprise-for-istio-workshops/blob/main/istio-ambient-multicluster/002-install-istio-on-cluster1.md):

```bash
export ISTIO_VERSION=1.29.0

for cluster in cluster1 cluster2; do
  ctx="KUBECONTEXT_$(echo $cluster | tr '[:lower:]' '[:upper:]')"
  echo "=== Installing Istio on ${cluster} ==="

  kubectl label namespace istio-system topology.istio.io/network=${cluster} --context ${!ctx} --overwrite

  kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.1/standard-install.yaml --context ${!ctx}

  helm upgrade --kube-context ${!ctx} --install istio-base \
    oci://us-docker.pkg.dev/soloio-img/istio-helm/base \
    -n istio-system --version=${ISTIO_VERSION}-solo --create-namespace

  helm upgrade --kube-context ${!ctx} --install istio-cni \
    oci://us-docker.pkg.dev/soloio-img/istio-helm/cni \
    -n istio-system --version=${ISTIO_VERSION}-solo \
    -f - <<EOF
profile: ambient
ambient:
  dnsCapture: true
excludeNamespaces:
  - istio-system
  - kube-system
global:
  hub: us-docker.pkg.dev/soloio-img/istio
  tag: ${ISTIO_VERSION}-solo
  variant: distroless
EOF

  helm upgrade --kube-context ${!ctx} --install istiod \
    oci://us-docker.pkg.dev/soloio-img/istio-helm/istiod \
    -n istio-system --version=${ISTIO_VERSION}-solo \
    -f - <<EOF
profile: ambient
global:
  hub: us-docker.pkg.dev/soloio-img/istio
  tag: ${ISTIO_VERSION}-solo
  variant: distroless
  multiCluster:
    clusterName: ${cluster}
  network: ${cluster}
meshConfig:
  trustDomain: cluster.local
env:
  PILOT_ENABLE_IP_AUTOALLOCATE: "true"
  PILOT_ENABLE_K8S_SELECT_WORKLOAD_ENTRIES: "false"
  PILOT_SKIP_VALIDATE_TRUST_DOMAIN: "true"
platforms:
  peering:
    enabled: true
license:
  value: ${SOLO_ISTIO_LICENSE_KEY}
EOF

  helm upgrade --kube-context ${!ctx} --install ztunnel \
    oci://us-docker.pkg.dev/soloio-img/istio-helm/ztunnel \
    -n istio-system --version=${ISTIO_VERSION}-solo \
    -f - <<EOF
profile: ambient
logLevel: info
global:
  hub: us-docker.pkg.dev/soloio-img/istio
  tag: ${ISTIO_VERSION}-solo
  variant: distroless
resources:
  requests:
    cpu: 200m
    memory: 512Mi
istioNamespace: istio-system
env:
  L7_ENABLED: "true"
  SKIP_VALIDATE_TRUST_DOMAIN: "true"
network: ${cluster}
multiCluster:
  clusterName: ${cluster}
EOF

  echo "Waiting for pods on ${cluster}..."
  kubectl rollout status ds/istio-cni-node -n istio-system --context ${!ctx} --timeout=90s
  kubectl rollout status deploy/istiod -n istio-system --context ${!ctx} --timeout=90s
  kubectl rollout status ds/ztunnel -n istio-system --context ${!ctx} --timeout=90s
done
```

### 9d: Set up east-west gateway peering

Download `solo-istioctl`:

```bash
OS=$(uname | tr '[:upper:]' '[:lower:]' | sed -E 's/darwin/osx/')
ARCH=$(uname -m | sed -E 's/aarch/arm/; s/x86_64/amd64/; s/armv7l/armv7/')
curl -sSL "https://storage.googleapis.com/soloio-istio-binaries/release/${ISTIO_VERSION}-solo/istioctl-${ISTIO_VERSION}-solo-${OS}-${ARCH}.tar.gz" | tar xzf - -C .
mv istioctl solo-istioctl && chmod +x solo-istioctl
```

Create and link east-west gateways:

```bash
# Create gateway namespace
kubectl create ns istio-gateways --context $KUBECONTEXT_CLUSTER1
kubectl create ns istio-gateways --context $KUBECONTEXT_CLUSTER2

# Deploy east-west peering gateways
./solo-istioctl multicluster expose --namespace istio-gateways --context $KUBECONTEXT_CLUSTER1
./solo-istioctl multicluster expose --namespace istio-gateways --context $KUBECONTEXT_CLUSTER2

# Wait for external IPs
kubectl wait --for=jsonpath='{.status.loadBalancer.ingress}' svc/istio-eastwest -n istio-gateways --context $KUBECONTEXT_CLUSTER1 --timeout=60s
kubectl wait --for=jsonpath='{.status.loadBalancer.ingress}' svc/istio-eastwest -n istio-gateways --context $KUBECONTEXT_CLUSTER2 --timeout=60s

# Link clusters
./solo-istioctl multicluster link \
  --contexts=$KUBECONTEXT_CLUSTER1,$KUBECONTEXT_CLUSTER2 \
  --namespace istio-gateways
```

Verify peering:

```bash
# Each cluster should see its own e/w gateway + remote peer gateway
kubectl get gateway -n istio-gateways --context $KUBECONTEXT_CLUSTER1
# NAME                         CLASS            ADDRESS          PROGRAMMED
# istio-eastwest               istio-eastwest   172.19.255.200   True
# istio-remote-peer-cluster2   istio-remote     172.19.255.211   True

kubectl get gateway -n istio-gateways --context $KUBECONTEXT_CLUSTER2
# NAME                         CLASS            ADDRESS          PROGRAMMED
# istio-eastwest               istio-eastwest   172.19.255.211   True
# istio-remote-peer-cluster1   istio-remote     172.19.255.200   True
```

### 9e: Deploy workloads and test cross-cluster routing

Deploy the full workshop setup on cluster 1 (Steps 1-7). Then on cluster 2, create the namespace and a matching `api` Service (for DNS resolution — it will have no local endpoints):

```bash
# Cluster 2: create namespace and api Service stub
kubectl create namespace payments-core --context $KUBECONTEXT_CLUSTER2
kubectl label namespace payments-core istio.io/dataplane-mode=ambient --context $KUBECONTEXT_CLUSTER2

kubectl apply --context $KUBECONTEXT_CLUSTER2 -n payments-core -f - <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: api
  labels:
    istio.io/use-waypoint: waypoint
    solo.io/service-scope: global
    solo.io/service-takeover: "true"
spec:
  ports:
  - name: http
    port: 80
    protocol: TCP
    targetPort: 80
  selector:
    gateway.networking.k8s.io/gateway-name: waypoint
EOF

# Deploy client on cluster 2
kubectl create namespace client --context $KUBECONTEXT_CLUSTER2
kubectl label namespace client istio.io/dataplane-mode=ambient --context $KUBECONTEXT_CLUSTER2
kubectl apply --context $KUBECONTEXT_CLUSTER2 -n client -f - <<'EOF'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: curl
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: curl
spec:
  replicas: 1
  selector:
    matchLabels:
      app: curl
  template:
    metadata:
      labels:
        app: curl
    spec:
      serviceAccountName: curl
      containers:
      - name: curl
        image: curlimages/curl:latest
        command: ["sleep", "infinity"]
EOF
```

Test cross-cluster routing:

```bash
kubectl --context $KUBECONTEXT_CLUSTER2 exec -n client deploy/curl -- \
  curl -sI http://api.payments-core.svc.cluster.local/users/get 2>&1 | grep -iE "HTTP|x-backend|x-delegation"
# Expected:
# HTTP/1.1 200 OK
# x-backend: users
# x-delegation: child-vs
```

Traffic flows: cluster2 ztunnel -> cluster2 e/w gateway -> cluster1 e/w gateway -> cluster1 waypoint -> cluster1 backend.

---

## Summary: Key Questions Answered

### Q1: How does a VirtualService bind to a waypoint?

**Answer:** Via the `hosts` field matching the service hostname. No `gateways` field is needed. When the waypoint handles traffic for `api.payments-core.svc.cluster.local`, it selects VirtualServices whose `hosts` match that hostname. The function `getVirtualServiceForWaypoint()` in `listener_waypoint.go` performs this matching.

This is different from the sidecar model where VS binds to a `networking.istio.io/Gateway` via the `gateways` field. At a waypoint, the binding is implicit through host matching.

### Q2: Does the `delegate` field work in waypoint context?

**Answer: Yes.** Delegation is resolved at the model layer by `mergeVirtualServicesIfNeeded()` in `pilot/pkg/model/virtualservice.go`, which runs during push context initialization — before any proxy-specific (sidecar vs. waypoint) code executes. The waypoint receives already-merged routes and has no awareness of whether they were originally delegated.

Step 7 proves this with the full delegation chain surviving a sidecar-to-ambient migration:
- Parent VS with `delegate` field → child VS without `hosts`
- Child VS with subset-based routing, retries, timeouts
- Dynamic child VS updates (canary weight changes, header-based preview)

### Q3: Does Argo Rollout's VS manipulation work at waypoints?

**Answer: Yes.** Argo Rollout only modifies the child VirtualService resource (adjusting route weights, adding/removing header-match rules for preview). It has no awareness of what the VS targets — it operates purely on the Kubernetes resource. Since delegation works at waypoints (Q2), and Argo Rollout only modifies the delegate VS, Argo Rollout works transparently.

Step 7 Phase 4 simulates the full Argo Rollout lifecycle:
- Canary weight progression (100/0 → 50/50)
- Header-based preview routing (`X-Canary: true`)
- Promotion (back to 100/0 stable)

### Q4: What is the recommended pattern for VS-to-waypoint binding?

**Answer:** Use the VS `hosts` field to match the service hostname. Do not use the `gateways` field. Solo considers VS with ambient waypoints as **stable** (not alpha like upstream OSS). The caveat: **don't mix VS and HTTPRoute for the same service/waypoint** — both transform to the same internal representation but have different matching/merging semantics.

### Q5: Does the API Service pattern work without real pod endpoints?

**Answer: No — and this is critical.** The `api` Service must select pods that actually exist. The selector `gateway.networking.k8s.io/gateway-name: waypoint` matches the waypoint proxy pods, giving the Service real Endpoints (waypoint pod IPs). If you create a Service with no selector or a selector matching nothing, ztunnel health-checks fail because there are no healthy endpoints, and all traffic is dropped.

Step 3 explains this and provides verification commands to confirm the Endpoints match waypoint pod IPs.

### Q6: Does the migration from sidecar to ambient break anything?

**Answer: No.** Step 7 proves the complete migration lifecycle:

| Phase | What Changes | What Stays the Same |
|-------|-------------|-------------------|
| Sidecar-only (2/2) | Starting state | Direct service access works |
| Coexistence (2/2 + waypoint) | Waypoint + api Service deployed | Routing works, sidecars still active |
| Ambient (1/1 + waypoint) | Namespace labels changed, pods restarted | All routing, VS delegation, canary patterns intact |

The only changes required are namespace labels (`istio-injection` -> `istio.io/dataplane-mode=ambient`) and pod restarts. No changes to VirtualServices, HTTPRoutes, Argo Rollout configs, or application code.

### Q7: Does AuthorizationPolicy work at waypoints?

**Answer: Yes.** Step 5 proves the two-level authorization model that maps directly to the sidecar-based pattern:

| Sidecar model | Waypoint model | Workshop proof |
|---------------|---------------|----------------|
| AuthZ at ingress gateway — check caller principal | AuthZ targeting `api` Service — evaluated at waypoint | `api-authz` policy: only `curl` SA allowed, unauthorized client gets 403 |
| AuthZ at backend sidecar — only gateway can access | AuthZ targeting backend Services — only waypoint SA allowed | `backends-via-waypoint-only` policy: direct access returns 403 |

The `targetRefs` field on AuthorizationPolicy controls where the policy is enforced. When targeting the `api` Service, the policy binds to the waypoint automatically (because the `api` Service selector matches waypoint pods). When targeting backend Services (`users`, `deposits`, `savings`), those services must first be labeled with `istio.io/use-waypoint=waypoint` — otherwise the `targetRefs` are invalid and the policy is not enforced.

### Migration path

1. Replace per-namespace `networking.istio.io/Gateway` + gateway pods with a waypoint (`Gateway` with `gatewayClassName: istio-waypoint`)
2. Create an `api` Service selecting the waypoint pods (as shown in Step 3)
3. Update parent VS `hosts` to match the `api` service hostname — **remove the `gateways` field** (no longer referencing a `networking.istio.io/Gateway`)
4. Keep child (delegated) VSes unchanged — they have no `hosts` or `gateways` to modify
5. Keep Argo Rollout configuration unchanged — it only modifies the child VS resource
6. Gradually migrate from VS to HTTPRoute over time (optional)

---

## Cleanup

```bash
# Single cluster
kubectl delete namespace payments-core
kubectl delete namespace client

# Multi-cluster (if Step 9 was run)
kind delete cluster --name cluster1
kind delete cluster --name cluster2
```
