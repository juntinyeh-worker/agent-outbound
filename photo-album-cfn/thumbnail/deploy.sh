#!/bin/bash
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "========================================="
echo " Thumbnail Generator — Deploy"
echo "========================================="

if ! command -v aws &>/dev/null; then echo "ERROR: aws CLI required."; exit 1; fi

read -p "AWS Region [us-east-1]: " REGION
REGION=${REGION:-us-east-1}

read -p "Photo S3 bucket name: " PHOTO_BUCKET
[ -z "$PHOTO_BUCKET" ] && echo "ERROR: Bucket name required." && exit 1

STACK_NAME="thumbnail-generator"

echo ""
echo "→ [1/3] Building Lambda layer..."
LAYER_DIR=$(mktemp -d)
pip3 install Pillow -t "$LAYER_DIR/python" --quiet --platform manylinux2014_x86_64 --only-binary=:all:
cd "$LAYER_DIR" && zip -r9 thumbnail-layer.zip python/ > /dev/null

echo ""
echo "→ [2/3] Deploying CloudFormation stack..."
aws cloudformation deploy \
  --stack-name "$STACK_NAME" \
  --template-file "$SCRIPT_DIR/thumbnail-cfn.yaml" \
  --parameter-overrides PhotoBucketName="$PHOTO_BUCKET" \
  --capabilities CAPABILITY_IAM \
  --region "$REGION"

LAYER_BUCKET=$(aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" --region "$REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='ThumbnailLayerBucket'].OutputValue" --output text)

echo ""
echo "→ [3/3] Uploading layer and code..."
aws s3 cp "$LAYER_DIR/thumbnail-layer.zip" "s3://$LAYER_BUCKET/thumbnail-layer.zip" --region "$REGION"

CODE_DIR=$(mktemp -d)
cp "$SCRIPT_DIR/lambda_function.py" "$CODE_DIR/"
cd "$CODE_DIR" && zip -r9 code.zip lambda_function.py > /dev/null

aws lambda update-function-code \
  --function-name thumbnail-generator \
  --zip-file "fileb://code.zip" \
  --region "$REGION" > /dev/null

LAYER_ARN=$(aws lambda publish-layer-version \
  --layer-name thumbnail-pillow \
  --content S3Bucket="$LAYER_BUCKET",S3Key=thumbnail-layer.zip \
  --compatible-runtimes python3.12 \
  --region "$REGION" \
  --query 'LayerVersionArn' --output text)

aws lambda update-function-configuration \
  --function-name thumbnail-generator \
  --layers "$LAYER_ARN" \
  --region "$REGION" > /dev/null

rm -rf "$LAYER_DIR" "$CODE_DIR"

API_URL=$(aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" --region "$REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='ThumbnailApiUrl'].OutputValue" --output text)

echo ""
echo "========================================="
echo " ✓ Thumbnail Generator Deployed!"
echo "========================================="
echo ""
echo " API: $API_URL"
echo ""
echo " Auto-trigger: New uploads to '$PHOTO_BUCKET' will generate thumbnails"
echo ""
echo " Manual batch generate:"
echo "   curl -X POST $API_URL \\"
echo "     -H 'Content-Type: application/json' \\"
echo "     -d '{\"bucket\": \"$PHOTO_BUCKET\", \"prefix\": \"album-name/\"}'"
echo ""
echo " Force regenerate all:"
echo "   curl -X POST $API_URL \\"
echo "     -H 'Content-Type: application/json' \\"
echo "     -d '{\"bucket\": \"$PHOTO_BUCKET\", \"prefix\": \"\", \"force\": true}'"
echo ""
