#!/bin/bash

# Multi File Size FIO Benchmark Runner for GKE
# This script runs FIO tests across different file sizes
# Usage: ./multi-filesize-benchmark.sh [num_files] [iterations] [mode] [block_size] [mount_options]

set -e

# Default values
NUM_FILES=${1:-10}
ITERATIONS=${2:-2}
MODE=${3:-read}
BLOCK_SIZE=${4:-1M}
MOUNT_OPTIONS=${5:-"implicit-dirs,metadata-cache:ttl-secs:60,log-severity=info,enable-buffered-read,log-severity=trace,read-block-size-mb=16"}

# Array of file sizes to test
FILE_SIZES=(
    # "64K"
    # "256K" 
    # "1M"
    # "4M"
    # "16M"
    # "64M"
    "100M"
    # "256M"
    "1G"
    # "4G"
    # "10G"
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

# Function to determine number of files based on file size
get_num_files_for_size() {
    local file_size="$1"
    
    case "$file_size" in
        "64K"|"256K")
            echo 200    # Many small files for better concurrency testing
            ;;
        "1M"|"4M")
            echo 100    # Moderate number of medium files
            ;;
        "16M"|"64M")
            echo 40     # Fewer medium-large files
            ;;
        "256M"|"512M")
            echo 20     # Fewer large files
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

echo "==============================================="
echo "Multi File Size FIO Benchmark"
echo "==============================================="
echo "Configuration:"
echo "  Files per test: Dynamic based on file size"
echo "  Iterations per size: $ITERATIONS"
echo "  Mode: $MODE"
echo "  Block Size: $BLOCK_SIZE"
echo "  Mount Options: $MOUNT_OPTIONS"
echo ""
echo "File Size -> Number of Files mapping:"
for file_size in "${FILE_SIZES[@]}"; do
    num_files=$(get_num_files_for_size "$file_size")
    echo "  $file_size -> $num_files files"
done
echo "==============================================="
echo ""

# Function to extract results from simple-fio.sh output
extract_results() {
    local output="$1"
    local iops=$(echo "$output" | grep "Average IOPS:" | tail -1 | awk '{print $3}')
    local bandwidth=$(echo "$output" | grep "Average Bandwidth:" | tail -1 | awk '{print $3}')
    
    # Extract overall pod resource usage
    local max_cpu=$(echo "$output" | grep "Overall Pod:" -A 2 | grep "Max CPU:" | awk '{print $3}' | sed 's/m$//')
    local max_memory=$(echo "$output" | grep "Overall Pod:" -A 2 | grep "Max Memory:" | awk '{print $3}' | sed 's/Mi$//')
    
    # Extract FIO container resource usage
    local fio_cpu=$(echo "$output" | grep "FIO Container:" -A 2 | grep "Max CPU:" | awk '{print $3}' | sed 's/m$//')
    local fio_memory=$(echo "$output" | grep "FIO Container:" -A 2 | grep "Max Memory:" | awk '{print $3}' | sed 's/Mi$//')
    
    # Extract GCS FUSE sidecar container resource usage
    local gcsfuse_cpu=$(echo "$output" | grep "GCS FUSE Sidecar Container:" -A 2 | grep "Max CPU:" | awk '{print $3}' | sed 's/m$//')
    local gcsfuse_memory=$(echo "$output" | grep "GCS FUSE Sidecar Container:" -A 2 | grep "Max Memory:" | awk '{print $3}' | sed 's/Mi$//')
    
    echo "$iops|$bandwidth|$max_cpu|$max_memory|$fio_cpu|$fio_memory|$gcsfuse_cpu|$gcsfuse_memory"
}

# Run tests for each file size
for file_size in "${FILE_SIZES[@]}"; do
    # Get dynamic file count for this file size
    dynamic_num_files=$(get_num_files_for_size "$file_size")
    
    echo "=============================================="
    echo "Testing File Size: $file_size ($dynamic_num_files files)"
    echo "=============================================="
    
    # Run the FIO test with dynamic file count
    output=$(./simple-fio.sh "$dynamic_num_files" "$file_size" "$ITERATIONS" "$MODE" "$BLOCK_SIZE" "$MOUNT_OPTIONS" 2>&1)
    
    # Check if test was successful
    if echo "$output" | grep -q "FIO Benchmark Complete"; then
        echo "✓ Test completed successfully"
        
        # Extract results
        result=$(extract_results "$output")
        iops=$(echo "$result" | cut -d'|' -f1)
        bandwidth=$(echo "$result" | cut -d'|' -f2)
        max_cpu=$(echo "$result" | cut -d'|' -f3)
        max_memory=$(echo "$result" | cut -d'|' -f4)
        fio_cpu=$(echo "$result" | cut -d'|' -f5)
        fio_memory=$(echo "$result" | cut -d'|' -f6)
        gcsfuse_cpu=$(echo "$result" | cut -d'|' -f7)
        gcsfuse_memory=$(echo "$result" | cut -d'|' -f8)
        
        # Store results
        results_iops["$file_size"]="$iops"
        results_bandwidth["$file_size"]="$bandwidth"
        results_max_cpu["$file_size"]="$max_cpu"
        results_max_memory["$file_size"]="$max_memory"
        results_fio_cpu["$file_size"]="$fio_cpu"
        results_fio_memory["$file_size"]="$fio_memory"
        results_gcsfuse_cpu["$file_size"]="$gcsfuse_cpu"
        results_gcsfuse_memory["$file_size"]="$gcsfuse_memory"
        
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
    fi
    
    # Brief pause between tests
    sleep 10
done

# Display final results summary
echo ""
echo "==============================================="
echo "FINAL RESULTS SUMMARY"
echo "==============================================="
printf "%-10s %-8s %-12s %-10s %-10s %-10s %-10s %-12s %-12s
" "File Size" "IOPS" "BW (MB/s)" "Pod CPU" "Pod Mem" "FIO CPU" "FIO Mem" "gcsfuse CPU" "gcsfuse mem"
echo "------------------------------------------------------------------------------------------------------------------------------"

for file_size in "${FILE_SIZES[@]}"; do
    iops="${results_iops[$file_size]}"
    bandwidth="${results_bandwidth[$file_size]}"
    max_cpu="${results_max_cpu[$file_size]}"
    max_memory="${results_max_memory[$file_size]}"
    fio_cpu="${results_fio_cpu[$file_size]}"
    fio_memory="${results_fio_memory[$file_size]}"
    gcsfuse_cpu="${results_gcsfuse_cpu[$file_size]}"
    gcsfuse_memory="${results_gcsfuse_memory[$file_size]}"
    
    printf "%-8s %-8s %-10s %-8s %-8s %-8s %-8s %-8s %-8s\n" "$file_size" "$iops" "$bandwidth" "${max_cpu}m" "${max_memory}Mi" "${fio_cpu}m" "${fio_memory}Mi" "${gcsfuse_cpu}m" "${gcsfuse_memory}Mi"
done

echo "========================================================================"

# Generate CSV output for analysis
csv_file="fio_results_$(date +%Y%m%d_%H%M%S).csv"
echo "File_Size,IOPS,Bandwidth_MBps,Pod_Max_CPU_m,Pod_Max_Memory_Mi,FIO_CPU_m,FIO_Memory_Mi,GCS_FUSE_CPU_m,GCS_FUSE_Memory_Mi" > "$csv_file"

for file_size in "${FILE_SIZES[@]}"; do
    iops="${results_iops[$file_size]}"
    bandwidth="${results_bandwidth[$file_size]}"
    max_cpu="${results_max_cpu[$file_size]}"
    max_memory="${results_max_memory[$file_size]}"
    fio_cpu="${results_fio_cpu[$file_size]}"
    fio_memory="${results_fio_memory[$file_size]}"
    gcsfuse_cpu="${results_gcsfuse_cpu[$file_size]}"
    gcsfuse_memory="${results_gcsfuse_memory[$file_size]}"
    echo "$file_size,$iops,$bandwidth,$max_cpu,$max_memory,$fio_cpu,$fio_memory,$gcsfuse_cpu,$gcsfuse_memory" >> "$csv_file"
done

echo "Results saved to: $csv_file"
echo ""
echo "Multi File Size Benchmark Complete!"
