# Cluster Size Presets
# Choose based on your needs: test (debug/dev), small (demos), medium (benchmarks), large (production)
# 
# x86 (Intel r7i) - Proven, compatible with existing images
# ARM (Graviton r7gd) - Cost-effective with local NVMe for AsyncDataCache
#
# Note: ARM (Graviton) requires ARM64-compiled Presto Native images

locals {
  # Cluster size configurations
  cluster_configs = {
    # ============================================
    # x86 (Intel) Configurations - r7i series
    # ============================================
    test = {
      coordinator_type = "t3.xlarge"      # 4 vCPU, 16GB RAM - $0.1664/hr
      worker_type      = "r7i.xlarge"     # 4 vCPU, 32GB RAM - $0.252/hr
      worker_count     = 1
      cost_per_hour    = "~$0.42"
      use_case         = "Testing & debugging setup"
      arch             = "x86_64"
    }
    small = {
      coordinator_type = "r7i.xlarge"     # 4 vCPU, 32GB RAM - $0.252/hr
      worker_type      = "r7i.2xlarge"    # 8 vCPU, 64GB RAM - $0.504/hr
      worker_count     = 2
      cost_per_hour    = "~$1.26"
      use_case         = "Small demos & development"
      arch             = "x86_64"
    }
    medium = {
      coordinator_type = "r7i.4xlarge"    # 16 vCPU, 128GB RAM - $1.008/hr
      worker_type      = "r7i.8xlarge"    # 32 vCPU, 256GB RAM - $2.016/hr
      worker_count     = 4
      cost_per_hour    = "~$9.07"
      use_case         = "Medium benchmarks (SF1000)"
      arch             = "x86_64"
    }
    large = {
      coordinator_type = "r7i.4xlarge"    # 16 vCPU, 128GB RAM - $1.008/hr
      worker_type      = "r7i.16xlarge"   # 64 vCPU, 512GB RAM - $4.032/hr
      worker_count     = 4
      cost_per_hour    = "~$17.14"
      use_case         = "Large benchmarks (SF3000+)"
      arch             = "x86_64"
    }
    xlarge = {
      coordinator_type = "r7i.8xlarge"    # 32 vCPU, 256GB RAM - $2.016/hr
      worker_type      = "r7i.16xlarge"   # 64 vCPU, 512GB RAM - $4.032/hr
      worker_count     = 8
      cost_per_hour    = "~$34.27"
      use_case         = "SF3000 in 1-1.5 hours (High Performance)"
      arch             = "x86_64"
    }
    xxlarge = {
      coordinator_type = "r7i.8xlarge"    # 32 vCPU, 256GB RAM - $2.016/hr
      worker_type      = "r7i.24xlarge"   # 96 vCPU, 768GB RAM - $6.048/hr
      worker_count     = 8
      cost_per_hour    = "~$50.40"
      use_case         = "SF3000 in <1 hour (Maximum Performance)"
      arch             = "x86_64"
    }

    # ============================================
    # ARM (Graviton) Configurations - r7gd series
    # Local NVMe SSD for AsyncDataCache
    # ~15% cheaper than x86 equivalent
    # ============================================
    graviton-small = {
      coordinator_type = "r7g.xlarge"     # 4 vCPU, 32GB RAM - $0.214/hr
      worker_type      = "r7gd.2xlarge"   # 8 vCPU, 64GB RAM, 1x474GB NVMe - $0.533/hr
      worker_count     = 2
      cost_per_hour    = "~$1.28"
      use_case         = "ARM: Small demos with NVMe cache"
      arch             = "arm64"
    }
    graviton-medium = {
      coordinator_type = "r7g.2xlarge"    # 8 vCPU, 64GB RAM - $0.428/hr
      worker_type      = "r7gd.4xlarge"   # 16 vCPU, 128GB RAM, 1x950GB NVMe - $1.066/hr
      worker_count     = 4
      cost_per_hour    = "~$4.69"
      use_case         = "ARM: Medium benchmarks with NVMe cache"
      arch             = "arm64"
    }
    graviton-large = {
      coordinator_type = "r7g.4xlarge"    # 16 vCPU, 128GB RAM - $0.857/hr
      worker_type      = "r7gd.8xlarge"   # 32 vCPU, 256GB RAM, 1x1900GB NVMe - $2.131/hr
      worker_count     = 4
      cost_per_hour    = "~$9.38"
      use_case         = "ARM: Large benchmarks (SF3000) with NVMe cache"
      arch             = "arm64"
    }
    graviton-xlarge = {
      coordinator_type = "r7g.4xlarge"    # 16 vCPU, 128GB RAM - $0.857/hr
      worker_type      = "r7gd.16xlarge"  # 64 vCPU, 512GB RAM, 2x1900GB NVMe - $4.262/hr
      worker_count     = 8
      cost_per_hour    = "~$34.95"
      use_case         = "ARM: High performance SF3000 with NVMe cache"
      arch             = "arm64"
    }

    # ============================================
    # Cost-Optimized Configurations
    # Best $/query based on benchmarks
    # ============================================
    cost-optimized-small = {
      coordinator_type = "r7i.xlarge"     # 4 vCPU, 32GB RAM - $0.252/hr
      worker_type      = "r7i.2xlarge"    # 8 vCPU, 64GB RAM - $0.504/hr
      worker_count     = 32
      cost_per_hour    = "~$16.38"
      use_case         = "Best $/run: 32x small nodes (~$5/benchmark)"
      arch             = "x86_64"
    }
    cost-optimized-medium = {
      coordinator_type = "r7i.2xlarge"    # 8 vCPU, 64GB RAM - $0.504/hr
      worker_type      = "r7i.4xlarge"    # 16 vCPU, 128GB RAM - $1.008/hr
      worker_count     = 16
      cost_per_hour    = "~$16.63"
      use_case         = "Balanced: 16x medium nodes (~$6/benchmark)"
      arch             = "x86_64"
    }
  }

  # Select configuration based on cluster_size
  selected_config = local.cluster_configs[var.cluster_size]

  # Use provided values or fall back to cluster_size defaults
  final_coordinator_type = var.coordinator_instance_type != "" ? var.coordinator_instance_type : local.selected_config.coordinator_type
  final_worker_type      = var.worker_instance_type != "" ? var.worker_instance_type : local.selected_config.worker_type
  final_worker_count     = var.worker_count != 0 ? var.worker_count : local.selected_config.worker_count
  
  # Architecture detection for AMI selection
  cluster_arch = local.selected_config.arch
  is_arm64     = local.cluster_arch == "arm64"
}

# Output cluster configuration for reference
output "cluster_configuration" {
  value = {
    size              = var.cluster_size
    architecture      = local.cluster_arch
    coordinator_type  = local.final_coordinator_type
    worker_type       = local.final_worker_type
    worker_count      = local.final_worker_count
    estimated_cost    = local.selected_config.cost_per_hour
    use_case          = local.selected_config.use_case
  }
}

