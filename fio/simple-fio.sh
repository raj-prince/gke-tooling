#!/bin/bash

# Simple FIO Benchmark Runner for GKE
# Usage: ./simple-fio.sh [num_files] [file_size] [iterations]

set -e

# Default values
NUM_FILES=${1:-100}
FILE_SIZE=${2:-256K}
ITERATIONS=${3:-3}
MODE=${4:-read}
BLOCK_SIZE=${5:-1M}

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

# Run single FIO job with multiple iterations inside
run_fio_job() {
    local job_name="fio-test-$(date +%s)"
    
    echo "[INFO] Running FIO test with $ITERATIONS iterations (Job: $job_name)"
    
    # Create the FIO test script
    create_fio_script
    
    # Create Kubernetes job YAML
    create_job_yaml "$job_name"
    
    # Deploy job
    kubectl apply -f /tmp/fio-job.yaml
    
    # Wait for completion and show results
    echo "[INFO] Waiting for job to complete..."
    kubectl wait --for=condition=complete job/${job_name} --timeout=600s
    
    # Get and show results
    local pod_name=$(kubectl get pods -l job-name=${job_name} -o jsonpath='{.items[0].metadata.name}')
    
    echo "[INFO] Results:"
    echo "=============================================="
    kubectl logs $pod_name
    echo "=============================================="
    
    # Cleanup
    kubectl delete job ${job_name}
    kubectl delete configmap "fio-script-${job_name}"
    rm -f /tmp/fio-job.yaml /tmp/fio-test-script.sh
}

# Create the FIO test script that will run inside the container
create_fio_script() {
    cat > /tmp/fio-test-script.sh << 'SCRIPT_EOF'
#!/bin/bash
set -e

# Install required packages
apt-get update -qq
apt-get install -y fio jq bc gettext-base

# Print test configuration
echo "Starting FIO test..."
echo "Files: $NUM_FILES x $FILE_SIZE"
echo "Mode: $MODE, Block Size: $BLOCK_SIZE"
echo "Iterations: $ITERATIONS"
echo ""

# Create FIO configuration file
create_fio_config() {
    cat > /tmp/fio.conf << FIO_CONFIG_EOF
[global]
ioengine=libaio
direct=1
verify=0
bs=$BLOCK_SIZE
iodepth=64
runtime=30s
time_based=1
nrfiles=$NUM_FILES
thread=1
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
        
        # Convert bandwidth from KB/s to MB/s
        read_bw_mbs=$(echo "scale=2; $read_bw_kbs / 1024" | bc -l)
        write_bw_mbs=$(echo "scale=2; $write_bw_kbs / 1024" | bc -l)
        
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
    sleep 5
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
            mountOptions: "implicit-dirs,metadata-cache:ttl-secs:-1,metadata-cache:stat-cache-max-size-mb:-1,metadata-cache:type-cache-max-size-mb:-1,log-severity=trace"
      - name: script-volume
        configMap:
          name: fio-script-${job_name}
          defaultMode: 0755
YAML_EOF

    # Create ConfigMap with the script
    kubectl create configmap "fio-script-${job_name}" --from-file=fio-test-script.sh=/tmp/fio-test-script.sh
    
    # Deploy job
    kubectl apply -f /tmp/fio-job.yaml
    
    # Wait for completion and show results
    echo "[INFO] Waiting for job to complete..."
    kubectl wait --for=condition=complete job/${job_name} --timeout=600s
    
    # Get and show results
    local pod_name=$(kubectl get pods -l job-name=${job_name} -o jsonpath='{.items[0].metadata.name}')
    
    echo "[INFO] Results:"
    echo "=============================================="
    kubectl logs $pod_name
    echo "=============================================="
    
    # Cleanup
    kubectl delete job ${job_name}
    kubectl delete configmap "fio-script-${job_name}"
    rm -f /tmp/fio-job.yaml /tmp/fio-test-script.sh
}

# Show usage
show_usage() {
    cat << EOF
Usage: $0 [num_files] [file_size] [iterations] [mode] [block_size]

Parameters:
  num_files    Number of files (default: 100)
  file_size    Size per file (default: 256K)
  iterations   Number of test runs within single job (default: 3)
  mode         I/O mode (default: read) - read, write, randread, randwrite
  block_size   Block size (default: 1M)

Examples:
  $0                           # 100 files x 256K, 3 iterations
  $0 50 1M 5                   # 50 files x 1M, 5 iterations  
  $0 100 256K 3 randwrite 4K   # 100 files x 256K, 3 iterations, random write, 4K blocks

EOF
}

# Main execution
if [ "$1" == "--help" ] || [ "$1" == "-h" ]; then
    show_usage
    exit 0
fi

echo "[INFO] Starting FIO Benchmark"
echo "[INFO] Configuration: $NUM_FILES files x $FILE_SIZE, $ITERATIONS iterations"
echo "[INFO] Mode: $MODE, Block Size: $BLOCK_SIZE"
echo ""

# Check dependencies
if ! command -v kubectl >/dev/null 2>&1; then
    echo "[ERROR] kubectl not found"
    exit 1
fi

# Setup cluster
setup_cluster

# Run single job with multiple FIO iterations inside
run_fio_job

echo "[INFO] FIO Benchmark Complete!"
