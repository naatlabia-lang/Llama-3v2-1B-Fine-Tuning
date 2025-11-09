#!/usr/bin/env bash
set -euo pipefail

# ==========================================================
#  Bootstrap monorepo worker/job en GCP + Vertex + WIF
#  - Habilita APIs
#  - Crea SA de CI + WIF (GitHub OIDC)
#  - Crea Artifact Registry (worker, job) en la MISMA región
#  - Crea GCS bucket, Pub/Sub, BigQuery
#  - Prepara Vertex AI (SA runner, bucket staging, permisos)
#  - Crea SA para Runtime de Notebook/Workbench (sin EUC)
# ==========================================================

# --------- Config ---------
PROJECT_ID="llama-3v2-1b-fine-tuning"
REGION="us-central1"
ZONE="${REGION}-a"

# Artifact Registry (REGIONAL == REGION)
AR_LOC="${REGION}"          # ← importante: misma región que Vertex
AR_FORMAT="docker"
WORKER_REPO="worker"
JOB_REPO="job"

# Recursos app
BUCKET_NAME="${PROJECT_ID}-wrkjob-bucket"
PUBSUB_TOPIC="worker-job-topic"
PUBSUB_SUB="worker-job-sub"
BQ_DATASET="wrkjob_ds"
BQ_LOC="US"

# CI (GitHub Actions) - SA + WIF
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

echo "==> Proyecto: $PROJECT_ID"
gcloud config set project "$PROJECT_ID" >/dev/null

# --------- APIs ----------
echo "==> Habilitando APIs…"
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
  notebooks.googleapis.com \
  --project "$PROJECT_ID"

# --------- SA de CI ----------
SA_EMAIL="${SA_ID}@${PROJECT_ID}.iam.gserviceaccount.com"
echo "==> Creando SA de CI (si no existe): $SA_EMAIL"
gcloud iam service-accounts describe "$SA_EMAIL" >/dev/null 2>&1 || \
  gcloud iam service-accounts create "$SA_ID" --display-name "$SA_DISPLAY"

echo "==> Roles para SA de CI…"
for ROLE in roles/artifactregistry.writer roles/storage.admin roles/pubsub.editor roles/bigquery.dataEditor roles/bigquery.jobUser; do
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:${SA_EMAIL}" --role="$ROLE" >/dev/null
done

# --------- Artifact Registry (regional) ----------
echo "==> Creando repos AR en ${AR_LOC}…"
for REPO in "$WORKER_REPO" "$JOB_REPO"; do
  gcloud artifacts repositories describe "$REPO" --location="$AR_LOC" >/dev/null 2>&1 || \
    gcloud artifacts repositories create "$REPO" \
      --repository-format="$AR_FORMAT" \
      --location="$AR_LOC" \
      --description="Repo for ${REPO} images"
done

# --------- GCS Bucket ----------
echo "==> Creando bucket GCS de app…"
gsutil ls -b "gs://${BUCKET_NAME}" >/dev/null 2>&1 || {
  gsutil mb -l "$REGION" "gs://${BUCKET_NAME}"
  gsutil uniformbucketlevelaccess set on "gs://${BUCKET_NAME}"
}

# --------- Pub/Sub ----------
echo "==> Creando Pub/Sub…"
gcloud pubsub topics describe "$PUBSUB_TOPIC" >/dev/null 2>&1 || gcloud pubsub topics create "$PUBSUB_TOPIC"
gcloud pubsub subscriptions describe "$PUBSUB_SUB" >/dev/null 2>&1 || \
  gcloud pubsub subscriptions create "$PUBSUB_SUB" --topic="$PUBSUB_TOPIC"

# --------- BigQuery ----------
echo "==> Creando dataset BigQuery…"
bq --project_id="$PROJECT_ID" show --format=none "$BQ_DATASET" >/dev/null 2>&1 || \
  bq --location="$BQ_LOC" mk --dataset "$PROJECT_ID:$BQ_DATASET"

# --------- WIF (GitHub OIDC) ----------
echo "==> Configurando Workload Identity Federation (GitHub OIDC)…"
gcloud iam workload-identity-pools describe "$WIP_NAME" --location="global" >/dev/null 2>&1 || \
  gcloud iam workload-identity-pools create "$WIP_NAME" --location="global" --display-name="$WIP_NAME"

WIP_ID="$(gcloud iam workload-identity-pools describe "$WIP_NAME" --location=global --format="value(name)")"

gcloud iam workload-identity-pools providers describe "$WIP_PROVIDER_NAME" \
  --workload-identity-pool="$WIP_NAME" --location="global" >/dev/null 2>&1 || \
  gcloud iam workload-identity-pools providers create-oidc "$WIP_PROVIDER_NAME" \
    --workload-identity-pool="$WIP_NAME" \
    --location="global" \
    --display-name="$WIP_PROVIDER_NAME" \
    --issuer-uri="$OIDC_ISSUER_URI" \
    --attribute-mapping="google.subject=assertion.sub,attribute.actor=assertion.actor,attribute.repository=assertion.repository"

PROVIDER_FQN="principalSet://iam.googleapis.com/${WIP_ID}/attribute.repository/${GH_ORG}/${GH_REPO}"
gcloud iam service-accounts add-iam-policy-binding "$SA_EMAIL" \
  --role="roles/iam.workloadIdentityUser" \
  --member="$PROVIDER_FQN" >/dev/null

# --------- Vertex AI Runner SA + Staging ----------
VERTEX_SA_EMAIL="${VERTEX_SA_ID}@${PROJECT_ID}.iam.gserviceaccount.com"
echo "==> Vertex runner SA…"
gcloud iam service-accounts describe "$VERTEX_SA_EMAIL" >/dev/null 2>&1 || \
  gcloud iam service-accounts create "$VERTEX_SA_ID" --display-name "Vertex AI Runner"

echo "==> Vertex staging bucket…"
gsutil ls -b "${VERTEX_STAGING_BUCKET}" >/dev/null 2>&1 || gsutil mb -l "$REGION" "${VERTEX_STAGING_BUCKET}"

echo "==> Roles para Vertex runner SA…"
for ROLE in roles/artifactregistry.reader roles/storage.objectAdmin roles/logging.logWriter roles/monitoring.metricWriter roles/aiplatform.user; do
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:${VERTEX_SA_EMAIL}" --role="$ROLE" >/dev/null
done

# --------- Runtime SA (Notebook/Workbench) sin EUC ----------
RUNTIME_SA_EMAIL="${RUNTIME_SA_ID}@${PROJECT_ID}.iam.gserviceaccount.com"
echo "==> Runtime (Notebook) SA sin EUC…"
gcloud iam service-accounts describe "$RUNTIME_SA_EMAIL" >/dev/null 2>&1 || \
  gcloud iam service-accounts create "$RUNTIME_SA_ID" --display-name "Notebook Runner"

for ROLE in roles/aiplatform.user roles/artifactregistry.reader roles/storage.objectAdmin roles/logging.logWriter roles/monitoring.metricWriter; do
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:${RUNTIME_SA_EMAIL}" --role="$ROLE" >/dev/null
done

# --------- (Opcional) Crear Workbench Managed Runtime con SA ----------
# NOTA: esto crea un runtime simple como cliente; ajusta la imagen si usas container propio.
RUNTIME_NAME="nb-ray-client"
echo "==> (Opcional) Creando Workbench Managed Runtime con SA (sin EUC)…"
gcloud notebooks runtimes describe "$RUNTIME_NAME" --location="$ZONE" >/dev/null 2>&1 || \
  gcloud notebooks runtimes create "$RUNTIME_NAME" \
    --location="$ZONE" \
    --runtime-type=managed \
    --machine-type=n2-standard-8 \
    --vm-image-project=deeplearning-platform-release \
    --vm-image-family=common-cpu-notebooks \
    --service-account="${RUNTIME_SA_EMAIL}" \
    --boot-disk-size=100GB

# --------- Salidas ----------
PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format="value(projectNumber)")

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



