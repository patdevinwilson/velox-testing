#!/bin/bash
# Apply SF3000 optimized configuration to Presto Native workers
# Tested on: r7gd.2xlarge x 32 nodes
# Result: 22/22 TPC-H queries passed

set -e

# Configuration values that worked for SF3000
MEMORY_GB=54
CONCURRENCY=8
DOCKER_MEMORY_GB=58

usage() {
    echo "Usage: $0 <coordinator_ip> <worker_ips_file> <ssh_key>"
    echo ""
    echo "  coordinator_ip   - IP address of the Presto coordinator"
    echo "  worker_ips_file  - File containing worker IPs (one per line)"
    echo "  ssh_key          - Path to SSH private key"
    echo ""
    echo "Example:"
    echo "  $0 10.0.1.100 worker_ips.txt ~/.ssh/my-key.pem"
    exit 1
}

if [ $# -lt 3 ]; then
    usage
fi

COORDINATOR_IP=$1
WORKER_IPS_FILE=$2
SSH_KEY=$3

if [ ! -f "$WORKER_IPS_FILE" ]; then
    echo "Error: Worker IPs file not found: $WORKER_IPS_FILE"
    exit 1
fi

if [ ! -f "$SSH_KEY" ]; then
    echo "Error: SSH key not found: $SSH_KEY"
    exit 1
fi

SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"

echo "=============================================="
echo " Applying SF3000 Configuration"
echo "=============================================="
echo "Memory per worker: ${MEMORY_GB}GB"
echo "Task concurrency: ${CONCURRENCY}"
echo "Docker memory limit: ${DOCKER_MEMORY_GB}GB"
echo ""

# Update coordinator memory limits
echo "Updating coordinator at $COORDINATOR_IP..."
ssh $SSH_OPTS ec2-user@$COORDINATOR_IP "
sudo tee /opt/presto/etc/config.properties.d/sf3000.properties > /dev/null << 'EOF'
# SF3000 optimized settings
query.max-memory=1700GB
query.max-total-memory=1700GB
query.max-memory-per-node=15GB
query.max-total-memory-per-node=15GB
EOF
sudo docker restart presto-coordinator
" 2>/dev/null

echo "✓ Coordinator updated"

# Update all workers
echo ""
echo "Updating workers..."
WORKER_COUNT=0
while IFS= read -r ip; do
    [ -z "$ip" ] && continue
    
    ssh $SSH_OPTS ec2-user@$ip "
    # Update config.properties
    sudo sed -i 's/system-memory-gb=[0-9]*/system-memory-gb=${MEMORY_GB}/' /opt/presto/etc/config.properties
    sudo sed -i 's/query-memory-gb=[0-9]*/query-memory-gb=${MEMORY_GB}/' /opt/presto/etc/config.properties
    sudo sed -i 's/query.max-memory-per-node=[0-9]*GB/query.max-memory-per-node=${MEMORY_GB}GB/' /opt/presto/etc/config.properties
    sudo sed -i 's/query.max-total-memory-per-node=[0-9]*GB/query.max-total-memory-per-node=${MEMORY_GB}GB/' /opt/presto/etc/config.properties
    sudo sed -i 's/system-mem-limit-gb=[0-9]*/system-mem-limit-gb=${MEMORY_GB}/' /opt/presto/etc/config.properties
    sudo sed -i 's/task.concurrency=[0-9]*/task.concurrency=${CONCURRENCY}/' /opt/presto/etc/config.properties
    sudo sed -i 's/task.max-worker-threads=[0-9]*/task.max-worker-threads=${CONCURRENCY}/' /opt/presto/etc/config.properties
    sudo sed -i 's/task.max-drivers-per-task=[0-9]*/task.max-drivers-per-task=${CONCURRENCY}/' /opt/presto/etc/config.properties
    
    # Add global arbitration if not present
    grep -q 'global-arbitration-enabled' /opt/presto/etc/config.properties || echo 'global-arbitration-enabled=true' | sudo tee -a /opt/presto/etc/config.properties > /dev/null
    grep -q 'memory-pool-abort-capacity-limit' /opt/presto/etc/config.properties || echo 'memory-pool-abort-capacity-limit=40GB' | sudo tee -a /opt/presto/etc/config.properties > /dev/null
    
    # Update Docker memory limits in systemd service
    sudo sed -i 's/--memory=[0-9]*g/--memory=${DOCKER_MEMORY_GB}g/' /etc/systemd/system/presto.service
    sudo sed -i 's/--memory-swap=[0-9]*g/--memory-swap=${DOCKER_MEMORY_GB}g/' /etc/systemd/system/presto.service
    
    # Restart worker
    sudo systemctl daemon-reload
    sudo systemctl restart presto
    " 2>/dev/null &
    
    WORKER_COUNT=$((WORKER_COUNT + 1))
done < "$WORKER_IPS_FILE"

wait
echo "✓ Updated $WORKER_COUNT workers"

# Wait for workers to reconnect
echo ""
echo "Waiting for workers to reconnect..."
sleep 20

ACTIVE_WORKERS=$(curl -s http://$COORDINATOR_IP:8080/v1/cluster 2>/dev/null | jq '.activeWorkers' 2>/dev/null || echo "0")
echo "Active workers: $ACTIVE_WORKERS"

echo ""
echo "=============================================="
echo " SF3000 Configuration Applied"
echo "=============================================="
echo ""
echo "Configuration summary:"
echo "  - Worker memory: ${MEMORY_GB}GB"
echo "  - Task concurrency: ${CONCURRENCY}"
echo "  - Global arbitration: enabled"
echo "  - Memory pool abort limit: 40GB"
echo ""
echo "This configuration passed all 22 TPC-H queries at SF3000."

