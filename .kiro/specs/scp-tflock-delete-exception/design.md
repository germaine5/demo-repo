# Design Document: SCP tflock Delete Exception

## Overview

This design describes the modification of an existing AWS Service Control Policy (SCP) to add a targeted exception that allows the `ADO-OrgHub-Role` IAM role to delete Terraform state lock files (`.tflock`) from two designated S3 buckets. The existing `DenyAllActionsForIAMUsersWithoutMFA` statement is preserved without modification.

The primary output artifact of this feature is the modified SCP JSON document. There is no application code to deploy — the deliverable is a policy document applied to the AWS Organizations root via the AWS console or CLI.

**Key research finding:** The requirements originally specified a `Deny` + `NotPrincipal` pattern. Research against [AWS documentation](https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_policies_elements_notprincipal.html) confirms that `NotPrincipal` is **not supported in Service Control Policies**. The correct AWS-supported equivalent is a `Deny` statement with a `Condition` using `ArnNotEquals` on the `aws:PrincipalArn` context key. This achieves identical logical behavior and is the pattern recommended by AWS for SCP role exceptions.

---

## Architecture

The SCP is a JSON policy document attached at the AWS Organizations root, meaning it applies as a guardrail to all member accounts. SCPs do not grant permissions — they constrain the maximum permissions available. An explicit `Deny` in an SCP overrides any `Allow` in an IAM policy within a member account.

The modified SCP uses two statements:

```
┌───────────────────────────────────────────────────────────────┐
│  SCP attached at Organizations Root                           │
│                                                               │
│  Statement 1: DenyAllActionsForIAMUsersWithoutMFA             │
│  ├── Effect: Deny                                             │
│  ├── Action: *                                                │
│  ├── Resource: *                                              │
│  └── Condition: PrincipalType=User AND MFA=false              │
│                                                               │
│  Statement 2: DenyS3DeleteObjectOnTfLockExceptADORole         │
│  ├── Effect: Deny                                             │
│  ├── Action: s3:DeleteObject                                  │
│  ├── Resource: [DR bucket /*.tflock, Primary bucket /*.tflock] │
│  └── Condition: aws:PrincipalArn ≠ ADO-OrgHub-Role ARN        │
└───────────────────────────────────────────────────────────────┘
```

**Policy evaluation logic for Statement 2:**

- If the calling principal's `aws:PrincipalArn` equals `arn:aws:iam::xxxxxxxxxxxx:role/ADO-OrgHub-Role`, the condition `ArnNotEquals` evaluates to `false`, so the `Deny` does **not** fire — the action is permitted subject to IAM identity policies.
- For any other principal, `ArnNotEquals` evaluates to `true`, the `Deny` fires, and the action is blocked regardless of IAM identity policies.

**Why `aws:PrincipalArn` covers both the role ARN and assumed-role sessions:**

The `aws:PrincipalArn` context key always resolves to the IAM role ARN (`arn:aws:iam::xxxxxxxxxxxx:role/ADO-OrgHub-Role`) for any session that assumed that role — regardless of the session name suffix. This means a single condition on the role ARN covers all assumed-role sessions derived from it. The assumed-role session ARN (`arn:aws:sts::xxxxxxxxxxxx:assumed-role/ADO-OrgHub-Role/*`) does **not** need to appear in `NotPrincipal` (which is unsupported) and does **not** need to appear in the condition, because `aws:PrincipalArn` already normalizes to the role ARN. This is confirmed by the [IAM condition key documentation](https://repost.aws/questions/QUD7RI2p5OQ1uCtj6d-Vn_pQ/iam-policy-condition-with-role-session-name): "the role session principal is granted the permissions based on the ARN of the role that was assumed, and not the ARN of the resulting session."

---

## Components and Interfaces

There is a single component: the SCP JSON document.

| Component | Description |
|---|---|
| SCP JSON document | The policy artifact stored in AWS Organizations |
| Statement 1 | Preserves the existing MFA-enforcement control for IAM Users |
| Statement 2 | New exception statement scoped to `s3:DeleteObject` on `*.tflock` objects in the two state buckets |

**Deployment interface:**

The SCP is managed via:
- AWS Management Console → AWS Organizations → Policies → Service Control Policies
- AWS CLI: `aws organizations update-policy --policy-id <id> --content file://scp.json`

---

## Data Models

The SCP is a JSON document conforming to the [AWS IAM policy language](https://docs.aws.amazon.com/organizations/latest/userguide/orgs_manage_policies_scps_syntax.html) schema.

### Final Modified SCP JSON

This is the primary output artifact of this feature:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "DenyAllActionsForIAMUsersWithoutMFA",
      "Effect": "Deny",
      "Action": "*",
      "Resource": "*",
      "Condition": {
        "BoolIfExists": {
          "aws:MultiFactorAuthPresent": "false"
        },
        "StringEquals": {
          "aws:PrincipalType": "User"
        }
      }
    },
    {
      "Sid": "DenyS3DeleteObjectOnTfLockExceptADORole",
      "Effect": "Deny",
      "Action": "s3:DeleteObject",
      "Resource": [
        "arn:aws:s3:::amzn-rs-dr-s3-statefile-bucket/*.tflock",
        "arn:aws:s3:::amzn-rs-s3-statefile-bucket/*.tflock"
      ],
      "Condition": {
        "ArnNotEquals": {
          "aws:PrincipalArn": "arn:aws:iam::xxxxxxxxxxxx:role/ADO-OrgHub-Role"
        }
      }
    }
  ]
}
```

### Statement Field Descriptions

**Statement 1 — DenyAllActionsForIAMUsersWithoutMFA (unchanged):**

| Field | Value | Notes |
|---|---|---|
| `Sid` | `DenyAllActionsForIAMUsersWithoutMFA` | Preserved exactly |
| `Effect` | `Deny` | |
| `Action` | `*` | All AWS actions |
| `Resource` | `*` | All resources |
| `Condition.BoolIfExists.aws:MultiFactorAuthPresent` | `"false"` | Fires when MFA is absent or false |
| `Condition.StringEquals.aws:PrincipalType` | `"User"` | Applies only to IAM Users |

**Statement 2 — DenyS3DeleteObjectOnTfLockExceptADORole (new):**

| Field | Value | Notes |
|---|---|---|
| `Sid` | `DenyS3DeleteObjectOnTfLockExceptADORole` | Descriptive; uniquely identifies the statement |
| `Effect` | `Deny` | SCP-supported effect; combined with ArnNotEquals acts as an allow exception |
| `Action` | `s3:DeleteObject` | Scoped to this action only |
| `Resource` | `["arn:aws:s3:::amzn-rs-dr-s3-statefile-bucket/*.tflock", "arn:aws:s3:::amzn-rs-s3-statefile-bucket/*.tflock"]` | Scoped to *.tflock objects in the two buckets only |
| `Condition.ArnNotEquals.aws:PrincipalArn` | `"arn:aws:iam::xxxxxxxxxxxx:role/ADO-OrgHub-Role"` | Deny fires for everyone except this role |

### Design Decision: `ArnNotEquals` vs `ArnNotLike`

`ArnNotEquals` is used (exact match) rather than `ArnNotLike` (wildcard match) because:
- The role ARN is fixed and known — no wildcard matching is needed.
- `ArnNotEquals` is more restrictive and less prone to unintended matches.
- `ArnNotLike` would only be appropriate if you needed to exempt a pattern of role ARNs (e.g., `arn:aws:iam::*:role/ADO-*`).

### Design Decision: Single Condition Value vs Array

The condition uses a single string value rather than an array `["arn:...", "arn:sts:..."]`. This is intentional because `aws:PrincipalArn` already resolves to the IAM role ARN for all assumed-role sessions of `ADO-OrgHub-Role` — the STS session ARN is not the value populated in `aws:PrincipalArn`. Including the STS ARN in an `ArnNotEquals` condition would be incorrect (it would never match, making the condition always evaluate to true and always deny).

---

## Correctness Properties

This feature is an Infrastructure as Code / JSON policy document artifact. All acceptance criteria map to structural properties of a specific JSON document rather than to universally quantified behaviors across a varying input space. Property-based testing is not appropriate here:

- There is no code function with inputs and outputs to test.
- The "correctness" is entirely determined by the structure and values of a fixed JSON document.
- Running 100 iterations over generated inputs would not reveal additional bugs beyond a single structural inspection.

Instead, correctness is verified through **example-based structural tests** that parse the JSON document and assert its content. These are documented in the Testing Strategy section below.

---

## Error Handling

| Scenario | Behavior |
|---|---|
| SCP JSON is malformed | AWS Organizations will reject the `UpdatePolicy` API call with a `MalformedPolicyDocumentException`. The existing policy remains unchanged. |
| SCP exceeds the 5,120-character limit | AWS Organizations will reject with a `PolicyTooLargeException`. The new statement adds approximately 350 characters; the total is well within the limit for a two-statement SCP. |
| `ArnNotEquals` condition key is misspelled | AWS Organizations policy validation will surface this as a validation error. |
| `aws:PrincipalArn` context key is unavailable at eval time | This key is always populated for IAM role sessions. For service-linked roles or anonymous access, the condition evaluates to `true` (deny fires), which is the safe/restrictive default. |
| Applying to the wrong OU instead of root | The exception would not apply to accounts in OUs outside the attachment scope. The design specifies attachment at the Organizations root. |

---

## Testing Strategy

This feature is a JSON policy document, not application code. PBT is not applicable (see Correctness Properties section). The testing strategy uses example-based structural validation and an optional smoke test.

### Unit Tests (Structural JSON Validation)

These tests parse the output SCP JSON and assert structural properties. They can be implemented as a simple Python/shell test or as part of a CI lint step.

**Test 1 — Valid JSON and correct schema version**
- Parse the document; assert no JSON parse errors.
- Assert `policy["Version"] == "2012-10-17"`.

**Test 2 — Exactly two statements**
- Assert `len(policy["Statement"]) == 2`.

**Test 3 — MFA Deny statement is preserved**
- Find the statement with `Sid == "DenyAllActionsForIAMUsersWithoutMFA"`.
- Assert `Effect == "Deny"`, `Action == "*"`, `Resource == "*"`.
- Assert `Condition` contains `BoolIfExists.aws:MultiFactorAuthPresent == "false"` and `StringEquals.aws:PrincipalType == "User"`.

**Test 4 — Exception statement has correct Effect and Action**
- Find the statement with `Sid == "DenyS3DeleteObjectOnTfLockExceptADORole"`.
- Assert `Effect == "Deny"`.
- Assert `Action == "s3:DeleteObject"` (not a wildcard).

**Test 5 — Exception statement Resource is exactly the two *.tflock ARNs**
- Assert `Resource` contains exactly two elements.
- Assert `"arn:aws:s3:::amzn-rs-dr-s3-statefile-bucket/*.tflock"` is in `Resource`.
- Assert `"arn:aws:s3:::amzn-rs-s3-statefile-bucket/*.tflock"` is in `Resource`.
- Assert no other resources are present.

**Test 6 — Exception statement condition uses ArnNotEquals on aws:PrincipalArn**
- Assert `Condition` contains `ArnNotEquals.aws:PrincipalArn == "arn:aws:iam::xxxxxxxxxxxx:role/ADO-OrgHub-Role"`.
- Assert no other condition operators are present in this statement.

**Test 7 — No wildcard in exception statement Action or Resource**
- Assert the exception statement's `Action` does not contain `*`.
- Assert none of the `Resource` values in the exception statement end in `/*` without the `.tflock` suffix.

### Smoke Test (Optional — Requires AWS Access)

**Test 8 — AWS Policy Validation**
- Use `aws organizations validate-policy --policy-type SERVICE_CONTROL_POLICY --content file://scp.json` (or IAM Access Analyzer's `ValidatePolicy` API) to confirm AWS accepts the document with no validation findings.
- This test requires AWS credentials with `organizations:ValidatePolicy` or `access-analyzer:ValidatePolicy` permission.
- Run this test before applying the policy to any OU or root.

### Integration Test (Post-Deploy Verification)

After deploying the modified SCP to the Organizations root:

1. Use the IAM Policy Simulator or a controlled `aws s3api delete-object` call from an assumed session of `ADO-OrgHub-Role` against one of the `.tflock` URIs to confirm the action is not blocked by the SCP.
2. Confirm that an equivalent call from a different role (e.g., a test role without the exception) is blocked.
3. Confirm that a call from `ADO-OrgHub-Role` targeting a non-`.tflock` object is still subject to normal policy evaluation (no broader exception was introduced).
