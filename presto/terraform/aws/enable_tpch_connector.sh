#!/bin/bash
# Enable built-in TPC-H connector for immediate benchmarking
# This generates TPC-H data on-the-fly, no S3 required

set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
SSH_KEY="${HOME}/.ssh/rapids-db-io.pem"

cd "${SCRIPT_DIR}"

COORDINATOR_IP=$(terraform output -raw coordinator_public_ip)

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Enabling Built-in TPC-H Connector"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Coordinator: ${COORDINATOR_IP}"
echo ""

ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no ec2-user@${COORDINATOR_IP} << 'EOFREMOTE'
echo "Adding TPC-H catalog..."

sudo tee /opt/presto/etc/catalog/tpch.properties > /dev/null << 'EOF'
connector.name=tpch
tpch.splits-per-node=4
EOF

echo "✓ TPC-H catalog added"
echo ""
echo "Restarting Presto..."
sudo docker restart presto-coordinator
sleep 15

echo "✓ Presto restarted"
echo ""
echo "Testing TPC-H connector..."
echo ""

# List available schemas
echo "Available TPC-H schemas (scale factors):"
presto --server localhost:8080 --catalog tpch --execute "SHOW SCHEMAS;" | grep -E "sf[0-9]+"

echo ""
echo "Testing SF100 customer table:"
presto --server localhost:8080 --catalog tpch --schema sf100 --execute "SELECT count(*) as customer_count FROM customer;"

echo ""
echo "Testing SF100 lineitem table:"
presto --server localhost:8080 --catalog tpch --schema sf100 --execute "SELECT count(*) as lineitem_count FROM lineitem;"

EOFREMOTE

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  TPC-H Connector Enabled!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Run TPC-H queries:"
echo "  ssh -i ~/.ssh/rapids-db-io.pem ec2-user@${COORDINATOR_IP}"
echo "  presto --server localhost:8080 --catalog tpch --schema sf100"
echo ""
echo "Available schemas: tiny, sf1, sf10, sf100, sf1000, sf10000, sf30000, sf100000"
echo ""
echo "Example query:"
echo '  SELECT sum(l_extendedprice * l_discount) as revenue'
echo '  FROM lineitem'
echo "  WHERE l_shipdate >= date '1994-01-01'"
echo "    AND l_shipdate < date '1995-01-01'"
echo "    AND l_discount between 0.05 and 0.07"
echo "    AND l_quantity < 24;"
echo ""

