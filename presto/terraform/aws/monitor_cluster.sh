#!/bin/bash
# Standalone Cluster Monitoring Script
# Monitor user-data logs and service status on all cluster instances

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Script directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
SSH_KEY="${HOME}/.ssh/rapids-db-io.pem"

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

# Check if terraform state exists
check_terraform() {
    if [ ! -f "${SCRIPT_DIR}/terraform.tfstate" ]; then
        log_error "No terraform state found. Have you deployed a cluster?"
        exit 1
    fi
}

# Get instance IPs from terraform
get_instance_ips() {
    cd "${SCRIPT_DIR}"
    
    COORDINATOR_IP=$(terraform output -raw coordinator_public_ip 2>/dev/null)
    WORKER_IPS=($(terraform output -json worker_public_ips 2>/dev/null | jq -r '.[]' 2>/dev/null))
    
    if [ -z "${COORDINATOR_IP}" ]; then
        log_error "Could not retrieve instance IPs from terraform"
        exit 1
    fi
    
    log "Found cluster:"
    log "  Coordinator: ${COORDINATOR_IP}"
    for i in "${!WORKER_IPS[@]}"; do
        log "  Worker $i: ${WORKER_IPS[$i]}"
    done
}

# Check SSH connectivity
check_ssh() {
    local ip="$1"
    ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o ConnectTimeout=5 ec2-user@${ip} "echo 'ok'" &>/dev/null
    return $?
}

# Get user-data log from instance
get_user_data_log() {
    local ip="$1"
    local lines="${2:-50}"
    
    ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o ConnectTimeout=10 ec2-user@${ip} \
        "sudo tail -${lines} /var/log/user-data.log 2>/dev/null || echo 'Log not available'"
}

# Check if user-data script completed
check_completion() {
    local ip="$1"
    
    ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o ConnectTimeout=10 ec2-user@${ip} \
        "sudo grep -q 'User data script completed successfully' /var/log/user-data.log 2>/dev/null" && return 0 || return 1
}

# Check Docker container status (for workers)
check_docker_container() {
    local ip="$1"
    local container_name="$2"
    
    ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o ConnectTimeout=10 ec2-user@${ip} \
        "sudo docker ps -a --filter 'name=${container_name}' --format '{{.Status}}|{{.Ports}}' 2>/dev/null" \
        || echo ""
}

# Display detailed status for an instance
display_instance_status() {
    local ip="$1"
    local name="$2"
    
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  ${name} (${ip})${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    
    # Check SSH
    if check_ssh "${ip}"; then
        echo -e "  SSH:           ${GREEN}✓ Connected${NC}"
    else
        echo -e "  SSH:           ${RED}✗ Unreachable${NC}"
        return 1
    fi
    
    # Check user-data completion
    if check_completion "${ip}"; then
        echo -e "  User-data:     ${GREEN}✓ Completed${NC}"
    else
        echo -e "  User-data:     ${YELLOW}⚠ In progress or failed${NC}"
    fi
    
    # Check service status based on role
    if [[ "${name}" == *"Coordinator"* ]]; then
        # Coordinator runs as Docker container
        local docker_status=$(check_docker_container "${ip}" "presto-coordinator")
        if [[ -n "${docker_status}" ]]; then
            local presto_state=$(echo "${docker_status}" | cut -d'|' -f1)
            local presto_ports=$(echo "${docker_status}" | cut -d'|' -f2-)
            if [[ "${presto_state}" == Up* ]]; then
                echo -e "  Presto (Java): ${GREEN}✓ Running (Docker)${NC}"
            else
                echo -e "  Presto (Java): ${RED}✗ ${presto_state}${NC}"
            fi
            if [[ -n "${presto_ports}" ]]; then
                echo -e "  Ports:         ${presto_ports}"
            fi
        else
            echo -e "  Presto (Java): ${RED}✗ Container not running${NC}"
        fi

        # Hive Metastore container (optional)
        local hms_status=$(check_docker_container "${ip}" "hive-metastore")
        if [[ -n "${hms_status}" ]]; then
            local hms_state=$(echo "${hms_status}" | cut -d'|' -f1)
            local hms_ports=$(echo "${hms_status}" | cut -d'|' -f2-)
            if [[ "${hms_state}" == Up* ]]; then
                echo -e "  Hive Metastore:${GREEN}✓ Running (Docker)${NC}"
            else
                echo -e "  Hive Metastore:${RED}✗ ${hms_state}${NC}"
            fi
            if [[ -n "${hms_ports}" ]]; then
                echo -e "  HMS Ports:     ${hms_ports}"
            fi
        fi
    else
        # Workers use Docker containers for Presto Native
        local worker_docker=$(check_docker_container "${ip}" "presto-worker")
        if [[ -n "${worker_docker}" ]]; then
            local worker_state=$(echo "${worker_docker}" | cut -d'|' -f1)
            local worker_ports=$(echo "${worker_docker}" | cut -d'|' -f2-)
            if [[ "${worker_state}" == Up* ]]; then
                echo -e "  Presto Native: ${GREEN}✓ Running (Docker)${NC}"
            else
                echo -e "  Presto Native: ${RED}✗ ${worker_state}${NC}"
            fi
            if [[ -n "${worker_ports}" ]]; then
                echo -e "  Ports:         ${worker_ports}"
            fi
        else
            echo -e "  Presto Native: ${RED}✗ Container not running${NC}"
        fi
    fi
    
    # Show last 10 lines of user-data log
    echo ""
    echo -e "${BLUE}  Last 10 lines of user-data log:${NC}"
    echo ""
    local log_content=$(get_user_data_log "${ip}" 10)
    echo "${log_content}" | sed 's/^/    /'
}

# Monitor all instances
monitor_all() {
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  Presto Cluster Status Monitor${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    
    # Display coordinator status
    display_instance_status "${COORDINATOR_IP}" "Coordinator"
    
    # Display worker statuses
    for i in "${!WORKER_IPS[@]}"; do
        display_instance_status "${WORKER_IPS[$i]}" "Worker-${i}"
    done
    
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# Watch mode - continuous monitoring
watch_mode() {
    local interval="${1:-30}"
    
    log "Starting watch mode (refresh every ${interval}s, Ctrl+C to exit)"
    echo ""
    
    while true; do
        clear
        monitor_all
        sleep "${interval}"
    done
}

# Display full log for specific instance
show_full_log() {
    local instance_type="$1"  # coordinator, worker-0, worker-1, etc.
    
    local ip=""
    if [ "${instance_type}" == "coordinator" ]; then
        ip="${COORDINATOR_IP}"
    elif [[ "${instance_type}" =~ worker-([0-9]+) ]]; then
        local worker_idx="${BASH_REMATCH[1]}"
        ip="${WORKER_IPS[$worker_idx]}"
    else
        log_error "Invalid instance type: ${instance_type}"
        log_info "Use: coordinator, worker-0, worker-1, etc."
        exit 1
    fi
    
    if [ -z "${ip}" ]; then
        log_error "Could not find IP for ${instance_type}"
        exit 1
    fi
    
    log "Fetching full user-data log from ${instance_type} (${ip})..."
    echo ""
    
    ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no ec2-user@${ip} \
        "sudo cat /var/log/user-data.log 2>/dev/null || echo 'Log not available'"
}

# Follow log in real-time
follow_log() {
    local instance_type="$1"
    
    local ip=""
    if [ "${instance_type}" == "coordinator" ]; then
        ip="${COORDINATOR_IP}"
    elif [[ "${instance_type}" =~ worker-([0-9]+) ]]; then
        local worker_idx="${BASH_REMATCH[1]}"
        ip="${WORKER_IPS[$worker_idx]}"
    else
        log_error "Invalid instance type: ${instance_type}"
        log_info "Use: coordinator, worker-0, worker-1, etc."
        exit 1
    fi
    
    if [ -z "${ip}" ]; then
        log_error "Could not find IP for ${instance_type}"
        exit 1
    fi
    
    log "Following user-data log from ${instance_type} (${ip})..."
    log_info "Press Ctrl+C to exit"
    echo ""
    
    ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no ec2-user@${ip} \
        "sudo tail -f /var/log/user-data.log 2>/dev/null || echo 'Log not available'"
}

# Show usage
usage() {
    cat <<EOF
Usage: $0 [COMMAND] [OPTIONS]

Commands:
    status              Show current status of all instances (default)
    watch [INTERVAL]    Watch mode - continuous monitoring (default: 30s)
    log <INSTANCE>      Show full user-data log for instance
    follow <INSTANCE>   Follow user-data log in real-time
    help                Show this help message

Instance names:
    coordinator         The coordinator node
    worker-0            Worker node 0
    worker-1            Worker node 1
    (etc.)

Examples:
    $0                          # Show status once
    $0 status                   # Show status once
    $0 watch                    # Watch mode, refresh every 30s
    $0 watch 10                 # Watch mode, refresh every 10s
    $0 log coordinator          # Show full log from coordinator
    $0 log worker-0             # Show full log from worker 0
    $0 follow coordinator       # Follow coordinator log in real-time

EOF
    exit 0
}

# Main
main() {
    check_terraform
    get_instance_ips
    
    local command="${1:-status}"
    
    case "${command}" in
        status)
            monitor_all
            ;;
        watch)
            local interval="${2:-30}"
            watch_mode "${interval}"
            ;;
        log)
            local instance="${2:-}"
            if [ -z "${instance}" ]; then
                log_error "Instance name required"
                usage
            fi
            show_full_log "${instance}"
            ;;
        follow)
            local instance="${2:-}"
            if [ -z "${instance}" ]; then
                log_error "Instance name required"
                usage
            fi
            follow_log "${instance}"
            ;;
        help|--help|-h)
            usage
            ;;
        *)
            log_error "Unknown command: ${command}"
            usage
            ;;
    esac
}

main "$@"

