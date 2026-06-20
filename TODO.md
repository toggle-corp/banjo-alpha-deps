# TODO

Helm chart: simple Postgres replacement for Bitnami chart.

## Scope (decided)

- Single replica, no scaling, no backup, no WAL archiving.
- Official `postgres` image.
- DB name / user (default `postgres`) / password supplied via Secret.
- Optional one-shot restore from a URL containing creds (`https://user:pass@host/dump`).
  - Empty URL → empty DB (not required, fail-open).
  - Support all common formats: plain `.sql`, `.sql.gz`, and `pg_dump -Fc` custom dumps.
  - Format detection inside postgres container using `gunzip -t` and `pg_restore -l` as authoritative parsers (no `file` dep).
  - Init container is curl-only; download to `emptyDir`, postgres container handles detection + restore.
- Service: ClusterIP only (single replica, app pods just need a stable DNS name; skip headless).

## Tasks

- [x] **Fix `_helpers.tpl` / `secrets.yaml`** — `stringData`, lookup-preserved autogen password, all four env keys.
- [x] **Convert Deployment → StatefulSet** — fixed stray `{{- end }}`, pod-level securityContext (999/999/999, runAsNonRoot), `envFrom` wired, `PGDATA` set to subdirectory to avoid lost+found issues.
- [x] **Add `Service`** — ClusterIP, port 5432.
- [x] **Add `PodDisruptionBudget`** — defaults to disabled (single-replica + `minAvailable: 1` blocks node drains; opt-in).
- [x] **Restore pipeline** — ConfigMap script + curl initContainer, both gated on non-empty `auth.dumpPath`. Effective URL is `auth.dumpBaseUrl + auth.dumpPath` (both non-secret, plain env vars). Auth is separate: `auth.dumpAuth.type` ∈ {`none`, `basic`, `bearer`}. For `basic`, `dumpAuth.value` is `user:pass` passed via `curl -u`; for `bearer`, the token is sent as `Authorization: Bearer …`. `dumpAuth.value` is the only secret — inline (chart-managed) or via `auth.existingDumpAuthSecret.{name,key}` pointing at an externally-managed Secret. Template-time validation fails hard on unknown auth type, missing value source, or both sources set. InitContainer skips download when `PGDATA/PG_VERSION` already exists.
- [x] **PVC default** → `ReadWriteOnce`.
- [x] **values.yaml shape** — finalized.
- [x] **`helm lint` / `helm template` clean** — both default and `auth.dumpPath` + PDB enabled paths render valid YAML.
- [x] **`helm unittest` suites** — 6 suites / 28 tests covering all conditionals, hardening, restore-script + wrapper content. Run with `helm unittest .` (requires the `helm-unittest` plugin).
- [x] **`.pre-commit-config.yaml`** — hygiene hooks (trailing whitespace, EOF, merge conflicts, large files, mixed line endings, check-yaml excluding `templates/`) plus local `helm lint`, `helm unittest`, and `shellcheck` hooks. Run manually with `pre-commit run --all-files`.
- [x] **Extract scripts to `scripts/`** — `10-restore.sh` and `entrypoint-wrapper.sh` are now standalone shell files embedded into the ConfigMap via `.Files.Get`. Wrapper reads `$PG_PVC_NAME` (set by the StatefulSet) to template the recovery message. Pure shell → editor support, shellcheck, direct testability.
- [x] **Docker integration test** — `tests/integration/run.sh`. Spins up `postgres:18.1` as a "factory" to generate sample dumps in plain SQL / gzipped SQL / `pg_dump -Fc` formats, then for each one runs the real entrypoint wrapper + restore script and verifies the data lands. Also tests the failure path: broken dump → pod exits non-zero → restart → wrapper refuses with the recovery message containing `$PG_PVC_NAME`. Takes ~30–40s. Not wired into pre-commit (too slow); run manually: `./tests/integration/run.sh`.
- [x] **`prepush.sh`** — single entry point that runs everything: `pre-commit run --all-files`, explicit `shellcheck` on all `.sh` files (covers untracked ones that pre-commit skips), then the Docker integration suite. Run before pushing: `./prepush.sh`.
- [x] **Add support for annotations for argo/helm hooks** — `commonAnnotations` value applied to every resource's metadata (StatefulSet, Service, PVC, PDB, Secret, ConfigMap). Enables Argo sync-waves, Helm hooks, etc. Covered by `tests/common_annotations_test.yaml`.
- [ ] Setup CI using woodpecker for running pre-push.sh checks
- [x] Auto generate pg credentials secret for consumers. Renamed `<fullname>-credential` → `<fullname>-pg-credential`; added `POSTGRES_HOST`, `POSTGRES_PORT`, `POSTGRES_URI` (URL-encoded) keys. Apps bind via `envFrom`. Helper renamed `tcpg.secretname` → `tcpg.pgSecretName`. Tests + docs updated.
- [x] Multi-stack umbrella chart `banjo-alpha-deps`. tcpg stays DIY under `templates/tcpg/`; garage vendored from Deuxfleurs at `charts/garage/` (refresh via `./scripts/vendor-garage.sh`); dragonfly pulled from OCI `ghcr.io/dragonflydb/dragonfly/helm@v1.38.0`. All three gated via `<name>.enabled`. Resource names stay `<release>-tcpg-*` regardless of umbrella name. Tests rewritten to `tcpg.*` value paths.
- [ ] Setup renovatebot for dependencies update tracking
- [ ] **Verify Dragonfly OCI dep works under ArgoCD.** The chart is pulled from `oci://ghcr.io/dragonflydb/dragonfly/helm` and the `.tgz` is `.gitignore`d, so ArgoCD's repo-server has to run `helm dependency build` at sync time. Requires: (1) network egress from `argocd-repo-server` to `ghcr.io`, (2) OCI-enabled repo-server (default since v2.4). If the tc cluster blocks egress or strips OCI support, flip `charts/*.tgz` out of `.gitignore` and commit the tarball for fully-offline sync.
- [ ] Setup bootstrapping for garagehq to support declarative config
    ```
    garagaBootstraper:
      bukets:
        - name: media
        - name: static
          acl: public  <-- default is private
      credentialFromSecret:
      credential:
        access_key:
        secret_key:
    ```
    - Define hook job (for both argocd and helm)
        - auto create bucket
        - auto create secrets
            - Generate a secret from root chart and pass it to the garagahq chart
- [x] Merge values/alpha.yaml -> values.yaml

## Review follow-ups (2026-04-22)

Chart hasn't been deployed yet, so no migration/compat concerns.

### Correctness / security

- [x] **Stop leaking `DUMP_AUTH_VALUE` into the main Postgres container env.** Split into a dedicated `<fullname>-load-credential` Secret (separate from `<fullname>-credential`). Init container's `secretKeyRef` points at the new one; main container's `envFrom` only pulls the pg-credential Secret.
- [x] **Add test** asserting the main container doesn't reference the load-credential Secret or expose `DUMP_AUTH_VALUE` (`statefulset_test.yaml` — "main container envFrom does not reference the load-credential secret").

### Test gaps

- [x] Default-false test for `dumpInsecureSkipTlsVerify`. Dropped the misleading `matchRegex 'INSECURE="-k"'` assertion from the positive test too — that string always appears in the script (inside an `if`), so the env-var value is the real toggle.

### Polish

- [x] **URL concat validation** — template-time XOR check: base ends with `/` XOR path starts with `/`. Emits `fail` with clear messages for both violations. Covered by two `failedTemplate` tests + a positive test for the non-default slash placement.
- [x] `chart/scripts/10-restore.sh` — `du -sh "$DUMP"`.
- [x] `CLAUDE.md` — docs-update convention expanded with the "where" (docs/usages.md) and exceptions.
- [x] `scripts/local-real-testing.sh` — `echo "Aborted."` moved inside the `set +x` region.

### Follow-up (not blocking)

- [x] `containerSecurityContext.readOnlyRootFilesystem: true` enabled by default. Added `emptyDir` mounts for `/tmp` (init + main) and `/var/run/postgresql` (main, unix socket). Integration test now passes `--read-only --tmpfs /tmp --tmpfs /var/run/postgresql` to match. Unittest asserts the flag + mounts on both containers.

## Review follow-ups (2026-04-23)

From review of `b9a228b feat: improvements - 02`.

### Correctness / security

- [x] **Validate `dumpBaseUrl` when `dumpPath` is set.** Template now fails with "auth.dumpBaseUrl is required when auth.dumpPath is set" before the slash-XOR check. Covered by a failedTemplate test.
- [x] **Quote the `INSECURE` curl flag safely.** Replaced `curl $INSECURE …` word-splitting with a `curl_download()` helper that branches on `$DUMP_INSECURE_SKIP_TLS_VERIFY` and forwards `"$@"`.

### Polish

- [x] `existingDumpAuthSecret.name` + `dumpAuth.type: none` now fails template with a clear message. Covered by a failedTemplate test.
- [x] `docs/usages.md` external-secret example: dropped `value: ""` in favor of an "omit `value`" comment.
- [x] Revisit `/dump` `readOnly: true` on the main container. Decision: keep RW. Restore runs in the main container (via `/docker-entrypoint-initdb.d`), so cleanup has to happen there too — init-container cleanup would run before the restore, not after. Added a comment at the mount site explaining the intent.

### Test gaps

- [x] Added a failedTemplate test for the "dumpPath set, dumpBaseUrl empty" case in `statefulset_test.yaml`.

## Known caveats

- Partial-restore failures: detected via a sentinel file (`$PGDATA/.restore_complete`) written only on full restore success. An entrypoint wrapper script refuses to start Postgres if the sentinel is missing on a populated PGDATA, with a clear log message instructing the operator to delete the PVC and reinstall. No silent partial-DB state.
- `serviceName` in the StatefulSet points at the regular ClusterIP Service (no headless). Per-pod DNS (`pod-0.svc.ns`) won't resolve, but apps connect via the ClusterIP name anyway.
