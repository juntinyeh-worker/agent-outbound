#!/bin/bash
set -e

# --- Configuration ---
PHOTOS_BUCKET="${PHOTOS_BUCKET:?Set PHOTOS_BUCKET env var}"
AWS_REGION="${AWS_REGION:-us-east-1}"
LAMBDA_NAME="photo-album-thumbnail-generator"
BATCH_ROLE_NAME="photo-album-s3-batch-role"
LAMBDA_ROLE_NAME="photo-album-thumbnail-lambda-role"
MANIFEST_KEY="batch-manifests/thumbnail-manifest.csv"
PILLOW_LAYER_ARN="${PILLOW_LAYER_ARN:-arn:aws:lambda:${AWS_REGION}:770693421928:layer:Klayers-p312-Pillow:4}"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "============================================"
echo "  Thumbnail Generator — S3 Batch Setup"
echo "============================================"
echo "  Bucket:  $PHOTOS_BUCKET"
echo "  Region:  $AWS_REGION"
echo "  Account: $ACCOUNT_ID"
echo ""

# --- 1. Create Lambda execution role ---
echo "→ Creating Lambda execution role..."
aws iam create-role \
  --role-name "$LAMBDA_ROLE_NAME" \
  --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}' \
  --region "$AWS_REGION" 2>/dev/null || echo "  (role exists)"

aws iam put-role-policy \
  --role-name "$LAMBDA_ROLE_NAME" \
  --policy-name "thumbnail-lambda-policy" \
  --policy-document "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [
      {
        \"Effect\": \"Allow\",
        \"Action\": [\"s3:GetObject\", \"s3:PutObject\", \"s3:HeadObject\"],
        \"Resource\": \"arn:aws:s3:::${PHOTOS_BUCKET}/*\"
      },
      {
        \"Effect\": \"Allow\",
        \"Action\": [\"logs:CreateLogGroup\", \"logs:CreateLogStream\", \"logs:PutLogEvents\"],
        \"Resource\": \"arn:aws:logs:${AWS_REGION}:${ACCOUNT_ID}:*\"
      }
    ]
  }"

echo "  Waiting for role propagation..."
sleep 10

# --- 2. Package and deploy Lambda ---
echo "→ Deploying Lambda function..."
cd "$SCRIPT_DIR/lambda"
zip -q handler.zip handler.py

aws lambda create-function \
  --function-name "$LAMBDA_NAME" \
  --runtime python3.12 \
  --handler handler.handler \
  --role "arn:aws:iam::${ACCOUNT_ID}:role/${LAMBDA_ROLE_NAME}" \
  --zip-file fileb://handler.zip \
  --timeout 60 \
  --memory-size 512 \
  --layers "$PILLOW_LAYER_ARN" \
  --region "$AWS_REGION" 2>/dev/null || \
aws lambda update-function-code \
  --function-name "$LAMBDA_NAME" \
  --zip-file fileb://handler.zip \
  --region "$AWS_REGION"

rm handler.zip
LAMBDA_ARN="arn:aws:lambda:${AWS_REGION}:${ACCOUNT_ID}:function:${LAMBDA_NAME}"

# --- 3. Create S3 Batch role ---
echo "→ Creating S3 Batch Operations role..."
aws iam create-role \
  --role-name "$BATCH_ROLE_NAME" \
  --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"batchoperations.s3.amazonaws.com"},"Action":"sts:AssumeRole"}]}' \
  --region "$AWS_REGION" 2>/dev/null || echo "  (role exists)"

aws iam put-role-policy \
  --role-name "$BATCH_ROLE_NAME" \
  --policy-name "s3-batch-thumbnail-policy" \
  --policy-document "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [
      {
        \"Effect\": \"Allow\",
        \"Action\": \"lambda:InvokeFunction\",
        \"Resource\": \"${LAMBDA_ARN}\"
      },
      {
        \"Effect\": \"Allow\",
        \"Action\": [\"s3:GetObject\", \"s3:PutObject\"],
        \"Resource\": [
          \"arn:aws:s3:::${PHOTOS_BUCKET}/*\",
          \"arn:aws:s3:::${PHOTOS_BUCKET}\"
        ]
      }
    ]
  }"

# --- 4. Generate manifest ---
echo "→ Generating manifest (listing all image files, excluding thumbnails)..."
aws s3api list-objects-v2 \
  --bucket "$PHOTOS_BUCKET" \
  --query "Contents[?ends_with(Key, '.jpg') || ends_with(Key, '.jpeg') || ends_with(Key, '.png') || ends_with(Key, '.JPG') || ends_with(Key, '.JPEG') || ends_with(Key, '.PNG')].{Key: Key}" \
  --output text \
  --region "$AWS_REGION" | \
  grep -v '_thumb\.' | \
  awk -v bucket="$PHOTOS_BUCKET" '{print bucket","$1}' > /tmp/manifest.csv

MANIFEST_COUNT=$(wc -l < /tmp/manifest.csv | tr -d ' ')
echo "  Found $MANIFEST_COUNT images to process"

aws s3 cp /tmp/manifest.csv "s3://${PHOTOS_BUCKET}/${MANIFEST_KEY}" --region "$AWS_REGION"
rm /tmp/manifest.csv

# --- 5. Submit S3 Batch Operations job ---
echo "→ Submitting S3 Batch Operations job..."
JOB_ID=$(aws s3control create-job \
  --account-id "$ACCOUNT_ID" \
  --region "$AWS_REGION" \
  --operation "{\"LambdaInvoke\":{\"FunctionArn\":\"${LAMBDA_ARN}\"}}" \
  --manifest "{\"Spec\":{\"Format\":\"S3BatchOperations_CSV_20180820\",\"Fields\":[\"Bucket\",\"Key\"]},\"Location\":{\"ObjectArn\":\"arn:aws:s3:::${PHOTOS_BUCKET}/${MANIFEST_KEY}\",\"ETag\":\"$(aws s3api head-object --bucket "$PHOTOS_BUCKET" --key "$MANIFEST_KEY" --query ETag --output text --region "$AWS_REGION")\"}}" \
  --report "{\"Bucket\":\"arn:aws:s3:::${PHOTOS_BUCKET}\",\"Prefix\":\"batch-reports/\",\"Format\":\"Report_CSV_20180820\",\"Enabled\":true,\"ReportScope\":\"AllTasks\"}" \
  --priority 1 \
  --role-arn "arn:aws:iam::${ACCOUNT_ID}:role/${BATCH_ROLE_NAME}" \
  --confirmation-required \
  --query 'JobId' --output text)

echo ""
echo "============================================"
echo "  ✓ Batch Job Created!"
echo "============================================"
echo ""
echo "  Job ID: $JOB_ID"
echo "  Status: Suspended (awaiting confirmation)"
echo ""
echo "  To confirm and start:"
echo "    aws s3control update-job-status --account-id $ACCOUNT_ID --job-id $JOB_ID --requested-job-status Ready --region $AWS_REGION"
echo ""
echo "  To monitor:"
echo "    aws s3control describe-job --account-id $ACCOUNT_ID --job-id $JOB_ID --region $AWS_REGION"
echo ""
echo "  Estimated cost: ~\$5 for $MANIFEST_COUNT images"
echo ""
