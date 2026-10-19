# OAN API gateway (Apache APISIX): DevOps guide

How the OAN gateway is configured, and how to run it locally and on Kubernetes with Helm.

Status of this document: `lint` and `diff` were run against a local APISIX 3.19.0 with ADC 0.31.0. `sync` has **not** been run, and ADC's APISIX backend lists support for 3.8 to 3.17 only (see section 6).

This folder is the **local** setup (ADC against APISIX in Docker). Kubernetes deployments use the APISIX Ingress Controller instead, with the central values in oan-helm (`environments/<env>/values/apisix.yaml`, guide `docs/apisix-gateway.md`) and each app's chart in `oan_*/apisix/k8s`. Section 4 is kept only as background.

## 1. Who owns what

Configuration is split so that one team's sync cannot delete another team's resources. ADC compares the **whole state** of each resource type it is given, so scope matters.

| Owner | File | Resource types | Scoping |
| --- | --- | --- | --- |
| DevOps | `apisix-local/adc.yaml` (this folder) | `global_rule`, `plugin_metadata`, `ssl` | `--include-resource-type` |
| Each app | `oan_*/apisix/adc.yaml` (generated, committed) | `service`, `route`, `consumer` | `--label-selector app=<name>` plus `--include-resource-type` |

- `adc-sync.sh` applies these scopes for you. **Always use it, or copy its flags exactly.** A plain `adc sync -f app.yaml` would delete every other app's services.
- App files are generated from each app's OpenAPI spec by `oan_*/apisix/generate_apisix_config_from_spec.py`. oan_auth_service is a library with no app file: its endpoints are included in each app's file. Never hand-edit them. Throttling tiers come from the `tier=` set on each endpoint's `@route`.
- The central file holds gateway-wide behaviour: `request-id` and `prometheus` as global rules today. Add TLS certificates (`ssl`) here when they exist. The same global rules are set for Kubernetes as `gatewayProxy.plugins` in oan-helm's `apisix.yaml`; keep the two in step.
- Consumers belong to the app that uses them and carry its `app` label (oan_a2c's partner and dashboard consumers). Their keys are `$env://` references that APISIX resolves from its own environment (see `docker-compose.yml`).
- CORS, body-size limits and rate limits stay in the app files. They are per-app decisions.

## 2. Values and where they are read

Hosts are `${VAR}` placeholders in the app `adc.yaml`. ADC fills them in from its own environment when it runs `lint|diff|sync`. An unset one fails the run (`Too small: expected string to have >=1 characters`).

**Needed when ADC runs (sync time)**

| Variable | Used for |
| --- | --- |
| `ADC_BACKEND` | `apisix` |
| `ADC_SERVER` | Admin API URL, for example `http://localhost:9180` |
| `ADC_TOKEN` | Admin key (a secret) |
| `OAN_GRIEVANCE_UPSTREAM_HOST` | Grievance service Frappe host |
| `OAN_GRIEVANCE_SOCKET_UPSTREAM_HOST` | `bench socketio` host |
| `FRAPPE_SITE_NAME` | Sent as `Host` so Frappe picks the site |
| `APISIX_REDIS_HOST` | Rate-limit counter store |

**Needed when the `adc.yaml` files are generated (CI, at release)**

| Variable | Default | Meaning |
| --- | --- | --- |
| `OAN_*_UPSTREAM_PORT`, `OAN_GRIEVANCE_SOCKET_UPSTREAM_PORT` | `8000`, `9000` | Written as numbers; ADC wants integers |
| `APISIX_REDIS_PORT` | `6379` | Same |
| `CORS_ORIGINS_REGEX` | `https?://localhost(:[0-9]+)?` | Allowed browser origins |
| `REALTIME_ALLOWED_ORIGINS` | `http://localhost:3000` | Comma-separated origins for the socket |
| `IAM_COOKIE_PREFIX`, `FRAPPE_WEB_ORIGIN` | empty, derived | See each app's `apisix/README.md` |

Regenerate and commit when any generation-time value changes for the target environment. Do not regenerate per deploy unless the pipeline commits or stores the result.

## 3. Local environment

Prerequisites: Docker, ADC (`npm i -g @api7/adc`, tested with 0.31.0), the Frappe bench running on the host.

1. Create `.env` next to `docker-compose.yml`:

   ```
   APISIX_ADMIN_KEY=<random string>
   ```

2. Start the stack (etcd, redis, APISIX with the admin UI):

   ```bash
   cd /Users/arnav/Code/apisix-local
   docker compose up -d
   ```

   Ports: `9080` traffic, `9180` admin API and UI (`/ui`), `9091` metrics.

3. Load the environment. `adc-env.sh` reads the admin key from the running container and sets the local upstream values (`host.docker.internal` reaches the host bench):

   ```bash
   source adc-env.sh
   ```

4. Generate the app configs when a spec or tier changes (from each app repo, using the bench Python for the spec step):

   ```bash
   # spec (needs frappe): from oan_grievance_service
   /path/to/frappe-bench/env/bin/python openapi/generate_openapi_spec.py
   # gateway config: oan_auth_service must be importable
   PYTHONPATH=../oan_auth_service python3 apisix/generate_apisix_config_from_spec.py
   ```

5. Check, then apply. **Central first**, then each app:

   ```bash
   ./adc-sync.sh lint central
   ./adc-sync.sh diff central          # read the plan before syncing
   ./adc-sync.sh sync central

   APPS=/Users/arnav/Code/frappe_local/frappe-bench/apps
   for a in oan_grievance_service oan_a2c; do
     ./adc-sync.sh lint $APPS/$a/apisix/adc.yaml
     ./adc-sync.sh sync $APPS/$a/apisix/adc.yaml
   done
   ```

   Syncing an app before central removes nothing, but the app's routes then run without `request-id` and `prometheus` until central lands.

6. Smoke test: `curl -i http://localhost:9080/v1/grievances/health` should return `200` with an `X-Request-Id` header.

### Read-only dashboard login (recommended, not applied here)

`config.yaml` has a single admin key, so the dashboard always shows write access. APISIX supports a second key with `role: viewer`. Add it under `deployment.admin.admin_key`, pass its value as another environment variable in `docker-compose.yml`, restart the `apisix` container, and log in to the UI with the viewer key. ADC keeps using the admin key.

### Stream mode warning

The dashboard says stream mode is disabled. Ignore it. Stream proxying is for raw TCP/UDP and is off by default; the OAN apps use HTTP and WebSocket only.

## 4. Kubernetes with Helm (superseded)

Superseded by the APISIX Ingress Controller setup in oan-helm (`docs/apisix-gateway.md`). The ADC-job approach below is kept only for reference.

Assumptions: the official chart (`https://charts.apiseven.com`, chart `apisix`), Frappe services reachable as in-cluster Services, Redis available (managed or in-cluster). The two concerns are separate: Helm installs the gateway, and an ADC job loads the configuration.

### 4.1 Install the gateway

```bash
helm repo add apisix https://charts.apiseven.com && helm repo update
kubectl create namespace gateway
kubectl -n gateway create secret generic apisix-admin \
  --from-literal=admin-key='<random>' --from-literal=viewer-key='<random>'
helm upgrade --install apisix apisix/apisix -n gateway -f values-apisix.yaml
```

`values-apisix.yaml` (a starting point; verify key names with `helm show values apisix/apisix`):

```yaml
apisix:
  router:
    http: radixtree_uri_with_parameter   # routes use :param segments
  admin:
    enabled: true
    allow:
      ipList: ["10.0.0.0/8"]             # internal CIDRs only, never 0.0.0.0/0
    credentials:
      admin: <from secret>               # supply via a secret, not in git
      viewer: <from secret>              # read-only key for the dashboard
  prometheus:
    enabled: true
etcd:
  enabled: true
  replicaCount: 3
  persistence:
    enabled: true
gateway:
  type: ClusterIP                        # expose through your Ingress or LB
dashboard:
  enabled: false                         # the dashboard is not needed in production
```

Points to confirm for your chart version: how admin credentials are taken from a Secret, the exact key that sets the router mode, and whether the chart enables the admin UI. The router mode is required: without it, routes with `:param` fail to match.

### 4.2 Load the configuration with an ADC job

ADC is a CLI, so run it as a Job in the release pipeline (or a Helm post-install/upgrade hook) after the gateway is ready. Keep three things out of the image: the admin key, the upstream hosts and the app `adc.yaml` files.

```yaml
apiVersion: v1
kind: ConfigMap
metadata: { name: adc-env, namespace: gateway }
data:
  ADC_BACKEND: apisix
  ADC_SERVER: http://apisix-admin.gateway.svc:9180
  OAN_AUTH_UPSTREAM_HOST: oan-auth.apps.svc
  OAN_GRIEVANCE_UPSTREAM_HOST: oan-grievance.apps.svc
  OAN_GRIEVANCE_SOCKET_UPSTREAM_HOST: oan-grievance-websocket.apps.svc
  FRAPPE_SITE_NAME: grievance.example.org
  APISIX_REDIS_HOST: redis.apps.svc
---
apiVersion: batch/v1
kind: Job
metadata: { name: adc-sync, namespace: gateway }
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: adc
          image: <registry>/adc:0.31.0        # pin the version tested here
          envFrom: [{ configMapRef: { name: adc-env } }]
          env:
            - name: ADC_TOKEN
              valueFrom: { secretKeyRef: { name: apisix-admin, key: admin-key } }
          command: ["/bin/sh", "-ec"]
          args:
            - |
              adc sync -f /cfg/central.yaml \
                --include-resource-type global_rule --include-resource-type plugin_metadata \
                --include-resource-type ssl --include-resource-type consumer
              for f in /cfg/apps/*.yaml; do
                app=$(sed -n 's/^    app: //p' "$f" | head -1)
                adc sync -f "$f" --label-selector "app=$app" \
                  --include-resource-type service --include-resource-type route
              done
          volumeMounts: [{ name: cfg, mountPath: /cfg }]
      volumes:
        - name: cfg
          projected: { sources: [] }          # mount central.yaml and each app file here
```

Notes:
- The image must contain ADC 0.31.0 or a version you have tested; check that its `adc` binary path matches the command. There is no official image assumed here.
- Fill the `cfg` volume from a ConfigMap built from `apisix-local/adc.yaml` and each app's committed `adc.yaml` (for example `kubectl create configmap`, or Kustomize `configMapGenerator`).
- Run `adc diff` first in a pipeline stage, and require approval before `sync`.
- Central runs before the apps, as in the local order.

### 4.3 Environment differences to set

| Item | Local | Kubernetes |
| --- | --- | --- |
| Upstream hosts | `host.docker.internal` | in-cluster Service DNS names |
| Admin key | read from the container | Secret `apisix-admin`, rotated by DevOps |
| `allow_admin` | `0.0.0.0/0` | internal CIDRs only |
| `CORS_ORIGINS_REGEX` | any `localhost` port | the real front-end origins |
| Redis | compose `redis` service | managed Redis or its own release |
| etcd | single container | 3 replicas with persistent volumes |

## 5. Operating notes

- **Adding an endpoint:** give its `@route` a `tier=`, regenerate the spec and the app `adc.yaml`, commit both, then `diff` and `sync` that app. A route without a tier stops the generator.
- **Rate limits** are counted in Redis. If Redis is down, `allow_degradation` keeps traffic flowing without limits.
- **Token checks** are done by Frappe, not the gateway (`GATEWAY_JWT = False` in the generators). Moving them to the gateway needs `jwt-auth` consumers for each issuer (use `key_claim_name: iss`) in the central file; test with a real token first.
- **Plugin reuse:** ADC 0.31.0 rejects `plugin_configs`, so shared plugins are either global rules (central file) or per-service blocks (app files).
- **Rollback:** re-run the previous commit's `adc.yaml` through the same sync. State lives in etcd, so back it up before major changes.

## 6. Known ADC limits (APISIX backend)

From the ADC APISIX-backend README: the backend is marked experimental, and versions it does not list are untested.

- **Version support:** full for APISIX 3.8 to 3.17, partial for 3.2 to 3.7. 3.18 and 3.19 are not listed. Pin APISIX and ADC to versions you have run a full `diff`, `sync`, `diff` round trip on, and re-test on every upgrade.
- **Not supported:** `upstream_id` references, `plugin_configs`, consumer groups. Upstreams are inline per service.
- **Noisy diffs:** some resources always show as changed, because APISIX adds default values when it stores them. Reviewers should expect this on `adc diff`.
- **Serialize syncs:** run one `adc sync` per gateway at a time (a CI concurrency group per environment). Concurrent writers can overwrite each other.
- **Consumers:** app syncs include the `consumer` type, scoped by the app label; the central sync does not, so it never deletes an app's consumers.
