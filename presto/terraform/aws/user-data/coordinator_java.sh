#!/bin/bash
set -e

# Logging
exec > >(tee /var/log/user-data.log)
exec 2>&1

echo "=== Starting Presto Java Coordinator Setup ==="
date

ENABLE_HMS="${enable_hms}"
%{ if enable_hms }
HMS_DB_ENDPOINT="${hms_db_endpoint}"
HMS_DB_NAME="${hms_db_name}"
HMS_DB_USER="${hms_db_user}"
HMS_DB_PASSWORD="${hms_db_password}"
HIVE_WAREHOUSE_DIR="${hive_warehouse_dir}"
%{ endif }

# Update system
dnf update -y

# Install dependencies (Java 11 for better Presto 0.289 compatibility)
# Note: --allowerasing fixes curl-minimal conflict in AL2023 ECS Optimized AMI
dnf install -y --allowerasing java-11-amazon-corretto java-11-amazon-corretto-devel \
  python3 python3-pip wget curl htop docker mariadb105 awscli jq
systemctl enable --now docker

# Configure environment
export JAVA_HOME=/usr/lib/jvm/java-11-amazon-corretto
echo "export JAVA_HOME=/usr/lib/jvm/java-11-amazon-corretto" >> /etc/profile.d/java.sh

# Create python symlink (AL2023 only has python3, Presto needs 'python')
ln -sf /usr/bin/python3 /usr/bin/python

# Configure AWS credentials
mkdir -p /root/.aws
cat > /root/.aws/credentials << 'AWSCREDS'
[default]
aws_access_key_id = ${aws_access_key_id}
aws_secret_access_key = ${aws_secret_access_key}
aws_session_token = ${aws_session_token}
AWSCREDS

cat > /root/.aws/config << 'AWSCONFIG'
[default]
region = us-east-1
output = json
AWSCONFIG

chmod 600 /root/.aws/credentials
chmod 600 /root/.aws/config

# Create directories
mkdir -p /opt/presto/etc/catalog /var/presto/data

# Create data and log directories
mkdir -p /var/presto/data /var/presto/catalog /opt/hms/conf

# Download Presto Coordinator Docker image from S3
echo "Downloading Presto Coordinator image from S3..."
COORDINATOR_IMAGE_SOURCE="s3://rapids-db-io-us-east-1/docker-images/presto-coordinator-matched-latest.tar.gz"
IMAGE_FILE="/tmp/presto-coordinator.tar.gz"

export AWS_ACCESS_KEY_ID="${aws_access_key_id}"
export AWS_SECRET_ACCESS_KEY="${aws_secret_access_key}"
export AWS_SESSION_TOKEN="${aws_session_token}"
export AWS_DEFAULT_REGION="us-east-1"

aws s3 cp "$${COORDINATOR_IMAGE_SOURCE}" "$${IMAGE_FILE}"
echo "✓ Downloaded coordinator image (size: $(du -h $${IMAGE_FILE} | cut -f1))"

echo "Loading coordinator image into Docker..."
LOAD_OUTPUT=$(gunzip -c "$${IMAGE_FILE}" | docker load)
echo "$${LOAD_OUTPUT}"

LOADED_IMAGE=$(echo "$${LOAD_OUTPUT}" | grep -oP 'Loaded image: \K.*' || echo "presto-coordinator:latest")
echo "Loaded image: $${LOADED_IMAGE}"

# Tag for consistency
docker tag "$${LOADED_IMAGE}" "presto-coordinator:latest"
rm -f "$${IMAGE_FILE}"

echo "✓ Coordinator image ready"
echo ""

# Detect instance resources for dynamic configuration
TOTAL_RAM_GB=$(free -g | awk '/^Mem:/ {print $2}')
VCPUS=$(nproc)

# Memory calculations using velox-testing params.json methodology
# Based on: velox-testing/presto/docker/config/params.json
# System reserved: 5% of RAM, capped at 2GB
# JVM heap: 90% of (RAM - system_reserved)
# Query memory per node: 60% of heap (to leave 30-40% headroom for Presto internals)

# System reserved memory (5% of total, cap at 2GB)
SYSTEM_RESERVED_GB=$((TOTAL_RAM_GB * 5 / 100))
if [ "$SYSTEM_RESERVED_GB" -gt 2 ]; then SYSTEM_RESERVED_GB=2; fi

# JVM Heap: 90% of (RAM - system_reserved)
USABLE_RAM_GB=$((TOTAL_RAM_GB - SYSTEM_RESERVED_GB))
JVM_HEAP_GB=$((USABLE_RAM_GB * 90 / 100))

# Query memory: heap * 0.60 (leaving 40% headroom for Presto internal memory)
QUERY_MEM_PER_NODE_GB=$((JVM_HEAP_GB * 60 / 100))

# Worker memory calculation based on instance type
# Native workers use 90% of (RAM - 2GB system reserved) for query processing
WORKER_INSTANCE_TYPE="${worker_instance_type}"
WORKER_COUNT=${worker_count}

# Map instance types to their approximate usable RAM (after system reserved)
# Format: RAM_GB - 2GB system reserved
get_worker_query_memory() {
  case "$1" in
    r7i.xlarge)    echo 28 ;;    # 32GB - 2GB = 30GB, 90% = 27GB, round to 28GB
    r7i.2xlarge)   echo 56 ;;    # 64GB - 2GB = 62GB, 90% = 55.8GB
    r7i.4xlarge)   echo 113 ;;   # 128GB - 2GB = 126GB, 90% = 113.4GB
    r7i.8xlarge)   echo 227 ;;   # 256GB - 2GB = 254GB, 90% = 228.6GB
    r7i.12xlarge)  echo 341 ;;   # 384GB - 2GB = 382GB, 90% = 343.8GB
    r7i.16xlarge)  echo 456 ;;   # 512GB - 2GB = 510GB, 90% = 459GB
    r7i.24xlarge)  echo 686 ;;   # 768GB - 2GB = 766GB, 90% = 689.4GB (actual ~703GB system mem * 0.9 = 632GB)
    r7i.48xlarge)  echo 1374 ;;  # 1536GB - 2GB = 1534GB, 90% = 1380.6GB
    *)
      # Default fallback: assume similar to coordinator
      echo $${QUERY_MEM_PER_NODE_GB}
      ;;
  esac
}

WORKER_QUERY_MEM_GB=$(get_worker_query_memory "$${WORKER_INSTANCE_TYPE}")

# Total cluster memory = coordinator memory + (worker memory × worker count)
TOTAL_CLUSTER_MEM_GB=$((QUERY_MEM_PER_NODE_GB + (WORKER_QUERY_MEM_GB * WORKER_COUNT)))

# Task concurrency: For large scale factors, increase concurrency
SCALE_FACTOR=${benchmark_scale_factor}
if [ "$SCALE_FACTOR" -ge 1000 ]; then
  TASK_CONCURRENCY=$((VCPUS * 6))
else
  TASK_CONCURRENCY=$((VCPUS * 4))
fi

# Bounds: min 8, max based on RAM (1 task per 2GB heap)
MAX_CONCURRENCY=$((JVM_HEAP_GB / 2))
if [ "$TASK_CONCURRENCY" -lt 8 ]; then TASK_CONCURRENCY=8; fi
if [ "$TASK_CONCURRENCY" -gt "$MAX_CONCURRENCY" ]; then TASK_CONCURRENCY=$MAX_CONCURRENCY; fi

# Presto requires power of 2 - round down to nearest power of 2
TASK_CONCURRENCY=$(awk -v n="$TASK_CONCURRENCY" 'BEGIN {
  p = 1;
  while (p * 2 <= n) p *= 2;
  print p;
}')

echo "=================================================="
echo " Coordinator Configuration (velox-testing params)"
echo "=================================================="
echo "Coordinator Instance: $${TOTAL_RAM_GB}GB RAM, $${VCPUS} vCPUs"
echo "Worker Instance Type: $${WORKER_INSTANCE_TYPE}"
echo "Worker Count: $${WORKER_COUNT}"
echo "Scale Factor: SF$${SCALE_FACTOR}"
echo "--------------------------------------------------"
echo "Coordinator Memory:"
echo "  System Reserved: $${SYSTEM_RESERVED_GB}GB"
echo "  JVM Heap: $${JVM_HEAP_GB}GB (90% of usable)"
echo "  Query Memory: $${QUERY_MEM_PER_NODE_GB}GB (60% of heap)"
echo ""
echo "Worker Memory (per worker):"
echo "  Query Memory: $${WORKER_QUERY_MEM_GB}GB (~90% of system memory)"
echo ""
echo "Total Cluster Memory:"
echo "  Coordinator: $${QUERY_MEM_PER_NODE_GB}GB"
echo "  Workers: $${WORKER_QUERY_MEM_GB}GB × $${WORKER_COUNT} = $((WORKER_QUERY_MEM_GB * WORKER_COUNT))GB"
echo "  Total: $${TOTAL_CLUSTER_MEM_GB}GB"
echo ""
echo "Task Concurrency: $${TASK_CONCURRENCY}"
echo "=================================================="

# node.properties
cat > /opt/presto/etc/node.properties << EOF
node.environment=production
node.id=$(uuidgen)
node.data-dir=/var/presto/data
EOF

# jvm.config (dynamically sized)
cat > /opt/presto/etc/jvm.config << EOF
-server
-Xmx$${JVM_HEAP_GB}G
-XX:+UseG1GC
-XX:G1HeapRegionSize=32M
-XX:+UseGCOverheadLimit
-XX:+ExplicitGCInvokesConcurrent
-XX:+HeapDumpOnOutOfMemoryError
-XX:+ExitOnOutOfMemoryError
-Djdk.attach.allowAttachSelf=true
EOF

# config.properties (dynamically sized)
# Get coordinator IP from EC2 metadata for correct routing
# Retry if needed since metadata might not be immediately available
COORDINATOR_IP=""
for i in {1..10}; do
  COORDINATOR_IP=$(curl -s --connect-timeout 2 http://169.254.169.254/latest/meta-data/local-ipv4 2>/dev/null)
  if [ -n "$COORDINATOR_IP" ]; then
    break
  fi
  sleep 1
done

# Fallback to hostname if metadata unavailable
if [ -z "$COORDINATOR_IP" ]; then
  COORDINATOR_IP=$(hostname -I | awk '{print $1}')
fi

# Verify we have a valid IP
if [ -z "$COORDINATOR_IP" ]; then
  echo "ERROR: Could not determine coordinator IP"
  exit 1
fi

echo "Coordinator IP: $COORDINATOR_IP"

# Calculate heap headroom BEFORE creating config file
HEAP_HEADROOM_GB=$((JVM_HEAP_GB * 40 / 100))

cat > /opt/presto/etc/config.properties << EOF
coordinator=true
node-scheduler.include-coordinator=false
http-server.http.port=8080
discovery.uri=http://$${COORDINATOR_IP}:8080
discovery-server.enabled=true

# Use host IP for inter-node communication (critical for Docker)
node.internal-address=$${COORDINATOR_IP}

query.max-memory=$${TOTAL_CLUSTER_MEM_GB}GB
query.max-memory-per-node=$${QUERY_MEM_PER_NODE_GB}GB
query.max-total-memory-per-node=$${QUERY_MEM_PER_NODE_GB}GB

# Memory management (CRITICAL for worker activation)
# Heap headroom = 40% of JVM heap (the memory NOT used for queries)
memory.heap-headroom-per-node=$${HEAP_HEADROOM_GB}GB

# Total memory across ALL nodes
query.max-total-memory=$${TOTAL_CLUSTER_MEM_GB}GB

# Disable reserved pool to simplify memory management
experimental.reserved-pool-enabled=false

task.concurrency=$${TASK_CONCURRENCY}
task.max-worker-threads=$${TASK_CONCURRENCY}
task.writer-count=$${TASK_CONCURRENCY}

# Query manager settings for native workers
query-manager.required-workers=1
query-manager.required-workers-max-wait=10s

# Match worker version for compatibility
presto.version=testversion
EOF

# log.properties
cat > /opt/presto/etc/log.properties << EOF
com.facebook.presto=INFO
EOF

HIVE_PROPERTIES_FILE=/opt/presto/etc/catalog/hive.properties

%{ if enable_hms }
cat > "$HIVE_PROPERTIES_FILE" << EOF
connector.name=hive-hadoop2
hive.metastore.uri=thrift://$COORDINATOR_IP:9083
hive.metastore.warehouse.dir=$HIVE_WAREHOUSE_DIR

hive.s3.endpoint=s3.us-east-1.amazonaws.com
hive.s3.path-style-access=false
hive.s3.max-connections=500

hive.storage-format=PARQUET
hive.compression-codec=SNAPPY
hive.parquet.use-column-names=true
hive.s3.aws-access-key=${aws_access_key_id}
hive.s3.aws-secret-key=${aws_secret_access_key}
hive.s3.session-token=${aws_session_token}

hive.max-partitions-per-scan=100000
hive.max-split-size=128MB
EOF
%{ else }
cat > "$HIVE_PROPERTIES_FILE" << 'HIVEEOF'
connector.name=hive-hadoop2
hive.metastore=file
hive.metastore.catalog.dir=/var/presto/catalog

hive.s3.endpoint=s3.us-east-1.amazonaws.com
hive.s3.path-style-access=false
hive.s3.max-connections=500

hive.storage-format=PARQUET
hive.compression-codec=SNAPPY
hive.parquet.use-column-names=true

hive.max-partitions-per-scan=100000
hive.max-split-size=128MB
HIVEEOF
%{ endif }

%{ if enable_hms }
echo "=== Configuring Hive Metastore Service (HMS) ==="

if [ -n "$HIVE_WAREHOUSE_DIR" ]; then
  WAREHOUSE_PATH="$HIVE_WAREHOUSE_DIR"
else
  WAREHOUSE_PATH="s3://rapids-db-io-us-east-1/hive-warehouse/"
fi

cat > /opt/hms/conf/hive-site.xml << EOF
<?xml version="1.0" encoding="UTF-8"?>
<configuration>
  <property>
    <name>javax.jdo.option.ConnectionURL</name>
    <value>jdbc:mysql://$HMS_DB_ENDPOINT/$HMS_DB_NAME?createDatabaseIfNotExist=true&amp;useSSL=true&amp;requireSSL=false</value>
  </property>
  <property>
    <name>javax.jdo.option.ConnectionDriverName</name>
    <value>com.mysql.cj.jdbc.Driver</value>
  </property>
  <property>
    <name>javax.jdo.option.ConnectionUserName</name>
    <value>$HMS_DB_USER</value>
  </property>
  <property>
    <name>javax.jdo.option.ConnectionPassword</name>
    <value>$HMS_DB_PASSWORD</value>
  </property>
  <property>
    <name>hive.metastore.warehouse.dir</name>
    <value>$WAREHOUSE_PATH</value>
  </property>
  <property>
    <name>hive.metastore.uris</name>
    <value>thrift://0.0.0.0:9083</value>
  </property>
  <property>
    <name>hive.metastore.thrift.bind.host</name>
    <value>0.0.0.0</value>
  </property>
  <property>
    <name>fs.s3a.access.key</name>
    <value>${aws_access_key_id}</value>
  </property>
  <property>
    <name>fs.s3a.secret.key</name>
    <value>${aws_secret_access_key}</value>
  </property>
  <property>
    <name>fs.s3a.session.token</name>
    <value>${aws_session_token}</value>
  </property>
  <property>
    <name>fs.s3a.endpoint</name>
    <value>s3.us-east-1.amazonaws.com</value>
  </property>
  <property>
    <name>datanucleus.autoCreateSchema</name>
    <value>false</value>
  </property>
  <property>
    <name>hive.metastore.schema.verification</name>
    <value>false</value>
  </property>
</configuration>
EOF

echo "Waiting for HMS database ($HMS_DB_ENDPOINT)..."
HMS_READY=false
for attempt in {1..30}; do
  if mysql -h "$HMS_DB_ENDPOINT" -u "$HMS_DB_USER" -p"$HMS_DB_PASSWORD" -e "SELECT 1" >/dev/null 2>&1; then
    HMS_READY=true
    echo "✓ HMS database is reachable"
    break
  fi
  echo "  Attempt $attempt/30 - waiting for MySQL..."
  sleep 10
done

if [ "$HMS_READY" != "true" ]; then
  echo "ERROR: HMS database not reachable"
  exit 1
fi

echo "Initializing HMS schema (idempotent)..."
set +e
SCHEMA_INIT_LOG=$(docker run --rm \
  -v /opt/hms/conf:/opt/hive/conf \
  -e HIVE_CONF_DIR=/opt/hive/conf \
  apache/hive:3.1.3 \
  schematool -dbType mysql -initSchema --verbose 2>&1)
SCHEMA_INIT_RC=$?
set -e

if [ $SCHEMA_INIT_RC -ne 0 ]; then
  if echo "$SCHEMA_INIT_LOG" | grep -qi "already exists"; then
    echo "✓ HMS schema already initialized"
  else
    echo "$SCHEMA_INIT_LOG"
    echo "ERROR: HMS schema initialization failed"
    exit 1
  fi
else
  echo "✓ HMS schema initialized"
fi

echo "Starting Hive Metastore container..."
docker rm -f hive-metastore >/dev/null 2>&1 || true
docker run -d \
  --name hive-metastore \
  --restart unless-stopped \
  -p 9083:9083 \
  -v /opt/hms/conf:/opt/hive/conf \
  -e SERVICE_NAME=metastore \
  -e AWS_ACCESS_KEY_ID=${aws_access_key_id} \
  -e AWS_SECRET_ACCESS_KEY=${aws_secret_access_key} \
  -e AWS_SESSION_TOKEN=${aws_session_token} \
  apache/hive:3.1.3

echo "✓ Hive Metastore listening on thrift://$COORDINATOR_IP:9083"
%{ endif }

# Launch Presto coordinator container (Docker only, no systemd)
echo "Starting Presto Java Coordinator container..."
docker rm -f presto-coordinator >/dev/null 2>&1 || true
docker run -d \
  --name presto-coordinator \
  --restart unless-stopped \
  -p 8080:8080 \
  -v /opt/presto/etc:/opt/presto-server/etc:ro \
  -v /var/presto/data:/var/presto/data \
  -v /var/presto/catalog:/var/presto/catalog \
  -e AWS_ACCESS_KEY_ID=${aws_access_key_id} \
  -e AWS_SECRET_ACCESS_KEY=${aws_secret_access_key} \
  -e AWS_SESSION_TOKEN=${aws_session_token} \
  presto-coordinator:latest

# Wait for Presto to start
echo "Waiting for Presto to start..."
for i in {1..60}; do
  if curl -s http://localhost:8080/v1/info > /dev/null 2>&1; then
    echo "✅ Presto started successfully!"
    break
  fi
  echo "Attempt $i/60 - waiting..."
  sleep 5
done

# Install Presto CLI
echo "Installing Presto CLI..."
wget -q https://repo1.maven.org/maven2/com/facebook/presto/presto-cli/0.289/presto-cli-0.289-executable.jar \
  -O /usr/local/bin/presto
chmod +x /usr/local/bin/presto

echo "=== Coordinator Setup Complete ==="
echo "Presto Java Coordinator running via Docker"
echo "Ready for Native Workers (Docker)"
echo "Web UI: http://$${COORDINATOR_IP}:8080"
echo ""
echo "TPC-H Connector: Use enable_tpch_connector.sh after deployment"
echo "External S3 Tables: Requires HMS (see HMS_DEPLOYMENT_GUIDE.md)"
echo ""
echo "To run queries: presto --server localhost:8080 --catalog tpch --schema sf100"
echo ""
echo "User data script completed successfully"

