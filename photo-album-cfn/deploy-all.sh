#!/bin/bash
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "========================================="
echo " S3 Photo Album — Nested Stack Deploy"
echo "========================================="
echo ""

# --- Prerequisites ---
if ! command -v aws &>/dev/null; then
  echo "ERROR: 'aws' CLI required." && exit 1
fi
if ! command -v pip3 &>/dev/null; then
  echo "ERROR: 'pip3' required for Lambda layers." && exit 1
fi

# --- Inputs ---
read -p "AWS Region [us-east-1]: " REGION
REGION=${REGION:-us-east-1}

read -p "Photo S3 bucket name: " PHOTO_BUCKET
[ -z "$PHOTO_BUCKET" ] && echo "ERROR: Required." && exit 1

CREATE_BUCKET="false"
IFS=',' read -ra BUCKET_LIST <<< "$PHOTO_BUCKET"
ALL_EXIST=true
for b in "${BUCKET_LIST[@]}"; do
  b=$(echo "$b" | xargs)  # trim whitespace
  if aws s3api head-bucket --bucket "$b" --region "$REGION" 2>/dev/null; then
    echo "✓ Bucket '$b' exists"
  else
    ALL_EXIST=false
    echo "✗ Bucket '$b' does not exist"
  fi
done
if [ "$ALL_EXIST" = false ]; then
  read -p "Create missing bucket(s)? [Y/n]: " CREATE_CONFIRM
  [[ "${CREATE_CONFIRM:-Y}" =~ ^[Yy]$ ]] && CREATE_BUCKET="true" || { echo "Aborted."; exit 1; }
fi

read -p "Admin email: " ADMIN_EMAIL
[ -z "$ADMIN_EMAIL" ] && echo "ERROR: Required." && exit 1

read -p "Template bucket name (for nested stack templates) [photo-album-templates-${REGION}]: " TEMPLATE_BUCKET
TEMPLATE_BUCKET=${TEMPLATE_BUCKET:-photo-album-templates-${REGION}}

STACK_NAME="photo-album"

echo ""
echo "  Region:          $REGION"
echo "  Photo Bucket:    $PHOTO_BUCKET (create: $CREATE_BUCKET)"
echo "  Admin Email:     $ADMIN_EMAIL"
echo "  Template Bucket: $TEMPLATE_BUCKET"
echo "  Stack Name:      $STACK_NAME"
echo ""
read -p "Continue? [Y/n]: " CONFIRM
[[ ! "${CONFIRM:-Y}" =~ ^[Yy]$ ]] && echo "Aborted." && exit 0

# =========================================
# STEP 1: Create template bucket if needed
# =========================================
echo ""
echo "→ [1/5] Ensuring template bucket exists..."
if ! aws s3api head-bucket --bucket "$TEMPLATE_BUCKET" --region "$REGION" 2>/dev/null; then
  if [ "$REGION" = "us-east-1" ]; then
    aws s3api create-bucket --bucket "$TEMPLATE_BUCKET" --region "$REGION"
  else
    aws s3api create-bucket --bucket "$TEMPLATE_BUCKET" --region "$REGION" \
      --create-bucket-configuration LocationConstraint="$REGION"
  fi
fi
echo "✓ Template bucket ready: $TEMPLATE_BUCKET"

# =========================================
# STEP 2: Upload nested stack templates
# =========================================
echo ""
echo "→ [2/5] Uploading nested stack templates to S3..."
aws s3 sync "$SCRIPT_DIR/stacks/" "s3://$TEMPLATE_BUCKET/stacks/" --region "$REGION" --quiet
echo "✓ Child templates uploaded"

# =========================================
# STEP 3: Build & upload Lambda layers
# =========================================
echo ""
echo "→ [3/5] Building Lambda layers..."

TMPDIR=$(mktemp -d)
PLATFORM="--platform manylinux2014_x86_64 --only-binary=:all:"

# Rotate + Thumbnail (both use Pillow)
echo "  Building Pillow layer..."
pip3 install Pillow -t "$TMPDIR/pillow/python" --quiet $PLATFORM 2>/dev/null
cd "$TMPDIR/pillow" && zip -r9 "$TMPDIR/pillow-layer.zip" python/ > /dev/null

# Burst detector (Pillow + imagehash + exifread + numpy + scipy)
echo "  Building burst-detector layer..."
pip3 install Pillow imagehash exifread numpy scipy -t "$TMPDIR/burst/python" --quiet $PLATFORM 2>/dev/null
cd "$TMPDIR/burst" && zip -r9 "$TMPDIR/burst-layer.zip" python/ > /dev/null

echo "✓ Layers built"

# =========================================
# STEP 4: Deploy parent stack (creates everything)
# =========================================
echo ""
echo "→ [4/5] Deploying parent stack..."
aws cloudformation deploy \
  --stack-name "$STACK_NAME" \
  --template-file "$SCRIPT_DIR/photo-album-cfn.yaml" \
  --parameter-overrides \
    PhotoBucketName="$PHOTO_BUCKET" \
    AdminEmail="$ADMIN_EMAIL" \
    CreatePhotoBucket="$CREATE_BUCKET" \
    TemplateBucket="$TEMPLATE_BUCKET" \
  --capabilities CAPABILITY_IAM CAPABILITY_AUTO_EXPAND \
  --region "$REGION"
echo "✓ Parent stack deployed"

# =========================================
# STEP 5: Upload layers & Lambda code
# =========================================
echo ""
echo "→ [5/5] Uploading layers and Lambda code..."

get_nested_output() {
  aws cloudformation describe-stacks --stack-name "$1" --region "$REGION" \
    --query "Stacks[0].Outputs[?OutputKey=='$2'].OutputValue" --output text
}

# Get nested stack physical IDs
ROTATE_STACK=$(aws cloudformation describe-stack-resource --stack-name "$STACK_NAME" \
  --logical-resource-id RotateStack --region "$REGION" \
  --query 'StackResourceDetail.PhysicalResourceId' --output text)
THUMBNAIL_STACK=$(aws cloudformation describe-stack-resource --stack-name "$STACK_NAME" \
  --logical-resource-id ThumbnailStack --region "$REGION" \
  --query 'StackResourceDetail.PhysicalResourceId' --output text)
BURST_STACK=$(aws cloudformation describe-stack-resource --stack-name "$STACK_NAME" \
  --logical-resource-id BurstDetectorStack --region "$REGION" \
  --query 'StackResourceDetail.PhysicalResourceId' --output text)
VIDEO_STACK=$(aws cloudformation describe-stack-resource --stack-name "$STACK_NAME" \
  --logical-resource-id VideoThumbnailStack --region "$REGION" \
  --query 'StackResourceDetail.PhysicalResourceId' --output text)

# Get layer buckets from nested stacks
ROTATE_LAYER_BUCKET=$(get_nested_output "$ROTATE_STACK" RotateLayerBucket)
THUMB_LAYER_BUCKET=$(get_nested_output "$THUMBNAIL_STACK" ThumbnailLayerBucket)
BURST_LAYER_BUCKET=$(get_nested_output "$BURST_STACK" LayerBucket)
VIDEO_LAYER_BUCKET=$(get_nested_output "$VIDEO_STACK" LayerBucket)

# Upload layers
aws s3 cp "$TMPDIR/pillow-layer.zip" "s3://$ROTATE_LAYER_BUCKET/rotate-layer.zip" --region "$REGION" --quiet
aws s3 cp "$TMPDIR/pillow-layer.zip" "s3://$THUMB_LAYER_BUCKET/thumbnail-layer.zip" --region "$REGION" --quiet
aws s3 cp "$TMPDIR/burst-layer.zip" "s3://$BURST_LAYER_BUCKET/burst-detector-layer.zip" --region "$REGION" --quiet
echo "  ✓ Layers uploaded (ffmpeg-layer.zip must be uploaded manually to $VIDEO_LAYER_BUCKET)"

# Upload Lambda code
upload_code() {
  local func_name=$1 src=$2
  local code_dir=$(mktemp -d)
  cp "$src" "$code_dir/lambda_function.py"
  cd "$code_dir" && zip -r9 code.zip lambda_function.py > /dev/null
  aws lambda update-function-code --function-name "$func_name" --zip-file "fileb://code.zip" --region "$REGION" > /dev/null
  rm -rf "$code_dir"
}

# Upload actual Lambda code (if source files exist)
[ -f "$SCRIPT_DIR/lambda/rotate.py" ] && upload_code "photo-rotate" "$SCRIPT_DIR/lambda/rotate.py"
[ -f "$SCRIPT_DIR/lambda/thumbnail.py" ] && upload_code "thumbnail-generator" "$SCRIPT_DIR/lambda/thumbnail.py"
[ -f "$SCRIPT_DIR/lambda/burst-detector.py" ] && upload_code "burst-detector" "$SCRIPT_DIR/lambda/burst-detector.py"
[ -f "$SCRIPT_DIR/lambda/video-thumbnail.py" ] && upload_code "video-thumbnail-generator" "$SCRIPT_DIR/lambda/video-thumbnail.py"

# Publish layers and update function configs
echo "  Publishing layer versions..."
PILLOW_ARN=$(aws lambda publish-layer-version --layer-name rotate-pillow \
  --content S3Bucket="$ROTATE_LAYER_BUCKET",S3Key=rotate-layer.zip \
  --compatible-runtimes python3.12 --region "$REGION" --query 'LayerVersionArn' --output text)
aws lambda update-function-configuration --function-name photo-rotate --layers "$PILLOW_ARN" --region "$REGION" > /dev/null

THUMB_PILLOW_ARN=$(aws lambda publish-layer-version --layer-name thumbnail-pillow \
  --content S3Bucket="$THUMB_LAYER_BUCKET",S3Key=thumbnail-layer.zip \
  --compatible-runtimes python3.12 --region "$REGION" --query 'LayerVersionArn' --output text)
aws lambda update-function-configuration --function-name thumbnail-generator --layers "$THUMB_PILLOW_ARN" --region "$REGION" > /dev/null

BURST_ARN=$(aws lambda publish-layer-version --layer-name burst-detector-deps \
  --content S3Bucket="$BURST_LAYER_BUCKET",S3Key=burst-detector-layer.zip \
  --compatible-runtimes python3.12 --region "$REGION" --query 'LayerVersionArn' --output text)
aws lambda update-function-configuration --function-name burst-detector --layers "$BURST_ARN" --region "$REGION" > /dev/null

rm -rf "$TMPDIR"
echo "✓ All layers published and functions updated"

# =========================================
# Done — print outputs
# =========================================
echo ""
echo "========================================="
echo " ✓ Deployment Complete!"
echo "========================================="
echo ""
aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$REGION" \
  --query 'Stacks[0].Outputs[].[OutputKey,OutputValue]' --output table
echo ""
echo "NOTE: Upload ffmpeg-layer.zip to s3://$VIDEO_LAYER_BUCKET/ffmpeg-layer.zip manually,"
echo "then re-run the parent stack deploy to pick it up."
