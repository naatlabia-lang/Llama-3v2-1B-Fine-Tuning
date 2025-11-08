#!/usr/bin/env bash
set -euo pipefail

# ==========================================================
#  Bootstrap para monorepo worker/job en GCP + Vertex + WIF
#  - Habilita APIs
#  - Crea SA de CI + WIF (GitHub OIDC)
#  - Crea Artifact Registry (worker, job)
#  - Crea GCS bucket, Pub/Sub, BigQuery
#  - Prepara Vertex AI (SA runner, bucket staging, permisos)
# ==========================================================

# --------- Config HARD-CODEADA ---------
PROJECT_ID="llama-3v2-1b-fine-tuning"
REGION="us-central1"

# Artifact Registry
AR_LOC="us"          # us | eu | asia
AR_FORMAT="docker"
WORKER_REPO="worker" # nombre del repositorio en AR (no la imagen)
JOB_REPO="job"

# Recursos varios
BUCKET_NAME="${PROJECT_ID}-wrkjob-bucket"
PUBSUB_TOPIC="worker-job-topic"
PUBSUB_SUB="worker-job-sub"
BQ_DATASET="wrkjob_ds"
BQ_LOC="US"

# CI (GitHub Actions) - Service Account y WIF
SA_ID="wrkjob-ci"
SA_DISPLAY="CI for worker+job"
WIP_NAME="wrkjob-pool"
WIP_PROVIDER_NAME="github"
OIDC_ISSUER_URI="https://token.actions.githubusercontent.com"
GH_ORG="naatlabia-lang"
GH_REPO="Llama-3v2-1B-Fine-Tuning"

# Vertex AI runner
VERTEX_SA_ID="vertex-runner"
VERTEX_STAGING_BUCKET="gs://${PROJECT_ID}-vertex-staging"

echo "==> Proyecto: $PROJECT_ID"
gcloud config set project "$PROJECT_ID" >/dev/null

# --------- Habilitar APIs ----------
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
  --project "$PROJECT_ID"

# --------- Service Account de CI ----------
SA_EMAIL="${SA_ID}@${PROJECT_ID}.iam.gserviceaccount.com"
echo "==> Creando SA de CI (si no existe): $SA_EMAIL"
if ! gcloud iam service-accounts describe "$SA_EMAIL" >/dev/null 2>&1; then
  gcloud iam service-accounts create "$SA_ID" --display-name "$SA_DISPLAY"
fi

echo "==> Asignando roles mínimos a la SA de CI…"
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/artifactregistry.writer" >/dev/null
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/storage.admin" >/dev/null
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/pubsub.editor" >/dev/null
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/bigquery.dataEditor" >/dev/null
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/bigquery.jobUser" >/dev/null

# --------- Artifact Registry (2 repos) ----------
echo "==> Creando repositorios en Artifact Registry (${AR_LOC})…"
for REPO in "$WORKER_REPO" "$JOB_REPO"; do
  if ! gcloud artifacts repositories describe "$REPO" --location="$AR_LOC" >/dev/null 2>&1; then
    gcloud artifacts repositories create "$REPO" \
      --repository-format="$AR_FORMAT" \
      --location="$AR_LOC" \
      --description="Repo for ${REPO} images"
  fi
done

# --------- GCS Bucket ----------
echo "==> Creando bucket GCS de app…"
if ! gsutil ls -b "gs://${BUCKET_NAME}" >/dev/null 2>&1; then
  gsutil mb -l "$REGION" "gs://${BUCKET_NAME}"
  gsutil uniformbucketlevelaccess set on "gs://${BUCKET_NAME}"
fi

# --------- Pub/Sub ----------
echo "==> Creando Pub/Sub…"
if ! gcloud pubsub topics describe "$PUBSUB_TOPIC" >/dev/null 2>&1; then
  gcloud pubsub topics create "$PUBSUB_TOPIC"
fi
if ! gcloud pubsub subscriptions describe "$PUBSUB_SUB" >/dev/null 2>&1; then
  gcloud pubsub subscriptions create "$PUBSUB_SUB" --topic="$PUBSUB_TOPIC"
fi

# --------- BigQuery ----------
echo "==> Creando dataset de BigQuery…"
if ! bq --project_id="$PROJECT_ID" show --format=none "$BQ_DATASET" >/dev/null 2>&1; then
  bq --location="$BQ_LOC" mk --dataset "$PROJECT_ID:$BQ_DATASET"
fi

# --------- Workload Identity Federation (GitHub OIDC) ----------
echo "==> Configurando Workload Identity Federation (GitHub OIDC)…"
# Pool
if ! gcloud iam workload-identity-pools describe "$WIP_NAME" --location="global" >/dev/null 2>&1; then
  gcloud iam workload-identity-pools create "$WIP_NAME" \
    --location="global" \
    --display-name="$WIP_NAME"
fi
WIP_ID=$(gcloud iam workload-identity-pools describe "$WIP_NAME" --location="global" --format="value(name)")

# Provider
if ! gcloud iam workload-identity-pools providers describe "$WIP_PROVIDER_NAME" --workload-identity-pool="$WIP_NAME" --location="global" >/dev/null 2>&1; then
  gcloud iam workload-identity-pools providers create-oidc "$WIP_PROVIDER_NAME" \
    --workload-identity-pool="$WIP_NAME" \
    --location="global" \
    --display-name="$WIP_PROVIDER_NAME" \
    --issuer-uri="$OIDC_ISSUER_URI" \
    --attribute-mapping="google.subject=assertion.sub,attribute.actor=assertion.actor,attribute.repository=assertion.repository"
fi

# Permitir que el repo GH asuma la SA de CI
PROVIDER_FQN="principalSet://iam.googleapis.com/${WIP_ID}/attribute.repository/${GH_ORG}/${GH_REPO}"
gcloud iam service-accounts add-iam-policy-binding "$SA_EMAIL" \
  --role="roles/iam.workloadIdentityUser" \
  --member="$PROVIDER_FQN" >/dev/null

# --------- Vertex AI: SA runner + staging bucket + permisos ----------
echo "==> Configurando Vertex AI (runner SA + staging bucket + perms)…"
VERTEX_SA_EMAIL="${VERTEX_SA_ID}@${PROJECT_ID}.iam.gserviceaccount.com"
if ! gcloud iam service-accounts describe "$VERTEX_SA_EMAIL" >/dev/null 2>&1; then
  gcloud iam service-accounts create "$VERTEX_SA_ID" \
    --display-name "Vertex AI Runner"
fi

# Bucket de staging de Vertex
if ! gsutil ls -b "${VERTEX_STAGING_BUCKET}" >/dev/null 2>&1; then
  gsutil mb -l "$REGION" "${VERTEX_STAGING_BUCKET}"
fi

# Permisos mínimos para ejecutar CustomJobs
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${VERTEX_SA_EMAIL}" \
  --role="roles/artifactregistry.reader" >/dev/null
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${VERTEX_SA_EMAIL}" \
  --role="roles/storage.objectAdmin" >/dev/null
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${VERTEX_SA_EMAIL}" \
  --role="roles/logging.logWriter" >/dev/null
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${VERTEX_SA_EMAIL}" \
  --role="roles/monitoring.metricWriter" >/dev/null
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${VERTEX_SA_EMAIL}" \
  --role="roles/aiplatform.user" >/dev/null

# --------- Salidas útiles ----------
PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format="value(projectNumber)")

echo
echo "==================== INFO PARA GITHUB ACTIONS ===================="
echo "Secrets:"
echo "  GCP_SERVICE_ACCOUNT            = ${SA_EMAIL}"
echo "  GCP_WORKLOAD_IDENTITY_PROVIDER = projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${WIP_NAME}/providers/${WIP_PROVIDER_NAME}"
echo
echo "Variables:"
echo "  PROJECT_ID         = ${PROJECT_ID}"
echo "  AR_LOC             = ${AR_LOC}"
echo "  WORKER_REPO        = ${WORKER_REPO}"
echo "  JOB_REPO           = ${JOB_REPO}"
echo "  WORKER_TORCH_DEVICE= cpu   # o cu121"
echo "  JOB_TORCH_DEVICE   = cpu   # o cu121"
echo
echo "Imágenes (AR):"
echo "  ${AR_LOC}-docker.pkg.dev/${PROJECT_ID}/${WORKER_REPO}/worker:<tag>"
echo "  ${AR_LOC}-docker.pkg.dev/${PROJECT_ID}/${JOB_REPO}/job:<tag>"
echo
echo "Vertex AI:"
echo "  RUNNER_SA          = ${VERTEX_SA_EMAIL}"
echo "  STAGING_BUCKET     = ${VERTEX_STAGING_BUCKET}"
echo "  Región             = ${REGION}"
echo "=================================================================="

echo
echo "Login Docker a Artifact Registry:"
echo "  gcloud auth configure-docker ${AR_LOC}-docker.pkg.dev -q"
echo
echo "Push manual (ejemplo):"
echo "  docker build -t ${AR_LOC}-docker.pkg.dev/${PROJECT_ID}/${WORKER_REPO}/worker:dev ./worker"
echo "  docker push ${AR_LOC}-docker.pkg.dev/${PROJECT_ID}/${WORKER_REPO}/worker:dev"
echo "  docker build -t ${AR_LOC}-docker.pkg.dev/${PROJECT_ID}/${JOB_REPO}/job:dev ./job"
echo "  docker push ${AR_LOC}-docker.pkg.dev/${PROJECT_ID}/${JOB_REPO}/job:dev"
echo
echo "------------------------------ DONE ---------------------------------"
