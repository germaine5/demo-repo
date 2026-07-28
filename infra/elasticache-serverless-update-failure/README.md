# ElastiCache ServerlessCache Update/Rollback Failure — Reproduction Guide

This directory contains three versioned CloudFormation templates that reproduce a confirmed bug
in `AWS::ElastiCache::ServerlessCache` property updates. Deploying them in sequence replicates
two distinct failure modes.

---

## Bug Summary

| Step | Template | Operation | Expected | Actual (buggy) |
|------|----------|-----------|----------|----------------|
| 1 | `template-v1.yaml` | CREATE | `CREATE_COMPLETE` | `CREATE_COMPLETE` ✓ |
| 2 | `template-v2.yaml` | UPDATE — add `MajorEngineVersion: '9'` | `UPDATE_COMPLETE` | Intermittently `UPDATE_FAILED` → `UPDATE_ROLLBACK_COMPLETE` |
| 3 | `template-v3.yaml` | UPDATE — add `ECPUPerSecond.Minimum: '2000'` | `UPDATE_COMPLETE` | `UPDATE_FAILED` → **`UPDATE_ROLLBACK_FAILED`** (stack stuck) |

---

## Prerequisites

- AWS CLI configured with credentials that have permission to create/update CloudFormation stacks,
  EC2 VPCs/subnets/security groups, and ElastiCache serverless caches.
- Deploy in **us-west-2** — this matches the customer's environment where the bug was observed.
  Valkey 9 availability can be verified with:
  ```
  aws elasticache describe-engine-default-parameters --cache-parameter-group-family valkey9 --region us-west-2
  ```
- Sufficient ElastiCache Serverless quota in the target account/region.

---

## Step-by-Step Deployment

### Step 1 — Deploy the baseline stack (CREATE)

```bash
STACK_NAME=ecache-repro
REGION=us-west-2   # must match customer region to replicate the bug

aws cloudformation deploy \
  --template-file template-v1.yaml \
  --stack-name $STACK_NAME \
  --region $REGION \
  --capabilities CAPABILITY_IAM \
  --no-fail-on-empty-changeset
```

**Expected result**: Stack reaches `CREATE_COMPLETE`.

Verify:
```bash
aws cloudformation describe-stacks \
  --stack-name $STACK_NAME \
  --region $REGION \
  --query 'Stacks[0].StackStatus'
```

> **Note**: ElastiCache Serverless CREATE can take 5–10 minutes. The `aws cloudformation deploy`
> command will wait for completion automatically.

---

### Step 2 — Add `MajorEngineVersion: '9'` (intermittent failure)

```bash
aws cloudformation deploy \
  --template-file template-v2.yaml \
  --stack-name $STACK_NAME \
  --region $REGION \
  --no-fail-on-empty-changeset
```

**Expected result (buggy service)**: This update intermittently fails. You may see:
- `UPDATE_COMPLETE` ✓ — success on this attempt, proceed to Step 3.
- `UPDATE_FAILED` → `UPDATE_ROLLBACK_COMPLETE` — re-run the same deploy command and try again.

Check the failure reason if the update failed:
```bash
aws cloudformation describe-stack-events \
  --stack-name $STACK_NAME \
  --region $REGION \
  --query 'StackEvents[?ResourceStatus==`UPDATE_FAILED`].[LogicalResourceId,ResourceStatusReason]' \
  --output table
```

**Repeat Step 2 until the stack reaches `UPDATE_COMPLETE` before continuing.**

---

### Step 3 — Add `ECPUPerSecond.Minimum: '2000'` (deterministic failure + rollback failure)

> ⚠️ **Only proceed after Step 2 has reached `UPDATE_COMPLETE`.**

```bash
aws cloudformation deploy \
  --template-file template-v3.yaml \
  --stack-name $STACK_NAME \
  --region $REGION \
  --no-fail-on-empty-changeset
```

**Expected result (buggy service)**:

1. CloudFormation starts the update.
2. The `ServerlessCache` resource handler returns "Internal failure".
3. CloudFormation attempts to roll back.
4. The rollback also fails with "Internal failure".
5. Stack status: **`UPDATE_ROLLBACK_FAILED`** ← bug confirmed.

Check the full event log:
```bash
aws cloudformation describe-stack-events \
  --stack-name $STACK_NAME \
  --region $REGION \
  --query 'StackEvents[?ResourceStatus==`UPDATE_FAILED` || ResourceStatus==`UPDATE_ROLLBACK_FAILED`].[Timestamp,LogicalResourceId,ResourceStatus,ResourceStatusReason]' \
  --output table
```

---

## Recovering from `UPDATE_ROLLBACK_FAILED`

After reproducing the bug, the stack is stuck. To clean up:

**Option A — Continue Update Rollback** (attempt service-side recovery):
```bash
aws cloudformation continue-update-rollback \
  --stack-name $STACK_NAME \
  --region $REGION
```
This may or may not succeed depending on the internal state of the ElastiCache resource.

**Option B — Delete the stack** (full teardown):
```bash
aws cloudformation delete-stack \
  --stack-name $STACK_NAME \
  --region $REGION

aws cloudformation wait stack-delete-complete \
  --stack-name $STACK_NAME \
  --region $REGION
```

> If the delete fails because the underlying ElastiCache resource is in a non-deletable state,
> you may need to delete the `ServerlessCache` resource manually via the ElastiCache console or
> CLI first, then mark it as `RETAIN` in the stack before deleting.

---

## Template Parameters

All three templates share the same parameters:

| Parameter | Default | Description |
|-----------|---------|-------------|
| `CacheName` | `ecache-repro` | `ServerlessCacheName` — must be consistent across all three deployments |
| `VpcCidr` | `10.100.0.0/16` | VPC CIDR block |
| `Subnet1Cidr` | `10.100.1.0/24` | First private subnet CIDR |
| `Subnet2Cidr` | `10.100.2.0/24` | Second private subnet CIDR |

To override parameters:
```bash
aws cloudformation deploy \
  --template-file template-v1.yaml \
  --stack-name $STACK_NAME \
  --region $REGION \
  --parameter-overrides CacheName=my-cache-repro VpcCidr=10.200.0.0/16 Subnet1Cidr=10.200.1.0/24 Subnet2Cidr=10.200.2.0/24
```

---

## What Each Template Changes

### template-v1.yaml — Baseline (CREATE) — matches customer's initial stack
```yaml
Engine: valkey
MajorEngineVersion: '9'          # present at creation
CacheUsageLimits:
  DataStorage:
    Minimum: '272'
    Unit: GB
# ECPUPerSecond: absent at creation
```

### template-v2.yaml — Step 2 UPDATE — adds MajorEngineVersion (intermittent failure)
```yaml
Engine: valkey
MajorEngineVersion: '9'          # <-- ADDED (was absent in v1)
CacheUsageLimits:
  DataStorage:                   # retained unchanged
    Minimum: '272'
    Unit: GB
# ECPUPerSecond: still absent
```

### template-v3.yaml — Step 3 UPDATE (bug trigger) — adds ECPUPerSecond
```yaml
Engine: valkey
MajorEngineVersion: '9'          # retained from v2
CacheUsageLimits:
  DataStorage:                   # retained unchanged
    Minimum: '272'
    Unit: GB
  ECPUPerSecond:                 # <-- ADDED (bug trigger)
    Minimum: '2000'
```

---

## Root Cause Hypotheses

See the full design document at `.kiro/specs/elasticache-serverless-update-failure/design.md`
for root cause analysis. Given the customer's exact config, the leading hypothesis is:

1. **ECPUPerSecond addition alongside existing DataStorage triggers Modify API rejection** —
   When a cache was created with `DataStorage` but no `ECPUPerSecond`, and an update attempts
   to add `ECPUPerSecond`, the ElastiCache Modify call may fail because the service requires
   both limits to be set together or not at all. This also explains why rollback fails: the
   rollback Modify call tries to remove `ECPUPerSecond`, which may be rejected if the resource
   is in a partially modified state.

2. **Version downgrade blocked during rollback** — After a partial `MajorEngineVersion`
   upgrade, the rollback Modify call tries to restore the previous state, which may be rejected
   by ElastiCache if version downgrades are disallowed.

**Workaround (user-actionable)**: Split the update into two separate stack deployments:
1. First deploy with `MajorEngineVersion: '9'` only and wait for `UPDATE_COMPLETE`.
2. Then deploy with `ECPUPerSecond` added in a separate update.

---

## Related Resources

- CloudFormation resource reference: [AWS::ElastiCache::ServerlessCache](https://docs.aws.amazon.com/AWSCloudFormation/latest/TemplateReference/aws-resource-elasticache-serverlesscache.html)
- Bugfix requirements: `.kiro/specs/elasticache-serverless-update-failure/bugfix.md`
- Bugfix design: `.kiro/specs/elasticache-serverless-update-failure/design.md`
