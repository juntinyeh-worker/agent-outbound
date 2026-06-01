#!/bin/bash
set -e

echo "========================================="
echo " S3 Photo Album — One-Click Deploy"
echo "========================================="
echo ""

# --- Check prerequisites ---
if ! command -v aws &>/dev/null; then
  echo "ERROR: 'aws' CLI is required but not installed."
  exit 1
fi
echo "✓ AWS CLI found"

# --- Gather inputs ---
read -p "AWS Region [us-east-1]: " REGION
REGION=${REGION:-us-east-1}

read -p "Photo S3 bucket name(s) [comma-separated]: " PHOTO_BUCKET
if [ -z "$PHOTO_BUCKET" ]; then
  echo "ERROR: Photo bucket name is required."
  exit 1
fi

# Check if first bucket exists (for create logic)
FIRST_BUCKET=$(echo "$PHOTO_BUCKET" | cut -d',' -f1 | tr -d ' ')
CREATE_BUCKET="false"
if aws s3api head-bucket --bucket "$FIRST_BUCKET" --region "$REGION" 2>/dev/null; then
  echo "✓ Bucket '$FIRST_BUCKET' exists"
else
  read -p "Bucket '$FIRST_BUCKET' doesn't exist. Create it? [Y/n]: " CREATE_CONFIRM
  CREATE_CONFIRM=${CREATE_CONFIRM:-Y}
  if [[ "$CREATE_CONFIRM" =~ ^[Yy]$ ]]; then
    CREATE_BUCKET="true"
  else
    echo "ERROR: Bucket must exist or be created."
    exit 1
  fi
fi

read -p "Admin email (will receive temp password): " ADMIN_EMAIL
if [ -z "$ADMIN_EMAIL" ]; then
  echo "ERROR: Admin email is required."
  exit 1
fi

STACK_NAME="photo-album"

echo ""
echo "Deploying with:"
echo "  Region:       $REGION"
echo "  Photo Bucket: $PHOTO_BUCKET (create: $CREATE_BUCKET)"
echo "  Admin Email:  $ADMIN_EMAIL"
echo "  Stack Name:   $STACK_NAME"
echo ""
read -p "Continue? [Y/n]: " CONFIRM
CONFIRM=${CONFIRM:-Y}
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
  echo "Aborted."
  exit 0
fi

# --- Step 1: Deploy CloudFormation Stack ---
echo ""
echo "→ [1/3] Deploying CloudFormation stack..."
aws cloudformation deploy \
  --stack-name "$STACK_NAME" \
  --template-file photo-album-cfn.yaml \
  --parameter-overrides \
    PhotoBucketName="$PHOTO_BUCKET" \
    AdminEmail="$ADMIN_EMAIL" \
    CreatePhotoBucket="$CREATE_BUCKET" \
  --capabilities CAPABILITY_IAM \
  --region "$REGION"

echo "✓ Stack deployed"

# --- Step 2: Get stack outputs ---
echo ""
echo "→ [2/3] Retrieving stack outputs..."

get_output() {
  aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" \
    --region "$REGION" \
    --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" \
    --output text
}

CLOUDFRONT_URL=$(get_output CloudFrontURL)
USER_POOL_ID=$(get_output UserPoolId)
CLIENT_ID=$(get_output UserPoolClientId)
IDENTITY_POOL_ID=$(get_output IdentityPoolId)
SITE_BUCKET=$(get_output SiteBucket)

echo "  CloudFront:    $CLOUDFRONT_URL"
echo "  UserPool:      $USER_POOL_ID"
echo "  ClientId:      $CLIENT_ID"
echo "  IdentityPool:  $IDENTITY_POOL_ID"
echo "  SiteBucket:    $SITE_BUCKET"

# --- Step 3: Generate and upload frontend ---
echo ""
echo "→ [3/3] Generating frontend and uploading to site bucket..."

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cp "$SCRIPT_DIR/index.html.template" /tmp/index.html

# Inject config values
sed -i "s|%%REGION%%|$REGION|g" /tmp/index.html
sed -i "s|%%USER_POOL_ID%%|$USER_POOL_ID|g" /tmp/index.html
sed -i "s|%%CLIENT_ID%%|$CLIENT_ID|g" /tmp/index.html
sed -i "s|%%IDENTITY_POOL_ID%%|$IDENTITY_POOL_ID|g" /tmp/index.html
sed -i "s|%%PHOTO_BUCKET%%|$PHOTO_BUCKET|g" /tmp/index.html

# Check if burst-detector stack exists
BURST_API_URL=""
BURST_API_URL=$(aws cloudformation describe-stacks \
  --stack-name burst-detector --region "$REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='BurstApiUrl'].OutputValue" \
  --output text 2>/dev/null || echo "")
if [ -z "$BURST_API_URL" ] || [ "$BURST_API_URL" = "None" ]; then
  BURST_API_URL=""
  echo "  (Burst detector not deployed — scan button will be hidden)"
fi
sed -i "s|%%BURST_API_URL%%|$BURST_API_URL|g" /tmp/index.html

# Check if photo-rotate stack exists
ROTATE_API_URL=""
ROTATE_API_URL=$(aws cloudformation describe-stacks \
  --stack-name photo-rotate --region "$REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='RotateApiUrl'].OutputValue" \
  --output text 2>/dev/null || echo "")
if [ -z "$ROTATE_API_URL" ] || [ "$ROTATE_API_URL" = "None" ]; then
  ROTATE_API_URL=""
  echo "  (Rotate not deployed — rotate buttons will be hidden)"
fi
sed -i "s|%%ROTATE_API_URL%%|$ROTATE_API_URL|g" /tmp/index.html

# Check if thumbnail-generator stack exists
THUMBNAIL_API_URL=""
THUMBNAIL_API_URL=$(aws cloudformation describe-stacks \
  --stack-name thumbnail-generator --region "$REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='ThumbnailApiUrl'].OutputValue" \
  --output text 2>/dev/null || echo "")
if [ -z "$THUMBNAIL_API_URL" ] || [ "$THUMBNAIL_API_URL" = "None" ]; then
  THUMBNAIL_API_URL=""
  echo "  (Thumbnail generator not deployed — generate button will be hidden)"
fi
sed -i "s|%%THUMBNAIL_API_URL%%|$THUMBNAIL_API_URL|g" /tmp/index.html

# Upload to site bucket
aws s3 cp /tmp/index.html "s3://$SITE_BUCKET/index.html" \
  --content-type "text/html" \
  --region "$REGION"

rm -f /tmp/index.html

echo "✓ Frontend uploaded"

echo ""
echo "========================================="
echo " ✓ Deployment Complete!"
echo "========================================="
echo ""
echo " URL:  $CLOUDFRONT_URL"
echo ""
echo "NEXT STEPS:"
echo " 1. Check your email ($ADMIN_EMAIL) for the temporary password"
echo " 2. Open: $CLOUDFRONT_URL"
echo " 3. Log in and set a new password"
echo " 4. You are in the 'Editors' group — you can browse and delete photos"
echo ""
echo "NOTE: CloudFront may take 1-2 minutes to propagate."
echo ""
