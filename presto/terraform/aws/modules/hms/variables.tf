# HMS Module Variables

variable "enable_hms" {
  description = "Enable Hive Metastore Service for external S3 table support"
  type        = bool
  default     = false
}

variable "cluster_name" {
  description = "Name of the Presto cluster"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID for HMS resources"
  type        = string
}

variable "subnet_ids" {
  description = "Subnet IDs for HMS database subnet group (min 2 AZs)"
  type        = list(string)
  default     = []
}

variable "presto_security_group_id" {
  description = "Security group ID of Presto cluster"
  type        = string
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

variable "aws_access_key_id" {
  description = "AWS Access Key ID for S3 access"
  type        = string
  sensitive   = true
}

variable "aws_secret_access_key" {
  description = "AWS Secret Access Key for S3 access"
  type        = string
  sensitive   = true
}

variable "aws_session_token" {
  description = "AWS Session Token for S3 access"
  type        = string
  sensitive   = true
  default     = ""
}

