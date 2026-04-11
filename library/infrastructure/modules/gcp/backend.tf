# =============================================================================
# Backend Configuration for GCP State Storage
# =============================================================================
# Create the bucket first:
#   gsutil mb -l us-central1 gs://YOUR_PROJECT_ID-aither-state
#   gsutil versioning set on gs://YOUR_PROJECT_ID-aither-state
#
# Then initialize with:
#   tofu init -backend-config="bucket=YOUR_PROJECT_ID-aither-state"
# =============================================================================

terraform {
  backend "gcs" {
    # The bucket name will be provided via -backend-config during init
    # bucket = "YOUR_PROJECT_ID-aither-state"
    prefix = "aither"
  }
}
