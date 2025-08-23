# Export the required environment variable.
export PROJECT_ID=supercomputer-testing
export CLUSTER_REGION=australia-southeast1
export CLUSTER_NAME=a3plus-benchmark
export GCS_BUCKET_LOGS=princer-nemo-logs
export GCS_BUCKET_DATA=princer-nemo-training
export GCS_BUCKET_CHECKPOINTS=princer-nemo-ckpt

# Set the project-id
gcloud config set project $PROJECT_ID

# Setup training data-set
gcloud storage folders create gs://${GCS_BUCKET_DATA}/pile
gcloud storage cp gs://cloud-samples-data/third-party/pile/*.* gs://${GCS_BUCKET_DATA}/pile/

# Get the recipe
git clone https://github.com/ai-hypercomputer/gpu-recipes.git
cd gpu-recipes
export REPO_ROOT=`git rev-parse --show-toplevel`
export RECIPE_ROOT=$REPO_ROOT/training/a3mega/llama3-1-70b/nemo-pretraining-gke-gcs

# Get the cluster credentials
gcloud container clusters get-credentials $CLUSTER_NAME --region $CLUSTER_REGION

# Create pv and pvc
helm uninstall princer-gcs-pv-pvc && helm install -f $REPO_ROOT/src/helm-charts/storage/gcs-fuse/values.yaml \
--set gcsVolumes[0].bucketName=${GCS_BUCKET_DATA} \
--set gcsVolumes[1].bucketName=${GCS_BUCKET_CHECKPOINTS} \
princer-gcs-pv-pvc \
$REPO_ROOT/src/helm-charts/storage/gcs-fuse

# Configure and submit the pretraining job
cd $RECIPE_ROOT
helm uninstall princer-llama31-70b-gcs && helm install -f values.yaml \
    --set-file nemo_config=$REPO_ROOT/src/frameworks/a3mega/nemo-configs/llama3-1-70b-256gpus-bf16-pile-checkpointing.yaml \
    --set volumes.gcsMounts[0].bucketName=${GCS_BUCKET_LOGS} \
    princer-llama31-70b-gcs \
    $REPO_ROOT/src/helm-charts/a3mega/nemo-training-v2


# Get the pods
kubectl get pods | grep "princer"
