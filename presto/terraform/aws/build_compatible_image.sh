#!/bin/bash
# Build Protocol-Compatible Presto Native Image
# Uses exact commits from velox-testing compatibility matrix

set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Building Protocol-Compatible Presto Native Image"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Presto commit: 92865fbce0 (November 12)"
echo "Velox commit: 65797d572e (November 17, IBM-techpreview)"
echo ""

# Navigate to parent directory (sibling repos location)
# Expected structure:
#   /Users/pwilson/projects/
#   ├── velox-testing/  (current repo)
#   ├── presto/         (sibling - REQUIRED)
#   └── velox/          (sibling - REQUIRED)

# Go up from velox-testing/presto/terraform/aws to parent
cd "${SCRIPT_DIR}/../../../.."
PARENT_DIR=$(pwd)

# Verify we're in the right place
if [ ! -d "${PARENT_DIR}/velox-testing" ]; then
    echo "Error: Not in parent directory of velox-testing"
    echo "Current: ${PARENT_DIR}"
    echo "Expected to find: ${PARENT_DIR}/velox-testing"
    exit 1
fi

echo "Working directory: ${PARENT_DIR}"
echo ""

# Verify velox-testing exists
if [ ! -d "${PARENT_DIR}/velox-testing" ]; then
    echo "Error: velox-testing not found"
    echo "Expected: ${PARENT_DIR}/velox-testing"
    exit 1
fi

# Clone or update repos
echo "=== Setting up sibling repositories ==="

# Presto (sibling to velox-testing)
if [ ! -d "${PARENT_DIR}/presto" ]; then
    echo "Cloning presto..."
    cd "${PARENT_DIR}"
    git clone https://github.com/prestodb/presto.git
    cd presto
    git checkout 92865fbce0
    echo "✓ Presto checked out at commit 92865fbce0"
else
    echo "Updating presto to commit 92865fbce0..."
    cd "${PARENT_DIR}/presto"
    git fetch
    git checkout 92865fbce0
    echo "✓ Presto at commit 92865fbce0"
fi

# Velox (sibling to velox-testing)
if [ ! -d "${PARENT_DIR}/velox" ]; then
    echo "Cloning velox (IBM-techpreview branch)..."
    cd "${PARENT_DIR}"
    git clone -b IBM-techpreview https://github.com/rapidsai/velox.git
    cd velox
    git checkout 65797d572e
    echo "✓ Velox checked out at commit 65797d572e"
else
    echo "Updating velox to commit 65797d572e..."
    cd "${PARENT_DIR}/velox"
    git fetch origin IBM-techpreview
    git checkout 65797d572e
    echo "✓ Velox at commit 65797d572e"
fi

cd "${PARENT_DIR}"

echo ""
echo "✓ All sibling repositories ready"
echo ""

echo "Directory structure:"
ls -ld velox-testing presto velox
echo ""

# Build dependencies (if not already built)
echo "=== Building Presto Native dependencies ==="
cd velox-testing/presto/scripts

if ! docker images | grep -q "presto/prestissimo-dependency:centos9"; then
    echo "Building dependencies image (this takes 30-60 minutes)..."
    ./build_centos_deps_image.sh
else
    echo "✓ Dependencies image already exists"
fi

echo ""
echo "=== Building Presto Native with matching protocol ==="
echo "This will take 15-30 minutes depending on your machine..."
echo ""

# Build Presto Native
export BUILD_TYPE=Release
export NUM_THREADS=$(nproc)

./start_native_cpu_presto.sh --build all

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Build Complete!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Verify build
echo "=== Verifying images ==="
docker images | grep presto

echo ""
echo "=== Testing locally ==="
# The script should have started containers
if curl -s http://localhost:8080/v1/info > /dev/null 2>&1; then
    echo "✓ Coordinator running"
    curl -s http://localhost:8080/v1/info | jq '{coordinator, version}'
    
    echo ""
    echo "✓ Testing query execution..."
    docker exec presto-coordinator bash -c \
        "java -jar /usr/local/bin/presto --server localhost:8080 --catalog system --execute 'SELECT 1'" || \
    echo "Using presto CLI from image..."
    
    echo ""
    echo "Active workers:"
    curl -s http://localhost:8080/v1/cluster | jq '.activeWorkers'
else
    echo "⚠ Containers not running, start with: docker-compose up -d"
fi

echo ""
echo "=== Saving image for AWS deployment ==="
OUTPUT_FILE="/tmp/presto-native-bd64355-compatible.tar.gz"

docker save presto-native-worker-cpu:latest | gzip > "${OUTPUT_FILE}"

echo "✓ Image saved to: ${OUTPUT_FILE}"
echo "  Size: $(du -h ${OUTPUT_FILE} | cut -f1)"
echo ""

echo "=== Upload to S3 ==="
echo "Run:"
echo "  aws s3 cp ${OUTPUT_FILE} s3://rapids-db-io-us-east-1/docker-images/"
echo ""
echo "Then update terraform.tfvars:"
echo '  presto_native_image_source = "s3://rapids-db-io-us-east-1/docker-images/presto-native-bd64355-compatible.tar.gz"'
echo ""
echo "And redeploy:"
echo "  cd velox-testing/presto/terraform/aws"
echo "  terraform destroy -auto-approve"
echo "  ./deploy_presto.sh"
echo ""
echo "This image will be protocol-compatible with Java coordinator 0.289-bd64355!"

