#!/usr/bin/env bash
# Integration test: spins up the real postgres image with our scripts mounted,
# verifies restore works for plain SQL, gzipped SQL, and pg_dump custom format,
# then verifies the wrapper refuses to start after a broken restore.
#
# Also covers the three things unit tests cannot, because they are runtime
# behaviour of the image rather than rendered YAML:
#   - the parameters the chart renders are actually accepted by Postgres (a bad
#     one is FATAL at startup, and on a first install that wedges the PVC)
#   - /dev/shm sizing decides whether parallel queries run or hard-error
#     (the preStop hook and shm.size exist because of these)
#   - preStop shuts down cleanly with a client still attached, so the next
#     start does not crash-recover
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART_DIR="$(cd "$HERE/../.." && pwd)"
SCRIPTS="$CHART_DIR/scripts"

PG_IMAGE="${PG_IMAGE:-postgres:18.1}"
TMPDIR="$(mktemp -d -t tcpg-integration-XXXXXX)"

CONTAINERS=()
cleanup() {
  set +e
  for c in "${CONTAINERS[@]:-}"; do
    docker rm -fv "$c" >/dev/null 2>&1 || true
  done
  if [ -d "$TMPDIR" ] && docker image inspect "$PG_IMAGE" >/dev/null 2>&1; then
    docker run --rm --user 0:0 \
      -v "$TMPDIR:/work" \
      --entrypoint /bin/sh \
      "$PG_IMAGE" \
      -c 'chmod -R a+rwX /work' >/dev/null 2>&1 || true
  fi
  rm -rf "$TMPDIR"
}
trap cleanup EXIT

# Track containers created for cleanup.
track() { CONTAINERS+=("$1"); }

run_pg() {
  # Foreground (returns exit code) — used for the failure path.
  local name="$1" pgdata="$2" dump_dir="$3"
  track "$name"
  docker run --rm --name "$name" \
    -e POSTGRES_PASSWORD=secret \
    -e POSTGRES_USER=postgres \
    -e POSTGRES_DB=testdb \
    -e PGDATA=/var/lib/postgresql/data/pgdata \
    -e PG_PVC_NAME=fake-pvc-name \
    --read-only \
    --tmpfs /tmp \
    --tmpfs /var/run/postgresql \
    -v "$pgdata:/var/lib/postgresql/data" \
    -v "$dump_dir:/restore" \
    -v "$SCRIPTS/10-restore.sh:/docker-entrypoint-initdb.d/10-restore.sh:ro" \
    -v "$SCRIPTS/entrypoint-wrapper.sh:/etc/postgres-wrapper/entrypoint-wrapper.sh:ro" \
    --entrypoint /bin/sh \
    "$PG_IMAGE" \
    /etc/postgres-wrapper/entrypoint-wrapper.sh postgres
}

start_pg_detached() {
  local name="$1" pgdata="$2" dump_dir="$3"
  track "$name"
  docker run -d --name "$name" \
    -e POSTGRES_PASSWORD=secret \
    -e POSTGRES_USER=postgres \
    -e POSTGRES_DB=testdb \
    -e PGDATA=/var/lib/postgresql/data/pgdata \
    -e PG_PVC_NAME=fake-pvc-name \
    --read-only \
    --tmpfs /tmp \
    --tmpfs /var/run/postgresql \
    -v "$pgdata:/var/lib/postgresql/data" \
    -v "$dump_dir:/restore" \
    -v "$SCRIPTS/10-restore.sh:/docker-entrypoint-initdb.d/10-restore.sh:ro" \
    -v "$SCRIPTS/entrypoint-wrapper.sh:/etc/postgres-wrapper/entrypoint-wrapper.sh:ro" \
    --entrypoint /bin/sh \
    "$PG_IMAGE" \
    /etc/postgres-wrapper/entrypoint-wrapper.sh postgres >/dev/null
}

wait_ready() {
  local name="$1"
  for _ in $(seq 1 60); do
    # Must be a TCP check. While the entrypoint runs initdb and
    # /docker-entrypoint-initdb.d (i.e. the restore), it starts a *temporary*
    # server with `-c listen_addresses=''` — reachable over the unix socket but
    # not TCP. A socket-based pg_isready therefore reports ready mid-restore, and
    # the assertions below then race the restore they are meant to be checking.
    # Only the final server listens on TCP. The chart's own probes do the same.
    if docker exec "$name" pg_isready -U postgres -d testdb -h 127.0.0.1 -p 5432 >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  echo "FAIL: $name never became ready" >&2
  docker logs "$name" >&2 || true
  return 1
}

# Generate sample dumps in all three formats using a temp postgres.
echo "==> Generating sample dumps (~10s)..."
mkdir -p "$TMPDIR/dumps"
track tcpg-factory
docker run -d --name tcpg-factory \
  -e POSTGRES_PASSWORD=temp \
  -e POSTGRES_DB=src \
  "$PG_IMAGE" >/dev/null
wait_ready tcpg-factory
docker exec tcpg-factory psql -U postgres -d src -c \
  "CREATE TABLE w (id int primary key, n text); INSERT INTO w VALUES (1,'alpha'),(2,'beta'),(3,'gamma');" >/dev/null
docker exec tcpg-factory pg_dump -U postgres src      > "$TMPDIR/dumps/sample.sql"
docker exec tcpg-factory pg_dump -U postgres -Fc src  > "$TMPDIR/dumps/sample.dump"
gzip -k "$TMPDIR/dumps/sample.sql"
docker rm -fv tcpg-factory >/dev/null

run_format_test() {
  local label="$1" src_dump="$2"
  local pgdata="$TMPDIR/pgdata-$label"
  local dump_dir="$TMPDIR/dump-$label"
  mkdir -p "$pgdata" "$dump_dir"
  chmod 0777 "$dump_dir"
  cp "$src_dump" "$dump_dir/dump"

  echo "==> [$label] starting postgres..."
  start_pg_detached "tcpg-$label" "$pgdata" "$dump_dir"
  wait_ready "tcpg-$label"

  count=$(docker exec "tcpg-$label" psql -U postgres -d testdb -tAc "SELECT count(*) FROM w" | tr -d ' \r\n')
  if [ "$count" != "3" ]; then
    echo "FAIL [$label]: expected 3 rows, got '$count'" >&2
    docker logs "tcpg-$label" >&2
    exit 1
  fi
  if ! docker exec "tcpg-$label" test -f /var/lib/postgresql/data/pgdata/.restore_complete; then
    echo "FAIL [$label]: sentinel file missing after successful restore" >&2
    exit 1
  fi
  echo "PASS [$label]: 3 rows restored, sentinel written"
  docker rm -fv "tcpg-$label" >/dev/null
}

run_format_test sql    "$TMPDIR/dumps/sample.sql"
run_format_test sql-gz "$TMPDIR/dumps/sample.sql.gz"
run_format_test custom "$TMPDIR/dumps/sample.dump"

# Failure path: a broken dump should make the restore script (and entrypoint) exit non-zero.
echo "==> [failure] starting postgres with broken dump..."
fail_pgdata="$TMPDIR/pgdata-fail"
fail_dump_dir="$TMPDIR/dump-fail"
mkdir -p "$fail_pgdata" "$fail_dump_dir"
chmod 0777 "$fail_dump_dir"
echo "THIS IS NOT VALID SQL @@@@@@" > "$fail_dump_dir/dump"

set +e
run_pg tcpg-fail-1 "$fail_pgdata" "$fail_dump_dir" >"$TMPDIR/fail1.log" 2>&1
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
  echo "FAIL: first run should have exited non-zero (restore script failed)" >&2
  cat "$TMPDIR/fail1.log" >&2
  exit 1
fi
if [ -f "$fail_pgdata/pgdata/.restore_complete" ]; then
  echo "FAIL: sentinel was written despite restore failure" >&2
  exit 1
fi
echo "PASS [failure-1]: first run exited $rc, sentinel not written"

# Restart with the same PGDATA — wrapper should refuse to start, exit 1, mention the PVC name.
echo "==> [failure] restarting with stale PGDATA — wrapper should refuse..."
set +e
run_pg tcpg-fail-2 "$fail_pgdata" "$fail_dump_dir" >"$TMPDIR/fail2.log" 2>&1
rc2=$?
set -e
if [ "$rc2" -eq 0 ]; then
  echo "FAIL: wrapper should have refused to start" >&2
  cat "$TMPDIR/fail2.log" >&2
  exit 1
fi
if ! grep -q "fake-pvc-name" "$TMPDIR/fail2.log"; then
  echo "FAIL: wrapper output should mention PG_PVC_NAME (fake-pvc-name)" >&2
  cat "$TMPDIR/fail2.log" >&2
  exit 1
fi
if ! grep -q "restore_complete" "$TMPDIR/fail2.log"; then
  echo "FAIL: wrapper output should mention the sentinel file" >&2
  cat "$TMPDIR/fail2.log" >&2
  exit 1
fi
echo "PASS [failure-2]: wrapper refused (exit $rc2) with recovery message"

# ---------------------------------------------------------------------------
# Tuning: the rendered parameters must actually start Postgres.
# ---------------------------------------------------------------------------
echo "==> [tuning] extracting the parameters the chart renders..."
mapfile -t PG_ARGS < <(
  helm template t "$CHART_DIR" --set tcpg.enabled=true -s templates/tcpg/postgres.yaml \
    | awk '/^          args:/{f=1;next} f&&/^            - /{gsub(/^            - /,"");gsub(/^"|"$/,"");print;next} f{exit}'
)
if [ "${#PG_ARGS[@]}" -lt 3 ] || [ "${PG_ARGS[0]}" != "postgres" ]; then
  echo "FAIL [tuning]: could not extract args from the rendered StatefulSet" >&2
  printf '%s\n' "${PG_ARGS[@]}" >&2
  exit 1
fi
# Every arg after "postgres" alternates -c / key=value, so parameter count is half.
EXPECTED_PARAMS=$(( (${#PG_ARGS[@]} - 1) / 2 ))
echo "    ${EXPECTED_PARAMS} parameters rendered"

tuning_pgdata="$TMPDIR/pgdata-tuning"
mkdir -p "$tuning_pgdata"
track tcpg-tuning
# Mirrors the chart's runtime shape: memory/CPU limits and the /dev/shm size the
# parameters are derived from.
docker run -d --name tcpg-tuning \
  -e POSTGRES_PASSWORD=secret -e POSTGRES_USER=postgres -e POSTGRES_DB=testdb \
  -e PGDATA=/var/lib/postgresql/data/pgdata \
  --read-only --tmpfs /tmp --tmpfs /var/run/postgresql \
  --memory=1g --cpus=2 --shm-size=128m \
  -v "$tuning_pgdata:/var/lib/postgresql/data" \
  "$PG_IMAGE" "${PG_ARGS[@]}" >/dev/null
if ! wait_ready tcpg-tuning; then
  echo "FAIL [tuning]: Postgres rejected a rendered parameter — check for 'unrecognized configuration parameter'" >&2
  exit 1
fi
applied=$(docker exec tcpg-tuning psql -U postgres -d testdb -tAc \
  "SELECT count(*) FROM pg_settings WHERE source = 'command line'" | tr -d ' \r\n')
if [ "$applied" != "$EXPECTED_PARAMS" ]; then
  echo "FAIL [tuning]: $EXPECTED_PARAMS parameters rendered but $applied took effect" >&2
  docker exec tcpg-tuning psql -U postgres -d testdb -c \
    "SELECT name, setting, source FROM pg_settings WHERE source = 'command line' ORDER BY name" >&2
  exit 1
fi
# pg_stat_statements is preloaded via shared_preload_libraries; the extension
# must be creatable or the observability defaults are useless.
docker exec tcpg-tuning psql -U postgres -d testdb -q -c \
  "CREATE EXTENSION IF NOT EXISTS pg_stat_statements" >/dev/null
docker exec tcpg-tuning psql -U postgres -d testdb -tAc \
  "SELECT count(*) FROM pg_stat_statements" >/dev/null
echo "PASS [tuning]: all $applied parameters applied, pg_stat_statements usable"

# ---------------------------------------------------------------------------
# The image must keep declaring STOPSIGNAL SIGINT. Container runtimes honour it
# (containerd does, so Kubernetes gets a *fast* shutdown), and that is what
# makes the default shutdown path clean. If an image bump ever drops it,
# Postgres would get SIGTERM, read it as a *smart* shutdown, wait for clients
# and be SIGKILLed into crash recovery — at which point the chart's preStop hook
# stops being belt-and-braces and becomes load-bearing. Assert the assumption
# rather than rediscovering it.
# ---------------------------------------------------------------------------
stopsig=$(docker image inspect "$PG_IMAGE" --format '{{.Config.StopSignal}}')
if [ "$stopsig" != "SIGINT" ]; then
  echo "FAIL [stopsignal]: $PG_IMAGE declares STOPSIGNAL=$stopsig, expected SIGINT." >&2
  echo "                   The preStop hook in chart/templates/tcpg/postgres.yaml is now" >&2
  echo "                   the only thing preventing a smart-shutdown hang. Re-read the" >&2
  echo "                   shutdown notes in docs/usages.md before changing anything." >&2
  exit 1
fi
echo "PASS [stopsignal]: image declares STOPSIGNAL=SIGINT (fast shutdown)"

# ---------------------------------------------------------------------------
# Shutdown: `pg_ctl -m fast stop` — the command the chart's preStop hook runs —
# must shut down cleanly with a client still attached, so the next start does
# not crash-recover.
# ---------------------------------------------------------------------------
echo "==> [shutdown] holding a client in an open transaction, then running preStop..."
docker exec -d tcpg-tuning \
  psql -U postgres -d testdb -c "begin" -c "select 1" -c "select pg_sleep(300)"
sleep 3
backends=$(docker exec tcpg-tuning psql -U postgres -d testdb -tAc \
  "SELECT count(*) FROM pg_stat_activity WHERE backend_type = 'client backend'" | tr -d ' \r\n')
if [ "$backends" -lt 2 ]; then
  echo "FAIL [shutdown]: expected a held-open client backend, found $backends" >&2
  exit 1
fi
# The exact command the chart puts in the preStop hook, as the user the pod runs
# it as (`podSecurityContext.runAsUser: 999` = postgres; pg_ctl refuses to run as
# root). Stopping PID 1 tears the container down under the exec, so the exec's
# own exit code is not meaningful — the assertions below are what matter.
stop_out="$(docker exec -u postgres tcpg-tuning \
  sh -c 'exec pg_ctl -D "$PGDATA" -m fast -w -t 100 stop' 2>&1 || true)"
for _ in $(seq 1 30); do
  [ "$(docker inspect -f '{{.State.Running}}' tcpg-tuning)" = "false" ] && break
  sleep 1
done
if [ "$(docker inspect -f '{{.State.Running}}' tcpg-tuning)" != "false" ]; then
  echo "FAIL [shutdown]: Postgres did not stop with a client attached" >&2
  echo "pg_ctl output: $stop_out" >&2
  docker logs tcpg-tuning 2>&1 | tail -20 >&2
  exit 1
fi
if ! docker logs tcpg-tuning 2>&1 | grep -q "database system is shut down"; then
  echo "FAIL [shutdown]: no clean-shutdown line in the log" >&2
  docker logs tcpg-tuning 2>&1 | tail -20 >&2
  exit 1
fi
# Restarting must not crash-recover.
docker start tcpg-tuning >/dev/null
wait_ready tcpg-tuning
if docker logs tcpg-tuning 2>&1 | grep -qE "was not properly shut down|automatic recovery in progress"; then
  echo "FAIL [shutdown]: next start had to crash-recover despite the clean stop" >&2
  docker logs tcpg-tuning 2>&1 | grep -E "was not properly shut down|automatic recovery" >&2
  exit 1
fi
echo "PASS [shutdown]: clean stop with a client attached, clean start after"
docker rm -fv tcpg-tuning >/dev/null

# ---------------------------------------------------------------------------
# /dev/shm: parallel workers build hash tables in shared memory. Too small and
# the query does not slow down, it fails — which is why the chart mounts a
# Memory-medium emptyDir instead of accepting Kubernetes' 64Mi default.
# ---------------------------------------------------------------------------
SHM_ROWS=1500000   # enough that a 128MB parallel hash table overruns a 64Mi /dev/shm

shm_probe() {
  # Runs a forced parallel hash join with work_mem well above the small case.
  local name="$1" shm="$2"
  local pgdata="$TMPDIR/pgdata-$name"
  mkdir -p "$pgdata"
  track "$name"
  # Defensive: a previous aborted run may have left this name behind.
  docker rm -fv "$name" >/dev/null 2>&1 || true
  docker run -d --name "$name" \
    -e POSTGRES_PASSWORD=secret -e POSTGRES_USER=postgres -e POSTGRES_DB=testdb \
    -e PGDATA=/var/lib/postgresql/data/pgdata \
    --read-only --tmpfs /tmp --tmpfs /var/run/postgresql \
    --memory=1g --cpus=2 --shm-size="$shm" \
    -v "$pgdata:/var/lib/postgresql/data" \
    "$PG_IMAGE" -c shared_buffers=256MB -c max_parallel_workers=2 >/dev/null
  wait_ready "$name"
  docker exec "$name" psql -U postgres -d testdb -q -c \
    "CREATE TABLE t1 AS SELECT g id, md5(g::text) pad FROM generate_series(1,$SHM_ROWS) g;
     CREATE TABLE t2 AS SELECT g id, md5(g::text) pad FROM generate_series(1,$SHM_ROWS) g;
     ANALYZE t1; ANALYZE t2;" >/dev/null
  docker exec "$name" psql -U postgres -d testdb -c \
    "SET max_parallel_workers_per_gather=2; SET parallel_setup_cost=0;
     SET parallel_tuple_cost=0; SET min_parallel_table_scan_size=0;
     SET work_mem='128MB'; SET enable_mergejoin=off; SET enable_nestloop=off;
     SELECT count(*) FROM t1 JOIN t2 USING (id);" 2>&1
}

echo "==> [shm] parallel hash join at Kubernetes' 64Mi default (expected to fail)..."
small_out="$(shm_probe tcpg-shm-small 64m || true)"
if ! grep -q "No space left on device" <<<"$small_out"; then
  echo "FAIL [shm]: expected a shared-memory failure at 64Mi, got:" >&2
  echo "$small_out" >&2
  exit 1
fi
docker rm -fv tcpg-shm-small >/dev/null
echo "PASS [shm-small]: 64Mi reproduces 'could not resize shared memory segment'"

echo "==> [shm] same query with the chart's Memory-medium /dev/shm..."
big_out="$(shm_probe tcpg-shm-big 256m || true)"
if ! grep -qE "^ *${SHM_ROWS}$" <<<"$big_out"; then
  echo "FAIL [shm]: query should have succeeded at 256Mi, got:" >&2
  echo "$big_out" >&2
  exit 1
fi
docker rm -fv tcpg-shm-big >/dev/null
echo "PASS [shm-big]: same query returns $SHM_ROWS rows"

echo
echo "All integration tests passed."
