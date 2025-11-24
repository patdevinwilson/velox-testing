#!/bin/bash
# Populate TPC-H tables in Hive using the proven CTAS pattern
# Tables are created as managed tables (stored in S3) populated from tpch.sf100
# This gives functionally equivalent results to external S3 tables

set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
SSH_KEY="${HOME}/.ssh/rapids-db-io.pem"

cd "${SCRIPT_DIR}"

COORDINATOR_IP=$(terraform output -raw coordinator_public_ip)
SCALE_FACTOR=$(grep "^benchmark_scale_factor" terraform.tfvars | cut -d'"' -f2)
ENABLE_HMS=$(terraform output -raw hms_enabled 2>/dev/null || echo "false")

if [[ "${SCALE_FACTOR}" == "none" || -z "${SCALE_FACTOR}" ]]; then
    echo "benchmark_scale_factor=none detected – defaulting to SF100 for schema registration"
    SCALE_FACTOR="100"
fi

if [ -f terraform.tfvars ]; then
    S3_BUCKET=$(awk -F'=' '/^s3_tpch_bucket/ {gsub(/[ "]/,"",$2); print $2}' terraform.tfvars | tail -n1)
    S3_PREFIX=$(awk -F'=' '/^s3_tpch_prefix/ {gsub(/[ "]/,"",$2); print $2}' terraform.tfvars | tail -n1)
fi

if [ -z "${S3_BUCKET}" ]; then
    S3_BUCKET="rapids-db-io-us-east-1"
fi

if [ -z "${S3_PREFIX}" ]; then
    S3_PREFIX="tpch"
fi

SANITIZED_PREFIX=$(echo "${S3_PREFIX}" | sed 's#^/*##; s#/*$##')
if [ -n "${SANITIZED_PREFIX}" ]; then
    S3_BASE="s3://${S3_BUCKET}/${SANITIZED_PREFIX}/sf${SCALE_FACTOR}"
else
    S3_BASE="s3://${S3_BUCKET}/sf${SCALE_FACTOR}"
fi

if [ "${ENABLE_HMS}" = "true" ]; then
    LOAD_MODE="external"
    TARGET_SCHEMA="tpch_s3"
else
    LOAD_MODE="managed"
    TARGET_SCHEMA="tpch"
fi

LOAD_MODE_DISPLAY=$(echo "${LOAD_MODE}" | tr '[:lower:]' '[:upper:]')

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Populating TPC-H SF${SCALE_FACTOR} Tables (${LOAD_MODE_DISPLAY} mode)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
if [ "${LOAD_MODE}" = "external" ]; then
    echo "Method: Register existing S3 parquet files via HMS"
    echo "S3 base path: ${S3_BASE}/<table>/"
else
    echo "Method: CREATE TABLE AS SELECT from tpch.sf${SCALE_FACTOR}"
    echo "Result: Managed Hive tables stored in S3"
fi
echo "Coordinator: ${COORDINATOR_IP}"
echo ""

ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no ec2-user@${COORDINATOR_IP} bash << EOFREMOTE
set -e

MODE="${LOAD_MODE}"
SCALE_FACTOR="${SCALE_FACTOR}"
S3_BASE="${S3_BASE}"

render_schema() {
  local table="\$1"
  case "\${table}" in
    customer)
cat <<'EOF'
c_custkey BIGINT,
c_name VARCHAR,
c_address VARCHAR,
c_nationkey BIGINT,
c_phone VARCHAR,
c_acctbal DOUBLE,
c_mktsegment VARCHAR,
c_comment VARCHAR
EOF
;;
    orders)
cat <<'EOF'
o_orderkey BIGINT,
o_custkey BIGINT,
o_orderstatus VARCHAR,
o_totalprice DOUBLE,
o_orderdate DATE,
o_orderpriority VARCHAR,
o_clerk VARCHAR,
o_shippriority INTEGER,
o_comment VARCHAR
EOF
;;
    lineitem)
cat <<'EOF'
l_orderkey BIGINT,
l_partkey BIGINT,
l_suppkey BIGINT,
l_linenumber INTEGER,
l_quantity DOUBLE,
l_extendedprice DOUBLE,
l_discount DOUBLE,
l_tax DOUBLE,
l_returnflag VARCHAR,
l_linestatus VARCHAR,
l_shipdate DATE,
l_commitdate DATE,
l_receiptdate DATE,
l_shipinstruct VARCHAR,
l_shipmode VARCHAR,
l_comment VARCHAR
EOF
;;
    part)
cat <<'EOF'
p_partkey BIGINT,
p_name VARCHAR,
p_mfgr VARCHAR,
p_brand VARCHAR,
p_type VARCHAR,
p_size INTEGER,
p_container VARCHAR,
p_retailprice DOUBLE,
p_comment VARCHAR
EOF
;;
    supplier)
cat <<'EOF'
s_suppkey BIGINT,
s_name VARCHAR,
s_address VARCHAR,
s_nationkey BIGINT,
s_phone VARCHAR,
s_acctbal DOUBLE,
s_comment VARCHAR
EOF
;;
    partsupp)
cat <<'EOF'
ps_partkey BIGINT,
ps_suppkey BIGINT,
ps_availqty INTEGER,
ps_supplycost DOUBLE,
ps_comment VARCHAR
EOF
;;
    nation)
cat <<'EOF'
n_nationkey BIGINT,
n_name VARCHAR,
n_regionkey BIGINT,
n_comment VARCHAR
EOF
;;
    region)
cat <<'EOF'
r_regionkey BIGINT,
r_name VARCHAR,
r_comment VARCHAR
EOF
;;
    *)
      echo ""
      ;;
  esac
}

if [ "\${MODE}" = "external" ]; then
  SCHEMA_NAME="tpch_s3"
  echo "Creating schema hive.\${SCHEMA_NAME}..."
  presto --server localhost:8080 --catalog hive --execute "
  DROP SCHEMA IF EXISTS hive.\${SCHEMA_NAME} CASCADE;
  CREATE SCHEMA hive.\${SCHEMA_NAME};
  " >/dev/null 2>&1 || true
  echo "✓ Schema ready"
  echo ""

  TABLES=(nation region supplier part partsupp customer orders lineitem)
  for table in "\${TABLES[@]}"; do
    echo "Registering external table \${table} -> \${S3_BASE}/\${table}/"
    schema_sql=\$(render_schema "\${table}")
    if [ -z "\${schema_sql}" ]; then
      echo "  ⚠️  No schema defined for \${table}, skipping"
      continue
    fi
    presto --server localhost:8080 --catalog hive --schema "\${SCHEMA_NAME}" --file - <<SQL
CREATE TABLE IF NOT EXISTS \${table} (
\${schema_sql}
)
WITH (
    external_location = '\${S3_BASE}/\${table}/',
    format = 'PARQUET'
);
SQL
    count=\$(presto --server localhost:8080 --catalog hive --schema "\${SCHEMA_NAME}" \
        --execute "SELECT count(*) FROM \${table};" 2>&1 | tail -1 | tr -d '"')
    echo "  ✓ \${table}: \${count} rows"
    echo ""
  done

  echo "External registration complete. Query tables via hive.\${SCHEMA_NAME}"
else
  SCHEMA_NAME="tpch"
  CREATE_ALL="false"
  if [ "\${SCALE_FACTOR}" = "100" ]; then
    CREATE_ALL="true"
  fi

  echo "Creating hive.\${SCHEMA_NAME} schema..."
  presto --server localhost:8080 --catalog hive --execute "
  DROP SCHEMA IF EXISTS hive.\${SCHEMA_NAME} CASCADE;
  CREATE SCHEMA hive.\${SCHEMA_NAME};
  " >/dev/null 2>&1 || true
  echo "✓ Schema ready"
  echo ""

  echo "Creating dimension tables..."
  for table in nation region; do
    echo "  - \${table}"
    presto --server localhost:8080 --catalog hive --schema "\${SCHEMA_NAME}" --execute "
      CREATE TABLE \${table} WITH (format = 'PARQUET') AS
      SELECT * FROM tpch.sf\${SCALE_FACTOR}.\${table};
    " >/dev/null 2>&1
    count=\$(presto --server localhost:8080 --catalog hive --schema "\${SCHEMA_NAME}" \
      --execute "SELECT count(*) FROM \${table};" 2>&1 | tail -1 | tr -d '"')
    echo "    ✓ rows: \${count}"
  done
  echo ""

  echo "Creating medium tables..."
  for table in supplier part customer; do
    echo "  - \${table}"
    presto --server localhost:8080 --catalog hive --schema "\${SCHEMA_NAME}" --execute "
      CREATE TABLE \${table} WITH (format = 'PARQUET') AS
      SELECT * FROM tpch.sf\${SCALE_FACTOR}.\${table};
    " >/dev/null 2>&1
    count=\$(presto --server localhost:8080 --catalog hive --schema "\${SCHEMA_NAME}" \
      --execute "SELECT count(*) FROM \${table};" 2>&1 | tail -1 | tr -d '"')
    echo "    ✓ rows: \${count}"
  done
  echo ""

  echo "Creating partsupp..."
  presto --server localhost:8080 --catalog hive --schema "\${SCHEMA_NAME}" --execute "
    CREATE TABLE partsupp WITH (format = 'PARQUET') AS
    SELECT * FROM tpch.sf\${SCALE_FACTOR}.partsupp;
  " >/dev/null 2>&1
  count=\$(presto --server localhost:8080 --catalog hive --schema "\${SCHEMA_NAME}" \
    --execute "SELECT count(*) FROM partsupp;" 2>&1 | tail -1 | tr -d '"')
  echo "    ✓ partsupp rows: \${count}"
  echo ""

  if [ "\${CREATE_ALL}" = "true" ]; then
    echo "Creating large fact tables (orders, lineitem)..."
    presto --server localhost:8080 --catalog hive --schema "\${SCHEMA_NAME}" --execute "
      CREATE TABLE orders WITH (format = 'PARQUET') AS
      SELECT * FROM tpch.sf\${SCALE_FACTOR}.orders;
    " >/dev/null 2>&1
    presto --server localhost:8080 --catalog hive --schema "\${SCHEMA_NAME}" --execute "
      CREATE TABLE lineitem WITH (format = 'PARQUET') AS
      SELECT * FROM tpch.sf\${SCALE_FACTOR}.lineitem;
    " >/dev/null 2>&1
    for table in orders lineitem; do
      count=\$(presto --server localhost:8080 --catalog hive --schema "\${SCHEMA_NAME}" \
        --execute "SELECT count(*) FROM \${table};" 2>&1 | tail -1 | tr -d '"')
      echo "    ✓ \${table}: \${count} rows"
    done
  else
    echo "Skipping orders and lineitem CTAS for SF\${SCALE_FACTOR} (use tpch.sf\${SCALE_FACTOR})"
  fi

  echo ""
  echo "Verification query (TPC-H Q6)..."
  presto --server localhost:8080 --catalog hive --schema "\${SCHEMA_NAME}" --execute "
  SELECT sum(l_extendedprice * l_discount) as revenue
  FROM lineitem
  WHERE l_shipdate >= date '1994-01-01'
    AND l_shipdate < date '1995-01-01'
    AND l_discount between 0.05 and 0.07
    AND l_quantity < 24;
  " 2>&1 | tail -1
fi

EOFREMOTE

if [ "${LOAD_MODE}" = "external" ]; then
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  ✅ External TPCH tables registered via HMS!"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "Schema: hive.tpch_s3"
    echo "Backed by: ${S3_BASE}/<table>/"
else
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  ✅ Managed TPCH tables written to S3!"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "Schema: hive.tpch"
    echo "Data: SF${SCALE_FACTOR}"
fi

echo ""
echo "Access via:"
echo "  ssh -i ~/.ssh/rapids-db-io.pem ec2-user@${COORDINATOR_IP}"
echo "  presto --server localhost:8080 --catalog hive --schema ${TARGET_SCHEMA}"
echo ""
echo "Web UI: http://${COORDINATOR_IP}:8080"
echo ""

