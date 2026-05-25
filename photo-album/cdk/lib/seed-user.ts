import * as cdk from 'aws-cdk-lib';
import * as cognito from 'aws-cdk-lib/aws-cognito';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as cr from 'aws-cdk-lib/custom-resources';
import { Construct } from 'constructs';

export interface SeedUserProps {
  userPool: cognito.UserPool;
  groupName: string;
  adminEmail: string;
}

export class SeedUser extends Construct {
  constructor(scope: Construct, id: string, props: SeedUserProps) {
    super(scope, id);

    const onEvent = new cdk.aws_lambda.Function(this, 'Handler', {
      runtime: cdk.aws_lambda.Runtime.NODEJS_20_X,
      handler: 'index.handler',
      timeout: cdk.Duration.seconds(30),
      code: cdk.aws_lambda.Code.fromInline(`
const { CognitoIdentityProviderClient, AdminCreateUserCommand, AdminAddUserToGroupCommand } = require('@aws-sdk/client-cognito-identity-provider');
const client = new CognitoIdentityProviderClient();

exports.handler = async (event) => {
  if (event.RequestType === 'Delete') return { PhysicalResourceId: event.PhysicalResourceId };

  const { USER_POOL_ID, EMAIL, GROUP_NAME } = event.ResourceProperties;
  try {
    await client.send(new AdminCreateUserCommand({
      UserPoolId: USER_POOL_ID,
      Username: EMAIL,
      UserAttributes: [{ Name: 'email', Value: EMAIL }, { Name: 'email_verified', Value: 'true' }],
      DesiredDeliveryMediums: ['EMAIL'],
    }));
  } catch (e) {
    if (e.name !== 'UsernameExistsException') throw e;
  }

  await client.send(new AdminAddUserToGroupCommand({
    UserPoolId: USER_POOL_ID,
    Username: EMAIL,
    GroupName: GROUP_NAME,
  }));

  return { PhysicalResourceId: EMAIL };
};
      `),
    });

    onEvent.addToRolePolicy(new iam.PolicyStatement({
      actions: ['cognito-idp:AdminCreateUser', 'cognito-idp:AdminAddUserToGroup'],
      resources: [props.userPool.userPoolArn],
    }));

    new cdk.CustomResource(this, 'Resource', {
      serviceToken: new cr.Provider(this, 'Provider', { onEventHandler: onEvent }).serviceToken,
      properties: {
        USER_POOL_ID: props.userPool.userPoolId,
        EMAIL: props.adminEmail,
        GROUP_NAME: props.groupName,
      },
    });
  }
}
