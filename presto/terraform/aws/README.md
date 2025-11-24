# AWS Terraform Deployment for Presto

Deploy production-ready Presto clusters on AWS with Java coordinator and Native (Velox) workers.

## Architecture

- **Coordinator:** Java Presto (provides UI, query planning, discovery service)
- **Workers:** Presto Native with Velox (high-performance C++ execution engine)
- **Storage:** S3-backed Hive catalog for parquet data
- **Networking:** Custom VPC with cluster placement group for low latency

## Prerequisites

1. **AWS Credentials**
   - AWS CLI configured or nvsec for credential management
   - Required permissions: EC2, VPC, S3, IAM (for session tokens)

2. **SSH Key Pair**
   - Existing AWS EC2 key pair (e.g., `rapids-db-io`)
   - Private key file accessible (e.g., `~/.ssh/rapids-db-io.pem`)

3. **Terraform**
   - Version 1.0+ installed
   - AWS provider configured

4. **Docker Image**
   - Pre-built Presto Native image in S3
   - Or build locally: `cd ../../scripts && ./start_native_cpu_presto.sh`

## Quick Start

### 1. Automated Deployment (Recommended)

```bash
cd /path/to/velox-testing/presto/terraform/aws

# Run interactive deployment script
./deploy_presto.sh
```

This script will:
- ✅ Refresh AWS credentials (nvsec, IAM, or manual)
- ✅ Prompt for cluster size (test/small/medium/large)
- ✅ Prompt for TPC-H scale factor (1/10/100/1000)
- ✅ Deploy infrastructure via Terraform
- ✅ Monitor instance initialization
- ✅ Automatically populate TPC-H tables
- ✅ Report deployment status

**Command-line options (native image workflow):**

```bash
# Provision a build instance that compiles Presto Native
./deploy_presto.sh --native-mode build

# Use a pre-built image stored in S3/ECR
./deploy_presto.sh --native-mode prebuilt \
  --prebuilt-image s3://rapids-db-io-us-east-1/docker-images/presto-native-full.tar.gz
```

Flags set the following Terraform variables automatically:
- `--native-mode build` ⇒ `create_build_instance=true`, `presto_native_deployment="build"`
- `--native-mode prebuilt` ⇒ `create_build_instance=false`, `presto_native_deployment="pull"`, `presto_native_image_source=<URI>`

### 2. Manual Deployment

#### Step 1: Configure Credentials

**Option A: Using nvsec**
```bash
# Get fresh credentials
echo "0" | nvsec awsos get-creds --aws-profile default

# Credentials are automatically extracted
export AWS_ACCESS_KEY_ID=...
export AWS_SECRET_ACCESS_KEY=...
export AWS_SESSION_TOKEN=...
```

**Option B: Using AWS CLI**
```bash
export AWS_PROFILE=your-profile
```

**Option C: Manual credentials**
```bash
export AWS_ACCESS_KEY_ID=ASIA...
export AWS_SECRET_ACCESS_KEY=...
export AWS_SESSION_TOKEN=...
```

#### Step 2: Create Configuration

```bash
# Copy example configuration
cp examples/terraform.tfvars.example terraform.tfvars

# Edit configuration
vim terraform.tfvars
```

**Minimum required configuration:**

```hcl
# AWS Configuration
aws_region   = "us-east-1"
key_name     = "rapids-db-io"  # Your SSH key name (no .pem)
cluster_name = "my-presto-cluster"

# Cluster Size (test/small/medium/large)
cluster_size = "small"

# Docker Image Location
presto_native_image_source = "s3://your-bucket/docker-images/presto-native.tar.gz"

# TPC-H Benchmark Configuration (available: 100, 1000, 3000)
benchmark_scale_factor = "100"  # SF100 = 100GB dataset
s3_tpch_bucket         = "rapids-db-io-us-east-1"
s3_tpch_prefix         = "tpch"  # S3 path: s3://rapids-db-io-us-east-1/tpch/sf100/

# AWS Credentials (for S3 access)
aws_access_key_id     = "ASIA..."
aws_secret_access_key = "..."
aws_session_token     = "..."  # Optional but recommended

# Optional: Auto-run benchmark after deployment
auto_run_benchmark = false

# Optional: Build instance (for building images in AWS)
create_build_instance = false
```

#### Step 3: Initialize Terraform

```bash
terraform init
```

This downloads required providers and initializes the backend.

#### Step 4: Plan Deployment

```bash
terraform plan
```

Review the planned changes:
- VPC, subnet, internet gateway, route table
- Security group (SSH, Presto UI, inter-cluster traffic)
- Placement group for low latency
- EC2 instances (1 coordinator + N workers)

#### Step 5: Deploy

```bash
terraform apply
```

Type `yes` to confirm. Deployment takes 3-5 minutes.

#### Step 6: Verify Deployment

```bash
# Get coordinator IP
COORDINATOR_IP=$(terraform output -raw coordinator_public_ip)

# Check Presto UI
open "http://${COORDINATOR_IP}:8080"

# SSH to coordinator
ssh -i ~/.ssh/rapids-db-io.pem ec2-user@${COORDINATOR_IP}
```

## Cluster Sizes

Pre-configured cluster sizes optimized for different workloads:

| Size | Coordinator | Workers | Total vCPUs | Total RAM | Hourly Cost | Use Case |
|------|-------------|---------|-------------|-----------|-------------|----------|
| **test** | r7i.large | 1x r7i.large | 4 | 32GB | ~$0.31 | Quick testing |
| **small** | r7i.xlarge | 2x r7i.2xlarge | 20 | 192GB | ~$1.26 | Development & demos |
| **medium** | r7i.2xlarge | 4x r7i.4xlarge | 40 | 448GB | ~$2.90 | Small production |
| **large** | r7i.4xlarge | 8x r7i.8xlarge | 144 | 1.5TB | ~$8.50 | Large production |

Set in `terraform.tfvars`:
```hcl
cluster_size = "small"
```

Or customize manually:
```hcl
coordinator_instance_type = "r7i.xlarge"
worker_instance_type      = "r7i.2xlarge"
worker_count              = 2
```

**Instance Family:** Using r7i (memory-optimized) for better query performance.

## TPC-H Benchmarking

### Automatic Table Population

After successful deployment, TPC-H tables are automatically populated:

```bash
# Triggered automatically by deploy_presto.sh
# Or run manually:
./populate_tpch_from_s3_equivalent.sh
```

This creates Hive tables in S3-backed parquet format:
- **Schema:** `hive.tpch`
- **Tables:** customer, lineitem, nation, orders, part, partsupp, region, supplier
- **Storage:** S3 parquet files via Hive file metastore

**Scale Factor Configuration:**

```hcl
benchmark_scale_factor = "100"  # Options: 100, 1000, 3000
```

**Available S3 Data:** `s3://rapids-db-io-us-east-1/tpch/`

| Scale Factor | Data Size | customer rows | lineitem rows | Time to populate |
|-------------|-----------|---------------|---------------|------------------|
| SF100 | 100GB | 15M | 600M | ~15 min |
| SF1000 | 1TB | 150M | 6B | ~2 hours |
| SF3000 | 3TB | 450M | 18B | ~6 hours |

**Note:** For SF1000+, only dimension tables are populated in Hive. Use `tpch.sfXXX` catalog for fact tables (generated data).

### Running Benchmarks

```bash
# SSH to coordinator
ssh -i ~/.ssh/rapids-db-io.pem ec2-user@<coordinator-ip>

# Use Hive catalog with S3 data
presto --server localhost:8080 --catalog hive --schema tpch

# Run TPC-H queries
SELECT count(*) FROM customer;
SELECT count(*) FROM lineitem;

# TPC-H Query 6 (Forecasting Revenue Change)
SELECT sum(l_extendedprice * l_discount) as revenue
FROM lineitem
WHERE l_shipdate >= date '1994-01-01'
  AND l_shipdate < date '1995-01-01'
  AND l_discount between 0.05 and 0.07
  AND l_quantity < 24;
```

### Automated Benchmark Execution

```bash
# Run full TPC-H benchmark suite
./run_tpch_benchmark.sh
```

This runs common TPC-H queries and reports results.

## Monitoring

### Using Monitor Script

```bash
# Check cluster status
./monitor_cluster.sh status

# Watch initialization (auto-refreshes)
./monitor_cluster.sh watch

# Follow coordinator logs
./monitor_cluster.sh log coordinator

# Follow worker logs
./monitor_cluster.sh log worker 0
```

### Manual Monitoring

**Check Active Workers:**
```bash
curl http://<coordinator-ip>:8080/v1/node | jq '.[] | {nodeId, state, coordinator}'
```

**View Query Execution:**
```bash
# Web UI
open http://<coordinator-ip>:8080

# Check running queries
curl http://<coordinator-ip>:8080/v1/query | jq
```

**Instance Logs:**
```bash
# SSH to instance
ssh -i ~/.ssh/rapids-db-io.pem ec2-user@<instance-ip>

# Coordinator logs
sudo journalctl -u presto -f

# Worker logs (Docker)
sudo docker logs -f presto-worker

# Initialization logs
sudo tail -f /var/log/user-data.log
```

## S3 Parquet Data Access

### Current Implementation

The deployment uses **Hive file metastore** with S3-backed managed tables:

1. **TPC-H Connector** - Generates data on-the-fly
   - Use: `presto --catalog tpch --schema sf100`
   - Pros: No S3 costs, no credential expiration
   - Best for: Performance benchmarking

2. **Hive Managed Tables** - Writes to S3
   - Use: `presto --catalog hive --schema tpch`
   - Created by: `populate_tpch_from_s3_equivalent.sh`
   - Pros: Tests actual S3 I/O, persistent storage
   - Best for: I/O benchmarking, data reuse

### Workflow

```mermaid
AWS Credentials (nvsec) → Terraform → EC2 Instances
                                          ↓
                                  User-Data Scripts
                                          ↓
                         ┌────────────────┼────────────────┐
                         ↓                ↓                ↓
                   Coordinator        Workers      Hive Catalog
                   (Docker env)   (Docker+systemd)  (S3 config)
                         ↓                ↓                ↓
                   Presto Java    Presto Native    S3 Access
                         └────────────────┴────────────────┘
                                          ↓
                                TPC-H Benchmarking
```

**Credential Flow:**
1. Credentials generated via nvsec/IAM
2. Passed through `terraform.tfvars`
3. Injected into:
   - Coordinator Docker container (`presto-coordinator`)
   - Worker Docker containers (via systemd-managed services)
   - Hive catalog + HMS configuration
4. Used for S3 access throughout cluster lifecycle

### External Tables (S3 Parquet)

- Enable HMS: set `enable_hms = true` in `terraform.tfvars`
- Deploy: `terraform apply`
- Register TPCH S3 tables: `./populate_tpch_from_s3_equivalent.sh` (creates `hive.tpch_s3`)

See `HMS_DEPLOYMENT_GUIDE.md` for full details on:
- File metastore limitations
- HMS deployment steps
- External table verification

## Terraform Commands

### Deployment

```bash
# Initialize (first time only)
terraform init

# Validate configuration
terraform validate

# Format configuration files
terraform fmt

# Preview changes
terraform plan

# Apply changes
terraform apply

# Apply with auto-approve (careful!)
terraform apply -auto-approve

# Apply specific resource
terraform apply -target=aws_instance.coordinator
```

### Inspection

```bash
# List all resources
terraform state list

# Show resource details
terraform state show aws_instance.coordinator

# List outputs
terraform output

# Get specific output
terraform output coordinator_public_ip

# Get output in JSON
terraform output -json
```

### Updates

```bash
# Refresh state from AWS
terraform refresh

# Upgrade providers
terraform init -upgrade

# Replace specific instance (recreate)
terraform apply -replace=aws_instance.workers[0]

# Taint resource (mark for recreation)
terraform taint aws_instance.coordinator
terraform apply
```

### Cleanup

```bash
# Destroy all resources
terraform destroy

# Destroy specific resource
terraform destroy -target=aws_instance.workers[1]

# Destroy with auto-approve
terraform destroy -auto-approve
```

## Outputs

After successful deployment:

```bash
$ terraform output

build_instance_ip      = "N/A"
cluster_configuration  = {
  coordinator_type = "r7i.xlarge"
  estimated_cost   = "~$1.26/hour"
  size             = "small"
  use_case         = "Small demos & development"
  worker_count     = 2
  worker_type      = "r7i.2xlarge"
}
coordinator_private_ip = "10.0.1.193"
coordinator_public_ip  = "54.163.30.136"
presto_ui_url         = "http://54.163.30.136:8080"
ssh_coordinator       = "ssh -i ~/.ssh/rapids-db-io.pem ec2-user@54.163.30.136"
ssh_workers           = [
  "ssh -i ~/.ssh/rapids-db-io.pem ec2-user@98.81.158.156",
  "ssh -i ~/.ssh/rapids-db-io.pem ec2-user@44.222.210.228",
]
worker_private_ips    = ["10.0.1.161", "10.0.1.191"]
worker_public_ips     = ["98.81.158.156", "44.222.210.228"]
```

## Troubleshooting

### Workers Not Showing as Active

**Symptom:** Web UI shows "0 active workers"

**Check:**
```bash
# Verify workers are running
ssh ec2-user@<worker-ip> 'sudo docker ps'

# Check worker logs
ssh ec2-user@<worker-ip> 'sudo docker logs presto-worker'

# Verify coordinator can reach workers
ssh ec2-user@<coordinator-ip> 'curl -s http://<worker-private-ip>:8080/v1/info'
```

**Common fixes:**
- Wait 2-3 minutes for initialization
- Verify `query-manager.required-workers` is set in coordinator config
- Check catalog configurations match (both use `hive-hadoop2`)
- Restart Presto: `sudo docker restart presto-coordinator`

### Deployment Fails

**Error:** `VpcLimitExceeded`
```
Solution: Delete unused VPCs in AWS console or via AWS CLI
aws ec2 describe-vpcs --filters "Name=tag:Name,Values=*presto*"
aws ec2 delete-vpc --vpc-id vpc-xxxxx
```

**Error:** `ExpiredToken`
```
Solution: Refresh AWS credentials
echo "0" | nvsec awsos get-creds --aws-profile default
# Update terraform.tfvars with new credentials
terraform apply
```

**Error:** `KeyPairNotFound`
```
Solution: Verify SSH key exists in AWS
aws ec2 describe-key-pairs --key-names rapids-db-io
# Or create new key pair in AWS console
```

### TPC-H Tables Not Created

**Check table population:**
```bash
ssh ec2-user@<coordinator-ip>

# Verify tables exist
presto --server localhost:8080 --catalog hive --schema tpch --execute "SHOW TABLES;"

# Check if empty
presto --server localhost:8080 --catalog hive --schema tpch --execute "SELECT count(*) FROM customer;"
```

**Re-populate tables:**
```bash
# From local machine
./populate_tpch_from_s3_equivalent.sh
```

### S3 Access Denied

**Symptom:** Queries fail with "Access Denied" or "Forbidden"

**Check credentials:**
```bash
ssh ec2-user@<coordinator-ip>

# Verify Hive catalog has credentials
grep "hive.s3.aws" /opt/presto/etc/catalog/hive.properties

# Test S3 access
aws s3 ls s3://rapids-db-io-us-east-1/tpch/
```

**Refresh credentials:**
1. Get new credentials via nvsec
2. Update `terraform.tfvars`
3. Run `terraform apply` to update instances
4. Or manually update on coordinator and restart

### High Costs

**Monitor spending:**
```bash
# Check running instances
aws ec2 describe-instances --filters "Name=tag:Name,Values=*presto*" \
  --query 'Reservations[].Instances[].[InstanceId,InstanceType,State.Name]' \
  --output table

# Estimate hourly cost from terraform output
terraform output cluster_configuration
```

**Reduce costs:**
- Use `cluster_size = "test"` for development
- `terraform destroy` when not in use
- Consider spot instances for non-critical workloads
- Use smaller scale factors (SF1, SF10)

## Advanced Configuration

### Custom Presto Settings

Edit user-data scripts before deployment:

**Coordinator:** `user-data/coordinator_java.sh`
```bash
# Modify config.properties
query.max-memory=100GB
query.max-memory-per-node=10GB
query-manager.required-workers=2
```

**Workers:** `user-data/worker_native.sh`
```bash
# Modify config.properties  
task.concurrency=16
task.max-worker-threads=32
```

### Build Instance

Build Docker images directly in AWS:

```hcl
create_build_instance = true
build_instance_type   = "c7a.4xlarge"
```

Access build instance:
```bash
BUILD_IP=$(terraform output -raw build_instance_ip)
ssh -i ~/.ssh/rapids-db-io.pem ec2-user@${BUILD_IP}

# Build image
cd /home/ec2-user/velox-testing/presto/scripts
./start_native_cpu_presto.sh

# Upload to S3
docker save presto-native-cpu:latest | gzip > /tmp/presto-native.tar.gz
aws s3 cp /tmp/presto-native.tar.gz s3://bucket/docker-images/
```

### Multiple Environments

Deploy separate clusters for dev/staging/prod:

```bash
# Development
terraform workspace new dev
vim terraform.tfvars  # cluster_size = "test"
terraform apply

# Production  
terraform workspace new prod
vim terraform.tfvars  # cluster_size = "large"
terraform apply

# Switch between environments
terraform workspace select dev
terraform workspace select prod
```

### Custom VPC Configuration

Override default VPC settings in `main.tf`:
```hcl
resource "aws_vpc" "presto_vpc" {
  cidr_block           = "10.1.0.0/16"  # Custom CIDR
  enable_dns_hostnames = true
  enable_dns_support   = true
  
  tags = {
    Name = "${var.cluster_name}-vpc"
    Environment = "production"
  }
}
```

## Security Best Practices

### Network Security

1. **Restrict SSH access**
   ```hcl
   # In security.tf, change from 0.0.0.0/0 to:
   ingress {
     from_port   = 22
     to_port     = 22
     protocol    = "tcp"
     cidr_blocks = ["YOUR_IP/32"]  # Your IP only
   }
   ```

2. **Use VPN or Bastion Host**
   - Deploy bastion host in public subnet
   - Move Presto cluster to private subnet
   - Access only through bastion

3. **Enable VPC Flow Logs**
   ```hcl
   resource "aws_flow_log" "presto_vpc_flow_log" {
     vpc_id          = aws_vpc.presto_vpc.id
     traffic_type    = "ALL"
     iam_role_arn    = aws_iam_role.flow_log_role.arn
     log_destination = aws_cloudwatch_log_group.flow_log.arn
   }
   ```

### Credential Management

1. **Use IAM Roles (Production)**
   ```hcl
   resource "aws_iam_instance_profile" "presto_profile" {
     name = "${var.cluster_name}-profile"
     role = aws_iam_role.presto_role.name
   }
   
   # Attach to instances
   iam_instance_profile = aws_iam_instance_profile.presto_profile.name
   ```

2. **Rotate Credentials**
   - Session tokens expire in ~1 hour
   - Use automation to refresh: `deploy_presto.sh` handles this
   - Or use IAM roles to avoid credential management

3. **Never Commit Credentials**
   ```bash
   # .gitignore includes:
   terraform.tfvars
   *.tfvars.bak
   ```

### Encryption

1. **EBS Encryption** (already enabled)
   - All volumes encrypted at rest
   - KMS managed keys

2. **S3 Encryption**
   ```hcl
   # Add to Hive catalog
   hive.s3.sse.enabled=true
   hive.s3.sse.type=S3
   ```

3. **Network Encryption**
   - Add TLS/SSL to Presto (requires certificates)
   - Use VPN for all cluster access

## Files Reference

```
aws/
├── README.md                              # This file
├── .gitignore                            # Ignore sensitive files
│
├── Terraform Configuration
├── main.tf                               # Main infrastructure
├── variables.tf                          # Input variables
├── outputs.tf                            # Output values  
├── security.tf                           # Security groups
├── cluster_sizes.tf                      # Cluster presets
├── build_instance.tf                     # Optional build instance
│
├── Scripts
├── deploy_presto.sh                      # Automated deployment
├── monitor_cluster.sh                    # Cluster monitoring
├── populate_tpch_from_s3_equivalent.sh   # TPC-H table population
├── run_tpch_benchmark.sh                 # Benchmark execution
├── enable_tpch_connector.sh              # Enable built-in TPC-H
│
├── Documentation
├── S3_PARQUET_WORKFLOW.md                # S3 data access guide
├── TPCH_S3_SOLUTION.md                   # TPC-H solutions
│
├── User-Data Scripts (Instance Initialization)
├── user-data/
│   ├── coordinator_java.sh               # Coordinator setup
│   ├── worker_native.sh                  # Native worker setup
│   └── worker_java.sh                    # Java worker setup
│
└── Examples
    └── examples/
        └── terraform.tfvars.example      # Example configuration
```

## Integration with Velox-Testing

This deployment is part of the velox-testing project workflow:

```bash
# 1. Develop and test locally
cd /path/to/velox-testing/presto/scripts
./start_native_cpu_presto.sh
docker-compose up
# Test queries, iterate on code

# 2. Build production image
docker save presto-native-cpu:latest | gzip > /tmp/presto-native.tar.gz

# 3. Upload to S3
aws s3 cp /tmp/presto-native.tar.gz s3://bucket/docker-images/

# 4. Deploy to AWS with same image
cd ../terraform/aws
./deploy_presto.sh
# Same image, now in production!
```

**Benefits:**
- Identical binaries in dev and prod
- Test locally before AWS spend
- Consistent benchmarking environment
- Rapid iteration cycle

## Support

- **Issues:** https://github.com/facebookincubator/velox-testing/issues
- **Presto Docs:** https://prestodb.io/docs/current/
- **Terraform AWS Provider:** https://registry.terraform.io/providers/hashicorp/aws/
- **Velox Project:** https://github.com/facebookincubator/velox

## License

Apache License 2.0 - Same as velox-testing parent project
