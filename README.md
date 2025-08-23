# GKE Tooling

This repository contains various tools and scripts for working with Google Kubernetes Engine (GKE).

## Directory Structure

### `fio/`
Contains FIO (Flexible I/O tester) benchmark tools for testing storage performance in GKE environments, specifically designed for GCS FUSE testing.

**Key files:**
- `fio-job.yaml` - Kubernetes Job manifest for FIO benchmarks
- `run-fio-benchmark.sh` - Main script to deploy and manage FIO jobs
- `fio-config.env.template` - Configuration template with test scenarios
- `README-FIO.md` - Detailed FIO documentation

**Quick start:**
```bash
cd fio
./run-fio-benchmark.sh deploy
```

### Root Directory Files
- `job.yaml` - General Kubernetes job manifest
- `a.sh` - GKE setup and deployment script
- `security/` - Security-related configurations
- Other YAML files for various GKE workloads

## Getting Started

1. **For FIO benchmarking:**
   ```bash
   cd fio
   ./run-fio-benchmark.sh help
   ```

2. **For general GKE setup:**
   ```bash
   ./a.sh
   ```

See individual directories and files for specific documentation and usage instructions.
