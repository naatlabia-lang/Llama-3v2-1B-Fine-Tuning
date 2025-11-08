#!/usr/bin/env bash
set -euo pipefail
# CREATE IN GCP ...
# =========================
# Bootstrap GCP Monorepo IaaC-lite
# - Crea Service Account (SA)
# - Configura Workload Identity Federation (WIF) para CI
# - Crea Artifact Registry (2 repos: worker y job)
# - Crea GCS bucket
# - Crea Pub/Sub (topic + sub)
# - Crea BigQuery dataset
# - Habilita APIs necesarias
#
# Uso típico (piped):
# curl -fsSL <URL>/bootstrap_gcp.sh | bash -s -- \
#   --project <PROJECT_ID> --region <REGION> \
#   --bucket <BUCKET_NAME> --dataset <BQ_DATASET> \
#   --topic <PUBSUB_TOPIC> --sub <PUBSUB_SUB> \
#   --wip <WIP_NAME> --wip-provider <WIP_PROVIDER_NAME> \
#   --issuer <OIDC_ISSUER_URI> --gh-org <GH_ORG> --gh-repo <GH_REPO>
#
# Ejemplo (GitHub OIDC):
# --issuer "https://token.actions.githubusercontent.com" \
# --gh-org "octavio-org" --gh-repo "monorepo-worker-job"
# =========================

# --------- Defaults ---------
PROJECT_ID=""
REGION="us-central1"
AR_FORMAT="docker"
AR_LOC="us"                 # Artifact Registry location (multi-region)
WORKER_REPO="worker"
JOB_REPO="job"

BUCKET_NAME=""
PUBSUB_TOPIC="worker-job-topic"
PUBSUB_SUB="worker-job-sub"
BQ_DATASET="wrkjob_ds"
BQ_LOC="US"

SA_ID="wrkjob-ci"
SA_DISPLAY="CI for worker+job"
# Workload Identity Pool / Provider (para OIDC GitHub u otro IdP)
WIP_NAME="wrkjob-pool"
WIP_PROVIDER_NAME="github"
OIDC_ISSUER_URI=""     # e.g. https://token.actions.githubusercontent.com
GH_ORG=""              # GitHub org
GH_REPO=""             # GitHub repo

# --------- Args ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --project) PROJECT_ID="$2"; shift 2;;
    --region) REGION="$2"; shift 2;;
    --bucket) BUCKET_NAME="$2"; shift 2;;
    --dataset) BQ_DATASET="$2"; shift 2;;
    --dataset-location|--bq-location) BQ_LOC="$2"; shift 2;;
    --topic) PUBSUB_TOPIC="$2"; shift 2;;
    --sub) PUBSUB_SUB="$2"; shift 2;;
    --sa-id) SA_ID="$2"; shift 2;;
    --sa-display) SA_DISPLAY="$2"; shift 2;;
    --wip) WIP_NAME="$2"; shift 2;;
    --wip-provider) WIP_PROVIDER_NAME="$2"; shift 2;;
    --issuer) OIDC_ISSUER_URI="$2"; shift 2;;
    --gh-org) GH_ORG="$2"; shift 2;;
    --gh-repo) GH_REPO="$2"; shift 2;;
    *) echo "Arg no reconocido: $1"; exit 1;;
  esac
done

# --------- Validaciones ----------
if ! command -v gcloud >/dev/null 2>&1; then
  echo "gcloud no está instalado."; exit 1
fi

if [[ -z "$PROJECT_ID" ]]; then
  echo "--project es requerido"; exit 1
fi

gcloud config set project "$PROJECT_ID" >/dev/null

# Bucket por defecto si no se pasa
if [[ -z "$BUCKET_NAME" ]]; then
  BUCKET_NAME="${PROJECT_ID}-wrkjob-bucket"
fi

echo "Proyecto: $PROJECT_ID"
echo "Región:   $REGION"
echo "AR loc:   $AR_LOC"
echo "Bucket:   $BUCKET_NAME"
echo "Dataset:  $BQ_DATASET ($BQ_LOC)"
echo "Topic/Sub: $PUBSUB_TOPIC / $PUBSUB_SUB"
echo "SA:       $SA_ID"
echo "WIF:      pool=$WIP_NAME provider=$WIP_PROVIDER_NAME issuer=$OIDC_ISSUER_URI"
echo "GitHub:   $GH_ORG/$GH_REPO"
echo

# --------- Habilitar APIs ----------
echo "Habilitando APIs…"
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
  --project "$PROJECT_ID"

# --------- Service Account ----------
echo "Creando Service Account (si no existe)…"
if ! gcloud iam service-accounts describe "${SA_ID}@${PROJECT_ID}.iam.gserviceaccount.com" >/dev/null 2>&1; then
  gcloud iam service-accounts create "$SA_ID" \
    --display-name "$SA_DISPLAY"
fi

SA_EMAIL="${SA_ID}@${PROJECT_ID}.iam.gserviceaccount.com"

# --------- Roles a la SA (mínimos para CI) ----------
echo "Asignando roles a la SA…"
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

# --------- Artifact Registry (dos repos) ----------
echo "Creando Artifact Registry repos…"
for REPO in "$WORKER_REPO" "$JOB_REPO"; do
  if ! gcloud artifacts repositories describe "$REPO" --location="$AR_LOC" >/dev/null 2>&1; then
    gcloud artifacts repositories create "$REPO" \
      --repository-format="$AR_FORMAT" \
      --location="$AR_LOC" \
      --description="Repo for ${REPO} images"
  fi
done

echo "Ejemplos de tags:"
echo "  $AR_LOC-docker.pkg.dev/${PROJECT_ID}/${WORKER_REPO}/worker:<tag>"
echo "  $AR_LOC-docker.pkg.dev/${PROJECT_ID}/${JOB_REPO}/job:<tag>"
echo

# --------- GCS Bucket ----------
echo "Creando bucket GCS…"
if ! gsutil ls -b "gs://${BUCKET_NAME}" >/dev/null 2>&1; then
  gsutil mb -l "$REGION" "gs://${BUCKET_NAME}"
  gsutil uniformbucketlevelaccess set on "gs://${BUCKET_NAME}"
fi

# --------- Pub/Sub ----------
echo "Creando Pub/Sub…"
if ! gcloud pubsub topics describe "$PUBSUB_TOPIC" >/dev/null 2>&1; then
  gcloud pubsub topics create "$PUBSUB_TOPIC"
fi

if ! gcloud pubsub subscriptions describe "$PUBSUB_SUB" >/dev/null 2>&1; then
  gcloud pubsub subscriptions create "$PUBSUB_SUB" --topic="$PUBSUB_TOPIC"
fi

# --------- BigQuery ----------
echo "Creando BigQuery dataset…"
if ! bq --project_id="$PROJECT_ID" show --format=none "$BQ_DATASET" >/dev/null 2>&1; then
  bq --location="$BQ_LOC" mk --dataset "$PROJECT_ID:$BQ_DATASET"
fi

# --------- Workload Identity Federation (GitHub OIDC) ----------
if [[ -n "$OIDC_ISSUER_URI" && -n "$GH_ORG" && -n "$GH_REPO" ]]; then
  echo "Configurando Workload Identity Federation…"
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

  PROVIDER_FQN="principalSet://iam.googleapis.com/${WIP_ID}/attribute.repository/${GH_ORG}/${GH_REPO}"

  # Permitir que el workflow asuma la SA
  gcloud iam service-accounts add-iam-policy-binding "$SA_EMAIL" \
    --role="roles/iam.workloadIdentityUser" \
    --member="$PROVIDER_FQN" >/dev/null

  echo "WIF listo. Usa en GitHub Actions:"
  echo "  permissions: id-token: write, contents: read"
  echo "  auth via: gcloud auth workforce identity federation…"
fi

# --------- (Opcional) Ray en GKE ----------
cat <<'NOTE'

[Opcional] Instalar Ray en GKE (resumen):
  gcloud container clusters create ray-cluster --zone us-central1-a --num-nodes 3
  gcloud container clusters get-credentials ray-cluster --zone us-central1-a
  kubectl apply -k "github.com/ray-project/kuberay/manifests/cluster-scope-resources?ref=v1.1.0"
  kubectl create ns ray
  kubectl apply -n ray -f https://raw.githubusercontent.com/ray-project/kuberay/release-1.1.0/ray-cluster.manifest.yaml

(Coméntalo en tu CI si quieres automatizarlo.)
NOTE

# --------- Salida útil ----------
echo
echo "Login Docker a Artifact Registry:"
echo "  gcloud auth configure-docker ${AR_LOC}-docker.pkg.dev -q"
echo
echo "Push imágenes:"
echo "  docker build -t ${AR_LOC}-docker.pkg.dev/${PROJECT_ID}/${WORKER_REPO}/worker:dev ./worker"
echo "  docker push ${AR_LOC}-docker.pkg.dev/${PROJECT_ID}/${WORKER_REPO}/worker:dev"
echo "  docker build -t ${AR_LOC}-docker.pkg.dev/${PROJECT_ID}/${JOB_REPO}/job:dev ./job"
echo "  docker push ${AR_LOC}-docker.pkg.dev/${PROJECT_ID}/${JOB_REPO}/job:dev"
echo
echo "DONE .........."
