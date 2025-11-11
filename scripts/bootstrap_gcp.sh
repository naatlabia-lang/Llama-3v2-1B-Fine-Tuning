#!/usr/bin/env bash
set -euo pipefail

# ==========================================================
#  Bootstrap monorepo worker/job en GCP + Vertex + WIF
# ==========================================================

# --------- Config ---------
PROJECT_ID="llama-3v2-1b-fine-tuning"
REGION="us-central1"

# Artifact Registry
AR_LOC="us"               # us | eu | asia
AR_FORMAT="docker"
WORKER_REPO="worker"
JOB_REPO="job"

# Recursos varios
BUCKET_NAME="${PROJECT_ID}-wrkjob-bucket"
PUBSUB_TOPIC="worker-job-topic"
PUBSUB_SUB="worker-job-sub"
BQ_DATASET="wrkjob_ds"
BQ_LOC="US"

# CI (GitHub Actions) - SA y WIF
SA_ID="wrkjob-ci"
SA_DISPLAY="CI for worker+job"
WIP_ID_SHORT="wrkjob-pool"        # ID del pool (estable, sin espacios)
PROVIDER_ID="github"              # ID del provider dentro del pool
OIDC_ISSUER_URI="https://token.actions.githubusercontent.com"
GH_ORG="naatlabia-lang"
GH_REPO="Llama-3v2-1B-Fine-Tuning"

# Condición por repo (puedes dejarla vacía para permitir todo el pool)
ATTR_COND="attribute.repository==\"${GH_ORG}/${GH_REPO}\""

# Vertex AI runner
VERTEX_SA_ID="vertex-runner"
VERTEX_STAGING_BUCKET="gs://${PROJECT_ID}-vertex-staging"

echo "==> Proyecto: $PROJECT_ID"
gcloud config set project "$PROJECT_ID" >/dev/null

PROJECT_NUMBER="$(gcloud projects describe "${PROJECT_ID}" --format='value(projectNumber)')"

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
  --project "$PROJECT_ID" >/dev/null

# --------- SA de CI ----------
SA_EMAIL="${SA_ID}@${PROJECT_ID}.iam.gserviceaccount.com"
echo "==> Creando SA de CI (si no existe): $SA_EMAIL"
gcloud iam service-accounts describe "$SA_EMAIL" --project "$PROJECT_ID" >/dev/null 2>&1 || \
gcloud iam service-accounts create "$SA_ID" --project "$PROJECT_ID" --display-name "$SA_DISPLAY"

echo "==> Asignando roles mínimos a la SA de CI…"
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${SA_EMAIL}" --role="roles/artifactregistry.writer" >/dev/null || true
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${SA_EMAIL}" --role="roles/storage.objectAdmin" >/dev/null || true
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${SA_EMAIL}" --role="roles/pubsub.publisher" >/dev/null || true
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${SA_EMAIL}" --role="roles/bigquery.dataEditor" >/dev/null || true
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${SA_EMAIL}" --role="roles/bigquery.jobUser" >/dev/null || true

# --------- Artifact Registry (2 repos) ----------
echo "==> Creando repositorios en Artifact Registry (${AR_LOC})…"
for REPO in "$WORKER_REPO" "$JOB_REPO"; do
  gcloud artifacts repositories describe "$REPO" --location="$AR_LOC" --project "$PROJECT_ID" >/dev/null 2>&1 || \
  gcloud artifacts repositories create "$REPO" \
    --repository-format="$AR_FORMAT" \
    --location="$AR_LOC" \
    --description="Repo for ${REPO} images" \
    --project "$PROJECT_ID" >/dev/null
done

# --------- GCS Bucket ----------
echo "==> Creando bucket GCS de app…"
gsutil ls -b "gs://${BUCKET_NAME}" >/dev/null 2>&1 || {
  gsutil mb -p "$PROJECT_ID" -l "$REGION" "gs://${BUCKET_NAME}"
  gsutil uniformbucketlevelaccess set on "gs://${BUCKET_NAME}"
}

# --------- Pub/Sub ----------
echo "==> Creando Pub/Sub…"
gcloud pubsub topics describe "$PUBSUB_TOPIC" --project "$PROJECT_ID" >/dev/null 2>&1 || \
gcloud pubsub topics create "$PUBSUB_TOPIC" --project "$PROJECT_ID" >/dev/null
gcloud pubsub subscriptions describe "$PUBSUB_SUB" --project "$PROJECT_ID" >/dev/null 2>&1 || \
gcloud pubsub subscriptions create "$PUBSUB_SUB" --topic="$PUBSUB_TOPIC" --project "$PROJECT_ID" >/dev/null

# --------- BigQuery ----------
echo "==> Creando dataset de BigQuery…"
bq --project_id="$PROJECT_ID" show --format=none "$BQ_DATASET" >/dev/null 2>&1 || \
bq --location="$BQ_LOC" --project_id="$PROJECT_ID" mk --dataset "${PROJECT_ID}:${BQ_DATASET}"

# --------- Workload Identity Federation (GitHub OIDC) ----------
echo "==> Configurando Workload Identity Federation (GitHub OIDC)…"

# NOTA: aquí usamos los IDs (no display names)
WIP_NAME="projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${WIP_ID_SHORT}"
PROVIDER_NAME="${WIP_NAME}/providers/${PROVIDER_ID}"

# Pool (por ID)
gcloud iam workload-identity-pools describe "${WIP_ID_SHORT}" \
  --location=global --project "$PROJECT_ID" >/dev/null 2>&1 || \
gcloud iam workload-identity-pools create "${WIP_ID_SHORT}" \
  --location=global --project "$PROJECT_ID" \
  --display-name="${WIP_ID_SHORT}" >/dev/null

# Provider (por ID) + attribute-mapping completo + condición opcional + allowed-audiences
if ! gcloud iam workload-identity-pools providers describe "${PROVIDER_ID}" \
      --workload-identity-pool="${WIP_ID_SHORT}" --location=global --project "$PROJECT_ID" >/dev/null 2>&1; then

  MAP="google.subject=assertion.sub,attribute.actor=assertion.actor,attribute.repository=assertion.repository,attribute.repository_owner=assertion.repository_owner,attribute.repository_id=assertion.repository_id,attribute.ref=assertion.ref,attribute.workflow=assertion.workflow,attribute.sha=assertion.sha,attribute.event_name=assertion.event_name"

  if [[ -n "${ATTR_COND}" ]]; then
    gcloud iam workload-identity-pools providers create-oidc "${PROVIDER_ID}" \
      --workload-identity-pool="${WIP_ID_SHORT}" \
      --location=global \
      --project "$PROJECT_ID" \
      --display-name="${PROVIDER_ID}" \
      --issuer-uri="${OIDC_ISSUER_URI}" \
      --allowed-audiences="https://github.com/${GH_ORG}" \
      --attribute-mapping="${MAP}" \
      --attribute-condition="${ATTR_COND}" >/dev/null
  else
    gcloud iam workload-identity-pools providers create-oidc "${PROVIDER_ID}" \
      --workload-identity-pool="${WIP_ID_SHORT}" \
      --location=global \
      --project "$PROJECT_ID" \
      --display-name="${PROVIDER_ID}" \
      --issuer-uri="${OIDC_ISSUER_URI}" \
      --allowed-audiences="https://github.com/${GH_ORG}" \
      --attribute-mapping="${MAP}" >/dev/null
  fi
fi

# Binding a la SA (principalSet usa el resource name del pool)
PROVIDER_MEMBER="principalSet://iam.googleapis.com/${WIP_NAME}/attribute.repository/${GH_ORG}/${GH_REPO}"
echo "==> Permitiendo que ${GH_ORG}/${GH_REPO} asuma ${SA_EMAIL}…"
gcloud iam service-accounts add-iam-policy-binding "$SA_EMAIL" \
  --project "$PROJECT_ID" \
  --role="roles/iam.workloadIdentityUser" \
  --member="${PROVIDER_MEMBER}" >/dev/null || true

# --------- Vertex AI: SA runner + staging bucket + permisos ----------
echo "==> Configurando Vertex AI (runner SA + staging bucket + perms)…"
VERTEX_SA_EMAIL="${VERTEX_SA_ID}@${PROJECT_ID}.iam.gserviceaccount.com"
gcloud iam service-accounts describe "$VERTEX_SA_EMAIL" --project "$PROJECT_ID" >/dev/null 2>&1 || \
gcloud iam service-accounts create "$VERTEX_SA_ID" --project "$PROJECT_ID" --display-name "Vertex AI Runner" >/dev/null

gsutil ls -b "${VERTEX_STAGING_BUCKET}" >/dev/null 2>&1 || \
gsutil mb -p "$PROJECT_ID" -l "$REGION" "${VERTEX_STAGING_BUCKET}"

gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${VERTEX_SA_EMAIL}" --role="roles/artifactregistry.reader" >/dev/null || true
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${VERTEX_SA_EMAIL}" --role="roles/storage.objectAdmin" >/dev/null || true
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${VERTEX_SA_EMAIL}" --role="roles/logging.logWriter" >/dev/null || true
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${VERTEX_SA_EMAIL}" --role="roles/monitoring.metricWriter" >/dev/null || true
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${VERTEX_SA_EMAIL}" --role="roles/aiplatform.user" >/dev/null || true

# ===== Permisos finos =====
# Cambia a "train_and_serve" si también vas a crear Model/Endpoint y desplegar online.
PERM_PRESET="${PERM_PRESET:-train_only}"

echo "==> Asignando permisos finos…"

# --- Artifact Registry: writer por repositorio (no a nivel proyecto) ---
for REPO in "$WORKER_REPO" "$JOB_REPO"; do
  gcloud artifacts repositories add-iam-policy-binding "$REPO" \
    --location="$AR_LOC" \
    --member="serviceAccount:${SA_EMAIL}" \
    --role="roles/artifactregistry.writer" \
    --project="$PROJECT_ID" >/dev/null || true
done

# --- GCS: CI solo al bucket de app; Runner solo a staging de Vertex ---
gcloud storage buckets add-iam-policy-binding "gs://${BUCKET_NAME}" \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/storage.objectAdmin" >/dev/null || true

gcloud storage buckets add-iam-policy-binding "${VERTEX_STAGING_BUCKET}" \
  --member="serviceAccount:${VERTEX_SA_EMAIL}" \
  --role="roles/storage.objectAdmin" >/dev/null || true

# --- Pub/Sub: permisos por recurso ---
gcloud pubsub topics add-iam-policy-binding "$PUBSUB_TOPIC" \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/pubsub.publisher" \
  --project="$PROJECT_ID" >/dev/null || true

gcloud pubsub subscriptions add-iam-policy-binding "$PUBSUB_SUB" \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/pubsub.subscriber" \
  --project="$PROJECT_ID" >/dev/null || true

# --- BigQuery: dataEditor solo sobre el dataset (no a nivel proyecto) ---
# Nota: 'bq add-iam-policy-binding' es idempotente y aplica IAM del dataset.
bq --project_id="$PROJECT_ID" add-iam-policy-binding "$BQ_DATASET" \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/bigquery.dataEditor" >/dev/null || true

# jobUser puede quedarse a nivel proyecto (requerido para lanzar jobs de BQ)
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/bigquery.jobUser" >/dev/null || true

# --- Logging/Monitoring básicos (si vas a escribir logs desde CI/Runner) ---
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/logging.logWriter" >/dev/null || true
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${VERTEX_SA_EMAIL}" \
  --role="roles/logging.logWriter" >/dev/null || true
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${VERTEX_SA_EMAIL}" \
  --role="roles/monitoring.metricWriter" >/dev/null || true

# --- Vertex AI: mínimos + opción para servir online ---
# Runner ejecuta entrenamientos/Batch Prediction.
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${VERTEX_SA_EMAIL}" \
  --role="roles/aiplatform.user" >/dev/null || true

# (Opcional) Para crear Jobs que lean/escriban en AR (pull de imagen del job):
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${VERTEX_SA_EMAIL}" \
  --role="roles/artifactregistry.reader" >/dev/null || true

# Si además vas a hacer Model.upload / Endpoint.create / DeployModel:
if [[ "$PERM_PRESET" == "train_and_serve" ]]; then
  # Puedes usar 'aiplatform.admin' (más amplio) o granular:
  # Granular recomendado:
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:${VERTEX_SA_EMAIL}" \
    --role="roles/aiplatform.modelUploader" >/dev/null || true
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:${VERTEX_SA_EMAIL}" \
    --role="roles/aiplatform.endpointAdmin" >/dev/null || true
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:${VERTEX_SA_EMAIL}" \
    --role="roles/aiplatform.deploymentResourceEditor" >/dev/null || true
fi

# --- Impersonación controlada: CI puede usar la Runner SA sin llaves ---
# (Necesario si el pipeline de CI lanza CustomJobs en Vertex impersonando la runner)
gcloud iam service-accounts add-iam-policy-binding "$VERTEX_SA_EMAIL" \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/iam.serviceAccountUser" \
  --project="$PROJECT_ID" >/dev/null || true

# --- Limpiar heredados a nivel proyecto (si los tenías arriba) ---
# (opcional) Puedes retirar roles a nivel proyecto que ya afinaste por recurso:
# gcloud projects remove-iam-policy-binding "$PROJECT_ID" \
#   --member="serviceAccount:${SA_EMAIL}" --role="roles/storage.objectAdmin"
# gcloud projects remove-iam-policy-binding "$PROJECT_ID" \
#   --member="serviceAccount:${SA_EMAIL}" --role="roles/artifactregistry.writer"
# … etc. (hazlo solo si estás seguro de no romper otros flujos)

echo "==> Permisos finos aplicados (preset: ${PERM_PRESET})"

  

# --------- Salidas útiles ----------
echo
echo "==================== INFO PARA GITHUB ACTIONS ===================="
echo "Secrets:"
echo "  GCP_SERVICE_ACCOUNT            = ${SA_EMAIL}"
echo "  GCP_WORKLOAD_IDENTITY_PROVIDER = projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${WIP_ID_SHORT}/providers/${PROVIDER_ID}"
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
