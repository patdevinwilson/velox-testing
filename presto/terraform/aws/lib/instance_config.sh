#!/bin/bash
# Dynamic instance configuration library
# Calculates optimal Presto settings based on instance type

# Get memory and CPU configuration for a given instance type
# Usage: get_instance_specs <instance_type>
# Returns: JSON object with specs
get_instance_specs() {
    local instance_type="$1"
    
    case "$instance_type" in
        # t3 series (burstable)
        t3.xlarge)    echo '{"vcpu":4,"ram_gb":16,"nvme_gb":0,"arch":"x86_64","cost_hr":0.1664}' ;;
        t3.2xlarge)   echo '{"vcpu":8,"ram_gb":32,"nvme_gb":0,"arch":"x86_64","cost_hr":0.3328}' ;;
        
        # r7i series (Intel, memory optimized)
        r7i.xlarge)   echo '{"vcpu":4,"ram_gb":32,"nvme_gb":0,"arch":"x86_64","cost_hr":0.252}' ;;
        r7i.2xlarge)  echo '{"vcpu":8,"ram_gb":64,"nvme_gb":0,"arch":"x86_64","cost_hr":0.504}' ;;
        r7i.4xlarge)  echo '{"vcpu":16,"ram_gb":128,"nvme_gb":0,"arch":"x86_64","cost_hr":1.008}' ;;
        r7i.8xlarge)  echo '{"vcpu":32,"ram_gb":256,"nvme_gb":0,"arch":"x86_64","cost_hr":2.016}' ;;
        r7i.12xlarge) echo '{"vcpu":48,"ram_gb":384,"nvme_gb":0,"arch":"x86_64","cost_hr":3.024}' ;;
        r7i.16xlarge) echo '{"vcpu":64,"ram_gb":512,"nvme_gb":0,"arch":"x86_64","cost_hr":4.032}' ;;
        r7i.24xlarge) echo '{"vcpu":96,"ram_gb":768,"nvme_gb":0,"arch":"x86_64","cost_hr":6.048}' ;;
        r7i.48xlarge) echo '{"vcpu":192,"ram_gb":1536,"nvme_gb":0,"arch":"x86_64","cost_hr":12.096}' ;;
        
        # r7g series (Graviton, memory optimized)
        r7g.xlarge)   echo '{"vcpu":4,"ram_gb":32,"nvme_gb":0,"arch":"arm64","cost_hr":0.214}' ;;
        r7g.2xlarge)  echo '{"vcpu":8,"ram_gb":64,"nvme_gb":0,"arch":"arm64","cost_hr":0.428}' ;;
        r7g.4xlarge)  echo '{"vcpu":16,"ram_gb":128,"nvme_gb":0,"arch":"arm64","cost_hr":0.857}' ;;
        r7g.8xlarge)  echo '{"vcpu":32,"ram_gb":256,"nvme_gb":0,"arch":"arm64","cost_hr":1.714}' ;;
        r7g.16xlarge) echo '{"vcpu":64,"ram_gb":512,"nvme_gb":0,"arch":"arm64","cost_hr":3.427}' ;;
        
        # r7gd series (Graviton with NVMe)
        r7gd.xlarge)   echo '{"vcpu":4,"ram_gb":32,"nvme_gb":237,"arch":"arm64","cost_hr":0.267}' ;;
        r7gd.2xlarge)  echo '{"vcpu":8,"ram_gb":64,"nvme_gb":474,"arch":"arm64","cost_hr":0.533}' ;;
        r7gd.4xlarge)  echo '{"vcpu":16,"ram_gb":128,"nvme_gb":950,"arch":"arm64","cost_hr":1.066}' ;;
        r7gd.8xlarge)  echo '{"vcpu":32,"ram_gb":256,"nvme_gb":1900,"arch":"arm64","cost_hr":2.131}' ;;
        r7gd.16xlarge) echo '{"vcpu":64,"ram_gb":512,"nvme_gb":3800,"arch":"arm64","cost_hr":4.262}' ;;
        
        # Default fallback
        *) echo '{"vcpu":4,"ram_gb":32,"nvme_gb":0,"arch":"x86_64","cost_hr":0.50}' ;;
    esac
}

# Calculate optimal Presto Native worker configuration
# Usage: calculate_worker_config <ram_gb> <vcpu> <scale_factor> <nvme_gb>
calculate_worker_config() {
    local ram_gb="$1"
    local vcpu="$2"
    local scale_factor="${3:-100}"
    local nvme_gb="${4:-0}"
    
    # System reserved: 5% of RAM, cap at 2GB
    local system_reserved=$((ram_gb * 5 / 100))
    if [ "$system_reserved" -gt 2 ]; then system_reserved=2; fi
    
    # Native workers can use 95% of remaining memory
    local usable_ram=$((ram_gb - system_reserved))
    local worker_memory=$((usable_ram * 95 / 100))
    
    # Buffer memory (5% of worker memory)
    local buffer_mem=$((worker_memory * 5 / 100))
    local buffer_cap=32
    if [ "$scale_factor" -ge 3000 ]; then buffer_cap=100
    elif [ "$scale_factor" -ge 1000 ]; then buffer_cap=64
    fi
    if [ "$buffer_mem" -gt "$buffer_cap" ]; then buffer_mem=$buffer_cap; fi
    
    # Task concurrency based on scale factor
    local task_concurrency=$vcpu
    if [ "$scale_factor" -ge 1000 ]; then
        task_concurrency=$((vcpu * 2))
    fi
    if [ "$task_concurrency" -gt 64 ]; then task_concurrency=64; fi
    
    # Round to power of 2
    local p=1
    while [ $((p * 2)) -le "$task_concurrency" ]; do
        p=$((p * 2))
    done
    task_concurrency=$p
    
    # AsyncDataCache size (50% of NVMe, cap at 500GB)
    local cache_size=0
    if [ "$nvme_gb" -gt 0 ]; then
        cache_size=$((nvme_gb / 2))
        if [ "$cache_size" -gt 500 ]; then cache_size=500; fi
        if [ "$cache_size" -lt 10 ]; then cache_size=10; fi
    fi
    
    cat <<EOF
{
    "system_reserved_gb": $system_reserved,
    "worker_memory_gb": $worker_memory,
    "buffer_memory_gb": $buffer_mem,
    "task_concurrency": $task_concurrency,
    "max_worker_threads": $task_concurrency,
    "cache_size_gb": $cache_size
}
EOF
}

# Calculate optimal Java coordinator configuration
# Usage: calculate_coordinator_config <ram_gb> <vcpu> <scale_factor> <worker_count> <worker_memory_per_node>
calculate_coordinator_config() {
    local ram_gb="$1"
    local vcpu="$2"
    local scale_factor="${3:-100}"
    local worker_count="${4:-1}"
    local worker_mem_per_node="${5:-56}"
    
    # System reserved: 5% of RAM, cap at 2GB
    local system_reserved=$((ram_gb * 5 / 100))
    if [ "$system_reserved" -gt 2 ]; then system_reserved=2; fi
    
    # JVM Heap: 90% of (RAM - system_reserved)
    local usable_ram=$((ram_gb - system_reserved))
    local jvm_heap=$((usable_ram * 90 / 100))
    
    # Query memory: 60% of heap (leaving 40% headroom)
    local query_mem_per_node=$((jvm_heap * 60 / 100))
    
    # Heap headroom: 40% of heap
    local heap_headroom=$((jvm_heap * 40 / 100))
    
    # Total cluster memory
    local total_cluster_mem=$((query_mem_per_node + (worker_mem_per_node * worker_count)))
    
    # Task concurrency
    local task_concurrency=$((vcpu * 4))
    if [ "$scale_factor" -ge 1000 ]; then
        task_concurrency=$((vcpu * 6))
    fi
    local max_concurrency=$((jvm_heap / 2))
    if [ "$task_concurrency" -lt 8 ]; then task_concurrency=8; fi
    if [ "$task_concurrency" -gt "$max_concurrency" ]; then task_concurrency=$max_concurrency; fi
    
    # Round to power of 2
    local p=1
    while [ $((p * 2)) -le "$task_concurrency" ]; do
        p=$((p * 2))
    done
    task_concurrency=$p
    
    cat <<EOF
{
    "system_reserved_gb": $system_reserved,
    "jvm_heap_gb": $jvm_heap,
    "query_mem_per_node_gb": $query_mem_per_node,
    "heap_headroom_gb": $heap_headroom,
    "total_cluster_mem_gb": $total_cluster_mem,
    "task_concurrency": $task_concurrency
}
EOF
}

# Generate worker config.properties content
# Usage: generate_worker_config <coordinator_ip> <worker_memory_gb> <task_concurrency> <cache_size_gb>
generate_worker_config() {
    local coordinator_ip="$1"
    local worker_memory_gb="$2"
    local task_concurrency="$3"
    local cache_size_gb="${4:-0}"
    
    cat <<EOF
# Worker mode
coordinator=false
presto.version=testversion

# HTTP Server
http-server.http.port=8080
discovery.uri=http://${coordinator_ip}:8080

# Memory settings (Native-specific)
system-memory-gb=${worker_memory_gb}
query-memory-gb=${worker_memory_gb}
query.max-memory-per-node=${worker_memory_gb}GB
query.max-total-memory-per-node=${worker_memory_gb}GB

# Memory arbitrator
memory-arbitrator-kind=SHARED
system-mem-pushback-enabled=true
system-mem-limit-gb=${worker_memory_gb}
system-mem-shrink-gb=20

# Concurrency
task.concurrency=${task_concurrency}
task.max-worker-threads=${task_concurrency}
task.max-drivers-per-task=${task_concurrency}

# Spilling
experimental.spill-enabled=true
experimental.spiller-spill-path=/var/presto/data/spill

# Native execution
native-execution-enabled=true
EOF

    # Add AsyncDataCache if NVMe available
    if [ "$cache_size_gb" -gt 0 ]; then
        cat <<EOF

# AsyncDataCache (SSD Cache)
async-data-cache-enabled=true
async-cache-ssd-gb=${cache_size_gb}
async-cache-ssd-path=/var/presto/cache
async-cache-ssd-checkpoint-enabled=true
EOF
    fi
}

# Generate coordinator config.properties content
# Usage: generate_coordinator_config <coordinator_ip> <jvm_heap_gb> <query_mem_per_node_gb> <heap_headroom_gb> <total_cluster_mem_gb> <task_concurrency>
generate_coordinator_config() {
    local coordinator_ip="$1"
    local jvm_heap_gb="$2"
    local query_mem_per_node_gb="$3"
    local heap_headroom_gb="$4"
    local total_cluster_mem_gb="$5"
    local task_concurrency="$6"
    
    cat <<EOF
coordinator=true
node-scheduler.include-coordinator=false
http-server.http.port=8080
discovery.uri=http://${coordinator_ip}:8080
discovery-server.enabled=true
node.internal-address=${coordinator_ip}

query.max-memory=${total_cluster_mem_gb}GB
query.max-memory-per-node=${query_mem_per_node_gb}GB
query.max-total-memory-per-node=${query_mem_per_node_gb}GB
query.max-total-memory=${total_cluster_mem_gb}GB
memory.heap-headroom-per-node=${heap_headroom_gb}GB

experimental.reserved-pool-enabled=false

task.concurrency=${task_concurrency}
task.max-worker-threads=${task_concurrency}
task.writer-count=${task_concurrency}

query-manager.required-workers=1
query-manager.required-workers-max-wait=10s

presto.version=testversion
EOF
}


