# FIO Benchmark Scripts for GKE

This directory contains shell scripts for running FIO (File I/O Tester) benchmarks on Google Kubernetes Engine (GKE) with Google Cloud Storage Fuse (GCS Fuse) mounts.

## Scripts Overview

### 1. `run-single-fio-job.sh`
Runs a single FIO benchmark job with specified parameters.

### 2. `run-multi-fio-job.sh`
Runs multiple FIO benchmark jobs across different file sizes for comprehensive testing.

## Prerequisites

- Google Cloud SDK (gcloud) installed and configured
- kubectl configured to access your GKE cluster
- Access to the specified GKE cluster and GCS bucket

## Configuration

Both scripts are pre-configured with the following GKE setup:
- **Project ID**: `gcs-tess`
- **Cluster Region**: `us-central1-c`
- **Cluster Name**: `warp-cluster`
- **Bucket Name**: `princer-gcsfuse-test`

## Usage

### Single FIO Job

```bash
./run-single-fio-job.sh [num_files] [file_size] [iterations] [mode] [block_size] [mount_options]
```

**Parameters:**
- `num_files`: Number of files to test with (default: 100)
- `file_size`: Size of each file (default: 256K)
- `iterations`: Number of test iterations (default: 3)
- `mode`: Test mode - read/write/randrw (default: read)
- `block_size`: FIO block size (default: 1M)
- `mount_options`: GCS Fuse mount options (default includes metadata caching and trace logging)

**Examples:**
```bash
# Run with defaults
./run-single-fio-job.sh

# Run with custom parameters
./run-single-fio-job.sh 50 1M 5 read 4M

# Run write test with large files
./run-single-fio-job.sh 10 100M 2 write 16M
```

### Multi File Size Job

```bash
./run-multi-fio-job.sh [num_files] [iterations] [mode] [block_size] [mount_options] [parallel_mode] [max_parallel_jobs]
```

**Parameters:**
- `num_files`: Base number of files (automatically adjusted per file size, default: 10)
- `iterations`: Number of iterations per file size (default: 2)
- `mode`: Test mode - read/write/randrw (default: read)
- `block_size`: FIO block size (default: 1M)
- `mount_options`: GCS Fuse mount options (default includes buffered read and metadata caching)
- `parallel_mode`: Enable parallel execution (default: false)
- `max_parallel_jobs`: Maximum parallel jobs when parallel mode is enabled (default: 3)

**Examples:**
```bash
# Run with defaults (sequential execution)
./run-multi-fio-job.sh

# Run with parallel execution
./run-multi-fio-job.sh 10 2 read 1M "implicit-dirs,metadata-cache:ttl-secs:60" true 3

# Run write tests with more iterations
./run-multi-fio-job.sh 15 5 write 4M
```

## File Size Configuration

The multi-job script tests various file sizes with automatically adjusted file counts:
- **Small files (64K-256K)**: 200 files
- **Medium files (1M-4M)**: 100 files  
- **Medium-large files (16M-64M)**: 40 files
- **Large files (256M-512M)**: 20 files
- **Very large files (1G-4G)**: 10 files
- **Huge files (10G+)**: 4 files

## Output and Results

Both scripts provide:
- **Performance Metrics**: IOPS and bandwidth measurements
- **Resource Usage**: CPU and memory consumption for pods and containers
- **Job ID Tracking**: Each test includes GKE job ID for debugging and correlation
- **Detailed Logs**: Comprehensive logging of the benchmark process
- **CSV Results**: Results are saved to timestamped CSV files with job ID information

### Multi-Job CSV Output Format
The multi-job script generates CSV files with the following columns:
```csv
File_Size,Job_ID,IOPS,Bandwidth_MBps,Pod_Max_CPU_m,Pod_Max_Memory_Mi,FIO_CPU_m,FIO_Memory_Mi,GCS_FUSE_CPU_m,GCS_FUSE_Memory_Mi
100M,fio-test-1756054084,629.85,660.44,4684,499,4563,130,1578,372
1G,fio-test-1756054123,892.45,935.12,5120,645,4980,145,1890,480
```

### Sample Output
```
==============================================
Starting FIO test with 2 iterations
GKE Job ID: fio-test-1756054084
==============================================
Pod created: fio-test-1756054084-bnhvm
[INFO] Pod status changed to: Succeeded, stopping resource monitoring

Results (Job ID: fio-test-1756054084, Pod: fio-test-1756054084-bnhvm):
==============================================
Average IOPS: 629.85
Average Bandwidth: 660.44 MB/s
Successful iterations: 2 / 2
Test completed!
==============================================

Resource Usage (Job ID: fio-test-1756054084):
  Overall Pod:
    Max CPU: 4684m
    Max Memory: 499Mi
  FIO Container:
    Max CPU: 4563m
    Max Memory: 130Mi
  GCS FUSE Sidecar Container:
    Max CPU: 1578m
    Max Memory: 372Mi
==============================================
```

## Monitoring and Debugging

Both scripts include advanced monitoring capabilities:
- **Dynamic Resource Monitoring**: Real-time CPU and memory tracking that adapts to job duration
- **Pod Status-Based Monitoring**: Monitoring automatically stops when pods complete (no fixed time limits)
- **Per-Container Metrics**: Separate tracking for FIO test container and GCS FUSE sidecar container
- **Silent Package Installation**: Uses modern `apt --quiet` for clean installation logs
- **Pod Status Checking**: Comprehensive error handling and status monitoring
- **Detailed Debug Output**: Container metrics are logged for troubleshooting
- **Automatic Cleanup**: Complete cleanup of Kubernetes resources after each test

### Monitoring Features:
- **Adaptive Duration**: Monitoring runs only while pods are in "Running" state
- **Real-time Metrics**: CPU and memory usage captured every 2 seconds
- **Maximum Value Tracking**: Records peak resource usage during test execution
- **Multi-Container Support**: Tracks both test workload and GCS FUSE sidecar separately
- **Job ID Integration**: All tests include GKE job IDs for easy debugging and log correlation

### Job ID Benefits for Debugging:
With job IDs, you can easily:
```bash
# View job details
kubectl describe job <job-id>

# Check pod logs  
kubectl logs <job-id>-<random-suffix>

# Get pod details
kubectl describe pod <job-id>-<random-suffix>

# View events related to the job
kubectl get events --field-selector involvedObject.name=<job-id>
```

## Troubleshooting

1. **Authentication Issues**: Ensure gcloud is authenticated and has access to the project
2. **Cluster Access**: Verify kubectl can connect to the specified GKE cluster
3. **Missing YAML Files**: Ensure referenced Kubernetes YAML files exist in the workspace
4. **Resource Limits**: Check if cluster has sufficient resources for the benchmark pods

## Recent Improvements

- **Smart Monitoring**: Resource monitoring now stops automatically when pods complete instead of running for fixed time periods
- **Clean Installation**: Package installation (fio, jq, bc, gettext-base) now uses `apt --quiet` for minimal output
- **Enhanced Resource Tracking**: Separate CPU and memory tracking for test container and GCS FUSE sidecar
- **Better Status Detection**: Monitoring loop breaks based on pod status changes (Running → Succeeded/Failed)
- **Improved Debugging**: Container metrics output available for troubleshooting performance issues

## Notes

- **Automatic Setup**: Scripts automatically configure GKE connections and clean up all resources
- **Timestamped Results**: Results are saved with timestamps to prevent overwriting previous test data  
- **Comprehensive Error Handling**: Built-in status monitoring and error recovery mechanisms
- **Flexible Mount Options**: Support for various GCS Fuse mount options for performance tuning
- **Resource Efficiency**: Monitoring adapts to actual job duration, avoiding unnecessary resource usage
- **Container Isolation**: Resource metrics separated by container type for better analysis
