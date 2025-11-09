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

# Limpieza previa
CLEAN_SLATE=true    # ← pon false si no quieres borrar
DRYRUN=false        # ← true = sólo mostrar comandos
SKIP_WIF_DELETE=${SKIP_WIF_DELETE:-false}  # export SKIP_WIF_DELETE=true para saltar WIF

# ===================== HELPERS =====================
cecho(){ echo -e "\033[1;36m==>\033[0m $*"; }
wecho(){ echo -e "\033[1;33m[SKIP]\033[0m $*"; }
eecho(){ echo -e "\033[1;31m[ERR]\033[0m $*"; }
doit(){ if [[ "$DRYRUN" == "true" ]]; then echo "+ $*"; else eval "$@"; fi; }
exists(){ eval "$1" >/dev/null 2>&1; } # exists "gcloud ... describe ..."

wait_sa(){
  local EMAIL="$1"
  for _ in {1..60}; do
    exists "gcloud iam service-accounts describe '$EMAIL'" && return 0
    sleep 1
  done
  eecho "Timeout esperando SA: $EMAIL"; exit 1
}

gcloud config set project "$PROJECT_ID" >/dev/null
PROJECT_NUMBER="$(gcloud projects describe "$PROJECT_ID" --format="value(projectNumber)")"
SA_EMAIL="${SA_ID}@${PROJECT_ID}.iam.gserviceaccount.com"
VERTEX_SA_EMAIL="${VERTEX_SA_ID}@${PROJECT_ID}.iam.gserviceaccount.com"
RUNTIME_SA_EMAIL="${RUNTIME_SA_ID}@${PROJECT_ID}.iam.gserviceaccount.com"

# ===================== CLEANUP (VALIDADO) =====================
if [[ "$CLEAN_SLATE" == "true" ]]; then
  cecho "CLEAN_SLATE=true  DRYRUN=$DRYRUN — iniciando borrado seguro (con validación)…"

  # 1) Workbench Runtime (instance)
  cecho "Borrando Workbench instance (si existe)…"
  if exists "gcloud notebooks instances describe '$RUNTIME_NAME' --location='$ZONE'"; then
    doit gcloud notebooks instances delete "$RUNTIME_NAME" --location="$ZONE" --quiet
  else wecho "Instance no existe: $RUNTIME_NAME"; fi

  # 2) Pub/Sub
  cecho "Borrando Pub/Sub…"
  if exists "gcloud pubsub subscriptions describe '$PUBSUB_SUB'"; then
    doit gcloud pubsub subscriptions delete "$PUBSUB_SUB"
  else wecho "Subscription no existe: $PUBSUB_SUB"; fi
  if exists "gcloud pubsub topics describe '$PUBSUB_TOPIC'"; then
    doit gcloud pubsub topics delete "$PUBSUB_TOPIC"
  else wecho "Topic no existe: $PUBSUB_TOPIC"; fi

  # 3) BigQuery dataset
  cecho "Borrando BigQuery dataset (recursivo)…"
  if exists "bq --project_id='$PROJECT_ID' show --format=none '$BQ_DATASET'"; then
    doit bq --project_id="$PROJECT_ID" rm -r -f -d "$PROJECT_ID:$BQ_DATASET"
  else wecho "BQ dataset no existe: $BQ_DATASET"; fi

  # 4) Buckets GCS
  cecho "Borrando buckets GCS…"
  if gsutil ls -b "gs://${BUCKET_NAME}" >/dev/null 2>&1; then
    doit gsutil -m rm -r "gs://${BUCKET_NAME}" >/dev/null 2>&1 || true
  else wecho "Bucket no existe: gs://${BUCKET_NAME}"; fi
  if gsutil ls -b "${VERTEX_STAGING_BUCKET}" >/dev/null 2>&1; then
    doit gsutil -m rm -r "${VERTEX_STAGING_BUCKET}" >/dev/null 2>&1 || true
  else wecho "Bucket no existe: ${VERTEX_STAGING_BUCKET}"; fi

  # 5) Artifact Registry repos
  cecho "Borrando repos de Artifact Registry…"
  for REPO in "$WORKER_REPO" "$JOB_REPO"; do
    if exists "gcloud artifacts repositories describe '$REPO' --location='$AR_LOC'"; then
      IMAGES="$(gcloud artifacts docker images list "$AR_LOC-docker.pkg.dev/$PROJECT_ID/$REPO" --format="value(IMAGE)" 2>/dev/null || true)"
      if [[ -n "${IMAGES}" ]]; then
        while read -r IMG; do
          [[ -z "$IMG" ]] && continue
          doit gcloud artifacts docker images delete "$IMG" --delete-tags --quiet >/dev/null 2>&1 || true
        done <<< "$IMAGES"
      fi
      doit gcloud artifacts repositories delete "$REPO" --location="$AR_LOC" --quiet >/dev/null 2>&1 || true
    else wecho "Repo AR no existe: $REPO ($AR_LOC)"; fi
  done

  # 6) WIF Provider y Pool (ultra-robusto y silencioso)
  cecho "Borrando WIF provider/pool… (SKIP_WIF_DELETE=$SKIP_WIF_DELETE)"
  if [[ "$SKIP_WIF_DELETE" == "true" ]]; then
    wecho "Saltando borrado de WIF por bandera."
  else
    ACTIVE_PROJECT="$(gcloud config get-value project)"
    ACTIVE_ACCOUNT="$(gcloud config get-value account)"
    cecho "Proyecto activo: ${ACTIVE_PROJECT} | Cuenta activa: ${ACTIVE_ACCOUNT}"

    if gcloud iam workload-identity-pools describe "$WIP_NAME" --location=global >/dev/null 2>&1; then
      if gcloud iam workload-identity-pools providers describe "$WIP_PROVIDER_NAME" \
           --workload-identity-pool="$WIP_NAME" --location=global >/dev/null 2>&1; then
        doit gcloud iam workload-identity-pools providers delete "$WIP_PROVIDER_NAME" \
          --workload-identity-pool="$WIP_NAME" --location=global --quiet >/dev/null 2>&1 || \
          wecho "No se pudo borrar provider (permiso/fallo benigno): $WIP_PROVIDER_NAME"
      else
        wecho "WIF provider no existe: $WIP_PROVIDER_NAME"
      fi

      if gcloud iam workload-identity-pools describe "$WIP_NAME" --location=global >/dev/null 2>&1; then
        doit gcloud iam workload-identity-pools delete "$WIP_NAME" \
          --location=global --quiet >/dev/null 2>&1 || \
          wecho "No se pudo borrar pool (no existe o sin permiso): $WIP_NAME"
      else
        wecho "WIF pool ya no existe tras borrar provider: $WIP_NAME"
      fi
    else
      wecho "WIF pool no existe o no es visible (NOT_FOUND). Continuando…"
    fi
  fi

  # 7) Service Accounts
  cecho "Borrando Service Accounts…"
  for SA in "$RUNTIME_SA_EMAIL" "$VERTEX_SA_EMAIL" "$SA_EMAIL"; do
    if exists "gcloud iam service-accounts describe '$SA'"; then
      doit gcloud iam service-accounts delete "$SA" --quiet >/dev/null 2>&1 || true
    else wecho "SA no existe: $SA"; fi
  done
fi

# ===================== ENABLE APIS =====================
cecho "Habilitando APIs…"
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
cecho "Creando SA de CI…"
gcloud iam service-accounts create "$SA_ID" --display-name="$SA_DISPLAY" >/dev/null 2>&1 || true
wait_sa "$SA_EMAIL"

cecho "Roles para SA de CI…"
for ROLE in roles/artifactregistry.writer roles/storage.admin roles/pubsub.editor roles/bigquery.dataEditor roles/bigquery.jobUser; do
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:${SA_EMAIL}" --role="$ROLE" >/dev/null 2>&1 || true
done

cecho "Creando Vertex runner SA…"
gcloud iam service-accounts create "$VERTEX_SA_ID" --display-name="Vertex AI Runner" >/dev/null 2>&1 || true
wait_sa "$VERTEX_SA_EMAIL"
for ROLE in roles/artifactregistry.reader roles/storage.objectAdmin roles/logging.logWriter roles/monitoring.metricWriter roles/aiplatform.user; do
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:${VERTEX_SA_EMAIL}" --role="$ROLE" >/dev/null 2>&1 || true
done

cecho "Creando Runtime (Notebook) SA…"
gcloud iam service-accounts create "$RUNTIME_SA_ID" --display-name="Notebook Runner" >/dev/null 2>&1 || true
wait_sa "$RUNTIME_SA_EMAIL"
for ROLE in roles/aiplatform.user roles/artifactregistry.reader roles/storage.objectAdmin roles/logging.logWriter roles/monitoring.metricWriter; do
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:${RUNTIME_SA_EMAIL}" --role="$ROLE" >/dev/null 2>&1 || true
done

# ===================== WIF POR REPO (con retry/perm checks) =====================
cecho "Configurando WIF (por repo)…"

POOL_OK=true
PROV_OK=true

# 1) Pool (create if missing)
gcloud iam workload-identity-pools describe "$WIP_NAME" --location=global >/dev/null 2>&1 || \
gcloud iam workload-identity-pools create "$WIP_NAME" \
  --location=global --display-name="$WIP_NAME" >/dev/null 2>&1 || POOL_OK=false

if [[ "$POOL_OK" != "true" ]]; then
  eecho "No pude crear/ver el pool '$WIP_NAME'. ¿Tienes roles/iam.workloadIdentityPoolAdmin?"
  wecho "Salto configuración WIF; puedes reintentar luego."
else
  # 2) Provider (create if missing)
  gcloud iam workload-identity-pools providers describe "$WIP_PROVIDER_NAME" \
    --workload-identity-pool="$WIP_NAME" --location=global >/dev/null 2>&1 || \
  gcloud iam workload-identity-pools providers create-oidc "$WIP_PROVIDER_NAME" \
    --workload-identity-pool="$WIP_NAME" \
    --location=global \
    --display-name="$WIP_PROVIDER_NAME" \
    --issuer-uri="$OIDC_ISSUER_URI" \
    --attribute-mapping="google.subject=assertion.sub,attribute.actor=assertion.actor,attribute.repository=assertion.repository" \
    --attribute-condition="attribute.repository=='${GH_ORG}/${GH_REPO}'" >/dev/null 2>&1 || PROV_OK=false

  # 3) Espera a que el provider exista (propagación IAM)
  if [[ "$PROV_OK" == "true" ]]; then
    for _ in {1..60}; do
      if gcloud iam workload-identity-pools providers describe "$WIP_PROVIDER_NAME" \
           --workload-identity-pool="$WIP_NAME" --location=global >/dev/null 2>&1; then
        break
      fi
      sleep 1
    done
    if ! gcloud iam workload-identity-pools providers describe "$WIP_PROVIDER_NAME" \
         --workload-identity-pool="$WIP_NAME" --location=global >/dev/null 2>&1; then
      PROV_OK=false
    fi
  fi

  if [[ "$PROV_OK" != "true" ]]; then
    eecho "No pude crear/ver el provider '$WIP_PROVIDER_NAME' en el pool '$WIP_NAME'."
    eecho "Verifica permisos: roles/iam.workloadIdentityPoolAdmin para la cuenta $(gcloud config get-value account)."
    eecho "Confirma repo objetivo: ${GH_ORG}/${GH_REPO}"
  else
    # 4) FQN y binding a la SA de CI
    PROVIDER_FQN="$(gcloud iam workload-identity-pools providers describe "$WIP_PROVIDER_NAME" \
      --workload-identity-pool="$WIP_NAME" --location=global --format='value(name)')"

    if [[ -z "${PROVIDER_FQN}" ]]; then
      eecho "No obtuve PROVIDER_FQN, salto el binding. Reintenta luego."
    else
      gcloud iam service-accounts add-iam-policy-binding "$SA_EMAIL" \
        --role="roles/iam.workloadIdentityUser" \
        --member="principalSet://iam.googleapis.com/${PROVIDER_FQN}/attribute.repository/${GH_ORG}/${GH_REPO}" >/dev/null 2>&1 || \
        wecho "No pude bindear WorkloadIdentityUser (permiso insuficiente)."
    fi
  fi
fi
# ===================== ARTIFACT REGISTRY =====================
cecho "Creando repos de Artifact Registry (regional: $AR_LOC)…"
for REPO in "$WORKER_REPO" "$JOB_REPO"; do
  gcloud artifacts repositories describe "$REPO" --location="$AR_LOC" >/dev/null 2>&1 || \
    gcloud artifacts repositories create "$REPO" \
      --repository-format="$AR_FORMAT" --location="$AR_LOC" \
      --description="Repo for ${REPO} images" >/dev/null 2>&1
done

# ===================== STORAGE / PUBSUB / BQ =====================
cecho "Creando bucket GCS de app…"
gsutil ls -b "gs://${BUCKET_NAME}" >/dev/null 2>&1 || {
  doit gsutil mb -l "$REGION" "gs://${BUCKET_NAME}"
  doit gsutil uniformbucketlevelaccess set on "gs://${BUCKET_NAME}"
}

cecho "Creando Pub/Sub…"
exists "gcloud pubsub topics describe '$PUBSUB_TOPIC'" || doit gcloud pubsub topics create "$PUBSUB_TOPIC"
exists "gcloud pubsub subscriptions describe '$PUBSUB_SUB'" || doit gcloud pubsub subscriptions create "$PUBSUB_SUB" --topic="$PUBSUB_TOPIC"

cecho "Creando dataset BigQuery…"
exists "bq --project_id='$PROJECT_ID' show --format=none '$BQ_DATASET'" || doit bq --location="$BQ_LOC" mk --dataset "$PROJECT_ID:$BQ_DATASET"

# ===================== VERTEX STAGING BUCKET =====================
cecho "Creando Vertex staging bucket…"
gsutil ls -b "${VERTEX_STAGING_BUCKET}" >/dev/null 2>&1 || doit gsutil mb -l "$REGION" "${VERTEX_STAGING_BUCKET}"

# ===================== (OPCIONAL) WORKBENCH INSTANCE (cliente) =====================
cecho "Creando Workbench Instance (cliente, sin EUC)…"
exists "gcloud notebooks instances describe '$RUNTIME_NAME' --location='$ZONE'" || \
  doit gcloud notebooks instances create "$RUNTIME_NAME" \
    --location="$ZONE" \
    --vm-image-project=deeplearning-platform-release \
    --vm-image-family=common-cpu-notebooks \
    --machine-type=n2-standard-8 \
    --service-account="${RUNTIME_SA_EMAIL}" \
    --boot-disk-size=100 \
    --boot-disk-type=pd-ssd \
    --no-public-ip

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

Workbench Instance (cliente):
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
