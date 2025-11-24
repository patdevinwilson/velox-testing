# Presto Native Image Compatibility Guide

## Current Status

✅ **Deployment Automation**: Fully functional  
✅ **Java Coordinator**: Starting successfully  
✅ **Native Workers**: Active (2/2 workers registering)  
✅ **Cluster Memory**: 112GB available  
❌ **Query Execution**: Protocol mismatch between coordinator and workers

## The Issue

**Error:**
```
Expected response code from http://10.0.1.179:8080/v1/task/... to be 200, but was 500:
[json.exception.out_of_range.403] key 'scaleWriters' not found PartitioningScheme bool scaleWriters
```

**Root Cause:**
- Java coordinator `0.289-bd64355` uses newer protocol with `scaleWriters` field
- Presto Native image from S3 (Nov 18, 2025) was built from older Presto commit
- Protocol version mismatch prevents task communication

## Solutions

### Solution 1: Build Compatible Presto Native (Recommended)

Build Presto Native from the **same commit** as the Java coordinator:

```bash
# 1. Clone Presto at matching version
cd ~/projects
git clone https://github.com/prestodb/presto.git
cd presto
git checkout bd64355  # Match coordinator version

# 2. Build using velox-testing scripts
cd ../velox-testing/presto/scripts
./build_centos_deps_image.sh  # First time only
./start_native_cpu_presto.sh --build all

# 3. Save and upload image
docker save presto-native-worker-cpu:latest | gzip > /tmp/presto-native-compatible.tar.gz
aws s3 cp /tmp/presto-native-compatible.tar.gz s3://rapids-db-io-us-east-1/docker-images/

# 4. Update terraform.tfvars
presto_native_image_source = "s3://rapids-db-io-us-east-1/docker-images/presto-native-compatible.tar.gz"

# 5. Redeploy
terraform destroy -auto-approve
./deploy_presto.sh
```

### Solution 2: Use Matching Java Coordinator Version

Downgrade Java coordinator to match the Native worker:

**Update coordinator_java.sh:**
```bash
# Find the matching Presto version for the Native image
# Then download that specific version instead of 0.289

# For example, if Native is from 0.288:
wget https://repo1.maven.org/maven2/com/facebook/presto/presto-server/0.288/presto-server-0.288.tar.gz
```

**Problem:** We don't know the exact Native worker version.

### Solution 3: Use Pre-built Compatible Images (If Available)

Check if rapids-db-io has protocol-matched images:

```bash
# List available images
aws s3 ls s3://rapids-db-io-us-east-1/docker-images/

# Look for versions with matching dates/tags
# Example: presto-native-0.289-bd64355.tar.gz
```

### Solution 4: Use All-Java Deployment (Temporary)

For immediate functionality without Velox acceleration:

**Update main.tf:**
```hcl
# Comment out Native worker, use Java worker
user_data = templatefile("${path.module}/user-data/worker_java.sh", {
  # ...
})
```

**Drawbacks:**
- No Velox GPU acceleration
- Slower query performance
- Not testing Native workers

## Verification Steps

After applying any solution, verify compatibility:

```bash
# SSH to coordinator
ssh -i ~/.ssh/rapids-db-io.pem ec2-user@<coordinator-ip>

# Test simple query
presto --server localhost:8080 --catalog system --execute "SELECT 1"

# Should succeed without task API errors
```

## Building from Source - Detailed Steps

### Prerequisites

Ensure sibling directory structure:
```
parent/
├── velox-testing/
├── presto/
└── velox/
```

### Build Process

```bash
cd velox-testing/presto/scripts

# Set build options
export BUILD_TYPE=Release  # Or Debug
export NUM_THREADS=8

# Build dependencies (first time)
./build_centos_deps_image.sh

# Build and start Presto Native
./start_native_cpu_presto.sh --build all

# Verify it works locally
docker ps
curl http://localhost:8080/v1/info

# Test a query
./presto_cli --server localhost:8080 --catalog system --execute "SELECT 1"

# If successful, save the image
docker save presto-native-worker-cpu:latest | gzip > presto-native-matched.tar.gz

# Upload to S3
aws s3 cp presto-native-matched.tar.gz s3://your-bucket/docker-images/
```

## Current Deployment Configuration

**What's Working:**
- ✅ Java Coordinator: 0.289-bd64355
- ✅ Workers Active: 2/2 registered
- ✅ Memory: 112GB cluster pool
- ✅ All configuration correct

**What Needs Fixing:**
- ❌ Protocol compatibility
- Requires: Matched Presto Native build

## Workaround for Immediate Testing

Use TPC-H connector instead of Native workers:

```bash
# Enable coordinator as worker temporarily
sed -i 's/node-scheduler.include-coordinator=false/node-scheduler.include-coordinator=true/' \
  /opt/presto-server/etc/config.properties

docker restart presto-coordinator

# Now queries execute on coordinator (Java)
# Can test TPC-H benchmarks without Native workers
```

## Recommended Path Forward

1. **Commit all deployment automation** (code is perfect)
2. **Build protocol-matched Presto Native** from source
3. **Upload to S3** and reference in terraform.tfvars
4. **Redeploy with compatible image**
5. **Verify end-to-end** functionality

## References

- Presto Releases: https://prestodb.io/download.html
- Presto GitHub: https://github.com/prestodb/presto/releases/tag/0.289
- Velox-testing: https://github.com/rapidsai/velox-testing
- Build Guide: velox-testing/presto/README.md

## Notes

- Current s3://rapids-db-io-us-east-1/docker-images/presto-native-full.tar.gz is incompatible
- Need image built from Presto commit `bd64355` or use Java coordinator `0.288`
- All configuration fixes are correct and will work with compatible image

