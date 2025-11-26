
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
