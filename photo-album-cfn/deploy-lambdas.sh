#!/bin/bash
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

REGION="${1:-ap-east-2}"
PHOTO_BUCKET="${2:-bobyeh-894668260168-ap-east-2-an}"

echo "=== Deploy Lambda Functions (separate stack) ==="
echo "Region: $REGION"
echo "Bucket: $PHOTO_BUCKET"
echo ""

aws cloudformation deploy \
  --stack-name photo-album-lambdas \
  --template-file "$SCRIPT_DIR/lambdas-only.yaml" \
  --parameter-overrides PhotoBucketName="$PHOTO_BUCKET" \
  --capabilities CAPABILITY_IAM \
  --region "$REGION"

echo ""
echo "=== Outputs ==="
aws cloudformation describe-stacks --stack-name photo-album-lambdas --region "$REGION" \
  --query 'Stacks[0].Outputs[*].[OutputKey,OutputValue]' --output table

echo ""
echo "=== Upload Lambda code ==="
echo "Now update each function with actual code:"
echo ""
echo "  cd $SCRIPT_DIR"
echo "  zip -j /tmp/thumb.zip thumbnail/lambda_function.py"
echo "  aws lambda update-function-code --function-name thumbnail-generator --zip-file fileb:///tmp/thumb.zip --region $REGION"
echo ""
echo "  zip -j /tmp/rotate.zip rotate/lambda_function.py"
echo "  aws lambda update-function-code --function-name photo-rotate --zip-file fileb:///tmp/rotate.zip --region $REGION"
echo ""
echo "  zip -j /tmp/burst.zip burst-detector/lambda_function.py"
echo "  aws lambda update-function-code --function-name burst-detector --zip-file fileb:///tmp/burst.zip --region $REGION"
echo ""
echo "  zip -j /tmp/video.zip video-thumbnail/lambda_function.py"
echo "  aws lambda update-function-code --function-name video-thumbnail-generator --zip-file fileb:///tmp/video.zip --region $REGION"
echo ""
echo "Then trigger thumbnail batch generation:"
echo "  aws lambda invoke --function-name thumbnail-generator --region $REGION --payload '{\"bucket\": \"$PHOTO_BUCKET\"}' --cli-binary-format raw-in-base64-out /tmp/out.json && cat /tmp/out.json"
