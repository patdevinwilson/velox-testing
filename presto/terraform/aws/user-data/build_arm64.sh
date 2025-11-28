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
sudo -u ec2-user git clone https://github.com/prestodb/presto.git
sudo -u ec2-user git clone https://github.com/facebookincubator/velox.git
sudo -u ec2-user git clone https://github.com/NVIDIA/velox-testing.git

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

# Create ARM64 build script
cat > /home/ec2-user/build_arm64.sh << 'BUILDSCRIPT'
#!/bin/bash
set -e

echo "=== Building Presto Native for ARM64 (Graviton) ==="
date

cd /home/ec2-user

# Build Presto Java package first (needed for coordinator)
echo "=== Building Presto Java Package ==="
cd /home/ec2-user/presto
export JAVA_HOME=/usr/lib/jvm/java-17-amazon-corretto
./mvnw clean install -DskipTests -Dmaven.javadoc.skip=true -pl '!presto-docs' -T 1C

# Find the built tarball
PRESTO_TARBALL=$(find /home/ec2-user/presto/presto-server/target -name "presto-server-*.tar.gz" | head -1)
echo "Presto tarball: $PRESTO_TARBALL"

# Build Velox dependencies for ARM64
echo "=== Building Velox Dependencies ==="
cd /home/ec2-user/velox
./scripts/setup-centos9.sh

# Build Velox with S3 support
echo "=== Building Velox with S3 Support ==="
make release EXTRA_CMAKE_FLAGS="-DVELOX_ENABLE_S3=ON -DVELOX_ENABLE_HDFS=ON -DVELOX_ENABLE_PARQUET=ON"

# Build Presto Native
echo "=== Building Presto Native ==="
cd /home/ec2-user/presto/presto-native-execution
cmake -B _build/release -GNinja -DCMAKE_BUILD_TYPE=Release \
    -DPRESTO_ENABLE_PARQUET=ON \
    -DVELOX_ENABLE_S3=ON \
    -DVELOX_ENABLE_HDFS=ON
ninja -C _build/release presto_server

echo "=== Build complete! ==="
ls -la /home/ec2-user/presto/presto-native-execution/_build/release/presto_cpp/main/presto_server

# Create Docker images
echo "=== Creating ARM64 Docker Images ==="

# Worker image
mkdir -p /home/ec2-user/docker-worker
cd /home/ec2-user/docker-worker

# Copy binary and dependencies
cp /home/ec2-user/presto/presto-native-execution/_build/release/presto_cpp/main/presto_server .

# Get all required shared libraries
ldd presto_server | grep "=> /" | awk '{print $3}' | xargs -I {} cp {} . 2>/dev/null || true

# Download S3A jars for Hive connector
mkdir -p lib
cd lib
wget -q https://repo1.maven.org/maven2/org/apache/hadoop/hadoop-aws/3.3.4/hadoop-aws-3.3.4.jar
wget -q https://repo1.maven.org/maven2/com/amazonaws/aws-java-sdk-bundle/1.12.262/aws-java-sdk-bundle-1.12.262.jar
wget -q https://repo1.maven.org/maven2/org/apache/hadoop/hadoop-common/3.3.4/hadoop-common-3.3.4.jar
cd ..

cat > Dockerfile << 'DOCKERFILE'
FROM amazonlinux:2023

RUN dnf install -y libstdc++ openssl-libs zlib libcurl-minimal && \
    dnf clean all

WORKDIR /opt/presto-server

# Copy binary
COPY presto_server /opt/presto-server/bin/presto_server
RUN chmod +x /opt/presto-server/bin/presto_server

# Copy shared libraries
COPY *.so* /usr/local/lib64/
RUN ldconfig

# Copy S3A jars
COPY lib/*.jar /opt/presto-server/lib/
ENV CLASSPATH=/opt/presto-server/lib/*

# Create directories
RUN mkdir -p /opt/presto-server/etc /var/presto/data /var/presto/cache

EXPOSE 8080

ENTRYPOINT ["/opt/presto-server/bin/presto_server"]
CMD ["--config=/opt/presto-server/etc/config.properties", "--logtostderr=1", "--v=1"]
DOCKERFILE

docker build -t presto-native-arm64:latest .

# Coordinator image (Java)
mkdir -p /home/ec2-user/docker-coordinator
cd /home/ec2-user/docker-coordinator

tar -xzf "$PRESTO_TARBALL"
PRESTO_DIR=$(ls -d presto-server-* | head -1)

cat > Dockerfile << DOCKERFILE
FROM amazoncorretto:17

WORKDIR /opt/presto-server

COPY $${PRESTO_DIR}/ /opt/presto-server/

RUN mkdir -p /opt/presto-server/etc /var/presto/data

EXPOSE 8080

ENTRYPOINT ["/opt/presto-server/bin/launcher"]
CMD ["run"]
DOCKERFILE

docker build -t presto-coordinator-arm64:latest .

# Save and upload to S3
echo "=== Uploading ARM64 images to S3 ==="
TIMESTAMP=$(date +%Y%m%d-%H%M%S)

docker save presto-native-arm64:latest | gzip > /home/ec2-user/presto-worker-arm64-$${TIMESTAMP}.tar.gz
docker save presto-coordinator-arm64:latest | gzip > /home/ec2-user/presto-coordinator-arm64-$${TIMESTAMP}.tar.gz

aws s3 cp /home/ec2-user/presto-worker-arm64-$${TIMESTAMP}.tar.gz s3://rapids-db-io-us-east-1/docker-images/
aws s3 cp /home/ec2-user/presto-coordinator-arm64-$${TIMESTAMP}.tar.gz s3://rapids-db-io-us-east-1/docker-images/

# Also upload as latest
aws s3 cp /home/ec2-user/presto-worker-arm64-$${TIMESTAMP}.tar.gz s3://rapids-db-io-us-east-1/docker-images/presto-worker-arm64-latest.tar.gz
aws s3 cp /home/ec2-user/presto-coordinator-arm64-$${TIMESTAMP}.tar.gz s3://rapids-db-io-us-east-1/docker-images/presto-coordinator-arm64-latest.tar.gz

echo "=== ARM64 Build Complete! ==="
echo "Worker image: s3://rapids-db-io-us-east-1/docker-images/presto-worker-arm64-latest.tar.gz"
echo "Coordinator image: s3://rapids-db-io-us-east-1/docker-images/presto-coordinator-arm64-latest.tar.gz"
date
BUILDSCRIPT

chmod +x /home/ec2-user/build_arm64.sh
chown ec2-user:ec2-user /home/ec2-user/build_arm64.sh

# Create start marker
touch /home/ec2-user/READY_TO_BUILD

echo "=== Build instance ready ==="
echo "To start build: sudo -u ec2-user /home/ec2-user/build_arm64.sh"
echo ""
echo "Or run in tmux:"
echo "  tmux new -s build"
echo "  ./build_arm64.sh"

