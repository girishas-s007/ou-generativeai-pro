#!/bin/bash
# Start or recreate the Oracle Database Free Podman container on gen-ai lab VMs.
# Safe to run repeatedly (idempotent). Requires root (sudo).

set -euo pipefail

DB_CONTAINER="26ai"
ORADATA="/home/opc/oradata"
IMAGE="container-registry.oracle.com/database/free:latest"
PASSWORD_FILE="/home/opc/db_password.txt"
LOGFILE="/var/log/start-oracle-db.log"

exec > >(tee -a "$LOGFILE") 2>&1

echo "===== $(date '+%Y-%m-%d %H:%M:%S') start-oracle-db.sh ====="

if ! command -v podman >/dev/null 2>&1; then
  echo "ERROR: podman is not installed."
  exit 1
fi

echo "Ensuring Oracle data directory exists..."
mkdir -p "$ORADATA"
chown -R 54321:54321 "$ORADATA"
chmod -R 755 "$ORADATA"

if [ -f "$PASSWORD_FILE" ]; then
  ORACLE_PWD="$(tr -d '[:space:]' < "$PASSWORD_FILE")"
  echo "Using existing SYS password from $PASSWORD_FILE"
else
  ORACLE_PWD="$(openssl rand -hex 16)"
  echo "$ORACLE_PWD" > "$PASSWORD_FILE"
  chown opc:opc "$PASSWORD_FILE"
  chmod 600 "$PASSWORD_FILE"
  echo "Generated new SYS password in $PASSWORD_FILE"
fi

if podman ps -a --format '{{.Names}}' | grep -qx "$DB_CONTAINER"; then
  if podman ps --format '{{.Names}}' | grep -qx "$DB_CONTAINER"; then
    echo "Container $DB_CONTAINER is already running."
  else
    echo "Starting stopped container $DB_CONTAINER..."
    podman start "$DB_CONTAINER"
  fi
else
  echo "Creating Oracle container $DB_CONTAINER..."
  podman run -d \
    --name "$DB_CONTAINER" \
    --network=host \
    -e ORACLE_PWD="$ORACLE_PWD" \
    -v "$ORADATA:/opt/oracle/oradata:z" \
    "$IMAGE"
fi

echo "Waiting for Oracle listener (FREE service)..."
MAX_RETRIES=60
for i in $(seq 1 $MAX_RETRIES); do
  if podman exec "$DB_CONTAINER" lsnrctl status 2>/dev/null | grep -q "FREE "; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') FREE service is registered."
    break
  fi
  echo "$(date '+%Y-%m-%d %H:%M:%S') [$i/$MAX_RETRIES] Waiting for listener..."
  sleep 10
done

if ! podman exec "$DB_CONTAINER" lsnrctl status 2>/dev/null | grep -q "FREEPDB1"; then
  echo "$(date '+%Y-%m-%d %H:%M:%S') FREEPDB1 not registered. Opening PDBs..."
  podman exec "$DB_CONTAINER" bash <<'EOF'
sqlplus -S / as sysdba <<'EOSQL'
ALTER SYSTEM SET LOCAL_LISTENER = '(ADDRESS=(PROTOCOL=TCP)(HOST=127.0.0.1)(PORT=1521))' SCOPE=BOTH;
ALTER SYSTEM REGISTER;
ALTER PLUGGABLE DATABASE ALL OPEN;
ALTER PLUGGABLE DATABASE ALL SAVE STATE;
EXIT;
EOSQL
EOF
fi

echo "Ensuring lab user and tablespaces exist in FREEPDB1..."
podman exec -i "$DB_CONTAINER" bash <<'EOF'
sqlplus -S / as sysdba <<'EOSQL'
ALTER SESSION SET CONTAINER=FREEPDB1;
DECLARE
  user_exists NUMBER;
  ts_exists   NUMBER;
BEGIN
  SELECT COUNT(*) INTO user_exists FROM dba_users WHERE username = 'VECTOR';
  IF user_exists = 0 THEN
    SELECT COUNT(*) INTO ts_exists FROM dba_tablespaces WHERE tablespace_name = 'TBS2';
    IF ts_exists = 0 THEN
      EXECUTE IMMEDIATE q'[
        CREATE BIGFILE TABLESPACE tbs2 DATAFILE 'bigtbs_f2.dbf' SIZE 1G AUTOEXTEND ON NEXT 32M MAXSIZE UNLIMITED EXTENT MANAGEMENT LOCAL SEGMENT SPACE MANAGEMENT AUTO
      ]';
    END IF;
    SELECT COUNT(*) INTO ts_exists FROM dba_tablespaces WHERE tablespace_name = 'UNDOTS2';
    IF ts_exists = 0 THEN
      EXECUTE IMMEDIATE q'[
        CREATE UNDO TABLESPACE undots2 DATAFILE 'undotbs_2a.dbf' SIZE 1G AUTOEXTEND ON RETENTION GUARANTEE
      ]';
    END IF;
    SELECT COUNT(*) INTO ts_exists FROM dba_tablespaces WHERE tablespace_name = 'TEMP_DEMO';
    IF ts_exists = 0 THEN
      EXECUTE IMMEDIATE q'[
        CREATE TEMPORARY TABLESPACE temp_demo TEMPFILE 'temp02.dbf' SIZE 1G REUSE AUTOEXTEND ON NEXT 32M MAXSIZE UNLIMITED EXTENT MANAGEMENT LOCAL UNIFORM SIZE 1M
      ]';
    END IF;
    EXECUTE IMMEDIATE 'CREATE USER vector IDENTIFIED BY vector DEFAULT TABLESPACE tbs2 QUOTA UNLIMITED ON tbs2';
    EXECUTE IMMEDIATE 'GRANT DB_DEVELOPER_ROLE TO vector';
  END IF;
END;
/
EXIT;
EOSQL
EOF

echo "Verifying port 1521 is listening on localhost..."
if ! ss -ltn | grep -q ':1521'; then
  echo "WARNING: nothing is listening on port 1521 yet. The database may still be initializing."
  echo "Re-run this script in a few minutes, or check: sudo podman logs $DB_CONTAINER"
  exit 1
fi

echo "Final listener status:"
podman exec "$DB_CONTAINER" bash -lc "lsnrctl services"

echo "===== Oracle Database is ready ====="
echo "Connect with DSN: localhost/FREEPDB1"
echo "Lab user: vector / vector"
echo "SYS password: $PASSWORD_FILE"
