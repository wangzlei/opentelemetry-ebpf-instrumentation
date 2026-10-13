# Ping demo checkout service -- Python (Flask + gunicorn). The app is examples/ping-demo/app/server.py
# plus PREFER_SAME_AZ; the gunicorn entry module is checkout_api, so the agent's autoname derives
# "checkout_api" from the command line. No OTEL_SERVICE_NAME, no OpenTelemetry SDK.
FROM python:3.12-slim@sha256:78387bc3881b8273120a12ebe6c1ab22b018ccc2c9adf565ae1ac9b536e184ea
RUN apt-get update && apt-get install -y --no-install-recommends openssl && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
# By name, not `COPY . .`: the test files must not ship into an image with no pytest.
COPY server.py cpuwork.py propagate.py checkout_api.py ./
ENV PORT=8000 ROLE=checkout PROFILE=healthy USE_TLS=0 CPU_SHARE=0
EXPOSE 8000
# gthread workers: handlers block on downstream calls + sleep. USE_TLS=1 serves HTTPS with a
# self-signed cert (demo only).
CMD ["sh", "-c", "\
  if [ \"$USE_TLS\" = \"1\" ]; then \
    openssl req -x509 -newkey rsa:2048 -nodes -keyout /tmp/k.pem -out /tmp/c.pem -days 3650 -subj '/CN=ping' >/dev/null 2>&1; \
    exec gunicorn -w 2 --threads 8 -b 0.0.0.0:${PORT} --certfile /tmp/c.pem --keyfile /tmp/k.pem --access-logfile - checkout_api:app; \
  else \
    exec gunicorn -w 2 --threads 8 -b 0.0.0.0:${PORT} --access-logfile - checkout_api:app; \
  fi"]
