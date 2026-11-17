#!/usr/bin/env bash
set -euo pipefail
umask 077

: "${PGDATA:?}"
: "${POSTGRES_USER:?}"
: "${POSTGRES_DB:?}"

[[ "$(cat "$PGDATA/PG_VERSION")" == 17 ]] || {
  echo "This deployment procedure requires PostgreSQL 17." >&2
  exit 1
}

[[ ! -e "$PGDATA/postmaster.pid" ]] || {
  echo "PostgreSQL must be stopped before preparing the upgrade." >&2
  exit 1
}

[[ ! -L "$PGDATA/pg_wal" && -z "$(ls -A "$PGDATA/pg_tblspc")" ]] || {
  echo "External WAL or tablespaces require an expanded backup procedure." >&2
  exit 1
}

backup_dir=$(mktemp -d /backups/pre-upgrade.XXXXXX)
echo "Creating backup at $backup_dir"
tar -C "$PGDATA" -cpf "$backup_dir/data.tar" .
(
  cd "$backup_dir"
  sha256sum data.tar > SHA256SUMS
)
touch "$backup_dir/COMPLETE"

socket_dir=$(mktemp -d /tmp/postgis-upgrade.XXXXXX)
chown postgres:postgres "$socket_dir"

cleanup() {
  gosu postgres pg_ctl -D "$PGDATA" -m fast -w -t 60 stop || true
}
trap cleanup EXIT

gosu postgres pg_ctl -D "$PGDATA" -w -t 60 \
  -o "-c listen_addresses='' -c unix_socket_directories=$socket_dir" start

export PGHOST="$socket_dir"
export PGUSER="$POSTGRES_USER"

databases=$(psql -X -w -At -v ON_ERROR_STOP=1 -d "$POSTGRES_DB" \
  -c 'SELECT datname FROM pg_database WHERE datallowconn ORDER BY datname')

while IFS= read -r database; do
  installed=$(psql -X -w -At -v ON_ERROR_STOP=1 -d "$database" \
    -c "SELECT EXISTS (SELECT FROM pg_extension WHERE extname = 'postgis')")

  if [[ "$installed" == t ]]; then
    echo "Upgrading PostGIS in $database"
    psql -X -w --single-transaction -v ON_ERROR_STOP=1 -d "$database" <<'SQL'
SELECT PostGIS_Extensions_Upgrade();
SELECT PostGIS_Full_Version();

DO $$
BEGIN
  IF EXISTS (
    SELECT FROM pg_extension e
    LEFT JOIN pg_available_extensions a ON a.name = e.extname
    WHERE e.extname IN (
      'postgis', 'postgis_topology', 'postgis_raster', 'postgis_sfcgal'
    )
    AND e.extversion IS DISTINCT FROM a.default_version
  ) THEN
    RAISE EXCEPTION 'PostGIS extension versions do not match the image';
  END IF;
END
$$;
SQL
  fi
done <<< "$databases"

gosu postgres pg_ctl -D "$PGDATA" -m fast -w -t 60 stop
trap - EXIT
rmdir "$socket_dir"

echo "PostGIS deployment preparation completed. Backup at $backup_dir"
