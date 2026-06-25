#!/bin/bash
# Deploy HAPI FHIR container directly to Cloud Run
# Make sure you are authenticated with gcloud before running this.

set -e

# Configuration
PROJECT_ID="${GCP_PROJECT_ID:-your-gcp-project-id}"
REGION="${GCP_REGION:-us-central1}"
CLOUDSQL_CONNECTION="${GCP_CLOUDSQL_CONNECTION_NAME:-your-project:us-central1:your-instance}"
HAPI_DB_PASSWORD="${HAPI_DB_PASSWORD:-hapi_secret}"

echo "Deploying HAPI FHIR to Cloud Run..."
echo "Project ID: $PROJECT_ID"
echo "Region: $REGION"
echo "Cloud SQL Connection: $CLOUDSQL_CONNECTION"

gcloud run deploy hapi-fhir \
  --image=hapiproject/hapi:latest \
  --region="$REGION" \
  --project="$PROJECT_ID" \
  --add-cloudsql-instances="$CLOUDSQL_CONNECTION" \
  --set-env-vars="SPRING_DATASOURCE_URL=jdbc:postgresql://localhost:5432/hapi?socketFactory=com.google.cloud.sql.postgres.SocketFactory&socketFactoryArg=$CLOUDSQL_CONNECTION,SPRING_DATASOURCE_USERNAME=hapi,SPRING_DATASOURCE_PASSWORD=$HAPI_DB_PASSWORD,SPRING_DATASOURCE_DRIVER_CLASS_NAME=org.postgresql.Driver,HIBERNATE_DIALECT=ca.uhn.fhir.jpa.model.dialect.HapiFhirPostgresDialect" \
  --no-allow-unauthenticated \
  --max-instances=1 \
  --memory=2Gi \
  --cpu=1

echo "HAPI FHIR deployed successfully!"
