# SSM Distributor package: ADOT-CloudWatchAgent-eBPF-Beta

The scripts and manifest of the Distributor package (account 292779133546,
us-west-2, shared with 868155213681). Each arch zip contains
`amazon-cloudwatch-agent.rpm` (built from the cwagent branch with `cwagent/0*.patch`)
plus `install.sh` and `uninstall.sh` from this directory.

- Install without arguments: behaves like the official CloudWatch Agent package
  (installs, does not start, no eBPF).
- Install with Additional Arguments `{"SSM_EBPF":"true"}`: installs and starts the
  agent with eBPF (`amazon-cloudwatch-agent-ctl -a enable-ebpf`). Distributor passes
  each key, which must start with `SSM_`, as an environment variable.
- A version change in Distributor is uninstall (old package's uninstall.sh, full
  `rpm -e`) then install, so the eBPF choice is carried across via
  `etc/ebpf/enabled.reinstall` (and `etc/restart`), like the official package.

Publish: zip each arch (`zip -X <zip> amazon-cloudwatch-agent.rpm install.sh uninstall.sh`),
update `version` and the sha256 values in manifest.json, upload the zips to
`s3://adot-obi-distributor-292779133546-usw2/<version>/`, then
`aws ssm update-document --name ADOT-CloudWatchAgent-eBPF-Beta --document-version '$LATEST' ...`
and `update-document-default-version`. versionName cannot contain `+`.
