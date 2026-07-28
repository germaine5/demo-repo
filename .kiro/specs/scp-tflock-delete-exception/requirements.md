# Requirements Document

## Introduction

This feature modifies an existing AWS Service Control Policy (SCP) to add a targeted exception that allows a specific IAM role to delete Terraform state lock files (`.tflock`) from two designated S3 buckets. The existing SCP denies all AWS actions to IAM Users who have not authenticated with MFA. The exception must not weaken that existing control — it must only apply to the named IAM role, the specified S3 buckets, and exclusively to `.tflock`-keyed objects.

## Glossary

- **SCP**: Service Control Policy — an AWS Organizations policy that sets permission guardrails for member accounts.
- **ADO-OrgHub-Role**: The IAM role `arn:aws:iam::xxxxxxxxxxxx:role/ADO-OrgHub-Role` that runs Azure DevOps pipeline automation and requires the ability to remove stale Terraform lock files.
- **Statefile_Bucket_DR**: The S3 bucket `amzn-rs-dr-s3-statefile-bucket` used as the disaster-recovery Terraform state backend.
- **Statefile_Bucket_Primary**: The S3 bucket `amzn-rs-s3-statefile-bucket` used as the primary Terraform state backend.
- **tflock_File**: An S3 object whose key matches the pattern `*.tflock`, created by Terraform to indicate a state lock is in progress.
- **MFA_Deny_Statement**: The existing SCP statement `DenyAllActionsForIAMUsersWithoutMFA` that denies all actions to IAM Users when `aws:MultiFactorAuthPresent` is false or absent.

## Requirements

### Requirement 1: Allow ADO-OrgHub-Role to Delete tflock Files

**User Story:** As a DevOps engineer, I want the ADO-OrgHub-Role to be able to delete `.tflock` files from the Terraform state S3 buckets, so that automated pipelines can clear stale Terraform state locks without being blocked by the SCP.

#### Acceptance Criteria

1. WHEN `arn:aws:iam::xxxxxxxxxxxx:role/ADO-OrgHub-Role` calls `s3:DeleteObject` on an object whose key matches `*.tflock` in `amzn-rs-dr-s3-statefile-bucket`, THE SCP SHALL permit the action.
2. WHEN `arn:aws:iam::xxxxxxxxxxxx:role/ADO-OrgHub-Role` calls `s3:DeleteObject` on an object whose key matches `*.tflock` in `amzn-rs-s3-statefile-bucket`, THE SCP SHALL permit the action.
3. WHEN any principal other than `arn:aws:iam::xxxxxxxxxxxx:role/ADO-OrgHub-Role` calls `s3:DeleteObject` on a `*.tflock` object in either bucket, THE SCP SHALL apply the normal policy evaluation (no additional exception is granted).
4. WHEN `arn:aws:iam::xxxxxxxxxxxx:role/ADO-OrgHub-Role` calls `s3:DeleteObject` on an object whose key does NOT match `*.tflock` in either bucket, THE SCP SHALL apply the normal policy evaluation (the exception does not extend to other object types).
5. WHEN `arn:aws:iam::xxxxxxxxxxxx:role/ADO-OrgHub-Role` calls any AWS action other than `s3:DeleteObject`, THE SCP SHALL apply the normal policy evaluation (the exception is scoped to `s3:DeleteObject` only).

### Requirement 2: Preserve the Existing MFA Deny Statement

**User Story:** As a security engineer, I want the existing MFA-enforcement control to remain fully intact, so that IAM Users without MFA continue to be denied all actions regardless of the new exception.

#### Acceptance Criteria

1. THE SCP SHALL retain the `DenyAllActionsForIAMUsersWithoutMFA` statement without modification.
2. WHILE `aws:PrincipalType` equals `User` and `aws:MultiFactorAuthPresent` is `false` or absent, THE SCP SHALL deny all actions on all resources.
3. WHEN the ADO-OrgHub-Role exception statement is evaluated, THE SCP SHALL apply it only to `aws:PrincipalType` of `AssumedRole`, ensuring the MFA_Deny_Statement logic for IAM Users is not affected.

### Requirement 3: Scope the Exception to the Two Designated Buckets

**User Story:** As a security engineer, I want the deletion exception to be restricted to only the two named Terraform state buckets, so that the ADO-OrgHub-Role cannot use this exception to delete objects from any other S3 bucket in the organization.

#### Acceptance Criteria

1. THE SCP exception statement SHALL restrict the `Resource` field to the ARNs of Statefile_Bucket_DR and Statefile_Bucket_Primary objects matching `*.tflock`, specifically:
   - `arn:aws:s3:::amzn-rs-dr-s3-statefile-bucket/*.tflock`
   - `arn:aws:s3:::amzn-rs-s3-statefile-bucket/*.tflock`
2. IF `arn:aws:iam::xxxxxxxxxxxx:role/ADO-OrgHub-Role` calls `s3:DeleteObject` on any S3 bucket ARN not listed in the Resource field, THEN THE SCP SHALL NOT grant an exception via this statement.

### Requirement 4: Implement the Exception as an Explicit SCP Allow via Deny-with-NotPrincipal Pattern

**User Story:** As a cloud platform engineer, I want the SCP exception implemented using AWS-recommended SCP patterns, so that the policy behaves predictably and is auditable.

#### Acceptance Criteria

1. THE SCP SHALL implement the exception using a `Deny` statement with a `NotPrincipal` condition targeting `arn:aws:iam::xxxxxxxxxxxx:role/ADO-OrgHub-Role`, which is the standard AWS SCP pattern for role-specific exceptions.
2. THE modified SCP SHALL remain a valid JSON document conforming to the AWS IAM policy language schema (Version `2012-10-17`).
3. THE modified SCP SHALL contain exactly two statements: the existing `DenyAllActionsForIAMUsersWithoutMFA` statement and the new exception statement.
4. WHEN the modified SCP JSON is evaluated by AWS Organizations, THE SCP SHALL produce no validation errors.
