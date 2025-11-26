#!/bin/bash
# Build Instance User-Data with S3A Support
# Builds Presto coordinator + worker with full S3 filesystem support

set -e

exec > >(tee /var/log/user-data.log)
exec 2>&1

echo "=== Presto Native Build Instance Setup (With S3A Support) ==="
date

# Update system
dnf update -y

# Install build dependencies
dnf install -y --allowerasing git docker gcc-c++ make cmake python3 wget curl awscli

# Start Docker
systemctl start docker
systemctl enable docker
usermod -aG docker ec2-user

# Install Docker Compose
curl -SL https://github.com/docker/compose/releases/download/v2.24.0/docker-compose-linux-x86_64 \
  -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose

# Install Docker Buildx
mkdir -p /root/.docker/cli-plugins
curl -SL https://github.com/docker/buildx/releases/download/v0.12.1/buildx-v0.12.1.linux-amd64 \
  -o /root/.docker/cli-plugins/docker-buildx
chmod +x /root/.docker/cli-plugins/docker-buildx

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

echo "=== Cloning Repositories ==="
cd /home/ec2-user

# Clone repos at specific commits
sudo -u ec2-user git clone https://github.com/rapidsai/velox-testing.git
sudo -u ec2-user git clone https://github.com/prestodb/presto.git
sudo -u ec2-user git clone -b IBM-techpreview https://github.com/rapidsai/velox.git

cd presto
sudo -u ec2-user git checkout 92865fbce0
cd ../velox  
sudo -u ec2-user git checkout 65797d572e
cd ..

echo "✓ All repositories ready"

# Create automated build script with S3A support
cat > /home/ec2-user/build_with_s3a.sh << 'EOFBUILD'
#!/bin/bash
set -e

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Building Presto Native with S3A Support"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Step 1: Build dependency image
echo "Step 1: Building dependencies (30-60 min)..."
cd ~/presto/presto-native-execution
rm -rf velox velox.bak
mkdir -p velox
cp -r ~/velox/scripts velox/
cp -r ~/velox/CMake velox/

cd ~/velox-testing
docker-compose -f presto/docker/docker-compose.yml build centos-native-dependency 2>&1 | tee /tmp/build_deps_final.log

echo "✓ Dependency image complete"

# Step 2: Compile Presto Native
echo ""
echo "Step 2: Compiling Presto Native (20-30 min)..."
mkdir -p ~/presto_build_s3a

docker run --rm \
  -v ~/presto/presto-native-execution:/presto \
  -v ~/velox:/presto/velox \
  -v ~/presto_build_s3a:/output \
  -w /presto \
  presto/prestissimo-dependency:centos9 \
  bash -c "
    make cmake-and-build BUILD_TYPE=release NUM_THREADS=32
    
    # Copy binary
    find . -name presto_server -type f -exec cp {} /output/ \;
    
    # Collect runtime libs
    mkdir -p /output/libs
    ldd /output/presto_server | awk 'NF == 4 { system(\"cp -L \" \\\$3 \" /output/libs/\") }'
    
    # Copy all boost libs
    cp -L /usr/local/lib/libboost*.so* /output/libs/ 2>/dev/null || true
  " 2>&1 | tee /tmp/compile_s3a.log

echo "✓ Presto Native compiled"

# Step 3: Download S3A libraries
echo ""
echo "Step 3: Adding S3A filesystem libraries..."
cd ~/presto_build_s3a

wget -q https://repo1.maven.org/maven2/org/apache/hadoop/hadoop-aws/3.3.4/hadoop-aws-3.3.4.jar
wget -q https://repo1.maven.org/maven2/com/amazonaws/aws-java-sdk-bundle/1.12.262/aws-java-sdk-bundle-1.12.262.jar
wget -q https://repo1.maven.org/maven2/org/apache/hadoop/hadoop-common/3.3.4/hadoop-common-3.3.4.jar
wget -q https://repo1.maven.org/maven2/org/apache/hadoop/hadoop-hdfs-client/3.3.4/hadoop-hdfs-client-3.3.4.jar

echo "✓ S3A libraries downloaded"

# Step 4: Create Dockerfile with S3A support
cat > Dockerfile << 'EOFDOCKER'
FROM presto/prestissimo-dependency:centos9

# Copy Presto Native binary
COPY presto_server /usr/bin/presto_server

# Copy all runtime libraries
COPY libs/* /usr/lib64/presto-native-libs/

# Copy S3A filesystem libraries
COPY hadoop-aws-3.3.4.jar /usr/lib64/presto-native-libs/
COPY aws-java-sdk-bundle-1.12.262.jar /usr/lib64/presto-native-libs/
COPY hadoop-common-3.3.4.jar /usr/lib64/presto-native-libs/
COPY hadoop-hdfs-client-3.3.4.jar /usr/lib64/presto-native-libs/

# Configure library paths
RUN echo "/usr/lib64/presto-native-libs" > /etc/ld.so.conf.d/presto_native.conf && \
    ldconfig && \
    chmod +x /usr/bin/presto_server

# Velox S3 configuration
ENV VELOX_S3_ENDPOINT=s3.us-east-1.amazonaws.com
ENV CLASSPATH=/usr/lib64/presto-native-libs/hadoop-aws-3.3.4.jar:/usr/lib64/presto-native-libs/aws-java-sdk-bundle-1.12.262.jar:/usr/lib64/presto-native-libs/hadoop-common-3.3.4.jar

WORKDIR /opt/presto-server

CMD ["bash", "-c", "ldconfig && /usr/bin/presto_server --etc-dir=/opt/presto-server/etc"]
EOFDOCKER

echo "✓ Dockerfile created with S3A support"

# Step 5: Build final image
echo ""
echo "Step 5: Building Docker image with S3A..."
docker build -t presto-native-worker-cpu:s3a-enabled . 2>&1 | tee /tmp/image_build_s3a.log

echo "✓ Image built"

# Step 6: Test S3 support
echo ""
echo "Step 6: Testing S3 filesystem registration..."
docker run --rm presto-native-worker-cpu:s3a-enabled bash -c "
  ldconfig
  /usr/bin/presto_server --help 2>&1 | head -5
"

# Step 7: Save and upload
echo ""
echo "Step 7: Saving and uploading to S3..."
cd ~
docker save presto-native-worker-cpu:s3a-enabled | gzip > presto-worker-s3a.tar.gz

echo "Uploading..."
aws s3 cp presto-worker-s3a.tar.gz s3://rapids-db-io-us-east-1/docker-images/presto-worker-matched.tar.gz

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ✅ BUILD COMPLETE WITH S3A SUPPORT!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Image uploaded to:"
echo "  s3://rapids-db-io-us-east-1/docker-images/presto-worker-matched.tar.gz"
echo ""
echo "Ready to deploy with full S3 parquet + protocol matching!"
EOFBUILD

chmod +x /home/ec2-user/build_with_s3a.sh
chown ec2-user:ec2-user /home/ec2-user/build_with_s3a.sh

echo "=== Build Instance Ready ==="
echo "Automated build script: ~/build_with_s3a.sh"
echo "Run time: ~90 minutes"
echo ""
echo "User data script completed successfully"


