
## S3 Image Versioning

Build images are uploaded to S3 with timestamps for version tracking:

**Timestamped (unique builds):**
```
s3://rapids-db-io-us-east-1/docker-images/presto-coordinator-matched-YYYYMMDD-HHMMSS.tar.gz
s3://rapids-db-io-us-east-1/docker-images/presto-worker-matched-YYYYMMDD-HHMMSS.tar.gz
```

**Latest (always points to most recent):**
```
s3://rapids-db-io-us-east-1/docker-images/presto-coordinator-matched-latest.tar.gz
s3://rapids-db-io-us-east-1/docker-images/presto-worker-matched-latest.tar.gz
```

This allows:
- Version history tracking
- Rollback to specific builds
- Easy reference to latest build

To use latest build:
```bash
./deploy_presto.sh --native-mode prebuilt \
  --prebuilt-image s3://rapids-db-io-us-east-1/docker-images/presto-worker-matched-latest.tar.gz
```

To use specific build:
```bash
./deploy_presto.sh --native-mode prebuilt \
  --prebuilt-image s3://rapids-db-io-us-east-1/docker-images/presto-worker-matched-20251126-163000.tar.gz
```

## Java Version Requirements

Presto requires Java 17 for building (as of recent versions):

```bash
# Installed automatically in build instance
dnf install -y java-17-amazon-corretto java-17-amazon-corretto-devel
export JAVA_HOME=/usr/lib/jvm/java-17-amazon-corretto
```

## Critical: Exact Commit Matching

For protocol-matched images, BOTH coordinator and workers must be built from the SAME commit:

**Commit Used:**
- Presto: `92865fbce0` (Nov 12, 2024)
- Velox: `65797d572e` (Nov 17, 2024, IBM-techpreview branch)

The build script ensures:
1. Presto checked out to 92865fbce0 BEFORE any building
2. Java package built FROM that commit (not from HEAD)
3. Worker compiled FROM that commit
4. Coordinator image built FROM that Java package

This prevents internal function mismatches like:
- `$hashvalue` not found
- `$operator$hash_code` not registered

## Verification

After deployment, verify versions match:
```bash
# On coordinator
docker inspect presto-coordinator:latest | grep Created

# On worker  
docker inspect presto-native-cpu:latest | grep Created

# Should be within minutes of each other from same build session
```
