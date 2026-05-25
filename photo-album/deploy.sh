#!/bin/bash
set -e

echo "========================================="
echo "  S3 Photo Album — One-Click Deploy"
echo "========================================="
echo ""

# --- Check prerequisites ---
for cmd in node npm aws cdk; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: '$cmd' is required but not installed."
    exit 1
  fi
done

echo "✓ Prerequisites OK (node, npm, aws, cdk)"
echo ""

# --- Gather inputs ---
read -p "AWS Region [us-east-1]: " REGION
REGION=${REGION:-us-east-1}

read -p "Existing photo S3 bucket name: " PHOTO_BUCKET
if [ -z "$PHOTO_BUCKET" ]; then
  echo "ERROR: Photo bucket name is required."
  exit 1
fi

read -p "Admin email (will receive temp password): " ADMIN_EMAIL
if [ -z "$ADMIN_EMAIL" ]; then
  echo "ERROR: Admin email is required."
  exit 1
fi

echo ""
echo "Deploying with:"
echo "  Region:       $REGION"
echo "  Photo Bucket: $PHOTO_BUCKET"
echo "  Admin Email:  $ADMIN_EMAIL"
echo ""
read -p "Continue? [Y/n]: " CONFIRM
CONFIRM=${CONFIRM:-Y}
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
  echo "Aborted."
  exit 0
fi

# --- Install & Deploy ---
cd "$(dirname "$0")/cdk"

echo ""
echo "→ Installing dependencies..."
npm install

echo ""
echo "→ Bootstrapping CDK (if needed)..."
cdk bootstrap "aws://${CDK_DEFAULT_ACCOUNT:-$(aws sts get-caller-identity --query Account --output text)}/$REGION" 2>/dev/null || true

echo ""
echo "→ Deploying stack..."
export CDK_DEFAULT_REGION="$REGION"
cdk deploy PhotoAlbumStack \
  -c photoBucket="$PHOTO_BUCKET" \
  -c adminEmail="$ADMIN_EMAIL" \
  --require-approval never \
  --outputs-file ../outputs.json

echo ""
echo "========================================="
echo "  ✓ Deployment Complete!"
echo "========================================="
echo ""
cat ../outputs.json 2>/dev/null || true
echo ""
echo "NEXT STEPS:"
echo "  1. Check your email ($ADMIN_EMAIL) for the temporary password"
echo "  2. Open the CloudFront URL from the outputs above"
echo "  3. Log in and set a new password"
echo "  4. You are in the 'Editors' group — you can purge, rotate, and comment"
echo ""
echo "To add more users:"
echo "  aws cognito-idp admin-create-user --user-pool-id <POOL_ID> --username <email>"
echo "  aws cognito-idp admin-add-user-to-group --user-pool-id <POOL_ID> --username <email> --group-name Viewers"
echo ""
