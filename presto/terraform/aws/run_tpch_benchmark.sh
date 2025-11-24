#!/bin/bash
# Run TPC-H benchmark queries on deployed cluster
# Automatically runs after table population completes

set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
SSH_KEY="${HOME}/.ssh/rapids-db-io.pem"

cd "${SCRIPT_DIR}"

COORDINATOR_IP=$(terraform output -raw coordinator_public_ip)
SCALE_FACTOR=$(grep "^benchmark_scale_factor" terraform.tfvars | cut -d'"' -f2)

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Running TPC-H Benchmark Queries"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Coordinator: ${COORDINATOR_IP}"
echo "Scale Factor: SF${SCALE_FACTOR}"
echo "Catalog: hive.tpch"
echo ""

ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no ec2-user@${COORDINATOR_IP} bash << 'EOFREMOTE'
set -e

echo "Running TPC-H Query 1 (Pricing Summary Report)..."
presto --server localhost:8080 --catalog hive --schema tpch --execute "
SELECT
    l_returnflag,
    l_linestatus,
    sum(l_quantity) as sum_qty,
    sum(l_extendedprice) as sum_base_price,
    sum(l_extendedprice * (1 - l_discount)) as sum_disc_price,
    sum(l_extendedprice * (1 - l_discount) * (1 + l_tax)) as sum_charge,
    avg(l_quantity) as avg_qty,
    avg(l_extendedprice) as avg_price,
    avg(l_discount) as avg_disc,
    count(*) as count_order
FROM lineitem
WHERE l_shipdate <= date '1998-09-01'
GROUP BY l_returnflag, l_linestatus
ORDER BY l_returnflag, l_linestatus;
" | head -20

echo ""
echo "Running TPC-H Query 6 (Forecasting Revenue Change)..."
presto --server localhost:8080 --catalog hive --schema tpch --execute "
SELECT sum(l_extendedprice * l_discount) as revenue
FROM lineitem
WHERE l_shipdate >= date '1994-01-01'
  AND l_shipdate < date '1995-01-01'
  AND l_discount between 0.05 and 0.07
  AND l_quantity < 24;
"

echo ""
echo "✓ Benchmark queries completed"

EOFREMOTE

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Benchmark Complete"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "View detailed results in Web UI: http://${COORDINATOR_IP}:8080"
echo ""
echo "Run more queries:"
echo "  ssh -i ~/.ssh/rapids-db-io.pem ec2-user@${COORDINATOR_IP}"
echo "  presto --server localhost:8080 --catalog hive --schema tpch"
echo ""

