#!/usr/bin/env python3
"""SigV4-signed CloudWatch PromQL query (port of eks-auto/cwagent-trial/compare/cwq.py).

  AWS_REGION=us-west-2 AWS_PROFILE=ping cwq.py '<promql>' [unix_time]   -> prints the JSON result

Labels with dots must be quoted ({"__name__"="http.server.request.duration","@resource.service.name"="x"}).
Metrics are delta temporality: windows use sum_over_time, e.g.
  histogram_count(sum_over_time({"__name__"="http.server.request.duration"}[5m]))
"""
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

import botocore.session
from botocore.auth import SigV4Auth
from botocore.awsrequest import AWSRequest

REGION = os.environ.get("AWS_REGION", "us-west-2")
URL = f"https://monitoring.{REGION}.amazonaws.com/api/v1/query"


def query(expr, at=None):
    body = {"query": expr}
    if at is not None:
        body["time"] = str(int(at))
    data = urllib.parse.urlencode(body)
    creds = botocore.session.get_session().get_credentials().get_frozen_credentials()
    req = AWSRequest(method="POST", url=URL, data=data,
                     headers={"Content-Type": "application/x-www-form-urlencoded"})
    SigV4Auth(creds, "monitoring", REGION).add_auth(req)
    r = urllib.request.Request(URL, data=data.encode(), headers=dict(req.headers), method="POST")
    try:
        with urllib.request.urlopen(r, timeout=60) as resp:
            return json.loads(resp.read())
    except urllib.error.HTTPError as e:
        return {"status": "error", "http": e.code, "body": e.read().decode()[:2000]}


if __name__ == "__main__":
    print(json.dumps(query(sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else None), indent=1))
