# Using the chart

A single-replica Postgres for alpha environments. Optional one-shot restore from a URL on first boot.

Chart source: `gitea.local.togglecorp.com/tc-infra/tcpg`.

## Quick start

Create a `values.yaml` and install:

```bash
helm install mydb oci://gitea.local.togglecorp.com/tc-infra/tcpg --version 0.0.1 -f values.yaml
```

Apps connect via the ClusterIP service: `mydb-tcpg.<namespace>.svc.cluster.local:5432`.

## Alpha environment (tc cluster)

The chart ships a ready-to-use base for alpha deploys at `chart/values/alpha.yaml`: modest resource requests, `local-path` storage, a nodeAffinity rule that avoids RAID nodes, and `dumpInsecureSkipTlsVerify: true` for internal dump hosts. It does **not** set credentials or a dump URL — layer your own overlay on top. If MinIO is enabled, your overlay **must** also set `minio.ingress.hostname` to the real S3 API host (the chart derives `S3_ENDPOINT_URL` from it and fails closed otherwise — see [Generated S3 credentials](#generated-s3-credentials)):

```bash
helm install mydb oci://gitea.local.togglecorp.com/tc-infra/tcpg --version 0.0.1 \
  -f chart/values/alpha.yaml \
  -f my-overlay.yaml
```

Where `my-overlay.yaml` provides per-install specifics (password, dump source, etc.):

```yaml
init:
  password: "your-db-password-here"
  dumpBaseUrl: "https://dumps.example.internal:8080"
  dumpPath: "/path/to/init-db.dump"
  dumpAuth:
    type: basic
    value: "dump-user:dump-password-here"
```

## Example: full setup with dump restore

Below is a realistic values file (based on `chart/values.local.yaml`). It sets resources, restores from a dump on first boot, pins storage class, and avoids RAID nodes via affinity.

```yaml
resources:
  requests:
    cpu: 0.1
    memory: 1Gi
  limits:
    cpu: 2
    memory: 1Gi

init:
  # Inline password (stored in the chart-managed Secret). Leave empty to
  # auto-generate a 32-char random password, preserved across upgrades via lookup.
  # NOTE: under GitOps (ArgoCD/Flux) an empty password drifts — set it explicitly
  # or ignore the Secret data (see "Running under ArgoCD / GitOps" below).
  password: "your-db-password-here"

  # One-shot restore on first init. Effective URL = dumpBaseUrl + dumpPath.
  # Skipped when PGDATA is already populated.
  dumpBaseUrl: "https://dumps.example.internal:8080"
  dumpPath: "/path/to/init-db.dump"

  # Skip TLS verification for the dump host (internal self-signed cert).
  dumpInsecureSkipTlsVerify: true

  # Basic auth: value is "user:pass", passed to curl -u.
  # For bearer, set type: bearer and value: <token>.
  dumpAuth:
    type: basic
    value: "dump-user:dump-password-here"

persistence:
  enabled: true
  storageClass: "local-path"
  size: 1Gi

affinity:
  nodeAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      nodeSelectorTerms:
        - matchExpressions:
            - key: "node.kubernetes.io/disk-raid"
              operator: NotIn
              values:
                - "true"
```

## Option reference

### `init` — first-init database credentials and restore

This block is **first-init only**: the credentials seed the DB the first time it is initialized, and the dump/restore config runs only at that first init. Re-rendering it does not re-seed an existing database.

- `init.database` (default `postgres`) — DB created by the entrypoint.
- `init.username` (default `postgres`) — superuser created by the entrypoint.
- `init.password` — if empty, a random 32-char password is generated on first install. It's preserved across upgrades via a `lookup` on the existing `<release>-tcpg-pg-credential` Secret, so setting it empty is safe for rotation-free operation under plain `helm upgrade`. **Under GitOps (ArgoCD/Flux) this is unsafe:** `lookup` returns nothing under `helm template`, so an empty password regenerates a new random value on every sync, which then drifts from the password already baked into the existing PVC and breaks authentication. Under GitOps, either set `init.password` explicitly or configure the Application to ignore the Secret's data — see [Running under ArgoCD / GitOps](#running-under-argocd--gitops).
- `init.dumpBaseUrl` + `init.dumpPath` — optional. Concatenated verbatim into the dump URL. Empty `dumpPath` disables restore; if `dumpPath` is set, `dumpBaseUrl` is required. Both are non-secret (plain env vars in the pod spec) — do **not** embed credentials in the URL.
- `init.dumpAuth.type` ∈ `none | basic | bearer`:
  - `none` — no auth header.
  - `basic` — `value` is `user:pass`, passed as `curl -u`.
  - `bearer` — `value` is the token, sent as `Authorization: Bearer <value>`.
- `init.dumpAuth.value` — the only secret. Stored in a dedicated chart-managed Secret named `<release>-tcpg-load-credential` (separate from the main `<release>-tcpg-pg-credential` that Postgres reads — prevents the dump auth from leaking into the Postgres container env).
- `init.existingDumpAuthSecret.{name,key}` — alternative: reference a pre-existing Secret instead of setting `dumpAuth.value` inline. Mutually exclusive with inline; template validation fails hard if both are set.
- `init.dumpInsecureSkipTlsVerify` (default `false`) — `curl -k` for the download. Use only for internal / self-signed hosts.

#### Password persistence: plain Helm vs GitOps

The generated DB password lives only in the `<release>-tcpg-pg-credential` Secret and is reused on subsequent renders via a Helm `lookup`. How that behaves depends on how you render the chart:

- **Plain `helm install` / `helm upgrade` (against a live cluster): nothing to do.** `lookup` reads the existing Secret, so an empty `init.password` is generated once on first install and preserved on every upgrade. This is the default happy path.
- **ArgoCD / Flux (`helm template`, no cluster read): `lookup` is blind** and always returns empty. So if `init.password` is empty, a brand-new random password is generated on **every sync** and overwrites the Secret — which then no longer matches the password baked into the existing PVC, and Postgres auth fails.

The chart serves both unchanged; only GitOps needs one of the two hatches below (a plain-Helm user never has an ArgoCD `Application`, so the `ignoreDifferences` option simply doesn't apply to them).

Two ways to make GitOps safe:

1. **Set `init.password` explicitly** in your values/overlay. Simple and deterministic.
2. **Let the chart generate it once, then never overwrite it.** Configure the ArgoCD `Application` to ignore the Secret's `/data` and respect that during sync, so the first-generated password is written once and left alone:

```yaml
spec:
  ignoreDifferences:
    - group: ""
      kind: Secret
      name: <release>-tcpg-pg-credential
      jsonPointers:
        - /data
  syncPolicy:
    syncOptions:
      - RespectIgnoreDifferences=true
```

**Recovery if drift already happened.** The live PVC still holds the *original* password (it was baked in at first init). First stabilize the password — set `init.password` to the value currently in the live Secret (or apply the `ignoreDifferences` config above) so it stops changing. If the data is disposable or dump-restorable, you can then delete the StatefulSet **and** its PVC so a fresh first-init bakes in the now-stable password.

**Using an externally-managed Secret for dump auth.** Instead of inlining `dumpAuth.value`, reference a pre-existing Secret — useful when the credential is managed by SealedSecrets, External Secrets Operator, Vault, etc.

Create (or have your operator create) the Secret in the same namespace:

```bash
# For basic auth — value format is "user:pass"
kubectl -n <namespace> create secret generic dump-credentials \
  --from-literal=DUMP_AUTH_VALUE='dump-user:dump-password-here'

# For bearer — value is the raw token
kubectl -n <namespace> create secret generic dump-credentials \
  --from-literal=DUMP_AUTH_VALUE='eyJhbGciOi...'
```

Then in values:

```yaml
init:
  dumpBaseUrl: "https://dumps.example.internal:8080"
  dumpPath: "/path/to/init-db.dump"
  dumpAuth:
    type: basic      # or bearer — must match the value's format
    # omit `value` when using existingDumpAuthSecret below
  existingDumpAuthSecret:
    name: dump-credentials
    key: DUMP_AUTH_VALUE   # default; override if your Secret uses a different key
```

Inline (`dumpAuth.value`) and external (`existingDumpAuthSecret.name`) are mutually exclusive — the template fails at render time if both are set.

**Supported dump formats** (auto-detected in the postgres container): plain `.sql`, gzipped `.sql.gz`, and `pg_dump -Fc` custom format. Detection uses `gunzip -t` and `pg_restore -l` — no `file` dependency.

**Restore semantics**: the restore runs via `docker-entrypoint-initdb.d`, so it happens exactly once — on first boot with an empty PGDATA. A sentinel file (`$PGDATA/.restore_complete`) is written only after full success; if it's missing on a populated PGDATA (partial restore), an entrypoint wrapper refuses to start and logs instructions to delete the PVC and reinstall. On success, the downloaded dump is removed from the `emptyDir` to free node disk.

### `persistence` — PVC

- `persistence.enabled` (default `true`) — when `false`, uses an `emptyDir` (data lost on pod restart). Only useful for ephemeral testing.
- `persistence.storageClass` — use "local-path" for tc cluster.
- `persistence.size` (default `10Gi`).
- `persistence.accessModes` (default `[ReadWriteOnce]`).

### `service`

- `service.type` (default `ClusterIP`), `service.port` (default `5432`). Single-replica chart, so no headless service; apps connect via the ClusterIP DNS name.

### `resources`

Standard Kubernetes resource requests/limits. Empty by default (`{}`). Set both requests and limits in production — the chart doesn't impose defaults.

### Scheduling: `affinity`, `tolerations`, `nodeSelector`

Plain passthrough to pod spec. All default to empty.

```yaml
nodeSelector:
  disktype: ssd

tolerations:
  - key: dedicated
    operator: Equal
    value: db
    effect: NoSchedule

affinity:
  nodeAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      nodeSelectorTerms:
        - matchExpressions:
            - key: node.kubernetes.io/disk-raid
              operator: NotIn
              values: ["true"]
```

### `commonAnnotations`

Applied to every resource's metadata (StatefulSet, Service, PVC, PDB, Secret, ConfigMap). Use for Argo CD sync-waves, Helm hooks, or any cross-cutting annotation:

```yaml
commonAnnotations:
  argocd.argoproj.io/sync-wave: "-1"
  helm.sh/hook-weight: "5"
```

### `podDisruptionBudget`

- `podDisruptionBudget.enabled` (default `false`). Enabling it sets `minAvailable: 1`, which on a single-replica StatefulSet blocks voluntary node drains — useful if you'd rather have a stuck drain than an automated DB restart, but it **will** block cluster upgrades and autoscaler node removal. Opt-in deliberately.

### Security contexts

- `podSecurityContext` — pod-level. Defaults to non-root (999/999/999), `runAsNonRoot: true`, `seccompProfile: RuntimeDefault`.
- `containerSecurityContext` — applied to every container (init + main). Defaults satisfy the restricted Pod Security Standard (`allowPrivilegeEscalation: false`, `readOnlyRootFilesystem: true`, `drop: [ALL]`). The chart mounts `emptyDir`s at `/tmp` (init + main) and `/var/run/postgresql` (main, for the unix socket) so Postgres has only `$PGDATA` + those two writable paths.

Override only if you know why.

### Images

- `image.{repository,tag,pullPolicy,pullSecrets}` — main Postgres image (default `postgres:18.1`).
- `initImage.{repository,tag,pullPolicy}` — curl image used by the dump-download init container (default `curlimages/curl:8.11.1`). Only runs when `init.dumpPath` is set.

## Connecting

The chart renders a consumer-facing Secret `<release>-tcpg-pg-credential` with everything an app needs. Keys:

| Key                 | Value                                                           |
|---------------------|-----------------------------------------------------------------|
| `POSTGRES_HOST`     | `<release>-tcpg.<namespace>.svc.cluster.local`                  |
| `POSTGRES_PORT`     | `5432` (or `service.port` override)                             |
| `POSTGRES_DB`       | `init.database`                                                 |
| `POSTGRES_USER`     | `init.username`                                                 |
| `POSTGRES_PASSWORD` | `init.password` (or the 32-char autogen value)                 |
| `POSTGRES_URI`      | `postgres://<user>:<pass>@<host>:<port>/<db>` (URL-encoded)     |

App pods can bind the whole thing via `envFrom`:

```yaml
envFrom:
  - secretRef:
      name: <release>-tcpg-pg-credential
```

Fetch the generated password manually:

```bash
kubectl -n <namespace> get secret <release>-tcpg-pg-credential \
  -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d
```

## Subcharts

`banjo-alpha-deps` is an umbrella. tcpg is a DIY component rendered from `templates/tcpg/`. Garage and Dragonfly come in via Helm dependencies.

| Component  | Source                                                  | Gate                 |
|------------|---------------------------------------------------------|----------------------|
| tcpg       | DIY (this chart, `templates/tcpg/`)                     | `tcpg.enabled`       |
| dragonfly  | `oci://ghcr.io/dragonflydb/dragonfly/helm`, pinned in `Chart.yaml` | `dragonfly.enabled` |
| garage     | vendored under `charts/garage/` (upstream not yet published a Helm chart) | `garage.enabled`    |
| minio      | `oci://registry-1.docker.io/bitnamicharts/minio`, pinned in `Chart.yaml` | `minio.enabled`     |

Dependencies are pulled with `helm dep update chart` (tarballs land in `chart/charts/*.tgz` and are `.gitignore`d — `Chart.lock` pins the versions).

### Enabling Dragonfly

```yaml
dragonfly:
  enabled: true
  # Any key under `dragonfly:` is passed through to the upstream chart.
  # Full upstream values: https://github.com/dragonflydb/dragonfly/blob/main/contrib/charts/dragonfly/values.yaml
  replicaCount: 1
  resources:
    requests: { cpu: "100m", memory: "256Mi" }
    limits:   { cpu: "1",    memory: "512Mi" }
```

Dragonfly Service DNS: `<release>-dragonfly.<namespace>.svc.cluster.local:6379`.

### Enabling Garage

Garage's upstream chart lives at `script/helm/garage/` inside the [Deuxfleurs/garage](https://git.deuxfleurs.fr/Deuxfleurs/garage) repo and is not published independently ([tracking issue](https://git.deuxfleurs.fr/Deuxfleurs/garage/issues/417)). We vendor it at `chart/charts/garage/` and pin the source commit in `chart/charts/garage/VENDORED_FROM.md`.

To refresh to the latest `main-v2` HEAD, run:

```bash
./scripts/vendor-garage.sh
```

(Or `UPSTREAM_REF=<sha-or-tag> ./scripts/vendor-garage.sh` to pin to a specific ref.) Bump the version in `chart/Chart.yaml`'s `dependencies:` block to match `charts/garage/Chart.yaml`, then `helm dep update chart`.

Minimal usage:

```yaml
garage:
  enabled: true
  # Any key under `garage:` is passed through to the vendored chart.
  # See chart/charts/garage/values.yaml (and upstream README) for the full surface.
```

### Enabling MinIO

S3-compatible object store from the upstream Bitnami chart, pulled via OCI. Standalone (single-node) topology only — `chart/values/alpha.yaml` pins `mode: standalone` and a single replica.

```yaml
minio:
  enabled: true
  ingress:
    enabled: true
    hostname: s3.example.com   # REQUIRED — the chart derives S3_ENDPOINT_URL from this
  # Any other key under `minio:` is passed through to the upstream chart.
  # Full upstream values: https://github.com/bitnami/charts/blob/main/bitnami/minio/values.yaml
defaultBuckets: "my-bucket"    # comma/space-separated, standalone-only
```

S3 API DNS: `<release>-minio.<namespace>.svc.cluster.local:9000`. Console (UI) listens on `:9001` on the same Service.

#### Generated S3 credentials

The parent chart owns MinIO's credentials. When `minio.enabled: true` it renders a single Kubernetes Secret named **`minio-s3-credential`** (the value of `minio.auth.existingSecret`) with four keys:

| Key | Description |
| --- | --- |
| `S3_ENDPOINT_URL` | S3 API URL — derived as `<endpointScheme>://<minio.ingress.hostname>`, or set verbatim via `minioConfig.endpointUrl`. |
| `S3_REGION` | S3 region (`minioConfig.region`, default `us-east-1`). |
| `S3_ACCESS_KEY_ID` | Access key id (`minioConfig.accessKeyId`, default `minio`). Not secret, not random. |
| `S3_SECRET_ACCESS_KEY` | Secret key. Auto-generated (`randAlphaNum 32`) on first install and preserved across upgrades; set `minioConfig.secretAccessKey` to pin/rotate. |

**GitOps caveat (same as the Postgres password — applies to `S3_SECRET_ACCESS_KEY`).** Preservation across renders relies on a Helm `lookup`, which works under plain `helm install`/`upgrade` but is **blind under `helm template`** (ArgoCD/Flux). So with an empty `minioConfig.secretAccessKey`, GitOps regenerates the secret key on **every sync**; since MinIO reads its root password back from this same Secret, both MinIO and every app using these creds break. Plain Helm needs nothing. Under GitOps, either set `minioConfig.secretAccessKey` explicitly, **or** have the Application ignore the `minio-s3-credential` Secret's `/data` (`ignoreDifferences` + sync option `RespectIgnoreDifferences=true`) — see [Running under ArgoCD / GitOps](#running-under-argocd--gitops) for the snippet.

Wire it into your app with `envFrom` — the app gets all four keys as environment variables:

```yaml
envFrom:
  - secretRef:
      name: minio-s3-credential
```

This is the **single source of truth**: MinIO reads `S3_ACCESS_KEY_ID` / `S3_SECRET_ACCESS_KEY` back from the same Secret as its root user / password (via `minio.auth.existingSecret` + `rootUserSecretKey` / `rootPasswordSecretKey`). No duplicated keys, no drift.

**`minio.ingress.hostname` is REQUIRED.** Unless you set `minioConfig.endpointUrl` explicitly, rendering **fails closed** if `minio.ingress` is disabled, the hostname is empty, or it's left at the upstream `minio.local` placeholder. For an in-cluster (non-ingress) endpoint, set `minioConfig.endpointUrl` instead, e.g.:

```yaml
minioConfig:
  endpointUrl: "http://minio.my-namespace.svc.cluster.local:9000"
```

`minioConfig` override reference:

```yaml
minioConfig:
  accessKeyId: minio        # S3_ACCESS_KEY_ID and MinIO's root user
  secretAccessKey: ""       # empty → random 32-char, preserved across upgrades
  region: us-east-1         # S3_REGION
  endpointScheme: https     # scheme used when deriving the endpoint from ingress.hostname
  endpointUrl: ""           # explicit S3_ENDPOINT_URL; empty → derived from ingress.hostname
  maxRequestBodyBytes: ""   # per-request body cap in bytes; empty → no Middleware rendered
  memRequestBodyBytes: ""   # bytes buffered in memory before spilling to disk; empty → Traefik default (1 MiB)
```

#### Limiting request body size (Traefik only)

The parent chart can cap the size of each request hitting the MinIO S3 ingress via a [Traefik Middleware](https://doc.traefik.io/traefik/middlewares/http/buffering/). Set `minioConfig.maxRequestBodyBytes` (integer bytes) to opt in; when non-empty and `minio.enabled: true`, the chart renders a `Middleware` named **`minio-body-limit`** in the release namespace:

```yaml
minioConfig:
  maxRequestBodyBytes: 104857600  # 100 MiB
  memRequestBodyBytes: 52428800   # 50 MiB (optional; omit → Traefik's 1 MiB default)
```

- `maxRequestBodyBytes` is a **per-request** cap, **not** a per-object limit — a multipart upload is many requests, so the total object can far exceed this value. It bounds how large any single HTTP request body may be.
- `memRequestBodyBytes` is how much of an in-flight request body Traefik holds in memory before spilling to disk. Empty → omitted from the spec, so Traefik's 1 MiB default applies. Only takes effect when `maxRequestBodyBytes` is set.

The Middleware is a Traefik CRD, so this **requires the Traefik ingress controller**. Wire it to the MinIO ingress by setting `minio.ingress.ingressClassName: "traefik"` and referencing the Middleware via the `router.middlewares` annotation (the MinIO subchart resolves `{{ .Release.Namespace }}` through `tpl` at render time):

```yaml
minio:
  ingress:
    enabled: true
    ingressClassName: "traefik"
    annotations:
      traefik.ingress.kubernetes.io/router.middlewares: '{{ .Release.Namespace }}-minio-body-limit@kubernetescrd'
```

The alpha overlay (`chart/values/alpha.yaml`) already wires all of this with a 100 MiB / 50 MiB pair.

**Rotation caveat.** Changing `minioConfig.secretAccessKey` (or the access key id) rewrites the Secret but does **not** restart pods automatically — you must manually restart both the MinIO pod(s) and the app pods for the new credentials to take effect. Any previously-issued presigned URLs break once the key rotates.

**Bitnami image-distribution caveat (Aug 2025).** Bitnami moved every public `bitnami/*` Docker repo to subscription-only (Bitnami Secure Images). The chart's pinned defaults reference those gated repos; a vanilla install would 401 on every image pull.

`chart/values.yaml` works around this by overriding all four image repositories the chart can pull (`image`, `clientImage`, `console.image`, `defaultInitContainers.volumePermissions.image`) to their `bitnamilegacy/*` equivalents — a frozen free mirror of the pre-cutover images. Tags are inherited from the chart's own pinned defaults; the same tags exist on bitnamilegacy, so versions stay in lockstep with whatever Chart.yaml's pinned `version:` was published with.

Trade-off: `bitnamilegacy/*` is frozen — no future security patches. Acceptable for alpha; **not** for production. For prod, either restore `image.repository: bitnami/<name>` (and the other three) and supply pull secrets for a Bitnami Secure Images subscription, or migrate off the Bitnami chart entirely (e.g. `minio/operator`).

## Caveats

- **Single replica, no backup, no WAL archiving.** For alpha/dev only — not production-grade.
- **No headless Service.** Per-pod DNS (`pod-0.svc.ns`) won't resolve. Apps must connect via the ClusterIP service name.
- **Partial restore recovery is manual.** If restore fails mid-way, delete the PVC and reinstall — the wrapper will tell you so in logs.
- **Benign `chmod: /var/run/postgresql: Operation not permitted` on pod start.** The official postgres image's entrypoint unconditionally tries `chmod 03775 /var/run/postgresql`. With `readOnlyRootFilesystem: true` we mount an `emptyDir` there (owned by `root:<fsGroup>` via k8s), and the non-root pg user can't chmod it. The entrypoint itself swallows the exit code (`|| :`) and the socket is still created correctly — it's a cosmetic line. Silencing it would require running an init container as root, which isn't worth the hardening tradeoff.
