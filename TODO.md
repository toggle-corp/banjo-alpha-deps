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
- [x] **Restore pipeline** — ConfigMap script + curl initContainer, both gated on non-empty `auth.dumpUrl`. InitContainer skips download when `PGDATA/PG_VERSION` already exists.
- [x] **PVC default** → `ReadWriteOnce`.
- [x] **values.yaml shape** — finalized.
- [x] **`helm lint` / `helm template` clean** — both default and `auth.dumpUrl` + PDB enabled paths render valid YAML.
- [x] **`helm unittest` suites** — 6 suites / 28 tests covering all conditionals, hardening, restore-script + wrapper content. Run with `helm unittest .` (requires the `helm-unittest` plugin).
- [x] **`.pre-commit-config.yaml`** — hygiene hooks (trailing whitespace, EOF, merge conflicts, large files, mixed line endings, check-yaml excluding `templates/`) plus local `helm lint`, `helm unittest`, and `shellcheck` hooks. Run manually with `pre-commit run --all-files`.
- [x] **Extract scripts to `scripts/`** — `10-restore.sh` and `entrypoint-wrapper.sh` are now standalone shell files embedded into the ConfigMap via `.Files.Get`. Wrapper reads `$PG_PVC_NAME` (set by the StatefulSet) to template the recovery message. Pure shell → editor support, shellcheck, direct testability.
- [x] **Docker integration test** — `tests/integration/run.sh`. Spins up `postgres:18.1` as a "factory" to generate sample dumps in plain SQL / gzipped SQL / `pg_dump -Fc` formats, then for each one runs the real entrypoint wrapper + restore script and verifies the data lands. Also tests the failure path: broken dump → pod exits non-zero → restart → wrapper refuses with the recovery message containing `$PG_PVC_NAME`. Takes ~30–40s. Not wired into pre-commit (too slow); run manually: `./tests/integration/run.sh`.
- [x] **`prepush.sh`** — single entry point that runs everything: `pre-commit run --all-files`, explicit `shellcheck` on all `.sh` files (covers untracked ones that pre-commit skips), then the Docker integration suite. Run before pushing: `./prepush.sh`.

## Known caveats

- Partial-restore failures: detected via a sentinel file (`$PGDATA/.restore_complete`) written only on full restore success. An entrypoint wrapper script refuses to start Postgres if the sentinel is missing on a populated PGDATA, with a clear log message instructing the operator to delete the PVC and reinstall. No silent partial-DB state.
- `serviceName` in the StatefulSet points at the regular ClusterIP Service (no headless). Per-pod DNS (`pod-0.svc.ns`) won't resolve, but apps connect via the ClusterIP name anyway.
