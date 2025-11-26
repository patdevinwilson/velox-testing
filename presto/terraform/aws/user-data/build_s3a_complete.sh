#!/bin/bash
# Complete Build for Presto Coordinator + Worker with S3A Support
# Builds protocol-matched images with full AWS S3 / Hive metastore support

set -e

exec > >(tee /var/log/user-data.log)
exec 2>&1

echo "=== Presto Build Instance with S3A Support ==="
date

# Update and install dependencies
dnf update -y
dnf install -y --allowerasing git docker gcc-c++ make cmake python3 wget curl awscli

# Install Java 17 for Presto Java build (required by newer Presto versions)
dnf install -y java-17-amazon-corretto java-17-amazon-corretto-devel
export JAVA_HOME=/usr/lib/jvm/java-17-amazon-corretto
echo "export JAVA_HOME=/usr/lib/jvm/java-17-amazon-corretto" >> /etc/profile.d/java17.sh

# Start Docker
systemctl start docker
systemctl enable docker
usermod -aG docker ec2-user

# Install Docker Compose
curl -SL https://github.com/docker/compose/releases/download/v2.24.0/docker-compose-linux-x86_64 \
  -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose
docker-compose --version

# Configure AWS credentials
mkdir -p /root/.aws /home/ec2-user/.aws
cat > /root/.aws/credentials << 'CREDS'
[default]
aws_access_key_id = ${aws_access_key_id}
aws_secret_access_key = ${aws_secret_access_key}
aws_session_token = ${aws_session_token}
CREDS

cat > /root/.aws/config << 'CONFIG'
[default]
region = ${aws_region}
output = json
CONFIG

cp /root/.aws/credentials /home/ec2-user/.aws/
cp /root/.aws/config /home/ec2-user/.aws/
chown -R ec2-user:ec2-user /home/ec2-user/.aws
chmod 600 /home/ec2-user/.aws/credentials

# Clone repositories as ec2-user
cd /home/ec2-user
echo "Cloning repositories..."

sudo -u ec2-user git clone https://github.com/rapidsai/velox-testing.git 2>&1 | tail -2 &
sudo -u ec2-user git clone https://github.com/prestodb/presto.git 2>&1 | tail -2 &
sudo -u ec2-user git clone -b IBM-techpreview https://github.com/rapidsai/velox.git 2>&1 | tail -2 &

wait

# CRITICAL: Lock both to exact commits for protocol matching
cd presto && sudo -u ec2-user git checkout 92865fbce0 && cd ..
cd velox && sudo -u ec2-user git checkout 65797d572e && cd ..

echo "✓ Repositories at exact commits:"
echo "  Presto: 92865fbce0 (Nov 12, 2024)"
echo "  Velox: 65797d572e (Nov 17, 2024)"

echo "✓ Repositories ready"

# Create automated build script
cat > /home/ec2-user/auto_build_s3a.sh << 'EOFAUTO'
#!/bin/bash
# Automated build with progress logging
set -e

LOG_FILE=~/build_progress.log
exec > >(tee $${LOG_FILE})
exec 2>&1

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Automated Presto Build with S3A Support"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Started: $(date)"
echo "  Presto: 92865fbce0"
echo "  Velox: 65797d572e"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# === STEP 1: Build Dependency Image ===
echo "[$(date +%H:%M:%S)] Step 1/5: Building dependency image (30-60 min)"
cd ~/presto/presto-native-execution

rm -rf velox
mkdir -p velox
cp -r ~/velox/scripts velox/
cp -r ~/velox/CMake velox/

cd ~/velox-testing
docker-compose build centos-native-dependency

echo "[$(date +%H:%M:%S)] ✓ Dependency image complete"

# === STEP 2: Build Presto Java ===
echo ""
echo "[$(date +%H:%M:%S)] Step 2/5: Building Presto Java package (5-10 min)"
cd ~/velox-testing/presto/scripts
PRESTO_VERSION=testing ./build_presto_java_package.sh | tail -20

echo "[$(date +%H:%M:%S)] ✓ Presto Java built"

# === STEP 3: Compile Presto Native ===
echo ""
echo "[$(date +%H:%M:%S)] Step 3/5: Compiling Presto Native C++ (20-30 min)"
mkdir -p ~/presto_with_s3a

docker run --rm \
  -v ~/presto/presto-native-execution:/presto \
  -v ~/velox:/presto/velox \
  -v ~/presto_with_s3a:/output \
  -w /presto \
  presto/prestissimo-dependency:centos9 \
  bash -c "
    make cmake-and-build \
      BUILD_TYPE=release \
      NUM_THREADS=32 \
      EXTRA_CMAKE_FLAGS='-DVELOX_ENABLE_S3=ON -DVELOX_ENABLE_HDFS=ON -DPRESTO_ENABLE_PARQUET=ON'
    find . -name presto_server -type f -exec cp {} /output/ \;
    mkdir -p /output/libs
    ldd /output/presto_server 2>/dev/null | awk 'NF == 4 { system(\"cp -L \" \\\$3 \" /output/libs/\") }'
    cp -L /usr/local/lib/libboost*.so* /output/libs/ 2>/dev/null || true
  "

echo "[$(date +%H:%M:%S)] ✓ Presto Native compiled"

# === STEP 4: Create Images with S3A ===
echo ""
echo "[$(date +%H:%M:%S)] Step 4/5: Creating Docker images with S3A support"
cd ~/presto_with_s3a

# Download S3A libraries
wget -q https://repo1.maven.org/maven2/org/apache/hadoop/hadoop-aws/3.3.4/hadoop-aws-3.3.4.jar
wget -q https://repo1.maven.org/maven2/com/amazonaws/aws-java-sdk-bundle/1.12.262/aws-java-sdk-bundle-1.12.262.jar
wget -q https://repo1.maven.org/maven2/org/apache/hadoop/hadoop-common/3.3.4/hadoop-common-3.3.4.jar
wget -q https://repo1.maven.org/maven2/org/apache/hadoop/hadoop-hdfs-client/3.3.4/hadoop-hdfs-client-3.3.4.jar

# Create worker Dockerfile
cat > Dockerfile.worker << 'EOFW'
FROM presto/prestissimo-dependency:centos9
COPY presto_server /usr/bin/presto_server
COPY libs/* /usr/lib64/presto-native-libs/
COPY *.jar /usr/lib64/presto-native-libs/
RUN echo "/usr/lib64/presto-native-libs" > /etc/ld.so.conf.d/presto_native.conf && \
    ldconfig && \
    chmod +x /usr/bin/presto_server
ENV CLASSPATH=/usr/lib64/presto-native-libs/hadoop-aws-3.3.4.jar:/usr/lib64/presto-native-libs/aws-java-sdk-bundle-1.12.262.jar:/usr/lib64/presto-native-libs/hadoop-common-3.3.4.jar:/usr/lib64/presto-native-libs/hadoop-hdfs-client-3.3.4.jar
ENV VELOX_S3_ENDPOINT=s3.us-east-1.amazonaws.com
WORKDIR /opt/presto-server
CMD ["bash", "-c", "ldconfig && /usr/bin/presto_server --etc-dir=/opt/presto-server/etc"]
EOFW

docker build -f Dockerfile.worker -t presto-native-worker-cpu:latest .

# Build coordinator from Presto Java tarball
cd ~/presto/docker
docker build --build-arg PRESTO_VERSION=testing -t presto-coordinator:latest .

echo "[$(date +%H:%M:%S)] ✓ Images built"

# === STEP 5: Save and Upload ===
echo ""
echo "[$(date +%H:%M:%S)] Step 5/5: Uploading to S3"
cd ~

# Create timestamped filenames
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
COORD_FILE="presto-coordinator-matched-$${TIMESTAMP}.tar.gz"
WORKER_FILE="presto-worker-matched-$${TIMESTAMP}.tar.gz"

docker save presto-coordinator:latest | gzip > $$COORD_FILE
docker save presto-native-worker-cpu:latest | gzip > $$WORKER_FILE

# Upload with timestamp
aws s3 cp $$COORD_FILE s3://rapids-db-io-us-east-1/docker-images/
aws s3 cp $$WORKER_FILE s3://rapids-db-io-us-east-1/docker-images/

# Also upload as "latest" for easy reference
aws s3 cp $$COORD_FILE s3://rapids-db-io-us-east-1/docker-images/presto-coordinator-matched-latest.tar.gz
aws s3 cp $$WORKER_FILE s3://rapids-db-io-us-east-1/docker-images/presto-worker-matched-latest.tar.gz

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ✅ BUILD COMPLETE!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Completed: $(date)"
echo ""
echo "Images with S3A support uploaded to S3:"
echo "  Timestamped:"
echo "    - s3://rapids-db-io-us-east-1/docker-images/$$COORD_FILE"
echo "    - s3://rapids-db-io-us-east-1/docker-images/$$WORKER_FILE"
echo "  Latest (symlinks):"
echo "    - s3://rapids-db-io-us-east-1/docker-images/presto-coordinator-matched-latest.tar.gz"
echo "    - s3://rapids-db-io-us-east-1/docker-images/presto-worker-matched-latest.tar.gz"
echo ""
echo "Features:"
echo "  ✅ Protocol-matched (Presto commit 92865fbce0)"
echo "  ✅ Velox S3 support enabled (VELOX_ENABLE_S3=ON)"
echo "  ✅ Hadoop S3A libraries included"
echo "  ✅ Ready for AWS Glue + S3 parquet!"
EOFAUTO

chmod +x /home/ec2-user/auto_build_s3a.sh
chown ec2-user:ec2-user /home/ec2-user/auto_build_s3a.sh

cat > /home/ec2-user/START_BUILD.txt << 'INSTRUCTIONS'
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Build Instance Ready!
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

To start the automated build:
  ./auto_build_s3a.sh

Or run manually:
  1. cd ~/presto/presto-native-execution && setup Velox
  2. cd ~/velox-testing && docker-compose build centos-native-dependency
  3. cd ~/velox-testing/presto/scripts && PRESTO_VERSION=testing ./build_presto_java_package.sh
  4. Compile and create worker image with S3A jars
  5. Build coordinator from tarball
  6. Upload both to S3

Estimated time: 90 minutes

INSTRUCTIONS

echo "=== Build Instance Ready ===" 
echo "Run: ./auto_build_s3a.sh"
echo ""
echo "User data script completed successfully"

