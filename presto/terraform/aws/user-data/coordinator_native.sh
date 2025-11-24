#!/bin/bash
set -e

# Logging
exec > >(tee /var/log/user-data.log)
exec 2>&1

echo "=== Starting Presto Native Coordinator Setup ==="
date

# Update system
dnf update -y

# Install Docker and dependencies
dnf install -y --allowerasing docker htop jq wget curl
systemctl start docker
systemctl enable docker

# Enable memory overcommit for Velox allocator
sysctl -w vm.overcommit_memory=1
sysctl -w vm.overcommit_ratio=100
echo "vm.overcommit_memory = 1" >> /etc/sysctl.conf
echo "vm.overcommit_ratio = 100" >> /etc/sysctl.conf

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
mkdir -p /opt/presto/etc/catalog /var/presto/data /var/presto/catalog

# Download Presto Native image from S3
PRESTO_IMAGE_SOURCE="${presto_native_image}"
PRESTO_IMAGE="presto-native-cpu:latest"

echo "Downloading Presto Native image from S3..."
echo "Source: $${PRESTO_IMAGE_SOURCE}"

export AWS_ACCESS_KEY_ID="${aws_access_key_id}"
export AWS_SECRET_ACCESS_KEY="${aws_secret_access_key}"
export AWS_SESSION_TOKEN="${aws_session_token}"
export AWS_DEFAULT_REGION="us-east-1"

IMAGE_FILE="/tmp/presto-native-image.tar.gz"
aws s3 cp "$${PRESTO_IMAGE_SOURCE}" "$${IMAGE_FILE}"

echo "✓ Downloaded image from S3 (size: $(du -h $${IMAGE_FILE} | cut -f1))"

echo "Loading image into Docker..."
LOAD_OUTPUT=$(gunzip -c "$${IMAGE_FILE}" | docker load)
echo "$${LOAD_OUTPUT}"

LOADED_IMAGE=$(echo "$${LOAD_OUTPUT}" | grep -oP 'Loaded image: \K.*' || echo "presto-native-cpu:full")
echo "Loaded image: $${LOADED_IMAGE}"

docker tag "$${LOADED_IMAGE}" "$${PRESTO_IMAGE}"
echo "✓ Tagged as $${PRESTO_IMAGE}"
rm -f "$${IMAGE_FILE}"

# Get instance resources
TOTAL_RAM_GB=$(free -g | awk '/^Mem:/{print $2}')
VCPUS=$(nproc)

# Memory calculations for Native coordinator
SYSTEM_RESERVED_GB=$((TOTAL_RAM_GB * 5 / 100))
if [ "$SYSTEM_RESERVED_GB" -gt 2 ]; then SYSTEM_RESERVED_GB=2; fi

USABLE_RAM_GB=$((TOTAL_RAM_GB - SYSTEM_RESERVED_GB))
COORDINATOR_MEMORY_GB=$((USABLE_RAM_GB * 90 / 100))

# Task concurrency
SCALE_FACTOR=${benchmark_scale_factor}
if [ "$SCALE_FACTOR" -ge 1000 ]; then
  TASK_CONCURRENCY=$((VCPUS * 2))
else
  TASK_CONCURRENCY=$${VCPUS}
fi

if [ "$TASK_CONCURRENCY" -gt 64 ]; then TASK_CONCURRENCY=64; fi

# Round to power of 2
TASK_CONCURRENCY=$(awk -v n="$TASK_CONCURRENCY" 'BEGIN {
  p = 1;
  while (p * 2 <= n) p *= 2;
  print p;
}')

echo "=================================================="
echo " Native Coordinator Configuration"
echo "=================================================="
echo "Instance: $${TOTAL_RAM_GB}GB RAM, $${VCPUS} vCPUs"
echo "Scale Factor: SF${benchmark_scale_factor}"
echo "Workers: ${worker_count}"
echo "--------------------------------------------------"
echo "System Reserved: $${SYSTEM_RESERVED_GB}GB"
echo "Coordinator Memory: $${COORDINATOR_MEMORY_GB}GB"
echo "Task Concurrency: $${TASK_CONCURRENCY}"
echo "=================================================="

# node.properties
cat > /opt/presto/etc/node.properties << EOF
node.environment=production
node.id=$(uuidgen)
node.data-dir=/var/presto/data
node.location=us-east-1a
EOF

# Get coordinator IP
COORDINATOR_IP=$(hostname -I | awk '{print $1}')

# Calculate worker query memory for cluster settings
get_worker_query_memory() {
  case "${worker_instance_type}" in
    r7i.xlarge)    echo 28 ;;
    r7i.2xlarge)   echo 56 ;;
    r7i.4xlarge)   echo 113 ;;
    r7i.8xlarge)   echo 227 ;;
    r7i.12xlarge)  echo 341 ;;
    r7i.16xlarge)  echo 456 ;;
    r7i.24xlarge)  echo 686 ;;
    r7i.48xlarge)  echo 1374 ;;
    *) echo $${COORDINATOR_MEMORY_GB} ;;
  esac
}

WORKER_QUERY_MEM_GB=$(get_worker_query_memory)
TOTAL_CLUSTER_MEM_GB=$((COORDINATOR_MEMORY_GB + (WORKER_QUERY_MEM_GB * ${worker_count})))

# config.properties (Native Coordinator - matching velox-testing exactly)
cat > /opt/presto/etc/config.properties << EOF
# Coordinator mode
coordinator=true
node-scheduler.include-coordinator=false

# HTTP Server
http-server.http.port=8080

# Discovery service
discovery-server.enabled=true
discovery.uri=http://$${COORDINATOR_IP}:8080

# Version (must match workers)
presto.version=testversion

# Logging
log.max-history=30
log.max-size=104857600B

# Scheduler settings for Native workers
node-scheduler.max-pending-splits-per-task=2000
node-scheduler.max-splits-per-node=2000

# Optimizer flags (from velox-testing)
optimizer.exploit-constraints=true
optimizer.in-predicates-as-inner-joins-enabled=true
optimizer.partial-aggregation-strategy=automatic
optimizer.prefer-partial-aggregation=true
optimizer.default-join-selectivity-coefficient=0.1
optimizer.infer-inequality-predicates=true
optimizer.handle-complex-equi-joins=true
optimizer.generate-domain-filters=true
join-max-broadcast-table-size=100MB

# Query execution settings
query.client.timeout=30m
query.execution-policy=phased
query.low-memory-killer.policy=total-reservation-on-blocked-nodes
query.max-execution-time=30m
query.max-history=1000
query.max-stage-count=1300
query.min-expire-age=120m
query.min-schedule-split-batch-size=2000
query.stage-count-warning-threshold=150
query.max-length=2000000

# Memory quotas (calculated based on cluster)
query.max-total-memory-per-node=$${COORDINATOR_MEMORY_GB}GB
query.max-total-memory=$${TOTAL_CLUSTER_MEM_GB}GB
query.max-memory-per-node=$${COORDINATOR_MEMORY_GB}GB
query.max-memory=$${TOTAL_CLUSTER_MEM_GB}GB
memory.heap-headroom-per-node=0GB

# Spill and memory settings
experimental.enable-dynamic-filtering=false
experimental.max-revocable-memory-per-node=50GB
experimental.max-spill-per-node=50GB
experimental.optimized-repartitioning=true
experimental.pushdown-dereference-enabled=true
experimental.pushdown-subfields-enabled=true
experimental.query-max-spill-per-node=50GB
experimental.reserved-pool-enabled=false
experimental.spiller-max-used-space-threshold=0.7
experimental.spiller-spill-path=/var/presto/data/spill

# Query manager for native workers
query-manager.required-workers=1
query-manager.required-workers-max-wait=10s

# Native execution (CRITICAL for Presto Native)
native-execution-enabled=true
optimizer.optimize-hash-generation=false
regex-library=RE2J
use-alternative-function-signatures=true
single-node-execution-enabled=true

# Concurrency
task.concurrency=$${TASK_CONCURRENCY}
task.max-worker-threads=$${TASK_CONCURRENCY}
task.max-drivers-per-task=$${TASK_CONCURRENCY}
EOF

# catalog/hive.properties
cat > /opt/presto/etc/catalog/hive.properties << 'HIVEEOF'
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

# catalog/tpch.properties
cat > /opt/presto/etc/catalog/tpch.properties << 'TPCHEOF'
connector.name=tpch
tpch.splits-per-node=4
TPCHEOF

# Create systemd service for Native coordinator
cat > /etc/systemd/system/presto.service << SERVICEEOF
[Unit]
Description=Presto Native Coordinator
After=docker.service
Requires=docker.service

[Service]
Type=simple
User=root
ExecStartPre=-/usr/bin/docker stop presto-coordinator
ExecStartPre=-/usr/bin/docker rm presto-coordinator
ExecStart=/usr/bin/docker run --rm \\
  --name presto-coordinator \\
  --network host \\
  --memory=$${COORDINATOR_MEMORY_GB}g \\
  --memory-swap=$${COORDINATOR_MEMORY_GB}g \\
  -v /opt/presto/etc:/opt/presto-server/etc:ro \\
  -v /var/presto/data:/var/presto/data \\
  -v /var/presto/catalog:/var/presto/catalog \\
  -e LD_LIBRARY_PATH=/usr/local/lib:/usr/local/lib64:/usr/lib:/usr/lib64 \\
  -e AWS_ACCESS_KEY_ID=${aws_access_key_id} \\
  -e AWS_SECRET_ACCESS_KEY=${aws_secret_access_key} \\
  -e AWS_SESSION_TOKEN=${aws_session_token} \\
  --entrypoint /bin/bash \\
  $${PRESTO_IMAGE} \\
  -c "ldconfig && /usr/bin/presto_server --etc-dir=/opt/presto-server/etc"
ExecStop=/usr/bin/docker stop presto-coordinator
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
SERVICEEOF

# Start Presto Native Coordinator
echo "Starting Presto Native Coordinator..."
systemctl daemon-reload
systemctl enable presto
systemctl start presto

# Wait for Presto to start
echo "Waiting for Presto to start..."
for i in {1..60}; do
  if curl -s http://localhost:8080/v1/info > /dev/null 2>&1; then
    echo "✅ Presto Native Coordinator started successfully!"
    break
  fi
  echo "Attempt $i/60 - waiting..."
  sleep 5
done

echo "=== Coordinator Setup Complete ==="
echo "Presto Native Coordinator running"
echo "Architecture: Native coordinator + Native workers (matching velox-testing)"
echo "Web UI: http://$${COORDINATOR_IP}:8080"

