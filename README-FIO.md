# FIO Benchmark for GKE

This repository contains scripts and configurations to run FIO (Flexible I/O tester) benchmarks in Google Kubernetes Engine (GKE) environments, specifically designed for testing GCS FUSE performance.

## Files Overview

- **`fio-job.yaml`** - Kubernetes Job manifest for FIO benchmark
- **`run-fio-benchmark.sh`** - Main script to deploy and manage FIO jobs
- **`fio-config.env.template`** - Configuration template with various test scenarios

## Quick Start

1. **Basic benchmark with default settings:**
   ```bash
   ./run-fio-benchmark.sh deploy
   ```

2. **Check benchmark status:**
   ```bash
   ./run-fio-benchmark.sh status
   ```

3. **View benchmark logs:**
   ```bash
   ./run-fio-benchmark.sh logs
   ```

## Advanced Usage

### Custom Configuration

1. **Using environment variables:**
   ```bash
   FIO_RW_MODE=randwrite FIO_SIZE=2G FIO_RUNTIME=300 ./run-fio-benchmark.sh deploy
   ```

2. **Using configuration file:**
   ```bash
   cp fio-config.env.template fio-config.env
   # Edit fio-config.env with your settings
   source fio-config.env
   ./run-fio-benchmark.sh deploy
   ```

### Available Commands

```bash
./run-fio-benchmark.sh [COMMAND]

Commands:
  deploy    Deploy a new FIO benchmark job
  status    Check the status of running jobs
  logs      Show logs from the latest job
  delete    Delete all FIO benchmark jobs
  clean     Clean up completed/failed jobs
  help      Show help message
```

## Configuration Options

### FIO Test Parameters

| Variable | Default | Description |
|----------|---------|-------------|
| `FIO_RUNTIME` | `60` | Test duration in seconds |
| `FIO_BLOCKSIZE` | `4k` | Block size (4k, 8k, 64k, 1m, etc.) |
| `FIO_IODEPTH` | `32` | Number of I/O operations in flight |
| `FIO_NUMJOBS` | `4` | Number of parallel jobs |
| `FIO_RW_MODE` | `randread` | I/O pattern (read, write, randread, randwrite, rw, randrw) |
| `FIO_SIZE` | `1G` | File size per job |
| `FIO_ENGINE` | `libaio` | I/O engine (libaio, sync, psync, mmap) |
| `FIO_DIRECT` | `1` | Direct I/O (1) or buffered (0) |

### GKE/GCS Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `PROJECT_ID` | `supercomputer-testing` | GCP Project ID |
| `CLUSTER_REGION` | `australia-southeast1` | GKE cluster region |
| `CLUSTER_NAME` | `a3plus-benchmark` | GKE cluster name |
| `BUCKET_NAME` | `gcs-fuse-warp-test-bucket` | GCS bucket name |

## Test Scenarios

### 1. Random Read Performance
Tests random read performance with small block sizes:
```bash
export FIO_RUNTIME="300"
export FIO_BLOCKSIZE="4k"
export FIO_IODEPTH="32"
export FIO_NUMJOBS="8"
export FIO_RW_MODE="randread"
export FIO_SIZE="2G"
```

### 2. Sequential Write Throughput
Tests large block sequential writes:
```bash
export FIO_RUNTIME="180"
export FIO_BLOCKSIZE="1m"
export FIO_IODEPTH="8"
export FIO_NUMJOBS="2"
export FIO_RW_MODE="write"
export FIO_SIZE="5G"
```

### 3. Mixed Workload
Tests combination of reads and writes:
```bash
export FIO_RUNTIME="600"
export FIO_BLOCKSIZE="8k"
export FIO_IODEPTH="16"
export FIO_NUMJOBS="4"
export FIO_RW_MODE="randrw"
export FIO_SIZE="1G"
```

### 4. Database-like Workload
High concurrency small block random I/O:
```bash
export FIO_RUNTIME="300"
export FIO_BLOCKSIZE="8k"
export FIO_IODEPTH="64"
export FIO_NUMJOBS="16"
export FIO_RW_MODE="randread"
export FIO_SIZE="500M"
```

### 5. Streaming Workload
Large sequential I/O for streaming applications:
```bash
export FIO_RUNTIME="120"
export FIO_BLOCKSIZE="1m"
export FIO_IODEPTH="4"
export FIO_NUMJOBS="1"
export FIO_RW_MODE="read"
export FIO_SIZE="10G"
```

## Understanding Results

FIO provides comprehensive performance metrics:

### Key Metrics
- **IOPS** - Input/Output Operations Per Second
- **Bandwidth** - Throughput in MB/s or KB/s
- **Latency** - Response time (min/max/mean/percentiles)
- **CPU Usage** - System and user CPU utilization

### Sample Output Interpretation
```
IOPS: 1234 (read), bandwidth: 4936KB/s
lat (usec): min=100, max=50000, avg=1234.56, stdev=234.12
```

This shows:
- 1,234 read operations per second
- ~4.9 MB/s throughput
- Latency ranging from 0.1ms to 50ms, averaging 1.23ms

## Troubleshooting

### Common Issues

1. **Job fails to start:**
   - Check GKE cluster connectivity: `kubectl cluster-info`
   - Verify service account permissions
   - Check GCS bucket accessibility

2. **Permission denied errors:**
   - Ensure service account has storage permissions
   - Verify GCS FUSE mount permissions

3. **Poor performance:**
   - Check node resources (CPU/Memory)
   - Verify network connectivity to GCS
   - Consider adjusting FIO parameters

### Debug Commands

```bash
# Check pod status
kubectl get pods -l app=fio-benchmark

# Describe pod for detailed info
kubectl describe pod <pod-name>

# Check events
kubectl get events --sort-by=.metadata.creationTimestamp

# Access pod shell for debugging
kubectl exec -it <pod-name> -- /bin/bash
```

## Best Practices

1. **Warm-up runs:** Run a short test first to warm up the system
2. **Multiple runs:** Run tests multiple times and average results
3. **Resource monitoring:** Monitor node resources during tests
4. **Clean up:** Use `./run-fio-benchmark.sh clean` to remove completed jobs
5. **Baseline testing:** Test local storage for comparison

## Integration with CI/CD

The script can be easily integrated into CI/CD pipelines:

```bash
# In your pipeline
source fio-config.env
./run-fio-benchmark.sh deploy
./run-fio-benchmark.sh status
# Wait for completion and collect results
./run-fio-benchmark.sh logs > fio-results.log
```

## Security Considerations

- The job runs with the `warp-benchmark` service account
- Ensure service account has minimal required permissions
- GCS bucket access is controlled via IAM
- Consider using Workload Identity for enhanced security

## Contributing

When modifying the configuration:
1. Test with small-scale runs first
2. Document any new parameters
3. Update this README with examples
4. Consider backward compatibility
