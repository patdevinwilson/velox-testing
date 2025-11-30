#!/bin/bash
# Run TPC-H benchmark queries and collect results
# Supports automated execution with CSV output

set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
SSH_KEY="${HOME}/.ssh/rapids-db-io.pem"
TFVARS_FILE="${SCRIPT_DIR}/terraform.tfvars"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

cd "${SCRIPT_DIR}"

# Refresh AWS credentials before benchmark
refresh_credentials() {
    echo -e "${BLUE}Refreshing AWS credentials...${NC}"
    
    if command -v nvsec &>/dev/null; then
        CREDS=$(echo "0" | nvsec awsos get-creds --aws-profile default 2>/dev/null | grep -E "aws_access_key_id|aws_secret_access_key|aws_session_token")
        if [ -n "$CREDS" ]; then
            export AWS_ACCESS_KEY_ID=$(echo "$CREDS" | grep "aws_access_key_id" | cut -d'=' -f2 | tr -d ' ')
            export AWS_SECRET_ACCESS_KEY=$(echo "$CREDS" | grep "aws_secret_access_key" | cut -d'=' -f2 | tr -d ' ')
            export AWS_SESSION_TOKEN=$(echo "$CREDS" | grep "aws_session_token" | cut -d'=' -f2 | tr -d ' ')
            
            # Update terraform.tfvars
            sed -i.bak '/^aws_access_key_id/d; /^aws_secret_access_key/d; /^aws_session_token/d' "${TFVARS_FILE}" 2>/dev/null || true
            cat >> "${TFVARS_FILE}" <<EOF

# AWS Credentials (auto-refreshed $(date '+%Y-%m-%d %H:%M:%S'))
aws_access_key_id     = "${AWS_ACCESS_KEY_ID}"
aws_secret_access_key = "${AWS_SECRET_ACCESS_KEY}"
aws_session_token     = "${AWS_SESSION_TOKEN}"
EOF
            echo -e "${GREEN}✓ Credentials refreshed${NC}"
        else
            echo -e "${YELLOW}Warning: Could not get credentials from nvsec${NC}"
        fi
    else
        echo -e "${YELLOW}Warning: nvsec not available, using existing credentials${NC}"
    fi
}

# Update credentials on all cluster nodes
update_cluster_credentials() {
    local coordinator_ip="$1"
    
    echo -e "${BLUE}Updating credentials on cluster nodes...${NC}"
    
    # Update coordinator
    ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no ec2-user@${coordinator_ip} "
        docker rm -f presto-coordinator 2>/dev/null || true
        docker run -d --name presto-coordinator --rm \
            --network host \
            -v /opt/presto/etc:/opt/presto-server/etc:ro \
            -e AWS_ACCESS_KEY_ID='${AWS_ACCESS_KEY_ID}' \
            -e AWS_SECRET_ACCESS_KEY='${AWS_SECRET_ACCESS_KEY}' \
            -e AWS_SESSION_TOKEN='${AWS_SESSION_TOKEN}' \
            presto-coordinator:latest
    " 2>/dev/null

    # Update workers - create service file on each worker with dynamic memory
    for ip in $(terraform output -json worker_public_ips 2>/dev/null | jq -r '.[]' 2>/dev/null); do
        ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o ConnectTimeout=5 ec2-user@$ip "
            # Calculate memory based on instance size (use 85% of total RAM)
            TOTAL_RAM_GB=\$(free -g | awk '/^Mem:/{print \$2}')
            if [ -z \"\$TOTAL_RAM_GB\" ] || [ \"\$TOTAL_RAM_GB\" = \"0\" ]; then
                TOTAL_RAM_MB=\$(free -m | awk '/^Mem:/{print \$2}')
                TOTAL_RAM_GB=\$((TOTAL_RAM_MB / 1024))
            fi
            # Use 85% for docker, leave headroom for OS
            DOCKER_MEM=\$((TOTAL_RAM_GB * 85 / 100))
            # For SF3000, cap at 54GB per worker to prevent OOM on Q21
            if [ \"\$DOCKER_MEM\" -gt 54 ]; then DOCKER_MEM=54; fi
            if [ \"\$DOCKER_MEM\" -lt 8 ]; then DOCKER_MEM=8; fi
            
            # Update config.properties with optimized memory settings
            sudo sed -i \"s/system-memory-gb=.*/system-memory-gb=\${DOCKER_MEM}/\" /opt/presto/etc/config.properties 2>/dev/null || true
            sudo sed -i \"s/query-memory-gb=.*/query-memory-gb=\${DOCKER_MEM}/\" /opt/presto/etc/config.properties 2>/dev/null || true
            sudo sed -i \"s/query.max-memory-per-node=.*/query.max-memory-per-node=\${DOCKER_MEM}GB/\" /opt/presto/etc/config.properties 2>/dev/null || true
            sudo sed -i \"s/query.max-total-memory-per-node=.*/query.max-total-memory-per-node=\${DOCKER_MEM}GB/\" /opt/presto/etc/config.properties 2>/dev/null || true
            sudo sed -i \"s/system-mem-limit-gb=.*/system-mem-limit-gb=\${DOCKER_MEM}/\" /opt/presto/etc/config.properties 2>/dev/null || true
            
            # Ensure SF3000 optimizations are applied
            grep -q 'global-arbitration-enabled' /opt/presto/etc/config.properties || echo 'global-arbitration-enabled=true' | sudo tee -a /opt/presto/etc/config.properties > /dev/null
            grep -q 'memory-pool-abort-capacity-limit' /opt/presto/etc/config.properties || echo 'memory-pool-abort-capacity-limit=40GB' | sudo tee -a /opt/presto/etc/config.properties > /dev/null
            # Reduce concurrency for memory-intensive queries
            sudo sed -i 's/task.concurrency=.*/task.concurrency=8/' /opt/presto/etc/config.properties 2>/dev/null || true
            sudo sed -i 's/task.max-worker-threads=.*/task.max-worker-threads=8/' /opt/presto/etc/config.properties 2>/dev/null || true
            sudo sed -i 's/task.max-drivers-per-task=.*/task.max-drivers-per-task=8/' /opt/presto/etc/config.properties 2>/dev/null || true
            
            sudo tee /etc/systemd/system/presto.service > /dev/null << SVCEOF
[Unit]
Description=Presto Native Worker
After=docker.service
Requires=docker.service

[Service]
Type=simple
User=root
ExecStartPre=-/usr/bin/docker stop presto-worker
ExecStartPre=-/usr/bin/docker rm presto-worker
ExecStart=/usr/bin/docker run --rm --name presto-worker --network host --memory=\${DOCKER_MEM}g --memory-swap=\${DOCKER_MEM}g -v /opt/presto/etc:/opt/presto-server/etc:ro -v /var/presto/data:/var/presto/data -v /var/presto/catalog:/var/presto/catalog -v /var/presto/cache:/var/presto/cache -e LD_LIBRARY_PATH=/usr/local/lib:/usr/local/lib64:/usr/lib:/usr/lib64 -e AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID} -e AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY} -e AWS_SESSION_TOKEN=${AWS_SESSION_TOKEN} presto-native-cpu:latest --etc_dir=/opt/presto-server/etc --logtostderr=1 --v=1
ExecStop=/usr/bin/docker stop presto-worker
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
SVCEOF
            sudo systemctl daemon-reload
            sudo systemctl restart presto
        " 2>/dev/null &
    done
    wait
    
    echo -e "${GREEN}✓ Cluster credentials updated${NC}"
    
    # Wait for workers to reconnect
    echo "Waiting for workers to reconnect..."
    sleep 25
    
    ACTIVE=$(curl -s http://${coordinator_ip}:8080/v1/cluster 2>/dev/null | jq '.activeWorkers' 2>/dev/null || echo "0")
    echo "Active workers: ${ACTIVE}"
}

# Refresh credentials
refresh_credentials

# Parse arguments
SCALE_FACTOR="${1:-}"
OUTPUT_CSV="${2:-tpch_results.csv}"
ANALYZE_FIRST="${3:-true}"

# Get coordinator IP
COORDINATOR_IP=$(terraform output -raw coordinator_public_ip 2>/dev/null)
if [ -z "${COORDINATOR_IP}" ]; then
    echo -e "${RED}ERROR: Could not get coordinator IP. Is the cluster deployed?${NC}"
    exit 1
fi

# Update credentials on cluster nodes
update_cluster_credentials "${COORDINATOR_IP}"

# Get scale factor from terraform.tfvars if not provided
if [ -z "${SCALE_FACTOR}" ]; then
    SCALE_FACTOR=$(grep "^benchmark_scale_factor" terraform.tfvars 2>/dev/null | cut -d'"' -f2 || echo "100")
    if [[ "${SCALE_FACTOR}" == "none" || -z "${SCALE_FACTOR}" ]]; then
        SCALE_FACTOR="100"
    fi
fi

TARGET_SCHEMA="tpch_sf${SCALE_FACTOR}"

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  TPC-H SF${SCALE_FACTOR} Benchmark${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "Coordinator: ${COORDINATOR_IP}"
echo "Schema: hive.${TARGET_SCHEMA}"
echo "Output: ${OUTPUT_CSV}"
echo ""

# Get cluster info
CLUSTER_INFO=$(ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no ec2-user@${COORDINATOR_IP} \
    "curl -s http://localhost:8080/v1/cluster" 2>/dev/null || echo "{}")
ACTIVE_WORKERS=$(echo "${CLUSTER_INFO}" | grep -o '"activeWorkers":[0-9]*' | cut -d: -f2 || echo "0")
echo "Active workers: ${ACTIVE_WORKERS}"
echo ""

# Run benchmark on coordinator
ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no ec2-user@${COORDINATOR_IP} bash -s "${SCALE_FACTOR}" "${TARGET_SCHEMA}" "${ANALYZE_FIRST}" <<'EOFREMOTE'
set -e

SCALE_FACTOR="$1"
SCHEMA_NAME="$2"
ANALYZE_FIRST="$3"

PRESTO="presto --server localhost:8080 --catalog hive --schema ${SCHEMA_NAME}"

# Install bc if not present (needed for runtime calculation)
if ! command -v bc &>/dev/null; then
    echo "Installing bc..."
    sudo dnf install -y bc 2>/dev/null || sudo yum install -y bc 2>/dev/null || true
fi

# Clear OS cache
echo "Clearing OS cache..."
sudo sh -c 'sync && echo 3 > /proc/sys/vm/drop_caches' 2>/dev/null || true

# Analyze tables if requested
if [ "${ANALYZE_FIRST}" = "true" ]; then
    echo ""
    echo "Analyzing tables for query optimization..."
    for tbl in nation region supplier part partsupp customer orders lineitem; do
        echo "  Analyzing ${tbl}..."
        ${PRESTO} --execute "ANALYZE ${tbl}" 2>/dev/null || echo "    (skipped)"
    done
    echo "✓ Table analysis complete"
    echo ""
fi

# TPC-H Queries
declare -A QUERIES

QUERIES[1]='SELECT l_returnflag, l_linestatus, sum(l_quantity) as sum_qty, sum(l_extendedprice) as sum_base_price, sum(l_extendedprice * (1 - l_discount)) as sum_disc_price, sum(l_extendedprice * (1 - l_discount) * (1 + l_tax)) as sum_charge, avg(l_quantity) as avg_qty, avg(l_extendedprice) as avg_price, avg(l_discount) as avg_disc, count(*) as count_order FROM lineitem WHERE l_shipdate <= date '\''1998-12-01'\'' - interval '\''90'\'' day GROUP BY l_returnflag, l_linestatus ORDER BY l_returnflag, l_linestatus'

QUERIES[2]='SELECT s_acctbal, s_name, n_name, p_partkey, p_mfgr, s_address, s_phone, s_comment FROM part, supplier, partsupp, nation, region WHERE p_partkey = ps_partkey AND s_suppkey = ps_suppkey AND p_size = 15 AND p_type like '\''%BRASS'\'' AND s_nationkey = n_nationkey AND n_regionkey = r_regionkey AND r_name = '\''EUROPE'\'' AND ps_supplycost = (SELECT min(ps_supplycost) FROM partsupp, supplier, nation, region WHERE p_partkey = ps_partkey AND s_suppkey = ps_suppkey AND s_nationkey = n_nationkey AND n_regionkey = r_regionkey AND r_name = '\''EUROPE'\'') ORDER BY s_acctbal desc, n_name, s_name, p_partkey LIMIT 100'

QUERIES[3]='SELECT l_orderkey, sum(l_extendedprice * (1 - l_discount)) as revenue, o_orderdate, o_shippriority FROM customer, orders, lineitem WHERE c_mktsegment = '\''BUILDING'\'' AND c_custkey = o_custkey AND l_orderkey = o_orderkey AND o_orderdate < date '\''1995-03-15'\'' AND l_shipdate > date '\''1995-03-15'\'' GROUP BY l_orderkey, o_orderdate, o_shippriority ORDER BY revenue desc, o_orderdate LIMIT 10'

QUERIES[4]='SELECT o_orderpriority, count(*) as order_count FROM orders WHERE o_orderdate >= date '\''1993-07-01'\'' AND o_orderdate < date '\''1993-10-01'\'' AND exists (SELECT * FROM lineitem WHERE l_orderkey = o_orderkey AND l_commitdate < l_receiptdate) GROUP BY o_orderpriority ORDER BY o_orderpriority'

QUERIES[5]='SELECT n_name, sum(l_extendedprice * (1 - l_discount)) as revenue FROM customer, orders, lineitem, supplier, nation, region WHERE c_custkey = o_custkey AND l_orderkey = o_orderkey AND l_suppkey = s_suppkey AND c_nationkey = s_nationkey AND s_nationkey = n_nationkey AND n_regionkey = r_regionkey AND r_name = '\''ASIA'\'' AND o_orderdate >= date '\''1994-01-01'\'' AND o_orderdate < date '\''1995-01-01'\'' GROUP BY n_name ORDER BY revenue desc'

QUERIES[6]='SELECT sum(l_extendedprice * l_discount) as revenue FROM lineitem WHERE l_shipdate >= date '\''1994-01-01'\'' AND l_shipdate < date '\''1995-01-01'\'' AND l_discount between 0.05 and 0.07 AND l_quantity < 24'

QUERIES[7]='SELECT supp_nation, cust_nation, l_year, sum(volume) as revenue FROM (SELECT n1.n_name as supp_nation, n2.n_name as cust_nation, extract(year from l_shipdate) as l_year, l_extendedprice * (1 - l_discount) as volume FROM supplier, lineitem, orders, customer, nation n1, nation n2 WHERE s_suppkey = l_suppkey AND o_orderkey = l_orderkey AND c_custkey = o_custkey AND s_nationkey = n1.n_nationkey AND c_nationkey = n2.n_nationkey AND ((n1.n_name = '\''FRANCE'\'' AND n2.n_name = '\''GERMANY'\'') OR (n1.n_name = '\''GERMANY'\'' AND n2.n_name = '\''FRANCE'\'')) AND l_shipdate between date '\''1995-01-01'\'' AND date '\''1996-12-31'\'') as shipping GROUP BY supp_nation, cust_nation, l_year ORDER BY supp_nation, cust_nation, l_year'

QUERIES[8]='SELECT o_year, sum(case when nation = '\''BRAZIL'\'' then volume else 0 end) / sum(volume) as mkt_share FROM (SELECT extract(year from o_orderdate) as o_year, l_extendedprice * (1 - l_discount) as volume, n2.n_name as nation FROM part, supplier, lineitem, orders, customer, nation n1, nation n2, region WHERE p_partkey = l_partkey AND s_suppkey = l_suppkey AND l_orderkey = o_orderkey AND o_custkey = c_custkey AND c_nationkey = n1.n_nationkey AND n1.n_regionkey = r_regionkey AND r_name = '\''AMERICA'\'' AND s_nationkey = n2.n_nationkey AND o_orderdate between date '\''1995-01-01'\'' AND date '\''1996-12-31'\'' AND p_type = '\''ECONOMY ANODIZED STEEL'\'') as all_nations GROUP BY o_year ORDER BY o_year'

QUERIES[9]='SELECT nation, o_year, sum(amount) as sum_profit FROM (SELECT n_name as nation, extract(year from o_orderdate) as o_year, l_extendedprice * (1 - l_discount) - ps_supplycost * l_quantity as amount FROM part, supplier, lineitem, partsupp, orders, nation WHERE s_suppkey = l_suppkey AND ps_suppkey = l_suppkey AND ps_partkey = l_partkey AND p_partkey = l_partkey AND o_orderkey = l_orderkey AND s_nationkey = n_nationkey AND p_name like '\''%green%'\'') as profit GROUP BY nation, o_year ORDER BY nation, o_year desc'

QUERIES[10]='SELECT c_custkey, c_name, sum(l_extendedprice * (1 - l_discount)) as revenue, c_acctbal, n_name, c_address, c_phone, c_comment FROM customer, orders, lineitem, nation WHERE c_custkey = o_custkey AND l_orderkey = o_orderkey AND o_orderdate >= date '\''1993-10-01'\'' AND o_orderdate < date '\''1994-01-01'\'' AND l_returnflag = '\''R'\'' AND c_nationkey = n_nationkey GROUP BY c_custkey, c_name, c_acctbal, c_phone, n_name, c_address, c_comment ORDER BY revenue desc LIMIT 20'

QUERIES[11]='SELECT ps_partkey, sum(ps_supplycost * ps_availqty) as value FROM partsupp, supplier, nation WHERE ps_suppkey = s_suppkey AND s_nationkey = n_nationkey AND n_name = '\''GERMANY'\'' GROUP BY ps_partkey HAVING sum(ps_supplycost * ps_availqty) > (SELECT sum(ps_supplycost * ps_availqty) * 0.0001 FROM partsupp, supplier, nation WHERE ps_suppkey = s_suppkey AND s_nationkey = n_nationkey AND n_name = '\''GERMANY'\'') ORDER BY value desc'

QUERIES[12]='SELECT l_shipmode, sum(case when o_orderpriority = '\''1-URGENT'\'' OR o_orderpriority = '\''2-HIGH'\'' then 1 else 0 end) as high_line_count, sum(case when o_orderpriority <> '\''1-URGENT'\'' AND o_orderpriority <> '\''2-HIGH'\'' then 1 else 0 end) as low_line_count FROM orders, lineitem WHERE o_orderkey = l_orderkey AND l_shipmode in ('\''MAIL'\'', '\''SHIP'\'') AND l_commitdate < l_receiptdate AND l_shipdate < l_commitdate AND l_receiptdate >= date '\''1994-01-01'\'' AND l_receiptdate < date '\''1995-01-01'\'' GROUP BY l_shipmode ORDER BY l_shipmode'

QUERIES[13]='SELECT c_count, count(*) as custdist FROM (SELECT c_custkey, count(o_orderkey) as c_count FROM customer left outer join orders on c_custkey = o_custkey AND o_comment not like '\''%special%requests%'\'' GROUP BY c_custkey) as c_orders GROUP BY c_count ORDER BY custdist desc, c_count desc'

QUERIES[14]='SELECT 100.00 * sum(case when p_type like '\''PROMO%'\'' then l_extendedprice * (1 - l_discount) else 0 end) / sum(l_extendedprice * (1 - l_discount)) as promo_revenue FROM lineitem, part WHERE l_partkey = p_partkey AND l_shipdate >= date '\''1995-09-01'\'' AND l_shipdate < date '\''1995-10-01'\'''

QUERIES[15]='WITH revenue AS (SELECT l_suppkey as supplier_no, sum(l_extendedprice * (1 - l_discount)) as total_revenue FROM lineitem WHERE l_shipdate >= date '\''1996-01-01'\'' AND l_shipdate < date '\''1996-04-01'\'' GROUP BY l_suppkey) SELECT s_suppkey, s_name, s_address, s_phone, total_revenue FROM supplier, revenue WHERE s_suppkey = supplier_no AND total_revenue = (SELECT max(total_revenue) FROM revenue) ORDER BY s_suppkey'

QUERIES[16]='SELECT p_brand, p_type, p_size, count(distinct ps_suppkey) as supplier_cnt FROM partsupp, part WHERE p_partkey = ps_partkey AND p_brand <> '\''Brand#45'\'' AND p_type not like '\''MEDIUM POLISHED%'\'' AND p_size in (49, 14, 23, 45, 19, 3, 36, 9) AND ps_suppkey not in (SELECT s_suppkey FROM supplier WHERE s_comment like '\''%Customer%Complaints%'\'') GROUP BY p_brand, p_type, p_size ORDER BY supplier_cnt desc, p_brand, p_type, p_size'

QUERIES[17]='SELECT sum(l_extendedprice) / 7.0 as avg_yearly FROM lineitem, part WHERE p_partkey = l_partkey AND p_brand = '\''Brand#23'\'' AND p_container = '\''MED BOX'\'' AND l_quantity < (SELECT 0.2 * avg(l_quantity) FROM lineitem WHERE l_partkey = p_partkey)'

QUERIES[18]='SELECT c_name, c_custkey, o_orderkey, o_orderdate, o_totalprice, sum(l_quantity) FROM customer, orders, lineitem WHERE o_orderkey in (SELECT l_orderkey FROM lineitem GROUP BY l_orderkey HAVING sum(l_quantity) > 300) AND c_custkey = o_custkey AND o_orderkey = l_orderkey GROUP BY c_name, c_custkey, o_orderkey, o_orderdate, o_totalprice ORDER BY o_totalprice desc, o_orderdate LIMIT 100'

QUERIES[19]='SELECT sum(l_extendedprice* (1 - l_discount)) as revenue FROM lineitem, part WHERE (p_partkey = l_partkey AND p_brand = '\''Brand#12'\'' AND p_container in ('\''SM CASE'\'', '\''SM BOX'\'', '\''SM PACK'\'', '\''SM PKG'\'') AND l_quantity >= 1 AND l_quantity <= 11 AND p_size between 1 AND 5 AND l_shipmode in ('\''AIR'\'', '\''AIR REG'\'') AND l_shipinstruct = '\''DELIVER IN PERSON'\'') OR (p_partkey = l_partkey AND p_brand = '\''Brand#23'\'' AND p_container in ('\''MED BAG'\'', '\''MED BOX'\'', '\''MED PKG'\'', '\''MED PACK'\'') AND l_quantity >= 10 AND l_quantity <= 20 AND p_size between 1 AND 10 AND l_shipmode in ('\''AIR'\'', '\''AIR REG'\'') AND l_shipinstruct = '\''DELIVER IN PERSON'\'') OR (p_partkey = l_partkey AND p_brand = '\''Brand#34'\'' AND p_container in ('\''LG CASE'\'', '\''LG BOX'\'', '\''LG PACK'\'', '\''LG PKG'\'') AND l_quantity >= 20 AND l_quantity <= 30 AND p_size between 1 AND 15 AND l_shipmode in ('\''AIR'\'', '\''AIR REG'\'') AND l_shipinstruct = '\''DELIVER IN PERSON'\'')'

QUERIES[20]='SELECT s_name, s_address FROM supplier, nation WHERE s_suppkey in (SELECT ps_suppkey FROM partsupp WHERE ps_partkey in (SELECT p_partkey FROM part WHERE p_name like '\''forest%'\'') AND ps_availqty > (SELECT 0.5 * sum(l_quantity) FROM lineitem WHERE l_partkey = ps_partkey AND l_suppkey = ps_suppkey AND l_shipdate >= date '\''1994-01-01'\'' AND l_shipdate < date '\''1995-01-01'\'')) AND s_nationkey = n_nationkey AND n_name = '\''CANADA'\'' ORDER BY s_name'

QUERIES[21]='SELECT s_name, count(*) as numwait FROM supplier, lineitem l1, orders, nation WHERE s_suppkey = l1.l_suppkey AND o_orderkey = l1.l_orderkey AND o_orderstatus = '\''F'\'' AND l1.l_receiptdate > l1.l_commitdate AND exists (SELECT * FROM lineitem l2 WHERE l2.l_orderkey = l1.l_orderkey AND l2.l_suppkey <> l1.l_suppkey) AND not exists (SELECT * FROM lineitem l3 WHERE l3.l_orderkey = l1.l_orderkey AND l3.l_suppkey <> l1.l_suppkey AND l3.l_receiptdate > l3.l_commitdate) AND s_nationkey = n_nationkey AND n_name = '\''SAUDI ARABIA'\'' GROUP BY s_name ORDER BY numwait desc, s_name LIMIT 100'

QUERIES[22]='SELECT cntrycode, count(*) as numcust, sum(c_acctbal) as totacctbal FROM (SELECT substring(c_phone from 1 for 2) as cntrycode, c_acctbal FROM customer WHERE substring(c_phone from 1 for 2) in ('\''13'\'', '\''31'\'', '\''23'\'', '\''29'\'', '\''30'\'', '\''18'\'', '\''17'\'') AND c_acctbal > (SELECT avg(c_acctbal) FROM customer WHERE c_acctbal > 0.00 AND substring(c_phone from 1 for 2) in ('\''13'\'', '\''31'\'', '\''23'\'', '\''29'\'', '\''30'\'', '\''18'\'', '\''17'\'')) AND not exists (SELECT * FROM orders WHERE o_custkey = c_custkey)) as custsale GROUP BY cntrycode ORDER BY cntrycode'

# CSV header
echo "query,status,runtime_seconds,error"

# Run each query
for q in $(seq 1 22); do
    query="${QUERIES[$q]}"
    
    START_TIME=$(date +%s.%N)
    
    if OUTPUT=$(${PRESTO} --execute "${query}" 2>&1); then
        END_TIME=$(date +%s.%N)
        RUNTIME=$(echo "$END_TIME - $START_TIME" | bc)
        echo "Q${q},success,${RUNTIME},"
    else
        END_TIME=$(date +%s.%N)
        RUNTIME=$(echo "$END_TIME - $START_TIME" | bc)
        ERROR=$(echo "$OUTPUT" | head -1 | tr ',' ';' | tr '\n' ' ')
        echo "Q${q},failed,${RUNTIME},${ERROR}"
    fi
done

EOFREMOTE > "${OUTPUT_CSV}"

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  Benchmark Complete${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "Results saved to: ${OUTPUT_CSV}"
echo ""

# Display summary
SUCCESS_COUNT=$(grep ",success," "${OUTPUT_CSV}" | wc -l)
FAIL_COUNT=$(grep ",failed," "${OUTPUT_CSV}" | wc -l)
echo "Summary: ${SUCCESS_COUNT} passed, ${FAIL_COUNT} failed"
echo ""

# Show failed queries
if [ "${FAIL_COUNT}" -gt 0 ]; then
    echo "Failed queries:"
    grep ",failed," "${OUTPUT_CSV}" | while IFS=, read -r q status runtime error; do
        echo "  ${q}: ${error}"
    done
    echo ""
fi

# Calculate total runtime
TOTAL_RUNTIME=$(grep ",success," "${OUTPUT_CSV}" | awk -F, '{sum+=$3} END {printf "%.2f", sum}')
echo "Total runtime (successful queries): ${TOTAL_RUNTIME}s"
