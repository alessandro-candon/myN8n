#!/bin/bash
# =============================================================================
# n8n on Cloud Run - Deployment Script
# Uses GCS bucket volume mount for SQLite persistence
# =============================================================================

set -e

# =============================================================================
# CONFIGURATION
# =============================================================================
PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project)}"
SERVICE_NAME="${SERVICE_NAME:-n8n}"
REGION="${REGION:-europe-west8}"  # Default: Milan, Italy

# Resource configuration (optimized for personal use)
MEMORY="${MEMORY:-1Gi}"
CPU="${CPU:-1}"
MIN_INSTANCES="${MIN_INSTANCES:-0}"
MAX_INSTANCES="${MAX_INSTANCES:-1}"

# Bucket name
BUCKET_NAME="${PROJECT_ID}-n8n-data"

# =============================================================================
# COLORS FOR OUTPUT
# =============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# =============================================================================
# PREFLIGHT CHECKS
# =============================================================================
preflight_checks() {
    log_info "Running preflight checks..."

    if ! command -v gcloud &> /dev/null; then
        log_error "gcloud CLI is not installed. Please install it first."
        exit 1
    fi

    if ! gcloud auth list --filter=status:ACTIVE --format="value(account)" | head -n1 &> /dev/null; then
        log_error "Not authenticated with gcloud. Run: gcloud auth login"
        exit 1
    fi

    if [ -z "$PROJECT_ID" ]; then
        log_error "No project set. Run: gcloud config set project YOUR_PROJECT_ID"
        exit 1
    fi

    log_success "Preflight checks passed. Project: $PROJECT_ID"
}

# =============================================================================
# SELECT REGION
# =============================================================================
select_region() {
    echo ""
    log_info "Select a region for deployment:"
    echo ""
    
    REGIONS=(
        "europe-west1:Belgium (Low CO2)"
        "europe-west8:Milan, Italy"
        "europe-west9:Paris, France"
        "us-central1:Iowa, USA"
        "us-east1:South Carolina, USA"
        "us-west1:Oregon, USA (Low CO2)"
        "asia-east1:Taiwan"
        "asia-northeast1:Tokyo, Japan"
        "australia-southeast1:Sydney"
    )
    
    for i in "${!REGIONS[@]}"; do
        region_code="${REGIONS[$i]%%:*}"
        region_desc="${REGIONS[$i]#*:}"
        printf "  ${GREEN}%d)${NC} %-25s %s\n" $((i+1)) "$region_code" "$region_desc"
    done
    echo ""
    
    while true; do
        read -p "Enter your choice (1-${#REGIONS[@]}): " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#REGIONS[@]}" ]; then
            REGION="${REGIONS[$((choice-1))]%%:*}"
            break
        else
            log_error "Invalid selection. Please enter a number between 1 and ${#REGIONS[@]}"
        fi
    done
    
    BUCKET_NAME="${PROJECT_ID}-n8n-data"
    
    log_success "Selected region: $REGION"
    echo ""
}

# =============================================================================
# ENABLE REQUIRED APIS
# =============================================================================
enable_apis() {
    log_info "Enabling required GCP APIs..."

    gcloud services enable \
        run.googleapis.com \
        storage.googleapis.com \
        secretmanager.googleapis.com \
        cloudbuild.googleapis.com \
        artifactregistry.googleapis.com \
        --project="$PROJECT_ID"

    log_success "APIs enabled"
}

# =============================================================================
# CREATE GCS BUCKET
# =============================================================================
create_bucket() {
    log_info "Creating GCS bucket: $BUCKET_NAME"

    if gcloud storage buckets describe "gs://$BUCKET_NAME" --project="$PROJECT_ID" &> /dev/null; then
        log_warn "Bucket already exists: $BUCKET_NAME"
    else
        gcloud storage buckets create "gs://$BUCKET_NAME" \
            --project="$PROJECT_ID" \
            --location="$REGION" \
            --uniform-bucket-level-access \
            --public-access-prevention

        log_success "Bucket created: $BUCKET_NAME"
    fi

    log_info "Creating initial directory structure..."
    echo "" | gcloud storage cp - "gs://$BUCKET_NAME/.n8n-initialized" 2>/dev/null || true
}

# =============================================================================
# CREATE ENCRYPTION KEY SECRET
# =============================================================================
create_encryption_key() {
    log_info "Creating encryption key in Secret Manager..."

    SECRET_NAME="n8n-encryption-key"

    if gcloud secrets describe "$SECRET_NAME" --project="$PROJECT_ID" &> /dev/null; then
        log_warn "Secret already exists: $SECRET_NAME"
    else
        ENCRYPTION_KEY=$(openssl rand -base64 32)

        echo -n "$ENCRYPTION_KEY" | gcloud secrets create "$SECRET_NAME" \
            --project="$PROJECT_ID" \
            --replication-policy="automatic" \
            --data-file=-

        log_success "Encryption key created in Secret Manager"
    fi
}

# =============================================================================
# CONFIGURE IAM PERMISSIONS
# =============================================================================
configure_iam() {
    log_info "Configuring IAM permissions..."

    PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format="value(projectNumber)")
    SERVICE_ACCOUNT="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"

    log_info "Service account: $SERVICE_ACCOUNT"

    gcloud storage buckets add-iam-policy-binding "gs://$BUCKET_NAME" \
        --member="serviceAccount:$SERVICE_ACCOUNT" \
        --role="roles/storage.objectUser" \
        --project="$PROJECT_ID"

    gcloud secrets add-iam-policy-binding "n8n-encryption-key" \
        --member="serviceAccount:$SERVICE_ACCOUNT" \
        --role="roles/secretmanager.secretAccessor" \
        --project="$PROJECT_ID"

    log_success "IAM permissions configured"
}

# =============================================================================
# DEPLOY TO CLOUD RUN
# =============================================================================
deploy_cloud_run() {
    log_info "Deploying to Cloud Run (using pre-built n8n image)..."

    PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format="value(projectNumber)")

    gcloud run deploy "$SERVICE_NAME" \
        --project="$PROJECT_ID" \
        --region="$REGION" \
        --image=n8nio/n8n:latest \
        --port=5678 \
        --memory="$MEMORY" \
        --cpu="$CPU" \
        --min-instances="$MIN_INSTANCES" \
        --max-instances="$MAX_INSTANCES" \
        --no-cpu-throttling \
        --execution-environment=gen2 \
        --allow-unauthenticated \
        --set-env-vars="GENERIC_TIMEZONE=Europe/Rome,TZ=Europe/Rome,N8N_PORT=5678,N8N_PROTOCOL=https,N8N_SECURE_COOKIE=true,DB_TYPE=sqlite,N8N_BLOCK_ENV_ACCESS_IN_NODE=true,N8N_DIAGNOSTICS_ENABLED=false" \
        --set-secrets="N8N_ENCRYPTION_KEY=n8n-encryption-key:latest" \
        --add-volume=name=n8n-data,type=cloud-storage,bucket="$BUCKET_NAME" \
        --add-volume-mount=volume=n8n-data,mount-path=/home/node/.n8n

    log_success "Deployed to Cloud Run"

    SERVICE_URL=$(gcloud run services describe "$SERVICE_NAME" \
        --project="$PROJECT_ID" \
        --region="$REGION" \
        --format="value(status.url)")

    echo ""
    log_success "=========================================="
    log_success "n8n is now available at:"
    echo -e "${GREEN}${SERVICE_URL}${NC}"
    log_success "=========================================="
    echo ""
    log_info "First visit will create your admin account."
    log_warn "Note: Cold starts may take 10-30 seconds."
}

# =============================================================================
# MAIN EXECUTION
# =============================================================================
main() {
    echo ""
    echo "==========================================="
    echo "  n8n on Cloud Run - Deployment Script"
    echo "==========================================="
    echo ""

    preflight_checks
    log_info "Using region: $REGION (Milan, Italy)"
    enable_apis
    create_bucket
    create_encryption_key
    configure_iam
    deploy_cloud_run

    echo ""
    log_success "Deployment complete!"
    echo ""
}

main "$@"
