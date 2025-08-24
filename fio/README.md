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
- **Detailed Logs**: Comprehensive logging of the benchmark process
- **CSV Results**: Results are saved to timestamped CSV files

### Sample Output
```
===============================================
FIO Benchmark Results
===============================================
Average IOPS: 1234.56
Average Bandwidth: 123.45 MB/s

Pod Resource Usage:
Max CPU Usage: 250m
Max Memory Usage: 512Mi

Container Resource Breakdown:
FIO Test Container:
  Max CPU Usage: 150m
  Max Memory Usage: 256Mi
GCSFuse Sidecar Container:
  Max CPU Usage: 100m
  Max Memory Usage: 256Mi
===============================================
```

## Monitoring and Debugging

Both scripts include:
- Real-time resource monitoring during benchmark execution
- Pod status checking and error handling
- Detailed logging with configurable severity levels
- Automatic cleanup of Kubernetes resources

## Troubleshooting

1. **Authentication Issues**: Ensure gcloud is authenticated and has access to the project
2. **Cluster Access**: Verify kubectl can connect to the specified GKE cluster
3. **Missing YAML Files**: Ensure referenced Kubernetes YAML files exist in the workspace
4. **Resource Limits**: Check if cluster has sufficient resources for the benchmark pods

## Notes

- The scripts automatically set up GKE connections and clean up resources
- Results are saved with timestamps to avoid overwriting previous test results
- Scripts include comprehensive error handling and status monitoring
- Both scripts support various GCS Fuse mount options for performance tuning
