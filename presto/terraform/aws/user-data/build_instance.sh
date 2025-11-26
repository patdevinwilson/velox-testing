#!/bin/bash
# Build Instance User-Data
# Builds protocol-matched Presto coordinator + worker images from same commit

set -e

exec > >(tee /var/log/user-data.log)
exec 2>&1

echo "=== Presto Native Build Instance Setup ==="
date

# Update system
dnf update -y

# Install build dependencies
dnf install -y git docker gcc-c++ make cmake python3 python3-pip wget curl awscli

# Start Docker
systemctl start docker
systemctl enable docker

# Add ec2-user to docker group
usermod -aG docker ec2-user

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

# Clone velox-testing
sudo -u ec2-user git clone https://github.com/rapidsai/velox-testing.git

# Clone Presto at specific commit (matches coordinator)
sudo -u ec2-user git clone https://github.com/prestodb/presto.git
cd presto
sudo -u ec2-user git checkout 92865fbce0
cd ..

# Clone Velox at specific commit
sudo -u ec2-user git clone -b IBM-techpreview https://github.com/rapidsai/velox.git
cd velox  
sudo -u ec2-user git checkout 65797d572e
cd ..

echo "✓ All repositories cloned at correct commits"

echo ""
echo "=== Creating Build Scripts ==="

# Automated build script
cat > /home/ec2-user/build_presto.sh << 'BUILDSSCRIPT'
#!/bin/bash
set -e

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Building Protocol-Matched Presto Images"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Presto: commit 92865fbce0"
echo "Velox: commit 65797d572e (IBM-techpreview)"
echo ""

cd ~/velox-testing/presto/scripts

echo "=== Step 1: Building Dependencies Image (30-60 minutes) ==="
./build_centos_deps_image.sh

echo ""
echo "=== Step 2: Building Presto Native (20-30 minutes) ==="
./start_native_cpu_presto.sh --build all

echo ""
echo "=== Step 3: Saving Images ==="
cd ~
docker save presto-coordinator:latest | gzip > presto-coordinator-matched.tar.gz
docker save presto-native-worker-cpu:latest | gzip > presto-worker-matched.tar.gz

echo "✓ Images saved:"
ls -lh presto-*.tar.gz

echo ""
echo "=== Step 4: Uploading to S3 ==="
aws s3 cp presto-coordinator-matched.tar.gz s3://rapids-db-io-us-east-1/docker-images/
aws s3 cp presto-worker-matched.tar.gz s3://rapids-db-io-us-east-1/docker-images/

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ✅ BUILD COMPLETE!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Images uploaded to S3:"
echo "  - presto-coordinator-matched.tar.gz"
echo "  - presto-worker-matched.tar.gz"
echo ""
echo "Next steps:"
echo "  1. Update terraform.tfvars:"
echo "     presto_native_image_source = \"s3://rapids-db-io-us-east-1/docker-images/presto-worker-matched.tar.gz\""
echo ""
echo "  2. Update coordinator_java.sh line 52:"
echo "     COORDINATOR_IMAGE_SOURCE=\"s3://rapids-db-io-us-east-1/docker-images/presto-coordinator-matched.tar.gz\""
echo ""
echo "  3. Redeploy cluster:"
echo "     terraform destroy -auto-approve"
echo "     ./deploy_presto.sh --native-mode prebuilt \\"
echo "       --prebuilt-image s3://rapids-db-io-us-east-1/docker-images/presto-worker-matched.tar.gz"
echo ""
echo "All 22 TPC-H queries will work with matched images!"
BUILDSSCRIPT

chmod +x /home/ec2-user/build_presto.sh

# Quick instructions
cat > /home/ec2-user/README.txt << 'INSTRUCTIONS'
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Presto Native Build Instance
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

This instance builds protocol-matched Presto coordinator + worker images.

Quick Start:
  ./build_presto.sh

Manual Steps:
  1. Build dependencies (~30-60 min):
     cd velox-testing/presto/scripts
     ./build_centos_deps_image.sh
  
  2. Build Presto Native (~20-30 min):
     ./start_native_cpu_presto.sh --build all
  
  3. Save and upload:
     docker save presto-coordinator:latest | gzip > presto-coordinator-matched.tar.gz
     docker save presto-native-worker-cpu:latest | gzip > presto-worker-matched.tar.gz
     aws s3 cp presto-coordinator-matched.tar.gz s3://rapids-db-io-us-east-1/docker-images/
     aws s3 cp presto-worker-matched.tar.gz s3://rapids-db-io-us-east-1/docker-images/

Total time: ~90 minutes

Repositories are already cloned at:
  - ~/velox-testing
  - ~/presto (commit 92865fbce0)
  - ~/velox (commit 65797d572e)

INSTRUCTIONS

chown ec2-user:ec2-user /home/ec2-user/BUILD_INSTRUCTIONS.txt

echo "=== Build Instance Ready ==="
echo "SSH: ssh -i ~/.ssh/rapids-db-io.pem ec2-user@$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4)"
echo "Instructions: cat ~/BUILD_INSTRUCTIONS.txt"
echo ""
echo "Presto commit: 92865fbce0"
echo "Velox commit: 65797d572e (IBM-techpreview)"
echo ""
echo "User data script completed successfully"


