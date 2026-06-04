# Nested Change Set + SSM Parameter Resolution Issue - Reproduction

## Problem Summary

When using **"Include nested stacks in change set"** (`--include-nested-stacks`),
change set creation fails if a parent stack passes an SSM parameter **name** to a
child stack using `!GetAtt NestedStack.Outputs.SomeOutput`, and the receiving
child/grandchild stack declares that parameter with type
`AWS::SSM::Parameter::Value<String>`.

## Error Messages

```
Unable to fetch parameters
[{{IntrinsicFunction:dx-infra-blue-green-pat1-common-CommonStack-.../IAMStack.Outputs.EcsScalableTargetRoleSsmOutput/Fn::GetAtt}}]
from parameter store for this account.
```

## Stack Hierarchy

```
bootstrap.yaml              ← Deploy FIRST (pre-creates SSM params)

parent-stack.yaml           ← Main stack
└── common-stack.yaml (CommonStack)
    ├── iam-stack.yaml (IAMStack)
    │   └── Outputs: EcsScalableTargetRoleSsmOutput = "/dx/infra/dev-common/service-scheduler-role-arn"
    └── mvax-parent.yaml (MvaxStack)
        │   ScalableTargetRoleArnSsm = !GetAtt IAMStack.Outputs.EcsScalableTargetRoleSsmOutput  ← FAILS on change set
        └── app.yaml (App)
            ├── aurora-template.yaml  (ScalableTargetRoleArnSsm: Type: AWS::SSM::Parameter::Value<String>)
            └── dns-records.yaml      (PrivateHostedZoneId/Name: Type: AWS::SSM::Parameter::Value<String>)
```

## Deployment Steps

### Prerequisites

- AWS CLI configured with appropriate permissions
- An AWS account with access to CloudFormation, SSM, IAM, and S3

### Step 1 — Set variables

```bash
export BUCKET_NAME="cfn-nested-repro-$(aws sts get-caller-identity --query Account --output text)"
export AWS_REGION="us-east-1"
export ENVIRONMENT="dev"
```

### Step 2 — Create S3 bucket for templates

```bash
aws s3 mb s3://$BUCKET_NAME --region $AWS_REGION
```

### Step 3 — Deploy the bootstrap stack (pre-creates SSM parameters)

```bash
aws cloudformation deploy \
  --stack-name nested-changeset-bootstrap \
  --template-file infra/nested-changeset-repro/bootstrap.yaml \
  --parameter-overrides Environment=$ENVIRONMENT \
  --capabilities CAPABILITY_NAMED_IAM \
  --region $AWS_REGION
```

Wait for it to complete. This creates the SSM parameters that the nested stacks
will resolve via `AWS::SSM::Parameter::Value<String>`.

### Step 4 — Upload nested templates to S3

```bash
aws s3 cp infra/nested-changeset-repro/parent-stack.yaml \
  s3://$BUCKET_NAME/infra/build/1/parent-stack.yaml

aws s3 cp infra/nested-changeset-repro/common-stack.yaml \
  s3://$BUCKET_NAME/infra/build/1/child-stacks/common/common-stack.yaml

aws s3 cp infra/nested-changeset-repro/iam-stack.yaml \
  s3://$BUCKET_NAME/infra/build/1/child-stacks/common/common-child/iam-stack.yaml

aws s3 cp infra/nested-changeset-repro/mvax-parent.yaml \
  s3://$BUCKET_NAME/infra/build/1/child-stacks/common/common-child/mvax-parent.yaml

aws s3 cp infra/nested-changeset-repro/app.yaml \
  s3://$BUCKET_NAME/infra/build/1/child-stacks/common/common-child/app.yaml

aws s3 cp infra/nested-changeset-repro/aurora-template.yaml \
  s3://$BUCKET_NAME/modules/rds/aurora-template.yaml

aws s3 cp infra/nested-changeset-repro/dns-records.yaml \
  s3://$BUCKET_NAME/modules/dns/dns-records.yaml
```

### Step 5 — Create the parent stack (initial deployment)

```bash
aws cloudformation create-stack \
  --stack-name dx-infra-blue-green-pat1-common \
  --template-url https://$BUCKET_NAME.s3.amazonaws.com/infra/build/1/parent-stack.yaml \
  --parameters \
    ParameterKey=InfraS3Bucket,ParameterValue=https://$BUCKET_NAME.s3.amazonaws.com \
    ParameterKey=BuildName,ParameterValue=build \
    ParameterKey=BuildId,ParameterValue=1 \
    ParameterKey=Environment,ParameterValue=$ENVIRONMENT \
  --capabilities CAPABILITY_NAMED_IAM \
  --region $AWS_REGION

aws cloudformation wait stack-create-complete \
  --stack-name dx-infra-blue-green-pat1-common \
  --region $AWS_REGION
```

This should succeed — during normal creation, `!GetAtt` resolves correctly
because IAMStack completes before MvaxStack starts.

### Step 6 — Upload "build 2" templates (can be identical)

```bash
for file in parent-stack.yaml; do
  aws s3 cp infra/nested-changeset-repro/$file \
    s3://$BUCKET_NAME/infra/build/2/$file
done

aws s3 cp infra/nested-changeset-repro/common-stack.yaml \
  s3://$BUCKET_NAME/infra/build/2/child-stacks/common/common-stack.yaml

aws s3 cp infra/nested-changeset-repro/iam-stack.yaml \
  s3://$BUCKET_NAME/infra/build/2/child-stacks/common/common-child/iam-stack.yaml

aws s3 cp infra/nested-changeset-repro/mvax-parent.yaml \
  s3://$BUCKET_NAME/infra/build/2/child-stacks/common/common-child/mvax-parent.yaml

aws s3 cp infra/nested-changeset-repro/app.yaml \
  s3://$BUCKET_NAME/infra/build/2/child-stacks/common/common-child/app.yaml
```

### Step 7 — Create nested change set (THIS TRIGGERS THE ERROR)

```bash
aws cloudformation create-change-set \
  --stack-name dx-infra-blue-green-pat1-common \
  --change-set-name test-nested-changeset \
  --template-url https://$BUCKET_NAME.s3.amazonaws.com/infra/build/2/parent-stack.yaml \
  --parameters \
    ParameterKey=InfraS3Bucket,ParameterValue=https://$BUCKET_NAME.s3.amazonaws.com \
    ParameterKey=BuildName,ParameterValue=build \
    ParameterKey=BuildId,ParameterValue=2 \
    ParameterKey=Environment,ParameterValue=$ENVIRONMENT \
  --capabilities CAPABILITY_NAMED_IAM \
  --include-nested-stacks \
  --region $AWS_REGION
```

### Step 8 — Verify the failure

```bash
aws cloudformation describe-change-set \
  --stack-name dx-infra-blue-green-pat1-common \
  --change-set-name test-nested-changeset \
  --region $AWS_REGION \
  --query '{Status: Status, StatusReason: StatusReason}'
```

Expected:
```json
{
  "Status": "FAILED",
  "StatusReason": "Unable to fetch parameters [{{IntrinsicFunction:...-CommonStack-.../IAMStack.Outputs.EcsScalableTargetRoleSsmOutput/Fn::GetAtt}}] from parameter store for this account."
}
```

### Cleanup

```bash
aws cloudformation delete-stack \
  --stack-name dx-infra-blue-green-pat1-common \
  --region $AWS_REGION

aws cloudformation wait stack-delete-complete \
  --stack-name dx-infra-blue-green-pat1-common \
  --region $AWS_REGION

aws cloudformation delete-stack \
  --stack-name nested-changeset-bootstrap \
  --region $AWS_REGION

aws cloudformation wait stack-delete-complete \
  --stack-name nested-changeset-bootstrap \
  --region $AWS_REGION

aws s3 rb s3://$BUCKET_NAME --force
```

## Root Cause

This is a known limitation of nested change sets. When `--include-nested-stacks`
is used, CloudFormation evaluates `AWS::SSM::Parameter::Value` types across all
nested stacks simultaneously during change set creation. Cross-stack intrinsic
functions (`!GetAtt`, `!Ref` to resources) cannot be resolved at that stage
because they depend on execution order. The unresolved token is passed as a
literal string to SSM Parameter Store, which fails.

## Workarounds

1. **Hardcode the SSM path** (loses dynamism)
2. **Use `{{resolve:ssm:...}}` dynamic references** directly in leaf templates
3. **Skip nested change sets** (use `--no-include-nested-stacks`)
4. **Pass the resolved value** (the ARN itself) instead of the SSM parameter name
