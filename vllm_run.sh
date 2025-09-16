#!/bin/sh


export PROJECT_ID="gcs-tess"
export ZONE="us-west1-a"
export VM_NAME="princer-vllm-benchmark-vm"
export MACHINE_TYPE="a3-highgpu-2g"
# export SERVICE_ACCOUNT="your-service-account@your-project-id.iam.gserviceaccount.com"

create_gcp_vm() {
    echo "Creating GCP VM: $VM_NAME in zone $ZONE"
    gcloud compute instances create $VM_NAME \
    --project=$PROJECT_ID \
    --zone=$ZONE \
    --machine-type=$MACHINE_TYPE \
    --maintenance-policy=TERMINATE \
    --image-family=ubuntu-2204-lts \
    --image-project=ubuntu-os-cloud \
    --boot-disk-size=200GB \
    --scopes=https://www.googleapis.com/auth/cloud-platform
    echo "GCP VM $VM_NAME created."
}

create_gcp_vm