#!/bin/bash

# FIO Benchmark Job Runner for GKE
# This script deploys and manages FIO jobs in your GKE environment

set -e

# Default environment variables (can be overridden)
export PROJECT_ID=${PROJECT_ID:-"gcs-tess"}
export CLUSTER_REGION=${CLUSTER_REGION:-"us-central1-c"}
export CLUSTER_NAME=${CLUSTER_NAME:-"warp-cluster"}
export BUCKET_NAME=${BUCKET_NAME:-"gcs-fuse-warp-test-bucket"}

# FIO job configuration defaults
export FIO_RUNTIME=${FIO_RUNTIME:-"60"}
export FIO_BLOCKSIZE=${FIO_BLOCKSIZE:-"4k"}
export FIO_IODEPTH=${FIO_IODEPTH:-"32"}
export FIO_NUMJOBS=${FIO_NUMJOBS:-"4"}
export FIO_RW_MODE=${FIO_RW_MODE:-"randread"}
export FIO_SIZE=${FIO_SIZE:-"1G"}
export FIO_ENGINE=${FIO_ENGINE:-"libaio"}
export FIO_DIRECT=${FIO_DIRECT:-"1"}

# Job naming
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
JOB_NAME=${JOB_NAME:-"fio-benchmark-${TIMESTAMP}"}

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_header() {
    echo -e "${BLUE}=== $1 ===${NC}"
}

# Function to show usage
show_usage() {
    cat << EOF
Usage: $0 [COMMAND] [OPTIONS]

Commands:
    deploy      Deploy the FIO benchmark job
    status      Check the status of FIO jobs
    logs        Show logs from the latest FIO job
    delete      Delete FIO jobs
    clean       Clean up completed/failed jobs
    help        Show this help message

Environment Variables (FIO Configuration):
    FIO_RUNTIME      Test duration in seconds (default: 60)
    FIO_BLOCKSIZE    Block size (default: 4k)
    FIO_IODEPTH      IO depth (default: 32)
    FIO_NUMJOBS      Number of parallel jobs (default: 4)
    FIO_RW_MODE      Read/write mode (default: randread)
                     Options: read, write, randread, randwrite, rw, randrw
    FIO_SIZE         File size per job (default: 1G)
    FIO_ENGINE       IO engine (default: libaio)
    FIO_DIRECT       Direct IO (default: 1)

Examples:
    # Run default benchmark
    $0 deploy
    
    # Run write benchmark with custom settings
    FIO_RW_MODE=randwrite FIO_SIZE=2G FIO_RUNTIME=120 $0 deploy
    
    # Check status
    $0 status
    
    # View logs
    $0 logs

EOF
}

# Function to setup GKE credentials
setup_gke() {
    print_header "Setting up GKE Environment"
    
    print_status "Setting project: $PROJECT_ID"
    gcloud config set project $PROJECT_ID
    
    print_status "Getting cluster credentials for: $CLUSTER_NAME in $CLUSTER_REGION"
    gcloud container clusters get-credentials $CLUSTER_NAME --region $CLUSTER_REGION
    
    print_status "Verifying cluster connection"
    kubectl cluster-info --request-timeout=10s > /dev/null
    if [ $? -eq 0 ]; then
        print_status "Successfully connected to GKE cluster"
    else
        print_error "Failed to connect to GKE cluster"
        exit 1
    fi
}

# Function to deploy FIO job
deploy_job() {
    print_header "Deploying FIO Benchmark Job"
    
    # Setup GKE
    setup_gke
    
    # Show configuration
    print_header "FIO Configuration"
    echo "Job Name: $JOB_NAME"
    echo "Runtime: $FIO_RUNTIME seconds"
    echo "Block Size: $FIO_BLOCKSIZE"
    echo "IO Depth: $FIO_IODEPTH"
    echo "Num Jobs: $FIO_NUMJOBS"
    echo "RW Mode: $FIO_RW_MODE"
    echo "File Size: $FIO_SIZE"
    echo "IO Engine: $FIO_ENGINE"
    echo "Direct IO: $FIO_DIRECT"
    echo "Bucket: $BUCKET_NAME"
    
    # Create temporary job manifest with custom values
    TEMP_JOB_FILE="/tmp/fio-job-${TIMESTAMP}.yaml"
    
    print_status "Creating job manifest: $TEMP_JOB_FILE"
    
    # Replace values in the template
    sed -e "s/name: fio-benchmark-job/name: ${JOB_NAME}/" \
        -e "s/value: \"60\"/value: \"${FIO_RUNTIME}\"/" \
        -e "s/value: \"4k\"/value: \"${FIO_BLOCKSIZE}\"/" \
        -e "s/value: \"32\"/value: \"${FIO_IODEPTH}\"/" \
        -e "s/value: \"4\"/value: \"${FIO_NUMJOBS}\"/" \
        -e "s/value: \"randread\"/value: \"${FIO_RW_MODE}\"/" \
        -e "s/value: \"1G\"/value: \"${FIO_SIZE}\"/" \
        -e "s/value: \"libaio\"/value: \"${FIO_ENGINE}\"/" \
        -e "s/value: \"1\"/value: \"${FIO_DIRECT}\"/" \
        -e "s/value: \"gcs-fuse-warp-test-bucket\"/value: \"${BUCKET_NAME}\"/" \
        -e "s/value: \"supercomputer-testing\"/value: \"${PROJECT_ID}\"/" \
        fio-job.yaml > "$TEMP_JOB_FILE"
    
    # Deploy the job
    print_status "Deploying job to Kubernetes"
    kubectl apply -f "$TEMP_JOB_FILE"
    
    print_status "Job deployed successfully: $JOB_NAME"
    print_status "Use '$0 status' to check progress"
    print_status "Use '$0 logs' to view logs"
    
    # Cleanup temp file
    rm -f "$TEMP_JOB_FILE"
}

# Function to check job status
check_status() {
    print_header "FIO Job Status"
    
    setup_gke
    
    print_status "All FIO jobs:"
    kubectl get jobs -l app=fio-benchmark -o wide
    
    echo ""
    print_status "FIO pods:"
    kubectl get pods -l app=fio-benchmark -o wide
    
    echo ""
    print_status "Recent events:"
    kubectl get events --sort-by=.metadata.creationTimestamp | grep -i fio | tail -10 || echo "No FIO-related events found"
}

# Function to show logs
show_logs() {
    print_header "FIO Job Logs"
    
    setup_gke
    
    # Find the most recent fio pod
    POD_NAME=$(kubectl get pods -l app=fio-benchmark --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1].metadata.name}' 2>/dev/null)
    
    if [ -z "$POD_NAME" ]; then
        print_warning "No FIO benchmark pods found"
        return 1
    fi
    
    print_status "Showing logs for pod: $POD_NAME"
    kubectl logs "$POD_NAME" -f
}

# Function to delete jobs
delete_jobs() {
    print_header "Deleting FIO Jobs"
    
    setup_gke
    
    print_status "Deleting all FIO benchmark jobs..."
    kubectl delete jobs -l app=fio-benchmark
    
    print_status "Jobs deleted"
}

# Function to clean up completed/failed jobs
clean_jobs() {
    print_header "Cleaning Up Completed/Failed Jobs"
    
    setup_gke
    
    print_status "Cleaning up completed jobs..."
    kubectl delete jobs -l app=fio-benchmark --field-selector=status.successful=1
    
    print_status "Cleaning up failed jobs..."
    kubectl delete jobs -l app=fio-benchmark --field-selector=status.failed=1
    
    print_status "Cleanup completed"
}

# Main script logic
case "${1:-deploy}" in
    "deploy")
        deploy_job
        ;;
    "status")
        check_status
        ;;
    "logs")
        show_logs
        ;;
    "delete")
        delete_jobs
        ;;
    "clean")
        clean_jobs
        ;;
    "help"|"-h"|"--help")
        show_usage
        ;;
    *)
        print_error "Unknown command: $1"
        show_usage
        exit 1
        ;;
esac
