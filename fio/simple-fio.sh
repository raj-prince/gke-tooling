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
BUCKET_NAME="gcs-fuse-warp-test-bucket"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

# Setup GKE
setup_cluster() {
    print_info "Setting up GKE connection..."
    gcloud config set project $PROJECT_ID
    gcloud container clusters get-credentials $CLUSTER_NAME --region $CLUSTER_REGION
}

# Run single FIO job with multiple iterations inside
run_fio_job() {
    local job_name="fio-test-$(date +%s)"
    
    print_info "Running FIO test with $ITERATIONS iterations (Job: $job_name)"
    
    # Create very simple YAML job without ConfigMap complexity
    cat > /tmp/fio-job.yaml << EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: ${job_name}
spec:
  template:
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
        command: ["bash", "-c"]
        args: ["apt-get update -qq && apt-get install -y fio jq bc gettext-base && echo 'Starting FIO test...' && echo 'Files: '\$NUM_FILES' x '\$FILE_SIZE && echo 'Mode: '\$MODE', Block Size: '\$BLOCK_SIZE && echo 'Iterations: '\$ITERATIONS && echo '' && cat > /tmp/fio.conf.template << 'FIOEND' && echo '[global]' >> /tmp/fio.conf && echo 'ioengine=libaio' >> /tmp/fio.conf && echo 'direct=1' >> /tmp/fio.conf && echo 'verify=0' >> /tmp/fio.conf && echo 'bs='\$BLOCK_SIZE >> /tmp/fio.conf && echo 'iodepth=64' >> /tmp/fio.conf && echo 'runtime=30s' >> /tmp/fio.conf && echo 'time_based=1' >> /tmp/fio.conf && echo 'nrfiles='\$NUM_FILES >> /tmp/fio.conf && echo 'thread=1' >> /tmp/fio.conf && echo 'group_reporting=1' >> /tmp/fio.conf && echo 'filename_format=test.\$jobnum.\$filenum' >> /tmp/fio.conf && echo '' >> /tmp/fio.conf && echo '[test]' >> /tmp/fio.conf && echo 'rw='\$MODE >> /tmp/fio.conf && echo 'filesize='\$FILE_SIZE >> /tmp/fio.conf && echo 'directory=/data' >> /tmp/fio.conf && echo 'numjobs=1' >> /tmp/fio.conf && echo 'Running FIO config:' && cat /tmp/fio.conf && echo '' && declare -a iops_results && declare -a bw_results && for i in \$(seq 1 \$ITERATIONS); do echo 'Running FIO iteration '\$i'/'\$ITERATIONS; json_output=/tmp/fio-result-\${i}.json; fio /tmp/fio.conf --output-format=json --output=\$json_output; if [ -f \$json_output ]; then echo 'FIO iteration '\$i' completed'; read_iops=\$(jq -r '.jobs[0].read.iops // 0' \$json_output); read_bw_kbs=\$(jq -r '.jobs[0].read.bw // 0' \$json_output); write_iops=\$(jq -r '.jobs[0].write.iops // 0' \$json_output); write_bw_kbs=\$(jq -r '.jobs[0].write.bw // 0' \$json_output); read_bw_mbs=\$(echo \"scale=2; \$read_bw_kbs / 1024\" | bc -l); write_bw_mbs=\$(echo \"scale=2; \$write_bw_kbs / 1024\" | bc -l); if (( \$(echo \"\$read_iops > 0\" | bc -l) )); then iops_results[\$i]=\$read_iops; bw_results[\$i]=\$read_bw_mbs; echo 'Read IOPS: '\$read_iops', BW: '\${read_bw_mbs}' MB/s'; elif (( \$(echo \"\$write_iops > 0\" | bc -l) )); then iops_results[\$i]=\$write_iops; bw_results[\$i]=\$write_bw_mbs; echo 'Write IOPS: '\$write_iops', BW: '\${write_bw_mbs}' MB/s'; fi; else echo 'ERROR: FIO iteration '\$i' failed'; fi; echo ''; sleep 5; done && echo 'RESULTS:' && if [ \${#iops_results[@]} -gt 0 ]; then total_iops=0; total_bw=0; for val in \"\${iops_results[@]}\"; do total_iops=\$(echo \"\$total_iops + \$val\" | bc -l); done; for val in \"\${bw_results[@]}\"; do total_bw=\$(echo \"\$total_bw + \$val\" | bc -l); done; avg_iops=\$(echo \"scale=2; \$total_iops / \${#iops_results[@]}\" | bc -l); avg_bw=\$(echo \"scale=2; \$total_bw / \${#bw_results[@]}\" | bc -l); echo 'Average IOPS: '\$avg_iops; echo 'Average Bandwidth: '\$avg_bw' MB/s'; echo 'Successful iterations: '\${#iops_results[@]}' / '\$ITERATIONS; fi && echo 'Test completed!'"]
        volumeMounts:
        - name: test-volume
          mountPath: /data
      volumes:
      - name: test-volume
        emptyDir: {}
EOF

    # Deploy job
    kubectl apply -f /tmp/fio-job.yaml
    
    # Wait for completion
    print_info "Waiting for job to complete..."
    kubectl wait --for=condition=complete job/${job_name} --timeout=600s
    
    # Get and show results
    local pod_name=$(kubectl get pods -l job-name=${job_name} -o jsonpath='{.items[0].metadata.name}')
    
    print_info "Results:"
    echo "=============================================="
    kubectl logs $pod_name
    echo "=============================================="
    
    # Cleanup
    kubectl delete job ${job_name}
    rm -f /tmp/fio-job.yaml
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

print_info "Starting FIO Benchmark"
print_info "Configuration: $NUM_FILES files x $FILE_SIZE, $ITERATIONS iterations"
print_info "Mode: $MODE, Block Size: $BLOCK_SIZE"
echo ""

# Check dependencies
if ! command -v kubectl >/dev/null 2>&1; then
    print_error "kubectl not found"
    exit 1
fi

# Setup cluster
setup_cluster

# Run single job with multiple FIO iterations inside
run_fio_job

print_info "FIO Benchmark Complete!"
