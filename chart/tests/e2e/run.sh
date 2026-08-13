#!/usr/bin/env bash
# End-to-end test against a real Kubernetes cluster (kind).
#
# The Docker integration suite (../integration/run.sh) proves things about the
# Postgres *image*. This suite proves things about *Kubernetes*, which is where
# most of the tcpg tuning fixes actually live:
#
#   - that kubelet invokes the preStop hook at all, inside the grace period —
#     the Docker suite only proves `pg_ctl -m fast stop` works when run by hand,
#     which is not the same claim
#   - what the runtime does WITHOUT the hook. This started as a negative control
#     expecting a hang, on the common belief that Kubernetes always sends
#     SIGTERM. It measured the opposite: containerd honours the image's
#     STOPSIGNAL (SIGINT), so shutdown is already fast and clean, and the hook
#     is defence in depth. The phase now pins that measured behaviour and fails
#     loudly if it ever changes.
#   - that emptyDir{medium: Memory, sizeLimit} behaves like --shm-size and is
#     actually enforced
#   - that the derived max_connections makes Postgres refuse a connection rather
#     than let the kernel OOM-kill the cluster
#   - that the pre-install/pre-upgrade secret-bootstrap Jobs work, credentials
#     are preserved across upgrades, and PGDATA survives a rollout
#
# Env:
#   CLUSTER_NAME    kind cluster name          (default: tcpg-e2e)
#   NAMESPACE       namespace to install into  (default: tcpg-e2e)
#   K8S_NODE_IMAGE  kindest/node image to pin  (default: kind's built-in)
#                   Pin this to the target cluster's Kubernetes version —
#                   conclusions about kubelet behaviour are version-specific.
#   REUSE_CLUSTER=1 reuse an existing cluster instead of creating one
#   KEEP_CLUSTER=1  leave the cluster running afterwards (for debugging)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART_DIR="$(cd "$HERE/../.." && pwd)"

CLUSTER="${CLUSTER_NAME:-tcpg-e2e}"
NS="${NAMESPACE:-tcpg-e2e}"
RELEASE=tcpg-e2e
KEEP_CLUSTER="${KEEP_CLUSTER:-0}"
REUSE_CLUSTER="${REUSE_CLUSTER:-0}"
TMPDIR="$(mktemp -d -t tcpg-e2e-XXXXXX)"
CREATED_CLUSTER=0

pass() { echo "PASS [$1]: $2"; }
die() {
  echo "FAIL [$1]: $2" >&2
  echo "--- pods ---" >&2; kubectl -n "$NS" get pods -o wide 2>&1 | head -20 >&2 || true
  echo "--- tcpg-0 log tail ---" >&2; kubectl -n "$NS" logs tcpg-0 -c pg --tail=40 2>&1 >&2 || true
  exit 1
}

cleanup() {
  set +e
  if [ "$CREATED_CLUSTER" = "1" ] && [ "$KEEP_CLUSTER" != "1" ]; then
    echo "==> deleting kind cluster '$CLUSTER'"
    kind delete cluster --name "$CLUSTER" >/dev/null 2>&1
  elif [ "$KEEP_CLUSTER" = "1" ]; then
    echo "==> leaving cluster '$CLUSTER' running (KEEP_CLUSTER=1)"
  fi
  rm -rf "$TMPDIR"
}
trap cleanup EXIT

k() { kubectl -n "$NS" "$@"; }
# Query Postgres over the unix socket inside the pod (local connections trust).
psql_q() { k exec tcpg-0 -c pg -- psql -U postgres -d postgres -tAc "$1"; }

READY_TIMEOUT=180
wait_ready() {
  k wait --for=condition=ready pod/tcpg-0 --timeout="${READY_TIMEOUT}s" >/dev/null
}

# ---------------------------------------------------------------------------
# Cluster
# ---------------------------------------------------------------------------
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  if [ "$REUSE_CLUSTER" = "1" ]; then
    echo "==> reusing existing kind cluster '$CLUSTER'"
  else
    echo "FAIL: kind cluster '$CLUSTER' already exists." >&2
    echo "      Refusing to touch it — it may not be ours. Delete it yourself with" >&2
    echo "      'kind delete cluster --name $CLUSTER', or set REUSE_CLUSTER=1." >&2
    exit 1
  fi
else
  echo "==> creating kind cluster '$CLUSTER' (~1 min)..."
  # shellcheck disable=SC2086  # deliberate: empty when no image is pinned
  kind create cluster --name "$CLUSTER" --config "$HERE/kind-config.yaml" \
    ${K8S_NODE_IMAGE:+--image "$K8S_NODE_IMAGE"} >/dev/null
  CREATED_CLUSTER=1
fi
kubectl config use-context "kind-$CLUSTER" >/dev/null
echo "    kubernetes: $(kubectl version -o json 2>/dev/null | grep -oP '"gitVersion":\s*"\K[^"]+' | tail -1)"

# kind ships one StorageClass, named `standard`, backed by rancher.io/local-path.
# The chart defaults to `local-path`, so alias it to the same provisioner rather
# than overriding the value — that way the chart's *default* values are what
# gets tested.
kubectl apply -f - >/dev/null <<'EOF'
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: local-path
provisioner: rancher.io/local-path
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
EOF

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
# Enforcing restricted makes every later phase double as an admission test.
kubectl label namespace "$NS" --overwrite \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/enforce-version=latest >/dev/null
pass setup "cluster ready, namespace enforcing restricted PSS, local-path StorageClass present"

# ---------------------------------------------------------------------------
# Phase 1 — install under restricted PSS
# ---------------------------------------------------------------------------
echo "==> [install] helm install with chart defaults..."
if ! helm install "$RELEASE" "$CHART_DIR" -n "$NS" --set tcpg.enabled=true \
     --wait --timeout 5m >"$TMPDIR/install.log" 2>&1; then
  echo "FAIL [install]: helm install failed" >&2
  tail -30 "$TMPDIR/install.log" >&2
  echo "--- events ---" >&2; k get events --sort-by=.lastTimestamp 2>&1 | tail -20 >&2
  exit 1
fi
wait_ready || die install "tcpg-0 never became ready"
pass install "admitted under restricted PSS and reached Ready"

# Burstable, not Guaranteed: memory request == limit, but CPU is deliberately
# burstable (0.1 -> 2) so restores and ad-hoc queries can use spare cores.
# Guaranteed would require the CPU request to equal its limit, reserving 2 full
# cores per instance. What matters for tcpg is that the *memory* request equals
# the limit, so the full 1Gi is reserved on the node.
qos=$(k get pod tcpg-0 -o jsonpath='{.status.qosClass}')
[ "$qos" = "Burstable" ] || die qos "expected Burstable QoS, got '$qos'"
req=$(k get pod tcpg-0 -o jsonpath='{.spec.containers[0].resources.requests.memory}')
lim=$(k get pod tcpg-0 -o jsonpath='{.spec.containers[0].resources.limits.memory}')
[ "$req" = "$lim" ] || die qos "memory request ($req) should equal the limit ($lim)"
pass qos "Burstable QoS with memory request == limit ($lim reserved, CPU burstable)"

pw=$(k get secret tcpg-pg-credential -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d)
[ "${#pw}" -eq 32 ] || die secret "expected a generated 32-char password, got ${#pw} chars"
pass secret "bootstrap Job generated a 32-char password"

# ---------------------------------------------------------------------------
# Phase 2 — derived parameters actually landed
# ---------------------------------------------------------------------------
rendered=$(helm get manifest "$RELEASE" -n "$NS" \
  | awk '/^          args:/{f=1;next} f&&/^            - /{gsub(/^            - /,"");gsub(/^"|"$/,"");print;next} f{exit}' \
  | grep -c '=' || true)
applied=$(psql_q "SELECT count(*) FROM pg_settings WHERE source = 'command line'" | tr -d ' \r')
[ "$rendered" = "$applied" ] || die params "$rendered parameters rendered but $applied took effect"
pass params "all $applied rendered parameters applied in-cluster"

for kv in "max_connections|43" "effective_cache_size|63488" "autovacuum_work_mem|32768" "autovacuum_max_workers|3"; do
  name="${kv%%|*}"; want="${kv##*|}"
  got=$(psql_q "SELECT setting FROM pg_settings WHERE name='$name'" | tr -d ' \r')
  [ "$got" = "$want" ] || die params "$name: expected $want, got $got"
done
pass params "post-review values in effect (max_connections=43, autovacuum budgeted)"

psql_q "CREATE EXTENSION IF NOT EXISTS pg_stat_statements" >/dev/null
psql_q "SELECT count(*) FROM pg_stat_statements" >/dev/null
pass observability "pg_stat_statements preloaded and usable"

# ---------------------------------------------------------------------------
# Phase 3 — /dev/shm is real, sized and enforced
# ---------------------------------------------------------------------------
shm_mb=$(k exec tcpg-0 -c pg -- sh -c "df -m /dev/shm | awk 'NR==2{print \$2}'" | tr -d ' \r')
if [ "$shm_mb" -lt 120 ] || [ "$shm_mb" -gt 136 ]; then
  die shm "expected ~128Mi /dev/shm, got ${shm_mb}Mi"
fi
pass shm "/dev/shm is ${shm_mb}Mi, not the 64Mi Kubernetes default"

# sizeLimit must be *enforced*: the memory budget subtracts shm.size on the
# assumption that shm cannot grow past it.
ddout=$(k exec tcpg-0 -c pg -- sh -c \
  'dd if=/dev/zero of=/dev/shm/fill bs=1M count=200 2>&1; rm -f /dev/shm/fill' || true)
grep -qiE 'no space left|disk quota' <<<"$ddout" \
  || die shm "sizeLimit not enforced — wrote 200Mi into a 128Mi /dev/shm: $ddout"
pass shm "sizeLimit is enforced (200Mi write refused)"

SHM_ROWS=1500000  # big enough that the parallel hash table overruns a 64Mi /dev/shm
psql_q "CREATE TABLE t1 AS SELECT g id, md5(g::text) pad FROM generate_series(1,$SHM_ROWS) g" >/dev/null
psql_q "CREATE TABLE t2 AS SELECT g id, md5(g::text) pad FROM generate_series(1,$SHM_ROWS) g" >/dev/null
psql_q "ANALYZE t1; ANALYZE t2" >/dev/null
pq="SET max_parallel_workers_per_gather=2; SET parallel_setup_cost=0; SET parallel_tuple_cost=0;
    SET min_parallel_table_scan_size=0; SET enable_mergejoin=off; SET enable_nestloop=off;"
shm_join() { k exec tcpg-0 -c pg -- psql -U postgres -d postgres -tAc "$1" 2>&1; }

ok=$(shm_join "$pq SELECT count(*) FROM t1 JOIN t2 USING (id);" | tr -d ' \r')
grep -q "$SHM_ROWS" <<<"$ok" || die shm "parallel hash join failed at the derived work_mem: $ok"
pass shm "parallel hash join succeeds with the chart's derived work_mem"

# A/B on shm.size alone: same data, same query, only /dev/shm differs. This is
# what makes the result attributable to the chart's value rather than to the
# query. A large work_mem is used so the hash table is big enough to matter.
big_q="$pq SET work_mem='256MB'; SELECT count(*) FROM t1 JOIN t2 USING (id);"
at128=$(shm_join "$big_q" 2>&1 | tr -d ' \r' || true)
grep -q "$SHM_ROWS" <<<"$at128" || die shm "query should succeed at the chart's 128Mi /dev/shm: $at128"
pass shm "a 256MB-work_mem hash join succeeds at the chart's 128Mi /dev/shm"

echo "==> [shm] reverting /dev/shm to Kubernetes' 64Mi default to A/B the same query..."
k patch statefulset tcpg -p \
  '{"spec":{"template":{"spec":{"volumes":[{"name":"dshm","emptyDir":{"medium":"Memory","sizeLimit":"64Mi"}}]}}}}' >/dev/null
k delete pod tcpg-0 --wait=true >/dev/null
wait_ready || die shm "pod did not come back after the 64Mi patch"
at64=$(shm_join "$big_q" || true)
grep -q 'No space left on device' <<<"$at64" \
  || die shm "expected the identical query to fail at 64Mi, got: $at64"
pass shm "the identical query hard-errors at 64Mi — shm.size is what makes the difference"

k patch statefulset tcpg -p \
  '{"spec":{"template":{"spec":{"volumes":[{"name":"dshm","emptyDir":{"medium":"Memory","sizeLimit":"128Mi"}}]}}}}' >/dev/null
k delete pod tcpg-0 --wait=true >/dev/null
wait_ready || die shm "pod did not come back after restoring 128Mi"
psql_q "DROP TABLE t1; DROP TABLE t2" >/dev/null
pass shm "restored to 128Mi"

# ---------------------------------------------------------------------------
# Phase 4 — preStop hook (the load-bearing one)
# ---------------------------------------------------------------------------
# Hold an open transaction from a SEPARATE pod, over TCP — the way a Django app
# with a persistent connection actually does it.
#
# It must not be done with `kubectl exec ... &` inside the pg pod: the exec'd
# psql is orphaned when its shell exits and gets reparented to PID 1, which here
# *is* the postmaster. Postgres then sees a child it did not fork, logs
# "untracked child process ... exited" and declares an abnormal shutdown — a
# crash recovery caused purely by the test harness, which would otherwise look
# exactly like the bug this phase is checking for.
hold_client() {
  k delete pod pgholder --ignore-not-found --wait=true >/dev/null 2>&1
  kubectl apply -n "$NS" -f - >/dev/null <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: pgholder
spec:
  restartPolicy: Never
  securityContext:
    runAsNonRoot: true
    runAsUser: 999
    seccompProfile: {type: RuntimeDefault}
  containers:
    - name: hold
      image: postgres:18.1
      securityContext:
        allowPrivilegeEscalation: false
        capabilities: {drop: [ALL]}
      envFrom:
        - secretRef: {name: tcpg-pg-credential}
      command: [sh, -c]
      args: ['exec psql "$POSTGRES_URI" -c "begin" -c "select 1" -c "select pg_sleep(300)"']
EOF
  for _ in $(seq 1 30); do
    n=$(psql_q "SELECT count(*) FROM pg_stat_activity WHERE backend_type='client backend' AND client_addr IS NOT NULL" | tr -d ' \r')
    [ "${n:-0}" -ge 1 ] && return 0
    sleep 1
  done
  die prestop "the holder pod never established a connection"
}

delete_and_time() {
  local logfile="$1"
  k logs -f tcpg-0 -c pg >"$logfile" 2>&1 &
  local logpid=$!
  sleep 2
  local start; start=$(date +%s)
  k delete pod tcpg-0 --wait=true >/dev/null
  local elapsed=$(( $(date +%s) - start ))
  # `kubectl logs -f` ends by itself once the pod is gone. Let it drain rather
  # than killing it immediately, or the final shutdown lines can be missing from
  # the captured log and the assertions read that as an unclean shutdown.
  local waited=0
  while kill -0 "$logpid" 2>/dev/null && [ "$waited" -lt 15 ]; do
    sleep 1
    waited=$((waited + 1))
  done
  kill "$logpid" >/dev/null 2>&1 || true
  wait "$logpid" >/dev/null 2>&1 || true
  echo "$elapsed"
}

echo "==> [prestop] deleting the pod with a client held in an open transaction..."
hold_client
elapsed=$(delete_and_time "$TMPDIR/prestop.log")
[ "$elapsed" -lt 30 ] \
  || die prestop "deletion took ${elapsed}s — the hook did not short-circuit the grace period"
grep -q "database system is shut down" "$TMPDIR/prestop.log" \
  || die prestop "no clean-shutdown line; kubelet may not have run the preStop hook"
wait_ready || die prestop "pod did not come back"
k logs tcpg-0 -c pg | grep -qE "not properly shut down|automatic recovery in progress" \
  && die prestop "restart had to crash-recover despite the hook"
k delete pod pgholder --ignore-not-found --wait=false >/dev/null 2>&1
pass prestop "deleted in ${elapsed}s, clean shutdown with a client attached, clean restart"

# Negative control. Without this, the phase above cannot distinguish "the hook
# works" from "nothing needed fixing in the first place".
# What the runtime does WITHOUT the hook. This started life as a negative
# control expecting a hang, on the widely repeated belief that Kubernetes always
# sends SIGTERM. It does not: containerd honours the image's STOPSIGNAL, which
# for postgres is SIGINT, so an un-hooked pod still fast-shuts-down cleanly in
# about a second. The assertion below records that measured behaviour.
#
# So the hook is defence in depth, not a fix for a live bug — it matters only if
# the image stops declaring STOPSIGNAL (asserted in ../integration/run.sh) or
# the runtime changes. If this phase ever starts reporting a smart shutdown, the
# hook has become load-bearing and the docs need revisiting.
echo "==> [prestop-control] measuring what the runtime does without the hook..."
# Save the chart's own values so they can be put back verbatim. Helm v4 applies
# server-side, so it will NOT reclaim fields another field manager (kubectl-patch)
# has taken ownership of — a `helm upgrade` here fails with a field conflict.
saved_lifecycle=$(k get statefulset tcpg -o jsonpath='{.spec.template.spec.containers[0].lifecycle}')
saved_grace=$(k get statefulset tcpg -o jsonpath='{.spec.template.spec.terminationGracePeriodSeconds}')
k patch statefulset tcpg --type=json -p \
  '[{"op":"remove","path":"/spec/template/spec/containers/0/lifecycle"},
    {"op":"replace","path":"/spec/template/spec/terminationGracePeriodSeconds","value":30}]' >/dev/null
k delete pod tcpg-0 --wait=true >/dev/null
wait_ready || die prestop-control "pod did not come back after patch"
hold_client
elapsed_nohook=$(delete_and_time "$TMPDIR/prestop-control.log")
wait_ready || die prestop-control "pod did not come back"
if grep -q "received smart shutdown request" "$TMPDIR/prestop-control.log"; then
  die prestop-control "the runtime sent SIGTERM (smart shutdown) — the preStop hook is now load-bearing, not defence in depth. Update docs/usages.md and chart/values.yaml, which currently state that containerd honours STOPSIGNAL=SIGINT."
fi
grep -q "received fast shutdown request" "$TMPDIR/prestop-control.log" \
  || die prestop-control "expected a fast shutdown from the runtime's STOPSIGNAL; log shows neither mode"
k logs tcpg-0 -c pg | grep -qE "not properly shut down|automatic recovery in progress" \
  && die prestop-control "un-hooked shutdown was unclean despite reporting fast shutdown"
k delete pod pgholder --ignore-not-found --wait=false >/dev/null 2>&1
pass prestop-control "without the hook the runtime still sends SIGINT: fast shutdown in ${elapsed_nohook}s, clean restart"

# Put it back the same way it was taken away, so ownership stays with
# kubectl-patch and the later `helm upgrade` phase does not hit a field conflict.
k patch statefulset tcpg --type=json -p \
  "[{\"op\":\"add\",\"path\":\"/spec/template/spec/containers/0/lifecycle\",\"value\":$saved_lifecycle},
    {\"op\":\"replace\",\"path\":\"/spec/template/spec/terminationGracePeriodSeconds\",\"value\":$saved_grace}]" >/dev/null
k delete pod tcpg-0 --wait=true >/dev/null
k rollout status statefulset tcpg --timeout=180s >/dev/null
wait_ready || die prestop-control "pod did not recover after restoring the hook"
k get statefulset tcpg -o jsonpath='{.spec.template.spec.containers[0].lifecycle.preStop}' \
  | grep -q pg_ctl || die prestop-control "preStop hook was not restored"
pass prestop-control "hook restored"

# ---------------------------------------------------------------------------
# Phase 5 — max_connections refuses instead of OOM-killing
# ---------------------------------------------------------------------------
echo "==> [maxconn] opening more connections than the derived cap..."
# Flood over TCP from a separate pod, for the same reason hold_client does:
# psql processes started with `kubectl exec ... &` are orphaned onto PID 1 (the
# postmaster), which then reports "untracked child process" and shuts down
# abnormally. Here they are children of the flood pod's own shell.
#
# The flood connects as a NON-superuser on purpose. Postgres keeps
# superuser_reserved_connections (3) slots back, so the superuser monitoring
# queries below still get in once the cap binds — flooding as `postgres` would
# consume the reserve too and lock the test itself out. It is also the realistic
# shape: an app role, not a superuser.
maxconn=$(psql_q "SHOW max_connections" | tr -d ' \r')
[ "$maxconn" = "43" ] || die maxconn "expected the derived max_connections=43, got $maxconn"
psql_q "DROP ROLE IF EXISTS floodapp" >/dev/null
psql_q "CREATE ROLE floodapp LOGIN PASSWORD 'floodpass'" >/dev/null

k delete pod pgflood --ignore-not-found --wait=true >/dev/null 2>&1
kubectl apply -n "$NS" -f - >/dev/null <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: pgflood
spec:
  restartPolicy: Never
  securityContext:
    runAsNonRoot: true
    runAsUser: 999
    seccompProfile: {type: RuntimeDefault}
  containers:
    - name: flood
      image: postgres:18.1
      securityContext:
        allowPrivilegeEscalation: false
        capabilities: {drop: [ALL]}
      envFrom:
        - secretRef: {name: tcpg-pg-credential}
      command: [sh, -c]
      # stderr is left unredirected so refusals land in the pod log.
      args:
        - |
          URI="postgres://floodapp:floodpass@$POSTGRES_HOST:$POSTGRES_PORT/$POSTGRES_DB"
          i=0
          while [ $i -lt 60 ]; do psql "$URI" -c "select pg_sleep(60)" >/dev/null & i=$((i+1)); done
          wait
EOF
k wait --for=condition=ready pod/pgflood --timeout=120s >/dev/null 2>&1 || true

# Superuser-reserved slots keep this working even at the cap, but stay tolerant.
count_conns() {
  k exec tcpg-0 -c pg -- psql -U postgres -d postgres -tAc \
    "SELECT count(*) FROM pg_stat_activity WHERE client_addr IS NOT NULL" 2>/dev/null | tr -d ' \r' || true
}
peak=0
for _ in $(seq 1 45); do
  n=$(count_conns)
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  [ "$n" -gt "$peak" ] && peak=$n
  [ "$n" -ge 39 ] && break
  sleep 1
done
[ "$peak" -le "$maxconn" ] || die maxconn "observed $peak connections, above max_connections=$maxconn"
[ "$peak" -ge 30 ] || die maxconn "only reached $peak connections — the flood never pressured the cap"

# The refusal must be a graceful FATAL from Postgres. Non-superusers are turned
# away once only the superuser-reserved slots remain, which is a different
# message from plain exhaustion — accept either.
floodlog=$(k logs pgflood 2>&1 | head -60)
grep -qiE "too many clients|remaining connection slots are reserved" <<<"$floodlog" \
  || die maxconn "expected a graceful connection refusal in the flood pod log, got: $(head -3 <<<"$floodlog")"

restarts=$(k get pod tcpg-0 -o jsonpath='{.status.containerStatuses[0].restartCount}')
reason=$(k get pod tcpg-0 -o jsonpath='{.status.containerStatuses[0].lastState.terminated.reason}')
[ "$restarts" = "0" ] || die maxconn "pod restarted ${restarts}x under connection pressure (reason: ${reason:-none})"
[ "$reason" != "OOMKilled" ] || die maxconn "pod was OOMKilled — the cap did not bound memory"
pass maxconn "peaked at $peak/$maxconn connections, excess refused gracefully; no restart, no OOMKill"

k delete pod pgflood --ignore-not-found --wait=true >/dev/null 2>&1
psql_q "DROP ROLE IF EXISTS floodapp" >/dev/null

# ---------------------------------------------------------------------------
# Phase 6 — upgrade rolls the StatefulSet, preserves data and credentials
# ---------------------------------------------------------------------------
psql_q "CREATE TABLE upgrade_marker (id int)" >/dev/null
psql_q "INSERT INTO upgrade_marker VALUES (42)" >/dev/null

# Run it twice: the second upgrade is where an immutable hook Job spec would bite.
for round in 1 2; do
  helm upgrade "$RELEASE" "$CHART_DIR" -n "$NS" --set tcpg.enabled=true \
    --set "tcpg.parameters.log_min_duration_statement=$((200 + round))ms" \
    --wait --timeout 5m >"$TMPDIR/upgrade-$round.log" 2>&1 \
    || { echo "FAIL [upgrade]: round $round failed" >&2; tail -25 "$TMPDIR/upgrade-$round.log" >&2; exit 1; }
  k rollout status statefulset tcpg --timeout=180s >/dev/null
  wait_ready || die upgrade "round $round: pod not ready"
done

got=$(psql_q "SELECT setting FROM pg_settings WHERE name='log_min_duration_statement'" | tr -d ' \r')
[ "$got" = "202" ] || die upgrade "expected log_min_duration_statement=202ms, got ${got}ms"
marker=$(psql_q "SELECT id FROM upgrade_marker" | tr -d ' \r')
[ "$marker" = "42" ] || die upgrade "PGDATA did not survive the rollout (marker='$marker')"
pw2=$(k get secret tcpg-pg-credential -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d)
[ "$pw2" = "$pw" ] || die upgrade "bootstrap Job overwrote the existing password instead of preserving it"
pass upgrade "two upgrades rolled cleanly; data and generated credential both preserved"

# ---------------------------------------------------------------------------
# Phase 7 — restore path with the init container
# ---------------------------------------------------------------------------
echo "==> [restore] serving a dump in-cluster over basic auth..."
kubectl apply -n "$NS" -f - >/dev/null <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: dumpserver
data:
  dump: |
    CREATE TABLE restored (id int primary key, n text);
    INSERT INTO restored VALUES (1,'alpha'),(2,'beta'),(3,'gamma');
  server.py: |
    import base64, http.server
    EXPECTED = "Basic " + base64.b64encode(b"dumpuser:dumppass").decode()
    class H(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            if self.headers.get("Authorization") != EXPECTED:
                self.send_response(401)
                self.send_header("WWW-Authenticate", 'Basic realm="dumps"')
                self.end_headers(); return
            body = open("/data/dump", "rb").read()
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers(); self.wfile.write(body)
        def log_message(self, *a): pass
    http.server.HTTPServer(("", 8080), H).serve_forever()
---
apiVersion: v1
kind: Pod
metadata:
  name: dumpserver
  labels: {app: dumpserver}
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 65534
    seccompProfile: {type: RuntimeDefault}
  containers:
    - name: s
      image: python:3.13-alpine
      command: [python3, /app/server.py]
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities: {drop: [ALL]}
      ports: [{containerPort: 8080}]
      volumeMounts:
        - {name: app, mountPath: /app}
        - {name: app, mountPath: /data}
  volumes:
    - name: app
      configMap: {name: dumpserver}
---
apiVersion: v1
kind: Service
metadata:
  name: dumpserver
spec:
  selector: {app: dumpserver}
  ports: [{port: 8080, targetPort: 8080}]
EOF
k wait --for=condition=ready pod/dumpserver --timeout=180s >/dev/null \
  || die restore "dump server pod never became ready"

helm install tcpg-restore "$CHART_DIR" -n "$NS" --set tcpg.enabled=true \
  --set tcpg.fullnameOverride=tcpgr \
  --set tcpg.init.restore.enabled=true \
  --set "tcpg.init.restore.baseUrl=http://dumpserver.$NS.svc.cluster.local:8080" \
  --set tcpg.init.restore.path=/dump \
  --set tcpg.init.restore.auth.type=basic \
  --set tcpg.init.restore.auth.value=dumpuser:dumppass \
  --wait --timeout 5m >"$TMPDIR/restore.log" 2>&1 \
  || { echo "FAIL [restore]: helm install failed" >&2; tail -30 "$TMPDIR/restore.log" >&2
       k logs tcpgr-0 -c download-dump 2>&1 | tail -20 >&2 || true; exit 1; }
k wait --for=condition=ready pod/tcpgr-0 --timeout=180s >/dev/null \
  || die restore "restored instance never became ready"

rows=$(k exec tcpgr-0 -c pg -- psql -U postgres -d postgres -tAc "SELECT count(*) FROM restored" | tr -d ' \r')
[ "$rows" = "3" ] || die restore "expected 3 restored rows, got '$rows'"
k exec tcpgr-0 -c pg -- test -f /var/lib/postgresql/data/pgdata/.restore_complete \
  || die restore "restore sentinel missing"
pass restore "init container downloaded over basic auth, 3 rows restored, sentinel written"
helm uninstall tcpg-restore -n "$NS" >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
# Phase 8 — guards fail closed on a real install, not just helm template
# ---------------------------------------------------------------------------
for case in "tcpg.parameters.work_mem=16MB|budget exceeded" \
            "tcpg.parameters.autovacuum_work_mem=-1|autovacuum workers" \
            "tcpg.parameters.work_mem=99999|needs an explicit unit"; do
  setexpr="${case%%|*}"; want="${case##*|}"
  out=$(helm install guard-check "$CHART_DIR" -n "$NS" --dry-run \
        --set tcpg.enabled=true --set "$setexpr" 2>&1 || true)
  grep -q "$want" <<<"$out" || die guards "expected '$want' for $setexpr, got: $(tail -2 <<<"$out")"
done
pass guards "budget, autovacuum and unit guards all reject at install time"

# ---------------------------------------------------------------------------
# Phase 9 — mailhog catches SMTP, guards the UI, and survives a restart
# ---------------------------------------------------------------------------
# bcrypt of "hunter2", minted with `docker run --rm mailhog/mailhog:v1.0.1
# bcrypt hunter2`. A fixture, not a credential — the chart never generates one
# (a fresh salt per render would leave an ArgoCD app permanently OutOfSync).
# shellcheck disable=SC2016  # the $2a$/$04$ are bcrypt field separators, not shell
MH_HTPASSWD='admin:$2a$04$/eeOOFDbquieypRZZV7VMeha9EiiZ8kOy1Z4LuOjE22xwm7nINRkG'

echo "==> [mailhog] installing with maildir persistence and UI auth..."
helm install mailhog-check "$CHART_DIR" -n "$NS" --set mailhog.enabled=true \
  --set mailhog.persistence.enabled=true \
  --set "mailhog.ui.auth.htpasswd=$MH_HTPASSWD" \
  --wait --timeout 5m >"$TMPDIR/mailhog.log" 2>&1 \
  || { echo "FAIL [mailhog]: helm install failed" >&2; tail -30 "$TMPDIR/mailhog.log" >&2
       k get events --sort-by=.lastTimestamp 2>&1 | tail -20 >&2; exit 1; }
pass mailhog "admitted under restricted PSS with readOnlyRootFilesystem and reached Ready"

# The client reads the connection details out of the chart's own consumer
# Secret, so a wrong host/port there fails this phase rather than passing
# quietly.
mh_host=$(k get secret mailhog-smtp-config -o jsonpath='{.data.SMTP_HOST}' | base64 -d)
mh_port=$(k get secret mailhog-smtp-config -o jsonpath='{.data.SMTP_PORT}' | base64 -d)
[ "$mh_host" = "mailhog.$NS.svc.cluster.local" ] \
  || die mailhog "SMTP_HOST is '$mh_host', expected mailhog.$NS.svc.cluster.local"

kubectl apply -n "$NS" -f - >/dev/null <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: mailclient
data:
  client.py: |
    import base64, json, os, smtplib, sys, urllib.error, urllib.request
    from email.message import EmailMessage
    host, smtp_port = os.environ["MH_HOST"], int(os.environ["MH_SMTP_PORT"])
    api = "http://%s:8025/api/v2/messages" % host

    def get(authenticated):
        req = urllib.request.Request(api)
        if authenticated:
            req.add_header("Authorization", "Basic " + base64.b64encode(b"admin:hunter2").decode())
        try:
            with urllib.request.urlopen(req, timeout=10) as r:
                return r.status, json.load(r)
        except urllib.error.HTTPError as e:
            return e.code, None

    if sys.argv[1] == "send":
        m = EmailMessage()
        m["From"], m["To"], m["Subject"] = "app@alpha.test", "user@example.com", "e2e"
        m.set_content("hello from e2e")
        s = smtplib.SMTP(host, smtp_port, timeout=10)
        s.send_message(m)
        s.quit()

    code, _ = get(False)
    assert code == 401, "unauthenticated API returned %s, expected 401" % code
    code, body = get(True)
    assert code == 200, "authenticated API returned %s, expected 200" % code
    print(body["total"])
---
apiVersion: v1
kind: Pod
metadata:
  name: mailclient
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 65534
    seccompProfile: {type: RuntimeDefault}
  containers:
    - name: c
      image: python:3.13-alpine
      command: [sleep, infinity]
      env:
        - {name: MH_HOST, value: "$mh_host"}
        - {name: MH_SMTP_PORT, value: "$mh_port"}
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities: {drop: [ALL]}
      volumeMounts:
        - {name: app, mountPath: /app}
  volumes:
    - name: app
      configMap: {name: mailclient}
EOF
k wait --for=condition=ready pod/mailclient --timeout=180s >/dev/null \
  || die mailhog "mail client pod never became ready"

total=$(k exec mailclient -- python3 /app/client.py send 2>&1 | tail -1 | tr -d ' \r') \
  || die mailhog "client failed: $total"
[ "$total" = "1" ] || die mailhog "expected 1 caught message, API reported '$total'"
pass mailhog "SMTP on :$mh_port caught the message; UI/API answers 401 without the MH_AUTH_FILE credentials"

# maildir lives on the PVC, so the inbox must outlive the pod. This also proves
# fsGroup 1000 makes the volume writable for the non-root mailhog user.
k delete pod -l app.kubernetes.io/name=mailhog --wait >/dev/null
k rollout status deployment mailhog --timeout=180s >/dev/null \
  || die mailhog "mailhog never came back after the pod delete"
total=$(k exec mailclient -- python3 /app/client.py check 2>&1 | tail -1 | tr -d ' \r') \
  || die mailhog "client failed after restart: $total"
[ "$total" = "1" ] || die mailhog "maildir did not survive the restart (API reported '$total')"
pass mailhog "maildir on the PVC survived a pod delete"

k delete pod mailclient --wait=false >/dev/null 2>&1 || true
helm uninstall mailhog-check -n "$NS" >/dev/null 2>&1 || true

echo
echo "All e2e tests passed."
