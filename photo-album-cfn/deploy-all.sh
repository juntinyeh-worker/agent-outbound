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

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
TEMPLATE_BUCKET="photo-album-cfn-templates-${ACCOUNT_ID}-${REGION}"

echo ""
echo "Deploying with:"
echo "  Region:          $REGION"
echo "  Photo Bucket:    $PHOTO_BUCKET (create: $CREATE_BUCKET)"
echo "  Admin Email:     $ADMIN_EMAIL"
echo "  Template Bucket: $TEMPLATE_BUCKET"
echo ""
read -p "Continue? [Y/n]: " CONFIRM
CONFIRM=${CONFIRM:-Y}
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
  echo "Aborted."
  exit 0
fi

# =========================================
# STEP 1: Main Stack (Cognito, CloudFront)
# =========================================
echo ""
echo "→ [1/4] Deploying main stack (Cognito, CloudFront, IAM)..."
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
# STEP 2: Upload nested templates to S3
# =========================================
echo ""
echo "→ [2/4] Uploading nested templates to S3..."

# Create template bucket if needed
if ! aws s3api head-bucket --bucket "$TEMPLATE_BUCKET" --region "$REGION" 2>/dev/null; then
  if [ "$REGION" = "us-east-1" ]; then
    aws s3api create-bucket --bucket "$TEMPLATE_BUCKET" --region "$REGION"
  else
    aws s3api create-bucket --bucket "$TEMPLATE_BUCKET" --region "$REGION" \
      --create-bucket-configuration LocationConstraint="$REGION"
  fi
fi

aws s3 cp "$SCRIPT_DIR/thumbnail/thumbnail-cfn.yaml" "s3://$TEMPLATE_BUCKET/thumbnail-cfn.yaml" --region "$REGION" --quiet
aws s3 cp "$SCRIPT_DIR/video-thumbnail/video-thumbnail-cfn.yaml" "s3://$TEMPLATE_BUCKET/video-thumbnail-cfn.yaml" --region "$REGION" --quiet
aws s3 cp "$SCRIPT_DIR/rotate/rotate-cfn.yaml" "s3://$TEMPLATE_BUCKET/rotate-cfn.yaml" --region "$REGION" --quiet
aws s3 cp "$SCRIPT_DIR/burst-detector/burst-detector-cfn.yaml" "s3://$TEMPLATE_BUCKET/burst-detector-cfn.yaml" --region "$REGION" --quiet
echo "✓ Templates uploaded"

# =========================================
# STEP 3: Deploy nested Lambda stack
# =========================================
echo ""
echo "→ [3/4] Deploying Lambda nested stack..."
aws cloudformation deploy \
  --stack-name photo-album-lambdas \
  --template-file "$SCRIPT_DIR/parent-stack.yaml" \
  --parameter-overrides \
    PhotoBucketName="$PHOTO_BUCKET" \
    TemplateBucketName="$TEMPLATE_BUCKET" \
  --capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM CAPABILITY_AUTO_EXPAND \
  --region "$REGION"
echo "✓ Lambda nested stack deployed"

# --- Build and upload layers + code ---
echo ""
echo "  Uploading Lambda layers and code..."

get_nested_output() {
  aws cloudformation describe-stacks --stack-name photo-album-lambdas --region "$REGION" \
    --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text
}

# Thumbnail layer
THUMB_LAYER_DIR=$(mktemp -d)
pip3 install Pillow -t "$THUMB_LAYER_DIR/python" --quiet --platform manylinux2014_x86_64 --only-binary=:all: 2>/dev/null
cd "$THUMB_LAYER_DIR" && zip -r9 thumbnail-layer.zip python/ > /dev/null

THUMB_LAYER_BUCKET=$(aws cloudformation list-stack-resources --stack-name photo-album-lambdas --region "$REGION" \
  --query "StackResourceSummaries[?LogicalResourceId=='ThumbnailStack'].PhysicalResourceId" --output text | xargs -I{} \
  aws cloudformation describe-stacks --stack-name {} --region "$REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='ThumbnailLayerBucket'].OutputValue" --output text)

aws s3 cp "$THUMB_LAYER_DIR/thumbnail-layer.zip" "s3://$THUMB_LAYER_BUCKET/thumbnail-layer.zip" --region "$REGION" --quiet

THUMB_CODE_DIR=$(mktemp -d)
cp "$SCRIPT_DIR/thumbnail/lambda_function.py" "$THUMB_CODE_DIR/"
cd "$THUMB_CODE_DIR" && zip -r9 code.zip lambda_function.py > /dev/null
aws lambda update-function-code --function-name thumbnail-generator --zip-file "fileb://code.zip" --region "$REGION" > /dev/null

THUMB_LAYER_ARN=$(aws lambda publish-layer-version \
  --layer-name thumbnail-pillow \
  --content S3Bucket="$THUMB_LAYER_BUCKET",S3Key=thumbnail-layer.zip \
  --compatible-runtimes python3.12 \
  --region "$REGION" --query 'LayerVersionArn' --output text)
aws lambda update-function-configuration --function-name thumbnail-generator --layers "$THUMB_LAYER_ARN" --region "$REGION" > /dev/null
rm -rf "$THUMB_LAYER_DIR" "$THUMB_CODE_DIR"
echo "  ✓ Thumbnail generator ready"

# Rotate layer (shares Pillow)
ROTATE_LAYER_DIR=$(mktemp -d)
pip3 install Pillow -t "$ROTATE_LAYER_DIR/python" --quiet --platform manylinux2014_x86_64 --only-binary=:all: 2>/dev/null
cd "$ROTATE_LAYER_DIR" && zip -r9 rotate-layer.zip python/ > /dev/null

ROTATE_LAYER_BUCKET=$(aws cloudformation list-stack-resources --stack-name photo-album-lambdas --region "$REGION" \
  --query "StackResourceSummaries[?LogicalResourceId=='RotateStack'].PhysicalResourceId" --output text | xargs -I{} \
  aws cloudformation describe-stacks --stack-name {} --region "$REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='RotateLayerBucket'].OutputValue" --output text)

aws s3 cp "$ROTATE_LAYER_DIR/rotate-layer.zip" "s3://$ROTATE_LAYER_BUCKET/rotate-layer.zip" --region "$REGION" --quiet

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
echo "  ✓ Rotate ready"

# Burst detector layer
BURST_LAYER_DIR=$(mktemp -d)
pip3 install Pillow imagehash exifread numpy scipy \
  -t "$BURST_LAYER_DIR/python" --quiet --platform manylinux2014_x86_64 --only-binary=:all: 2>/dev/null
cd "$BURST_LAYER_DIR" && zip -r9 burst-layer.zip python/ > /dev/null

BURST_LAYER_BUCKET=$(aws cloudformation list-stack-resources --stack-name photo-album-lambdas --region "$REGION" \
  --query "StackResourceSummaries[?LogicalResourceId=='BurstDetectorStack'].PhysicalResourceId" --output text | xargs -I{} \
  aws cloudformation describe-stacks --stack-name {} --region "$REGION" \
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
echo "  ✓ Burst detector ready"

# Video thumbnail (FFmpeg layer — must be pre-built or use public layer)
VIDEO_CODE_DIR=$(mktemp -d)
cp "$SCRIPT_DIR/video-thumbnail/lambda_function.py" "$VIDEO_CODE_DIR/"
cd "$VIDEO_CODE_DIR" && zip -r9 code.zip lambda_function.py > /dev/null
aws lambda update-function-code --function-name video-thumbnail-generator --zip-file "fileb://code.zip" --region "$REGION" > /dev/null

VIDEO_LAYER_BUCKET=$(aws cloudformation list-stack-resources --stack-name photo-album-lambdas --region "$REGION" \
  --query "StackResourceSummaries[?LogicalResourceId=='VideoThumbnailStack'].PhysicalResourceId" --output text | xargs -I{} \
  aws cloudformation describe-stacks --stack-name {} --region "$REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='LayerBucket'].OutputValue" --output text)

echo "  ⚠ Video thumbnail: upload ffmpeg-layer.zip to s3://$VIDEO_LAYER_BUCKET/ffmpeg-layer.zip manually"
echo "    (FFmpeg static binary must be compiled for Amazon Linux 2023 x86_64)"
rm -rf "$VIDEO_CODE_DIR"
echo "  ✓ Video thumbnail code uploaded"

# =========================================
# STEP 4: Generate & upload frontend
# =========================================
echo ""
echo "→ [4/4] Generating frontend and uploading..."

get_output() {
  aws cloudformation describe-stacks --stack-name "$1" --region "$REGION" \
    --query "Stacks[0].Outputs[?OutputKey=='$2'].OutputValue" --output text
}

CLOUDFRONT_URL=$(get_output photo-album CloudFrontURL)
USER_POOL_ID=$(get_output photo-album UserPoolId)
CLIENT_ID=$(get_output photo-album UserPoolClientId)
IDENTITY_POOL_ID=$(get_output photo-album IdentityPoolId)
SITE_BUCKET=$(get_output photo-album SiteBucket)
ROTATE_API_URL=$(get_nested_output RotateUrl)
BURST_API_URL=$(get_nested_output BurstDetectorUrl)
THUMBNAIL_API_URL=$(get_nested_output ThumbnailUrl)

cp "$SCRIPT_DIR/index.html.template" /tmp/index.html
sed -i "s|%%REGION%%|$REGION|g" /tmp/index.html
sed -i "s|%%USER_POOL_ID%%|$USER_POOL_ID|g" /tmp/index.html
sed -i "s|%%CLIENT_ID%%|$CLIENT_ID|g" /tmp/index.html
sed -i "s|%%IDENTITY_POOL_ID%%|$IDENTITY_POOL_ID|g" /tmp/index.html
sed -i "s|%%PHOTO_BUCKET%%|$PHOTO_BUCKET|g" /tmp/index.html
sed -i "s|%%BURST_API_URL%%|$BURST_API_URL|g" /tmp/index.html
sed -i "s|%%ROTATE_API_URL%%|$ROTATE_API_URL|g" /tmp/index.html
sed -i "s|%%THUMBNAIL_API_URL%%|$THUMBNAIL_API_URL|g" /tmp/index.html

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
echo " Stacks deployed:"
echo "   ✓ photo-album         (Cognito, CloudFront, IAM)"
echo "   ✓ photo-album-lambdas (Nested: thumbnail, video-thumb, rotate, burst)"
echo ""
echo " Features:"
echo "   ✓ Photo album (browse, upload, delete)"
echo "   ✓ Thumbnails (auto-generate on upload + manual batch)"
echo "   ✓ Video thumbnails (auto-generate on upload)"
echo "   ✓ Rotate (clockwise/counter-clockwise)"
echo "   ✓ Burst detection (scan & deduplicate)"
echo ""
echo "NEXT STEPS:"
echo " 1. Check your email ($ADMIN_EMAIL) for the temporary password"
echo " 2. Open: $CLOUDFRONT_URL"
echo " 3. Log in and set a new password"
echo ""
echo "NOTE: CloudFront may take 1-2 minutes to propagate."
echo ""
