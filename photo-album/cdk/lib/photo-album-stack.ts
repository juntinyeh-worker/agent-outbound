import * as cdk from 'aws-cdk-lib';
import * as cognito from 'aws-cdk-lib/aws-cognito';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as s3 from 'aws-cdk-lib/aws-s3';
import * as cloudfront from 'aws-cdk-lib/aws-cloudfront';
import * as origins from 'aws-cdk-lib/aws-cloudfront-origins';
import * as s3deploy from 'aws-cdk-lib/aws-s3-deployment';
import { Construct } from 'constructs';
import { SeedUser } from './seed-user';

export interface PhotoAlbumStackProps extends cdk.StackProps {
  photoBucketName: string;
  adminEmail: string;
}

export class PhotoAlbumStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props: PhotoAlbumStackProps) {
    super(scope, id, props);

    const photoBucket = s3.Bucket.fromBucketName(this, 'PhotosBucket', props.photoBucketName);

    // --- Site Bucket ---
    const siteBucket = new s3.Bucket(this, 'SiteBucket', {
      encryption: s3.BucketEncryption.S3_MANAGED,
      blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
      removalPolicy: cdk.RemovalPolicy.DESTROY,
      autoDeleteObjects: true,
    });

    // --- CloudFront ---
    const distribution = new cloudfront.Distribution(this, 'Distribution', {
      defaultBehavior: { origin: origins.S3BucketOrigin.withOriginAccessControl(siteBucket) },
      defaultRootObject: 'index.html',
      enableLogging: true,
    });

    // --- Cognito User Pool ---
    const userPool = new cognito.UserPool(this, 'UserPool', {
      selfSignUpEnabled: false,
      signInAliases: { email: true },
      autoVerify: { email: true },
      passwordPolicy: { minLength: 8 },
      accountRecovery: cognito.AccountRecovery.EMAIL_ONLY,
    });

    const userPoolClient = userPool.addClient('WebClient', {
      authFlows: { userSrp: true },
      preventUserExistenceErrors: true,
    });

    // --- IAM Roles ---
    const viewerRole = new iam.Role(this, 'ViewerRole', {
      assumedBy: new iam.FederatedPrincipal('cognito-identity.amazonaws.com', {}, 'sts:AssumeRoleWithWebIdentity'),
    });
    viewerRole.addToPolicy(new iam.PolicyStatement({
      actions: ['s3:ListBucket'],
      resources: [photoBucket.bucketArn],
    }));
    viewerRole.addToPolicy(new iam.PolicyStatement({
      actions: ['s3:GetObject'],
      resources: [photoBucket.arnForObjects('*')],
    }));

    const editorRole = new iam.Role(this, 'EditorRole', {
      assumedBy: new iam.FederatedPrincipal('cognito-identity.amazonaws.com', {}, 'sts:AssumeRoleWithWebIdentity'),
    });
    editorRole.addToPolicy(new iam.PolicyStatement({
      actions: ['s3:ListBucket'],
      resources: [photoBucket.bucketArn],
    }));
    editorRole.addToPolicy(new iam.PolicyStatement({
      actions: ['s3:GetObject', 's3:PutObject', 's3:DeleteObject'],
      resources: [photoBucket.arnForObjects('*')],
    }));

    // --- Cognito Groups ---
    new cognito.CfnUserPoolGroup(this, 'ViewersGroup', {
      userPoolId: userPool.userPoolId,
      groupName: 'Viewers',
      roleArn: viewerRole.roleArn,
      precedence: 2,
    });

    new cognito.CfnUserPoolGroup(this, 'EditorsGroup', {
      userPoolId: userPool.userPoolId,
      groupName: 'Editors',
      roleArn: editorRole.roleArn,
      precedence: 1,
    });

    // --- Identity Pool ---
    const identityPool = new cognito.CfnIdentityPool(this, 'IdentityPool', {
      allowUnauthenticatedIdentities: false,
      cognitoIdentityProviders: [{
        clientId: userPoolClient.userPoolClientId,
        providerName: userPool.userPoolProviderName,
      }],
    });

    // Patch trust policies
    const trustCondition = {
      StringEquals: { 'cognito-identity.amazonaws.com:aud': identityPool.ref },
      'ForAnyValue:StringLike': { 'cognito-identity.amazonaws.com:amr': 'authenticated' },
    };
    (viewerRole.node.defaultChild as iam.CfnRole).addOverride(
      'Properties.AssumeRolePolicyDocument.Statement.0.Condition', trustCondition,
    );
    (editorRole.node.defaultChild as iam.CfnRole).addOverride(
      'Properties.AssumeRolePolicyDocument.Statement.0.Condition', trustCondition,
    );

    // Token-based role mapping
    new cognito.CfnIdentityPoolRoleAttachment(this, 'RoleAttachment', {
      identityPoolId: identityPool.ref,
      roles: { authenticated: viewerRole.roleArn },
      roleMappings: {
        mapping: {
          type: 'Token',
          ambiguousRoleResolution: 'AuthenticatedRole',
          identityProvider: `${userPool.userPoolProviderName}:${userPoolClient.userPoolClientId}`,
        },
      },
    });

    // --- Seed Admin User ---
    new SeedUser(this, 'SeedAdmin', {
      userPool,
      groupName: 'Editors',
      adminEmail: props.adminEmail,
    });

    // --- Outputs ---
    new cdk.CfnOutput(this, 'CloudFrontURL', { value: `https://${distribution.distributionDomainName}` });
    new cdk.CfnOutput(this, 'UserPoolId', { value: userPool.userPoolId });
    new cdk.CfnOutput(this, 'UserPoolClientId', { value: userPoolClient.userPoolClientId });
    new cdk.CfnOutput(this, 'IdentityPoolId', { value: identityPool.ref });
    new cdk.CfnOutput(this, 'PhotoBucket', { value: props.photoBucketName });
    new cdk.CfnOutput(this, 'SiteBucket', { value: siteBucket.bucketName });
  }
}
