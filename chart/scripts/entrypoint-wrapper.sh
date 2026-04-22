#!/bin/sh
# Refuses to start Postgres if PGDATA is initialized but the restore
# sentinel is missing — i.e., a previous restore failed partway and the
# data dir is in an unknown state. Recovery is manual (delete PVC).
set -eu

if [ -s "$PGDATA/PG_VERSION" ] && [ ! -f "$PGDATA/.restore_complete" ]; then
  cat >&2 <<EOF
==============================================================================
ERROR: A previous restore did not complete successfully.
       PGDATA is initialized but the sentinel \$PGDATA/.restore_complete is missing.
       The database is in an inconsistent state and Postgres will not be started.

       To recover, delete the PVC and reinstall the chart:
         kubectl delete pvc ${PG_PVC_NAME:-<release>-tcpg-pg-data}
         helm upgrade --install ...
==============================================================================
EOF
  exit 1
fi

exec docker-entrypoint.sh "$@"
