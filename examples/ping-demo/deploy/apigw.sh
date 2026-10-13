#!/usr/bin/env bash
# ping demo: inventory -> API Gateway (REST API) -> Lambda, both with X-Ray active tracing
# (vended traces). Inventory POSTs to $STOCK_URL (redeploy-apps.sh passes it to every inventory).
# Port of collector-monorepo/demo/lei/apigw.sh, parametrized by env/<region>.env.
#
#   REGION=us-west-2 ./apigw.sh          create or update (idempotent), prints STOCK_URL
#   REGION=us-west-2 ./apigw.sh url      print STOCK_URL of the existing API (empty if none)
#   REGION=us-west-2 ./apigw.sh down     delete the API, the function and its role
#
# REST API (not HTTP API): only REST APIs support X-Ray tracing. No auth (the function
# returns a constant); the stage throttles to 20 req/s (burst 40). Tagged purpose=ping-demo.
# The vended APIGW -> Lambda traces are separate root traces (APIGW only honours
# X-Amzn-Trace-Id, not traceparent) -- known and accepted.
. "$(dirname "$0")/lib.sh"
check_account
# IAM is global: the role name carries the region so `down` in one region keeps the other.
FN=$PFX-inventory-stock ROLE=$PFX-inventory-stock-$REGION-role API=$PFX-inventory-api STAGE=v1
FN_ARN=arn:aws:lambda:$AWS_REGION:$ACCOUNT:function:$FN
log() { echo "[$(date +%H:%M:%S)] $*" >&2; }
api_id() { aws apigateway get-rest-apis --query "items[?name=='$API'].id | [0]" --output text; }

if [ "${1:-}" = url ]; then
  id=$(api_id); none "$id" || echo "https://$id.execute-api.$AWS_REGION.amazonaws.com/$STAGE/stock"
  exit 0
fi

if [ "${1:-}" = down ]; then
  id=$(api_id); none "$id" || { aws apigateway delete-rest-api --rest-api-id "$id"; log "deleted API $API"; }
  aws lambda delete-function --function-name $FN 2>/dev/null && log "deleted $FN" || true
  for p in service-role/AWSLambdaBasicExecutionRole AWSXRayDaemonWriteAccess; do
    aws iam detach-role-policy --role-name $ROLE --policy-arn arn:aws:iam::aws:policy/$p 2>/dev/null || true
  done
  aws iam delete-role --role-name $ROLE 2>/dev/null && log "deleted $ROLE" || true
  exit 0
fi

# 1) function (active tracing)
if ! aws iam get-role --role-name $ROLE >/dev/null 2>&1; then
  aws iam create-role --role-name $ROLE --tags Key=$TAG_KEY,Value=$TAG_VAL \
    --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}' >/dev/null
  log "created role $ROLE"; NEWROLE=1
fi
for p in service-role/AWSLambdaBasicExecutionRole AWSXRayDaemonWriteAccess; do
  aws iam attach-role-policy --role-name $ROLE --policy-arn arn:aws:iam::aws:policy/$p
done
[ -z "${NEWROLE:-}" ] || sleep 10  # IAM propagation before CreateFunction
TMP=$(mktemp -d); trap 'rm -rf $TMP' EXIT
cat > $TMP/handler.py <<'PY'
import json, random, time

def handler(event, context):
    body = json.loads(event.get("body") or "{}")
    time.sleep(random.uniform(0.01, 0.04))  # "look up" the stock level
    return {"statusCode": 200, "headers": {"Content-Type": "application/json"},
            "body": json.dumps({"sku": body.get("sku"), "in_stock": random.randint(0, 50)})}
PY
(cd $TMP && python3 -m zipfile -c fn.zip handler.py)
if aws lambda get-function --function-name $FN >/dev/null 2>&1; then
  aws lambda update-function-code --function-name $FN --zip-file fileb://$TMP/fn.zip >/dev/null
  aws lambda wait function-updated-v2 --function-name $FN
  aws lambda update-function-configuration --function-name $FN --tracing-config Mode=Active >/dev/null
  log "updated $FN"
else
  aws lambda create-function --function-name $FN --runtime python3.12 --handler handler.handler \
    --role arn:aws:iam::$ACCOUNT:role/$ROLE --zip-file fileb://$TMP/fn.zip --memory-size 128 --timeout 10 \
    --tracing-config Mode=Active --tags $TAG_KEY=$TAG_VAL >/dev/null
  log "created $FN"
fi
aws lambda wait function-active-v2 --function-name $FN
aws lambda wait function-updated-v2 --function-name $FN

# 2) REST API: POST /stock -> Lambda proxy
id=$(api_id)
if none "$id"; then
  id=$(aws apigateway create-rest-api --name $API --endpoint-configuration types=REGIONAL \
    --tags $TAG_KEY=$TAG_VAL --query id --output text)
  log "created API $API $id"
fi
root=$(aws apigateway get-resources --rest-api-id "$id" --query "items[?path=='/'].id | [0]" --output text)
res=$(aws apigateway get-resources --rest-api-id "$id" --query "items[?path=='/stock'].id | [0]" --output text)
none "$res" && res=$(aws apigateway create-resource --rest-api-id "$id" --parent-id "$root" --path-part stock --query id --output text)
aws apigateway put-method --rest-api-id "$id" --resource-id "$res" --http-method POST --authorization-type NONE >/dev/null 2>&1 || true
aws apigateway put-integration --rest-api-id "$id" --resource-id "$res" --http-method POST --type AWS_PROXY \
  --integration-http-method POST \
  --uri "arn:aws:apigateway:$AWS_REGION:lambda:path/2015-03-31/functions/$FN_ARN/invocations" >/dev/null
aws lambda add-permission --function-name $FN --statement-id apigw-$id --action lambda:InvokeFunction \
  --principal apigateway.amazonaws.com --source-arn "arn:aws:execute-api:$AWS_REGION:$ACCOUNT:$id/*/POST/stock" >/dev/null 2>&1 || true
aws apigateway create-deployment --rest-api-id "$id" --stage-name $STAGE >/dev/null
aws apigateway update-stage --rest-api-id "$id" --stage-name $STAGE --patch-operations \
  op=replace,path=/tracingEnabled,value=true \
  'op=replace,path=/*/*/throttling/rateLimit,value=20' \
  'op=replace,path=/*/*/throttling/burstLimit,value=40' >/dev/null
URL=https://$id.execute-api.$AWS_REGION.amazonaws.com/$STAGE/stock
log "stage $STAGE: X-Ray tracing on, throttle 20/s"
curl -s -X POST -H 'Content-Type: application/json' -d '{"sku":"probe"}' "$URL" >&2; echo >&2
echo "$URL"
