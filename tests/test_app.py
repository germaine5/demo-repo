"""Tests for the main application."""
from src.app import handler


def test_handler_returns_200():
    response = handler({}, {})
    assert response["statusCode"] == 200


def test_handler_returns_body():
    response = handler({}, {})
    assert "body" in response
