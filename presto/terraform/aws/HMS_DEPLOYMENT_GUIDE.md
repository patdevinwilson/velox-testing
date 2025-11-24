# Hive Metastore Service (HMS) Deployment Guide

## Purpose

This guide explains how to deploy HMS to enable **external S3 table support** in Presto for production use cases.

## Why HMS is Required

### Current Limitation

The default file-based metastore cannot create external tables:

```sql
-- FAILS with file metastore:
CREATE EXTERNAL TABLE customer (...)
LOCATION 's3://rapids-db-io-us-east-1/tpch/sf3000/customer/';

-- Error: External location is not a valid file system URI
```

### With HMS

External tables work correctly:

```sql
-- WORKS with HMS:
CREATE EXTERNAL TABLE customer (
    c_custkey BIGINT,
    c_name VARCHAR,
    ...
)
STORED AS PARQUET
LOCATION 's3://rapids-db-io-us-east-1/tpch/sf3000/customer/';

-- Query actual S3 parquet files
SELECT count(*) FROM customer;  -- 450M rows from S3
```

## Deployment Options

### Option 1: Built-in HMS Module (Terraform)

**Status:** ✅ Fully automated

**What happens when enabled:**
- Provisions RDS MySQL (db.t3.medium by default)
- Creates a dedicated DB subnet group + security group scoped to the Presto VPC
- Generates `/opt/hms/conf/hive-site.xml` with S3 + JDBC credentials
- Runs `schematool -dbType mysql -initSchema` automatically (idempotent)
- Starts a persistent `hive-metastore` Docker container on the coordinator (`-p 9083:9083`)
- Updates coordinator/worker `hive.properties` to `hive.metastore.uri=thrift://<coordinator>:9083`
- `populate_tpch_from_s3_equivalent.sh` registers external TPCH tables that point directly to the parquet files in S3

**Enable in `terraform.tfvars`:**

```hcl
# In terraform.tfvars
enable_hms = true
hms_db_password = "YourSecurePassword123!"
```

```bash
terraform apply
```

**Verify after deployment:**

```bash
# Metastore container & port
ssh ec2-user@<coord> 'sudo docker ps | grep hive-metastore'
nc -zv <coord-private-ip> 9083

# Presto catalog now points at HMS
ssh ec2-user@<coord> 'grep hive.metastore.uri /opt/presto/etc/catalog/hive.properties'

# Register S3-backed TPCH tables
./populate_tpch_from_s3_equivalent.sh
presto --server localhost:8080 --catalog hive --schema tpch_s3 --execute "SHOW TABLES;"
```

### Option 2: AWS Glue Data Catalog (Recommended)

**Easiest production solution** - fully managed by AWS:

**Update terraform.tfvars:**
```hcl
use_glue_catalog = true  # TODO: Add this variable
```

**Update coordinator hive.properties:**
```properties
connector.name=hive-hadoop2
hive.metastore=glue
hive.metastore.glue.region=us-east-1

# S3 Configuration (same as before)
hive.s3.endpoint=s3.us-east-1.amazonaws.com
...
```

**Advantages:**
- ✅ No RDS to manage
- ✅ No HMS container
- ✅ Automatic schema discovery
- ✅ Integrated with AWS ecosystem

**Disadvantages:**
- Additional AWS Glue costs
- Requires IAM permissions

### Option 3: Manual HMS Setup

Still possible, but no longer necessary now that the module automates every step. Use only if you need a bespoke metastore topology.

## Current Workaround

**For benchmarking now**, use TPC-H connector:

```sql
-- Equivalent to S3 SF3000 data
presto --catalog tpch --schema sf3000

SELECT count(*) FROM customer;   -- 450M rows
SELECT count(*) FROM lineitem;    -- 18B rows
```

**Functional equivalence:**
- Same data size
- Same schema
- Same row counts
- Tests Presto/Velox performance

**Missing:**
- Actual S3 I/O testing
- Production simulation with real parquet files

## Current Status

- ✅ HMS module provisions RDS + Dockerized metastore automatically
- ✅ Workers and coordinator pick up `hive.metastore.uri`
- ✅ `populate_tpch_from_s3_equivalent.sh` registers S3 parquet tables when HMS is enabled
- ☑️ Optional glue integration (future enhancement)

## Quick Reference

**Check if HMS is available:**
```bash
# On coordinator
netstat -tlnp | grep 9083

# Test HMS connection
nc -zv localhost 9083
```

**Create external tables (when HMS ready):**
```sql
CREATE EXTERNAL TABLE hive.tpch_s3.customer (...)
STORED AS PARQUET
LOCATION 's3://rapids-db-io-us-east-1/tpch/sf3000/customer/';
```

**Verify table points to S3:**
```sql
SHOW CREATE TABLE hive.tpch_s3.customer;
-- Should show: LOCATION 's3://...'
```

## Files

```
modules/hms/
├── main.tf         # RDS + security groups
├── variables.tf    # HMS inputs
├── outputs.tf      # HMS endpoints & flags
└── README.md       # Module documentation
```

## Next Steps

1. **For production S3 parquet access:** set `enable_hms=true` and re-run `terraform apply`
2. **Register datasets:** run `./populate_tpch_from_s3_equivalent.sh` (creates `hive.tpch_s3`)
3. **Benchmark:** point queries at `hive.tpch_s3` (external tables)

## Support

- HMS Module: `modules/hms/README.md`
- Main deployment: `README.md`
- AWS Glue: https://docs.aws.amazon.com/glue/

