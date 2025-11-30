# Presto Native on AWS

Deploy Presto clusters with Java coordinator and Native (Velox) workers on AWS.

## Architecture

- **Coordinator:** Java Presto (UI, query planning, discovery)
- **Workers:** Presto Native with Velox (C++ execution engine)
- **Metadata:** AWS Glue Data Catalog
- **Storage:** S3 parquet files (TPC-H datasets)
- **Caching:** AsyncDataCache on NVMe SSDs (r7gd instances)

## Quick Start

### Prerequisites

1. AWS credentials (nvsec, IAM role, or AWS CLI)
2. SSH key pair (`rapids-db-io`)
3. Terraform 1.0+

### Deploy Cluster

```bash
# Show all options
./deploy_cluster.sh --help

# Deploy medium cluster with SF100 benchmark
./deploy_cluster.sh --size medium --benchmark 100

# Deploy Graviton cluster with SF3000 (recommended for large benchmarks)
./deploy_cluster.sh --workers 32 --instance r7gd.2xlarge --benchmark 3000
```

## Usage Examples

### Basic Deployments

```bash
# Quick test cluster (1 worker, ~$0.42/hr)
./deploy_cluster.sh --size test --benchmark 100

# Medium cluster for benchmarks (4 workers, ~$9/hr)
./deploy_cluster.sh --size medium --benchmark 1000

# Large cluster for SF3000 (8 workers, ~$50/hr)
./deploy_cluster.sh --size xxlarge --benchmark 3000
```

### Custom Worker Count

```bash
# 16 workers using medium instance type
./deploy_cluster.sh --size medium --workers 16 --benchmark 3000

# 8 large workers
./deploy_cluster.sh --workers 8 --instance r7i.24xlarge --benchmark 3000

# 32 small workers (cost-optimized)
./deploy_cluster.sh --size cost-optimized-small --benchmark 3000
```

### Graviton (ARM) Clusters - Recommended for SF3000

Graviton instances are ~15% cheaper with local NVMe SSD for AsyncDataCache.

```bash
# Medium Graviton cluster
./deploy_cluster.sh --size graviton-medium --benchmark 1000

# Large Graviton with custom worker count
./deploy_cluster.sh --size graviton-large --workers 8 --benchmark 3000

# SF3000 validated configuration (32 x r7gd.2xlarge)
# All 22 TPC-H queries pass in ~23 minutes
./deploy_cluster.sh --workers 32 --instance r7gd.2xlarge --benchmark 3000
```

**Note:** Graviton requires ARM64 images. The deploy script auto-selects the correct image based on instance architecture.

### Run TPC-H Benchmark

```bash
# Run benchmark with auto credential refresh
./run_tpch_benchmark.sh 3000

# Run benchmark with custom output file
./run_tpch_benchmark.sh 3000 results/my_benchmark.csv

# Skip table analysis (faster, use cached stats)
./run_tpch_benchmark.sh 3000 results/run2.csv false
```

The benchmark script automatically:
- Refreshes AWS credentials via `nvsec awsos get-creds`
- Updates credentials on coordinator and all workers
- Runs all 22 TPC-H queries
- Outputs CSV with timing results

### Build Fresh Images

```bash
# Build images from source (~90 min) then deploy
./deploy_cluster.sh --build --size large --benchmark 3000

# Build with log streaming to terminal
./deploy_cluster.sh --build --size medium
```

### Skip Benchmark

```bash
# Deploy without running TPC-H queries
./deploy_cluster.sh --size medium --no-benchmark
```

### Direct Terraform

```bash
# Full control via terraform variables
terraform apply \
  -var="cluster_size=medium" \
  -var="worker_count=16" \
  -var="worker_instance_type=r7i.8xlarge" \
  -var="benchmark_scale_factor=3000"
```

## Command Reference

### deploy_cluster.sh

```
Usage: ./deploy_cluster.sh [OPTIONS]

Options:
  --size <size>         Cluster size preset (default: medium)
                        x86: test, small, medium, large, xlarge, xxlarge
                        ARM: graviton-small, graviton-medium, graviton-large, graviton-xlarge
                        Cost: cost-optimized-small, cost-optimized-medium
  
  --workers <n>         Override number of worker nodes
  --instance <type>     Override worker instance type (e.g., r7i.8xlarge)
  
  --benchmark <sf>      TPC-H scale factor: 100, 1000, 3000 (default: 100)
  --build               Build fresh images before deployment
  --no-benchmark        Skip automatic benchmark after deployment
  --no-stream           Don't stream build logs (just show progress)
  
  -h, --help            Show this help
```

### deploy_presto.sh (Interactive)

```
Usage: ./deploy_presto.sh [OPTIONS]

Options:
  --native-mode build       Deploy build instance to compile from source
  --native-mode prebuilt    Use prebuilt S3 images
  --prebuilt-image <URI>    S3 URI for prebuilt worker image
  -h, --help                Show this help
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

| Size | Workers | Instance | RAM/node | NVMe | Cost/hr |
|------|---------|----------|----------|------|---------|
| graviton-small | 2 | r7gd.2xlarge | 64GB | 474GB | ~$1.28 |
| graviton-medium | 4 | r7gd.4xlarge | 128GB | 950GB | ~$4.69 |
| graviton-large | 4 | r7gd.8xlarge | 256GB | 1.9TB | ~$9.38 |
| graviton-xlarge | 8 | r7gd.16xlarge | 512GB | 3.8TB | ~$35 |

### Cost-Optimized

| Size | Workers | Instance | Cost/hr | $/benchmark |
|------|---------|----------|---------|-------------|
| cost-optimized-small | 32 | r7i.2xlarge | ~$16 | ~$5/run |
| cost-optimized-medium | 16 | r7i.4xlarge | ~$17 | ~$6/run |

## TPC-H Data

Pre-generated parquet data in S3:

| Scale | Size | lineitem rows | S3 Path |
|-------|------|---------------|---------|
| SF100 | 100GB | 600M | `s3://rapids-db-io-us-east-1/tpch/sf100/` |
| SF1000 | 1TB | 6B | `s3://rapids-db-io-us-east-1/tpch/sf1000/` |
| SF3000 | 3TB | 18B | `s3://rapids-db-io-us-east-1/tpch/sf3000/` |

## SF3000 Validated Configuration

The following configuration has been tested and passes all 22 TPC-H queries:

| Setting | Value | Notes |
|---------|-------|-------|
| Instance Type | r7gd.2xlarge | Graviton3 + 474GB NVMe |
| Worker Count | 32 | ~2TB total RAM |
| Memory/Worker | 54GB | Reduced from 64GB for Q21 |
| Task Concurrency | 8 | Reduced from 16 for memory |
| Global Arbitration | enabled | Better memory management |
| AsyncDataCache | 352GB/node | Uses NVMe SSD |

### Apply SF3000 Config to Running Cluster

```bash
# Using the config script
./configs/apply_sf3000_config.sh <coordinator_ip> <worker_ips_file> <ssh_key>

# Or deploy with auto-tuning (SF3000 config applied automatically)
./deploy_cluster.sh --workers 32 --instance r7gd.2xlarge --benchmark 3000
```

### SF3000 Benchmark Results (r7gd.2xlarge × 32)

| Query | Runtime | Query | Runtime |
|-------|---------|-------|---------|
| Q1 | 46.0s | Q12 | 45.4s |
| Q2 | 20.0s | Q13 | 36.1s |
| Q3 | 56.4s | Q14 | 38.8s |
| Q4 | 42.8s | Q15 | 42.3s |
| Q5 | 86.2s | Q16 | 12.5s |
| Q6 | 25.5s | Q17 | 100.7s |
| Q7 | 73.3s | Q18 | 102.6s |
| Q8 | 70.5s | Q19 | 56.4s |
| Q9 | 100.2s | Q20 | 51.2s |
| Q10 | 52.2s | Q21 | 191.5s |
| Q11 | 16.4s | Q22 | 18.0s |

**Total: 1,365s (22.75 min) | All 22 queries passed ✓**

## Configuration

### terraform.tfvars

```hcl
# Cluster configuration
cluster_size           = "medium"
worker_count           = 8           # Override preset default
worker_instance_type   = "r7i.8xlarge"  # Override preset default

# Benchmark
benchmark_scale_factor = "3000"      # 100, 1000, 3000

# Image source
presto_native_deployment   = "pull"
presto_native_image_source = "s3://rapids-db-io-us-east-1/docker-images/presto-worker-matched-latest.tar.gz"
```

## Access Cluster

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

## Destroy Cluster

```bash
terraform destroy
```

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
├── deploy_cluster.sh             # Main deployment script (recommended)
├── deploy_presto.sh              # Interactive deployment
├── run_tpch_benchmark.sh         # Benchmark runner (auto-refreshes credentials)
├── populate_tpch_from_s3_equivalent.sh  # Table registration
├── configs/
│   ├── sf3000_r7gd_2xlarge_32nodes.json  # Validated SF3000 config
│   └── apply_sf3000_config.sh            # Apply config to running cluster
├── results/                      # Benchmark results (CSV files)
├── lib/
│   └── instance_config.sh        # Dynamic config library
├── main.tf                       # Infrastructure
├── variables.tf                  # Input variables
├── cluster_sizes.tf              # Cluster presets
├── terraform.tfvars              # Configuration (gitignored)
└── user-data/
    ├── coordinator_java.sh       # Coordinator setup
    ├── worker_native.sh          # Worker setup (auto-selects ARM64/x86)
    ├── build_s3a_complete.sh     # Build script (x86)
    └── build_arm64.sh            # Build script (ARM64)
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
