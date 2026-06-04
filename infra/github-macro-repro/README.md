# GitHubInclude CloudFormation Macro

A custom CloudFormation macro that fetches a YAML snippet from a GitHub
repository and injects it into a template at change set creation time.
This is the equivalent of `AWS::Include` but sourced from GitHub instead of S3.

## How it works

```
Developer runs create-change-set
        ↓
CloudFormation sees Transform: GitHubInclude
        ↓
Calls GitHubInclude Lambda with the template fragment
        ↓
Lambda finds Fn::Transform / GitHubInclude nodes
        ↓
Lambda calls GitHub Contents API to fetch the YAML file
        ↓
Lambda parses YAML and replaces the Fn::Transform node
        ↓
Lambda returns the modified template to CloudFormation
        ↓
CloudFormation deploys the assembled template
```

## Files

```
infra/github-macro-repro/
├── 1-macro-stack.yaml          ← Deploy first: registers the macro
├── 2-consumer-stack.yaml       ← Deploy second: uses the macro
├── github-snippets/
│   └── s3-logging-bucket.yaml  ← Push this to your GitHub repo
└── README.md
```

## Setup and Deployment

### Prerequisites
- AWS CLI configured
- A GitHub account with a repository
- A GitHub Personal Access Token (PAT) with `repo` scope
  - For **public repos**: token is optional
  - For **private repos**: token is required
  - Create one at: https://github.com/settings/tokens

### Step 1 — Push the snippet to your GitHub repo

Create a folder called `snippets` in your GitHub repo and push the snippet file:

```bash
# 

mkdir snippets
cp infra/github-macro-repro/github-snippets/s3-logging-bucket.yaml snippets/
git add snippets/s3-logging-bucket.yaml
git commit -m "Add s3-logging-bucket snippet for CFN macro"
git push
```

### Step 2 — Deploy the macro stack

```bash
export AWS_REGION="us-east-1"
export GITHUB_TOKEN="ghp_xxxxxxxxxxxx"  # your PAT

aws cloudformation deploy \
  --stack-name github-include-macro \
  --template-file infra/github-macro-repro/1-macro-stack.yaml \
  --parameter-overrides GitHubToken=$GITHUB_TOKEN \
  --capabilities CAPABILITY_NAMED_IAM \
  --region $AWS_REGION
```

Wait for completion. This registers the `GitHubInclude` macro in your account.

### Step 3 — Deploy the consumer stack

```bash
aws cloudformation deploy \
  --stack-name github-include-consumer \
  --template-file infra/github-macro-repro/2-consumer-stack.yaml \
  --parameter-overrides \
    GitHubOwner=<your-github-username-or-org> \
    GitHubRepo=<your-repo-name> \
    GitHubRef=main \
  --capabilities CAPABILITY_AUTO_EXPAND \
  --region $AWS_REGION
```

Note: `--capabilities CAPABILITY_AUTO_EXPAND` is **required** whenever a template
uses a macro or transform.

### Step 4 — Verify the injection worked

```bash
aws cloudformation describe-stack-resources \
  --stack-name github-include-consumer \
  --region $AWS_REGION \
  --query 'StackResources[].{Type:ResourceType,LogicalId:LogicalResourceId}'
```

You should see `LoggingBucket` and `LoggingBucketPolicy` in the output — these
came from your GitHub repo, not from the consumer template.

### Cleanup

```bash
aws cloudformation delete-stack --stack-name github-include-consumer --region $AWS_REGION
aws cloudformation wait stack-delete-complete --stack-name github-include-consumer --region $AWS_REGION

aws cloudformation delete-stack --stack-name github-include-macro --region $AWS_REGION
aws cloudformation wait stack-delete-complete --stack-name github-include-macro --region $AWS_REGION
```

## Key Differences vs AWS::Include

| | `AWS::Include` | `GitHubInclude` (this macro) |
|---|---|---|
| Source | S3 only | GitHub (public or private) |
| Auth | S3 bucket policy / IAM | GitHub PAT via Secrets Manager |
| Inline use | Yes (`Fn::Transform`) | Yes (`Fn::Transform`) |
| Top-level use | Yes (`Transform:`) | Yes (`Transform:`) |
| Versioning | S3 object versions | Git branches, tags, commit SHAs |

## Important Behaviors (SME exam relevant)

- The macro runs at **change set creation time**, not execution time
- Dynamic references (`{{resolve:ssm:...}}`) in the template are **not resolved**
  before the macro runs — the macro sees the literal string
- The `Fn::Transform` node is **completely replaced** by the returned fragment
- If the Lambda fails or GitHub is unreachable, the **change set fails** (not the stack)
- `CAPABILITY_AUTO_EXPAND` is required to deploy any template using a macro
- Macros are **account and region scoped** — you must deploy the macro stack in
  every region where you want to use it
- You cannot use a macro in a StackSet without deploying the macro to every
  target account/region first
