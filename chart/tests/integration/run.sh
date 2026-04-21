#!/usr/bin/env bash
# Integration test: spins up the real postgres image with our scripts mounted,
# verifies restore works for plain SQL, gzipped SQL, and pg_dump custom format,
# then verifies the wrapper refuses to start after a broken restore.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART_DIR="$(cd "$HERE/../.." && pwd)"
SCRIPTS="$CHART_DIR/scripts"

PG_IMAGE="${PG_IMAGE:-postgres:18.1}"
TMPDIR="$(mktemp -d -t tcpg-integration-XXXXXX)"

CONTAINERS=()
cleanup() {
  for c in "${CONTAINERS[@]:-}"; do
    docker rm -fv "$c" >/dev/null 2>&1 || true
  done
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
    -v "$pgdata:/var/lib/postgresql/data" \
    -v "$dump_dir:/dump:ro" \
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
    -v "$pgdata:/var/lib/postgresql/data" \
    -v "$dump_dir:/dump:ro" \
    -v "$SCRIPTS/10-restore.sh:/docker-entrypoint-initdb.d/10-restore.sh:ro" \
    -v "$SCRIPTS/entrypoint-wrapper.sh:/etc/postgres-wrapper/entrypoint-wrapper.sh:ro" \
    --entrypoint /bin/sh \
    "$PG_IMAGE" \
    /etc/postgres-wrapper/entrypoint-wrapper.sh postgres >/dev/null
}

wait_ready() {
  local name="$1"
  for _ in $(seq 1 60); do
    if docker exec "$name" pg_isready -U postgres -d testdb >/dev/null 2>&1; then
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

echo
echo "All integration tests passed."
