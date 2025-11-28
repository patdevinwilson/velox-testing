#!/bin/bash
# Interactive Presto AWS Deployment Script
# Handles credentials, sizing, benchmarking, and status reporting

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Script directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
STATUS_FILE="${SCRIPT_DIR}/.deployment_status.json"
TFVARS_FILE="${SCRIPT_DIR}/terraform.tfvars"

CLI_NATIVE_MODE=""
CLI_PREBUILT_IMAGE=""

# Function to log with timestamp
log() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1"
}

log_error() {
    echo -e "${RED}[$(date '+%Y-%m-%d %H:%M:%S')] ERROR:${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[$(date '+%Y-%m-%d %H:%M:%S')] WARNING:${NC} $1"
}

log_info() {
    echo -e "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')] INFO:${NC} $1"
}

ensure_tfvars_file() {
    if [ ! -f "${TFVARS_FILE}" ]; then
        touch "${TFVARS_FILE}"
    fi
}

set_tfvar_value() {
    local key="$1"
    local value="$2"
    local quoted="${3:-true}"

    ensure_tfvars_file

    local formatted="${value}"
    if [ "${quoted}" = "true" ]; then
        formatted="\"${value}\""
    fi

    if grep -q "^${key}" "${TFVARS_FILE}" 2>/dev/null; then
        sed -i.bak "s|^${key}.*$|${key} = ${formatted}|" "${TFVARS_FILE}"
    else
        echo "${key} = ${formatted}" >> "${TFVARS_FILE}"
    fi
}

print_usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Presto Native Worker Image Options:
  --native-mode build           Deploy a build instance to compile from source
                                (Recommended for protocol-matched images)
  --native-mode prebuilt        Use prebuilt S3 images (requires --prebuilt-image)
  --prebuilt-image <URI>        S3 URI for prebuilt worker image
  
Other Options:
  -h, --help                    Show this help text

Build Instance Workflow:
  1. Deploy with --native-mode build
  2. SSH to build instance and run:
     ./auto_build_s3a.sh  # ~90 min total
  3. Images uploaded to S3:
     - presto-worker-matched-latest.tar.gz
     - presto-coordinator-matched-latest.tar.gz
  4. Redeploy cluster with matched images

Prebuilt Workflow:
  1. Use existing protocol-matched S3 images
  2. Deploy with --native-mode prebuilt --prebuilt-image <S3-URI>

Available S3 Images:
  s3://rapids-db-io-us-east-1/docker-images/presto-worker-matched-latest.tar.gz
  s3://rapids-db-io-us-east-1/docker-images/presto-coordinator-matched-latest.tar.gz

Examples:
  # Build from source (protocol-matched, recommended)
  $0 --native-mode build

  # Use prebuilt protocol-matched images from S3 (recommended)
  $0 --native-mode prebuilt \\
    --prebuilt-image s3://rapids-db-io-us-east-1/docker-images/presto-worker-matched-latest.tar.gz

EOF
}

parse_cli_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --native-mode)
                CLI_NATIVE_MODE="$2"
                shift 2
                ;;
            --native-build)
                CLI_NATIVE_MODE="build"
                shift
                ;;
            --native-prebuilt)
                CLI_NATIVE_MODE="prebuilt"
                shift
                ;;
            --prebuilt-image)
                CLI_PREBUILT_IMAGE="$2"
                shift 2
                ;;
            -h|--help)
                print_usage
                exit 0
                ;;
            --)
                shift
                break
                ;;
            *)
                log_error "Unknown argument: $1"
                print_usage
                exit 1
                ;;
        esac
    done
}

# Function to update status file
update_status() {
    local stage="$1"
    local status="$2"
    local message="$3"
    
    cat > "${STATUS_FILE}" <<EOF
{
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "stage": "${stage}",
  "status": "${status}",
  "message": "${message}",
  "region": "${AWS_REGION:-us-east-1}"
}
EOF
    
    log_info "Status: ${stage} - ${status}"
    if [ -n "${message}" ]; then
        echo "         ${message}"
    fi
}

# Function to handle credential refresh
refresh_credentials() {
    local method="$1"
    
    update_status "credentials" "in_progress" "Refreshing AWS credentials using ${method}"
    
    case "${method}" in
        nvsec)
            log "Refreshing credentials with nvsec..."
            if ! command -v nvsec &> /dev/null; then
                log_error "nvsec not found. Please install nvsec or choose another method."
                return 1
            fi
            
            # Get credentials from nvsec
            CREDS=$(echo "0" | nvsec awsos get-creds --aws-profile default 2>/dev/null | grep -E "aws_access_key_id|aws_secret_access_key|aws_session_token")
            
            if [ -z "$CREDS" ]; then
                log_error "Failed to get credentials from nvsec"
                return 1
            fi
            
            # Export credentials
            export AWS_ACCESS_KEY_ID=$(echo "$CREDS" | grep "aws_access_key_id" | cut -d'=' -f2)
            export AWS_SECRET_ACCESS_KEY=$(echo "$CREDS" | grep "aws_secret_access_key" | cut -d'=' -f2)
            export AWS_SESSION_TOKEN=$(echo "$CREDS" | grep "aws_session_token" | cut -d'=' -f2)
            
            # Update terraform.tfvars
            update_tfvars_credentials
            ;;
            
        iam)
            log "Using IAM role credentials (from instance profile or ECS task role)..."
            # Remove explicit credentials from tfvars
            sed -i.bak '/^aws_access_key_id/d; /^aws_secret_access_key/d; /^aws_session_token/d' "${SCRIPT_DIR}/terraform.tfvars" 2>/dev/null || true
            ;;
            
        configure)
            log "Using AWS CLI configured credentials..."
            # Use the default AWS CLI credentials
            if ! aws sts get-caller-identity &> /dev/null; then
                log_error "AWS CLI credentials are not valid. Please run 'aws configure'"
                return 1
            fi
            ;;
            
        *)
            log_error "Unknown credential method: ${method}"
            return 1
            ;;
    esac
    
    # Verify credentials work
    if aws sts get-caller-identity &> /dev/null; then
        ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
        USER_ARN=$(aws sts get-caller-identity --query Arn --output text)
        log "✓ Credentials verified: ${USER_ARN}"
        log "  Account: ${ACCOUNT_ID}"
        update_status "credentials" "success" "Authenticated as ${USER_ARN}"
        return 0
    else
        log_error "Credential verification failed"
        update_status "credentials" "failed" "Failed to authenticate"
        return 1
    fi
}

# Function to update terraform.tfvars with credentials
update_tfvars_credentials() {
    log "Updating terraform.tfvars with fresh credentials..."
    
    # Remove old credentials if they exist
    sed -i.bak '/^aws_access_key_id/d; /^aws_secret_access_key/d; /^aws_session_token/d' "${SCRIPT_DIR}/terraform.tfvars" 2>/dev/null || true
    
    # Add new credentials
    cat >> "${SCRIPT_DIR}/terraform.tfvars" <<EOF

# AWS Credentials (auto-generated by deploy_presto.sh)
aws_access_key_id     = "${AWS_ACCESS_KEY_ID}"
aws_secret_access_key = "${AWS_SECRET_ACCESS_KEY}"
aws_session_token     = "${AWS_SESSION_TOKEN}"
EOF
}

# Function to configure deployment
configure_deployment() {
    log "Configuring deployment parameters..."
    update_status "configuration" "in_progress" "Setting up deployment configuration"
    
    # Cluster size selection
    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}  Select Cluster Size${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "${YELLOW}x86 (Intel r7i):${NC}"
    echo "  1) test      - 1x r7i.xlarge     32GB   (~\$0.42/hr)  - Quick testing"
    echo "  2) small     - 2x r7i.2xlarge    64GB   (~\$1.26/hr)  - Small demos"
    echo "  3) medium    - 4x r7i.8xlarge    256GB  (~\$9/hr)     - Benchmarks"
    echo "  4) large     - 4x r7i.16xlarge   512GB  (~\$17/hr)    - Large benchmarks"
    echo "  5) xlarge    - 8x r7i.16xlarge   512GB  (~\$34/hr)    - High performance"
    echo "  6) xxlarge   - 8x r7i.24xlarge   768GB  (~\$50/hr)    - Maximum performance"
    echo ""
    echo -e "${YELLOW}ARM (Graviton r7gd with NVMe SSD cache):${NC}"
    echo "  7) graviton-small  - 2x r7gd.2xlarge   64GB+474GB   (~\$1.28/hr)"
    echo "  8) graviton-medium - 4x r7gd.4xlarge   128GB+950GB  (~\$4.69/hr)"
    echo "  9) graviton-large  - 4x r7gd.8xlarge   256GB+1.9TB  (~\$9.38/hr)"
    echo " 10) graviton-xlarge - 8x r7gd.16xlarge  512GB+3.8TB  (~\$35/hr)"
    echo ""
    echo -e "${YELLOW}Cost-Optimized (best \$/benchmark):${NC}"
    echo " 11) cost-small  - 32x r7i.2xlarge  (~\$16/hr, ~\$5/run)"
    echo " 12) cost-medium - 16x r7i.4xlarge  (~\$17/hr, ~\$6/run)"
    echo ""
    read -p "Select cluster size [1-12] (default: 3): " CLUSTER_SIZE_CHOICE
    CLUSTER_SIZE_CHOICE=${CLUSTER_SIZE_CHOICE:-3}
    
    case ${CLUSTER_SIZE_CHOICE} in
        1) CLUSTER_SIZE="test" ;;
        2) CLUSTER_SIZE="small" ;;
        3) CLUSTER_SIZE="medium" ;;
        4) CLUSTER_SIZE="large" ;;
        5) CLUSTER_SIZE="xlarge" ;;
        6) CLUSTER_SIZE="xxlarge" ;;
        7) CLUSTER_SIZE="graviton-small" ;;
        8) CLUSTER_SIZE="graviton-medium" ;;
        9) CLUSTER_SIZE="graviton-large" ;;
        10) CLUSTER_SIZE="graviton-xlarge" ;;
        11) CLUSTER_SIZE="cost-optimized-small" ;;
        12) CLUSTER_SIZE="cost-optimized-medium" ;;
        *) log_warning "Invalid choice, defaulting to medium"; CLUSTER_SIZE="medium" ;;
    esac
    
    # TPC-H scale factor selection
    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}  Select TPC-H Benchmark Scale Factor${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo "1) none   - No benchmark (skip TPC-H setup)"
    echo "2) 100    - SF100  (100GB dataset)"
    echo "3) 1000   - SF1000 (1TB dataset)"
    echo "4) 3000   - SF3000 (3TB dataset)"
    echo ""
    read -p "Select scale factor [1-4] (default: 2): " SCALE_FACTOR_CHOICE
    SCALE_FACTOR_CHOICE=${SCALE_FACTOR_CHOICE:-2}
    
    case ${SCALE_FACTOR_CHOICE} in
        1) SCALE_FACTOR="none" ;;
        2) SCALE_FACTOR="100" ;;
        3) SCALE_FACTOR="1000" ;;
        4) SCALE_FACTOR="3000" ;;
        *) log_warning "Invalid choice, defaulting to SF100"; SCALE_FACTOR="100" ;;
    esac
    
    # Auto-run benchmark option
    echo ""
    read -p "Automatically run benchmark after deployment? [y/N]: " AUTO_BENCHMARK
    AUTO_BENCHMARK=${AUTO_BENCHMARK:-n}
    
    if [[ "${AUTO_BENCHMARK}" =~ ^[Yy] ]]; then
        AUTO_RUN_BENCHMARK="true"
    else
        AUTO_RUN_BENCHMARK="false"
    fi
    
    # Update terraform.tfvars
    log "Updating terraform.tfvars with configuration..."
    
    # Update or add cluster_size
    if grep -q "^cluster_size" "${SCRIPT_DIR}/terraform.tfvars"; then
        sed -i.bak "s/^cluster_size.*$/cluster_size = \"${CLUSTER_SIZE}\"/" "${SCRIPT_DIR}/terraform.tfvars"
    else
        echo "cluster_size = \"${CLUSTER_SIZE}\"" >> "${SCRIPT_DIR}/terraform.tfvars"
    fi
    
    # Update or add benchmark_scale_factor
    if grep -q "^benchmark_scale_factor" "${SCRIPT_DIR}/terraform.tfvars"; then
        sed -i.bak "s/^benchmark_scale_factor.*$/benchmark_scale_factor = \"${SCALE_FACTOR}\"/" "${SCRIPT_DIR}/terraform.tfvars"
    else
        echo "benchmark_scale_factor = \"${SCALE_FACTOR}\"" >> "${SCRIPT_DIR}/terraform.tfvars"
    fi
    
    # Update or add auto_run_benchmark
    if grep -q "^auto_run_benchmark" "${SCRIPT_DIR}/terraform.tfvars"; then
        sed -i.bak "s/^auto_run_benchmark.*$/auto_run_benchmark = ${AUTO_RUN_BENCHMARK}/" "${SCRIPT_DIR}/terraform.tfvars"
    else
        echo "auto_run_benchmark = ${AUTO_RUN_BENCHMARK}" >> "${SCRIPT_DIR}/terraform.tfvars"
    fi
    
    # Enable status reporting
    if grep -q "^enable_status_reporting" "${SCRIPT_DIR}/terraform.tfvars"; then
        sed -i.bak "s/^enable_status_reporting.*$/enable_status_reporting = true/" "${SCRIPT_DIR}/terraform.tfvars"
    else
        echo "enable_status_reporting = true" >> "${SCRIPT_DIR}/terraform.tfvars"
    fi
    
    log "✓ Configuration complete:"
    log "  Cluster size: ${CLUSTER_SIZE}"
    log "  TPC-H scale factor: ${SCALE_FACTOR}"
    log "  Auto-run benchmark: ${AUTO_RUN_BENCHMARK}"
    
    update_status "configuration" "success" "Cluster: ${CLUSTER_SIZE}, TPC-H: SF${SCALE_FACTOR}"
}

apply_native_mode_configuration() {
    if [ -z "${CLI_NATIVE_MODE}" ] && [ -z "${CLI_PREBUILT_IMAGE}" ]; then
        return
    fi

    local mode="${CLI_NATIVE_MODE}"
    if [ -z "${mode}" ]; then
        mode="prebuilt"
    fi

    case "${mode}" in
        build)
            log "Configuring native deployment for build instance mode"
            set_tfvar_value "create_build_instance" "true" false
            set_tfvar_value "presto_native_deployment" "build" true
            if [ -n "${CLI_PREBUILT_IMAGE}" ]; then
                log_warning "--prebuilt-image ignored because --native-mode=build"
            fi
            ;;
        prebuilt|pull|s3)
            if [ -z "${CLI_PREBUILT_IMAGE}" ]; then
                log_error "--prebuilt-image is required when --native-mode=prebuilt"
                exit 1
            fi
            log "Configuring native deployment for prebuilt image: ${CLI_PREBUILT_IMAGE}"
            set_tfvar_value "create_build_instance" "false" false
            set_tfvar_value "presto_native_deployment" "pull" true
            set_tfvar_value "presto_native_image_source" "${CLI_PREBUILT_IMAGE}" true
            ;;
        *)
            log_error "Invalid value for --native-mode: ${mode}. Use 'build' or 'prebuilt'."
            exit 1
            ;;
    esac
}

# Function to deploy infrastructure
deploy_infrastructure() {
    log "Deploying Presto infrastructure..."
    update_status "deployment" "in_progress" "Running terraform apply"
    
    cd "${SCRIPT_DIR}"
    
    # Initialize terraform modules (always) to ensure module changes are picked up
    log "Initializing Terraform modules..."
    if ! terraform init -upgrade; then
        log_error "Terraform init failed"
        update_status "deployment" "failed" "Terraform init failed"
        return 1
    fi
    
    # Run terraform apply
    log "Applying Terraform configuration..."
    if terraform apply -auto-approve; then
        log "✓ Infrastructure deployed successfully"
        update_status "deployment" "success" "Infrastructure provisioned"
        return 0
    else
        log_error "Terraform apply failed"
        update_status "deployment" "failed" "Terraform apply failed"
        return 1
    fi
}

# Function to check SSH connectivity
wait_for_ssh() {
    local ip="$1"
    local name="$2"
    local max_attempts=30
    local attempt=0
    
    log_info "Waiting for SSH on ${name} (${ip})..."
    
    while [ $attempt -lt $max_attempts ]; do
        if ssh -i ~/.ssh/rapids-db-io.pem -o StrictHostKeyChecking=no -o ConnectTimeout=5 ec2-user@${ip} "echo 'SSH ready'" &>/dev/null; then
            log "✓ SSH ready on ${name}"
            return 0
        fi
        attempt=$((attempt + 1))
        sleep 10
    done
    
    log_warning "SSH timeout on ${name} after ${max_attempts} attempts"
    return 1
}

# Function to check user-data log status
check_user_data_log() {
    local ip="$1"
    local name="$2"
    
    log_info "Checking user-data log on ${name} (${ip})..."
    
    # Check if log file exists and get last few lines
    local log_status=$(ssh -i ~/.ssh/rapids-db-io.pem -o StrictHostKeyChecking=no -o ConnectTimeout=10 ec2-user@${ip} \
        "if [ -f /var/log/user-data.log ]; then \
            tail -20 /var/log/user-data.log; \
        else \
            echo 'Log file not yet created'; \
        fi" 2>/dev/null)
    
    if [ -z "$log_status" ]; then
        log_warning "Could not retrieve log from ${name}"
        return 1
    fi
    
    # Check for completion markers
    if echo "$log_status" | grep -q "User data script completed successfully"; then
        log "✓ ${name}: User-data script completed successfully"
        return 0
    elif echo "$log_status" | grep -q "ERROR\|Failed\|failed"; then
        log_error "${name}: Errors detected in user-data log"
        echo "$log_status" | tail -5
        return 2
    else
        log_info "${name}: User-data script still running..."
        echo "$log_status" | tail -3
        return 1
    fi
}

# Function to monitor all instances
monitor_instances() {
    log "Monitoring instance initialization..."
    update_status "monitoring" "in_progress" "Checking instance initialization status"
    
    cd "${SCRIPT_DIR}"
    
    # Get instance IPs
    local coordinator_ip=$(terraform output -raw coordinator_public_ip 2>/dev/null)
    local worker_ips=($(terraform output -json worker_public_ips 2>/dev/null | jq -r '.[]'))
    
    if [ -z "${coordinator_ip}" ]; then
        log_error "Could not retrieve instance IPs"
        return 1
    fi
    
    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}  Instance Initialization Monitor${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    # Wait for SSH on all instances
    log "Phase 1: Waiting for SSH connectivity..."
    wait_for_ssh "${coordinator_ip}" "coordinator" || log_warning "SSH timeout on coordinator"
    
    for i in "${!worker_ips[@]}"; do
        wait_for_ssh "${worker_ips[$i]}" "worker-$i" || log_warning "SSH timeout on worker-$i"
    done
    
    echo ""
    log "Phase 2: Monitoring user-data script execution..."
    echo ""
    
    # Monitor user-data logs
    local max_checks=60  # 10 minutes (60 * 10 seconds)
    local check_count=0
    local all_complete=false
    
    # Track completion status (bash 3.2 compatible)
    local coordinator_status="pending"
    local worker_status=()
    for i in "${!worker_ips[@]}"; do
        worker_status[$i]="pending"
    done
    
    while [ $check_count -lt $max_checks ] && [ "$all_complete" == "false" ]; do
        all_complete=true
        
        # Check coordinator
        if [ "$coordinator_status" == "pending" ]; then
            check_user_data_log "${coordinator_ip}" "coordinator"
            local ret=$?
            if [ $ret -eq 0 ]; then
                coordinator_status="complete"
            elif [ $ret -eq 2 ]; then
                coordinator_status="error"
            else
                all_complete=false
            fi
        fi
        
        # Check workers
        for i in "${!worker_ips[@]}"; do
            if [ "${worker_status[$i]}" == "pending" ]; then
                check_user_data_log "${worker_ips[$i]}" "worker-$i"
                local ret=$?
                if [ $ret -eq 0 ]; then
                    worker_status[$i]="complete"
                elif [ $ret -eq 2 ]; then
                    worker_status[$i]="error"
                else
                    all_complete=false
                fi
            fi
        done
        
        if [ "$all_complete" == "false" ]; then
            check_count=$((check_count + 1))
            if [ $check_count -lt $max_checks ]; then
                echo ""
                log_info "Rechecking in 10 seconds... (${check_count}/${max_checks})"
                sleep 10
            fi
        fi
    done
    
    # Display final status
    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}  Initialization Status Summary${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    local has_errors=false
    for key in "${!instance_status[@]}"; do
        if [ "${instance_status[$key]}" == "complete" ]; then
            echo -e "  ${GREEN}✓${NC} $key: Complete"
        elif [ "${instance_status[$key]}" == "error" ]; then
            echo -e "  ${RED}✗${NC} $key: Error"
            has_errors=true
        else
            echo -e "  ${YELLOW}⚠${NC} $key: Timeout (still running)"
        fi
    done
    
    echo ""
    
    if [ "$has_errors" == "true" ]; then
        log_error "Some instances encountered errors during initialization"
        log_info "Check logs with: ssh -i ~/.ssh/rapids-db-io.pem ec2-user@<ip> 'sudo tail -50 /var/log/user-data.log'"
        update_status "monitoring" "completed_with_errors" "Initialization completed with errors"
        return 1
    elif [ "$all_complete" == "false" ]; then
        log_warning "Some instances did not complete initialization within timeout"
        log_info "You can continue monitoring manually with SSH"
        update_status "monitoring" "completed_with_timeout" "Initialization timeout, services may still be starting"
        return 0
    else
        log "✓ All instances initialized successfully"
        update_status "monitoring" "success" "All instances ready"
        return 0
    fi
}

# Function to extract and display outputs
display_outputs() {
    log "Retrieving deployment outputs..."
    update_status "outputs" "in_progress" "Collecting deployment information"
    
    cd "${SCRIPT_DIR}"
    
    # Get terraform outputs
    COORDINATOR_IP=$(terraform output -raw coordinator_public_ip 2>/dev/null || echo "")
    PRESTO_UI_URL=$(terraform output -raw presto_ui_url 2>/dev/null || echo "")
    SSH_COORDINATOR=$(terraform output -raw ssh_coordinator 2>/dev/null || echo "")
    
    if [ -z "${COORDINATOR_IP}" ]; then
        log_warning "Could not retrieve outputs. Deployment may have failed."
        return 1
    fi
    
    # Create detailed status with outputs
    cat > "${STATUS_FILE}" <<EOF
{
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "stage": "complete",
  "status": "success",
  "region": "${AWS_REGION:-us-east-1}",
  "cluster_size": "${CLUSTER_SIZE}",
  "tpch_scale_factor": "${SCALE_FACTOR}",
  "coordinator_ip": "${COORDINATOR_IP}",
  "presto_ui_url": "${PRESTO_UI_URL}",
  "ssh_command": "${SSH_COORDINATOR}"
}
EOF
    
    # Display summary
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  Presto Cluster Deployed Successfully!${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "${BLUE}Cluster Configuration:${NC}"
    echo "  Size: ${CLUSTER_SIZE}"
    echo "  TPC-H Scale: SF${SCALE_FACTOR}"
    echo "  Region: ${AWS_REGION:-us-east-1}"
    echo ""
    echo -e "${BLUE}Access Information:${NC}"
    echo "  Presto UI: ${PRESTO_UI_URL}"
    echo "  Coordinator IP: ${COORDINATOR_IP}"
    echo ""
    echo -e "${BLUE}SSH Access:${NC}"
    echo "  ${SSH_COORDINATOR}"
    echo ""
    echo -e "${BLUE}Status File:${NC}"
    echo "  ${STATUS_FILE}"
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    
    update_status "complete" "success" "Cluster ready at ${PRESTO_UI_URL}"
}

# Main execution
main() {
    parse_cli_args "$@"

    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  Presto AWS Deployment Script${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    # Credential refresh method selection
    echo -e "${BLUE}Select credential refresh method:${NC}"
    echo "1) nvsec       - Use NVIDIA Security tool"
    echo "2) iam         - Use IAM role (for EC2/ECS)"
    echo "3) configure   - Use AWS CLI credentials"
    echo ""
    read -p "Select method [1-3] (default: 1): " CRED_METHOD_CHOICE
    CRED_METHOD_CHOICE=${CRED_METHOD_CHOICE:-1}
    
    case ${CRED_METHOD_CHOICE} in
        1) CRED_METHOD="nvsec" ;;
        2) CRED_METHOD="iam" ;;
        3) CRED_METHOD="configure" ;;
        *) log_warning "Invalid choice, defaulting to nvsec"; CRED_METHOD="nvsec" ;;
    esac
    
    # Execute deployment steps
    if ! refresh_credentials "${CRED_METHOD}"; then
        log_error "Failed to refresh credentials. Exiting."
        exit 1
    fi
    
    configure_deployment
    apply_native_mode_configuration
    
    echo ""
    read -p "Proceed with deployment? [Y/n]: " PROCEED
    PROCEED=${PROCEED:-y}
    
    if [[ ! "${PROCEED}" =~ ^[Yy] ]]; then
        log "Deployment cancelled by user"
        exit 0
    fi
    
    if deploy_infrastructure; then
        display_outputs
        
        # Monitor instance initialization
        echo ""
        log "Starting instance initialization monitoring..."
        if monitor_instances; then
            log "✓ All instances initialized successfully"
            
            # Wait for workers to become active before running TPC-H setup
            echo ""
            log "Waiting for workers to become active..."
            update_status "worker_activation" "in_progress" "Waiting for workers to activate"
            
            # Get coordinator IP for checking
            cd "${SCRIPT_DIR}"
            COORDINATOR_IP=$(terraform output -raw coordinator_public_ip 2>/dev/null)
            
            # Wait up to 5 minutes for at least 1 worker to become active
            MAX_WAIT=60  # 60 attempts × 5 seconds = 5 minutes
            WAIT_COUNT=0
            WORKERS_ACTIVE=false
            
            while [ $WAIT_COUNT -lt $MAX_WAIT ]; do
                ACTIVE_WORKERS=$(ssh -i ~/.ssh/rapids-db-io.pem -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
                    ec2-user@${COORDINATOR_IP} \
                    "curl -s http://localhost:8080/v1/cluster 2>/dev/null | jq -r '.activeWorkers' 2>/dev/null" || echo "0")
                
                if [ "$ACTIVE_WORKERS" -ge 1 ] 2>/dev/null; then
                    log "✓ Workers active: ${ACTIVE_WORKERS}"
                    WORKERS_ACTIVE=true
                    update_status "worker_activation" "success" "${ACTIVE_WORKERS} workers active"
                    break
                fi
                
                WAIT_COUNT=$((WAIT_COUNT + 1))
                if [ $((WAIT_COUNT % 6)) -eq 0 ]; then
                    log_info "Still waiting for workers... (${WAIT_COUNT}/${MAX_WAIT})"
                fi
                sleep 5
            done
            
            if [ "$WORKERS_ACTIVE" = "false" ]; then
                log_warning "Workers did not become active within timeout"
                log_info "You can check worker status with: ./monitor_cluster.sh"
                update_status "worker_activation" "timeout" "Workers did not activate in time"
            fi
            
            # Automatically populate TPC-H tables if scale factor is set AND workers are active
            if [ "${SCALE_FACTOR}" != "none" ] && [ "$WORKERS_ACTIVE" = "true" ]; then
                echo ""
                log "Starting automatic TPC-H table population..."
                log_info "Scale Factor: SF${SCALE_FACTOR}"
                log_info "This will create Hive tables with S3-backed parquet data"
                
                update_status "tpch_population" "in_progress" "Populating TPC-H SF${SCALE_FACTOR} tables"
                
                # Run the population script
                if "${SCRIPT_DIR}/populate_tpch_from_s3_equivalent.sh"; then
                    log "✓ TPC-H tables populated successfully"
                    update_status "tpch_population" "success" "TPC-H SF${SCALE_FACTOR} ready for benchmarking"
                else
                    log_warning "TPC-H table population failed or incomplete"
                    update_status "tpch_population" "failed" "Table population encountered errors"
                fi
            elif [ "${SCALE_FACTOR}" != "none" ] && [ "$WORKERS_ACTIVE" = "false" ]; then
                log_warning "Skipping TPC-H table population - workers not active"
                log_info "You can manually populate later with: ./populate_tpch_from_s3_equivalent.sh"
            else
                log_info "TPC-H table population skipped (scale_factor=none)"
            fi
            
            # If auto-benchmark is enabled, run benchmarks
            if [ "${AUTO_RUN_BENCHMARK}" = "true" ]; then
                echo ""
                log "Starting automated benchmarking..."
                update_status "benchmark" "in_progress" "Running TPC-H benchmarks"
                
                # Run benchmarks (create benchmark script if needed)
                if [ -f "${SCRIPT_DIR}/run_tpch_benchmark.sh" ]; then
                    "${SCRIPT_DIR}/run_tpch_benchmark.sh"
                else
                    log_info "Benchmark script not found, skipping auto-benchmark"
                    log_info "You can run benchmarks manually on the coordinator"
                fi
            fi
        else
            log_warning "Instance initialization completed with warnings"
        fi
        
        exit 0
    else
        log_error "Deployment failed"
        exit 1
    fi
}

# Run main
main "$@"

