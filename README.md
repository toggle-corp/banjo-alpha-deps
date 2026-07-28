# banjo-alpha-deps

Helm umbrella chart bundling the stateful dependencies our alpha environments need:

| Component | What it is | Source |
| --- | --- | --- |
| `tcpg` | Single-replica Postgres with an optional one-shot restore from a dump URL on first boot | in-tree (`chart/templates/tcpg/`) |
| `minio` | S3-compatible object storage | Bitnami chart (OCI) |
| `garage` | S3-compatible object storage (lightweight alternative) | Deuxfleurs chart, vendored into `chart/charts/garage/` |
| `dragonfly` | Redis/Memcached-compatible in-memory store | DragonflyDB chart (OCI) |

Every component is **opt-in** — all four default to `enabled: false`.

The chart's defaults are tuned for Togglecorp's alpha cluster (modest resource
requests, `local-path` storage, fixed resource names, a RAID-avoiding
nodeAffinity rule). It is published here because it's generally useful to read,
not because it's a general-purpose product — expect to adjust `chart/values.yaml`
for any other cluster.

## Install

```bash
git clone https://github.com/toggle-corp/banjo-alpha-deps.git
helm install mydeps ./banjo-alpha-deps/chart -f values.yaml
```

Full option reference, examples, and per-component notes: **[docs/usages.md](docs/usages.md)**.

## Generated credentials

Credential Secrets that you leave empty are created by a **pre-install/pre-upgrade
Helm-hook `Job`** that talks to the live cluster with `kubectl` — no `lookup`, no
ArgoCD `ignoreDifferences`. The same mechanism works under plain Helm, Flux
`HelmRelease`, and ArgoCD. Three-state logic per credential:

- explicit value → written (and overwritten on upgrade)
- empty + Secret already exists → preserved, no-op
- empty + Secret absent → generated once

See the "generated secrets" sections of [docs/usages.md](docs/usages.md) for which
credentials are write-once (baked into the PVC at init) versus rotatable.

## Development

```bash
helm dep build chart          # fetch OCI subcharts (tarballs are gitignored)
helm unittest chart           # unit tests — required for any chart change
./prepush.sh                  # pre-commit + shellcheck + Docker integration suite
```

`chart/tests/integration/run.sh` spins up real Postgres containers to exercise the
restore pipeline across plain SQL, gzipped SQL, and `pg_dump -Fc` dumps, plus the
corrupt-dump failure path. Takes ~30-40s and needs Docker.

Conventions for contributors (tests + docs required per chart change, the
bootstrap-Job secret pattern) are in [CLAUDE.md](CLAUDE.md).
