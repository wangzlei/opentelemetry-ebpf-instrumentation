"""Entry module for the checkout service.

The Flask app lives in server.py (the same file every role of the Python app uses). The image runs
`gunicorn ... checkout_api:app`, so the process's own command line names the service: the agent's
autoname derives `checkout_api` without OTEL_SERVICE_NAME.
"""
from server import app  # noqa: F401
