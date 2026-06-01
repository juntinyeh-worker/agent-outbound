#!/bin/bash
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "========================================="
echo " S3 Photo Album — All-in-One Deploy"
echo "========================================="
echo ""

# --- Check prerequisites ---
if ! command -v aws &>/dev/null; then
  echo "ERROR: 'aws' CLI is required but not installed."
  exit 1
fi
if ! command -v pip3 &>/dev/null; then
  echo "ERROR: 'pip3' is required for Lambda layers."
  exit 1
fi
echo "✓ Prerequisites OK (aws, pip3)"

# --- Gather inputs ---
read -p "AWS Region [us-east-1]: " REGION
REGION=${REGION:-us-east-1}

read -p "Photo S3 bucket name: " PHOTO_BUCKET
if [ -z "$PHOTO_BUCKET" ]; then
  echo "ERROR: Photo bucket name is required."
  exit 1
fi

CREATE_BUCKET="false"
if aws s3api head-bucket --bucket "$PHOTO_BUCKET" --region "$REGION" 2>/dev/null; then
  echo "✓ Bucket '$PHOTO_BUCKET' exists"
else
  read -p "Bucket '$PHOTO_BUCKET' doesn't exist. Create it? [Y/n]: " CREATE_CONFIRM
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

echo ""
echo "Deploying with:"
echo "  Region:       $REGION"
echo "  Photo Bucket: $PHOTO_BUCKET (create: $CREATE_BUCKET)"
echo "  Admin Email:  $ADMIN_EMAIL"
echo ""
read -p "Continue? [Y/n]: " CONFIRM
CONFIRM=${CONFIRM:-Y}
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
  echo "Aborted."
  exit 0
fi

# =========================================
# STEP 1: Main Stack
# =========================================
echo ""
echo "→ [1/5] Deploying main stack (Cognito, CloudFront, IAM)..."
aws cloudformation deploy \
  --stack-name photo-album \
  --template-file "$SCRIPT_DIR/photo-album-cfn.yaml" \
  --parameter-overrides \
    PhotoBucketName="$PHOTO_BUCKET" \
    AdminEmail="$ADMIN_EMAIL" \
    CreatePhotoBucket="$CREATE_BUCKET" \
  --capabilities CAPABILITY_IAM \
  --region "$REGION"
echo "✓ Main stack deployed"

# =========================================
# STEP 2: Rotate Stack
# =========================================
echo ""
echo "→ [2/5] Deploying rotate stack..."

# Build Pillow layer
ROTATE_LAYER_DIR=$(mktemp -d)
pip3 install Pillow -t "$ROTATE_LAYER_DIR/python" --quiet --platform manylinux2014_x86_64 --only-binary=:all: 2>/dev/null
cd "$ROTATE_LAYER_DIR" && zip -r9 rotate-layer.zip python/ > /dev/null

aws cloudformation deploy \
  --stack-name photo-rotate \
  --template-file "$SCRIPT_DIR/rotate/rotate-cfn.yaml" \
  --parameter-overrides PhotoBucketName="$PHOTO_BUCKET" \
  --capabilities CAPABILITY_IAM \
  --region "$REGION"

ROTATE_LAYER_BUCKET=$(aws cloudformation describe-stacks \
  --stack-name photo-rotate --region "$REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='RotateLayerBucket'].OutputValue" --output text)

aws s3 cp "$ROTATE_LAYER_DIR/rotate-layer.zip" "s3://$ROTATE_LAYER_BUCKET/rotate-layer.zip" --region "$REGION" --quiet

# Upload Lambda code
ROTATE_CODE_DIR=$(mktemp -d)
cp "$SCRIPT_DIR/rotate/lambda_function.py" "$ROTATE_CODE_DIR/"
cd "$ROTATE_CODE_DIR" && zip -r9 code.zip lambda_function.py > /dev/null
aws lambda update-function-code --function-name photo-rotate --zip-file "fileb://code.zip" --region "$REGION" > /dev/null

ROTATE_LAYER_ARN=$(aws lambda publish-layer-version \
  --layer-name rotate-pillow \
  --content S3Bucket="$ROTATE_LAYER_BUCKET",S3Key=rotate-layer.zip \
  --compatible-runtimes python3.12 \
  --region "$REGION" --query 'LayerVersionArn' --output text)
aws lambda update-function-configuration --function-name photo-rotate --layers "$ROTATE_LAYER_ARN" --region "$REGION" > /dev/null

rm -rf "$ROTATE_LAYER_DIR" "$ROTATE_CODE_DIR"
echo "✓ Rotate stack deployed"

# =========================================
# STEP 3: Burst Detector Stack
# =========================================
echo ""
echo "→ [3/5] Deploying burst detector stack..."

BURST_LAYER_DIR=$(mktemp -d)
pip3 install Pillow imagehash exifread numpy scipy \
  -t "$BURST_LAYER_DIR/python" --quiet --platform manylinux2014_x86_64 --only-binary=:all: 2>/dev/null
cd "$BURST_LAYER_DIR" && zip -r9 burst-layer.zip python/ > /dev/null

aws cloudformation deploy \
  --stack-name burst-detector \
  --template-file "$SCRIPT_DIR/burst-detector/burst-detector-cfn.yaml" \
  --parameter-overrides PhotoBucketName="$PHOTO_BUCKET" \
  --capabilities CAPABILITY_IAM \
  --region "$REGION"

BURST_LAYER_BUCKET=$(aws cloudformation describe-stacks \
  --stack-name burst-detector --region "$REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='LayerBucket'].OutputValue" --output text)

aws s3 cp "$BURST_LAYER_DIR/burst-layer.zip" "s3://$BURST_LAYER_BUCKET/burst-detector-layer.zip" --region "$REGION" --quiet

BURST_CODE_DIR=$(mktemp -d)
cp "$SCRIPT_DIR/burst-detector/lambda_function.py" "$BURST_CODE_DIR/"
cd "$BURST_CODE_DIR" && zip -r9 code.zip lambda_function.py > /dev/null
aws lambda update-function-code --function-name burst-detector --zip-file "fileb://code.zip" --region "$REGION" > /dev/null

BURST_LAYER_ARN=$(aws lambda publish-layer-version \
  --layer-name burst-detector-deps \
  --content S3Bucket="$BURST_LAYER_BUCKET",S3Key=burst-detector-layer.zip \
  --compatible-runtimes python3.12 \
  --region "$REGION" --query 'LayerVersionArn' --output text)
aws lambda update-function-configuration --function-name burst-detector --layers "$BURST_LAYER_ARN" --region "$REGION" > /dev/null

rm -rf "$BURST_LAYER_DIR" "$BURST_CODE_DIR"
echo "✓ Burst detector deployed"

# =========================================
# STEP 4: Collect all outputs
# =========================================
echo ""
echo "→ [4/5] Collecting stack outputs..."

get_output() {
  aws cloudformation describe-stacks --stack-name "$1" --region "$REGION" \
    --query "Stacks[0].Outputs[?OutputKey=='$2'].OutputValue" --output text
}

CLOUDFRONT_URL=$(get_output photo-album CloudFrontURL)
USER_POOL_ID=$(get_output photo-album UserPoolId)
CLIENT_ID=$(get_output photo-album UserPoolClientId)
IDENTITY_POOL_ID=$(get_output photo-album IdentityPoolId)
SITE_BUCKET=$(get_output photo-album SiteBucket)
ROTATE_API_URL=$(get_output photo-rotate RotateApiUrl)
BURST_API_URL=$(get_output burst-detector BurstApiUrl)

echo "  CloudFront:    $CLOUDFRONT_URL"
echo "  UserPool:      $USER_POOL_ID"
echo "  IdentityPool:  $IDENTITY_POOL_ID"
echo "  Rotate API:    $ROTATE_API_URL"
echo "  Burst API:     $BURST_API_URL"

# =========================================
# STEP 5: Generate & upload frontend
# =========================================
echo ""
echo "→ [5/5] Generating frontend and uploading..."

cp "$SCRIPT_DIR/index.html.template" /tmp/index.html

sed -i "s|%%REGION%%|$REGION|g" /tmp/index.html
sed -i "s|%%USER_POOL_ID%%|$USER_POOL_ID|g" /tmp/index.html
sed -i "s|%%CLIENT_ID%%|$CLIENT_ID|g" /tmp/index.html
sed -i "s|%%IDENTITY_POOL_ID%%|$IDENTITY_POOL_ID|g" /tmp/index.html
sed -i "s|%%PHOTO_BUCKET%%|$PHOTO_BUCKET|g" /tmp/index.html
sed -i "s|%%BURST_API_URL%%|$BURST_API_URL|g" /tmp/index.html
sed -i "s|%%ROTATE_API_URL%%|$ROTATE_API_URL|g" /tmp/index.html

aws s3 cp /tmp/index.html "s3://$SITE_BUCKET/index.html" \
  --content-type "text/html" --region "$REGION" --quiet

rm -f /tmp/index.html

echo "✓ Frontend uploaded"

echo ""
echo "========================================="
echo " ✓ All-in-One Deployment Complete!"
echo "========================================="
echo ""
echo " URL:  $CLOUDFRONT_URL"
echo ""
echo " Features deployed:"
echo "   ✓ Photo album (browse, upload, delete)"
echo "   ✓ Rotate (clockwise/counter-clockwise)"
echo "   ✓ Comments (S3 sidecar JSON)"
echo "   ✓ Burst detection (scan & deduplicate)"
echo ""
echo "NEXT STEPS:"
echo " 1. Check your email ($ADMIN_EMAIL) for the temporary password"
echo " 2. Open: $CLOUDFRONT_URL"
echo " 3. Log in and set a new password"
echo ""
echo "NOTE: CloudFront may take 1-2 minutes to propagate."
echo ""
