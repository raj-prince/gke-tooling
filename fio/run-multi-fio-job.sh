#!/bin/bash

# Multi File Size FIO Benchmark Runner for GKE
# This script runs FIO tests across different file sizes
# Usage: ./run-multi-fio-job.sh [iterations] [mode] [block_size] [parallel_mode] [max_parallel_jobs] [mount_options]

set -e

# Default values
ITERATIONS=${1:-2}
MODE=${2:-read}
BLOCK_SIZE=${3:-1M}
PARALLEL_MODE=${4:-false}  # Set to true to enable parallel execution
MAX_PARALLEL_JOBS=${5:-3}  # Maximum parallel jobs when parallel mode is enabled
MOUNT_OPTIONS=${6:-"implicit-dirs,metadata-cache:ttl-secs:60,enable-buffered-read,client-protocol=grpc,log-severity=info,read-block-size-mb=16,read-max-blocks-per-handle=20,read-global-max-blocks=40"}

# Array of file sizes to test
FILE_SIZES=(
    "64K"
    "256K" 
    "1M"
    "4M"
    "16M"
    "64M"
    "100M"
    "256M"
    "1G"
    "4G"
    "10G"
)

# Results storage
declare -A results_iops
declare -A results_bandwidth
declare -A results_max_cpu
declare -A results_max_memory
declare -A results_fio_cpu
declare -A results_fio_memory
declare -A results_gcsfuse_cpu
declare -A results_gcsfuse_memory
declare -A results_job_id

# Function to determine number of files based on file size
get_num_files_for_size() {
    local file_size="$1"
    
    case "$file_size" in
        "64K"|"256K")
            echo 400    # Many small files for better concurrency testing
            ;;
        "1M"|"4M")
            echo 200    # Moderate number of medium files
            ;;
        "16M"|"64M")
            echo 50     # Fewer medium-large files
            ;;
        "256M"|"512M")
            echo 30     # Fewer large files
            ;;
        "1G"|"2G"|"4G")
            echo 10     # Few very large files
            ;;
        "10G"|"20G")
            echo 4      # Very few huge files
            ;;
        *)
            echo 20     # Default fallback
            ;;
    esac
}

# Function to convert size string to bytes
convert_to_bytes() {
    local size="$1"
    local number=$(echo "$size" | sed 's/[^0-9.]//g')
    local unit=$(echo "$size" | sed 's/[0-9.]//g' | tr '[:lower:]' '[:upper:]')
    
    case "$unit" in
        "K"|"KB")
            echo $(echo "$number * 1024" | bc -l | cut -d'.' -f1)
            ;;
        "M"|"MB")
            echo $(echo "$number * 1024 * 1024" | bc -l | cut -d'.' -f1)
            ;;
        "G"|"GB")
            echo $(echo "$number * 1024 * 1024 * 1024" | bc -l | cut -d'.' -f1)
            ;;
        "T"|"TB")
            echo $(echo "$number * 1024 * 1024 * 1024 * 1024" | bc -l | cut -d'.' -f1)
            ;;
        *)
            # Assume bytes if no unit
            echo "$number"
            ;;
    esac
}

# Function to adjust block size if it's larger than file size
get_adjusted_block_size() {
    local file_size="$1"
    local block_size="$2"
    
    # Convert both to bytes for comparison
    local file_bytes=$(convert_to_bytes "$file_size")
    local block_bytes=$(convert_to_bytes "$block_size")
    
    # If block size is larger than file size, use file size as block size
    if [ "$block_bytes" -gt "$file_bytes" ]; then
        echo "$file_size"
    else
        echo "$block_size"
    fi
}

echo "==============================================="
echo "Multi File Size FIO Benchmark"
echo "==============================================="
echo "Configuration:"
echo "  Files per test: Dynamic based on file size"
echo "  Iterations per size: $ITERATIONS"
echo "  Mode: $MODE"
echo "  Block Size: $BLOCK_SIZE (auto-adjusted if larger than file size)"
echo "  Mount Options: $MOUNT_OPTIONS"
echo "  Parallel Mode: $PARALLEL_MODE"
if [ "$PARALLEL_MODE" = "true" ]; then
    echo "  Max Parallel Jobs: $MAX_PARALLEL_JOBS"
fi
echo ""
echo "File Size -> Number of Files mapping:"
for file_size in "${FILE_SIZES[@]}"; do
    num_files=$(get_num_files_for_size "$file_size")
    echo "  $file_size -> $num_files files"
done
echo "==============================================="
echo ""

# Function to extract results from run-single-fio-job.sh output
extract_results() {
    local output="$1"
    local iops=$(echo "$output" | grep "Average IOPS:" | tail -1 | awk '{print $3}')
    local bandwidth=$(echo "$output" | grep "Average Bandwidth:" | tail -1 | awk '{print $3}')
    
    # Extract job ID from the output - fixed version
    local job_id=$(echo "$output" | grep "GKE Job ID:" | awk '{print $5}' | head -1)
    
    # Debug: if job_id is empty, try alternative extraction methods
    if [ -z "$job_id" ]; then
        # Try to extract from "Job ID:" pattern (without [INFO])
        job_id=$(echo "$output" | grep -E "Job ID:" | awk '{print $4}' | head -1)
        
        # If still empty, try extracting from results line
        if [ -z "$job_id" ]; then
            job_id=$(echo "$output" | grep "Results (Job ID:" | sed -n 's/.*Job ID: \([^,]*\).*/\1/p' | head -1)
        fi
        
        # If still empty, set as unknown
        if [ -z "$job_id" ]; then
            job_id="UNKNOWN"
        fi
    fi
    
    # Extract overall pod resource usage
    local max_cpu=$(echo "$output" | grep "Overall Pod:" -A 2 | grep "Max CPU:" | awk '{print $3}' | sed 's/m$//')
    local max_memory=$(echo "$output" | grep "Overall Pod:" -A 2 | grep "Max Memory:" | awk '{print $3}' | sed 's/Mi$//')
    
    # Extract FIO container resource usage
    local fio_cpu=$(echo "$output" | grep "FIO Container:" -A 2 | grep "Max CPU:" | awk '{print $3}' | sed 's/m$//')
    local fio_memory=$(echo "$output" | grep "FIO Container:" -A 2 | grep "Max Memory:" | awk '{print $3}' | sed 's/Mi$//')
    
    # Extract GCS FUSE sidecar container resource usage
    local gcsfuse_cpu=$(echo "$output" | grep "GCS FUSE Sidecar Container:" -A 2 | grep "Max CPU:" | awk '{print $3}' | sed 's/m$//')
    local gcsfuse_memory=$(echo "$output" | grep "GCS FUSE Sidecar Container:" -A 2 | grep "Max Memory:" | awk '{print $3}' | sed 's/Mi$//')
    
    echo "$iops|$bandwidth|$max_cpu|$max_memory|$fio_cpu|$fio_memory|$gcsfuse_cpu|$gcsfuse_memory|$job_id"
}

# Function to run a single test and save results to file (for parallel mode)
run_single_test() {
    local file_size="$1"
    local dynamic_num_files="$2"
    local output_file="$3"
    
    echo "=============================================="
    echo "Starting Test: File Size $file_size ($dynamic_num_files files) [PID: $$]"
    echo "=============================================="
    
    # Get adjusted block size (use file size if block size is larger than file size)
    adjusted_block_size=$(get_adjusted_block_size "$file_size" "$BLOCK_SIZE")
    if [ "$adjusted_block_size" != "$BLOCK_SIZE" ]; then
        echo "  Note: Block size adjusted from $BLOCK_SIZE to $adjusted_block_size (file size limit)"
    fi
    
    # Run the FIO test with dynamic file count and adjusted block size
    output=$(./run-single-fio-job.sh "$dynamic_num_files" "$file_size" "$ITERATIONS" "$MODE" "$adjusted_block_size" "$MOUNT_OPTIONS" 2>&1)
    
    # Check if test was successful
    if echo "$output" | grep -q "FIO Benchmark Complete"; then
        echo "✓ Test completed successfully for $file_size"
        
        # Extract results
        result=$(extract_results "$output")
        
        # Debug: Show extracted job ID
        extracted_job_id=$(echo "$result" | cut -d'|' -f9)
        echo "[DEBUG] Extracted Job ID: '$extracted_job_id'"
        
        # Save results to temporary file
        echo "SUCCESS|$file_size|$dynamic_num_files|$result" > "$output_file"
        
        # Display immediate results
        iops=$(echo "$result" | cut -d'|' -f1)
        bandwidth=$(echo "$result" | cut -d'|' -f2)
        max_cpu=$(echo "$result" | cut -d'|' -f3)
        max_memory=$(echo "$result" | cut -d'|' -f4)
        fio_cpu=$(echo "$result" | cut -d'|' -f5)
        fio_memory=$(echo "$result" | cut -d'|' -f6)
        gcsfuse_cpu=$(echo "$result" | cut -d'|' -f7)
        gcsfuse_memory=$(echo "$result" | cut -d'|' -f8)
        job_id=$(echo "$result" | cut -d'|' -f9)
        
        echo "  Job ID: $job_id"
        echo "  Files: $dynamic_num_files"
        echo "  IOPS: $iops"
        echo "  Bandwidth: $bandwidth MB/s"
        echo "  Overall Pod - Max CPU: ${max_cpu}m, Max Memory: ${max_memory}Mi"
        echo "  FIO Container - Max CPU: ${fio_cpu}m, Max Memory: ${fio_memory}Mi"
        echo "  GCS FUSE Sidecar - Max CPU: ${gcsfuse_cpu}m, Max Memory: ${gcsfuse_memory}Mi"
        echo ""
    else
        echo "✗ Test failed for file size $file_size"
        echo "$output"
        echo ""
        
        # Save failure marker
        echo "FAILED|$file_size|$dynamic_num_files|FAILED|FAILED|FAILED|FAILED|FAILED|FAILED|FAILED|FAILED|FAILED" > "$output_file"
    fi
}

# Choose execution mode based on PARALLEL_MODE
if [ "$PARALLEL_MODE" = "true" ]; then
    echo "Running tests in PARALLEL mode..."
    
    # Create temporary directory for job outputs
    TEMP_DIR=$(mktemp -d)
    trap "rm -rf $TEMP_DIR" EXIT
    
    # Launch parallel tests
    echo "Launching parallel tests..."
    job_pids=()
    output_files=()
    
    for file_size in "${FILE_SIZES[@]}"; do
        # Get dynamic file count for this file size
        dynamic_num_files=$(get_num_files_for_size "$file_size")
        
        # Create unique output file for this test
        output_file="$TEMP_DIR/result_${file_size}.txt"
        output_files+=("$output_file")
        
        # Launch test in background
        run_single_test "$file_size" "$dynamic_num_files" "$output_file" &
        job_pid=$!
        job_pids+=($job_pid)
        
        echo "Started test for $file_size (PID: $job_pid)"
        
        # Limit concurrent jobs
        if [ ${#job_pids[@]} -ge $MAX_PARALLEL_JOBS ]; then
            echo "Waiting for some jobs to complete before starting more..."
            # Wait for at least one job to complete
            wait ${job_pids[0]}
            # Remove completed job from array (simple approach - remove first)
            job_pids=("${job_pids[@]:1}")
        fi
        
        # Brief pause to avoid overwhelming the system
        sleep 5
    done
    
    # Wait for all remaining jobs to complete
    echo ""
    echo "Waiting for all tests to complete..."
    for pid in "${job_pids[@]}"; do
        wait $pid
        echo "Test with PID $pid completed"
    done
    
    echo ""
    echo "All tests completed! Collecting results..."
    
    # Collect results from output files
    for output_file in "${output_files[@]}"; do
        if [ -f "$output_file" ]; then
            line=$(cat "$output_file")
            IFS='|' read -r status file_size num_files iops bandwidth max_cpu max_memory fio_cpu fio_memory gcsfuse_cpu gcsfuse_memory job_id <<< "$line"
            
            # Store results
            results_iops["$file_size"]="$iops"
            results_bandwidth["$file_size"]="$bandwidth"
            results_max_cpu["$file_size"]="$max_cpu"
            results_max_memory["$file_size"]="$max_memory"
            results_fio_cpu["$file_size"]="$fio_cpu"
            results_fio_memory["$file_size"]="$fio_memory"
            results_gcsfuse_cpu["$file_size"]="$gcsfuse_cpu"
            results_gcsfuse_memory["$file_size"]="$gcsfuse_memory"
            results_job_id["$file_size"]="$job_id"
        fi
    done

else
    echo "Running tests in SEQUENTIAL mode..."

# Run tests for each file size (sequential mode)
for file_size in "${FILE_SIZES[@]}"; do
    # Get dynamic file count for this file size
    dynamic_num_files=$(get_num_files_for_size "$file_size")
    
    echo "=============================================="
    echo "Testing File Size: $file_size ($dynamic_num_files files)"
    echo "=============================================="
    
    # Get adjusted block size (use file size if block size is larger than file size)
    adjusted_block_size=$(get_adjusted_block_size "$file_size" "$BLOCK_SIZE")
    if [ "$adjusted_block_size" != "$BLOCK_SIZE" ]; then
        echo "  Note: Block size adjusted from $BLOCK_SIZE to $adjusted_block_size (file size limit)"
    fi
    
    # Run the FIO test with dynamic file count and adjusted block size
    output=$(./run-single-fio-job.sh "$dynamic_num_files" "$file_size" "$ITERATIONS" "$MODE" "$adjusted_block_size" "$MOUNT_OPTIONS" 2>&1)
    
    # Check if test was successful
    if echo "$output" | grep -q "FIO Benchmark Complete"; then
        echo "✓ Test completed successfully"
        
        # Extract results
        result=$(extract_results "$output")
        
        # Debug: Show extracted job ID
        extracted_job_id=$(echo "$result" | cut -d'|' -f9)
        echo "[DEBUG] Extracted Job ID: '$extracted_job_id'"
        
        iops=$(echo "$result" | cut -d'|' -f1)
        bandwidth=$(echo "$result" | cut -d'|' -f2)
        max_cpu=$(echo "$result" | cut -d'|' -f3)
        max_memory=$(echo "$result" | cut -d'|' -f4)
        fio_cpu=$(echo "$result" | cut -d'|' -f5)
        fio_memory=$(echo "$result" | cut -d'|' -f6)
        gcsfuse_cpu=$(echo "$result" | cut -d'|' -f7)
        gcsfuse_memory=$(echo "$result" | cut -d'|' -f8)
        job_id=$(echo "$result" | cut -d'|' -f9)
        
        # Store results
        results_iops["$file_size"]="$iops"
        results_bandwidth["$file_size"]="$bandwidth"
        results_max_cpu["$file_size"]="$max_cpu"
        results_max_memory["$file_size"]="$max_memory"
        results_fio_cpu["$file_size"]="$fio_cpu"
        results_fio_memory["$file_size"]="$fio_memory"
        results_gcsfuse_cpu["$file_size"]="$gcsfuse_cpu"
        results_gcsfuse_memory["$file_size"]="$gcsfuse_memory"
        results_job_id["$file_size"]="$job_id"
        
        echo "  Job ID: $job_id"
        
        echo "  Files: $dynamic_num_files"
        echo "  IOPS: $iops"
        echo "  Bandwidth: $bandwidth MB/s"
        echo "  Overall Pod - Max CPU: ${max_cpu}m, Max Memory: ${max_memory}Mi"
        echo "  FIO Container - Max CPU: ${fio_cpu}m, Max Memory: ${fio_memory}Mi"
        echo "  GCS FUSE Sidecar - Max CPU: ${gcsfuse_cpu}m, Max Memory: ${gcsfuse_memory}Mi"
        echo ""
    else
        echo "✗ Test failed for file size $file_size"
        echo "$output"
        echo ""
        
        # Store failure markers
        results_iops["$file_size"]="FAILED"
        results_bandwidth["$file_size"]="FAILED"
        results_max_cpu["$file_size"]="FAILED"
        results_max_memory["$file_size"]="FAILED"
        results_fio_cpu["$file_size"]="FAILED"
        results_fio_memory["$file_size"]="FAILED"
        results_gcsfuse_cpu["$file_size"]="FAILED"
        results_gcsfuse_memory["$file_size"]="FAILED"
        results_job_id["$file_size"]="FAILED"
    fi
    
    # Brief pause between tests
    sleep 10
done

fi  # End of parallel/sequential mode selection

# Display final results summary
echo ""
echo "==============================================="
echo "FINAL RESULTS SUMMARY"
echo "==============================================="
printf "%-10s %-20s %-8s %-12s %-10s %-10s %-10s %-10s %-12s %-12s\n" "File Size" "Job ID" "IOPS" "BW (MB/s)" "Pod CPU" "Pod Mem" "FIO CPU" "FIO Mem" "gcsfuse CPU" "gcsfuse mem"
echo "------------------------------------------------------------------------------------------------------------------------------------------------"

for file_size in "${FILE_SIZES[@]}"; do
    iops="${results_iops[$file_size]}"
    bandwidth="${results_bandwidth[$file_size]}"
    max_cpu="${results_max_cpu[$file_size]}"
    max_memory="${results_max_memory[$file_size]}"
    fio_cpu="${results_fio_cpu[$file_size]}"
    fio_memory="${results_fio_memory[$file_size]}"
    gcsfuse_cpu="${results_gcsfuse_cpu[$file_size]}"
    gcsfuse_memory="${results_gcsfuse_memory[$file_size]}"
    job_id="${results_job_id[$file_size]}"
    
    # Debug: Show what job ID is being used
    echo "[DEBUG] File Size: $file_size, Job ID: '$job_id'"
    
    printf "%-10s %-20s %-8s %-12s %-10s %-10s %-10s %-10s %-12s %-12s\n" "$file_size" "$job_id" "$iops" "$bandwidth" "${max_cpu}m" "${max_memory}Mi" "${fio_cpu}m" "${fio_memory}Mi" "${gcsfuse_cpu}m" "${gcsfuse_memory}Mi"
done

echo "========================================================================"

# Generate CSV output for analysis
csv_file="fio_results_$(date +%Y%m%d_%H%M%S).csv"
echo "File_Size,Job_ID,IOPS,Bandwidth_MBps,Pod_Max_CPU_m,Pod_Max_Memory_MiB,FIO_CPU_m,FIO_Memory_MiB,GCS_FUSE_CPU_m,GCS_FUSE_Memory_MiB" > "$csv_file"

for file_size in "${FILE_SIZES[@]}"; do
    iops="${results_iops[$file_size]}"
    bandwidth="${results_bandwidth[$file_size]}"
    max_cpu="${results_max_cpu[$file_size]}"
    max_memory="${results_max_memory[$file_size]}"
    fio_cpu="${results_fio_cpu[$file_size]}"
    fio_memory="${results_fio_memory[$file_size]}"
    gcsfuse_cpu="${results_gcsfuse_cpu[$file_size]}"
    gcsfuse_memory="${results_gcsfuse_memory[$file_size]}"
    job_id="${results_job_id[$file_size]}"
    echo "$file_size,$job_id,$iops,$bandwidth,$max_cpu,$max_memory,$fio_cpu,$fio_memory,$gcsfuse_cpu,$gcsfuse_memory" >> "$csv_file"
done

echo "Results saved to: $csv_file"
echo ""
echo "Multi File Size Benchmark Complete!"
