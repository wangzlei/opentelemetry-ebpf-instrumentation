#!/usr/bin/env python3
"""Load/probe helper run INSIDE the test network (uses the checkout image's python + requests).

  probe.py hit URL N [CONCURRENCY]      -> JSON {"statuses": {code: count}, "p50":..., "p99":...}
  probe.py get URL | post URL           -> prints status + body
"""
import collections
import concurrent.futures as cf
import json
import sys
import time

import requests


def one(url):
    t = time.perf_counter()
    try:
        r = requests.post(url, json={}, timeout=20)
        return r.status_code, time.perf_counter() - t
    except requests.RequestException:
        return 0, time.perf_counter() - t


def main():
    cmd, url = sys.argv[1], sys.argv[2]
    if cmd in ("get", "post"):
        r = getattr(requests, cmd)(url, timeout=10)
        print(r.status_code, " ".join(r.text.split()))
        return
    n = int(sys.argv[3])
    conc = int(sys.argv[4]) if len(sys.argv) > 4 else 16
    with cf.ThreadPoolExecutor(conc) as ex:
        res = list(ex.map(one, [url] * n))
    lat = sorted(d for _, d in res)
    print(json.dumps({"n": n, "statuses": dict(sorted(collections.Counter(s for s, _ in res).items())),
                      "p50": round(lat[len(lat) // 2], 3), "p99": round(lat[int(len(lat) * 0.99) - 1], 3)}))


main()
