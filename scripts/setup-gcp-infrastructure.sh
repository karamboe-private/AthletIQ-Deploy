#!/bin/bash
# Automate the GCP infrastructure setup for AthletIQ deployment.
# Run this script on your local machine using the gcloud CLI.

set -e

# --- Configuration ---
# Modify these variables as needed
PROJECT_ID="${GCP_PROJECT_ID:-your-gcp-project-id}"
REGION="${GCP_REGION:-us-central1}"
DB_INSTANCE_NAME="athletiq-db"
DB_PASSWORD=$(openssl rand -base64 15)
HAPI_DB_PASSWORD=$(openssl rand -base64 15)
GITHUB_ORG_OR_USER="kennethb" # Change to your GitHub username/org
GITHUB_REPOS=("AthletIQ-Backend" "AthletIQ-frontend" "AthletIQ-Landingpage") # Repos to trust

echo "=== AthletIQ GCP Infrastructure Setup ==="
echo "Project ID: $PROJECT_ID"
echo "Region: $REGION"
echo "GitHub Org/User: $GITHUB_ORG_OR_USER"

# 1. Ensure logged in and correct project
gcloud config set project "$PROJECT_ID"

# 2. Enable GCP APIs
echo "Enabling GCP APIs (this can take a minute)..."
gcloud services enable \
  run.googleapis.com \
  sqladmin.googleapis.com \
  artifactregistry.googleapis.com \
  iam.googleapis.com \
  iamcredentials.googleapis.com

# 3. Create Artifact Registry
echo "Creating Artifact Registry repository 'athletiq'..."
gcloud artifacts repositories create athletiq \
  --repository-format=docker \
  --location="$REGION" \
  --description="AthletIQ Docker repository" || echo "Repository already exists."

# 4. Create Cloud SQL (PostgreSQL 17)
echo "Creating Cloud SQL PostgreSQL instance (this may take 5-10 minutes)..."
gcloud sql instances create "$DB_INSTANCE_NAME" \
  --database-version=POSTGRES_17 \
  --tier=db-f1-micro \
  --region="$REGION" \
  --storage-type=HDD \
  --storage-size=10 || echo "Database instance already exists."

# Create databases
echo "Creating 'athletiq' database..."
gcloud sql databases create athletiq --instance="$DB_INSTANCE_NAME" || echo "Database athletiq already exists."
echo "Creating 'hapi' database..."
gcloud sql databases create hapi --instance="$DB_INSTANCE_NAME" || echo "Database hapi already exists."

# Set passwords
echo "Setting database user passwords..."
gcloud sql users create athletiq --instance="$DB_INSTANCE_NAME" --password="$DB_PASSWORD" || \
  gcloud sql users set-password athletiq --instance="$DB_INSTANCE_NAME" --password="$DB_PASSWORD"
gcloud sql users create hapi --instance="$DB_INSTANCE_NAME" --password="$HAPI_DB_PASSWORD" || \
  gcloud sql users set-password hapi --instance="$DB_INSTANCE_NAME" --password="$HAPI_DB_PASSWORD"

# Get connection name
CLOUDSQL_CONNECTION_NAME=$(gcloud sql instances describe "$DB_INSTANCE_NAME" --format="value(connectionName)")

# 5. Set up Workload Identity Federation (WIF) for GitHub
echo "Setting up Workload Identity Federation..."
POOL_NAME="github-actions-pool"
PROVIDER_NAME="github-provider"

# Create WIF Pool
gcloud iam workload-identity-pools create "$POOL_NAME" \
  --location="global" \
  --display-name="GitHub Actions Pool" || echo "WIF Pool already exists."

# Create WIF Provider linked to GitHub
gcloud iam workload-identity-pools providers create-oidc "$PROVIDER_NAME" \
  --location="global" \
  --workload-identity-pool="$POOL_NAME" \
  --display-name="GitHub Provider" \
  --attribute-mapping="google.subject=assertion.subject,attribute.actor=assertion.actor,attribute.repository=assertion.repository" \
  --issuer-uri="https://token.actions.githubusercontent.com" || echo "WIF Provider already exists."

# Create deployment Service Account
SA_NAME="github-deployer"
SA_EMAIL="$SA_NAME@$PROJECT_ID.iam.gserviceaccount.com"

gcloud iam service-accounts create "$SA_NAME" \
  --display-name="GitHub Actions Deployer" || echo "Service account already exists."

# Bind WIF to the Service Account
WIF_POOL_ID=$(gcloud iam workload-identity-pools describe "$POOL_NAME" --location="global" --format="value(name)")

# Grant permission to GitHub repositories to assume the Service Account
for REPO in "${GITHUB_REPOS[@]}"; do
  echo "Binding SA to repository: $GITHUB_ORG_OR_USER/$REPO"
  gcloud iam service-accounts add-iam-policy-binding "$SA_EMAIL" \
    --role="roles/iam.workloadIdentityUser" \
    --member="principalSet://iam.googleapis.com/$WIF_POOL_ID/attribute.repository/$GITHUB_ORG_OR_USER/$REPO"
done

# Grant roles to the Service Account
echo "Granting roles to Service Account..."
ROLES=("roles/run.admin" "roles/artifactregistry.writer" "roles/iam.serviceAccountUser" "roles/sql.client")
for ROLE in "${ROLES[@]}"; do
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:$SA_EMAIL" \
    --role="$ROLE"
done

# 6. Outputs
WIF_PROVIDER_URI=$(gcloud iam workload-identity-pools providers describe "$PROVIDER_NAME" \
  --workload-identity-pool="$POOL_NAME" \
  --location="global" \
  --format="value(name)")

echo "=================================================="
echo "Setup complete! Please configure the following Secrets/Variables in GitHub:"
echo "=================================================="
echo ""
echo "### GitHub Variables (vars):"
echo "  GCP_PROJECT_ID: $PROJECT_ID"
echo "  GCP_REGION: $REGION"
echo "  NEXT_PUBLIC_API_BASE_URL: https://<your-backend-cloud-run-url> (update after backend deployment)"
echo "  BACKEND_URL: https://<your-backend-cloud-run-url> (update after backend deployment)"
echo "  HAPI_FHIR_URL: https://<your-hapi-fhir-cloud-run-url> (update after HAPI deployment)"
echo ""
echo "### GitHub Secrets (secrets):"
echo "  GCP_WIF_PROVIDER: $WIF_PROVIDER_URI"
echo "  GCP_WIF_SERVICE_ACCOUNT: $SA_EMAIL"
echo "  GCP_CLOUDSQL_CONNECTION_NAME: $CLOUDSQL_CONNECTION_NAME"
echo "  DB_PASSWORD: $DB_PASSWORD"
echo "  HAPI_DB_PASSWORD: $HAPI_DB_PASSWORD"
echo "  JWT_SECRET: (Generate a secure random string)"
echo ""
echo "=================================================="
echo "To deploy HAPI FHIR, run:"
echo "  GCP_PROJECT_ID=$PROJECT_ID GCP_REGION=$REGION GCP_CLOUDSQL_CONNECTION_NAME=$CLOUDSQL_CONNECTION_NAME HAPI_DB_PASSWORD=$HAPI_DB_PASSWORD ./scripts/deploy-hapi-fhir.sh"
echo "=================================================="
