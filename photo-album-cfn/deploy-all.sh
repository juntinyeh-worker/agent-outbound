#!/bin/bash
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "========================================="
echo " S3 Photo Album — All-in-One Deploy"
echo "========================================="
echo ""

# --- Check prerequisites ---
if ! command -v aws &>/dev/null; then
  echo "ERROR: 'aws' CLI is required." && exit 1
fi
if ! command -v pip3 &>/dev/null; then
  echo "ERROR: 'pip3' is required for Lambda layers." && exit 1
fi
echo "✓ Prerequisites OK"

# --- Gather inputs ---
read -p "AWS Region [ap-east-2]: " REGION
REGION=${REGION:-ap-east-2}

read -p "Photo S3 bucket name: " PHOTO_BUCKET
[ -z "$PHOTO_BUCKET" ] && echo "ERROR: Required." && exit 1

CREATE_BUCKET="false"
IFS=',' read -ra BUCKET_LIST <<< "$PHOTO_BUCKET"
ALL_EXIST=true
for b in "${BUCKET_LIST[@]}"; do
  b=$(echo "$b" | xargs)
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

read -p "Template bucket [photo-album-templates-${REGION}]: " TEMPLATE_BUCKET
TEMPLATE_BUCKET=${TEMPLATE_BUCKET:-photo-album-templates-${REGION}}

STACK_NAME="photo-album"

echo ""
echo "  Region:          $REGION"
echo "  Photo Bucket:    $PHOTO_BUCKET (create: $CREATE_BUCKET)"
echo "  Admin Email:     $ADMIN_EMAIL"
echo "  Template Bucket: $TEMPLATE_BUCKET"
echo ""
read -p "Continue? [Y/n]: " CONFIRM
[[ ! "${CONFIRM:-Y}" =~ ^[Yy]$ ]] && echo "Aborted." && exit 0

# =========================================
# STEP 1: Create template bucket
# =========================================
echo ""
echo "→ [1/6] Ensuring template bucket exists..."
if ! aws s3api head-bucket --bucket "$TEMPLATE_BUCKET" --region "$REGION" 2>/dev/null; then
  if [ "$REGION" = "us-east-1" ]; then
    aws s3api create-bucket --bucket "$TEMPLATE_BUCKET" --region "$REGION"
  else
    aws s3api create-bucket --bucket "$TEMPLATE_BUCKET" --region "$REGION" \
      --create-bucket-configuration LocationConstraint="$REGION"
  fi
fi
echo "✓ Template bucket ready"

# =========================================
# STEP 2: Upload nested stack templates
# =========================================
echo ""
echo "→ [2/6] Uploading nested stack templates..."
aws s3 sync "$SCRIPT_DIR/stacks/" "s3://$TEMPLATE_BUCKET/stacks/" --region "$REGION" --quiet
echo "✓ Templates uploaded"

# =========================================
# STEP 3: Deploy parent stack
# =========================================
echo ""
echo "→ [3/6] Deploying stack..."
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
echo "✓ Stack deployed"

# =========================================
# STEP 4: Build Lambda layers
# =========================================
echo ""
echo "→ [4/6] Building Lambda layers..."
TMPDIR=$(mktemp -d)

echo "  Building Pillow layer..."
pip3 install Pillow -t "$TMPDIR/pillow/python" --quiet --platform manylinux2014_x86_64 --only-binary=:all: --python-version 3.12 2>/dev/null
cd "$TMPDIR/pillow" && zip -r9 "$TMPDIR/pillow-layer.zip" python/ > /dev/null

echo "  Building burst-detector layer..."
pip3 install Pillow imagehash exifread numpy scipy -t "$TMPDIR/burst/python" --quiet --platform manylinux2014_x86_64 --only-binary=:all: --python-version 3.12 2>/dev/null
cd "$TMPDIR/burst" && zip -r9 "$TMPDIR/burst-layer.zip" python/ > /dev/null
echo "✓ Layers built"

# =========================================
# STEP 5: Upload code & layers to Lambda
# =========================================
echo ""
echo "→ [5/6] Uploading Lambda code and layers..."

upload_code() {
  local func_name=$1 src=$2
  local code_dir=$(mktemp -d)
  cp "$src" "$code_dir/lambda_function.py"
  cd "$code_dir" && zip -r9 code.zip lambda_function.py > /dev/null
  aws lambda update-function-code --function-name "$func_name" --zip-file "fileb://code.zip" --region "$REGION" > /dev/null
  rm -rf "$code_dir"
  echo "  ✓ $func_name code uploaded"
}

upload_code "thumbnail-generator" "$SCRIPT_DIR/thumbnail/lambda_function.py"
upload_code "photo-rotate" "$SCRIPT_DIR/rotate/lambda_function.py"
upload_code "burst-detector" "$SCRIPT_DIR/burst-detector/lambda_function.py"
upload_code "video-thumbnail-generator" "$SCRIPT_DIR/video-thumbnail/lambda_function.py"

# Publish and attach layers
echo "  Publishing layers..."
PILLOW_ARN=$(aws lambda publish-layer-version --layer-name thumbnail-pillow \
  --zip-file "fileb://$TMPDIR/pillow-layer.zip" \
  --compatible-runtimes python3.12 --region "$REGION" --query 'LayerVersionArn' --output text)

aws lambda update-function-configuration --function-name thumbnail-generator --layers "$PILLOW_ARN" --region "$REGION" > /dev/null
aws lambda update-function-configuration --function-name photo-rotate --layers "$PILLOW_ARN" --region "$REGION" > /dev/null

BURST_ARN=$(aws lambda publish-layer-version --layer-name burst-detector-deps \
  --zip-file "fileb://$TMPDIR/burst-layer.zip" \
  --compatible-runtimes python3.12 --region "$REGION" --query 'LayerVersionArn' --output text)
aws lambda update-function-configuration --function-name burst-detector --layers "$BURST_ARN" --region "$REGION" > /dev/null

rm -rf "$TMPDIR"
echo "✓ Layers published"
echo "  NOTE: ffmpeg layer for video-thumbnail must be uploaded manually"

# =========================================
# STEP 6: Generate & upload frontend
# =========================================
echo ""
echo "→ [6/6] Generating frontend..."

get_output() {
  aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$REGION" \
    --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text
}

CLOUDFRONT_URL=$(get_output CloudFrontURL)
USER_POOL_ID=$(get_output UserPoolId)
CLIENT_ID=$(get_output UserPoolClientId)
IDENTITY_POOL_ID=$(get_output IdentityPoolId)
SITE_BUCKET=$(get_output SiteBucket)
ROTATE_API_URL=$(get_output RotateApiUrl)
BURST_API_URL=$(get_output BurstApiUrl)
THUMBNAIL_API_URL=$(get_output ThumbnailApiUrl)

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

# =========================================
# Done
# =========================================
echo ""
echo "========================================="
echo " ✓ Deployment Complete!"
echo "========================================="
echo ""
echo " URL: $CLOUDFRONT_URL"
echo ""
echo " API Endpoints:"
echo "   Rotate:    $ROTATE_API_URL"
echo "   Thumbnail: $THUMBNAIL_API_URL"
echo "   Burst:     $BURST_API_URL"
echo ""
echo " Check email ($ADMIN_EMAIL) for temp password"
echo ""
