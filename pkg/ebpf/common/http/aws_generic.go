// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0

package ebpfcommon // import "go.opentelemetry.io/obi/pkg/ebpf/common/http"

import (
	"bytes"
	"strings"

	"go.opentelemetry.io/obi/pkg/appolly/app/request"
)

// Generic AWS SDK identification from the REQUEST HEAD ONLY.
//
// Unlike AWSS3Span/AWSSQSSpan, this parser needs neither the response headers
// nor the body, so it works off the small inline eBPF buffer (FULL_BUF_SIZE,
// 256B) that is captured for every request regardless of whether large buffers
// are enabled. That makes it essentially free: no extra kernel->user transfer,
// no dependency on payload_extraction large buffers, and immune to body
// truncation or ring-buffer drops of large-buffer chunks.
//
// Why the request head is enough (measured against a real boto3 request):
//
//	[   0] POST / HTTP/1.1
//	[  17] X-Amz-Target: DynamoDB_20120810.Query   <- operation
//	[  59] Content-Type: application/x-amz-json-1.0
//	[ 104] User-Agent: ... (166B)
//	[ 284] X-Amz-Date                              <- past 256B
//	[ 317] X-Amz-Security-Token (1239B)
//	[1580] Authorization (246B)
//	[1959] traceparent / baggage                   <- always last
//
// AWS SDKs emit the semantic headers first (the serializer adds X-Amz-Target
// before signing), the bulky auth headers next, and W3C propagation headers
// last -- traceparent/baggage MUST be injected after SigV4 signing or they
// would break the signature, so they can never push X-Amz-Target out of the
// window.
//
// Trade-offs vs the S3/SQS parsers:
//   - no aws.request_id / aws.extended_request_id (response headers)
//   - no body-derived detail (S3 bucket/key, SQS QueueUrl, DynamoDB TableName)
//   - identification is by host suffix rather than by the x-amz-request-id
//     "AWS fingerprint" in the response
const (
	amzTargetHeaderLower = "x-amz-target"
	awsHostSuffix        = ".amazonaws.com"
)

// awsServiceNames maps the endpoint host prefix to the OTel rpc.service value.
// Only entries that need a specific casing/name are listed; anything else falls
// back to the host prefix as-is.
// Keys are endpoint host labels (as they appear in <label>.<region>.amazonaws.com);
// several services expose more than one label, and a few use a label that does
// not resemble the product name at all (e.g. "monitoring" = CloudWatch,
// "email" = SES, "ddb" = account-specific DynamoDB). Values are the OTel
// rpc.service value.
var awsServiceNames = map[string]string{
	// --- Storage / data ---
	"s3":                "S3",
	"s3-control":        "S3Control",
	"s3-outposts":       "S3Outposts",
	"dynamodb":          "DynamoDB",
	"ddb":               "DynamoDB", // <account-id>.ddb.<region>.amazonaws.com
	"streams":           "DynamoDBStreams",
	"dax":               "DAX",
	"rds":               "RDS",
	"rds-data":          "RDSData",
	"redshift":          "Redshift",
	"redshift-data":     "RedshiftData",
	"elasticache":       "ElastiCache",
	"elasticfilesystem": "EFS",
	"memory-db":         "MemoryDB",
	"memorydb":          "MemoryDB",
	"docdb":             "DocDB",
	"neptune":           "Neptune",
	"neptune-graph":     "NeptuneGraph",
	"timestream":        "Timestream",
	"ingest.timestream": "Timestream",
	"query.timestream":  "Timestream",
	"fsx":               "FSx",
	"backup":            "Backup",
	"glacier":           "Glacier",
	"athena":            "Athena",
	"glue":              "Glue",
	"lakeformation":     "LakeFormation",
	"datasync":          "DataSync",
	"dms":               "DMS",

	// --- Messaging / streaming / integration ---
	"sqs":              "SQS",
	"sns":              "SNS",
	"kinesis":          "Kinesis",
	"firehose":         "Firehose",
	"kinesisanalytics": "KinesisAnalytics",
	"kinesisvideo":     "KinesisVideo",
	"events":           "EventBridge",
	"scheduler":        "EventBridgeScheduler",
	"pipes":            "EventBridgePipes",
	"states":           "SFN",
	"swf":              "SWF",
	"mq":               "MQ",
	"kafka":            "MSK",
	"appflow":          "AppFlow",

	// --- Compute / containers ---
	"lambda":                  "Lambda",
	"ec2":                     "EC2",
	"ecs":                     "ECS",
	"eks":                     "EKS",
	"ecr":                     "ECR",
	"api.ecr":                 "ECR",
	"api.ecr-public":          "ECRPublic",
	"ecr-public":              "ECRPublic",
	"batch":                   "Batch",
	"autoscaling":             "AutoScaling",
	"application-autoscaling": "ApplicationAutoScaling",
	"elasticbeanstalk":        "ElasticBeanstalk",
	"apprunner":               "AppRunner",
	"lightsail":               "Lightsail",
	"outposts":                "Outposts",
	"imagebuilder":            "ImageBuilder",

	// --- Networking / delivery ---
	"elasticloadbalancing": "ELB",
	"route53":              "Route53",
	"route53resolver":      "Route53Resolver",
	"cloudfront":           "CloudFront",
	"apigateway":           "APIGateway",
	"execute-api":          "APIGateway",
	"appsync":              "AppSync",
	"globalaccelerator":    "GlobalAccelerator",
	"directconnect":        "DirectConnect",
	"networkmanager":       "NetworkManager",
	"servicediscovery":     "CloudMap",
	"vpc-lattice":          "VPCLattice",

	// --- Security / identity ---
	"sts":                 "STS",
	"iam":                 "IAM",
	"kms":                 "KMS",
	"secretsmanager":      "SecretsManager",
	"acm":                 "ACM",
	"acm-pca":             "ACMPCA",
	"cognito-idp":         "CognitoIdentityProvider",
	"cognito-identity":    "CognitoIdentity",
	"sso":                 "SSO",
	"identitystore":       "IdentityStore",
	"organizations":       "Organizations",
	"guardduty":           "GuardDuty",
	"inspector2":          "Inspector2",
	"securityhub":         "SecurityHub",
	"macie2":              "Macie2",
	"wafv2":               "WAFV2",
	"waf":                 "WAF",
	"shield":              "Shield",
	"detective":           "Detective",
	"api.detective":       "Detective",
	"access-analyzer":     "AccessAnalyzer",
	"ram":                 "RAM",
	"signer":              "Signer",
	"verifiedpermissions": "VerifiedPermissions",

	// --- Management / observability ---
	"monitoring":            "CloudWatch", // CloudWatch metrics endpoint label
	"logs":                  "CloudWatchLogs",
	"oam":                   "CloudWatchOAM",
	"synthetics":            "CloudWatchSynthetics",
	"rum":                   "CloudWatchRUM",
	"internetmonitor":       "InternetMonitor",
	"applicationinsights":   "ApplicationInsights",
	"xray":                  "XRay",
	"servicecatalog":        "ServiceCatalog",
	"ssm":                   "SSM",
	"ssm-incidents":         "SSMIncidents",
	"ssm-contacts":          "SSMContacts",
	"cloudformation":        "CloudFormation",
	"cloudtrail":            "CloudTrail",
	"config":                "Config",
	"resource-groups":       "ResourceGroups",
	"tagging":               "ResourceGroupsTagging",
	"health":                "Health",
	"support":               "Support",
	"trustedadvisor":        "TrustedAdvisor",
	"servicequotas":         "ServiceQuotas",
	"license-manager":       "LicenseManager",
	"compute-optimizer":     "ComputeOptimizer",
	"cost-optimization-hub": "CostOptimizationHub",
	"ce":                    "CostExplorer",
	"budgets":               "Budgets",
	"cur":                   "CostAndUsageReport",
	"pricing":               "Pricing",
	"api.pricing":           "Pricing",
	"codeguru-reviewer":     "CodeGuruReviewer",
	"codeguru-profiler":     "CodeGuruProfiler",

	// --- Developer tools ---
	"codebuild":            "CodeBuild",
	"codepipeline":         "CodePipeline",
	"codedeploy":           "CodeDeploy",
	"codecommit":           "CodeCommit",
	"codeartifact":         "CodeArtifact",
	"codestar-connections": "CodeStarConnections",
	"cloud9":               "Cloud9",
	"amplify":              "Amplify",
	"devicefarm":           "DeviceFarm",
	"cloudshell":           "CloudShell",

	// --- AI / ML ---
	"bedrock":               "Bedrock",
	"bedrock-runtime":       "BedrockRuntime",
	"bedrock-agent":         "BedrockAgent",
	"bedrock-agent-runtime": "BedrockAgentRuntime",
	"sagemaker":             "SageMaker",
	"runtime.sagemaker":     "SageMakerRuntime",
	"api.sagemaker":         "SageMaker",
	"comprehend":            "Comprehend",
	"rekognition":           "Rekognition",
	"textract":              "Textract",
	"translate":             "Translate",
	"transcribe":            "Transcribe",
	"polly":                 "Polly",
	"personalize":           "Personalize",
	"forecast":              "Forecast",
	"kendra":                "Kendra",
	"q":                     "Q",

	// --- Application / end-user ---
	"email":             "SES", // SES classic endpoint label
	"pinpoint":          "Pinpoint",
	"connect":           "Connect",
	"chime":             "Chime",
	"workspaces":        "WorkSpaces",
	"workdocs":          "WorkDocs",
	"workmail":          "WorkMail",
	"quicksight":        "QuickSight",
	"mediaconvert":      "MediaConvert",
	"medialive":         "MediaLive",
	"mediapackage":      "MediaPackage",
	"mediastore":        "MediaStore",
	"ivs":               "IVS",
	"elastictranscoder": "ElasticTranscoder",

	// --- IoT / edge ---
	"iot":          "IoT",
	"iotanalytics": "IoTAnalytics",
	"iotevents":    "IoTEvents",
	"iotsitewise":  "IoTSiteWise",
	"greengrass":   "Greengrass",

	// --- Migration / misc ---
	"serverlessrepo":               "ServerlessRepo",
	"marketplacecommerceanalytics": "MarketplaceCommerceAnalytics",
	"opensearch":                   "OpenSearch",
	"es":                           "OpenSearch", // legacy Elasticsearch Service label
	"aoss":                         "OpenSearchServerless",
	"elasticmapreduce":             "EMR",
	"emr-serverless":               "EMRServerless",
	"emr-containers":               "EMRContainers",
	"databrew":                     "GlueDataBrew",
	"dataexchange":                 "DataExchange",
	"entityresolution":             "EntityResolution",
	"proton":                       "Proton",
	"resiliencehub":                "ResilienceHub",
	"fis":                          "FIS",
	"wellarchitected":              "WellArchitected",
	"controltower":                 "ControlTower",
	"account":                      "Account",
	"appconfig":                    "AppConfig",
	"appconfigdata":                "AppConfigData",
	"appmesh":                      "AppMesh",
	"gamelift":                     "GameLift",
	"braket":                       "Braket",
	"groundstation":                "GroundStation",
	"snowball":                     "Snowball",
	"transfer":                     "Transfer",
	"schemas":                      "Schemas",
	"discovery":                    "ApplicationDiscovery",
	"mgn":                          "MGN",
	"drs":                          "DRS",
}

// AWSGenericSpan enriches a span with AWS service/operation resolved purely
// from the request head. Returns false when the request is not an AWS SDK call
// or when no operation could be resolved.
func AWSGenericSpan(baseSpan *request.Span, reqHead []byte, host string) (request.Span, bool) {
	service, ok := awsServiceFromHost(host)
	if !ok {
		return *baseSpan, false
	}

	operation := awsOperationFromTarget(reqHead)
	if operation == "" {
		// REST-style services (S3, Lambda, Bedrock, API Gateway, ...) carry the
		// operation in the request line rather than in X-Amz-Target.
		//
		// For S3 the bucket may live in the host (virtual-hosted style), in
		// which case the whole path is the object key and the segment count
		// means something different than in path style.
		virtualHosted := service == "S3" && strings.Contains(strings.ToLower(host), ".s3.")
		operation = awsOperationFromPath(service, baseSpan.Method, baseSpan.Path, virtualHosted)
	}
	if operation == "" {
		return *baseSpan, false
	}

	baseSpan.SubType = request.HTTPSubtypeAWSGeneric
	baseSpan.AWS = &request.AWS{
		Generic: request.AWSGeneric{
			Service:   service,
			Operation: operation,
			Region:    awsRegionFromHost(host),
		},
	}

	return *baseSpan, true
}

// awsServiceFromHost maps "dynamodb.us-west-2.amazonaws.com" -> "DynamoDB".
// It also handles virtual-hosted-style S3 ("bucket.s3.us-west-2.amazonaws.com")
// and China partitions ("...amazonaws.com.cn").
func awsServiceFromHost(host string) (string, bool) {
	h := strings.ToLower(host)
	// Drop any :port
	if i := strings.IndexByte(h, ':'); i >= 0 {
		h = h[:i]
	}
	h = strings.TrimSuffix(h, ".cn")
	if !strings.HasSuffix(h, awsHostSuffix) {
		return "", false
	}

	labels := strings.Split(strings.TrimSuffix(h, awsHostSuffix), ".")
	// Scan left to right and take the first label that names a known service.
	// This catches virtual-hosted-style S3 (bucket precedes "s3") and
	// account-specific endpoints like <account-id>.ddb.<region>.
	for _, l := range labels {
		if name, ok := awsServiceNames[l]; ok {
			return name, true
		}
	}
	// Unknown service: fall back to the leftmost label that plausibly IS a
	// service name, so the dependency is still attributed to something AWS.
	//
	// Labels that are per-account/per-resource (a bare account id, an opaque
	// id, a region) must NOT become the service name: they would explode
	// rpc.service into a high-cardinality dimension -- exactly the failure mode
	// we avoid elsewhere. Skipping them usually leaves the real service label
	// (e.g. "<account>.<newservice>.<region>" -> "newservice").
	for _, l := range labels {
		if plausibleAWSServiceLabel(l) {
			return l, true
		}
	}
	return "", false
}

// plausibleAWSServiceLabel rejects host labels that are clearly not a service
// name: empty, all-digit (AWS account id), a region, or long opaque ids.
func plausibleAWSServiceLabel(l string) bool {
	if l == "" || len(l) > 30 {
		return false
	}
	if isAWSRegion(l) {
		return false
	}
	allDigits := true
	for _, r := range l {
		if r < '0' || r > '9' {
			allDigits = false
			break
		}
	}
	return !allDigits
}

// awsOperationFromTarget extracts the operation from the X-Amz-Target header,
// used by the AWS-JSON (RPC-style) protocols: DynamoDB, SQS, SNS, Kinesis,
// Secrets Manager, CloudWatch Logs, EventBridge, Step Functions, ...
//
//	X-Amz-Target: DynamoDB_20120810.Query  ->  "Query"
//	X-Amz-Target: AmazonSQS.SendMessage    ->  "SendMessage"
func awsOperationFromTarget(reqHead []byte) string {
	val, ok := headerValueFromHead(reqHead, amzTargetHeaderLower)
	if !ok {
		return ""
	}
	// Everything after the last '.' is the operation; the prefix is the
	// service+API-version shape which we already get from the host.
	if i := strings.LastIndexByte(val, '.'); i >= 0 && i+1 < len(val) {
		return val[i+1:]
	}
	return val
}

// awsOperationFromPath infers the operation for REST-style AWS services from
// the HTTP method and path. This is best-effort and intentionally coarse: it
// names the operation where the mapping is unambiguous, otherwise it returns
// the method so the span still carries *an* operation.
func awsOperationFromPath(service, method, path string, virtualHosted bool) string {
	// Strip any query string.
	if i := strings.IndexByte(path, '?'); i >= 0 {
		path = path[:i]
	}
	segs := splitPath(path)

	switch service {
	case "S3":
		// Delegated to the dedicated S3 parser when large buffers are on; this
		// is the reduced request-head-only inference.
		//
		// Path style:            /bucket/key  -> 2+ segments means an object
		// Virtual-hosted style:  /key        -> the bucket is in the host, so
		//                                       ANY segment is already an object
		hasObject := len(segs) >= 2
		hasBucket := len(segs) >= 1
		if virtualHosted {
			hasObject = len(segs) >= 1
			hasBucket = true
		}

		switch method {
		case "GET":
			switch {
			case hasObject:
				return "GetObject"
			case hasBucket:
				return "ListObjects"
			default:
				return "ListBuckets"
			}
		case "PUT":
			if hasObject {
				return "PutObject"
			}
			return "CreateBucket"
		case "DELETE":
			if hasObject {
				return "DeleteObject"
			}
			return "DeleteBucket"
		case "HEAD":
			if hasObject {
				return "HeadObject"
			}
			return "HeadBucket"
		case "POST":
			return "PostObject"
		}
	case "Lambda":
		// The operation depends on how many segments follow "functions":
		//   /2015-03-31/functions               -> collection  (List/Create)
		//   /2015-03-31/functions/{name}        -> one function (Get/Delete/Update)
		//   /2015-03-31/functions/{name}/invocations -> Invoke
		for i, s := range segs {
			if s != "functions" {
				continue
			}
			rest := segs[i+1:]
			switch len(rest) {
			case 0: // collection
				switch method {
				case "GET":
					return "ListFunctions"
				case "POST":
					return "CreateFunction"
				}
			case 1: // a single function
				switch method {
				case "GET":
					return "GetFunction"
				case "DELETE":
					return "DeleteFunction"
				case "PUT", "POST":
					return "UpdateFunctionCode"
				}
			default: // sub-resource
				switch rest[1] {
				case "invocations":
					return "Invoke"
				case "configuration":
					if method == "GET" {
						return "GetFunctionConfiguration"
					}
					return "UpdateFunctionConfiguration"
				case "aliases":
					if method == "GET" {
						return "ListAliases"
					}
					return "CreateAlias"
				case "versions":
					return "ListVersionsByFunction"
				}
			}
		}
	case "BedrockRuntime", "Bedrock":
		// /model/{modelId}/invoke  |  /model/{modelId}/invoke-with-response-stream
		for i, s := range segs {
			if s == "model" && i+2 < len(segs) {
				switch segs[i+2] {
				case "invoke":
					return "InvokeModel"
				case "invoke-with-response-stream":
					return "InvokeModelWithResponseStream"
				case "converse":
					return "Converse"
				case "converse-stream":
					return "ConverseStream"
				}
			}
		}
	case "XRay":
		// /TraceSegments, /Traces, ...
		if len(segs) > 0 {
			return "Put" + segs[len(segs)-1]
		}
	}

	// Unknown REST shape: at least report the HTTP method so the operation is
	// never empty for an AWS host.
	if method != "" {
		return method
	}
	return ""
}

func splitPath(path string) []string {
	path = strings.Trim(path, "/")
	if path == "" {
		return nil
	}
	return strings.Split(path, "/")
}

// awsRegionFromHost pulls the region out of the endpoint host, defaulting to
// us-east-1 for global endpoints (e.g. sts.amazonaws.com), mirroring
// parseAWSRegion in aws_common.go.
func awsRegionFromHost(host string) string {
	h := strings.ToLower(host)
	if i := strings.IndexByte(h, ':'); i >= 0 {
		h = h[:i]
	}
	if m := awsRegionURLRgx.FindStringSubmatch(h); len(m) >= 2 && isAWSRegion(m[1]) {
		return m[1]
	}
	if m := awsRegionURLRgx2.FindStringSubmatch(h); len(m) >= 2 && isAWSRegion(m[1]) {
		return m[1]
	}
	return "us-east-1"
}

// headerValueFromHead does a case-insensitive scan for a header in a raw HTTP
// request head. It works on a possibly TRUNCATED buffer: the header must be
// fully present (name, value and terminating CRLF) within the buffer to be
// returned, so a header cut off by the 256B window is simply reported missing
// rather than yielding a partial value.
func headerValueFromHead(head []byte, lowerName string) (string, bool) {
	// Stop at the end of the header block if it is present in the buffer.
	// Keep the terminating CRLF of the LAST header (cut at end+2, not end), so
	// that final header still looks complete to the line scan below -- otherwise
	// a fully-received last header would be misjudged as truncated.
	if end := bytes.Index(head, []byte("\r\n\r\n")); end >= 0 {
		head = head[:end+2]
	}
	// Trim at the first NUL: the eBPF buffer is zero-padded.
	if z := bytes.IndexByte(head, 0); z >= 0 {
		head = head[:z]
	}

	name := []byte(lowerName)
	for off := 0; off < len(head); {
		nl := bytes.Index(head[off:], []byte("\r\n"))
		if nl < 0 {
			// Last line is incomplete (window cut it) -- do not parse it.
			return "", false
		}
		line := head[off : off+nl]
		off += nl + 2

		colon := bytes.IndexByte(line, ':')
		if colon < 0 {
			continue // request line, or malformed
		}
		if !bytes.EqualFold(bytes.TrimSpace(line[:colon]), name) {
			continue
		}
		return string(bytes.TrimSpace(line[colon+1:])), true
	}
	return "", false
}
