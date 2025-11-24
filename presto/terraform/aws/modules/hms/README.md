# Hive Metastore Service (HMS) Module

## Purpose

This module deploys Hive Metastore Service (HMS) to enable external S3 table support in Presto.

## Why HMS is Needed

**Problem:** File-based metastore (`hive.metastore=file`) cannot create external tables pointing to S3:

```sql
-- This FAILS with file metastore:
CREATE EXTERNAL TABLE customer (...)
LOCATION 's3://bucket/path/';
-- Error: External location is not a valid file system URI
```

**Solution:** HMS with database backend supports external S3 tables:

```sql
-- This WORKS with HMS:
CREATE EXTERNAL TABLE customer (...)
STORED AS PARQUET
LOCATION 's3://rapids-db-io-us-east-1/tpch/sf3000/customer/';
```

## Architecture

```
┌─────────────────────────────────────────────┐
│ Presto Coordinator                           │
│   ├─ Hive Catalog (connector.name=hive)     │
│   └─ hive.metastore.uri=thrift://localhost:9083 │
└─────────────┬───────────────────────────────┘
              │
              ▼
┌─────────────────────────────────────────────┐
│ HMS Container (on Coordinator)               │
│   ├─ Thrift Server (port 9083)              │
│   └─ Connects to RDS MySQL                   │
└─────────────┬───────────────────────────────┘
              │
              ▼
┌─────────────────────────────────────────────┐
│ RDS MySQL (db.t3.medium)                    │
│   └─ Stores table metadata                   │
└─────────────────────────────────────────────┘
              ▲
              │
         Table metadata
              │
              ▼
┌─────────────────────────────────────────────┐
│ S3 Parquet Data                             │
│   s3://rapids-db-io-us-east-1/tpch/sf3000/  │
│   ├─ customer/                              │
│   ├─ lineitem/                              │
│   └─ ... (actual data files)                │
└─────────────────────────────────────────────┘
```

## Usage

### Enable HMS in terraform.tfvars

```hcl
# Enable HMS module
enable_hms = true

# HMS database password (required if enable_hms=true)
hms_db_password = "your-secure-password"

# Optional: Customize HMS database instance
hms_db_instance_class = "db.t3.medium"  # Default
```

### Deploy

```bash
terraform apply
```

This creates:
- RDS MySQL database for HMS metadata
- Security group allowing Presto → MySQL
- HMS configuration on coordinator

### Create External Tables

After deployment run:

```bash
# Registers hive.tpch_s3 tables that point directly to S3 parquet files
./populate_tpch_from_s3_equivalent.sh
```

The script detects HMS automatically (`terraform output hms_enabled`) and issues:

```sql
CREATE TABLE IF NOT EXISTS hive.tpch_s3.customer (...) 
WITH (external_location='s3://<bucket>/<prefix>/sf100/customer/', format='PARQUET');
```

You can then query the S3 data immediately:

```bash
presto --server localhost:8080 --catalog hive --schema tpch_s3 \
  --execute "SELECT count(*) FROM customer;"
```

## Alternative: AWS Glue Data Catalog

For a fully managed solution, use AWS Glue instead of HMS:

```hcl
# In terraform.tfvars
use_glue_catalog = true
```

Then update `hive.properties`:
```properties
connector.name=hive-hadoop2
hive.metastore=glue
```

**Advantages:**
- No RDS to manage
- No HMS container to run
- Fully managed by AWS
- Automatic schema discovery

**Disadvantages:**
- AWS Glue costs
- Requires IAM permissions
- Less control over metadata

## Files

```
modules/hms/
├── main.tf        # RDS MySQL + subnet/SG plumbing
├── variables.tf   # Inputs (password, enable flag, etc.)
├── outputs.tf     # Endpoint + thrift URI indicators
└── README.md      # This file
```

## What Gets Provisioned

- **Networking:** private subnets + subnet group dedicated to RDS
- **Database:** MySQL 8.0 on db.t3.medium (configurable)
- **Security:** SG that only allows ingress from the Presto cluster SG
- **Coordinator automation:** user-data renders `hive-site.xml`, initializes the schema, and runs `hive-metastore` with `--restart unless-stopped`
- **Workers:** automatically point `hive.metastore.uri` at the coordinator via private IP
- **Table registration:** `populate_tpch_from_s3_equivalent.sh` creates external tables when HMS is enabled

## Cost

**HMS Module adds:**
- RDS MySQL (db.t3.medium): ~$0.068/hour
- No additional compute (runs on coordinator)
- **Total: ~$0.07/hour** additional cost

For xxlarge cluster:
- Base: $50.40/hour
- With HMS: $50.47/hour (+0.1%)

## Support

See parent README for general deployment documentation.

For HMS-specific issues:
- Hive Metastore docs: https://cwiki.apache.org/confluence/display/Hive/AdminManual+Metastore+Administration
- Presto Hive connector: https://prestodb.io/docs/current/connector/hive.html

