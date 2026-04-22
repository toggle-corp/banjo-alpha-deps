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

The chart ships a ready-to-use base for alpha deploys at `chart/values/alpha.yaml`: modest resource requests, `local-path` storage, a nodeAffinity rule that avoids RAID nodes, and `dumpInsecureSkipTlsVerify: true` for internal dump hosts. It does **not** set credentials or a dump URL — layer your own overlay on top:

```bash
helm install mydb oci://gitea.local.togglecorp.com/tc-infra/tcpg --version 0.0.1 \
  -f chart/values/alpha.yaml \
  -f my-overlay.yaml
```

Where `my-overlay.yaml` provides per-install specifics (password, dump source, etc.):

```yaml
auth:
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

auth:
  # Inline password (stored in the chart-managed Secret). Leave empty to
  # auto-generate a 32-char random password, preserved across upgrades via lookup.
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

### `auth` — database credentials and restore

- `auth.database` (default `postgres`) — DB created by the entrypoint.
- `auth.username` (default `postgres`) — superuser created by the entrypoint.
- `auth.password` — if empty, a random 32-char password is generated on first install. It's preserved across upgrades via a `lookup` on the existing Secret, so setting it empty is safe for rotation-free operation.
- `auth.dumpBaseUrl` + `auth.dumpPath` — optional. Concatenated verbatim into the dump URL. Empty `dumpPath` disables restore. Both are non-secret (plain env vars in the pod spec) — do **not** embed credentials in the URL.
- `auth.dumpAuth.type` ∈ `none | basic | bearer`:
  - `none` — no auth header.
  - `basic` — `value` is `user:pass`, passed as `curl -u`.
  - `bearer` — `value` is the token, sent as `Authorization: Bearer <value>`.
- `auth.dumpAuth.value` — the only secret. Stored in a dedicated chart-managed Secret named `<release>-tcpg-load-credential` (separate from the main `<release>-tcpg-credential` that Postgres reads — prevents the dump auth from leaking into the Postgres container env).
- `auth.existingDumpAuthSecret.{name,key}` — alternative: reference a pre-existing Secret instead of setting `dumpAuth.value` inline. Mutually exclusive with inline; template validation fails hard if both are set.
- `auth.dumpInsecureSkipTlsVerify` (default `false`) — `curl -k` for the download. Use only for internal / self-signed hosts.

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
auth:
  dumpBaseUrl: "https://dumps.example.internal:8080"
  dumpPath: "/path/to/init-db.dump"
  dumpAuth:
    type: basic      # or bearer — must match the value's format
    value: ""        # leave empty or exclude when using existingDumpAuthSecret
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
- `containerSecurityContext` — applied to every container (init + main). Defaults satisfy the restricted Pod Security Standard (`allowPrivilegeEscalation: false`, `drop: [ALL]`).

Override only if you know why.

### Images

- `image.{repository,tag,pullPolicy,pullSecrets}` — main Postgres image (default `postgres:18.1`).
- `initImage.{repository,tag,pullPolicy}` — curl image used by the dump-download init container (default `curlimages/curl:8.11.1`). Only runs when `auth.dumpPath` is set.

## Connecting

Connection string (default DB / user):

```
postgres://postgres:<password>@<release>-tcpg.<namespace>.svc.cluster.local:5432/postgres
```

Fetch the generated password:

```bash
kubectl -n <namespace> get secret <release>-tcpg-credential \
  -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d
```

## Caveats

- **Single replica, no backup, no WAL archiving.** For alpha/dev only — not production-grade.
- **No headless Service.** Per-pod DNS (`pod-0.svc.ns`) won't resolve. Apps must connect via the ClusterIP service name.
- **Partial restore recovery is manual.** If restore fails mid-way, delete the PVC and reinstall — the wrapper will tell you so in logs.
