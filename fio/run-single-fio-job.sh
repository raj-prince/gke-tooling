#!/bin/bash

# Simple FIO Benchmark Runner for GKE
# Usage: ./simple-fio.sh [num_files] [file_size] [iterations] [mode] [block_size] [mount_options]

set -e

# Default values
NUM_FILES=${1:-100}
FILE_SIZE=${2:-256K}
ITERATIONS=${3:-3}
MODE=${4:-read}
BLOCK_SIZE=${5:-1M}
MOUNT_OPTIONS=${6:-"implicit-dirs,metadata-cache:ttl-secs:-1,metadata-cache:stat-cache-max-size-mb:-1,metadata-cache:type-cache-max-size-mb:-1,log-severity=info"}

# GKE Configuration
PROJECT_ID="gcs-tess"
CLUSTER_REGION="us-central1-c"
CLUSTER_NAME="warp-cluster"
BUCKET_NAME="princer-gcsfuse-test"

# Setup GKE
setup_cluster() {
    echo "[INFO] Setting up GKE connection..."
    gcloud config set project $PROJECT_ID
    gcloud container clusters get-credentials $CLUSTER_NAME --region $CLUSTER_REGION
}

# Monitor CPU and memory usage of a pod
monitor_resources() {
    local pod_name="$1"
    local job_name="$2"
    
    local max_cpu="0"
    local max_memory="0"
    local monitoring_count=0
    
    echo "[INFO] Starting resource monitoring for Job ID: ${job_name}, Pod: ${pod_name}"
    
    # Start monitoring immediately but wait for pod to be ready first
    local attempts=0
    while [ $attempts -lt 30 ]; do
        pod_status=$(kubectl get pod "$pod_name" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
        if [ "$pod_status" = "Running" ]; then
            echo "[INFO] Pod is running, starting resource monitoring"
            break
        fi
        sleep 1
        attempts=$((attempts + 1))
    done
    
    if [ $attempts -eq 30 ]; then
        echo "[WARNING] Pod never reached Running state within timeout"
        echo "0" > "/tmp/max_cpu_${job_name}"
        echo "0" > "/tmp/max_memory_${job_name}"
        return
    fi
    
    # Remove debug output and make it simpler - just capture any metrics we can
    local max_cpu=0
    local max_memory=0
    local max_fio_cpu=0
    local max_fio_memory=0
    local max_gcsfuse_cpu=0
    local max_gcsfuse_memory=0
    
    # Monitor resources while pod is running
    while true; do
        # Check pod status first
        pod_status=$(kubectl get pod "$pod_name" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
        
        # Break if pod is no longer running
        if [ "$pod_status" != "Running" ]; then
            echo "[INFO] Pod status changed to: $pod_status, stopping resource monitoring"
            break
        fi
        
        # Get overall pod metrics
        resource_output=$(kubectl top pod "$pod_name" --no-headers 2>/dev/null || echo "")
        
        if [[ -n "$resource_output" ]]; then
            cpu_val=$(echo "$resource_output" | awk '{print $2}' | sed 's/m$//')
            mem_val=$(echo "$resource_output" | awk '{print $3}' | sed 's/Mi$//')
            
            # Check if values are numeric and update max
            if [[ "$cpu_val" =~ ^[0-9]+$ ]] && (( cpu_val > max_cpu )); then
                max_cpu=$cpu_val
            fi
            
            if [[ "$mem_val" =~ ^[0-9]+$ ]] && (( mem_val > max_memory )); then
                max_memory=$mem_val
            fi
        fi
        
        # Get per-container metrics
        container_output=$(kubectl top pod "$pod_name" --containers --no-headers 2>/dev/null || echo "")
        
        if [[ -n "$container_output" ]]; then
            # Debug: show what container output looks like
            echo "[DEBUG] Container metrics output:"
            echo "$container_output"
            
            # Parse individual container metrics
            while IFS= read -r line; do
                container_name=$(echo "$line" | awk '{print $2}')
                
                if [[ "$container_name" == "fio-test" ]]; then
                    fio_cpu=$(echo "$line" | awk '{print $3}' | sed 's/m$//')
                    fio_mem=$(echo "$line" | awk '{print $4}' | sed 's/Mi$//')
                    
                    if [[ "$fio_cpu" =~ ^[0-9]+$ ]] && (( fio_cpu > max_fio_cpu )); then
                        max_fio_cpu=$fio_cpu
                    fi
                    
                    if [[ "$fio_mem" =~ ^[0-9]+$ ]] && (( fio_mem > max_fio_memory )); then
                        max_fio_memory=$fio_mem
                    fi
                elif [[ "$container_name" == "gke-gcsfuse-sidecar" ]]; then
                    gcsfuse_cpu=$(echo "$line" | awk '{print $3}' | sed 's/m$//')
                    gcsfuse_mem=$(echo "$line" | awk '{print $4}' | sed 's/Mi$//')
                    
                    if [[ "$gcsfuse_cpu" =~ ^[0-9]+$ ]] && (( gcsfuse_cpu > max_gcsfuse_cpu )); then
                        max_gcsfuse_cpu=$gcsfuse_cpu
                    fi
                    
                    if [[ "$gcsfuse_mem" =~ ^[0-9]+$ ]] && (( gcsfuse_mem > max_gcsfuse_memory )); then
                        max_gcsfuse_memory=$gcsfuse_mem
                    fi
                fi
            done <<< "$container_output"
        fi
        
        sleep 2  # Check every 2 seconds
    done
    
    echo "[INFO] Resource monitoring completed."
    echo "[INFO] Overall Pod - Max CPU: ${max_cpu}m, Max Memory: ${max_memory}Mi"
    echo "[INFO] FIO Container - Max CPU: ${max_fio_cpu}m, Max Memory: ${max_fio_memory}Mi"  
    echo "[INFO] GCS FUSE Container - Max CPU: ${max_gcsfuse_cpu}m, Max Memory: ${max_gcsfuse_memory}Mi"
    
    # Save max values to temp files
    echo "$max_cpu" > "/tmp/max_cpu_${job_name}"
    echo "$max_memory" > "/tmp/max_memory_${job_name}"
    echo "$max_fio_cpu" > "/tmp/max_fio_cpu_${job_name}"
    echo "$max_fio_memory" > "/tmp/max_fio_memory_${job_name}"
    echo "$max_gcsfuse_cpu" > "/tmp/max_gcsfuse_cpu_${job_name}"
    echo "$max_gcsfuse_memory" > "/tmp/max_gcsfuse_memory_${job_name}"
    echo "$max_memory" > "/tmp/max_memory_${job_name}"
}

# Run single FIO job with multiple iterations inside
run_fio_job() {
    local job_name="fio-test-$(date +%s)"
    
    echo "[INFO] =============================================="
    echo "[INFO] Starting FIO test with $ITERATIONS iterations"
    echo "[INFO] GKE Job ID: ${job_name}"
    echo "[INFO] =============================================="
    
    # Create the FIO test script
    create_fio_script
    
    # Create Kubernetes job YAML
    create_job_yaml "$job_name"
    
    # Deploy job
    kubectl apply -f /tmp/fio-job.yaml
    
    # Wait for job to complete and monitor resources
    echo "[INFO] Waiting for job to complete (Job ID: ${job_name})..."
    
    # Wait for pod to be created and get its name
    local pod_name=""
    while [ -z "$pod_name" ]; do
        pod_name=$(kubectl get pods -l job-name=${job_name} -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
        sleep 1
    done
    
    echo "[INFO] Pod created: ${pod_name}"
    
    # Start resource monitoring in background
    monitor_resources "$pod_name" "$job_name" &
    local monitor_pid=$!
    
    # Wait for job completion, timeout 2 hrs
    kubectl wait --for=condition=complete job/${job_name} --timeout=7200s
    
    # Let monitoring run for a bit longer to capture any remaining metrics
    sleep 10
    kill $monitor_pid 2>/dev/null || true
    wait $monitor_pid 2>/dev/null || true
    
    # Get final resource usage
    local max_cpu=$(cat "/tmp/max_cpu_${job_name}" 2>/dev/null || echo "0")
    local max_memory=$(cat "/tmp/max_memory_${job_name}" 2>/dev/null || echo "0")
    local max_fio_cpu=$(cat "/tmp/max_fio_cpu_${job_name}" 2>/dev/null || echo "0")
    local max_fio_memory=$(cat "/tmp/max_fio_memory_${job_name}" 2>/dev/null || echo "0")
    local max_gcsfuse_cpu=$(cat "/tmp/max_gcsfuse_cpu_${job_name}" 2>/dev/null || echo "0")
    local max_gcsfuse_memory=$(cat "/tmp/max_gcsfuse_memory_${job_name}" 2>/dev/null || echo "0")
    
    echo "[INFO] Results (Job ID: ${job_name}, Pod: ${pod_name}):"
    echo "=============================================="
    kubectl logs $pod_name
    echo "=============================================="
    echo "[INFO] Resource Usage (Job ID: ${job_name}):"
    echo "  Overall Pod:"
    echo "    Max CPU: ${max_cpu}m"
    echo "    Max Memory: ${max_memory}Mi"
    echo "  FIO Container:"
    echo "    Max CPU: ${max_fio_cpu}m"
    echo "    Max Memory: ${max_fio_memory}Mi"
    echo "  GCS FUSE Sidecar Container:"
    echo "    Max CPU: ${max_gcsfuse_cpu}m"
    echo "    Max Memory: ${max_gcsfuse_memory}Mi"
    echo "=============================================="
    
    # Cleanup
    echo "[INFO] Cleaning up Job ID: ${job_name}"
    kubectl delete job ${job_name}
    kubectl delete configmap "fio-script-${job_name}"
    rm -f /tmp/fio-job.yaml /tmp/fio-test-script.sh
    rm -f "/tmp/max_cpu_${job_name}" "/tmp/max_memory_${job_name}"
    rm -f "/tmp/max_fio_cpu_${job_name}" "/tmp/max_fio_memory_${job_name}"
    rm -f "/tmp/max_gcsfuse_cpu_${job_name}" "/tmp/max_gcsfuse_memory_${job_name}"
}

# Create the FIO test script that will run inside the container
create_fio_script() {
    cat > /tmp/fio-test-script.sh << 'SCRIPT_EOF'
#!/bin/bash
set -e

# Install required packages
apt update -qq > /dev/null
apt install -qq -y fio jq bc gettext-base > /dev/null

# Print test configuration
echo "Starting FIO test..."
echo "Files: $NUM_FILES x $FILE_SIZE"
echo "Mode: $MODE, Block Size: $BLOCK_SIZE"
echo "Iterations: $ITERATIONS"
echo ""
mkdir -p /data/$FILE_SIZE

# Create FIO configuration file
create_fio_config() {
    cat > /tmp/fio.conf << FIO_CONFIG_EOF
[global]
ioengine=libaio
direct=0
verify=0
bs=$BLOCK_SIZE
iodepth=2
runtime=120s
time_based=0
fadvise_hint=0
nrfiles=$NUM_FILES
thread=1
openfiles=1
group_reporting=1
filename_format=test.\$jobnum.\$filenum

[test]
rw=$MODE
filesize=$FILE_SIZE
directory=/data/$FILE_SIZE
numjobs=1
FIO_CONFIG_EOF
}

# Create the FIO config
create_fio_config

echo "Running FIO config:"
cat /tmp/fio.conf
echo ""

# Arrays to store results from multiple iterations
declare -a iops_results
declare -a bw_results

# Run FIO multiple times
for i in $(seq 1 $ITERATIONS); do
    echo "Running FIO iteration $i/$ITERATIONS"
    
    json_output="/tmp/fio-result-${i}.json"
    fio /tmp/fio.conf --output-format=json --output="$json_output"
    
    if [ -f "$json_output" ]; then
        echo "FIO iteration $i completed"
        
        # Parse JSON results
        read_iops=$(jq -r '.jobs[0].read.iops // 0' "$json_output")
        read_bw_kbs=$(jq -r '.jobs[0].read.bw // 0' "$json_output")
        write_iops=$(jq -r '.jobs[0].write.iops // 0' "$json_output")
        write_bw_kbs=$(jq -r '.jobs[0].write.bw // 0' "$json_output")
        
        # Convert bandwidth from KiB/s (FIO output) to MB/s (decimal)
        # FIO outputs in KiB/s (1024 bytes), convert to MB/s (1000000 bytes)
        read_bw_mbs=$(echo "scale=2; ($read_bw_kbs * 1024) / 1000000" | bc -l)
        write_bw_mbs=$(echo "scale=2; ($write_bw_kbs * 1024) / 1000000" | bc -l)
        
        # Store results based on operation type
        if (( $(echo "$read_iops > 0" | bc -l) )); then
            iops_results[$i]=$read_iops
            bw_results[$i]=$read_bw_mbs
            echo "Read IOPS: $read_iops, BW: ${read_bw_mbs} MB/s"
        elif (( $(echo "$write_iops > 0" | bc -l) )); then
            iops_results[$i]=$write_iops
            bw_results[$i]=$write_bw_mbs
            echo "Write IOPS: $write_iops, BW: ${write_bw_mbs} MB/s"
        fi
    else
        echo "ERROR: FIO iteration $i failed"
    fi
    
    echo ""
done

# Calculate and display averages
echo "RESULTS:"
if [ ${#iops_results[@]} -gt 0 ]; then
    total_iops=0
    total_bw=0
    
    # Sum all IOPS and bandwidth values
    for val in "${iops_results[@]}"; do
        total_iops=$(echo "$total_iops + $val" | bc -l)
    done
    
    for val in "${bw_results[@]}"; do
        total_bw=$(echo "$total_bw + $val" | bc -l)
    done
    
    # Calculate averages
    avg_iops=$(echo "scale=2; $total_iops / ${#iops_results[@]}" | bc -l)
    avg_bw=$(echo "scale=2; $total_bw / ${#bw_results[@]}" | bc -l)
    
    echo "Average IOPS: $avg_iops"
    echo "Average Bandwidth: $avg_bw MB/s"
    echo "Successful iterations: ${#iops_results[@]} / $ITERATIONS"
fi

echo "Test completed!"
SCRIPT_EOF
}

# Create Kubernetes job YAML
create_job_yaml() {
    local job_name="$1"
    
    cat > /tmp/fio-job.yaml << YAML_EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: ${job_name}
spec:
  template:
    metadata:
      annotations:
        gke-gcsfuse/volumes: "true"
        gke-gcsfuse/cpu-limit: "0"
        gke-gcsfuse/memory-limit: "0"
        gke-gcsfuse/ephemeral-storage-limit: "0"
    spec:
      restartPolicy: Never
      serviceAccountName: warp-benchmark
      containers:
      - name: gke-gcsfuse-sidecar
        image: gcr.io/gcs-tess/princer_google_com_20250903183340/gcs-fuse-csi-driver-sidecar-mounter:v1.17.0-86-g31041c94
      - name: fio-test
        image: ubuntu:22.04
        env:
        - name: NUM_FILES
          value: "${NUM_FILES}"
        - name: FILE_SIZE
          value: "${FILE_SIZE}"
        - name: ITERATIONS
          value: "${ITERATIONS}"
        - name: MODE
          value: "${MODE}"
        - name: BLOCK_SIZE
          value: "${BLOCK_SIZE}"
        command: ["bash", "/tmp/fio-test-script.sh"]
        volumeMounts:
        - name: gcs-fuse-volume
          mountPath: /data
        - name: script-volume
          mountPath: /tmp/fio-test-script.sh
          subPath: fio-test-script.sh
      volumes:
      - name: gcs-fuse-volume
        csi:
          driver: gcsfuse.csi.storage.gke.io
          readOnly: false
          volumeAttributes:
            bucketName: "${BUCKET_NAME}"
            mountOptions: "${MOUNT_OPTIONS},read_ahead_kb=1024"
      - name: script-volume
        configMap:
          name: fio-script-${job_name}
          defaultMode: 0755
YAML_EOF

    # Create ConfigMap with the script
    kubectl create configmap "fio-script-${job_name}" --from-file=fio-test-script.sh=/tmp/fio-test-script.sh
}

# Show usage
show_usage() {
    cat << EOF
Usage: $0 [num_files] [file_size] [iterations] [mode] [block_size] [mount_options]

Parameters:
  num_files     Number of files (default: 100)
  file_size     Size per file (default: 256K)
  iterations    Number of test runs within single job (default: 3)
  mode          I/O mode (default: read) - read, write, randread, randwrite
  block_size    Block size (default: 1M)
  mount_options GCS FUSE mount options (default: "implicit-dirs,metadata-cache:ttl-secs:-1,metadata-cache:stat-cache-max-size-mb:-1,metadata-cache:type-cache-max-size-mb:-1,log-severity=trace")

Examples:
  $0                           # Default: 100 files x 256K, 3 iterations
  $0 50 1M 5                   # 50 files x 1M, 5 iterations  
  $0 100 256K 3 randwrite 4K   # 100 files x 256K, 3 iterations, random write, 4K blocks
  $0 10 512K 2 read 64K "implicit-dirs,metadata-cache:ttl-secs:60" # Custom mount options

Common Mount Options:
  - implicit-dirs                    # Enable implicit directories
  - metadata-cache:ttl-secs:60       # Set metadata cache TTL to 60 seconds
  - metadata-cache:ttl-secs:-1       # Disable metadata cache TTL
  - log-severity=trace               # Enable trace logging
  - log-severity=info                # Set log level to info
  - max-conns-per-host:100           # Maximum connections per host

EOF
}

# Main execution function
main() {
    # Handle help requests
    if [ "$1" == "--help" ] || [ "$1" == "-h" ]; then
        show_usage
        exit 0
    fi

    echo "[INFO] Simple FIO Benchmark for GKE"
    echo "[INFO] Files: $NUM_FILES x $FILE_SIZE"
    echo "[INFO] Mode: $MODE, Block Size: $BLOCK_SIZE"
    echo "[INFO] Iterations: $ITERATIONS"
    echo "[INFO] Mount Options: $MOUNT_OPTIONS"
    echo ""
    
    # Check dependencies
    if ! command -v kubectl >/dev/null 2>&1; then
        echo "[ERROR] kubectl not found"
        exit 1
    fi
    
    if ! command -v gcloud >/dev/null 2>&1; then
        echo "[ERROR] gcloud not found"
        exit 1
    fi
    
    # Setup cluster connection
    setup_cluster
    
    # Run the FIO job
    run_fio_job
    
    echo "[INFO] FIO Benchmark Complete!"
}

# Execute main function with all arguments
main "$@"
