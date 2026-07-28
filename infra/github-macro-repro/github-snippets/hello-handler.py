import json

def handler(event, context):
    """
    This Lambda function code lives in GitHub.
    The GitHubInclude macro fetches it and injects it
    into the CloudFormation template as a ZipFile inline code block.
    """
    print("Event:", json.dumps(event))
    return {
        "statusCode": 200,
        "body": json.dumps({
            "message": "Hello from GitHub-injected Lambda code!",
            "source": "germaine5/demo-repo"
        })
    }
