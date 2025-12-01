#!/bin/bash
set -e

# Logging
exec > >(tee /var/log/user-data.log)
exec 2>&1

echo "=== Starting Presto Native Worker Setup (Stable Build) ==="
date

ENABLE_HMS="${enable_hms}"
HIVE_METASTORE_URI="${hive_metastore_uri}"

# Update system
dnf update -y

# Install Docker
dnf install -y --allowerasing docker htop jq
systemctl start docker
systemctl enable docker

# Enable memory overcommit for Velox allocator (CRITICAL for Presto Native)
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

# Create directories (including AsyncDataCache directory)
mkdir -p /opt/presto/etc/catalog /var/presto/data /var/presto/data/spill /var/presto/catalog /var/presto/cache

# Detect architecture from the host system (most reliable method)
HOST_ARCH=$(uname -m)
echo "Detected host architecture: $${HOST_ARCH}"

# Select the appropriate Presto Native image based on architecture
if [[ "$${HOST_ARCH}" == "aarch64" ]] || [[ "$${HOST_ARCH}" == "arm64" ]]; then
    PRESTO_IMAGE_SOURCE="s3://rapids-db-io-us-east-1/docker-images/presto-worker-arm64-latest.tar.gz"
    echo "Using ARM64 worker image for Graviton"
else
    PRESTO_IMAGE_SOURCE="s3://rapids-db-io-us-east-1/docker-images/presto-worker-matched-latest.tar.gz"
    echo "Using x86_64 worker image"
fi
PRESTO_IMAGE="presto-native-cpu:latest"

echo "Presto Native image source: $${PRESTO_IMAGE_SOURCE}"

# Check if source is S3 or a registry
if [[ "$${PRESTO_IMAGE_SOURCE}" == s3://* ]]; then
  echo "Downloading Presto Native image from S3..."
  echo "Source: $${PRESTO_IMAGE_SOURCE}"
  
  # Export AWS credentials for CLI
  export AWS_ACCESS_KEY_ID="${aws_access_key_id}"
  export AWS_SECRET_ACCESS_KEY="${aws_secret_access_key}"
  export AWS_SESSION_TOKEN="${aws_session_token}"
  export AWS_DEFAULT_REGION="us-east-1"
  
  # Download from S3
  IMAGE_FILE="/tmp/presto-native-image.tar.gz"
  aws s3 cp "$${PRESTO_IMAGE_SOURCE}" "$${IMAGE_FILE}"
  
  if [ $? -eq 0 ]; then
    echo "✓ Downloaded image from S3 (size: $(du -h $${IMAGE_FILE} | cut -f1))"
    
    # Load image into Docker
    echo "Loading image into Docker..."
    LOAD_OUTPUT=$(gunzip -c "$${IMAGE_FILE}" | docker load)
    echo "$${LOAD_OUTPUT}"
    
    if [ $? -eq 0 ]; then
      echo "✓ Successfully loaded Docker image"
      rm -f "$${IMAGE_FILE}"
      
      # Extract the actual image name and tag from docker load output
      # Output format: "Loaded image: repository:tag"
      LOADED_IMAGE=$(echo "$${LOAD_OUTPUT}" | grep -oP 'Loaded image: \K.*' || echo "presto-native-cpu:full")
      echo "Loaded image: $${LOADED_IMAGE}"
      
      # Tag it as 'latest' for consistency
      docker tag "$${LOADED_IMAGE}" "$${PRESTO_IMAGE}"
      echo "✓ Tagged as $${PRESTO_IMAGE}"
    else
      echo "✗ Failed to load Docker image"
      exit 1
    fi
  else
    echo "✗ Failed to download image from S3"
    exit 1
  fi
  
elif [[ "$${PRESTO_IMAGE_SOURCE}" == *.dkr.ecr.*.amazonaws.com/* ]]; then
  echo "Pulling Presto Native image from ECR..."
  
  # Login to ECR
  echo "Logging in to ECR..."
  # Extract region from ECR URL (e.g., 123456789.dkr.ecr.us-east-1.amazonaws.com/image)
  AWS_REGION=$(echo "$${PRESTO_IMAGE_SOURCE}" | cut -d. -f4)
  ECR_REGISTRY=$(echo "$${PRESTO_IMAGE_SOURCE}" | cut -d/ -f1)
  
  aws ecr get-login-password --region "$${AWS_REGION}" | \
    docker login --username AWS --password-stdin "$${ECR_REGISTRY}"
  
  docker pull "$${PRESTO_IMAGE_SOURCE}"
  docker tag "$${PRESTO_IMAGE_SOURCE}" "$${PRESTO_IMAGE}"
  
else
  echo "Pulling Presto Native image from registry..."
  docker pull "$${PRESTO_IMAGE_SOURCE}"
  docker tag "$${PRESTO_IMAGE_SOURCE}" "$${PRESTO_IMAGE}"
fi

# Verify image is fully loaded and ready
echo "Verifying Docker image is ready..."
sleep 5  # Give docker time to finish any background operations

# Check image exists using docker inspect (more reliable than grep)
if docker inspect "$${PRESTO_IMAGE}" >/dev/null 2>&1; then
  echo "✓ Docker image verified and ready"
  echo "Image: $${PRESTO_IMAGE}"
  docker images | grep presto-native | head -3
else
  echo "✗ ERROR: Image $${PRESTO_IMAGE} not found after loading!"
  echo "Available images:"
  docker images
  exit 1
fi

# Test that we can inspect the image
if docker inspect "$${PRESTO_IMAGE}" > /dev/null 2>&1; then
  echo "✓ Image inspection successful"
else
  echo "✗ ERROR: Cannot inspect image $${PRESTO_IMAGE}"
  exit 1
fi

# Wait for coordinator to be ready
echo "Waiting for coordinator to be ready..."
sleep 60

# Get instance specs for dynamic configuration
TOTAL_RAM_GB=$(free -g | awk '/^Mem:/{print $2}')
VCPUS=$(nproc)

# Fallback if TOTAL_RAM_GB is empty or 0
if [ -z "$${TOTAL_RAM_GB}" ] || [ "$${TOTAL_RAM_GB}" = "0" ]; then
  # Try with megabytes and convert
  TOTAL_RAM_MB=$(free -m | awk '/^Mem:/{print $2}')
  TOTAL_RAM_GB=$((TOTAL_RAM_MB / 1024))
fi

# Ensure we have a valid number
if [ -z "$${TOTAL_RAM_GB}" ]; then
  echo "Warning: Could not determine RAM, defaulting to 64GB"
  TOTAL_RAM_GB=64
fi

# Native Worker Memory Configuration
# Optimized for maximum utilization while preventing OOM
# Docker limit is set higher than Presto memory to allow native overhead

if [ "$TOTAL_RAM_GB" -ge 480 ]; then
  # 512GB instances (r7gd.16xlarge): ~494GB available
  # Docker: 98% of available, Presto: Docker - 15GB native overhead
  DOCKER_MEM_LIMIT_GB=$((TOTAL_RAM_GB * 98 / 100))
  WORKER_MEMORY_GB=$((DOCKER_MEM_LIMIT_GB - 15))
elif [ "$TOTAL_RAM_GB" -ge 240 ]; then
  # 256GB instances (r7gd.8xlarge): ~240GB available
  # Docker: 98% of available, Presto: Docker - 12GB native overhead
  DOCKER_MEM_LIMIT_GB=$((TOTAL_RAM_GB * 98 / 100))
  WORKER_MEMORY_GB=$((DOCKER_MEM_LIMIT_GB - 12))
elif [ "$TOTAL_RAM_GB" -ge 120 ]; then
  # 128GB instances (r7gd.4xlarge): ~120GB available
  # Docker: 97% of available, Presto: Docker - 7GB native overhead
  DOCKER_MEM_LIMIT_GB=$((TOTAL_RAM_GB * 97 / 100))
  WORKER_MEMORY_GB=$((DOCKER_MEM_LIMIT_GB - 7))
elif [ "$TOTAL_RAM_GB" -ge 60 ]; then
  # 64GB instances (r7gd.2xlarge): ~60GB available
  # Conservative for Q21 hash table requirements
  DOCKER_MEM_LIMIT_GB=58
  WORKER_MEMORY_GB=54
else
  # Smaller instances: 95% Docker, 90% Presto
  DOCKER_MEM_LIMIT_GB=$((TOTAL_RAM_GB * 95 / 100))
  WORKER_MEMORY_GB=$((TOTAL_RAM_GB * 90 / 100))
fi

# Scale factor for configuration tuning
SCALE_FACTOR="${benchmark_scale_factor}"
if [ -z "$SCALE_FACTOR" ] || ! [[ "$SCALE_FACTOR" =~ ^[0-9]+$ ]]; then
  SCALE_FACTOR=100
fi

# Buffer memory (5% of worker memory)
# Scale cap based on scale factor: SF100=32GB, SF1000=64GB, SF3000=100GB
BUFFER_MEM_GB=$((WORKER_MEMORY_GB * 5 / 100))
if [ "$SCALE_FACTOR" -ge 3000 ]; then
  BUFFER_CAP=100
elif [ "$SCALE_FACTOR" -ge 1000 ]; then
  BUFFER_CAP=64
else
  BUFFER_CAP=32
fi
if [ "$BUFFER_MEM_GB" -gt "$BUFFER_CAP" ]; then BUFFER_MEM_GB=$BUFFER_CAP; fi

# Task concurrency: Match vCPU count for optimal parallelization
# Presto Native benefits from high concurrency on large instances
TASK_CONCURRENCY=$${VCPUS}

# Presto requires power of 2 - round down to nearest power of 2
TASK_CONCURRENCY=$(awk -v n="$TASK_CONCURRENCY" 'BEGIN {
  p = 1;
  while (p * 2 <= n) p *= 2;
  print p;
}')

# AsyncDataCache size calculation
# Check for NVMe instance storage (r7gd, i3, etc.)
# NVMe devices are typically /dev/nvme1n1 or similar (nvme0 is usually root)
NVME_DEVICE=""
for dev in /dev/nvme1n1 /dev/nvme2n1 /dev/nvme3n1; do
    if [ -b "$dev" ]; then
        NVME_DEVICE="$dev"
        break
    fi
done

if [ -n "$NVME_DEVICE" ]; then
    echo "Found NVMe instance storage: $NVME_DEVICE"
    # Format and mount NVMe for cache
    mkfs.xfs -f "$NVME_DEVICE" 2>/dev/null || true
    mkdir -p /var/presto/cache
    mount "$NVME_DEVICE" /var/presto/cache 2>/dev/null || true
    chown -R root:root /var/presto/cache
    
    # Get NVMe size for cache
    NVME_SIZE_GB=$(lsblk -b -d -o SIZE "$NVME_DEVICE" 2>/dev/null | tail -1 | awk '{print int($1/1024/1024/1024)}')
    CACHE_SIZE_GB=$((NVME_SIZE_GB * 80 / 100))  # Use 80% of NVMe for cache
    if [ "$CACHE_SIZE_GB" -gt 1500 ]; then CACHE_SIZE_GB=1500; fi
    echo "NVMe cache size: $${CACHE_SIZE_GB}GB"
else
    # Fallback to EBS-based cache (50% of available, capped at 200GB)
    AVAILABLE_DISK_GB=$(df -BG /var/presto | tail -1 | awk '{print int($4)}')
    CACHE_SIZE_GB=$((AVAILABLE_DISK_GB / 2))
    if [ "$CACHE_SIZE_GB" -gt 200 ]; then CACHE_SIZE_GB=200; fi
fi

if [ "$CACHE_SIZE_GB" -lt 10 ]; then CACHE_SIZE_GB=10; fi

echo "=================================================="
echo " Native Worker Configuration (velox-testing)"
echo "=================================================="
echo "Instance: $${TOTAL_RAM_GB}GB RAM, $${VCPUS} vCPUs"
echo "Scale Factor: SF$${SCALE_FACTOR}"
echo "--------------------------------------------------"
echo "Docker Memory Limit: $${DOCKER_MEM_LIMIT_GB}GB"
echo "Presto Memory: $${WORKER_MEMORY_GB}GB"
echo "Native Overhead: $((DOCKER_MEM_LIMIT_GB - WORKER_MEMORY_GB))GB"
echo "Buffer Memory: $${BUFFER_MEM_GB}GB"
echo "Task Concurrency: $${TASK_CONCURRENCY}"
echo "AsyncDataCache: $${CACHE_SIZE_GB}GB (SSD cache for S3)"
echo "=================================================="

# node.properties
cat > /opt/presto/etc/node.properties << EOF
node.environment=production
node.id=$(uuidgen)
node.data-dir=/var/presto/data
node.location=us-east-1a
EOF

# Get worker IP from EC2 metadata (not Docker internal IP)
# Using hostname -I gives Docker bridge IP when inside container
# EC2 metadata gives the actual host private IP
WORKER_IP=""
for i in {1..10}; do
  WORKER_IP=$(curl -s --connect-timeout 2 http://169.254.169.254/latest/meta-data/local-ipv4 2>/dev/null)
  if [ -n "$WORKER_IP" ]; then
    break
  fi
  sleep 1
done

# Fallback
if [ -z "$WORKER_IP" ]; then
WORKER_IP=$(hostname -I | awk '{print $1}')
fi

echo "Worker IP: $WORKER_IP"

# config.properties (WORKER MODE)
# Note: Presto Native has different config property names than Java
cat > /opt/presto/etc/config.properties << EOFCONFIG
# Worker mode (explicit)
coordinator=false

# Match coordinator version exactly (critical for compatibility)
presto.version=testversion

# HTTP Server
http-server.http.port=8080
discovery.uri=http://${coordinator_ip}:8080

# Node communication
node.internal-address=$${WORKER_IP}

# Memory settings (Native-specific)
system-memory-gb=$${WORKER_MEMORY_GB}
query-memory-gb=$${WORKER_MEMORY_GB}

# Memory limits matching velox-testing
query.max-memory-per-node=$${WORKER_MEMORY_GB}GB
query.max-total-memory-per-node=$${WORKER_MEMORY_GB}GB

# Memory arbitrator for Native workers
memory-arbitrator-kind=SHARED

# Concurrency (workers can handle more)
task.concurrency=$${TASK_CONCURRENCY}
task.max-worker-threads=$${TASK_CONCURRENCY}
task.max-drivers-per-task=$${TASK_CONCURRENCY}

# Optimizations
experimental.spill-enabled=true
experimental.spiller-spill-path=/var/presto/data/spill

# Native execution
native-execution-enabled=true

# Memory pushback for container limits
system-mem-pushback-enabled=true
system-mem-limit-gb=$${WORKER_MEMORY_GB}
system-mem-shrink-gb=20

# AsyncDataCache (SSD Cache) for S3 data
# Caches remote data locally to avoid repeated S3 reads
# Significantly improves performance for repeated queries
async-data-cache-enabled=true
async-cache-ssd-gb=$${CACHE_SIZE_GB}
async-cache-ssd-path=/var/presto/cache
async-cache-ssd-checkpoint-enabled=true
EOFCONFIG

# catalog/hive.properties
HIVE_PROPERTIES_FILE=/opt/presto/etc/catalog/hive.properties

if [ "$ENABLE_HMS" = "true" ] && [ -n "$HIVE_METASTORE_URI" ]; then
# HMS mode - use Thrift metastore
cat > "$HIVE_PROPERTIES_FILE" << EOF
connector.name=hive-hadoop2
hive.metastore.uri=$${HIVE_METASTORE_URI}

hive.s3.endpoint=s3.us-east-1.amazonaws.com
hive.s3.path-style-access=false
hive.s3.max-connections=500

hive.storage-format=PARQUET
hive.compression-codec=SNAPPY
hive.parquet.use-column-names=true

hive.max-partitions-per-scan=100000
hive.max-split-size=128MB
EOF
else
# Default: Use AWS Glue Data Catalog for S3 external tables
# Credentials are passed via environment variables to the container
cat > "$HIVE_PROPERTIES_FILE" << 'HIVEEOF'
connector.name=hive-hadoop2
hive.metastore=glue
hive.metastore.glue.region=us-east-1

hive.s3.endpoint=s3.us-east-1.amazonaws.com
hive.s3.path-style-access=false
hive.s3.max-connections=500

hive.storage-format=PARQUET
hive.compression-codec=SNAPPY
hive.parquet.use-column-names=true

hive.max-partitions-per-scan=100000
hive.max-split-size=128MB
HIVEEOF
fi

# Create systemd service with memory limit
cat > /etc/systemd/system/presto.service << SERVICEEOF
[Unit]
Description=Presto Native Worker (Stable Build)
After=docker.service
Requires=docker.service

[Service]
Type=simple
User=root
ExecStartPre=-/usr/bin/docker stop presto-worker
ExecStartPre=-/usr/bin/docker rm presto-worker
ExecStart=/usr/bin/docker run --rm \\
  --name presto-worker \\
  --network host \\
  --memory=$${DOCKER_MEM_LIMIT_GB}g \\
  --memory-swap=$${DOCKER_MEM_LIMIT_GB}g \\
  -v /opt/presto/etc:/opt/presto-server/etc:ro \\
  -v /var/presto/data:/var/presto/data \\
  -v /var/presto/catalog:/var/presto/catalog \\
  -v /var/presto/cache:/var/presto/cache \\
  -e LD_LIBRARY_PATH=/usr/local/lib:/usr/local/lib64:/usr/lib:/usr/lib64 \\
  -e AWS_ACCESS_KEY_ID=${aws_access_key_id} \\
  -e AWS_SECRET_ACCESS_KEY=${aws_secret_access_key} \\
  -e AWS_SESSION_TOKEN=${aws_session_token} \\
  $${PRESTO_IMAGE} \\
  --etc_dir=/opt/presto-server/etc --logtostderr=1 --v=1
ExecStop=/usr/bin/docker stop presto-worker
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
SERVICEEOF

# Start Presto Worker
echo "Starting Presto Native Worker..."
systemctl daemon-reload
systemctl enable presto
systemctl start presto

# Check status
sleep 10
if docker ps | grep presto-worker > /dev/null 2>&1; then
  echo "✅ Worker started successfully!"
else
  echo "⚠️ Worker not started yet"
  echo "Systemd service status:"
  systemctl status presto --no-pager -l | head -20
  echo ""
  echo "Docker logs (if container exists):"
  docker logs presto-worker 2>&1 | tail -30 || echo "No container logs available"
fi

echo "=== Worker Setup Complete ==="
echo "Presto Native Worker running"
echo "Image: ${presto_native_image}"
echo "Will connect to coordinator at ${coordinator_ip}:8080"

