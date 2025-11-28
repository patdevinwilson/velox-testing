#!/bin/bash
set -e

# Logging
exec > >(tee /var/log/user-data.log)
exec 2>&1

echo "=== Presto Native ARM64 (Graviton) Build Instance ==="
date

# AWS Credentials
export AWS_ACCESS_KEY_ID="${aws_access_key_id}"
export AWS_SECRET_ACCESS_KEY="${aws_secret_access_key}"
export AWS_SESSION_TOKEN="${aws_session_token}"
export AWS_DEFAULT_REGION="${aws_region}"

# Update system
dnf update -y
dnf install -y git docker cmake ninja-build gcc gcc-c++ python3 python3-pip \
    java-17-amazon-corretto-devel maven awscli jq htop tmux

# Start Docker
systemctl start docker
systemctl enable docker
usermod -aG docker ec2-user

# Install Docker Compose
curl -L "https://github.com/docker/compose/releases/download/v2.24.0/docker-compose-linux-aarch64" -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose
ln -sf /usr/local/bin/docker-compose /usr/bin/docker-compose

# Clone repositories
cd /home/ec2-user
sudo -u ec2-user git clone https://github.com/prestodb/presto.git &
sudo -u ec2-user git clone -b IBM-techpreview https://github.com/rapidsai/velox.git &
sudo -u ec2-user git clone https://github.com/rapidsai/velox-testing.git &
wait

# Checkout compatible commits (same as x86 build)
cd /home/ec2-user/presto
sudo -u ec2-user git checkout 92865fbce0

cd /home/ec2-user/velox
sudo -u ec2-user git checkout 65797d572e

cd /home/ec2-user/velox-testing
sudo -u ec2-user git checkout b7f0ace60e

echo "=== Repositories cloned and checked out ==="
echo "  Presto: 92865fbce0"
echo "  Velox: 65797d572e"
echo "  Velox Testing: b7f0ace60e"

# CRITICAL: Copy velox into presto-native-execution for Docker build context
# Docker doesn't follow symlinks, so we must copy the files
echo "=== Setting up Docker build context ==="
cd /home/ec2-user/presto/presto-native-execution
sudo -u ec2-user rm -rf velox
sudo -u ec2-user cp -r /home/ec2-user/velox velox
echo "Velox copied into presto-native-execution"

# Create ARM64 build script
cat > /home/ec2-user/build_arm64.sh << 'BUILDSCRIPT'
#!/bin/bash
set -e

LOG_FILE=/home/ec2-user/build_progress.log
exec > >(tee -a "$LOG_FILE")
exec 2>&1

echo "=== Building Presto Native for ARM64 (Graviton) ==="
date

cd /home/ec2-user

# Step 1: Build dependency image using Docker (handles all complex deps)
echo ""
echo "[$(date +%H:%M:%S)] Step 1/4: Building ARM64 dependency image (this takes ~60 min)"
echo "============================================================"
cd /home/ec2-user/presto/presto-native-execution

# Build the dependency image with ARM flag
docker build \
    --build-arg ARM_BUILD_TARGET=aarch64 \
    -f scripts/dockerfiles/centos-dependency.dockerfile \
    -t presto/prestissimo-dependency:centos9 \
    . 2>&1 | tee /home/ec2-user/deps_build.log

if ! docker images | grep -q "presto/prestissimo-dependency"; then
    echo "ERROR: Dependency image build failed!"
    exit 1
fi
echo "✓ Dependency image built successfully"

# Step 2: Build Presto Java package (needed for coordinator)
echo ""
echo "[$(date +%H:%M:%S)] Step 2/4: Building Presto Java Package"
echo "============================================================"
cd /home/ec2-user/presto
export JAVA_HOME=/usr/lib/jvm/java-17-amazon-corretto
./mvnw clean install -DskipTests -Dmaven.javadoc.skip=true -pl '!presto-docs' -T 1C 2>&1 | tail -100

# Find the built tarball
PRESTO_TARBALL=$(find /home/ec2-user/presto/presto-server/target -name "presto-server-*.tar.gz" | head -1)
if [ -z "$PRESTO_TARBALL" ]; then
    echo "ERROR: Presto tarball not found!"
    exit 1
fi
echo "✓ Presto tarball: $PRESTO_TARBALL"

# Step 3: Build Presto Native using Docker (uses the dependency image)
echo ""
echo "[$(date +%H:%M:%S)] Step 3/4: Building Presto Native worker image"
echo "============================================================"
cd /home/ec2-user/presto/presto-native-execution

# Create a simplified Dockerfile for the native worker
cat > /tmp/arm64-worker.dockerfile << 'DOCKERFILE'
FROM presto/prestissimo-dependency:centos9

ARG BUILD_TYPE=release
ARG NUM_THREADS=16
ARG EXTRA_CMAKE_FLAGS="-DPRESTO_ENABLE_TESTING=OFF -DPRESTO_ENABLE_PARQUET=ON -DVELOX_ENABLE_S3=ON -DVELOX_ENABLE_HDFS=ON -DVELOX_BUILD_TESTING=OFF"

ENV EXTRA_CMAKE_FLAGS=${EXTRA_CMAKE_FLAGS}
ENV NUM_THREADS=${NUM_THREADS}

RUN mkdir /runtime-libraries

RUN --mount=type=bind,source=.,target=/presto_native_staging/presto \
    --mount=type=cache,target=/build_cache \
    make --directory="/presto_native_staging/presto" cmake-and-build \
        BUILD_TYPE=${BUILD_TYPE} \
        BUILD_DIR="" \
        BUILD_BASE_DIR=/build_cache && \
    cp /build_cache/presto_cpp/main/presto_server /usr/bin/ && \
    LD_LIBRARY_PATH=/usr/local/lib:/usr/local/lib64 ldd /usr/bin/presto_server | \
        awk 'NF == 4 { system("cp " $3 " /runtime-libraries") }' || true

# Download S3A jars for Hive connector
RUN mkdir -p /opt/presto-server/lib && \
    curl -sL -o /opt/presto-server/lib/hadoop-aws-3.3.4.jar \
        https://repo1.maven.org/maven2/org/apache/hadoop/hadoop-aws/3.3.4/hadoop-aws-3.3.4.jar && \
    curl -sL -o /opt/presto-server/lib/aws-java-sdk-bundle-1.12.262.jar \
        https://repo1.maven.org/maven2/com/amazonaws/aws-java-sdk-bundle/1.12.262/aws-java-sdk-bundle-1.12.262.jar && \
    curl -sL -o /opt/presto-server/lib/hadoop-common-3.3.4.jar \
        https://repo1.maven.org/maven2/org/apache/hadoop/hadoop-common/3.3.4/hadoop-common-3.3.4.jar

# Set up runtime environment
RUN mkdir -p /usr/lib64/presto-native-libs && \
    cp /runtime-libraries/* /usr/lib64/presto-native-libs/ 2>/dev/null || true && \
    echo "/usr/lib64/presto-native-libs" > /etc/ld.so.conf.d/presto_native.conf && \
    echo "/usr/local/lib" >> /etc/ld.so.conf.d/presto_native.conf && \
    echo "/usr/local/lib64" >> /etc/ld.so.conf.d/presto_native.conf && \
    ldconfig

ENV CLASSPATH=/opt/presto-server/lib/*
ENV LD_LIBRARY_PATH=/usr/lib64/presto-native-libs:/usr/local/lib:/usr/local/lib64

RUN mkdir -p /opt/presto-server/etc /var/presto/data /var/presto/cache

EXPOSE 8080

ENTRYPOINT ["/usr/bin/presto_server"]
CMD ["--config=/opt/presto-server/etc/config.properties", "--logtostderr=1", "--v=1"]
DOCKERFILE

docker build \
    -f /tmp/arm64-worker.dockerfile \
    -t presto-native-arm64:latest \
    . 2>&1 | tee /home/ec2-user/native_build.log

if ! docker images | grep -q "presto-native-arm64"; then
    echo "ERROR: Native worker image build failed!"
    exit 1
fi
echo "✓ Native worker image built"

# Step 4: Build coordinator image (Java)
echo ""
echo "[$(date +%H:%M:%S)] Step 4/4: Building coordinator image"
echo "============================================================"
mkdir -p /home/ec2-user/docker-coordinator
cd /home/ec2-user/docker-coordinator

tar -xzf "$PRESTO_TARBALL"
PRESTO_DIR=$(ls -d presto-server-* | head -1)

cat > Dockerfile << DOCKERFILE
FROM amazoncorretto:17

WORKDIR /opt/presto-server

COPY ${PRESTO_DIR}/ /opt/presto-server/

RUN mkdir -p /opt/presto-server/etc /var/presto/data

EXPOSE 8080

ENTRYPOINT ["/opt/presto-server/bin/launcher"]
CMD ["run"]
DOCKERFILE

docker build -t presto-coordinator-arm64:latest .
echo "✓ Coordinator image built"

# Upload to S3
echo ""
echo "[$(date +%H:%M:%S)] Uploading ARM64 images to S3"
echo "============================================================"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)

docker save presto-native-arm64:latest | gzip > /home/ec2-user/presto-worker-arm64-${TIMESTAMP}.tar.gz
docker save presto-coordinator-arm64:latest | gzip > /home/ec2-user/presto-coordinator-arm64-${TIMESTAMP}.tar.gz

# Upload with timestamp
aws s3 cp /home/ec2-user/presto-worker-arm64-${TIMESTAMP}.tar.gz \
    s3://rapids-db-io-us-east-1/docker-images/ --no-progress
aws s3 cp /home/ec2-user/presto-coordinator-arm64-${TIMESTAMP}.tar.gz \
    s3://rapids-db-io-us-east-1/docker-images/ --no-progress

# Also upload as latest
aws s3 cp /home/ec2-user/presto-worker-arm64-${TIMESTAMP}.tar.gz \
    s3://rapids-db-io-us-east-1/docker-images/presto-worker-arm64-latest.tar.gz --no-progress
aws s3 cp /home/ec2-user/presto-coordinator-arm64-${TIMESTAMP}.tar.gz \
    s3://rapids-db-io-us-east-1/docker-images/presto-coordinator-arm64-latest.tar.gz --no-progress

echo ""
echo "============================================================"
echo "=== ARM64 Build Complete! ==="
echo "============================================================"
echo "Worker image: s3://rapids-db-io-us-east-1/docker-images/presto-worker-arm64-latest.tar.gz"
echo "Coordinator image: s3://rapids-db-io-us-east-1/docker-images/presto-coordinator-arm64-latest.tar.gz"
echo ""
echo "Timestamped versions:"
echo "  presto-worker-arm64-${TIMESTAMP}.tar.gz"
echo "  presto-coordinator-arm64-${TIMESTAMP}.tar.gz"
echo ""
date
touch /home/ec2-user/BUILD_COMPLETE
BUILDSCRIPT

chmod +x /home/ec2-user/build_arm64.sh
chown ec2-user:ec2-user /home/ec2-user/build_arm64.sh

# Create start marker
touch /home/ec2-user/READY_TO_BUILD
chown ec2-user:ec2-user /home/ec2-user/READY_TO_BUILD

echo "=== Build instance ready ==="
echo "Velox directory structure verified in presto-native-execution"
ls -la /home/ec2-user/presto/presto-native-execution/velox/CMake/resolve_dependency_modules/arrow/ 2>/dev/null || echo "Warning: Arrow patch not found"

# Auto-start build in background
echo ""
echo "=== Auto-starting ARM64 build ==="
sudo -u ec2-user nohup /home/ec2-user/build_arm64.sh > /home/ec2-user/build_output.log 2>&1 &
echo "Build started with PID: $!"
echo "Monitor with: tail -f /home/ec2-user/build_progress.log"
