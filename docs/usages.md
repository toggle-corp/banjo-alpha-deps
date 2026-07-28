# Using the chart

Umbrella chart of alpha-environment dependencies for the tc cluster: Postgres (`tcpg`), MinIO, Garage, and Dragonfly. Every component is opt-in (`enabled: false` by default). `tcpg` is a single-replica Postgres with an optional one-shot restore from a URL on first boot.

Chart source: <https://github.com/toggle-corp/banjo-alpha-deps>.

## Quick start

Clone the repo, create a `values.yaml`, and install from the local chart:

```bash
git clone https://github.com/toggle-corp/banjo-alpha-deps.git
helm install mydb ./banjo-alpha-deps/chart -f values.yaml
```

> Togglecorp internal: the chart is also published to the internal OCI registry, so
> `helm install mydb oci://<internal-registry>/togglecorp/banjo-alpha-deps --version 0.0.1 -f values.yaml`
> works from inside the network.

Apps connect via the ClusterIP service: `tcpg.<namespace>.svc.cluster.local:5432` (fixed name — see [Connecting](#connecting)).

## Minimum values to define

The chart's `values.yaml` defaults are already tuned for tc alpha (modest resource requests, `local-path` storage, RAID-avoiding nodeAffinity, fixed resource names, a 100 MiB MinIO body cap). You only supply the per-install values below. Every component is **opt-in** (`enabled: false` by default).

Copy this block into your overlay, fill the `# REQUIRED` lines, and delete the components you don't need:

```yaml
# === Postgres (tcpg) =========================================================
tcpg:
  enabled: true                 # REQUIRED to deploy Postgres at all
  init:
    # Bootstrapped into the tcpg-pg-credential Secret by a pre-install/pre-upgrade
    # Helm-hook Job (same model under plain Helm and GitOps — no lookup). Empty →
    # generated once and preserved; set → written/overwritten. Write-once /
    # init-frozen: baked into the PVC at first init and never re-read, so set it
    # only at first init or a deliberate reset (must match the PVC).
    # Consumed by: the app, via the `tcpg-pg-credential` Secret (POSTGRES_PASSWORD).
    password: "CHANGE-ME-db-password"   # optional — pin at first init

    # optional — one-shot restore on FIRST init only. Effective URL = restore.baseUrl + restore.path.
    restore:
      enabled: false           # SOLE on/off gate — whole block ignored when false
      baseUrl: ""              # required when enabled, e.g. https://dumps.example.internal:8080
      path: ""                # required when enabled, e.g. /path/to/init-db.dump
      insecureSkipTlsVerify: false   # optional: set true for internal self-signed dump hosts
      auth:
        type: none             # optional: none | basic | bearer
        value: ""              # optional: "user:pass" (basic) or token (bearer)

# === MinIO (S3-compatible object store) ======================================
minio:
  enabled: true                 # REQUIRED to deploy MinIO at all
  ingress:
    hostname: "s3.example.com"  # REQUIRED when minio on — chart derives S3_ENDPOINT_URL from it.
                                # (Alternatively set minioConfig.endpointUrl for an in-cluster endpoint.)
  defaultBuckets: ""           # optional, comma/space-separated, e.g. "uploads,backups"
minioConfig:
  # Bootstrapped into the minio-s3-credential Secret by a pre-install/pre-upgrade
  # Helm-hook Job (same model under plain Helm and GitOps — no lookup). Empty →
  # generated once and preserved; set to a value → written/overwritten (rotation).
  # MinIO re-reads it on restart, so rotating is in-place: set the value, then
  # restart MinIO + consuming app pods.
  # Consumed by: MinIO (root password) AND the app, via `minio-s3-credential` (S3_SECRET_ACCESS_KEY).
  secretAccessKey: ""          # optional — set to pin/rotate
  endpointUrl: ""             # optional — set instead of minio.ingress.hostname for in-cluster endpoints

# === Garage / Dragonfly (optional extra components) ==========================
garage:
  enabled: false               # flip to true to deploy Garage (single-node S3)
dragonfly:
  enabled: false               # flip to true to deploy Dragonfly (Redis-compatible)
```

**Consumer secrets to `envFrom`** (fixed names due to `fullnameOverride`, no `<release>-` prefix):

- `tcpg-pg-credential` — Postgres connection (`POSTGRES_HOST/PORT/DB/USER/PASSWORD/URI`).
- `minio-s3-credential` — S3 access (`S3_ENDPOINT_URL/REGION/ACCESS_KEY_ID/SECRET_ACCESS_KEY`).

## Alpha environment (tc cluster)

This chart is alpha / tc-cluster-only, and its `values.yaml` defaults are already tuned for it: modest resource requests, `local-path` storage, a nodeAffinity rule that avoids RAID nodes, fixed resource names, and a 100 MiB/50 MiB MinIO request-body cap. There is **no separate overlay to layer** — just supply your per-install values (credentials, dump source, MinIO hostname) directly:

```bash
helm install mydb ./chart -f values.yaml
```

Where `values.yaml` provides per-install specifics (password, dump source, etc.). Note `restore.insecureSkipTlsVerify` stays `false` in the defaults — set it per-install when your dump host uses an internal/self-signed cert:

```yaml
tcpg:
  enabled: true
  init:
    password: "your-db-password-here"
    restore:
      enabled: true
      baseUrl: "https://dumps.example.internal:8080"
      path: "/path/to/init-db.dump"
      insecureSkipTlsVerify: true   # per-install: internal self-signed dump host
      auth:
        type: basic
        value: "dump-user:dump-password-here"
```

## Deployment-metadata labels (`app.togglecorp.com/*`)

The ingresses this chart renders carry the shared **deployment-metadata standard**, so
downstream tooling (the dashboard, uptime monitoring, `kubectl -l …`) can tell what a
deployment is without a hardcoded mapping table. The canonical spec lives in
`docs/annotations.md` of Togglecorp's internal `argo-templates` repo.

Responsibilities are split, and Helm deep-merges the two halves:

| Field | Who sets it |
| --- | --- |
| `part-of`, `name`, `stack`, `tier`, `instance` | the **deploy layer** (argo-templates' `banjo-x`), per install |
| `component: resources` | **this chart** — only it knows these ingresses serve a dependency, not the app |
| `health-check: /minio/health/live` | **this chart** — MinIO's liveness path is a property of MinIO |

A parent Helm chart cannot push values into a subchart, so the deploy layer writes the
subchart paths directly. If you install this chart by hand and want the taxonomy, supply:

```yaml
minio:
  # No per-ingress `labels` value exists in the bitnami minio subchart, so the taxonomy
  # goes here. Selector-safe: bitnami's common.labels.matchLabels picks only
  # app.kubernetes.io/{name,instance} out of customLabels, so custom labels can never
  # reach an immutable matchLabels selector.
  commonLabels:
    app.togglecorp.com/part-of: IFRC
    app.togglecorp.com/name: GO
    app.togglecorp.com/stack: banjo
    app.togglecorp.com/tier: alpha
    app.togglecorp.com/instance: "3"

garage:                      # garage's vendored chart DOES expose per-ingress labels
  ingress:
    s3:
      api: { labels: { app.togglecorp.com/part-of: IFRC } }
      web: { labels: { app.togglecorp.com/part-of: IFRC } }
```

Label values must be legal Kubernetes label values (≤63 chars, alphanumeric first/last,
only `A-Za-z0-9._-` between). Mixed case is fine and expected — these are display-ready.

## Example: dump restore overlay

A realistic per-install overlay that restores from a dump on first boot. Resources, `local-path` storage, and the RAID-avoiding affinity are already baked into the defaults, so an overlay only needs the per-install specifics (note everything is nested under `tcpg:` — this is an umbrella chart):

```yaml
tcpg:
  enabled: true
  init:
    # Password for the `tcpg-pg-credential` Secret, bootstrapped by a Helm-hook
    # Job (same under plain Helm and GitOps). Leave empty to auto-generate a
    # 32-char random password once (preserved thereafter); set it to pin the
    # value at first init (see "Credential bootstrap: how the Secrets are
    # created" below).
    password: "your-db-password-here"

    # One-shot restore on first init. Effective URL = restore.baseUrl + restore.path.
    # Gated by restore.enabled; skipped when PGDATA is already populated.
    restore:
      enabled: true
      baseUrl: "https://dumps.example.internal:8080"
      path: "/path/to/init-db.dump"

      # Skip TLS verification for the dump host (internal self-signed cert).
      insecureSkipTlsVerify: true

      # Basic auth: value is "user:pass", passed to curl -u.
      # For bearer, set type: bearer and value: <token>.
      auth:
        type: basic
        value: "dump-user:dump-password-here"
```

## Option reference

### `init` — first-init database credentials and restore

This block is **first-init only**: the credentials seed the DB the first time it is initialized, and the dump/restore config runs only at that first init. Re-rendering it does not re-seed an existing database.

- `tcpg.secretName` (default empty → `tcpg-pg-credential`) — override the name of the Postgres credential Secret. The bootstrap Job creates/manages a Secret by this name; the StatefulSet and your app consume it by the same name.
- `init.database` (default `postgres`) — DB created by the entrypoint.
- `init.username` (default `postgres`) — superuser created by the entrypoint.
- `init.password` — bootstrapped into the `tcpg-pg-credential` Secret by a pre-install/pre-upgrade **Helm-hook Job** that runs against the live cluster (so it behaves identically under plain Helm and GitOps — no `lookup`). Three-state logic: **set** → the Job writes/overwrites the Secret with this password; **empty + Secret exists** → preserved untouched (no-op); **empty + Secret absent** → the Job generates a random 32-char password once. The password is frozen into the PVC at first init and never re-read afterwards, so set `init.password` explicitly **only** at first init or for a deliberate reset, and it must match the value baked into the PVC. See [Credential bootstrap: how the Secrets are created](#credential-bootstrap-how-the-secrets-are-created).
- `init.restore.enabled` (default `false`) — the **sole on/off gate** for the restore feature. When `false`, nothing restore-related renders (no init container, no ConfigMap, no `tcpg-restore-credential` Secret), regardless of the other fields below.
- `init.restore.baseUrl` + `init.restore.path` — both **required** when `restore.enabled` is `true`. Concatenated verbatim into the dump URL. Both are non-secret (plain env vars in the pod spec) — do **not** embed credentials in the URL.
- `init.restore.auth.type` ∈ `none | basic | bearer`:
  - `none` — no auth header.
  - `basic` — `value` is `user:pass`, passed as `curl -u`.
  - `bearer` — `value` is the token, sent as `Authorization: Bearer <value>`.
- `init.restore.auth.value` — the only secret. Stored in a dedicated **chart-rendered** Secret named `tcpg-restore-credential` (separate from `tcpg-pg-credential` that Postgres reads — prevents the dump auth from leaking into the Postgres container env). Unlike `tcpg-pg-credential`, this is a plain user-supplied value rendered straight from values (no bootstrap Job, no generation), so it is GitOps-safe as-is.
- `init.restore.auth.existingSecret.{name,key}` — alternative: reference a pre-existing Secret instead of setting `auth.value` inline. Mutually exclusive with inline (template validation fails hard if both are set). `key` has **no default** — set it explicitly; it is required whenever `existingSecret.name` is set.
- `init.restore.insecureSkipTlsVerify` (default `false`) — `curl -k` for the download. Use only for internal / self-signed hosts.

#### Credential bootstrap: how the Secrets are created

The `tcpg-pg-credential` (and the MinIO `minio-s3-credential`) Secrets are **not** rendered by the chart templates. Instead a **pre-install / pre-upgrade Helm-hook `Job`** runs `kubectl` against the **live cluster** to create or update each Secret. This is one mechanism that behaves identically under plain `helm`, Flux `HelmRelease`, and ArgoCD — there is **no `lookup`** (which is blind under `helm template` / GitOps) and **no `ignoreDifferences` hatch** to configure.

How it works:

- A `Job` at hook weight `0` (`helm.sh/hook: pre-install,pre-upgrade`) generates/writes the Secret before the StatefulSet rolls. ArgoCD auto-converts the Helm hook to a `PreSync` Job; Flux and plain Helm run it as a normal pre-install/pre-upgrade hook. The Job uses **only** `helm.sh/hook` (no `argocd.argoproj.io/hook` — adding an Argo hook would suppress the Helm-hook path and break plain Helm/Flux, since a Job spec is immutable).
- The Job needs RBAC to manage the Secret. The chart **auto-creates** a `ServiceAccount` + `Role` + `RoleBinding` so they exist before the Job. The Role can `create` secrets and `get/update/patch` only the named credential Secrets.
- **Ordering — RBAC before Job.** Plain Helm and Flux order hooks by `helm.sh/hook-weight` (RBAC at `-5`, Job at `0`). ArgoCD **ignores** `helm.sh/hook-weight` and orders the converted `PreSync` resources by `argocd.argoproj.io/sync-wave` instead, so both annotations are set: the RBAC carries `sync-wave: "-5"` and the Jobs `sync-wave: "0"`. Keep both — they target different engines.
- **The created Secret is deliberately *not* tagged as app-owned.** The Job stamps it with only the two honest identity labels — `app.kubernetes.io/name` and `app.kubernetes.io/component` — and deliberately **omits** `app.kubernetes.io/instance`, `app.kubernetes.io/managed-by`, and `helm.sh/chart`. It also annotates the Secret with `argocd.argoproj.io/sync-options: Prune=false` and `argocd.argoproj.io/compare-options: IgnoreExtraneous`. **Why:** `app.kubernetes.io/instance` is ArgoCD's *default* resource-tracking label, so a default-config controller would otherwise adopt this out-of-band Secret as app-owned, notice it is absent from the rendered/desired manifest set, and **auto-prune** it on the next sync — the cause of the "fine on deploy, gone hours later" Postgres/MinIO auth outage. `Prune=false` means ArgoCD never deletes it; `IgnoreExtraneous` means it is never even flagged `OutOfSync`. Both annotations are no-ops under plain Helm/Flux, and dropping the tracking labels stops a default-config controller from adopting it in the first place (belt-and-suspenders).
- Render fails closed: the static fields (DB/user/host/port, S3 endpoint, etc.) are computed at render time and the existing `required`/`fail` validations still run, so misconfiguration is caught at `helm template` time.

The DB password is **three-state** (see `init.password` above): an explicit value is written/overwritten; an empty value with an existing Secret is preserved untouched; an empty value with no Secret generates a random 32-char password once. Because the password is frozen into the PVC at first init, the generated charset is URL-safe and any user-supplied special-character password is URL-encoded into `POSTGRES_URI`.

> **Static fields are always re-applied; only the credential is preserved.** On every run the Job re-applies the static connection fields (DB / user / host / port / URI) from the current rendered values, preserving only the existing password when `init.password` is empty. Setting `init.password` explicitly rewrites **all** connection fields in the Secret (DB / USER / HOST / PORT / URI) from current values, not just the password — so ensure they still match the **PVC-frozen** database, since the password itself is frozen at first init and is never re-read.

> **Teardown caveat.** The credential Secrets are created by `kubectl` from inside the hook Job, so they are **not** Helm- or Argo-managed objects — and the minimal labels + `Prune=false` / `IgnoreExtraneous` annotations described above are what *guarantee* that (without them, ArgoCD's default `app.kubernetes.io/instance` tracking would adopt and prune the Secret). They are **not** removed by `helm uninstall` or an ArgoCD app delete. Reinstalling into the same namespace finds the leftover Secret and reuses its credential (the preserve branch). To fully reset, delete the Secret manually (`kubectl -n <ns> delete secret <name>`).

**Pin the password** by setting `init.password` (only at first init or a deliberate reset — it must match the value already baked into the PVC).

**Recovery if drift already happened** (e.g. from an older `lookup`-based chart): the live PVC still holds the *original* password. Set `init.password` to the value currently in the live Secret so the Job stops changing it. If the data is disposable or dump-restorable, you can instead delete the StatefulSet **and** its PVC so a fresh first-init bakes in the now-stable password.

Override the bootstrap image with `secretBootstrap.image.{repository,tag,pullPolicy}` (default `alpine/k8s:1.31.1` — it ships a shell plus `kubectl`, which the Job's container script needs).

**Using an externally-managed Secret for dump auth.** Instead of inlining `restore.auth.value`, reference a pre-existing Secret — useful when the credential is managed by SealedSecrets, External Secrets Operator, Vault, etc.

Create (or have your operator create) the Secret in the same namespace:

```bash
# For basic auth — value format is "user:pass"
kubectl -n <namespace> create secret generic dump-credentials \
  --from-literal=RESTORE_AUTH_VALUE='dump-user:dump-password-here'

# For bearer — value is the raw token
kubectl -n <namespace> create secret generic dump-credentials \
  --from-literal=RESTORE_AUTH_VALUE='eyJhbGciOi...'
```

Then in values:

```yaml
init:
  restore:
    enabled: true
    baseUrl: "https://dumps.example.internal:8080"
    path: "/path/to/init-db.dump"
    auth:
      type: basic      # or bearer — must match the value's format
      # omit `value` when using existingSecret below
      existingSecret:
        name: dump-credentials
        key: RESTORE_AUTH_VALUE   # required — must match the key in your Secret
```

Inline (`restore.auth.value`) and external (`restore.auth.existingSecret.name`) are mutually exclusive — the template fails at render time if both are set.

**Supported dump formats** (auto-detected in the postgres container): plain `.sql`, gzipped `.sql.gz`, and `pg_dump -Fc` custom format. Detection uses `gunzip -t` and `pg_restore -l` — no `file` dependency.

**Restore semantics**: the restore runs via `docker-entrypoint-initdb.d`, so it happens exactly once — on first boot with an empty PGDATA. A sentinel file (`$PGDATA/.restore_complete`) is written only after full success; if it's missing on a populated PGDATA (partial restore), an entrypoint wrapper refuses to start and logs instructions to delete the PVC and reinstall. On success, the downloaded dump is removed from the `emptyDir` to free node disk.

### `persistence` — PVC

- `persistence.enabled` (default `true`) — when `false`, uses an `emptyDir` (data lost on pod restart). Only useful for ephemeral testing.
- `persistence.storageClass` (default `local-path`) — the tc-cluster node-local provisioner; it ignores `size` (node disk is the real limit).
- `persistence.size` (default `1Gi`; ignored by `local-path`).
- `persistence.accessModes` (default `[ReadWriteOnce]`).

### `service`

- `service.type` (default `ClusterIP`), `service.port` (default `5432`). Single-replica chart, so no headless service; apps connect via the ClusterIP DNS name.

### `resources`

Standard Kubernetes resource requests/limits. Defaults to `requests: {cpu: 0.1, memory: 1Gi}` / `limits: {cpu: 2, memory: 1Gi}` (memory request == limit keeps Postgres in the Guaranteed QoS class; CPU is burstable for dump restore / ad-hoc queries). Override for larger workloads.

### Scheduling: `affinity`, `tolerations`, `nodeSelector`

Plain passthrough to pod spec. `tolerations` and `nodeSelector` default to empty. `affinity` defaults to a RAID-avoiding `nodeAffinity` (keeps disposable alpha databases off the RAID node pool, which is reserved for prod) — override or clear it if you need different scheduling.

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
- `initImage.{repository,tag,pullPolicy}` — curl image used by the dump-download init container (default `curlimages/curl:8.11.1`). Only runs when `init.restore.enabled` is `true`.

## Connecting

The chart renders a consumer-facing Secret `tcpg-pg-credential` with everything an app needs. Keys:

| Key                 | Value                                                           |
|---------------------|-----------------------------------------------------------------|
| `POSTGRES_HOST`     | `tcpg.<namespace>.svc.cluster.local`                  |
| `POSTGRES_PORT`     | `5432` (or `service.port` override)                             |
| `POSTGRES_DB`       | `init.database`                                                 |
| `POSTGRES_USER`     | `init.username`                                                 |
| `POSTGRES_PASSWORD` | `init.password` (or the 32-char autogen value)                 |
| `POSTGRES_URI`      | `postgres://<user>:<pass>@<host>:<port>/<db>` (URL-encoded)     |

App pods can bind the whole thing via `envFrom`:

```yaml
envFrom:
  - secretRef:
      name: tcpg-pg-credential
```

Fetch the generated password manually:

```bash
kubectl -n <namespace> get secret tcpg-pg-credential \
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

Dragonfly Service DNS: `dragonfly.<namespace>.svc.cluster.local:6379`.

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

S3-compatible object store from the upstream Bitnami chart, pulled via OCI. Standalone (single-node) topology only — the baked-in `chart/values.yaml` defaults pin `mode: standalone` and a single replica.

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

S3 API DNS: `minio.<namespace>.svc.cluster.local:9000`. Console (UI) listens on `:9001` on the same Service.

#### Generated S3 credentials

The parent chart owns MinIO's credentials. When `minio.enabled: true` a **pre-install/pre-upgrade Helm-hook Job** (`templates/minio/secret-bootstrap-job.yaml`) creates a single Kubernetes Secret named **`minio-s3-credential`** (the value of `minio.auth.existingSecret`) against the live cluster, with four keys:

| Key | Description |
| --- | --- |
| `S3_ENDPOINT_URL` | S3 API URL — derived as `<endpointScheme>://<minio.ingress.hostname>`, or set verbatim via `minioConfig.endpointUrl`. |
| `S3_REGION` | S3 region (`minioConfig.region`, default `us-east-1`). |
| `S3_ACCESS_KEY_ID` | Access key id (`minioConfig.accessKeyId`, default `minio`). Not secret, not random. |
| `S3_SECRET_ACCESS_KEY` | Secret key. Empty `minioConfig.secretAccessKey` → generated once and preserved; set it to pin/rotate (the Job overwrites). |

The bootstrap Job runs the same way under plain `helm`, Flux `HelmRelease`, and ArgoCD (which converts the Helm hook to a `PreSync` Job) — there is **no `lookup`** and **no `ignoreDifferences` hatch** to configure. The chart auto-creates the RBAC the Job needs (see [Credential bootstrap: how the Secrets are created](#credential-bootstrap-how-the-secrets-are-created)). The `S3_SECRET_ACCESS_KEY` is three-state: explicit value → written/overwritten; empty + Secret exists → preserved; empty + Secret absent → generated once.

**Rotating the S3 secret key.** MinIO re-reads its root credentials on every start, so this key is rotatable in place (the Postgres password is not — it's frozen into the PVC at first init). Set `minioConfig.secretAccessKey` to the new value and re-run (plain `helm upgrade`) or sync (GitOps); the Job overwrites the Secret with the new key. Do **not** edit the Secret by hand under GitOps — the next sync's Job would overwrite a hand-edited value only when an explicit `secretAccessKey` is set, so always rotate through the value.

After rotating, restart MinIO and any consuming app pods so they pick up the new key (`envFrom` does not refresh a running pod).

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
  secretAccessKey: ""       # empty → generated once by the bootstrap Job; set to pin/rotate
  region: us-east-1         # S3_REGION
  endpointScheme: https     # scheme used when deriving the endpoint from ingress.hostname
  endpointUrl: ""           # explicit S3_ENDPOINT_URL; empty → derived from ingress.hostname
  maxRequestBodyBytes: 104857600  # default 100 MiB; per-request body cap in bytes; "" → no Middleware rendered
  memRequestBodyBytes: 52428800   # default 50 MiB; bytes buffered in memory before spilling to disk; "" → Traefik default (1 MiB)
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

The baked-in `chart/values.yaml` defaults already wire all of this with a 100 MiB / 50 MiB pair, so the body cap is on by default whenever `minio.enabled: true`. Set `minioConfig.maxRequestBodyBytes: ""` to disable it.

**Rotation caveat.** Changing `minioConfig.secretAccessKey` (or the access key id) rewrites the Secret but does **not** restart pods automatically — you must manually restart both the MinIO pod(s) and the app pods for the new credentials to take effect. Any previously-issued presigned URLs break once the key rotates.

**Bitnami image-distribution caveat (Aug 2025).** Bitnami moved every public `bitnami/*` Docker repo to subscription-only (Bitnami Secure Images). The chart's pinned defaults reference those gated repos; a vanilla install would 401 on every image pull.

`chart/values.yaml` works around this by overriding all four image repositories the chart can pull (`image`, `clientImage`, `console.image`, `defaultInitContainers.volumePermissions.image`) to their `bitnamilegacy/*` equivalents — a frozen free mirror of the pre-cutover images. Tags are inherited from the chart's own pinned defaults; the same tags exist on bitnamilegacy, so versions stay in lockstep with whatever Chart.yaml's pinned `version:` was published with.

Trade-off: `bitnamilegacy/*` is frozen — no future security patches. Acceptable for alpha; **not** for production. For prod, either restore `image.repository: bitnami/<name>` (and the other three) and supply pull secrets for a Bitnami Secure Images subscription, or migrate off the Bitnami chart entirely (e.g. `minio/operator`).

## Caveats

- **Single replica, no backup, no WAL archiving.** For alpha/dev only — not production-grade.
- **No headless Service.** Per-pod DNS (`pod-0.svc.ns`) won't resolve. Apps must connect via the ClusterIP service name.
- **Partial restore recovery is manual.** If restore fails mid-way, delete the PVC and reinstall — the wrapper will tell you so in logs.
- **Benign `chmod: /var/run/postgresql: Operation not permitted` on pod start.** The official postgres image's entrypoint unconditionally tries `chmod 03775 /var/run/postgresql`. With `readOnlyRootFilesystem: true` we mount an `emptyDir` there (owned by `root:<fsGroup>` via k8s), and the non-root pg user can't chmod it. The entrypoint itself swallows the exit code (`|| :`) and the socket is still created correctly — it's a cosmetic line. Silencing it would require running an init container as root, which isn't worth the hardening tradeoff.
