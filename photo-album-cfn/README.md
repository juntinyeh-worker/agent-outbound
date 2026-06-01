# S3 Photo Album — CloudFormation Deploy

Pure CloudFormation deployment. No CDK, no Node.js required. Only needs AWS CLI.

## Deploy

```bash
chmod +x deploy.sh
./deploy.sh
```

The script will prompt for:
- AWS Region
- Your existing photo S3 bucket name
- Admin email (receives temporary password)

## What gets created
- S3 site bucket + CloudFront distribution
- Cognito User Pool with Viewer/Editor groups
- Cognito Identity Pool with role-based S3 access
- Admin user seeded into Editors group
- Frontend app uploaded to site bucket
