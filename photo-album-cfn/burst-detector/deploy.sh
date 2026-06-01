#!/bin/bash
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "========================================="
echo " Burst Detector — Deploy"
echo "========================================="
echo ""

if ! command -v aws &>/dev/null; then
  echo "ERROR: 'aws' CLI required."
  exit 1
fi

read -p "AWS Region [us-east-1]: " REGION
REGION=${REGION:-us-east-1}

read -p "Photo S3 bucket name: " PHOTO_BUCKET
[ -z "$PHOTO_BUCKET" ] && echo "ERROR: Bucket name required." && exit 1

STACK_NAME="burst-detector"

echo ""
echo "→ [1/4] Building Lambda layer..."

# Build layer in a temp dir
LAYER_DIR=$(mktemp -d)
pip3 install \
  Pillow imagehash exifread numpy scipy \
  -t "$LAYER_DIR/python" --quiet --platform manylinux2014_x86_64 --only-binary=:all:

cd "$LAYER_DIR"
zip -r9 burst-detector-layer.zip python/ > /dev/null
LAYER_ZIP="$LAYER_DIR/burst-detector-layer.zip"
echo "  Layer size: $(du -h "$LAYER_ZIP" | cut -f1)"

echo ""
echo "→ [2/4] Deploying CloudFormation stack..."

aws cloudformation deploy \
  --stack-name "$STACK_NAME" \
  --template-file "$SCRIPT_DIR/burst-detector-cfn.yaml" \
  --parameter-overrides PhotoBucketName="$PHOTO_BUCKET" \
  --capabilities CAPABILITY_IAM \
  --region "$REGION"

# Get layer bucket
LAYER_BUCKET=$(aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" --region "$REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='LayerBucket'].OutputValue" --output text)

echo ""
echo "→ [3/4] Uploading layer and Lambda code..."

aws s3 cp "$LAYER_ZIP" "s3://$LAYER_BUCKET/burst-detector-layer.zip" --region "$REGION"

# Package and upload Lambda code
CODE_DIR=$(mktemp -d)
cp "$SCRIPT_DIR/lambda_function.py" "$CODE_DIR/"
cd "$CODE_DIR"
zip -r9 code.zip lambda_function.py > /dev/null

aws lambda update-function-code \
  --function-name burst-detector \
  --zip-file "fileb://code.zip" \
  --region "$REGION" > /dev/null

# Update layer
aws lambda publish-layer-version \
  --layer-name burst-detector-deps \
  --content S3Bucket="$LAYER_BUCKET",S3Key=burst-detector-layer.zip \
  --compatible-runtimes python3.12 \
  --region "$REGION" > /dev/null

LAYER_ARN=$(aws lambda list-layer-versions \
  --layer-name burst-detector-deps --region "$REGION" \
  --query 'LayerVersions[0].LayerVersionArn' --output text)

aws lambda update-function-configuration \
  --function-name burst-detector \
  --layers "$LAYER_ARN" \
  --region "$REGION" > /dev/null

echo ""
echo "→ [4/4] Getting API URL..."

API_URL=$(aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" --region "$REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='BurstApiUrl'].OutputValue" --output text)

# Cleanup
rm -rf "$LAYER_DIR" "$CODE_DIR"

echo ""
echo "========================================="
echo " ✓ Burst Detector Deployed!"
echo "========================================="
echo ""
echo " API: $API_URL"
echo ""
echo " Test it:"
echo "   curl -X POST $API_URL \\"
echo "     -H 'Content-Type: application/json' \\"
echo "     -d '{\"bucket\": \"$PHOTO_BUCKET\", \"prefix\": \"album-name/\"}'"
echo ""
