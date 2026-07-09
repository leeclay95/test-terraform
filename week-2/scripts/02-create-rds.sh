#!/usr/bin/env bash
# Simulates a "found" RDS instance created by hand, holding user account data.
#
# NOTE ON DATA: Floci backs RDS with a real postgres:16-alpine Docker container
# (per Floci's own docs — RDS is "Real Docker", not a shallow API mock), so we
# seed it with real SQL rows below. `aws rds wait db-instance-available` isn't
# quite enough on its own — it confirms the control-plane status flipped to
# "available", but the postgres process inside the container can still be a
# few seconds behind that. We retry the psql connection a few times before
# giving up, rather than assuming a single failed connection means the engine
# is unreachable (an earlier ad hoc test made exactly that mistake).
set -euo pipefail

: "${AWS_ENDPOINT_URL:=http://localhost:4566}"
export AWS_ENDPOINT_URL
export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-test}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-test}"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
unset AWS_PROFILE

DB_ID="acme-corp-users-db"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EVIDENCE_DIR="$SCRIPT_DIR/../evidence"
mkdir -p "$EVIDENCE_DIR"

# Idempotent: skip creation if the instance already exists, so the script can be
# re-run to (re)seed without hitting DBInstanceAlreadyExists under `set -e`.
if aws rds describe-db-instances --db-instance-identifier "$DB_ID" >/dev/null 2>&1; then
  echo "== RDS instance $DB_ID already exists — skipping create =="
else
  echo "== Creating RDS instance: $DB_ID =="
  aws rds create-db-instance \
    --db-instance-identifier "$DB_ID" \
    --db-instance-class db.t3.micro \
    --engine postgres \
    --engine-version 16.3 \
    --master-username appadmin \
    --master-user-password "DemoPass123!" \
    --allocated-storage 20 \
    --db-name appdb \
    --no-multi-az \
    --tags Key=data-classification,Value=pii Key=owner,Value=acme-corp-app-team Key=demo,Value=week-2-import \
    > "$EVIDENCE_DIR/rds_create_response.json"
fi

echo "== Waiting for instance to report available =="
aws rds wait db-instance-available --db-instance-identifier "$DB_ID"

aws rds describe-db-instances --db-instance-identifier "$DB_ID" > "$EVIDENCE_DIR/rds_describe.json"

# Floci reports the endpoint as localhost:7001, but its docker-compose only
# publishes 4566 — the backing postgres container's port is NOT mapped to the
# host, so localhost:7001 is unreachable (connection refused). Connect straight
# to the container instead: it listens on 5432 on the Docker bridge, reachable
# from the host by the container's IP. This works regardless of whether Floci
# publishes the RDS port.
RDS_ENDPOINT_ADDR=$(python3 -c "import json; print(json.load(open('$EVIDENCE_DIR/rds_describe.json'))['DBInstances'][0]['Endpoint']['Address'])")
RDS_ENDPOINT_PORT=$(python3 -c "import json; print(json.load(open('$EVIDENCE_DIR/rds_describe.json'))['DBInstances'][0]['Endpoint']['Port'])")

CONTAINER="floci-rds-$DB_ID"
echo "== Locating backing container: $CONTAINER =="
DB_HOST=""
for i in $(seq 1 10); do
  DB_HOST=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$CONTAINER" 2>/dev/null || true)
  [ -n "$DB_HOST" ] && break
  sleep 2
done
if [ -z "$DB_HOST" ]; then
  echo "  Could not find/inspect container $CONTAINER — is Floci running? (docker ps | grep $DB_ID)" >&2
  exit 1
fi
DB_PORT=5432
echo "  Floci endpoint (metadata):    $RDS_ENDPOINT_ADDR:$RDS_ENDPOINT_PORT  (not host-published)"
echo "  Reachable endpoint (in use):  $DB_HOST:$DB_PORT"

# Fake-data conventions match the bucket script: example.com emails, an
# invalid 000-xx-xxxx SSN prefix never issued to a real person.
cat > "$EVIDENCE_DIR/simulated_users.csv" <<'CSV'
id,username,email,ssn,signup_date
1,ttesterson1,fake.user1@example.com,000-01-0001,2023-01-04
2,ttesterson2,fake.user2@example.com,000-02-0002,2023-02-11
3,ttesterson3,fake.user3@example.com,000-03-0003,2023-03-22
4,ttesterson4,fake.user4@example.com,000-04-0004,2023-05-09
5,ttesterson5,fake.user5@example.com,000-05-0005,2023-07-17
CSV

echo "== Waiting for the Postgres engine inside the container to accept connections =="
ready=""
for i in $(seq 1 20); do
  if PGPASSWORD="DemoPass123!" psql -h "$DB_HOST" -p "$DB_PORT" -U appadmin -d appdb -c '\q' 2>/dev/null; then
    ready=1
    break
  fi
  sleep 3
done
if [ -z "$ready" ]; then
  echo "  Postgres never came up after 60s — check: docker ps | grep postgres" >&2
  exit 1
fi

echo "== Seeding real rows into $DB_ID =="
PGPASSWORD="DemoPass123!" psql -h "$DB_HOST" -p "$DB_PORT" -U appadmin -d appdb <<SQL
CREATE TABLE IF NOT EXISTS users (
  id integer PRIMARY KEY,
  username text NOT NULL,
  email text NOT NULL,
  ssn text NOT NULL,
  signup_date date NOT NULL
);
-- Idempotent seed: clear existing rows so a re-run doesn't hit duplicate-key
-- errors on the id primary key.
TRUNCATE users;
SQL
PGPASSWORD="DemoPass123!" psql -h "$DB_HOST" -p "$DB_PORT" -U appadmin -d appdb \
  -c "\copy users FROM '$EVIDENCE_DIR/simulated_users.csv' WITH (FORMAT csv, HEADER true)"
PGPASSWORD="DemoPass123!" psql -h "$DB_HOST" -p "$DB_PORT" -U appadmin -d appdb \
  -c "SELECT * FROM users;" > "$EVIDENCE_DIR/rds_seeded_rows.txt"

echo
echo "== Done. =="
echo "  Instance ID:  $DB_ID"
echo "  Endpoint:     $DB_HOST:$DB_PORT"
echo "  Describe output: evidence/rds_describe.json"
echo "  Seeded rows:  evidence/rds_seeded_rows.txt"
echo "  Verify with:  PGPASSWORD='DemoPass123!' psql -h $DB_HOST -p $DB_PORT -U appadmin -d appdb -c 'SELECT * FROM users;'"
