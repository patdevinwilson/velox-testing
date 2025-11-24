#!/bin/bash
set -e

# Logging
exec > >(tee /var/log/user-data.log)
exec 2>&1

echo "=== Starting Presto Java Worker Setup ==="
date

# Get instance specs for dynamic configuration
TOTAL_RAM_GB=$(free -g | awk '/^Mem:/{print $2}')
VCPUS=$(nproc)

echo "Instance Resources: $${TOTAL_RAM_GB}GB RAM, $${VCPUS} vCPUs"

# Update system
dnf update -y

# Install Java 11 and dependencies
# Note: --allowerasing fixes curl-minimal conflict in AL2023
dnf install -y --allowerasing java-11-amazon-corretto java-11-amazon-corretto-devel wget tar gzip htop python3

# Create python symlink (Presto launcher needs 'python')
ln -sf /usr/bin/python3 /usr/local/bin/python

# Download and install Presto
PRESTO_VERSION="0.289"
echo "Downloading Presto $${PRESTO_VERSION}..."
cd /opt
wget -q https://repo1.maven.org/maven2/com/facebook/presto/presto-server/$${PRESTO_VERSION}/presto-server-$${PRESTO_VERSION}.tar.gz
tar -xzf presto-server-$${PRESTO_VERSION}.tar.gz
rm presto-server-$${PRESTO_VERSION}.tar.gz
ln -s /opt/presto-server-$${PRESTO_VERSION} /opt/presto-server

# Create directories
mkdir -p /opt/presto-server/etc/catalog
mkdir -p /opt/presto-server/var/log
mkdir -p /var/presto/data

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

# Dynamic memory configuration
# For workers: 80% of RAM for JVM heap
JVM_HEAP_GB=$((TOTAL_RAM_GB * 80 / 100))
QUERY_MEM_PER_NODE_GB=$((JVM_HEAP_GB * 70 / 100))

echo "Memory Configuration: JVM Heap=$${JVM_HEAP_GB}GB, Query Memory=$${QUERY_MEM_PER_NODE_GB}GB"

# node.properties
cat > /opt/presto-server/etc/node.properties << EOF
node.environment=production
node.id=$(uuidgen)
node.data-dir=/var/presto/data
node.location=us-east-1a
EOF

# jvm.config
cat > /opt/presto-server/etc/jvm.config << EOF
-server
-Xmx$${JVM_HEAP_GB}G
-Xms$${JVM_HEAP_GB}G
-XX:+UseG1GC
-XX:G1HeapRegionSize=32M
-XX:+UseGCOverheadLimit
-XX:+ExplicitGCInvokesConcurrent
-XX:+HeapDumpOnOutOfMemoryError
-XX:+ExitOnOutOfMemoryError
-XX:ReservedCodeCacheSize=512M
-Djdk.attach.allowAttachSelf=true
-Djdk.nio.maxCachedBufferSize=2000000
EOF

# config.properties
cat > /opt/presto-server/etc/config.properties << EOF
coordinator=false
http-server.http.port=8080
discovery.uri=http://${coordinator_ip}:8080

query.max-memory=900GB
query.max-memory-per-node=$${QUERY_MEM_PER_NODE_GB}GB
query.max-total-memory-per-node=$${QUERY_MEM_PER_NODE_GB}GB

memory.heap-headroom-per-node=10GB

task.concurrency=$${VCPUS}
task.max-worker-threads=$${VCPUS}
task.writer-count=$((VCPUS / 2))

exchange.client-threads=$((VCPUS / 4))
exchange.max-buffer-size=32MB

optimizer.join-reordering-strategy=AUTOMATIC

experimental.spill-enabled=true
experimental.spiller-spill-path=/var/presto/data/spill
experimental.max-spill-per-node=500GB
EOF

# catalog/hive.properties
cat > /opt/presto-server/etc/catalog/hive.properties << 'HIVEEOF'
connector.name=hive
hive.metastore=file
hive.metastore.catalog.dir=/var/presto/catalog

hive.s3.aws-access-key=${aws_access_key_id}
hive.s3.aws-secret-key=${aws_secret_access_key}
hive.s3.endpoint=s3.amazonaws.com
hive.s3.path-style-access=true
hive.s3.max-connections=500
hive.s3.max-error-retries=10

hive.storage-format=PARQUET
hive.compression-codec=SNAPPY
hive.parquet.use-column-names=true

hive.max-partitions-per-scan=100000
hive.max-split-size=128MB
HIVEEOF

# Wait for coordinator to be ready
echo "Waiting for coordinator to be ready..."
for i in {1..30}; do
  if curl -sf http://${coordinator_ip}:8080/v1/info >/dev/null 2>&1; then
    echo "Coordinator is ready!"
    break
  fi
  echo "Attempt $i/30: Coordinator not ready yet, waiting..."
  sleep 10
done

# Create systemd service
cat > /etc/systemd/system/presto.service << 'SERVICEEOF'
[Unit]
Description=Presto Java Worker
After=network.target

[Service]
Type=forking
User=root
Environment="JAVA_HOME=/usr/lib/jvm/java-11-amazon-corretto"
ExecStart=/opt/presto-server/bin/launcher start
ExecStop=/opt/presto-server/bin/launcher stop
Restart=on-failure
RestartSec=10
LimitNOFILE=131072

[Install]
WantedBy=multi-user.target
SERVICEEOF

# Start Presto Worker
echo "Starting Presto Java Worker..."
systemctl daemon-reload
systemctl enable presto
systemctl start presto

# Wait and check status
sleep 10
systemctl status presto --no-pager || true

echo ""
echo "=== Worker Setup Complete ==="
echo "Presto Java Worker starting..."
echo "Will connect to coordinator at ${coordinator_ip}:8080"
echo ""
echo "Check status:"
echo "  systemctl status presto"
echo "  tail -f /opt/presto-server/var/log/server.log"
echo ""

