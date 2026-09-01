// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0

package ebpfcommon

import (
	"testing"

	"github.com/stretchr/testify/assert"

	"go.opentelemetry.io/obi/pkg/appolly/app/request"
)

// reqHead builds a raw HTTP request head, zero-padded to 256 bytes to mimic the
// eBPF FULL_BUF_SIZE inline buffer (which is truncated and NUL-padded).
func reqHead(line string, headers ...string) []byte {
	s := line + "\r\n"
	for _, h := range headers {
		s += h + "\r\n"
	}
	b := make([]byte, 256)
	copy(b, s)
	return b
}

func TestAWSGeneric_DynamoDB_TargetHeader(t *testing.T) {
	// Real boto3 layout: X-Amz-Target sits at offset 17, well inside 256B.
	head := reqHead("POST / HTTP/1.1",
		"X-Amz-Target: DynamoDB_20120810.Query",
		"Content-Type: application/x-amz-json-1.0",
		"User-Agent: Boto3/1.35.0 md/Botocore#1.35.0 ua/2.0 os/linux#5.15 md/arch#x86_64 lang/python#3.12",
	)
	base := request.Span{Type: request.EventTypeHTTPClient, Method: "POST", Path: "/"}

	span, ok := AWSGenericSpan(&base, head, "dynamodb.us-west-2.amazonaws.com")
	assert.True(t, ok)
	assert.Equal(t, request.HTTPSubtypeAWSGeneric, span.SubType)
	assert.Equal(t, "DynamoDB", span.AWS.Generic.Service)
	assert.Equal(t, "Query", span.AWS.Generic.Operation)
	assert.Equal(t, "us-west-2", span.AWS.Generic.Region)
	assert.Equal(t, "DynamoDB.Query", span.TraceName())
}

func TestAWSGeneric_SQS_TargetHeader(t *testing.T) {
	head := reqHead("POST / HTTP/1.1", "X-Amz-Target: AmazonSQS.SendMessage")
	base := request.Span{Type: request.EventTypeHTTPClient, Method: "POST", Path: "/"}

	span, ok := AWSGenericSpan(&base, head, "sqs.eu-west-1.amazonaws.com")
	assert.True(t, ok)
	assert.Equal(t, "SQS", span.AWS.Generic.Service)
	assert.Equal(t, "SendMessage", span.AWS.Generic.Operation)
	assert.Equal(t, "eu-west-1", span.AWS.Generic.Region)
}

func TestAWSGeneric_TruncatedTargetIsIgnored(t *testing.T) {
	// A header whose CRLF falls outside the window must NOT yield a partial
	// value. Build a head where X-Amz-Target is cut off mid-value.
	s := "POST / HTTP/1.1\r\nX-Amz-Target: DynamoDB_20120810.Que"
	b := make([]byte, 256)
	copy(b, s)
	base := request.Span{Type: request.EventTypeHTTPClient, Method: "POST", Path: "/"}

	span, ok := AWSGenericSpan(&base, b, "dynamodb.us-west-2.amazonaws.com")
	// Falls back to path inference, which for a non-REST service yields the
	// method rather than a truncated operation.
	assert.True(t, ok)
	assert.Equal(t, "POST", span.AWS.Generic.Operation, "must not use a truncated header value")
}

func TestAWSGeneric_S3_PathStyle(t *testing.T) {
	head := reqHead("GET /my-bucket/some/key.txt HTTP/1.1")
	base := request.Span{Type: request.EventTypeHTTPClient, Method: "GET", Path: "/my-bucket/some/key.txt"}

	span, ok := AWSGenericSpan(&base, head, "s3.us-west-2.amazonaws.com")
	assert.True(t, ok)
	assert.Equal(t, "S3", span.AWS.Generic.Service)
	assert.Equal(t, "GetObject", span.AWS.Generic.Operation)
}

func TestAWSGeneric_S3_ListBuckets(t *testing.T) {
	head := reqHead("GET / HTTP/1.1")
	base := request.Span{Type: request.EventTypeHTTPClient, Method: "GET", Path: "/"}

	span, ok := AWSGenericSpan(&base, head, "s3.us-west-2.amazonaws.com")
	assert.True(t, ok)
	assert.Equal(t, "ListBuckets", span.AWS.Generic.Operation)
}

func TestAWSGeneric_S3_VirtualHostedStyle(t *testing.T) {
	head := reqHead("PUT /obj.txt HTTP/1.1")
	base := request.Span{Type: request.EventTypeHTTPClient, Method: "PUT", Path: "/obj.txt"}

	span, ok := AWSGenericSpan(&base, head, "my-bucket.s3.eu-central-1.amazonaws.com")
	assert.True(t, ok)
	assert.Equal(t, "S3", span.AWS.Generic.Service, "bucket label must not be taken as the service")
	assert.Equal(t, "PutObject", span.AWS.Generic.Operation)
	assert.Equal(t, "eu-central-1", span.AWS.Generic.Region)
}

func TestAWSGeneric_Lambda_Invoke(t *testing.T) {
	p := "/2015-03-31/functions/my-fn/invocations"
	head := reqHead("POST " + p + " HTTP/1.1")
	base := request.Span{Type: request.EventTypeHTTPClient, Method: "POST", Path: p}

	span, ok := AWSGenericSpan(&base, head, "lambda.us-west-2.amazonaws.com")
	assert.True(t, ok)
	assert.Equal(t, "Lambda", span.AWS.Generic.Service)
	assert.Equal(t, "Invoke", span.AWS.Generic.Operation)
}

func TestAWSGeneric_BedrockRuntime_InvokeModel(t *testing.T) {
	p := "/model/anthropic.claude-3-sonnet/invoke"
	head := reqHead("POST " + p + " HTTP/1.1")
	base := request.Span{Type: request.EventTypeHTTPClient, Method: "POST", Path: p}

	span, ok := AWSGenericSpan(&base, head, "bedrock-runtime.us-west-2.amazonaws.com")
	assert.True(t, ok)
	assert.Equal(t, "BedrockRuntime", span.AWS.Generic.Service)
	assert.Equal(t, "InvokeModel", span.AWS.Generic.Operation)
}

func TestAWSGeneric_NonAWSHostRejected(t *testing.T) {
	head := reqHead("GET / HTTP/1.1")
	base := request.Span{Type: request.EventTypeHTTPClient, Method: "GET", Path: "/"}

	_, ok := AWSGenericSpan(&base, head, "www.example.com")
	assert.False(t, ok)

	_, ok = AWSGenericSpan(&base, head, "notamazonaws.com")
	assert.False(t, ok)
}

func TestAWSGeneric_GlobalEndpointDefaultsRegion(t *testing.T) {
	head := reqHead("POST / HTTP/1.1", "X-Amz-Target: AWSSecurityTokenServiceV20110615.GetCallerIdentity")
	base := request.Span{Type: request.EventTypeHTTPClient, Method: "POST", Path: "/"}

	span, ok := AWSGenericSpan(&base, head, "sts.amazonaws.com")
	assert.True(t, ok)
	assert.Equal(t, "STS", span.AWS.Generic.Service)
	assert.Equal(t, "GetCallerIdentity", span.AWS.Generic.Operation)
	assert.Equal(t, "us-east-1", span.AWS.Generic.Region)
}

func TestAWSGeneric_ChinaPartition(t *testing.T) {
	head := reqHead("POST / HTTP/1.1", "X-Amz-Target: AmazonSNS.Publish")
	base := request.Span{Type: request.EventTypeHTTPClient, Method: "POST", Path: "/"}

	span, ok := AWSGenericSpan(&base, head, "sns.cn-north-1.amazonaws.com.cn")
	assert.True(t, ok)
	assert.Equal(t, "SNS", span.AWS.Generic.Service)
	assert.Equal(t, "Publish", span.AWS.Generic.Operation)
	assert.Equal(t, "cn-north-1", span.AWS.Generic.Region)
}

// Account-specific DynamoDB endpoint: <account-id>.ddb.<region>.amazonaws.com.
// The account id must never become rpc.service (it would be high-cardinality).
func TestAWSGeneric_DynamoDB_AccountSpecificEndpoint(t *testing.T) {
	head := reqHead("POST / HTTP/1.1", "X-Amz-Target: DynamoDB_20120810.ListTables")
	base := request.Span{Type: request.EventTypeHTTPClient, Method: "POST", Path: "/"}

	span, ok := AWSGenericSpan(&base, head, "292779133546.ddb.us-west-2.amazonaws.com")
	assert.True(t, ok)
	assert.Equal(t, "DynamoDB", span.AWS.Generic.Service, "must resolve ddb, not the account id")
	assert.Equal(t, "ListTables", span.AWS.Generic.Operation)
	assert.Equal(t, "us-west-2", span.AWS.Generic.Region)
}

func TestAWSGeneric_AccountIDNeverBecomesService(t *testing.T) {
	head := reqHead("POST / HTTP/1.1", "X-Amz-Target: Whatever.DoThing")
	base := request.Span{Type: request.EventTypeHTTPClient, Method: "POST", Path: "/"}

	// Unknown service label preceded by an account id: the numeric label must be
	// skipped so rpc.service does not explode in cardinality.
	span, ok := AWSGenericSpan(&base, head, "292779133546.somesvc.us-west-2.amazonaws.com")
	assert.True(t, ok)
	assert.Equal(t, "somesvc", span.AWS.Generic.Service)
}

func TestAWSGeneric_Lambda_ListVsGetVsInvoke(t *testing.T) {
	cases := []struct {
		method, path, want string
	}{
		{"GET", "/2015-03-31/functions/", "ListFunctions"},
		{"GET", "/2015-03-31/functions", "ListFunctions"},
		{"POST", "/2015-03-31/functions", "CreateFunction"},
		{"GET", "/2015-03-31/functions/my-fn", "GetFunction"},
		{"DELETE", "/2015-03-31/functions/my-fn", "DeleteFunction"},
		{"POST", "/2015-03-31/functions/my-fn/invocations", "Invoke"},
		{"GET", "/2015-03-31/functions/my-fn/configuration", "GetFunctionConfiguration"},
	}
	for _, c := range cases {
		head := reqHead(c.method + " " + c.path + " HTTP/1.1")
		base := request.Span{Type: request.EventTypeHTTPClient, Method: c.method, Path: c.path}
		span, ok := AWSGenericSpan(&base, head, "lambda.us-west-2.amazonaws.com")
		assert.True(t, ok, c.path)
		assert.Equal(t, "Lambda", span.AWS.Generic.Service)
		assert.Equal(t, c.want, span.AWS.Generic.Operation, "%s %s", c.method, c.path)
	}
}

// A sample of the expanded table, including labels that do not resemble the
// product name.
func TestAWSGeneric_ServiceLabelAliases(t *testing.T) {
	cases := map[string]string{
		"monitoring.us-west-2.amazonaws.com":           "CloudWatch",
		"logs.us-west-2.amazonaws.com":                 "CloudWatchLogs",
		"email.us-west-2.amazonaws.com":                "SES",
		"es.us-west-2.amazonaws.com":                   "OpenSearch",
		"elasticmapreduce.us-west-2.amazonaws.com":     "EMR",
		"states.us-west-2.amazonaws.com":               "SFN",
		"kafka.us-west-2.amazonaws.com":                "MSK",
		"elasticloadbalancing.us-west-2.amazonaws.com": "ELB",
		"bedrock-runtime.us-west-2.amazonaws.com":      "BedrockRuntime",
		"secretsmanager.us-west-2.amazonaws.com":       "SecretsManager",
	}
	for host, want := range cases {
		head := reqHead("POST / HTTP/1.1", "X-Amz-Target: Svc.Op")
		base := request.Span{Type: request.EventTypeHTTPClient, Method: "POST", Path: "/"}
		span, ok := AWSGenericSpan(&base, head, host)
		assert.True(t, ok, host)
		assert.Equal(t, want, span.AWS.Generic.Service, host)
	}
}

func TestAWSGeneric_UnknownServiceFallsBackToHostLabel(t *testing.T) {
	head := reqHead("POST / HTTP/1.1", "X-Amz-Target: SomeNewService_20990101.DoThing")
	base := request.Span{Type: request.EventTypeHTTPClient, Method: "POST", Path: "/"}

	span, ok := AWSGenericSpan(&base, head, "somenewservice.us-west-2.amazonaws.com")
	assert.True(t, ok)
	assert.Equal(t, "somenewservice", span.AWS.Generic.Service)
	assert.Equal(t, "DoThing", span.AWS.Generic.Operation)
}

func TestAWSGeneric_HeaderCaseInsensitive(t *testing.T) {
	head := reqHead("POST / HTTP/1.1", "x-amz-target: AmazonSQS.ReceiveMessage")
	base := request.Span{Type: request.EventTypeHTTPClient, Method: "POST", Path: "/"}

	span, ok := AWSGenericSpan(&base, head, "sqs.us-west-2.amazonaws.com")
	assert.True(t, ok)
	assert.Equal(t, "ReceiveMessage", span.AWS.Generic.Operation)
}

func TestAWSGeneric_HostWithPort(t *testing.T) {
	head := reqHead("POST / HTTP/1.1", "X-Amz-Target: DynamoDB_20120810.PutItem")
	base := request.Span{Type: request.EventTypeHTTPClient, Method: "POST", Path: "/"}

	span, ok := AWSGenericSpan(&base, head, "dynamodb.us-west-2.amazonaws.com:443")
	assert.True(t, ok)
	assert.Equal(t, "DynamoDB", span.AWS.Generic.Service)
	assert.Equal(t, "PutItem", span.AWS.Generic.Operation)
}
