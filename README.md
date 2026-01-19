# Validation Cloud Takehome - Web3 Node Automation & Simulation

This repository contains a comprehensive solution for deploying an Ethereum Web3 Node (Geth + Prysm) on Kubernetes and simulating a Bare Metal provisioning pipeline.

## Quick Start
**Prerequisites**: Ubuntu 24.04 (Host), 4+ vCPUs, 8GB+ RAM.

```bash
# 1. Run the Master Lifecycle Script
./scripts/lifecycle.sh

# This will:
# - Install all dependencies (Docker, Minikube, Go, Kubectl)
# - Deploy the Web3 Node (Geth + Prysm) on Minikube
# - Verify deployment health via a custom Go binary
# - Expose Grafana on localhost:3000
```

To clean up: `./scripts/lifecycle.sh --destroy`

---

## Architecture & Compliance Map

### Part 1A: Web3 Node on Kubernetes (Simulated Bare Metal)
*   **Requirement**: "Deploy Geth/Prysm... simulate storage... ensure syncing."
*   **Solution**: I use **Minikube** with **StatefulSets** and **HostPath** volumes.
    *   **Why StatefulSets?**: Blockchain nodes have identity (enode IDs) and crucial state. StatefulSets ensure stable network IDs and persistent storage across pod restarts.
    *   **Why HostPath?**: HostPath volumes map a directory on the host machine directly to the pod, mimicking the behavior of local NVMe disks on a bare metal server (low latency, no network storage overhead).
    *   **Sync Logic**: The node connects to the **Sepolia Testnet** for real P2P behavior. Engine API authentication is handled via an auto-generated `jwt.hex` Secret.
    *   **Reliability**: I use **Application-Aware Readiness Probes** (not just TCP checks). Geth is checked via a custom JSON-RPC command (`eth_blockNumber`), and Prysm via its HTTP Health API (`/eth/v1/node/health`), ensuring traffic only reaches fully responsive nodes.
    *   **Safety**: I increased `terminationGracePeriodSeconds` to **60s** (default 30s) to allow Geth/Prysm to flush LevelDB memtables to disk on shutdown, preventing database corruption.

### Part 1B & 2C: Bare Metal Optimization & Provisioning
*   **Requirement**: "Document optimizations... Provide Ansible playbook... Configure networking/system tuning."
*   **Solution**:
    1.  **Ansible Playbook** (`ansible/playbook.yml`): A reference playbook refactored into Roles. The `lifecycle.sh` verifies this by spinning up a "Bare Metal" container and running Ansible against it via SSH. It installs **K3s** (Lightweight K8s) and exposes the API on `localhost:7443`.
    2.  **Network Tuning**: I tune `net.core.somaxconn` (Max Connections) to `32768`. Crucially, I enable **TCP BBR** to maximize throughput on the *P2P/WAN* interface (essential for block propagation).
    3.  **System Tuning**: I raise file descriptors (`ulimit -n`) to `1,000,000` for LevelDB performance.
    4.  **Hardware Tuning (Bonus)**: See "Advanced Hardware Tuning" below for NUMA/CPU pinning strategies.

### Part 1C: Monitoring & Observability
*   **Requirement**: "Monitor... Peer count, Sync progress, Memory/CPU, Disk IO."
*   **Solution**: A fully automated **Prometheus + Grafana** stack.
    *   **Dashboards**: I pre-provision a "Ethereum Node Status" dashboard via ConfigMap.
    *   **Metrics Covered**:
        *   [OK] **Peer Count**: `p2p_peers` (Geth) & `p2p_peer_count` (Prysm).
        *   [OK] **Sync Progress**: `chain_head_block` vs `eth_blockNumber`.
        *   [OK] **Memory/CPU**: Container usage metrics (cAdvisor).
        *   [OK] **Disk IO**: `container_fs_reads_bytes_total` (Explicitly added to dashboard).

### Part 2A & 2B: Automation & Health Checks
*   **Requirement**: "Automate deployment... Write a Go script for health checks."
*   **Solution**:
    1.  **Deployment**: `scripts/lifecycle.sh` automates the entire End-to-End flow (Setup -> Deploy -> Verify -> Cleanup).
    2.  **Health Check**: `scripts/healthcheck.go` is a custom Go binary that queries the JSON-RPC API. It parses `eth_syncing` and includes **Zombie Detection** (failing calls if the head block is >60s old despite being "synced").
    2.  **Health Check**: `scripts/healthcheck.go` is a custom Go binary that queries the JSON-RPC API. It parses `eth_syncing` and includes **Zombie Detection** (failing calls if the head block is >60s old despite being "synced").
    3.  **Smart Probes**: Liveness Probe logic was refined to **pass** during syncing (preventing restart loops) while the Readiness Probe **fails** (preventing traffic).

## 3. Production & Scaling Alternatives
*How we evolve this for Global Scale:*

| Component | Current Implementation | Production Alternative | Reason for Upgrade |
| :--- | :--- | :--- | :--- |
| **Orchestration** | Raw Manifests (`kubectl apply`) | **Helm Charts + ArgoCD** | Templating for multiple environments (Dev/Stage/Prod) and GitOps audit trails. |
| **Storage** | Minikube `HostPath` | **OpenEBS LocalPV** | Replaces raw `HostPath` with formal PVC/PV objects, strictly enforcing host affinity while preserving bare-metal performance. |
| **Multi-Region** | Single Cluster | **Federated Clusters** | Deploy independent clusters in US/EU/APAC. Use **Global Accelerator** (Anycast) to route users to the nearest node. |
| **Secrets** | K8s Secret (Generated) | **HashiCorp Vault** | Dynamic secret rotation and centralized management for compliance (SOC2). |
| **Ingress** | Port Forwarding | **Nginx / HAProxy** | TLS termination, Rate Limiting, and Load Balancing across multiple replicas. |

---

### Bonus: Advanced Tuning (Hardware & Application)
To demonstrate deep knowledge of high-performance validation:

#### 1. Application-Level Optimization (Geth & Prysm)
*   **Geth Database Cache**: I would explicitly set `--cache` to 30-50% of available RAM (e.g., `--cache=32768` on a 64GB node) to keep the State Trie in memory and redundant disk reads.
*   **Snapshot Mode**: Ensure `--snapshot=true` is enabled. this allows EVM execution to read state directly from a flat file rather than traversing the Merkle Trie, massively speeding up RPC calls.

*   **P2P Limits**: We don't need 1000 peers for an RPC node. I would tune `--maxpeers` down to ~30-50 to save bandwidth/CPU for handling RPC queries, relying on a few high-quality static peers.







## Troubleshooting & Common Issues
*   **"Pending" Pods**: likely CPU/RAM starvation. Check `kubectl describe pod geth-0`. Ensure you have 4 vCPUs allocated to Docker.
*   **"Connection Refused" on Grafana**: PORT 3000 might be in use. The script attempts to find a free port or kill the occupier, but check `lsof -i :3000`.
*   **"Execution Client Not Connected"**: This is expected for the first ~60 seconds while Geth initializes. The health check loop accounts for this delay.

## Trade-offs and Justifications

| Decision | Trade-off | Justification |
| :--- | :--- | :--- |
| **Local HostPath Storage** | Node Affinity (Not Portable) | **Production Requirement**. Network storage (EBS/Ceph) cannot handle the extreme random IOPS of the State Trie. Direct NVMe access (via Manual Local PV or **OpenEBS LocalPV**) is the only viable solution for high-performance nodes. This allows standard PVC objects but retains host affinity requirements. |
| **Sepolia Testnet** | Long Sync Time | Mainnet is 1TB+. Sepolia provides realistic P2P traffic without the massive storage overhead. |
| **Ansible (Non-Executing)** | "Theory" only | Configuring host kernel parameters (sysctl) on a reviewer's laptop is dangerous/rude. I provide the *code* to prove the skill, but skip execution for safety. |
| **Root Execution (Docker)** | Security | To guarantee `HostPath` volume permissions work seamlessly on all reviewer laptops (without `chown` fights), containers run as root. In production, I would restrict this via `securityContext: runAsUser: 1000`. |

## Optimization & Production Strategy
(This section documents the advanced tuning applied in this project for Reviewer context)

### 1. P2P Networking Optimization
*   **TCP BBR**: Enabled in `ansible/roles/system_tuning` (`net.ipv4.tcp_congestion_control = bbr`). BBR drastically improves throughput on lossy WAN links, essential for rapid block propagation.
*   **Connection Limits**: `net.core.somaxconn` raised to `32768` (from 128) to handle the 100+ peer churn common in Ethereum.
*   **Manifest Tuning**: Geth/Prysm configured with `--maxpeers=100` to balance propagation speed with CPU load.

### 2. Data Persistence
*   **StatefulSets**: Used to guarantee stable network identities (Enode IDs) and persistent storage bindings (`volumeClaimTemplates`).
*   **HostPath (NVMe)**: In bare metal production, we use **OpenEBS LocalPV**. This acts as a wrapper around local NVMe disks, allowing us to use standard Kubernetes PVCs (auditable, manageable) while strictly binding the Pod to the specific node with the data. Network storage (EBS/Ceph) is too slow for the random I/O of the State Trie.
*   **Graceful Shutdown**: `terminationGracePeriodSeconds: 60` is set to ensure LevelDB has time to flush Memtables to disk on stopping, preventing database corruption.

### 3. System Tuning (Kernel & NUMA)
These are applied via the Ansible playbook (`ansible/playbook.yml`):
*   **File Descriptors**: `fs.file-max=1000000` and `ulimit -n 1048576` prevents "Too many open files" errors during heavy sync.
*   **Memory Maps**: `vm.max_map_count=262144` is required for modern DB engines (RocksDB/LevelDB) to mmap large data files.
*   **NUMA (Strategy)**: For dual-socket Bare Metal servers, we would use `cpuset` or K8s `TopologyManager` to pin the Geth process and the NIC interrupts to the **same CPU socket**. This avoids expensive QPI/UPI cross-socket traffic, reducing latency by ~15-20%.

### 4. Kubernetes-Native Monitoring
*   **Prometheus**: Scrapes standard metrics ports (6060 for Geth, 8080 for Prysm).
*   **ServiceMonitors**: Production setup uses Prometheus Operator `ServiceMonitor` resources to auto-discover new pods.
*   **Grafana**: Pre-provisioned dashboards visualize "Peers", "Sync Gap", and "Memory Usage".
*   **Probes**: Custom `readinessProbes` use the application's JSON-RPC API to verify actual functionality, not just TCP connectivity.

