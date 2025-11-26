terraform {
  required_version = ">= 1.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# Note: IAM role creation disabled due to insufficient permissions
# Using AWS credentials passed via user-data instead

# Data source for latest Amazon Linux 2023 AMI
data "aws_ami" "amazon_linux_2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# VPC and Networking
resource "aws_vpc" "presto_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "${var.cluster_name}-vpc"
  }
}

resource "aws_subnet" "presto_subnet" {
  vpc_id                  = aws_vpc.presto_vpc.id
  cidr_block              = "10.0.1.0/24"
  map_public_ip_on_launch = true
  availability_zone       = data.aws_availability_zones.available.names[0]

  tags = {
    Name = "${var.cluster_name}-subnet"
  }
}

# Private subnets reserved for HMS (only created when HMS is enabled)
resource "aws_subnet" "hms_private" {
  count = var.enable_hms ? 2 : 0

  vpc_id                  = aws_vpc.presto_vpc.id
  cidr_block              = "10.0.${10 + count.index}.0/24"
  map_public_ip_on_launch = false
  availability_zone       = data.aws_availability_zones.available.names[count.index]

  tags = {
    Name = "${var.cluster_name}-hms-${count.index}"
  }
}

data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_internet_gateway" "presto_igw" {
  vpc_id = aws_vpc.presto_vpc.id

  tags = {
    Name = "${var.cluster_name}-igw"
  }
}

resource "aws_route_table" "presto_rt" {
  vpc_id = aws_vpc.presto_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.presto_igw.id
  }

  tags = {
    Name = "${var.cluster_name}-rt"
  }
}

resource "aws_route_table_association" "presto_rta" {
  subnet_id      = aws_subnet.presto_subnet.id
  route_table_id = aws_route_table.presto_rt.id
}

# Ensure HMS subnets share the same routing (if created)
resource "aws_route_table_association" "presto_rta_hms" {
  count = var.enable_hms ? length(aws_subnet.hms_private) : 0

  subnet_id      = aws_subnet.hms_private[count.index].id
  route_table_id = aws_route_table.presto_rt.id
}

# Hive Metastore module (creates RDS + supporting resources)
module "hms" {
  source = "./modules/hms"

  enable_hms              = var.enable_hms
  cluster_name            = var.cluster_name
  vpc_id                  = aws_vpc.presto_vpc.id
  subnet_ids              = var.enable_hms ? [for subnet in aws_subnet.hms_private : subnet.id] : []
  presto_security_group_id = aws_security_group.presto_sg.id
  hms_db_instance_class   = var.hms_db_instance_class
  hms_db_password         = var.hms_db_password
  aws_access_key_id       = var.aws_access_key_id
  aws_secret_access_key   = var.aws_secret_access_key
  aws_session_token       = var.aws_session_token
}

# Coordinator Instance
resource "aws_instance" "coordinator" {
  ami                    = data.aws_ami.amazon_linux_2023.id
  instance_type          = local.final_coordinator_type
  key_name               = var.key_name
  subnet_id              = aws_subnet.presto_subnet.id
  vpc_security_group_ids = [aws_security_group.presto_sg.id]

  root_block_device {
    volume_size = 200
    volume_type = "gp3"
  }

  # Java Coordinator + Native Workers (matches velox-testing exactly)
  # This is the proven architecture from velox-testing
  user_data = templatefile("${path.module}/user-data/coordinator_java.sh", {
    cluster_name            = var.cluster_name
    aws_access_key_id       = var.aws_access_key_id
    aws_secret_access_key   = var.aws_secret_access_key
    aws_session_token       = var.aws_session_token
    benchmark_scale_factor  = var.benchmark_scale_factor
    s3_tpch_bucket          = var.s3_tpch_bucket
    s3_tpch_prefix          = var.s3_tpch_prefix
    worker_count            = local.final_worker_count
    worker_instance_type    = local.final_worker_type
    enable_hms              = var.enable_hms
    hms_db_endpoint         = var.enable_hms ? module.hms.hms_db_endpoint : ""
    hms_db_name             = var.enable_hms ? "metastore" : ""
    hms_db_user             = var.enable_hms ? "hive" : ""
    hms_db_password         = var.enable_hms ? var.hms_db_password : ""
    hive_warehouse_dir      = var.enable_hms ? format(
      "s3://%s/%s/hive-warehouse/",
      var.s3_tpch_bucket != "" ? var.s3_tpch_bucket : "rapids-db-io-us-east-1",
      var.s3_tpch_prefix != "" ? var.s3_tpch_prefix : "tpch"
    ) : ""
  })

  tags = {
    Name = "${var.cluster_name}-coordinator"
    Role = "coordinator"
  }
}

# Worker Instances
resource "aws_instance" "workers" {
  count                  = local.final_worker_count
  ami                    = data.aws_ami.amazon_linux_2023.id
  instance_type          = local.final_worker_type
  key_name               = var.key_name
  subnet_id              = aws_subnet.presto_subnet.id
  vpc_security_group_ids = [aws_security_group.presto_sg.id]

  root_block_device {
    volume_size = 500
    volume_type = "gp3"
    iops        = 16000
    throughput  = 1000
  }

  # OPTION 1: Presto Java Workers (Stable, Compatible)
  # user_data = templatefile("${path.module}/user-data/worker_java.sh", {
  #   cluster_name          = var.cluster_name
  #   coordinator_ip        = aws_instance.coordinator.private_ip
  #   worker_id             = count.index
  #   aws_access_key_id     = var.aws_access_key_id
  #   aws_secret_access_key = var.aws_secret_access_key
  #   aws_session_token     = var.aws_session_token
  # })

  # OPTION 2: Presto Native Workers (High Performance, Stable Build)
  user_data = templatefile("${path.module}/user-data/worker_native.sh", {
    cluster_name           = var.cluster_name
    coordinator_ip         = aws_instance.coordinator.private_ip
    worker_id              = count.index
    aws_access_key_id      = var.aws_access_key_id
    aws_secret_access_key  = var.aws_secret_access_key
    aws_session_token      = var.aws_session_token
    presto_native_image    = var.presto_native_image_source
    benchmark_scale_factor = var.benchmark_scale_factor
    enable_hms             = var.enable_hms
    hive_metastore_uri     = var.enable_hms ? format("thrift://%s:9083", aws_instance.coordinator.private_ip) : ""
  })

  tags = {
    Name = "${var.cluster_name}-worker-${count.index}"
    Role = "worker"
  }

  depends_on = [aws_instance.coordinator]
}

# Placement group for low latency (optional)
resource "aws_placement_group" "presto_pg" {
  name     = "${var.cluster_name}-pg"
  strategy = "cluster"
}

