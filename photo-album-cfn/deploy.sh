#!/bin/bash
set -e

echo "========================================="
echo " S3 Photo Album — One-Click Deploy"
echo "========================================="
echo ""

# --- Check prerequisites ---
if ! command -v aws &>/dev/null; then
  echo "ERROR: 'aws' CLI is required but not installed."
  exit 1
fi
echo "✓ AWS CLI found"

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

STACK_NAME="photo-album"

echo ""
echo "Deploying with:"
echo "  Region:       $REGION"
echo "  Photo Bucket: $PHOTO_BUCKET"
echo "  Admin Email:  $ADMIN_EMAIL"
echo "  Stack Name:   $STACK_NAME"
echo ""
read -p "Continue? [Y/n]: " CONFIRM
CONFIRM=${CONFIRM:-Y}
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
  echo "Aborted."
  exit 0
fi

# --- Step 1: Deploy CloudFormation Stack ---
echo ""
echo "→ [1/3] Deploying CloudFormation stack..."
aws cloudformation deploy \
  --stack-name "$STACK_NAME" \
  --template-file photo-album-cfn.yaml \
  --parameter-overrides \
    PhotoBucketName="$PHOTO_BUCKET" \
    AdminEmail="$ADMIN_EMAIL" \
  --capabilities CAPABILITY_IAM \
  --region "$REGION"

echo "✓ Stack deployed"

# --- Step 2: Get stack outputs ---
echo ""
echo "→ [2/3] Retrieving stack outputs..."

get_output() {
  aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" \
    --region "$REGION" \
    --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" \
    --output text
}

CLOUDFRONT_URL=$(get_output CloudFrontURL)
USER_POOL_ID=$(get_output UserPoolId)
CLIENT_ID=$(get_output UserPoolClientId)
IDENTITY_POOL_ID=$(get_output IdentityPoolId)
SITE_BUCKET=$(get_output SiteBucket)

echo "  CloudFront:    $CLOUDFRONT_URL"
echo "  UserPool:      $USER_POOL_ID"
echo "  ClientId:      $CLIENT_ID"
echo "  IdentityPool:  $IDENTITY_POOL_ID"
echo "  SiteBucket:    $SITE_BUCKET"

# --- Step 3: Generate and upload frontend ---
echo ""
echo "→ [3/3] Generating frontend and uploading to site bucket..."

cat > /tmp/index.html << 'FRONTEND_EOF'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>S3 Photo Album</title>
<style>
* { margin: 0; padding: 0; box-sizing: border-box; }
body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; background: #1a1a2e; color: #eee; min-height: 100vh; }
.header { display: flex; justify-content: space-between; align-items: center; padding: 12px 24px; background: #16213e; border-bottom: 1px solid #0f3460; }
.header h1 { font-size: 18px; font-weight: 500; }
.header .user { display: flex; align-items: center; gap: 12px; font-size: 14px; }
.header .badge { background: #e94560; padding: 2px 8px; border-radius: 4px; font-size: 11px; font-weight: 600; }
.header .badge.viewer { background: #0f3460; }
.breadcrumb { padding: 10px 24px; font-size: 13px; color: #888; border-bottom: 1px solid #0f3460; }
.breadcrumb a { color: #4ea8de; text-decoration: none; cursor: pointer; }
.grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(180px, 1fr)); gap: 16px; padding: 24px; }
.card { background: #16213e; border-radius: 8px; overflow: hidden; cursor: pointer; transition: transform 0.15s; }
.card:hover { transform: translateY(-2px); box-shadow: 0 4px 20px rgba(233,69,96,0.2); }
.card .thumb { width: 100%; aspect-ratio: 1; object-fit: cover; background: #0f3460; display: flex; align-items: center; justify-content: center; font-size: 48px; }
.card .thumb img { width: 100%; height: 100%; object-fit: cover; }
.card .info { padding: 8px 12px; }
.card .info .name { font-size: 12px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.card .info .meta { font-size: 11px; color: #666; margin-top: 2px; }
.lightbox { display: none; position: fixed; inset: 0; background: rgba(0,0,0,0.95); z-index: 100; flex-direction: column; }
.lightbox.active { display: flex; }
.lightbox .toolbar { display: flex; justify-content: space-between; align-items: center; padding: 12px 24px; background: #111; }
.lightbox .toolbar .title { font-size: 14px; }
.lightbox .toolbar button { padding: 6px 14px; border: none; border-radius: 4px; cursor: pointer; font-size: 12px; font-weight: 500; }
.btn-purge { background: #3d0000; color: #e94560; }
.btn-close { background: #333; color: #eee; }
.lightbox .image-area { flex: 1; display: flex; align-items: center; justify-content: center; padding: 24px; }
.lightbox .image-area img { max-width: 100%; max-height: 100%; object-fit: contain; border-radius: 4px; }
.login-overlay { position: fixed; inset: 0; background: #1a1a2e; display: flex; align-items: center; justify-content: center; z-index: 200; }
.login-box { background: #16213e; padding: 40px; border-radius: 12px; text-align: center; width: 320px; }
.login-box h2 { margin-bottom: 24px; font-weight: 500; }
.login-box input { width: 100%; padding: 10px 14px; margin-bottom: 12px; border-radius: 6px; border: 1px solid #0f3460; background: #1a1a2e; color: #eee; font-size: 14px; }
.login-box button { width: 100%; padding: 10px; background: #e94560; color: #fff; border: none; border-radius: 6px; font-size: 14px; cursor: pointer; font-weight: 500; }
.login-box .error { color: #e94560; font-size: 12px; margin-top: 8px; display: none; }
.login-box .note { margin-top: 16px; font-size: 11px; color: #666; }
.loading { text-align: center; padding: 60px; color: #888; }
</style>
</head>
<body>

<div class="login-overlay" id="loginOverlay">
  <div class="login-box">
    <h2>📷 S3 Photo Album</h2>
    <input type="email" id="emailInput" placeholder="Email">
    <input type="password" id="passwordInput" placeholder="Password">
    <div id="newPasswordSection" style="display:none">
      <input type="password" id="newPasswordInput" placeholder="New Password (required on first login)">
    </div>
    <button id="loginBtn" onclick="handleLogin()">Sign In</button>
    <div class="error" id="loginError"></div>
    <div class="note">Authenticated via Amazon Cognito</div>
  </div>
</div>

<div class="header">
  <h1>📷 S3 Photo Album</h1>
  <div class="user">
    <span class="badge" id="roleBadge">Viewer</span>
    <span id="userEmail"></span>
    <button style="background:#333;color:#eee;border:none;padding:4px 10px;border-radius:4px;cursor:pointer;font-size:12px" onclick="logout()">Logout</button>
  </div>
</div>

<div class="breadcrumb" id="breadcrumb"></div>
<div class="grid" id="grid"><div class="loading">Sign in to view albums</div></div>

<div class="lightbox" id="lightbox">
  <div class="toolbar">
    <div class="title" id="lightboxTitle"></div>
    <div style="display:flex;gap:8px">
      <button class="btn-purge" id="purgeBtn" onclick="purgePhoto()">🗑 Purge</button>
      <button class="btn-close" onclick="closeLightbox()">✕ Close</button>
    </div>
  </div>
  <div class="image-area">
    <img id="lightboxImg" src="" alt="">
  </div>
</div>

<script src="https://cdn.jsdelivr.net/npm/amazon-cognito-identity-js@6/dist/amazon-cognito-identity.min.js"></script>
<script src="https://sdk.amazonaws.com/js/aws-sdk-2.1692.0.min.js"></script>
<script>
const CONFIG = {
  region: '%%REGION%%',
  userPoolId: '%%USER_POOL_ID%%',
  clientId: '%%CLIENT_ID%%',
  identityPoolId: '%%IDENTITY_POOL_ID%%',
  photoBucket: '%%PHOTO_BUCKET%%'
};

let currentPath = '';
let userSession = null;
let userGroup = null;

const poolData = { UserPoolId: CONFIG.userPoolId, ClientId: CONFIG.clientId };
const userPool = new AmazonCognitoIdentity.CognitoUserPool(poolData);

function showError(msg) {
  const el = document.getElementById('loginError');
  el.textContent = msg;
  el.style.display = 'block';
}

let cognitoUser = null;

function handleLogin() {
  const email = document.getElementById('emailInput').value;
  const password = document.getElementById('passwordInput').value;
  const newPassword = document.getElementById('newPasswordInput').value;

  if (cognitoUser && newPassword) {
    cognitoUser.completeNewPasswordChallenge(newPassword, {}, {
      onSuccess: (session) => { onLoginSuccess(session, email); },
      onFailure: (err) => { showError(err.message); }
    });
    return;
  }

  const authDetails = new AmazonCognitoIdentity.AuthenticationDetails({ Username: email, Password: password });
  cognitoUser = new AmazonCognitoIdentity.CognitoUser({ Username: email, Pool: userPool });

  cognitoUser.authenticateUser(authDetails, {
    onSuccess: (session) => { onLoginSuccess(session, email); },
    onFailure: (err) => { showError(err.message); },
    newPasswordRequired: () => {
      document.getElementById('newPasswordSection').style.display = 'block';
      document.getElementById('loginBtn').textContent = 'Set New Password';
      showError('Please set a new password.');
    }
  });
}

function onLoginSuccess(session, email) {
  userSession = session;
  document.getElementById('loginOverlay').style.display = 'none';
  document.getElementById('userEmail').textContent = email;

  const payload = session.getIdToken().decodePayload();
  const groups = payload['cognito:groups'] || [];
  userGroup = groups.includes('Editors') ? 'Editors' : 'Viewers';
  document.getElementById('roleBadge').textContent = userGroup === 'Editors' ? 'Editor' : 'Viewer';
  document.getElementById('roleBadge').className = 'badge' + (userGroup === 'Viewers' ? ' viewer' : '');
  document.getElementById('purgeBtn').style.display = userGroup === 'Editors' ? '' : 'none';

  setupAWS(session);
}

function setupAWS(session) {
  const token = session.getIdToken().getJwtToken();
  const logins = {};
  logins[`cognito-idp.${CONFIG.region}.amazonaws.com/${CONFIG.userPoolId}`] = token;

  AWS.config.region = CONFIG.region;
  AWS.config.credentials = new AWS.CognitoIdentityCredentials({
    IdentityPoolId: CONFIG.identityPoolId,
    Logins: logins
  });

  AWS.config.credentials.refresh((err) => {
    if (err) { console.error(err); return; }
    listObjects('');
  });
}

function listObjects(prefix) {
  currentPath = prefix;
  updateBreadcrumb();
  const s3 = new AWS.S3();
  s3.listObjectsV2({
    Bucket: CONFIG.photoBucket,
    Prefix: prefix,
    Delimiter: '/'
  }, (err, data) => {
    if (err) { console.error(err); return; }
    renderGrid(data);
  });
}

function updateBreadcrumb() {
  const parts = currentPath.split('/').filter(Boolean);
  let html = `<a onclick="listObjects('')">${CONFIG.photoBucket}</a>`;
  let path = '';
  parts.forEach(p => {
    path += p + '/';
    const pp = path;
    html += ` / <a onclick="listObjects('${pp}')">${p}</a>`;
  });
  document.getElementById('breadcrumb').innerHTML = html;
}

function renderGrid(data) {
  const grid = document.getElementById('grid');
  let html = '';

  (data.CommonPrefixes || []).forEach(p => {
    const name = p.Prefix.replace(currentPath, '');
    html += `<div class="card" onclick="listObjects('${p.Prefix}')">
      <div class="thumb">📁</div>
      <div class="info"><div class="name">${name}</div></div>
    </div>`;
  });

  (data.Contents || []).forEach(obj => {
    if (obj.Key === currentPath) return;
    const name = obj.Key.replace(currentPath, '');
    const size = (obj.Size / 1024 / 1024).toFixed(1) + ' MB';
    const isImage = /\.(jpg|jpeg|png|gif|webp|bmp)$/i.test(name);
    if (isImage) {
      html += `<div class="card" onclick="openPhoto('${obj.Key}')">
        <div class="thumb"><img src="" data-key="${obj.Key}" onload="this.style.opacity=1" style="opacity:0;transition:opacity 0.3s"></div>
        <div class="info"><div class="name">${name}</div><div class="meta">${size}</div></div>
      </div>`;
    } else {
      html += `<div class="card">
        <div class="thumb">📄</div>
        <div class="info"><div class="name">${name}</div><div class="meta">${size}</div></div>
      </div>`;
    }
  });

  if (!html) html = '<div class="loading">No items in this folder</div>';
  grid.innerHTML = html;

  // Load thumbnails
  document.querySelectorAll('[data-key]').forEach(img => {
    const s3 = new AWS.S3();
    s3.getSignedUrl('getObject', { Bucket: CONFIG.photoBucket, Key: img.dataset.key, Expires: 300 }, (err, url) => {
      if (!err) img.src = url;
    });
  });
}

let currentPhotoKey = '';
function openPhoto(key) {
  currentPhotoKey = key;
  const name = key.split('/').pop();
  document.getElementById('lightboxTitle').textContent = name;
  document.getElementById('lightbox').classList.add('active');
  const s3 = new AWS.S3();
  s3.getSignedUrl('getObject', { Bucket: CONFIG.photoBucket, Key: key, Expires: 300 }, (err, url) => {
    if (!err) document.getElementById('lightboxImg').src = url;
  });
}

function closeLightbox() {
  document.getElementById('lightbox').classList.remove('active');
  document.getElementById('lightboxImg').src = '';
}

function purgePhoto() {
  if (!confirm('Permanently delete this photo?')) return;
  const s3 = new AWS.S3();
  s3.deleteObject({ Bucket: CONFIG.photoBucket, Key: currentPhotoKey }, (err) => {
    if (err) { alert('Delete failed: ' + err.message); return; }
    closeLightbox();
    listObjects(currentPath);
  });
}

function logout() {
  const user = userPool.getCurrentUser();
  if (user) user.signOut();
  location.reload();
}

document.addEventListener('keydown', (e) => { if (e.key === 'Escape') closeLightbox(); });
</script>
</body>
</html>
FRONTEND_EOF

# Inject config values
sed -i "s|%%REGION%%|$REGION|g" /tmp/index.html
sed -i "s|%%USER_POOL_ID%%|$USER_POOL_ID|g" /tmp/index.html
sed -i "s|%%CLIENT_ID%%|$CLIENT_ID|g" /tmp/index.html
sed -i "s|%%IDENTITY_POOL_ID%%|$IDENTITY_POOL_ID|g" /tmp/index.html
sed -i "s|%%PHOTO_BUCKET%%|$PHOTO_BUCKET|g" /tmp/index.html

# Upload to site bucket
aws s3 cp /tmp/index.html "s3://$SITE_BUCKET/index.html" \
  --content-type "text/html" \
  --region "$REGION"

rm -f /tmp/index.html

echo "✓ Frontend uploaded"

echo ""
echo "========================================="
echo " ✓ Deployment Complete!"
echo "========================================="
echo ""
echo " URL:  $CLOUDFRONT_URL"
echo ""
echo "NEXT STEPS:"
echo " 1. Check your email ($ADMIN_EMAIL) for the temporary password"
echo " 2. Open: $CLOUDFRONT_URL"
echo " 3. Log in and set a new password"
echo " 4. You are in the 'Editors' group — you can browse and delete photos"
echo ""
echo "NOTE: CloudFront may take 1-2 minutes to propagate."
echo ""
