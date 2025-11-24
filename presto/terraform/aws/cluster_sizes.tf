# Cluster Size Presets
# Choose based on your needs: test (debug/dev), small (demos), medium (benchmarks), large (production)

locals {
  # Cluster size configurations
  cluster_configs = {
    test = {
      coordinator_type = "t3.xlarge"      # 4 vCPU, 16GB RAM - $0.1664/hr
      worker_type      = "r7i.xlarge"     # 4 vCPU, 32GB RAM - $0.252/hr
      worker_count     = 1
      cost_per_hour    = "~$0.42"
      use_case         = "Testing & debugging setup"
    }
    small = {
      coordinator_type = "r7i.xlarge"     # 4 vCPU, 32GB RAM - $0.252/hr
      worker_type      = "r7i.2xlarge"    # 8 vCPU, 64GB RAM - $0.504/hr
      worker_count     = 2
      cost_per_hour    = "~$1.26"
      use_case         = "Small demos & development"
    }
    medium = {
      coordinator_type = "r7i.4xlarge"    # 16 vCPU, 128GB RAM - $1.008/hr
      worker_type      = "r7i.8xlarge"    # 32 vCPU, 256GB RAM - $2.016/hr
      worker_count     = 4
      cost_per_hour    = "~$9.07"
      use_case         = "Medium benchmarks (SF1000)"
    }
    large = {
      coordinator_type = "r7i.4xlarge"    # 16 vCPU, 128GB RAM - $1.008/hr
      worker_type      = "r7i.16xlarge"   # 64 vCPU, 512GB RAM - $4.032/hr
      worker_count     = 4
      cost_per_hour    = "~$17.14"
      use_case         = "Large benchmarks (SF3000+)"
    }
    xlarge = {
      coordinator_type = "r7i.8xlarge"    # 32 vCPU, 256GB RAM - $2.016/hr
      worker_type      = "r7i.16xlarge"   # 64 vCPU, 512GB RAM - $4.032/hr
      worker_count     = 8
      cost_per_hour    = "~$34.27"
      use_case         = "SF3000 in 1-1.5 hours (High Performance)"
    }
    xxlarge = {
      coordinator_type = "r7i.8xlarge"    # 32 vCPU, 256GB RAM - $2.016/hr
      worker_type      = "r7i.24xlarge"   # 96 vCPU, 768GB RAM - $6.048/hr
      worker_count     = 8
      cost_per_hour    = "~$50.40"
      use_case         = "SF3000 in <1 hour (Maximum Performance)"
    }
  }

  # Select configuration based on cluster_size
  selected_config = local.cluster_configs[var.cluster_size]

  # Use provided values or fall back to cluster_size defaults
  final_coordinator_type = var.coordinator_instance_type != "" ? var.coordinator_instance_type : local.selected_config.coordinator_type
  final_worker_type      = var.worker_instance_type != "" ? var.worker_instance_type : local.selected_config.worker_type
  final_worker_count     = var.worker_count != 0 ? var.worker_count : local.selected_config.worker_count
}

# Output cluster configuration for reference
output "cluster_configuration" {
  value = {
    size              = var.cluster_size
    coordinator_type  = local.final_coordinator_type
    worker_type       = local.final_worker_type
    worker_count      = local.final_worker_count
    estimated_cost    = local.selected_config.cost_per_hour
    use_case          = local.selected_config.use_case
  }
}

