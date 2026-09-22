#!/bin/bash
set -e

REGION=${1:-us-east-1}
TABLE="research-agent-tf-locks"

# S3 bucket names are globally unique across ALL AWS accounts, so the state
# bucket is suffixed with this account's ID. Override with: ./bootstrap.sh <region> <bucket>
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET=${2:-research-agent-tfstate-${ACCOUNT_ID}}

# The backend block in terraform/main.tf cannot interpolate variables, so the
# bucket name is a literal there. Catch a mismatch now rather than at apply time.
BACKEND_TF="$(dirname "$0")/terraform/main.tf"
if [ -f "$BACKEND_TF" ] && ! grep -q "bucket *= *\"$BUCKET\"" "$BACKEND_TF"; then
  echo "WARNING: terraform/main.tf backend does not reference bucket '$BUCKET'."
  echo "         Update its backend \"s3\" block to match before running terraform init."
fi

echo "Creating S3 bucket: $BUCKET in region: $REGION"

if [ "$REGION" = "us-east-1" ]; then
  CREATE_ERR=$(aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" 2>&1 >/dev/null) || true
else
  CREATE_ERR=$(aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" \
    --create-bucket-configuration LocationConstraint="$REGION" 2>&1 >/dev/null) || true
fi

if [ -z "$CREATE_ERR" ]; then
  echo "Bucket created."
elif echo "$CREATE_ERR" | grep -q "BucketAlreadyOwnedByYou"; then
  echo "Bucket already exists in this account, continuing."
elif echo "$CREATE_ERR" | grep -q "BucketAlreadyExists"; then
  echo "ERROR: bucket name '$BUCKET' is taken by another AWS account."
  echo "       S3 bucket names are global. Re-run with a unique name:"
  echo "         ./bootstrap.sh $REGION my-unique-tfstate-name"
  exit 1
else
  echo "ERROR: could not create bucket '$BUCKET':"
  echo "$CREATE_ERR"
  exit 1
fi

echo "Enabling versioning on S3 bucket..."
aws s3api put-bucket-versioning \
  --bucket "$BUCKET" \
  --versioning-configuration Status=Enabled

echo "Blocking public access on S3 bucket..."
aws s3api put-public-access-block \
  --bucket "$BUCKET" \
  --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

echo "Enabling server-side encryption on S3 bucket..."
aws s3api put-bucket-encryption \
  --bucket "$BUCKET" \
  --server-side-encryption-configuration \
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

echo "Creating DynamoDB table for Terraform state locking: $TABLE"
aws dynamodb create-table \
  --table-name "$TABLE" \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region "$REGION" 2>/dev/null && echo "DynamoDB table created." || echo "DynamoDB table already exists, continuing."

echo ""
echo "Bootstrap complete."
echo "  S3 bucket  : $BUCKET (versioned, encrypted, private)"
echo "  DynamoDB   : $TABLE (state locking)"
echo ""
echo "Next step: cd terraform && terraform init && terraform apply"
