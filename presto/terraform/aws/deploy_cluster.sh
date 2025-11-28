#!/bin/bash
# Unified Presto Cluster Deployment Script
# - Auto-builds images with S3 support
# - Streams build logs to local terminal
# - Deploys coordinator and workers with dynamic configs
# - Auto-runs TPC-H population, analysis, and benchmarks
#
# Usage:
#   ./deploy_cluster.sh                    # Interactive mode
#   ./deploy_cluster.sh --size medium      # Non-interactive with size
#   ./deploy_cluster.sh --build            # Build images first
#   ./deploy_cluster.sh --benchmark sf3000 # Run benchmark after deploy

set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "${SCRIPT_DIR}/lib/instance_config.sh" 2>/dev/null || true

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

SSH_KEY="${HOME}/.ssh/rapids-db-io.pem"
TFVARS_FILE="${SCRIPT_DIR}/terraform.tfvars"
LOG_DIR="${SCRIPT_DIR}/logs"
mkdir -p "${LOG_DIR}"

# Default values
CLUSTER_SIZE="medium"
SCALE_FACTOR="100"
BUILD_IMAGES=false
BUILD_ARM64=false
AUTO_BENCHMARK=true
STREAM_LOGS=true
WORKER_COUNT=""
WORKER_INSTANCE_TYPE=""

log() { echo -e "${GREEN}[$(date '+%H:%M:%S')]${NC} $1"; }
log_info() { echo -e "${BLUE}[$(date '+%H:%M:%S')]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[$(date '+%H:%M:%S')]${NC} $1"; }
log_error() { echo -e "${RED}[$(date '+%H:%M:%S')]${NC} $1"; }

print_banner() {
    echo -e "${CYAN}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Presto Native Cluster Deployment"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "${NC}"
}

print_usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Options:
  --size <size>         Cluster size preset (default: medium)
                        x86: test, small, medium, large, xlarge, xxlarge
                        ARM: graviton-small, graviton-medium, graviton-large, graviton-xlarge
                        Cost: cost-optimized-small, cost-optimized-medium
  
  --workers <n>         Override number of worker nodes
  --instance <type>     Override worker instance type (e.g., r7i.8xlarge)
  
  --benchmark <sf>      TPC-H scale factor: 100, 1000, 3000 (default: 100)
  --build               Build fresh x86 images before deployment
  --build-arm64         Build fresh ARM64 (Graviton) images
  --no-benchmark        Skip automatic benchmark after deployment
  --no-stream           Don't stream build logs (just show progress)
  
  -h, --help            Show this help

Examples:
  # Quick deploy with prebuilt images
  $0 --size medium --benchmark 100

  # Custom worker count
  $0 --size medium --workers 16 --benchmark 3000

  # Custom instance type and count
  $0 --workers 8 --instance r7i.24xlarge --benchmark 3000

  # Build fresh x86 images and deploy large cluster
  $0 --build --size large --benchmark 3000

  # Build ARM64 images for Graviton
  $0 --build-arm64

  # Deploy Graviton cluster (cost-effective) with prebuilt images
  $0 --size graviton-medium --benchmark 1000

EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --size) CLUSTER_SIZE="$2"; shift 2 ;;
            --workers) WORKER_COUNT="$2"; shift 2 ;;
            --instance) WORKER_INSTANCE_TYPE="$2"; shift 2 ;;
            --benchmark) SCALE_FACTOR="$2"; shift 2 ;;
            --build) BUILD_IMAGES=true; shift ;;
            --build-arm64) BUILD_ARM64=true; shift ;;
            --no-benchmark) AUTO_BENCHMARK=false; shift ;;
            --no-stream) STREAM_LOGS=false; shift ;;
            -h|--help) print_usage; exit 0 ;;
            *) log_error "Unknown option: $1"; print_usage; exit 1 ;;
        esac
    done
}

refresh_credentials() {
    log "Refreshing AWS credentials..."
    
    if command -v nvsec &>/dev/null; then
        CREDS=$(echo "0" | nvsec awsos get-creds --aws-profile default 2>/dev/null | grep -E "aws_access_key_id|aws_secret_access_key|aws_session_token")
        if [ -n "$CREDS" ]; then
            export AWS_ACCESS_KEY_ID=$(echo "$CREDS" | grep "aws_access_key_id" | cut -d'=' -f2)
            export AWS_SECRET_ACCESS_KEY=$(echo "$CREDS" | grep "aws_secret_access_key" | cut -d'=' -f2)
            export AWS_SESSION_TOKEN=$(echo "$CREDS" | grep "aws_session_token" | cut -d'=' -f2)
        fi
    fi
    
    if aws sts get-caller-identity &>/dev/null; then
        ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
        log "✓ Authenticated to AWS account: ${ACCOUNT_ID}"
        
        # Update terraform.tfvars
        sed -i.bak '/^aws_access_key_id/d; /^aws_secret_access_key/d; /^aws_session_token/d' "${TFVARS_FILE}" 2>/dev/null || true
        cat >> "${TFVARS_FILE}" <<EOF

# AWS Credentials (auto-generated)
aws_access_key_id     = "${AWS_ACCESS_KEY_ID}"
aws_secret_access_key = "${AWS_SECRET_ACCESS_KEY}"
aws_session_token     = "${AWS_SESSION_TOKEN}"
EOF
        return 0
    else
        log_error "AWS authentication failed"
        return 1
    fi
}

update_tfvars() {
    log "Updating terraform.tfvars..."
    
    # Update cluster_size
    if grep -q "^cluster_size" "${TFVARS_FILE}"; then
        sed -i.bak "s/^cluster_size.*$/cluster_size = \"${CLUSTER_SIZE}\"/" "${TFVARS_FILE}"
    else
        echo "cluster_size = \"${CLUSTER_SIZE}\"" >> "${TFVARS_FILE}"
    fi
    
    # Update worker_count if specified
    if [ -n "${WORKER_COUNT}" ]; then
        if grep -q "^worker_count" "${TFVARS_FILE}"; then
            sed -i.bak "s/^worker_count.*$/worker_count = ${WORKER_COUNT}/" "${TFVARS_FILE}"
        else
            echo "worker_count = ${WORKER_COUNT}" >> "${TFVARS_FILE}"
        fi
        log "  Worker count: ${WORKER_COUNT} (override)"
    fi
    
    # Update worker_instance_type if specified
    if [ -n "${WORKER_INSTANCE_TYPE}" ]; then
        if grep -q "^worker_instance_type" "${TFVARS_FILE}"; then
            sed -i.bak "s/^worker_instance_type.*$/worker_instance_type = \"${WORKER_INSTANCE_TYPE}\"/" "${TFVARS_FILE}"
        else
            echo "worker_instance_type = \"${WORKER_INSTANCE_TYPE}\"" >> "${TFVARS_FILE}"
        fi
        log "  Worker instance: ${WORKER_INSTANCE_TYPE} (override)"
    fi
    
    # Update benchmark_scale_factor
    if grep -q "^benchmark_scale_factor" "${TFVARS_FILE}"; then
        sed -i.bak "s/^benchmark_scale_factor.*$/benchmark_scale_factor = \"${SCALE_FACTOR}\"/" "${TFVARS_FILE}"
    else
        echo "benchmark_scale_factor = \"${SCALE_FACTOR}\"" >> "${TFVARS_FILE}"
    fi
    
    # Set deployment mode
    if [ "${BUILD_ARM64}" = true ]; then
        # ARM64 build mode - only deploy build instance
        sed -i.bak "s/^build_arm64.*$/build_arm64 = true/" "${TFVARS_FILE}" 2>/dev/null || \
            echo 'build_arm64 = true' >> "${TFVARS_FILE}"
        sed -i.bak "s/^presto_native_deployment.*$/presto_native_deployment = \"pull\"/" "${TFVARS_FILE}" 2>/dev/null || \
            echo 'presto_native_deployment = "pull"' >> "${TFVARS_FILE}"
        sed -i.bak "s/^create_build_instance.*$/create_build_instance = false/" "${TFVARS_FILE}" 2>/dev/null || \
            echo 'create_build_instance = false' >> "${TFVARS_FILE}"
        log "  Mode: ARM64 (Graviton) build - only build instance"
    elif [ "${BUILD_IMAGES}" = true ]; then
        # x86 build mode
        sed -i.bak "s/^build_arm64.*$/build_arm64 = false/" "${TFVARS_FILE}" 2>/dev/null || \
            echo 'build_arm64 = false' >> "${TFVARS_FILE}"
        sed -i.bak "s/^presto_native_deployment.*$/presto_native_deployment = \"build\"/" "${TFVARS_FILE}" 2>/dev/null || \
            echo 'presto_native_deployment = "build"' >> "${TFVARS_FILE}"
        sed -i.bak "s/^create_build_instance.*$/create_build_instance = true/" "${TFVARS_FILE}" 2>/dev/null || \
            echo 'create_build_instance = true' >> "${TFVARS_FILE}"
        log "  Mode: x86 build"
    else
        # Pull prebuilt images
        sed -i.bak "s/^build_arm64.*$/build_arm64 = false/" "${TFVARS_FILE}" 2>/dev/null || \
            echo 'build_arm64 = false' >> "${TFVARS_FILE}"
        sed -i.bak "s/^presto_native_deployment.*$/presto_native_deployment = \"pull\"/" "${TFVARS_FILE}" 2>/dev/null || \
            echo 'presto_native_deployment = "pull"' >> "${TFVARS_FILE}"
        sed -i.bak "s/^create_build_instance.*$/create_build_instance = false/" "${TFVARS_FILE}" 2>/dev/null || \
            echo 'create_build_instance = false' >> "${TFVARS_FILE}"
        log "  Mode: Pull prebuilt images"
    fi
    
    log "  Cluster size: ${CLUSTER_SIZE}"
    log "  Scale factor: SF${SCALE_FACTOR}"
}

stream_build_logs() {
    local build_ip="$1"
    local log_file="${LOG_DIR}/build_$(date +%Y%m%d_%H%M%S).log"
    
    log "Streaming build logs to ${log_file}..."
    log_info "Build progress will appear below. Press Ctrl+C to stop streaming (build continues)."
    echo ""
    
    # Stream logs in background
    ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no ec2-user@${build_ip} \
        "tail -f ~/build_progress.log 2>/dev/null || tail -f ~/build_output.log 2>/dev/null" \
        2>/dev/null | tee "${log_file}" &
    STREAM_PID=$!
    
    # Wait for build to complete
    while true; do
        sleep 30
        
        # Check if build is complete
        BUILD_STATUS=$(ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no ec2-user@${build_ip} \
            "grep -q 'BUILD COMPLETE' ~/build_progress.log 2>/dev/null && echo 'complete' || echo 'running'" 2>/dev/null)
        
        if [ "${BUILD_STATUS}" = "complete" ]; then
            kill ${STREAM_PID} 2>/dev/null || true
            echo ""
            log "✓ Build completed successfully!"
            return 0
        fi
        
        # Check for errors
        BUILD_ERROR=$(ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no ec2-user@${build_ip} \
            "grep -i 'error\|failed' ~/build_progress.log 2>/dev/null | tail -1" 2>/dev/null)
        
        if [ -n "${BUILD_ERROR}" ]; then
            log_warn "Possible error detected: ${BUILD_ERROR}"
        fi
    done
}

wait_for_build() {
    local build_ip="$1"
    
    log "Waiting for build instance to be ready..."
    
    # Wait for SSH
    for i in $(seq 1 30); do
        if ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o ConnectTimeout=5 ec2-user@${build_ip} "echo ready" &>/dev/null; then
            log "✓ Build instance SSH ready"
            break
        fi
        sleep 10
    done
    
    # Wait for repos to clone
    log "Waiting for repository cloning..."
    for i in $(seq 1 60); do
        CLONE_STATUS=$(ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no ec2-user@${build_ip} \
            "ls -d ~/presto ~/velox ~/velox-testing 2>/dev/null | wc -l" 2>/dev/null || echo "0")
        
        if [ "${CLONE_STATUS}" -ge 3 ]; then
            log "✓ Repositories cloned"
            break
        fi
        sleep 10
    done
    
    # Stream logs if requested
    if [ "${STREAM_LOGS}" = true ]; then
        stream_build_logs "${build_ip}"
    else
        log_info "Build running in background. Check progress with:"
        log_info "  ssh -i ${SSH_KEY} ec2-user@${build_ip} 'tail -f ~/build_progress.log'"
        
        # Just wait for completion
        while true; do
            sleep 60
            BUILD_STATUS=$(ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no ec2-user@${build_ip} \
                "grep -q 'BUILD COMPLETE' ~/build_progress.log 2>/dev/null && echo 'complete' || echo 'running'" 2>/dev/null)
            
            if [ "${BUILD_STATUS}" = "complete" ]; then
                log "✓ Build completed!"
                break
            fi
            log_info "Build still running..."
        done
    fi
}

deploy_infrastructure() {
    log "Deploying infrastructure..."
    
    cd "${SCRIPT_DIR}"
    
    terraform init -upgrade
    
    if terraform apply -auto-approve; then
        log "✓ Infrastructure deployed"
        return 0
    else
        log_error "Terraform apply failed"
        return 1
    fi
}

wait_for_cluster() {
    local coordinator_ip="$1"
    
    log "Waiting for cluster to be ready..."
    
    # Wait for Presto to start
    for i in $(seq 1 60); do
        if ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no ec2-user@${coordinator_ip} \
            "curl -s http://localhost:8080/v1/info" &>/dev/null; then
            log "✓ Presto coordinator ready"
            break
        fi
        sleep 5
    done
    
    # Wait for workers
    log "Waiting for workers to register..."
    for i in $(seq 1 60); do
        ACTIVE_WORKERS=$(ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no ec2-user@${coordinator_ip} \
            "curl -s http://localhost:8080/v1/cluster 2>/dev/null | grep -o '\"activeWorkers\":[0-9]*' | cut -d: -f2" 2>/dev/null || echo "0")
        
        if [ "${ACTIVE_WORKERS}" -ge 1 ]; then
            log "✓ ${ACTIVE_WORKERS} workers active"
            return 0
        fi
        sleep 5
    done
    
    log_warn "Worker registration timeout"
    return 1
}

run_post_deploy() {
    local coordinator_ip="$1"
    
    # Populate TPC-H tables
    log "Populating TPC-H SF${SCALE_FACTOR} tables..."
    if "${SCRIPT_DIR}/populate_tpch_from_s3_equivalent.sh"; then
        log "✓ TPC-H tables registered"
    else
        log_warn "Table population had issues"
    fi
    
    # Run benchmark if enabled
    if [ "${AUTO_BENCHMARK}" = true ]; then
        log "Running TPC-H benchmark..."
        RESULTS_FILE="${LOG_DIR}/tpch_sf${SCALE_FACTOR}_${CLUSTER_SIZE}_$(date +%Y%m%d_%H%M%S).csv"
        
        if "${SCRIPT_DIR}/run_tpch_benchmark.sh" "${SCALE_FACTOR}" "${RESULTS_FILE}" "true"; then
            log "✓ Benchmark complete: ${RESULTS_FILE}"
            
            # Show summary
            echo ""
            echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            echo -e "${CYAN}  Benchmark Results${NC}"
            echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            cat "${RESULTS_FILE}"
        else
            log_warn "Benchmark had issues"
        fi
    fi
}

main() {
    print_banner
    parse_args "$@"
    
    # Refresh credentials
    if ! refresh_credentials; then
        exit 1
    fi
    
    # Update configuration
    update_tfvars
    
    echo ""
    echo -e "${BLUE}Configuration:${NC}"
    echo "  Cluster size:    ${CLUSTER_SIZE}"
    echo "  Scale factor:    SF${SCALE_FACTOR}"
    echo "  Build x86:       ${BUILD_IMAGES}"
    echo "  Build ARM64:     ${BUILD_ARM64}"
    echo "  Auto benchmark:  ${AUTO_BENCHMARK}"
    echo ""
    
    read -p "Proceed with deployment? [Y/n]: " PROCEED
    PROCEED=${PROCEED:-y}
    if [[ ! "${PROCEED}" =~ ^[Yy] ]]; then
        log "Deployment cancelled"
        exit 0
    fi
    
    # Deploy infrastructure
    if ! deploy_infrastructure; then
        exit 1
    fi
    
    cd "${SCRIPT_DIR}"
    
    # Handle ARM64 build mode
    if [ "${BUILD_ARM64}" = true ]; then
        BUILD_IP=$(terraform output -raw build_arm64_ip 2>/dev/null || echo "")
        
        if [ -n "${BUILD_IP}" ] && [ "${BUILD_IP}" != "N/A" ]; then
            log "ARM64 build instance: ${BUILD_IP}"
            wait_for_build "${BUILD_IP}"
            
            log "✓ ARM64 images uploaded to S3:"
            log "  s3://rapids-db-io-us-east-1/docker-images/presto-worker-arm64-latest.tar.gz"
            log "  s3://rapids-db-io-us-east-1/docker-images/presto-coordinator-arm64-latest.tar.gz"
            log ""
            log "To deploy Graviton cluster with these images:"
            log "  $0 --size graviton-medium --benchmark 3000"
            exit 0
        else
            log_error "ARM64 build instance not found"
            exit 1
        fi
    fi
    
    # Handle x86 build mode
    if [ "${BUILD_IMAGES}" = true ]; then
        BUILD_IP=$(terraform output -raw build_instance_public_ip 2>/dev/null || echo "")
        
        if [ -n "${BUILD_IP}" ]; then
            wait_for_build "${BUILD_IP}"
            
            # After build, redeploy with prebuilt images
            log "Redeploying cluster with built images..."
            sed -i.bak "s/^presto_native_deployment.*$/presto_native_deployment = \"pull\"/" "${TFVARS_FILE}"
            sed -i.bak "s/^create_build_instance.*$/create_build_instance = false/" "${TFVARS_FILE}"
            
            terraform apply -auto-approve
        fi
    fi
    
    # Get coordinator IP and wait for cluster
    COORDINATOR_IP=$(terraform output -raw coordinator_public_ip 2>/dev/null)
    
    if [ -n "${COORDINATOR_IP}" ]; then
        wait_for_cluster "${COORDINATOR_IP}"
        run_post_deploy "${COORDINATOR_IP}"
        
        echo ""
        echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${GREEN}  Deployment Complete!${NC}"
        echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""
        echo "  Presto UI:  http://${COORDINATOR_IP}:8080"
        echo "  SSH:        ssh -i ${SSH_KEY} ec2-user@${COORDINATOR_IP}"
        echo ""
        echo "  Run queries:"
        echo "    presto --server localhost:8080 --catalog hive --schema tpch_sf${SCALE_FACTOR}"
        echo ""
    else
        log_error "Could not get coordinator IP"
        exit 1
    fi
}

main "$@"

