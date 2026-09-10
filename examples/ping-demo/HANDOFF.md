# ping demo — live deployment handoff

Running now in account `868155213681`, region `us-west-2`. Access via SSM (no SSH / public
IPs); use your own credentials. See `NOTES.md` for the design and RCA story.

## Layout: 3 per-AZ app subnets (production-like)

VPC `vpc-017c34776120b35bc` (10.0.0.0/16), NAT `nat-0b6143c75712bb572`, SG
`sg-0f6caf64203f751e2` (intra :8000 + egress). One app subnet per AZ, route table
`rtb-01a1e5ac8d3313dc3` (→ NAT). Each AZ's payment + audit share that AZ's subnet.

| subnet | AZ | CIDR | instances |
|---|---|---|---|
| subnet-021e38e8d9ca3548a (ping-app-2a) | us-west-2a | 10.0.10.0/24 | payment 10.0.10.246 (i-0bd3c18270fbd8be5), audit 10.0.10.5 (i-051d704f8a697dc5e) |
| subnet-04ed7b4596cd7e459 (ping-app-2b) | us-west-2b | 10.0.11.0/24 | payment 10.0.11.181 (i-07a4fbaa2980a6904), audit 10.0.11.192 (i-09e47f349f831a7ac) **← netem loss** |
| subnet-048815f90d9293828 (ping-app-2c) | us-west-2c | 10.0.12.0/24 | payment 10.0.12.186 (i-038d0c9f83638fcc1), audit 10.0.12.78 (i-0fb0f7a36c567d972) |

checkout (i-07334e30db77c8da8, 10.0.6.247) and inventory (i-0b02004536f14e479, 10.0.6.157)
are in the obs subnet `subnet-002be9598dad093c4` (us-west-2a, 10.0.6.0/24).

All 8 are tagged `purpose=ping-demo` (+ `ping-role`). Each runs `ping-collector` +
`ping-app-svc`; checkout also `ping-traffic`.

## Routing

- checkout → payment: **random** across the 3 payments (fan-out).
- payment → audit: **same-AZ** (payment runs with `PREFER_SAME_AZ=1`; each payment calls only
  the audit in its own subnet/AZ). Verified: audit-2b only receives from payment-2b, etc.

## Discovery — Route 53 private zone `ping.internal` (`Z097757611V01PJRE00N6`)

`payment.ping.internal` → 10.0.10.246 / 10.0.11.181 / 10.0.12.186 (multivalue);
`audit.ping.internal` → 10.0.10.5 / 10.0.11.192 / 10.0.12.78; `inventory` → 10.0.6.157;
`checkout` → 10.0.6.247.

## Collector image

`ghcr.io/wangzlei/obi-collector:f5027fd` (retagged `obi-collector:ping`; public, multi-arch).
Rebuild: `gh workflow run "Build artifacts (obi + collector)" --repo wangzlei/opentelemetry-ebpf-instrumentation --ref demo/ping`.

## NFM (Network Flow Monitor)

Enabled on all 8 (SSM Distributor install + activate). Scope id
`c3ef8975-a420-4029-a972-6ac74d688422`. Instance role
`Ec2DemoObservability-ObsInstanceRoleD741B38A-...` has
`CloudWatchNetworkFlowMonitorAgentPublishPolicy` (+ `AWSXRayDaemonWriteAccess`). No monitor
created yet (Workload insights only; create a monitor for RTT/NHI CloudWatch metrics).

## ACTIVE FAULT (remove to return to baseline)

`netem loss 25%` on `ens5` of the **2b subnet** instances — payment-2b
`i-07a4fbaa2980a6904` and audit-2b `i-09e47f349f831a7ac`:
```bash
aws ssm send-command --region us-west-2 --targets Key=InstanceIds,Values=i-07a4fbaa2980a6904,i-09e47f349f831a7ac \
  --document-name AWS-RunShellScript --parameters 'commands=["tc qdisc del dev ens5 root"]'
```
Current effect: payment-2b (10.0.11.181) server p99 ~22s vs ~1s for 2a/2c; audit-2b server
~normal; NFM Workload insights RETRANSMISSIONS top-contributor = subnet-04ed7b4596cd7e459.

## Common ops

```bash
aws ssm start-session --target <id>
aws ssm send-command --targets Key=tag:purpose,Values=ping-demo --document-name AWS-RunShellScript --parameters 'commands=["docker ps"]'
```
Config at `/opt/ping/collector-config.yaml` (mounted into collector); app files `/opt/ping/app`.

## Teardown

```bash
IDS=$(aws ec2 describe-instances --region us-west-2 --filters Name=tag:purpose,Values=ping-demo \
  Name=instance-state-name,Values=running --query 'Reservations[].Instances[].InstanceId' --output text)
aws ec2 terminate-instances --region us-west-2 --instance-ids $IDS
# then delete subnets 021e/04ed/0488 + route table rtb-01a1e5ac8d3313dc3, Route 53 zone, SG (optional)
```
8× t3.medium run continuously; NFM active agents incur cost.
