#!/bin/bash
set -e

echo "========================================="
echo " Photo Rotate — Deploy"
echo "========================================="

if ! command -v aws &>/dev/null; then echo "ERROR: aws CLI required."; exit 1; fi

read -p "AWS Region [us-east-1]: " REGION
REGION=${REGION:-us-east-1}

read -p "Photo S3 bucket name: " PHOTO_BUCKET
[ -z "$PHOTO_BUCKET" ] && echo "ERROR: Bucket name required." && exit 1

STACK_NAME="photo-rotate"

echo ""
echo "→ [1/3] Building Lambda layer..."
LAYER_DIR=$(mktemp -d)
pip3 install Pillow -t "$LAYER_DIR/python" --quiet --platform manylinux2014_x86_64 --only-binary=:all:
cd "$LAYER_DIR" && zip -r9 rotate-layer.zip python/ > /dev/null

echo ""
echo "→ [2/3] Deploying CloudFormation stack..."
aws cloudformation deploy \
  --stack-name "$STACK_NAME" \
  --template-file "$(dirname "$0")/rotate-cfn.yaml" \
  --parameter-overrides PhotoBucketName="$PHOTO_BUCKET" \
  --capabilities CAPABILITY_IAM \
  --region "$REGION"

LAYER_BUCKET=$(aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" --region "$REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='RotateLayerBucket'].OutputValue" --output text)

echo ""
echo "→ [3/3] Uploading layer and code..."
aws s3 cp "$LAYER_DIR/rotate-layer.zip" "s3://$LAYER_BUCKET/rotate-layer.zip" --region "$REGION"

CODE_DIR=$(mktemp -d)
cp "$(dirname "$0")/lambda_function.py" "$CODE_DIR/"
cd "$CODE_DIR" && zip -r9 code.zip lambda_function.py > /dev/null

aws lambda update-function-code \
  --function-name photo-rotate \
  --zip-file "fileb://code.zip" \
  --region "$REGION" > /dev/null

LAYER_ARN=$(aws lambda publish-layer-version \
  --layer-name rotate-pillow \
  --content S3Bucket="$LAYER_BUCKET",S3Key=rotate-layer.zip \
  --compatible-runtimes python3.12 \
  --region "$REGION" \
  --query 'LayerVersionArn' --output text)

aws lambda update-function-configuration \
  --function-name photo-rotate \
  --layers "$LAYER_ARN" \
  --region "$REGION" > /dev/null

rm -rf "$LAYER_DIR" "$CODE_DIR"

API_URL=$(aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" --region "$REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='RotateApiUrl'].OutputValue" --output text)

echo ""
echo "========================================="
echo " ✓ Photo Rotate Deployed!"
echo "========================================="
echo " API: $API_URL"
echo ""
