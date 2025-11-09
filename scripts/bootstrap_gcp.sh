#!/usr/bin/env bash
set -euxo pipefail

# ===================== CONFIG =====================
PROJECT_ID="llama-3v2-1b-fine-tuning"
REGION="us-central1"
ZONE="${REGION}-a"

# Artifact Registry (regional == REGION)
AR_LOC="${REGION}"
AR_FORMAT="docker"
WORKER_REPO="worker"
JOB_REPO="job"

# App resources
BUCKET_NAME="${PROJECT_ID}-wrkjob-bucket"
PUBSUB_TOPIC="worker-job-topic"
PUBSUB_SUB="worker-job-sub"
BQ_DATASET="wrkjob_ds"
BQ_LOC="US"

# CI (GitHub Actions) - SA + WIF (POR REPO)
SA_ID="wrkjob-ci"
SA_DISPLAY="CI for worker+job"
WIP_NAME="wrkjob-pool"
WIP_PROVIDER_NAME="github"
OIDC_ISSUER_URI="https://token.actions.githubusercontent.com"
GH_ORG="naatlabia-lang"
GH_REPO="Llama-3v2-1B-Fine-Tuning"

# Vertex AI runner SA + staging
VERTEX_SA_ID="vertex-runner"
VERTEX_STAGING_BUCKET="gs://${PROJECT_ID}-vertex-staging"

# Runtime (Notebook/Workbench) SA (sin EUC)
RUNTIME_SA_ID="nb-runner"
RUNTIME_NAME="nb-ray-client"

# ===================== HELPERS =====================
log()  { echo -e "\033[1;36m==>\033[0m $*"; }
wait_sa() {
  local EMAIL="$1"
  for i in {1..60}; do
    if gcloud iam service-accounts describe "$EMAIL" >/dev/null 2>&1; then return 0; fi
    sleep 1
  done
  echo "Timeout esperando SA: $EMAIL" >&2
  exit 1
}
# ===================================================

gcloud config set project "${PROJECT_ID}"

PROJECT_NUMBER="$(gcloud projects describe "${PROJECT_ID}" --format="value(projectNumber)")"
SA_EMAIL="${SA_ID}@${PROJECT_ID}.iam.gserviceaccount.com"
VERTEX_SA_EMAIL="${VERTEX_SA_ID}@${PROJECT_ID}.iam.gserviceaccount.com"
RUNTIME_SA_EMAIL="${RUNTIME_SA_ID}@${PROJECT_ID}.iam.gserviceaccount.com"

# ===================== ENABLE APIS =====================
log "Habilitando APIs…"
gcloud services enable \
  artifactregistry.googleapis.com \
  iam.googleapis.com \
  iamcredentials.googleapis.com \
  sts.googleapis.com \
  pubsub.googleapis.com \
  storage.googleapis.com \
  bigquery.googleapis.com \
  cloudbuild.googleapis.com \
  container.googleapis.com \
  aiplatform.googleapis.com \
  compute.googleapis.com \
  notebooks.googleapis.com

# ===================== CREATE SAs =====================
log "Creando SA de CI…"
gcloud iam service-accounts create "${SA_ID}" --display-name="${SA_DISPLAY}" || true
wait_sa "${SA_EMAIL}"

log "Roles para SA de CI…"
for ROLE in roles/artifactregistry.writer roles/storage.admin roles/pubsub.editor roles/bigquery.dataEditor roles/bigquery.jobUser; do
  gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${SA_EMAIL}" --role="${ROLE}"
done

log "Creando Vertex runner SA…"
gcloud iam service-accounts create "${VERTEX_SA_ID}" --display-name="Vertex AI Runner" || true
wait_sa "${VERTEX_SA_EMAIL}"
for ROLE in roles/artifactregistry.reader roles/storage.objectAdmin roles/logging.logWriter roles/monitoring.metricWriter roles/aiplatform.user; do
  gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${VERTEX_SA_EMAIL}" --role="${ROLE}"
done

log "Creando Runtime (Notebook) SA…"
gcloud iam service-accounts create "${RUNTIME_SA_ID}" --display-name="Notebook Runner" || true
wait_sa "${RUNTIME_SA_EMAIL}"
for ROLE in roles/aiplatform.user roles/artifactregistry.reader roles/storage.objectAdmin roles/logging.logWriter roles/monitoring.metricWriter; do
  gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${RUNTIME_SA_EMAIL}" --role="${ROLE}"
done

# ===================== WIF (POR REPO) =====================
log "Configurando Workload Identity Federation (por repo)…"
# Pool
gcloud iam workload-identity-pools create "${WIP_NAME}" \
  --location=global --display-name="${WIP_NAME}" || true

# Provider con attribute-condition (por repo)
gcloud iam workload-identity-pools providers create-oidc "${WIP_PROVIDER_NAME}" \
  --workload-identity-pool="${WIP_NAME}" \
  --location=global \
  --display-name="${WIP_PROVIDER_NAME}" \
  --issuer-uri="${OIDC_ISSUER_URI}" \
  --attribute-mapping="google.subject=assertion.sub,attribute.actor=assertion.actor,attribute.repository=assertion.repository" \
  --attribute-condition="assertion.repository=='${GH_ORG}/${GH_REPO}'" || true

# Provider FQN
PROVIDER_FQN="$(gcloud iam workload-identity-pools providers describe "${WIP_PROVIDER_NAME}" \
  --workload-identity-pool="${WIP_NAME}" --location=global --format='value(name)')"

# Binding SA CI ← principalSet (repo específico)
gcloud iam service-accounts add-iam-policy-binding "${SA_EMAIL}" \
  --role="roles/iam.workloadIdentityUser" \
  --member="principalSet://iam.googleapis.com/${PROVIDER_FQN}/attribute.repository/${GH_ORG}/${GH_REPO}"

# ===================== ARTIFACT REGISTRY =====================
log "Creando repos de Artifact Registry (regional: ${AR_LOC})…"
for REPO in "${WORKER_REPO}" "${JOB_REPO}"; do
  gcloud artifacts repositories create "${REPO}" \
    --repository-format="${AR_FORMAT}" --location="${AR_LOC}" \
    --description="Repo for ${REPO} images" || true
done

# ===================== STORAGE / PUBSUB / BQ =====================
log "Creando bucket GCS de app…"
gsutil mb -l "${REGION}" "gs://${BUCKET_NAME}" || true
gsutil uniformbucketlevelaccess set on "gs://${BUCKET_NAME}" || true

log "Creando Pub/Sub (topic y sub)…"
gcloud pubsub topics create "${PUBSUB_TOPIC}" || true
gcloud pubsub subscriptions create "${PUBSUB_SUB}" --topic="${PUBSUB_TOPIC}" || true

log "Creando dataset BigQuery…"
bq --location="${BQ_LOC}" mk --dataset "${PROJECT_ID}:${BQ_DATASET}" || true

# ===================== VERTEX STAGING BUCKET =====================
log "Creando Vertex staging bucket…"
gsutil mb -l "${REGION}" "${VERTEX_STAGING_BUCKET}" || true

# ===================== (OPCIONAL) RUNTIME WORKBENCH =====================
log "Creando Workbench Managed Runtime con SA (sin EUC)…"
gcloud notebooks runtimes create "${RUNTIME_NAME}" \
  --location="${ZONE}" \
  --runtime-type=managed \
  --machine-type=n2-standard-8 \
  --vm-image-project=deeplearning-platform-release \
  --vm-image-family=common-cpu-notebooks \
  --service-account="${RUNTIME_SA_EMAIL}" \
  --boot-disk-size=100GB || true

# ===================== OUTPUTS =====================
cat <<EOF

==================== INFO PARA GITHUB ACTIONS ====================
Secrets:
  GCP_SERVICE_ACCOUNT            = ${SA_EMAIL}
  GCP_WORKLOAD_IDENTITY_PROVIDER = projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${WIP_NAME}/providers/${WIP_PROVIDER_NAME}

Variables:
  PROJECT_ID         = ${PROJECT_ID}
  REGION             = ${REGION}
  AR_LOC             = ${AR_LOC}
  WORKER_REPO        = ${WORKER_REPO}
  JOB_REPO           = ${JOB_REPO}
  WORKER_TORCH_DEVICE= cpu   # cu121/cu118 si usas GPU
  JOB_TORCH_DEVICE   = cpu

Artifact Registry (regional):
  ${AR_LOC}-docker.pkg.dev/${PROJECT_ID}/${WORKER_REPO}/worker:<tag>
  ${AR_LOC}-docker.pkg.dev/${PROJECT_ID}/${JOB_REPO}/job:<tag>

Vertex AI:
  RUNNER_SA          = ${VERTEX_SA_EMAIL}
  STAGING_BUCKET     = ${VERTEX_STAGING_BUCKET}
  Región             = ${REGION}

Workbench Runtime (cliente):
  NAME               = ${RUNTIME_NAME}
  ZONE               = ${ZONE}
  SERVICE_ACCOUNT    = ${RUNTIME_SA_EMAIL}
==================================================================

Docker login a Artifact Registry:
  gcloud auth configure-docker ${AR_LOC}-docker.pkg.dev -q

Push ejemplo:
  docker build -t ${AR_LOC}-docker.pkg.dev/${PROJECT_ID}/${WORKER_REPO}/worker:dev ./worker
  docker push ${AR_LOC}-docker.pkg.dev/${PROJECT_ID}/${WORKER_REPO}/worker:dev
  docker build -t ${AR_LOC}-docker.pkg.dev/${PROJECT_ID}/${JOB_REPO}/job:dev ./job
  docker push ${AR_LOC}-docker.pkg.dev/${PROJECT_ID}/${JOB_REPO}/job:dev
-------------------------------------------------------------------
EOF
