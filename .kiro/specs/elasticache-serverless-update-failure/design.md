# ElastiCache ServerlessCache Update/Rollback Failure — Bugfix Design

## Overview

This document formalizes the bug reproduction strategy for a confirmed failure pattern in
`AWS::ElastiCache::ServerlessCache` CloudFormation resource updates. Two distinct failure modes
are being reproduced:

1. **Intermittent update failure** — Adding `MajorEngineVersion: '9'` to an existing Valkey
   serverless cache intermittently fails with an "internal failure" during the UPDATE operation.
   Rollback succeeds, so the stack recovers to its previous state.

2. **Combined update + rollback failure** — Adding both `MajorEngineVersion: '9'` and
   `ECPUPerSecond: { Minimum: '2000' }` simultaneously triggers an internal failure AND a rollback
   failure, leaving the stack permanently stuck in `UPDATE_ROLLBACK_FAILED`.

The reproduction approach uses three versioned CloudFormation templates that a developer deploys
in sequence, deliberately triggering the failure states so the root cause can be observed and
confirmed.

**Engine Note**: `MajorEngineVersion: '9'` applies to **Valkey** (Valkey 9.0), not Redis OSS.
Redis OSS for ElastiCache Serverless tops out at 7.x. All templates use `Engine: valkey`.

---

## Glossary

- **Bug_Condition (C)**: The set of inputs (stack property states) that trigger the internal
  failure. Specifically: an existing `AWS::ElastiCache::ServerlessCache` resource where
  `MajorEngineVersion` and/or `ECPUPerSecond` were absent at creation, and the update attempts
  to introduce one or both simultaneously.
- **Property (P)**: The desired correct behavior — any update to a `ServerlessCache` resource
  that does not require replacement should either succeed (reaching `UPDATE_COMPLETE`) or fail
  and roll back cleanly (reaching `UPDATE_ROLLBACK_COMPLETE`). The stack MUST NOT reach
  `UPDATE_ROLLBACK_FAILED`.
- **Preservation**: Behaviors that must remain unaffected: initial CREATE success, no-op updates,
  successful-update state transitions, and retention of previously applied property values.
- **ModifyServerlessCache_original / F**: The current (unfixed) CloudFormation resource handler
  for `AWS::ElastiCache::ServerlessCache` Modify operations.
- **ModifyServerlessCache_fixed / F'**: The patched handler after the root cause is resolved.
- **ECPUPerSecond**: The `ElastiCacheProcessingUnitsPerSecond` sub-property of
  `CacheUsageLimits`, controlling the maximum/minimum ECPU throughput for a serverless cache.
- **MajorEngineVersion**: A top-level `AWS::ElastiCache::ServerlessCache` property (string)
  specifying the engine major version (e.g., `'7'`, `'8'`, `'9'` for Valkey).
- **UPDATE_ROLLBACK_FAILED**: A terminal CloudFormation stack state from which the stack cannot
  recover without manual intervention (`ContinueUpdateRollback` API call or stack deletion).
- **Template v1 / v2 / v3**: The three YAML CloudFormation templates stored under
  `infra/elasticache-serverless-update-failure/` representing each deployment step.

---

## Bug Details

### Bug Condition

The bug manifests when CloudFormation attempts to modify an `AWS::ElastiCache::ServerlessCache`
resource that was initially created **without** `MajorEngineVersion` or `ECPUPerSecond` (under
`CacheUsageLimits`), and the update introduces one or both of those properties. The ElastiCache
service handler either fails to process the Modify API call, fails to handle the response, or
fails during the rollback's corresponding Modify call to restore the original state.

**Formal Specification:**

```
FUNCTION isBugCondition(stackUpdate)
  INPUT: stackUpdate — describes the before/after property state of a ServerlessCache resource
  OUTPUT: boolean

  LET wasCreatedWithout_MajorEngineVersion =
        stackUpdate.previous.MajorEngineVersion IS NULL OR UNDEFINED

  LET wasCreatedWithout_ECPUPerSecond =
        stackUpdate.previous.CacheUsageLimits.ECPUPerSecond IS NULL OR UNDEFINED

  LET addingMajorEngineVersion =
        stackUpdate.desired.MajorEngineVersion IS NOT NULL
        AND stackUpdate.desired.MajorEngineVersion != stackUpdate.previous.MajorEngineVersion

  LET addingECPUPerSecond =
        stackUpdate.desired.CacheUsageLimits.ECPUPerSecond IS NOT NULL
        AND stackUpdate.previous.CacheUsageLimits.ECPUPerSecond IS NULL

  -- Intermittent failure condition (Step 2):
  LET isStep2BugCondition =
        wasCreatedWithout_MajorEngineVersion
        AND wasCreatedWithout_ECPUPerSecond
        AND addingMajorEngineVersion
        AND NOT addingECPUPerSecond

  -- Deterministic failure + rollback failure condition (Step 3):
  LET isStep3BugCondition =
        addingMajorEngineVersion
        AND addingECPUPerSecond

  RETURN isStep2BugCondition OR isStep3BugCondition
END FUNCTION
```

### Examples

- **Step 2 — intermittent failure**: Stack created with `Engine: valkey` and no
  `MajorEngineVersion`. Update adds `MajorEngineVersion: '9'`. Expected: `UPDATE_COMPLETE`.
  Actual (intermittently): CloudFormation status transitions to `UPDATE_FAILED` with reason
  "Internal failure", then rolls back to `UPDATE_ROLLBACK_COMPLETE`.

- **Step 3 — combined update, deterministic failure**: After Step 2 succeeds (stack now has
  `MajorEngineVersion: '9'`), update simultaneously adds `ECPUPerSecond: { Minimum: '2000' }`.
  Note: `MajorEngineVersion` is already `'9'` at this point — the diff may include it or not
  depending on template content. Expected: `UPDATE_COMPLETE`. Actual: `UPDATE_FAILED` with
  "Internal failure", followed by `UPDATE_ROLLBACK_FAILED` — the rollback itself fails, leaving
  the stack permanently stuck.

- **Edge case — no-op update**: An update to the stack that adds or changes only non-ElastiCache
  resources (e.g., a stack Tag or an unrelated resource) should succeed without triggering the
  bug.

- **Edge case — adding ECPUPerSecond without MajorEngineVersion change**: If only ECPUPerSecond
  is added on a stack that already had `MajorEngineVersion` set at creation, it is unknown
  whether this also triggers the failure. This should be noted for investigation but is outside
  the primary reproduction scope.

---

## Expected Behavior

### Preservation Requirements

**Unchanged Behaviors:**

- Initial CREATE of an `AWS::ElastiCache::ServerlessCache` with baseline properties (no
  `MajorEngineVersion`, no `ECPUPerSecond`) MUST continue to succeed.
- An update that changes only non-ElastiCache resources in the same stack MUST NOT affect the
  ServerlessCache resource.
- Once `MajorEngineVersion: '9'` is successfully applied (Step 2 succeeds), that value MUST be
  retained through subsequent stack operations.
- Mouse-click-equivalent interactions — i.e., direct ElastiCache API calls via Console or CLI
  that modify these same properties — are assumed to work correctly and are out of scope for
  CloudFormation template reproduction.

**Scope:**

All stack updates that do NOT introduce `MajorEngineVersion` or `ECPUPerSecond` as new
properties on a `ServerlessCache` that was created without them should be completely unaffected
by this fix. This includes:

- Stack updates that modify only Tags, Description, or SnapshotRetentionLimit.
- Stack updates adding entirely different AWS resource types to the same stack.
- Stack updates that re-declare an already-set `MajorEngineVersion` value without change.

**Note:** The expected correct behavior for buggy inputs is defined in the Correctness Properties
section (Property 1 and Property 3).

---

## Hypothesized Root Cause

Based on the bug description and the property structure of `AWS::ElastiCache::ServerlessCache`,
the most likely causes are:

1. **ElastiCache ModifyServerlessCache API parameter validation bug**: The ElastiCache service
   may reject a Modify call that introduces `MajorEngineVersion` alongside `ECPUPerSecond` on a
   resource that had neither at creation time. The validation may incorrectly treat the combined
   presence as an invalid state transition (e.g., attempting a major version upgrade concurrent
   with a capacity change).

2. **CFN resource handler does not handle partial Modify responses**: The CloudFormation
   resource handler for `AWS::ElastiCache::ServerlessCache` may not correctly parse or handle
   an error response from the ElastiCache Modify API when both properties are new. This could
   surface as a generic "internal failure" rather than a typed error.

3. **Rollback Modify call uses incorrect property state**: When CloudFormation attempts to roll
   back, it constructs a Modify call targeting the previous state (no `MajorEngineVersion`, no
   `ECPUPerSecond`). If the resource has partially transitioned to a new engine version during
   the failed forward update, the rollback Modify may fail because the ElastiCache service
   disallows downgrading `MajorEngineVersion` (version downgrades are generally not supported
   in ElastiCache).

4. **Stabilization polling error misclassification**: The resource handler may time out or
   receive an unexpected `MODIFYING` status from the ElastiCache API and classify it as a
   terminal failure rather than a retriable intermediate state, causing both the update and the
   rollback to fail at the polling/stabilization layer.

5. **Ordering constraint violation**: The ElastiCache API may require `MajorEngineVersion` to
   be set before `ECPUPerSecond` can be set to a non-default value. CloudFormation sends them
   as a single Modify call with both fields, which the service may reject.

---

## Correctness Properties

Property 1: Bug Condition — MajorEngineVersion-Only Update Must Succeed or Roll Back Cleanly

_For any_ stack update where the bug condition holds because only `MajorEngineVersion: '9'` is
being added (isStep2BugCondition returns true), the CloudFormation stack MUST eventually reach
either `UPDATE_COMPLETE` (if the update succeeds) or `UPDATE_ROLLBACK_COMPLETE` (if the update
fails and rollback is triggered). The stack MUST NOT reach `UPDATE_ROLLBACK_FAILED`.

**Validates: Requirements 2.1, 2.2**

Property 2: Bug Condition — Combined Update Must Not Leave Stack in UPDATE_ROLLBACK_FAILED

_For any_ stack update where the bug condition holds because both `MajorEngineVersion: '9'` and
`ECPUPerSecond: { Minimum: '2000' }` are being introduced simultaneously (isStep3BugCondition
returns true), the CloudFormation stack MUST eventually reach `UPDATE_COMPLETE` (correct fix) or
`UPDATE_ROLLBACK_COMPLETE` (graceful failure). The stack MUST NOT reach `UPDATE_ROLLBACK_FAILED`.

**Validates: Requirements 2.3, 2.4**

Property 3: Preservation — Initial CREATE Must Succeed

_For any_ deployment of `template-v1.yaml` with valid VPC/subnet/security-group configuration,
the CloudFormation stack MUST reach `CREATE_COMPLETE` status. This property must hold before and
after any fix is applied to the update/rollback handler.

**Validates: Requirements 3.1**

Property 4: Preservation — Successful Updates Must Reach UPDATE_COMPLETE

_For any_ input where the bug condition does NOT hold (isBugCondition returns false) and a stack
update is submitted, the fixed handler SHALL produce the same outcome as the original handler,
reaching `UPDATE_COMPLETE` without regression.

**Validates: Requirements 3.2, 3.3**

---

## Fix Implementation

### Changes Required

Assuming Root Cause hypothesis #3 (rollback Modify call fails because major version cannot be
downgraded) combined with #1 (combined Modify rejected by ElastiCache service):

**File**: CloudFormation resource handler for `AWS::ElastiCache::ServerlessCache`
(internal AWS service — not directly modifiable by the user; this section documents what the fix
should target for the service team)

**Function**: `ModifyServerlessCache` handler / stabilization loop

**Specific Changes**:

1. **Separate Modify operations for MajorEngineVersion and CacheUsageLimits**: When both
   `MajorEngineVersion` and `ECPUPerSecond` are being introduced simultaneously and the
   resource did not previously have either, the handler should sequence the Modify calls —
   first apply `MajorEngineVersion`, wait for stabilization, then apply `ECPUPerSecond`.

2. **Version downgrade guard in rollback path**: Before issuing the rollback Modify call, the
   handler should check whether the resource has already begun an engine version upgrade. If so,
   it must not attempt to set `MajorEngineVersion` back to `null`/previous value; instead it
   should allow the resource to remain at the new engine version and only roll back the
   `ECPUPerSecond` component.

3. **Typed error handling for ElastiCache Modify rejections**: The handler should map
   ElastiCache `InvalidParameterCombination` or similar API errors to a
   `HandlerErrorCode.InvalidRequest` rather than `HandlerErrorCode.InternalFailure`, enabling
   clearer diagnosis and preventing the generic "internal failure" masking.

4. **Stabilization timeout increase**: If the failure occurs because the handler does not wait
   long enough for the Valkey 9.0 upgrade to complete (can take several minutes), increase the
   stabilization polling timeout for `MajorEngineVersion` changes.

5. **Template-side workaround (user-actionable)**: Users can avoid the combined update failure
   by splitting Step 2 and Step 3 into two sequential stack updates — first add
   `MajorEngineVersion: '9'` and wait for `UPDATE_COMPLETE`, then add
   `ECPUPerSecond: { Minimum: '2000' }` in a separate update.

---

## Testing Strategy

### Validation Approach

The testing strategy follows a two-phase approach: first, deploy the templates in sequence to
surface counterexamples that demonstrate the bug on the live CloudFormation service; then, after
a fix is applied, re-run the same deployment sequence to verify the fix works and that baseline
behavior is preserved.

### Exploratory Bug Condition Checking

**Goal**: Surface counterexamples that demonstrate both failure modes BEFORE any fix is applied.
Confirm or refute the root cause hypotheses. If the repro does not consistently reproduce the
bug, refine the templates or test parameters.

**Test Plan**: Deploy `template-v1.yaml`, then `template-v2.yaml`, then `template-v3.yaml` in
sequence. Observe CloudFormation stack events and final stack status after each deploy. Record
the exact error message from `UPDATE_FAILED` and `UPDATE_ROLLBACK_FAILED` events.

**Test Cases**:

1. **Step 1 — Baseline CREATE**: Deploy `template-v1.yaml`. Assert stack reaches
   `CREATE_COMPLETE`. (Must succeed to proceed.)

2. **Step 2 — MajorEngineVersion update (intermittent)**: Deploy `template-v2.yaml`. Observe
   whether stack reaches `UPDATE_COMPLETE` or `UPDATE_FAILED` → `UPDATE_ROLLBACK_COMPLETE`.
   Retry if it fails (intermittent). Record number of attempts required.

3. **Step 3 — Combined update (deterministic failure)**: After Step 2 has succeeded, deploy
   `template-v3.yaml`. Assert stack reaches `UPDATE_FAILED` (will fail on unfixed service) and
   then `UPDATE_ROLLBACK_FAILED` (will fail on unfixed service).

4. **Edge case — no-op re-apply**: After Step 3 leaves the stack in `UPDATE_ROLLBACK_FAILED`,
   attempt `ContinueUpdateRollback`. Observe whether this resolves the stuck state. This may
   fail on unfixed service.

**Expected Counterexamples**:

- Stack does not reach `UPDATE_COMPLETE` after `template-v3.yaml` deploy; remains in
  `UPDATE_ROLLBACK_FAILED`.
- Possible causes: Modify call rejected for combined properties; version downgrade blocked
  during rollback; stabilization timeout misclassified as failure.

### Fix Checking

**Goal**: After a fix is applied, verify that for all inputs where the bug condition holds, the
fixed handler produces the expected behavior (UPDATE_COMPLETE or clean rollback).

**Pseudocode:**

```
FOR ALL stackUpdate WHERE isBugCondition(stackUpdate) DO
  deploy(stackUpdate.template)
  finalStatus := pollUntilTerminal(stackUpdate.stackName)
  ASSERT finalStatus IN ['UPDATE_COMPLETE', 'UPDATE_ROLLBACK_COMPLETE']
  ASSERT finalStatus != 'UPDATE_ROLLBACK_FAILED'
END FOR
```

### Preservation Checking

**Goal**: Verify that for all inputs where the bug condition does NOT hold, the fixed handler
produces the same result as the original handler — no regression in baseline create, no-op
update, or successful update behavior.

**Pseudocode:**

```
FOR ALL stackUpdate WHERE NOT isBugCondition(stackUpdate) DO
  result_original := observe(originalHandler, stackUpdate)
  result_fixed    := observe(fixedHandler, stackUpdate)
  ASSERT result_original = result_fixed
END FOR
```

**Testing Approach**: Property-based testing is recommended for preservation checking because:
- It generates many stack configurations automatically (different region, VPC CIDR, cache name)
- It catches environment-specific edge cases that manual single-environment tests miss
- It provides strong guarantees that the fix only affects the targeted failure modes

**Test Plan**: Deploy `template-v1.yaml` in a clean environment (unfixed service), verify
`CREATE_COMPLETE`. Then re-deploy the same template against the fixed service handler and verify
the same outcome.

**Test Cases**:

1. **CREATE Preservation**: Verify `template-v1.yaml` reaches `CREATE_COMPLETE` on the fixed
   handler, same as the unfixed handler.
2. **No-op Update Preservation**: Re-deploy `template-v1.yaml` (identical stack) and verify
   `UPDATE_COMPLETE` is reached without touching the ServerlessCache resource.
3. **MajorEngineVersion Retention**: After Step 2 succeeds (fixed), verify that `template-v3.yaml`
   does not attempt to re-apply `MajorEngineVersion: '9'` as a new change (it was already set).

### Unit Tests

- Test CloudFormation stack status polling logic: assert `UPDATE_ROLLBACK_FAILED` is correctly
  detected and reported.
- Test the step-by-step deployment script exits cleanly when Step 2 fails intermittently and
  retries automatically.
- Test that deploying `template-v3.yaml` against a stack still in `UPDATE_ROLLBACK_FAILED`
  (instead of attempting Step 3 from `UPDATE_COMPLETE`) produces an appropriate error.

### Property-Based Tests

- Generate random valid VPC CIDR blocks and subnet configurations; for each configuration,
  assert `template-v1.yaml` CREATE succeeds (no configuration-specific CREATE failures).
- Generate random `ServerlessCacheName` values (valid CFN name format) and verify that the bug
  condition check (`isBugCondition`) correctly classifies each step's property diff as buggy or
  non-buggy.
- For any simulated stack update where `ECPUPerSecond.Minimum` is already set at creation
  (not matching the bug condition), assert that the update to add `MajorEngineVersion` does not
  trigger the Step 3 failure path.

### Integration Tests

- Full three-step deployment sequence (`v1` → `v2` → `v3`) in a dedicated test AWS account,
  with assertions on stack status at each step.
- Verify CloudFormation stack events contain the expected error message pattern ("Internal
  failure" or "InvalidParameterCombination") at the `UPDATE_FAILED` event.
- After fix is applied: verify the full three-step sequence completes with all stacks in
  `UPDATE_COMPLETE` (no `UPDATE_ROLLBACK_FAILED`).
- Verify stack deletion after `UPDATE_ROLLBACK_FAILED` is possible (cleanup test), or that
  `ContinueUpdateRollback` resolves the stuck state.

---

## Infrastructure Templates

### Template Structure

Three versioned CloudFormation YAML templates are stored under
`infra/elasticache-serverless-update-failure/`:

| Template | Description | Key Change |
|---|---|---|
| `template-v1.yaml` | Baseline CREATE | No `MajorEngineVersion`, no `ECPUPerSecond` |
| `template-v2.yaml` | Step 2 UPDATE | Adds `MajorEngineVersion: '7'` (or `'9'`) only |
| `template-v3.yaml` | Step 3 UPDATE (bug trigger) | Adds `ECPUPerSecond` and sets/retains `MajorEngineVersion: '9'` |

> **MajorEngineVersion note for template-v2**: The initial `MajorEngineVersion` in `template-v2`
> may be `'7'` (to establish a baseline version on record) or `'9'` directly, depending on what
> the reporter used. Use `'9'` to match the bug report exactly. If `'9'` is not yet available in
> your region, use `'8'` as an intermediate step.

### Minimum Required Resources

Each template includes:

- **VPC** (`AWS::EC2::VPC`) — required for subnet and security group scope
- **Two private subnets** (`AWS::EC2::Subnet`) in different AZs — ElastiCache Serverless
  requires at least 2 subnets across 2 AZs
- **Security Group** (`AWS::EC2::SecurityGroup`) — attached to the ServerlessCache
- **`AWS::ElastiCache::ServerlessCache`** — the resource under test

### Deployment Steps (README Summary)

See `infra/elasticache-serverless-update-failure/README.md` for full step-by-step instructions.
High-level flow:

```
Step 1: aws cloudformation deploy --template-file template-v1.yaml --stack-name ecache-repro
Step 2: aws cloudformation deploy --template-file template-v2.yaml --stack-name ecache-repro
        (retry if UPDATE_FAILED → UPDATE_ROLLBACK_COMPLETE; this step is intermittent)
Step 3: aws cloudformation deploy --template-file template-v3.yaml --stack-name ecache-repro
        (expect UPDATE_FAILED → UPDATE_ROLLBACK_FAILED — this is the bug being replicated)
```
