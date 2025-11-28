# Presto Native on AWS

Deploy Presto clusters with Java coordinator and Native (Velox) workers on AWS.

## Architecture

- **Coordinator:** Java Presto (UI, query planning, discovery)
- **Workers:** Presto Native with Velox (C++ execution engine)
- **Metadata:** AWS Glue Data Catalog
- **Storage:** S3 parquet files (TPC-H datasets)

## Quick Start

### Prerequisites

1. AWS credentials (nvsec, IAM role, or AWS CLI)
2. SSH key pair (`rapids-db-io`)
3. Terraform 1.0+

### Deploy Cluster

```bash
cd velox-testing/presto/terraform/aws

# Unified deployment (recommended)
./deploy_cluster.sh --size medium --benchmark 100

# Or interactive mode
./deploy_cluster.sh
```

The script will:
- Refresh AWS credentials
- Deploy infrastructure with dynamic configs
- Register TPC-H tables in Glue
- Run ANALYZE TABLES for optimization
- Execute all 22 TPC-H queries
- Save results to CSV

### Build Fresh Images

```bash
# Build images from source and deploy
./deploy_cluster.sh --build --size large --benchmark 3000

# Build logs are streamed to your terminal
# Total build time: ~90 minutes
```

### Access Cluster

```bash
# Get coordinator IP
COORDINATOR_IP=$(terraform output -raw coordinator_public_ip)

# SSH to coordinator
ssh -i ~/.ssh/rapids-db-io.pem ec2-user@${COORDINATOR_IP}

# Run queries
presto --server localhost:8080 --catalog hive --schema tpch_sf100

# Web UI
open http://${COORDINATOR_IP}:8080
```

### Destroy Cluster

```bash
terraform destroy
```

## Cluster Sizes

### x86 (Intel r7i)

| Size | Workers | Instance | RAM/node | Cost/hr | Use Case |
|------|---------|----------|----------|---------|----------|
| test | 1 | r7i.xlarge | 32GB | ~$0.42 | Quick testing |
| small | 2 | r7i.2xlarge | 64GB | ~$1.26 | Development |
| medium | 4 | r7i.8xlarge | 256GB | ~$9 | Benchmarks (SF1000) |
| large | 4 | r7i.16xlarge | 512GB | ~$17 | Large benchmarks |
| xlarge | 8 | r7i.16xlarge | 512GB | ~$34 | High performance |
| xxlarge | 8 | r7i.24xlarge | 768GB | ~$50 | Maximum performance |

### ARM (Graviton r7gd with NVMe)

~15% cheaper than x86 with local SSD cache for better S3 performance.

| Size | Workers | Instance | RAM/node | NVMe | Cost/hr |
|------|---------|----------|----------|------|---------|
| graviton-small | 2 | r7gd.2xlarge | 64GB | 474GB | ~$1.28 |
| graviton-medium | 4 | r7gd.4xlarge | 128GB | 950GB | ~$4.69 |
| graviton-large | 4 | r7gd.8xlarge | 256GB | 1.9TB | ~$9.38 |
| graviton-xlarge | 8 | r7gd.16xlarge | 512GB | 3.8TB | ~$35 |

**Note:** Graviton requires ARM64-compiled images. Use `--build` to compile.

### Cost-Optimized

Best $/benchmark based on testing:

| Size | Workers | Instance | Cost/hr | $/benchmark |
|------|---------|----------|---------|-------------|
| cost-optimized-small | 32 | r7i.2xlarge | ~$16 | ~$5/run |
| cost-optimized-medium | 16 | r7i.4xlarge | ~$17 | ~$6/run |

## Dynamic Configuration

Worker and coordinator configs are automatically tuned based on instance size:

- **Memory:** 95% of RAM allocated to Velox (workers), 90% to JVM (coordinator)
- **Concurrency:** Scales with vCPU count and scale factor
- **AsyncDataCache:** Auto-detects NVMe and configures SSD caching
- **Buffer Memory:** Scales with scale factor (32GB for SF100, 100GB for SF3000)

## TPC-H Data

Pre-generated parquet data in S3:

| Scale | Size | lineitem rows | S3 Path |
|-------|------|---------------|---------|
| SF100 | 100GB | 600M | `s3://rapids-db-io-us-east-1/tpch/sf100/` |
| SF1000 | 1TB | 6B | `s3://rapids-db-io-us-east-1/tpch/sf1000/` |
| SF3000 | 3TB | 18B | `s3://rapids-db-io-us-east-1/tpch/sf3000/` |

## Configuration

Edit `terraform.tfvars`:

```hcl
cluster_size           = "medium"   # See cluster sizes above
benchmark_scale_factor = "100"      # 100, 1000, 3000

# Prebuilt images from S3
presto_native_deployment   = "pull"
presto_native_image_source = "s3://rapids-db-io-us-east-1/docker-images/presto-worker-matched-latest.tar.gz"
```

## Scripts Reference

| Script | Purpose |
|--------|---------|
| `deploy_cluster.sh` | **Main script** - build, deploy, benchmark |
| `deploy_presto.sh` | Interactive deployment (legacy) |
| `run_tpch_benchmark.sh` | Run TPC-H queries with CSV output |
| `populate_tpch_from_s3_equivalent.sh` | Register S3 tables in Glue |

## Troubleshooting

### Workers Not Active

```bash
# Check worker logs
ssh ec2-user@<worker-ip> 'sudo docker logs presto-worker'

# Verify discovery
ssh ec2-user@<coordinator-ip> 'curl http://localhost:8080/v1/cluster'
```

### S3 Access Denied

```bash
# Verify credentials
ssh ec2-user@<coordinator-ip> 'docker exec presto-coordinator env | grep AWS'

# Test S3
ssh ec2-user@<coordinator-ip> 'aws s3 ls s3://rapids-db-io-us-east-1/tpch/'
```

### Expired Credentials

```bash
# Refresh and redeploy
./deploy_cluster.sh  # Auto-refreshes credentials
```

## Files

```
aws/
├── deploy_cluster.sh             # Main deployment script
├── run_tpch_benchmark.sh         # Benchmark runner
├── populate_tpch_from_s3_equivalent.sh  # Table registration
├── lib/
│   └── instance_config.sh        # Dynamic config library
├── main.tf                       # Infrastructure
├── variables.tf                  # Input variables
├── cluster_sizes.tf              # Cluster presets
├── terraform.tfvars              # Configuration
└── user-data/
    ├── coordinator_java.sh       # Coordinator setup
    ├── worker_native.sh          # Worker setup (x86)
    ├── build_s3a_complete.sh     # Build script
    └── build_arm64.sh            # ARM64 build script
```

## Prebuilt Images

Available in S3:

```
s3://rapids-db-io-us-east-1/docker-images/
├── presto-coordinator-matched-latest.tar.gz  # Java coordinator
├── presto-worker-matched-latest.tar.gz       # Native worker (x86)
└── presto-worker-arm64-latest.tar.gz         # Native worker (ARM64)
```

## License

Apache License 2.0
