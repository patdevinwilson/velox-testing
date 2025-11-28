#!/bin/bash
# Populate TPC-H tables in Hive using external table registration with Glue
# Tables point to existing S3 parquet files - no data movement required
#
# Prerequisites:
#   - Coordinator configured with hive.metastore=glue
#   - AWS credentials passed to coordinator container
#   - S3 parquet data exists at s3://bucket/tpch/sfXXX/<table>/

set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
SSH_KEY="${HOME}/.ssh/rapids-db-io.pem"

cd "${SCRIPT_DIR}"

# Get coordinator IP
COORDINATOR_IP=$(terraform output -raw coordinator_public_ip 2>/dev/null)
if [ -z "${COORDINATOR_IP}" ]; then
    echo "ERROR: Could not get coordinator IP. Is the cluster deployed?"
    exit 1
fi

# Get scale factor from terraform.tfvars or use default
SCALE_FACTOR=$(grep "^benchmark_scale_factor" terraform.tfvars 2>/dev/null | cut -d'"' -f2 || echo "100")
if [[ "${SCALE_FACTOR}" == "none" || -z "${SCALE_FACTOR}" ]]; then
    echo "benchmark_scale_factor=none detected – defaulting to SF100 for schema registration"
    SCALE_FACTOR="100"
fi

# S3 bucket configuration
if [ -f terraform.tfvars ]; then
    S3_BUCKET=$(awk -F'=' '/^s3_tpch_bucket/ {gsub(/[ "]/,"",$2); print $2}' terraform.tfvars | tail -n1)
    S3_PREFIX=$(awk -F'=' '/^s3_tpch_prefix/ {gsub(/[ "]/,"",$2); print $2}' terraform.tfvars | tail -n1)
fi

S3_BUCKET="${S3_BUCKET:-rapids-db-io-us-east-1}"
S3_PREFIX="${S3_PREFIX:-tpch}"

SANITIZED_PREFIX=$(echo "${S3_PREFIX}" | sed 's#^/*##; s#/*$##')
if [ -n "${SANITIZED_PREFIX}" ]; then
    S3_BASE="s3://${S3_BUCKET}/${SANITIZED_PREFIX}/sf${SCALE_FACTOR}"
else
    S3_BASE="s3://${S3_BUCKET}/sf${SCALE_FACTOR}"
fi

TARGET_SCHEMA="tpch_sf${SCALE_FACTOR}"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Registering TPC-H SF${SCALE_FACTOR} External Tables"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Method: Register existing S3 parquet files via Glue"
echo "S3 base path: ${S3_BASE}/<table>/"
echo "Target schema: hive.${TARGET_SCHEMA}"
echo "Coordinator: ${COORDINATOR_IP}"
echo ""

# Run registration on coordinator
ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no ec2-user@${COORDINATOR_IP} bash -s "${SCALE_FACTOR}" "${S3_BASE}" "${TARGET_SCHEMA}" <<'EOFREMOTE'
set -e

SCALE_FACTOR="$1"
S3_BASE="$2"
SCHEMA_NAME="$3"

echo "DEBUG: SCALE_FACTOR=${SCALE_FACTOR}, S3_BASE=${S3_BASE}, SCHEMA_NAME=${SCHEMA_NAME}"

# Wait for Presto to be ready
echo "Waiting for Presto to be ready..."
MAX_WAIT=60
for i in $(seq 1 $MAX_WAIT); do
    if curl -s http://localhost:8080/v1/info >/dev/null 2>&1; then
        echo "✓ Presto is ready"
        break
    fi
    if [ $i -eq $MAX_WAIT ]; then
        echo "ERROR: Presto not ready after ${MAX_WAIT} attempts"
        exit 1
    fi
    sleep 2
done

# Check for active workers
echo "Checking for active workers..."
ACTIVE_WORKERS=$(curl -s http://localhost:8080/v1/cluster 2>/dev/null | grep -o '"activeWorkers":[0-9]*' | cut -d: -f2 || echo "0")
echo "  Active workers: ${ACTIVE_WORKERS}"

# Schema definitions for TPC-H tables
render_schema() {
  local tbl="$1"
  case "$tbl" in
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

# Create schema (Glue database)
echo ""
echo "Creating schema hive.${SCHEMA_NAME}..."
presto --server localhost:8080 --catalog hive --execute "
CREATE SCHEMA IF NOT EXISTS ${SCHEMA_NAME}
" 2>&1 || echo "  (schema may already exist)"
echo "✓ Schema ready"
echo ""

# Register all 8 TPC-H tables
TABLES=(nation region supplier part partsupp customer orders lineitem)
SUCCESS_COUNT=0
FAIL_COUNT=0

for tbl in "${TABLES[@]}"; do
    echo "Registering external table ${tbl} -> ${S3_BASE}/${tbl}/"
    schema_sql=$(render_schema "${tbl}")
    
    if [ -z "${schema_sql}" ]; then
        echo "  ⚠️  No schema defined for ${tbl}, skipping"
        continue
    fi
    
    # Drop existing table if it exists (to allow re-registration)
    presto --server localhost:8080 --catalog hive --schema "${SCHEMA_NAME}" --execute "
DROP TABLE IF EXISTS ${tbl}
" 2>/dev/null || true
    
    # Create external table
    if presto --server localhost:8080 --catalog hive --schema "${SCHEMA_NAME}" --execute "
CREATE TABLE ${tbl} (
${schema_sql}
)
WITH (
    external_location = '${S3_BASE}/${tbl}/',
    format = 'PARQUET'
)
" 2>&1; then
        # Verify table by counting rows
        cnt=$(presto --server localhost:8080 --catalog hive --schema "${SCHEMA_NAME}" \
            --execute "SELECT count(*) FROM ${tbl}" 2>&1 | tail -1 | tr -d '"' || echo "ERROR")
        
        if [[ "${cnt}" =~ ^[0-9]+$ ]]; then
            echo "  ✓ ${tbl}: ${cnt} rows"
            SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
        else
            echo "  ⚠️  ${tbl}: created but count failed (${cnt})"
            FAIL_COUNT=$((FAIL_COUNT + 1))
        fi
    else
        echo "  ✗ ${tbl}: failed to create"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
    echo ""
done

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Registration Summary"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Success: ${SUCCESS_COUNT}/8 tables"
if [ ${FAIL_COUNT} -gt 0 ]; then
    echo "  Failed:  ${FAIL_COUNT}/8 tables"
fi
echo ""

# Run verification query if lineitem was created successfully
if [ ${SUCCESS_COUNT} -ge 1 ]; then
    echo "Verification: TPC-H Q6 on lineitem..."
    result=$(presto --server localhost:8080 --catalog hive --schema "${SCHEMA_NAME}" --execute "
SELECT sum(l_extendedprice * l_discount) as revenue
FROM lineitem
WHERE l_shipdate >= date '1994-01-01'
  AND l_shipdate < date '1995-01-01'
  AND l_discount between 0.05 and 0.07
  AND l_quantity < 24
" 2>&1 | tail -1)
    echo "  Q6 Revenue: ${result}"
fi

EOFREMOTE

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ✅ TPC-H SF${SCALE_FACTOR} Tables Registered in Glue"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Schema: hive.${TARGET_SCHEMA}"
echo "Data:   ${S3_BASE}/<table>/"
echo ""
echo "Access via:"
echo "  ssh -i ~/.ssh/rapids-db-io.pem ec2-user@${COORDINATOR_IP}"
echo "  presto --server localhost:8080 --catalog hive --schema ${TARGET_SCHEMA}"
echo ""
echo "Run benchmark:"
echo "  ./run_tpch_benchmark.sh ${SCALE_FACTOR}"
echo ""
echo "Web UI: http://${COORDINATOR_IP}:8080"
echo ""
