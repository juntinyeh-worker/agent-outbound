#!/bin/bash
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "========================================="
echo " Video Thumbnail Generator — Deploy"
echo "========================================="

if ! command -v aws &>/dev/null; then echo "ERROR: aws CLI required."; exit 1; fi

read -p "AWS Region [us-east-1]: " REGION
REGION=${REGION:-us-east-1}

read -p "Photo/video S3 bucket name: " PHOTO_BUCKET
[ -z "$PHOTO_BUCKET" ] && echo "ERROR: Bucket name required." && exit 1

STACK_NAME="video-thumbnail"

echo ""
echo "→ [1/3] Building FFmpeg Lambda layer..."

LAYER_DIR=$(mktemp -d)
cd "$LAYER_DIR"

# Download pre-built FFmpeg static binary for Lambda (Amazon Linux 2023)
curl -sL https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-amd64-static.tar.xz -o ffmpeg.tar.xz
tar xf ffmpeg.tar.xz
mkdir -p bin
cp ffmpeg-*-amd64-static/ffmpeg bin/
chmod +x bin/ffmpeg
zip -r9 ffmpeg-layer.zip bin/ > /dev/null
echo "  Layer size: $(du -h ffmpeg-layer.zip | cut -f1)"

echo ""
echo "→ [2/3] Deploying CloudFormation stack..."
aws cloudformation deploy \
  --stack-name "$STACK_NAME" \
  --template-file "$SCRIPT_DIR/video-thumbnail-cfn.yaml" \
  --parameter-overrides PhotoBucketName="$PHOTO_BUCKET" \
  --capabilities CAPABILITY_IAM \
  --region "$REGION"

LAYER_BUCKET=$(aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" --region "$REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='LayerBucket'].OutputValue" --output text)

echo ""
echo "→ [3/3] Uploading layer and code..."
aws s3 cp "$LAYER_DIR/ffmpeg-layer.zip" "s3://$LAYER_BUCKET/ffmpeg-layer.zip" --region "$REGION"

# Upload Lambda code
CODE_DIR=$(mktemp -d)
cp "$SCRIPT_DIR/lambda_function.py" "$CODE_DIR/"
cd "$CODE_DIR" && zip -r9 code.zip lambda_function.py > /dev/null
aws lambda update-function-code --function-name video-thumbnail-generator --zip-file "fileb://code.zip" --region "$REGION" > /dev/null

LAYER_ARN=$(aws lambda publish-layer-version \
  --layer-name ffmpeg-layer \
  --content S3Bucket="$LAYER_BUCKET",S3Key=ffmpeg-layer.zip \
  --compatible-runtimes python3.12 \
  --region "$REGION" \
  --query 'LayerVersionArn' --output text)

aws lambda update-function-configuration \
  --function-name video-thumbnail-generator \
  --layers "$LAYER_ARN" \
  --region "$REGION" > /dev/null

rm -rf "$LAYER_DIR" "$CODE_DIR"

API_URL=$(aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" --region "$REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='VideoThumbApiUrl'].OutputValue" --output text)

echo ""
echo "========================================="
echo " ✓ Video Thumbnail Generator Deployed!"
echo "========================================="
echo ""
echo " API: $API_URL"
echo ""
echo " Auto-trigger: MOV/MP4 uploads generate thumbnails automatically"
echo ""
echo " Manual batch:"
echo "   curl -X POST $API_URL \\"
echo "     -H 'Content-Type: application/json' \\"
echo "     -d '{\"bucket\": \"$PHOTO_BUCKET\", \"prefix\": \"album/\"}'"
echo ""
