# AWS Configuration
variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "Name of the Presto cluster"
  type        = string
  default     = "presto-velox-cluster"
}

variable "key_name" {
  description = "SSH key pair name"
  type        = string
}

variable "cluster_size" {
  description = <<-EOT
    Cluster size preset. Options:
    
    x86 (Intel r7i):
      test ($0.42/hr), small ($1.26/hr), medium ($9/hr), large ($17/hr), xlarge ($34/hr), xxlarge ($50/hr)
    
    ARM (Graviton r7gd with NVMe):
      graviton-small ($1.28/hr), graviton-medium ($4.69/hr), graviton-large ($9.38/hr), graviton-xlarge ($34.95/hr)
    
    Cost-Optimized (best $/benchmark):
      cost-optimized-small ($16/hr, ~$5/run), cost-optimized-medium ($17/hr, ~$6/run)
  EOT
  type        = string
  default     = "test"
  
  validation {
    condition = contains([
      "test", "small", "medium", "large", "xlarge", "xxlarge",
      "graviton-small", "graviton-medium", "graviton-large", "graviton-xlarge",
      "cost-optimized-small", "cost-optimized-medium"
    ], var.cluster_size)
    error_message = "Invalid cluster_size. See variable description for valid options."
  }
}

variable "benchmark_scale_factor" {
  description = "TPC-H benchmark scale factor to run: none (no auto-benchmark), 100, 1000, 3000"
  type        = string
  default     = "none"
  
  validation {
    condition     = contains(["none", "100", "1000", "3000"], var.benchmark_scale_factor)
    error_message = "benchmark_scale_factor must be: none, 100, 1000, or 3000"
  }
}

variable "s3_tpch_bucket" {
  description = "S3 bucket containing TPC-H data (required if benchmark_scale_factor is not 'none')"
  type        = string
  default     = ""
}

variable "s3_tpch_prefix" {
  description = "S3 prefix for TPC-H data (default: tpch)"
  type        = string
  default     = "tpch"
}

variable "coordinator_instance_type" {
  description = "EC2 instance type for coordinator (empty = use cluster_size default)"
  type        = string
  default     = ""
}

variable "worker_instance_type" {
  description = "EC2 instance type for workers (empty = use cluster_size default)"
  type        = string
  default     = ""
}

variable "worker_count" {
  description = "Number of worker nodes (0 = use cluster_size default)"
  type        = number
  default     = 0
}

variable "allowed_cidr_blocks" {
  description = "CIDR blocks allowed to access the cluster"
  type        = list(string)
  default     = ["0.0.0.0/0"] # Restrict this in production
}

variable "s3_data_location" {
  description = "S3 location for TPC-H data"
  type        = string
  default     = "s3://rapids-db-io-us-east-1/tpch/sf3000/"
}

variable "presto_docker_image" {
  description = "Docker image for Presto Native with Velox"
  type        = string
  default     = "prestodb/presto-native:latest"
}

# Temporary AWS credentials (will expire!)
variable "aws_access_key_id" {
  description = "AWS Access Key ID (optional - uses AWS CLI credentials if not set)"
  type        = string
  sensitive   = true
  default     = ""
}

variable "aws_secret_access_key" {
  description = "AWS Secret Access Key (optional - uses AWS CLI credentials if not set)"
  type        = string
  sensitive   = true
  default     = ""
}

variable "aws_session_token" {
  description = "AWS Session Token (optional - uses AWS CLI credentials if not set)"
  type        = string
  sensitive   = true
  default     = ""
}

variable "presto_native_image" {
  description = "Presto Native Docker image URI (for stable build workflow)"
  type        = string
  default     = "presto-native-cpu:latest"  # Override with ECR URI: 123456789012.dkr.ecr.us-east-1.amazonaws.com/presto-native-cpu:latest
}

variable "create_build_instance" {
  description = "Create a build instance for compiling Presto Native on Linux"
  type        = bool
  default     = false  # Set to true to create build instance
}

variable "enable_legacy_build_instance" {
  description = "Also launch the original build instance inside the cluster VPC (legacy fallback)"
  type        = bool
  default     = false
}

variable "build_arm64" {
  description = "Deploy ARM64 (Graviton) build instance to compile Presto Native for ARM"
  type        = bool
  default     = false
}

variable "presto_native_deployment" {
  description = "Presto Native deployment method: 'none' (Java only), 'build' (build from source), 'pull'/'prebuilt' (use pre-built image)"
  type        = string
  default     = "none"
  
  validation {
    condition     = contains(["none", "build", "pull", "prebuilt"], var.presto_native_deployment)
    error_message = "presto_native_deployment must be: none, build, pull, or prebuilt"
  }
}

variable "presto_native_image_source" {
  description = "Source for pre-built Presto Native image (S3 path or Docker registry)"
  type        = string
  default     = "s3://rapids-db-io-us-east-1/docker-images/presto-native-full.tar.gz"
}

variable "enable_status_reporting" {
  description = "Enable automated status reporting to local environment"
  type        = bool
  default     = true
}

variable "auto_run_benchmark" {
  description = "Automatically run benchmark after cluster is ready"
  type        = bool
  default     = false
}

# HMS Module Variables
variable "enable_hms" {
  description = "Enable Hive Metastore Service for external S3 table support"
  type        = bool
  default     = false
}

variable "hms_db_instance_class" {
  description = "RDS instance class for HMS database"
  type        = string
  default     = "db.t3.medium"
}

variable "hms_db_password" {
  description = "Password for HMS database (required if enable_hms=true)"
  type        = string
  sensitive   = true
  default     = ""
}

# Optional: Uncomment if using existing IAM instance profile
# variable "existing_iam_instance_profile_name" {
#   description = "Name of existing IAM instance profile with S3 access"
#   type        = string
#   default     = ""
# }
