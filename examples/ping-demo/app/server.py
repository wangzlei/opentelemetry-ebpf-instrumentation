#!/usr/bin/env python3
"""Ping demo service — one Flask app, role selected by $ROLE.

Runs under gunicorn (see Dockerfile). Flask+gunicorn is the server stack OBI
reliably captures; a raw http.server produced status 499 / 0-byte responses
because OBI missed the response write.

Topology (XP_DRAFT §1):
  checkout  POST /checkout      -> payment POST /charges, inventory POST /reservations
  payment   POST /charges       -> audit   POST /audit
  inventory POST /reservations  (leaf)
  audit     POST /audit         (leaf)

Health profile ($PROFILE, XP_DRAFT §3) shapes this service's own responses:
status-code mix + latency, so OBI's http.server.request.duration shows the
right RED arm (2xx=OK, 4xx=Error, 5xx=Fault). Downstream calls produce
http.client.request.duration (the edge signal).
"""
import os
import random
import time

import requests
import urllib3
from flask import Flask, jsonify

urllib3.disable_warnings()  # self-signed downstream certs in the HTTPS demo

ROLE = os.environ.get("ROLE", "checkout")
PORT = int(os.environ.get("PORT", "8000"))

# Comma-separated downstream base URLs; picked random.choice so multiple
# instances (payment x3, audit x3) fan out on EC2.
PAYMENT_URLS = [u for u in os.environ.get("PAYMENT_URLS", "").split(",") if u]
INVENTORY_URLS = [u for u in os.environ.get("INVENTORY_URLS", "").split(",") if u]
AUDIT_URLS = [u for u in os.environ.get("AUDIT_URLS", "").split(",") if u]

ROUTES = {
    "checkout": "/checkout",
    "payment": "/charges",
    "inventory": "/reservations",
    "audit": "/audit",
}
SERVE_ROUTE = ROUTES[ROLE]

# XP_DRAFT §3 _PROFILES: status -> (weight, mean_s, min_s, max_s)
PROFILES = {
    "healthy": [(200, 1000, 0.05, 0.005, 0.40)],
    "degraded": [(200, 1000, 0.30, 0.05, 2.00)],
    "erroring": [
        (200, 500, 0.06, 0.005, 0.50),
        (404, 120, 0.01, 0.001, 0.08),
        (500, 250, 0.03, 0.002, 0.30),
        (429, 130, 0.01, 0.001, 0.10),
    ],
    "faulty": [
        (200, 200, 0.08, 0.005, 0.60),
        (503, 500, 0.05, 0.002, 1.50),
        (500, 300, 0.04, 0.002, 0.90),
    ],
}

# PROFILE is read per request so it can be flipped at runtime via POST /fault
# (fault injection for the demo) without restarting the process.
_state = {"profile": os.environ.get("PROFILE", "healthy")}


def pick_response():
    rows = PROFILES[_state["profile"]]
    weights = [r[1] for r in rows]
    status, _w, mean, lo, hi = random.choices(rows, weights=weights, k=1)[0]
    latency = min(hi, max(lo, random.triangular(lo, hi, mean)))
    return status, latency


def call(base_urls, path):
    """POST to one downstream instance (retry another on failure)."""
    if not base_urls:
        return
    urls = random.sample(base_urls, len(base_urls))  # shuffle for failover order
    for base in urls:
        try:
            requests.post(base.rstrip("/") + path, json={}, timeout=5, verify=False)
            return
        except requests.RequestException:
            continue  # dead instance -> try next (client-side resilience)


def fan_out():
    if ROLE == "checkout":
        call(PAYMENT_URLS, "/charges")
        call(INVENTORY_URLS, "/reservations")
    elif ROLE == "payment":
        call(AUDIT_URLS, "/audit")
    # inventory, audit: leaves


app = Flask(__name__)


@app.get("/healthz")
def healthz():
    return jsonify(ok=True, role=ROLE, profile=_state["profile"])


@app.post("/fault")
def fault():
    from flask import request
    p = request.args.get("profile", "degraded")
    if p not in PROFILES:
        return jsonify(error="unknown profile", valid=list(PROFILES)), 400
    _state["profile"] = p
    return jsonify(role=ROLE, profile=p)


@app.post(SERVE_ROUTE)
def serve():
    status, latency = pick_response()
    if status < 400:
        fan_out()  # only orchestrate on the OK path
    time.sleep(latency)
    return jsonify(role=ROLE, status=status), status


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=PORT)
