#!/bin/bash
set -e

# Colors
GREEN='\033[0;32m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[DEPLOY]${NC} $1"
}

log "Deploying Web3 Node Stack..."

# 1. Apply Manifests
log "Applying Kubernetes Manifests..."
# Apply services first
kubectl apply -f k8s/services.yaml
# Apply statefulsets
# Apply statefulsets
kubectl apply -f k8s/geth-statefulset.yaml
kubectl apply -f k8s/prysm-statefulset.yaml
# Apply monitoring
# Apply ConfigMaps (Scripts & Dashboards)
kubectl apply -f k8s/configmap-scripts.yaml
kubectl apply -f k8s/monitoring.yaml # Contains Dashboard CM

# 2. Waiting for Pods
# Helper to wait for pod creation
wait_for_pod_creation() {
    local label=$1
    local ns=$2
    local timeout=60
    local i=0
    echo "Waiting for pod ($label) in namespace ($ns) to be created..."
    while [ $i -lt $timeout ]; do
        if kubectl get pod -n "$ns" -l "$label" --no-headers | grep -q "."; then
            return 0
        fi
        sleep 2
        ((i+=2))
    done
    echo "Timeout waiting for pod creation: $label in $ns"
    return 1
}

log "Waiting for Geth to be Running (Syncing)..."
wait_for_pod_creation "app=geth" "web3"
kubectl wait --for=jsonpath='{.status.phase}'=Running pod -n web3 -l app=geth --timeout=600s

log "Waiting for Prysm to be Running (Syncing)..."
wait_for_pod_creation "app=prysm" "web3"
kubectl wait --for=jsonpath='{.status.phase}'=Running pod -n web3 -l app=prysm --timeout=600s

log "Waiting for Monitoring Stack..."
wait_for_pod_creation "app=prometheus" "monitoring"
kubectl wait --for=condition=ready pod -n monitoring -l app=prometheus --timeout=300s
wait_for_pod_creation "app=grafana" "monitoring"
kubectl wait --for=condition=ready pod -n monitoring -l app=grafana --timeout=300s

log "All Pods are Ready."
log "Services:"
kubectl get svc -A

log "Verifying Geth is active..."
if kubectl logs -n web3 statefulset/geth --tail=200 | grep -qE "Enabled snap sync|Started P2P networking|Chain head"; then
    log "[PASS] Geth logs indicate Sync/P2P has started."
else
    log "[WARN] Geth logs missing sync startup messages. Check manually."
fi

log "Verifying Prysm is active..."
if kubectl logs -n web3 statefulset/prysm --tail=200 | grep -qE "p2p server|Checkpoint sync|Synced new block"; then
    log "[PASS] Prysm logs indicate Sync/P2P has started."
else
    log "[WARN] Prysm logs missing sync startup messages. Check manually."
fi

log "Deployment Complete!"
