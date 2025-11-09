#!/usr/bin/env bash
set -euo pipefail

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

# CI (GitHub Actions) - SA + WIF (por repo)
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

# BORRAR TODO ANTES (extremadamente destructivo)
CLEAN_SLATE=true    # ← pon en false si no quieres borrar
DRYRUN=false        # true = sólo mostrar; false = ejecutar
# ===================================================

# Helpers
log() { echo -e "\033[1;36m==>\033[0m $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
doit() { if [[ "$DRYRUN" == "true" ]]; then echo "+ $*"; else eval "$@"; fi; }

gcloud config set project "$PROJECT_ID" >/dev/null

PROJECT_NUMBER="$(gcloud projects describe "$PROJECT_ID" --format="value(projectNumber)")"
SA_EMAIL="${SA_ID}@${PROJECT_ID}.iam.gserviceaccount.com"
VERTEX_SA_EMAIL="${VERTEX_SA_ID}@${PROJECT_ID}.iam.gserviceaccount.com"
RUNTIME_SA_EMAIL="${RUNTIME_SA_ID}@${PROJECT_ID}.iam.gserviceaccount.com"

# ===================== CLEANUP =====================
if [[ "$CLEAN_SLATE" == "true" ]]; then
  warn "CLEAN_SLATE=true → Se eliminarán recursos. DRYRUN=$DRYRUN"

  # 1) Workbench Runtime
  log "Borrando Workbench runtime (si existe)…"
  if gcloud notebooks runtimes describe "$RUNTIME_NAME" --location="$ZONE" >/dev/null 2>&1; then
    doit gcloud notebooks runtimes delete "$RUNTIME_NAME" --location="$ZONE" --quiet
  fi

  # 2) Pub/Sub
  log "Borrando Pub/Sub (topic/sub)…"
  if gcloud pubsub subscriptions describe "$PUBSUB_SUB" >/dev/null 2>&1; then
    doit gcloud pubsub subscriptions delete "$PUBSUB_SUB"
  fi
  if gcloud pubsub topics describe "$PUBSUB_TOPIC" >/dev/null 2>&1; then
    doit gcloud pubsub topics delete "$PUBSUB_TOPIC"
  fi

  # 3) BigQuery dataset (recursivo)
  log "Borrando BigQuery dataset (recursivo)…"
  if bq --project_id="$PROJECT_ID" show --format=none "$BQ_DATASET" >/dev/null 2>&1; then
    doit bq --project_id="$PROJECT_ID" rm -r -f -d "$PROJECT_ID:$BQ_DATASET"
  fi

  # 4) Buckets GCS (app + staging Vertex)
  log "Borrando buckets GCS…"
  if gsutil ls -b "gs://${BUCKET_NAME}" >/dev/null 2>&1; then
    doit gsutil -m rm -r "gs://${BUCKET_NAME}" || true
  fi
  if gsutil ls -b "${VERTEX_STAGING_BUCKET}" >/dev/null 2>&1; then
    doit gsutil -m rm -r "${VERTEX_STAGING_BUCKET}" || true
  fi

  # 5) Artifact Registry repos (borra imágenes y repo)
  log "Borrando repos de Artifact Registry regionales…"
  for REPO in "$WORKER_REPO" "$JOB_REPO"; do
    if gcloud artifacts repositories describe "$REPO" --location="$AR_LOC" >/dev/null 2>&1; then
      # borra paquetes (por si falla eliminación directa)
      for IMG in $(gcloud artifacts docker images list "$AR_LOC-docker.pkg.dev/$PROJECT_ID/$REPO" --format="value(IMAGE)" 2>/dev/null || true); do
        doit gcloud artifacts docker images delete "$IMG" --delete-tags --quiet || true
      done
      doit gcloud artifacts repositories delete "$REPO" --location="$AR_LOC" --quiet || true
    fi
  done

  # 6) WIF: desvincular y borrar provider y pool
  log "Borrando WIF provider/pool y bindings…"
  # Quita binding de la SA de CI para principalSet (si existe)
  if gcloud iam service-accounts describe "$SA_EMAIL" >/dev/null 2>&1; then
    # No hay “remove-binding” directo con principalSet, pero borrar provider/pool invalida el principal
    :
  fi
  # Borrar provider (si existe)
  if gcloud iam workload-identity-pools providers describe "$WIP_PROVIDER_NAME" \
    --workload-identity-pool="$WIP_NAME" --location="global" >/dev/null 2>&1; then
    doit gcloud iam workload-identity-pools providers delete "$WIP_PROVIDER_NAME" \
      --workload-identity-pool="$WIP_NAME" --location="global" --quiet
  fi
  # Borrar pool (si existe)
  if gcloud iam workload-identity-pools describe "$WIP_NAME" --location="global" >/dev/null 2>&1; then
    doit gcloud iam workload-identity-pools delete "$WIP_NAME" --location="global" --quiet
  fi

  # 7) Service Accounts (runtime, vertex, ci) y sus bindings
  log "Borrando Service Accounts…"
  for SA in "$RUNTIME_SA_EMAIL" "$VERTEX_SA_EMAIL" "$SA_EMAIL"; do
    if gcloud iam service-accounts describe "$SA" >/dev/null 2>&1; then
      doit gcloud iam service-accounts delete "$SA" --quiet
    fi
  done
fi

# ===================== ENABLE APIS =====================
log "Habilitando APIs…"
doit gcloud services enable \
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

# ===================== CREATE SAs =====================
log "Creando SA de CI…"
doit gcloud iam service-accounts create "$SA_ID" --display-name "$SA_DISPLAY" || true

log "Roles para SA de CI…"
for ROLE in roles/artifactregistry.writer roles/storage.admin roles/pubsub.editor roles/bigquery.dataEditor roles/bigquery.jobUser; do
  doit gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:${SA_EMAIL}" --role="$ROLE"
done

log "Creando Vertex runner SA…"
doit gcloud iam service-accounts create "$VERTEX_SA_ID" --display-name "Vertex AI Runner" || true
for ROLE in roles/artifactregistry.reader roles/storage.objectAdmin roles/logging.logWriter roles/monitoring.metricWriter roles/aiplatform.user; do
  doit gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:${VERTEX_SA_EMAIL}" --role="$ROLE"
done

log "Creando Runtime (Notebook) SA…"
doit gcloud iam service-accounts create "$RUNTIME_SA_ID" --display-name "Notebook Runner" || true
for ROLE in roles/aiplatform.user roles/artifactregistry.reader roles/storage.objectAdmin roles/logging.logWriter roles/monitoring.metricWriter; do
  doit gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:${RUNTIME_SA_EMAIL}" --role="$ROLE"
done

# ===================== WIF (por REPO) =====================
log "Configurando Workload Identity Federation (por repo)…"
doit gcloud iam workload-identity-pools create "$WIP_NAME" \
  --location="global" --display-name="$WIP_NAME" || true

WIP_ID="$(gcloud iam workload-identity-pools describe "$WIP_NAME" --location=global --format="value(name)")"

# Provider con attribute-condition por repo
doit gcloud iam workload-identity-pools providers create-oidc "$WIP_PROVIDER_NAME" \
  --workload-identity-pool="$WIP_NAME" \
  --location="global" \
  --display-name="$WIP_PROVIDER_NAME" \
  --issuer-uri="$OIDC_ISSUER_URI" \
  --attribute-mapping="google.subject=assertion.sub,attribute.actor=assertion.actor,attribute.repository=assertion.repository" \
  --attribute-condition="assertion.repository=='${GH_ORG}/${GH_REPO}'" || true

PROVIDER_FQN="$(gcloud iam workload-identity-pools providers describe "$WIP_PROVIDER_NAME" \
  --workload-identity-pool="$WIP_NAME" --location=global --format='value(name)')"

# Binding SA CI ← principalSet (repo específico)
doit gcloud iam service-accounts add-iam-policy-binding "$SA_EMAIL" \
  --role="roles/iam.workloadIdentityUser" \
  --member="principalSet://iam.googleapis.com/${PROVIDER_FQN}/attribute.repository/${GH_ORG}/${GH_REPO}"

# ===================== ARTIFACT REGISTRY =====================
log "Creando repos de Artifact Registry (regional: $AR_LOC)…"
for REPO in "$WORKER_REPO" "$JOB_REPO"; do
  doit gcloud artifacts repositories create "$REPO" \
    --repository-format="$AR_FORMAT" --location="$AR_LOC" \
    --description="Repo for ${REPO} images" || true
done

# ===================== STORAGE / PUBSUB / BQ =====================
log "Creando bucket GCS de app…"
doit gsutil mb -l "$REGION" "gs://${BUCKET_NAME}" || true
doit gsutil uniformbucketlevelaccess set on "gs://${BUCKET_NAME}" || true

log "Creando Pub/Sub…"
doit gcloud pubsub topics create "$PUBSUB_TOPIC" || true
doit gcloud pubsub subscriptions create "$PUBSUB_SUB" --topic="$PUBSUB_TOPIC" || true

log "Creando dataset BigQuery…"
doit bq --location="$BQ_LOC" mk --dataset "$PROJECT_ID:$BQ_DATASET" || true

# ===================== VERTEX STAGING BUCKET =====================
log "Creando Vertex staging bucket…"
doit gsutil mb -l "$REGION" "${VERTEX_STAGING_BUCKET}" || true

# ===================== (OPCIONAL) RUNTIME WORKBENCH =====================
log "Creando Workbench Managed Runtime con SA (sin EUC)…"
doit gcloud notebooks runtimes create "$RUNTIME_NAME" \
  --location="$ZONE" \
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

