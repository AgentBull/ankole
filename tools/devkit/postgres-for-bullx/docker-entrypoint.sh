#!/usr/bin/env bash
set -Eeuo pipefail

process_init_files() {
  echo
  local f
  shopt -s nullglob
  for f in /docker-entrypoint-initdb.d/*; do
    case "$f" in
      *.sh)
        if [ -x "$f" ]; then
          echo "$0: running $f"
          "$f"
        else
          echo "$0: sourcing $f"
          # shellcheck source=/dev/null
          . "$f"
        fi
        ;;
      *.sql)
        echo "$0: running $f"
        psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" < "$f"
        echo
        ;;
      *.sql.gz)
        echo "$0: running $f"
        gunzip -c "$f" | psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB"
        echo
        ;;
      *)
        echo "$0: ignoring $f"
        ;;
    esac
    echo
  done
  shopt -u nullglob
}

if [ "${1:0:1}" = "-" ]; then
  set -- postgres "$@"
fi

: "${POSTGRES_USER:=postgres}"
: "${POSTGRES_PASSWORD:=just4local-dev}"
: "${POSTGRES_DB:=$POSTGRES_USER}"
: "${POSTGRES_HOST_AUTH_METHOD:=md5}"
: "${PGDATA:=/var/lib/pgsql/18/data}"
export PGDATA

if [ "$(id -u)" = "0" ]; then
  mkdir -p "$PGDATA"
  chown -R postgres:postgres "$PGDATA" /docker-entrypoint-initdb.d
  chmod 700 "$PGDATA"
  exec /usr/sbin/runuser -u postgres -- "$0" "$@"
fi

if [ "$1" = "postgres" ] && [ ! -s "$PGDATA/PG_VERSION" ]; then
  if [ -z "$POSTGRES_PASSWORD" ] && [ "$POSTGRES_HOST_AUTH_METHOD" != "trust" ]; then
    echo >&2 "Error: Database is uninitialized and POSTGRES_PASSWORD is not set."
    exit 1
  fi

  echo "--- Initializing PostgreSQL ---"
  echo "POSTGRES_USER: ${POSTGRES_USER}"
  echo "POSTGRES_DB: ${POSTGRES_DB}"
  echo "POSTGRES_HOST_AUTH_METHOD: ${POSTGRES_HOST_AUTH_METHOD}"
  echo "-------------------------------"

  initdb -U "$POSTGRES_USER" --pwfile=<(printf "%s\n" "$POSTGRES_PASSWORD")

  pg_ctl -D "$PGDATA" -o "-c listen_addresses=''" -w start

  if [ "$POSTGRES_DB" != "postgres" ]; then
    echo "Creating database '$POSTGRES_DB'..."
    psql --username "$POSTGRES_USER" --dbname postgres -v ON_ERROR_STOP=1 -c "CREATE DATABASE \"$POSTGRES_DB\""
  fi

  process_init_files

  pg_ctl -D "$PGDATA" -m fast -w stop

  {
    echo
    echo "host all all 0.0.0.0/0 $POSTGRES_HOST_AUTH_METHOD"
    echo "host all all ::/0 $POSTGRES_HOST_AUTH_METHOD"
  } >> "$PGDATA/pg_hba.conf"

  echo
  echo "PostgreSQL init process complete; ready for start up."
fi

if [ "$1" = "postgres" ]; then
  set -- "$@" -c listen_addresses="*"
fi

exec "$@"
