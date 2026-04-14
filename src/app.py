"""Main application entry point."""


def handler(event, context):
    """Lambda handler or main entry point."""
    return {
        "statusCode": 200,
        "body": "Hello from the pipeline!"
    }


if __name__ == "__main__":
    print(handler({}, {}))
