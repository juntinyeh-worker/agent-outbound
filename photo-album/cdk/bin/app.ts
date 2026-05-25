#!/usr/bin/env node
import * as cdk from 'aws-cdk-lib';
import { PhotoAlbumStack } from '../lib/photo-album-stack';

const app = new cdk.App();

const photoBucketName = app.node.tryGetContext('photoBucket');
const adminEmail = app.node.tryGetContext('adminEmail');

if (!photoBucketName) throw new Error('Missing context: -c photoBucket=<your-bucket-name>');
if (!adminEmail) throw new Error('Missing context: -c adminEmail=<your-email>');

new PhotoAlbumStack(app, 'PhotoAlbumStack', {
  photoBucketName,
  adminEmail,
  env: {
    account: process.env.CDK_DEFAULT_ACCOUNT,
    region: process.env.CDK_DEFAULT_REGION,
  },
});
