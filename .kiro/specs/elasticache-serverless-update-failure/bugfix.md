# Bugfix Requirements Document

## Introduction

This document captures the bug scenario observed with `AWS::ElastiCache::ServerlessCache` CloudFormation resource updates. After a successful initial stack creation, certain property updates (specifically `MajorEngineVersion` and `ECPUPerSecond`) intermittently fail with an "internal failure" error in CloudFormation. More critically, when both properties are updated together, the subsequent rollback also fails — leaving the stack permanently stuck in `UPDATE_ROLLBACK_FAILED` state. The goal is to replicate this scenario end-to-end using CloudFormation templates so the team can observe, reproduce, and investigate the root cause of the internal failure and the rollback failure behavior.

## Bug Analysis

### Current Behavior (Defect)

1.1 WHEN a CloudFormation stack containing `AWS::ElastiCache::ServerlessCache` is updated to add `MajorEngineVersion: '9'` THEN the system intermittently fails with an "internal failure" error during the UPDATE operation

1.2 WHEN the update to add `MajorEngineVersion: '9'` fails with an internal failure THEN the system performs a rollback that succeeds (stack returns to the previous stable state)

1.3 WHEN a CloudFormation stack containing `AWS::ElastiCache::ServerlessCache` is updated to add both `ECPUPerSecond: { Minimum: '2000' }` AND `MajorEngineVersion: '9'` simultaneously THEN the system fails with an "internal failure" error during the UPDATE operation

1.4 WHEN the combined update of `ECPUPerSecond` and `MajorEngineVersion` fails with an internal failure THEN the system also fails during rollback, leaving the stack in `UPDATE_ROLLBACK_FAILED` state

### Expected Behavior (Correct)

2.1 WHEN a CloudFormation stack containing `AWS::ElastiCache::ServerlessCache` is updated to add `MajorEngineVersion: '9'` THEN the system SHALL complete the UPDATE operation successfully without internal failure

2.2 WHEN an `AWS::ElastiCache::ServerlessCache` update fails for any reason THEN the system SHALL successfully roll back the stack to its previous stable state, never leaving the stack in `UPDATE_ROLLBACK_FAILED`

2.3 WHEN a CloudFormation stack containing `AWS::ElastiCache::ServerlessCache` is updated to add both `ECPUPerSecond: { Minimum: '2000' }` AND `MajorEngineVersion: '9'` simultaneously THEN the system SHALL complete the UPDATE operation successfully without internal failure

2.4 WHEN the combined update of `ECPUPerSecond` and `MajorEngineVersion` fails for any reason THEN the system SHALL successfully roll back to the previous stable stack state

### Unchanged Behavior (Regression Prevention)

3.1 WHEN an `AWS::ElastiCache::ServerlessCache` resource is created for the first time with valid baseline properties THEN the system SHALL CONTINUE TO complete the CREATE operation successfully

3.2 WHEN an `AWS::ElastiCache::ServerlessCache` stack is updated with properties that were already set during create (no actual change to the ElastiCache resource) THEN the system SHALL CONTINUE TO complete the update without error

3.3 WHEN an `AWS::ElastiCache::ServerlessCache` update succeeds THEN the system SHALL CONTINUE TO transition the stack to `UPDATE_COMPLETE` state

3.4 WHEN a CloudFormation stack update fails and rollback is triggered THEN the system SHALL CONTINUE TO restore all other resources in the stack to their previous state before the failed update

3.5 WHEN `MajorEngineVersion: '9'` is successfully applied to an `AWS::ElastiCache::ServerlessCache` resource in a prior update THEN the system SHALL CONTINUE TO retain that value through subsequent stack operations
