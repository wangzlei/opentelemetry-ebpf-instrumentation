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

Publish: `distributor/publish.sh [--set-default] [--dry-run]` (from the Mac). It takes the
clean cwagent worktree `../adot-obi-work/cwagent` (version `1.300074.0-obi.<cwagent sha>`, plus
`-r<N>` if that versionName already exists), syncs the current adot-obi tree to the dev desktop
(`ci/run-remote.sh apply` + BPF generation) and the cwagent tree (tar over ssh), runs
`make package-rpm` there, zips each arch with this directory's install.sh/uninstall.sh, uploads
to `s3://adot-obi-distributor-292779133546-usw2/<version>/`, adds the document version
(`aws ssm update-document ... --document-version '$LATEST'`), optionally makes it the default,
and writes the published manifest back to `manifest.json` (commit it). `--dry-run` only checks
the trees, ssh and credentials and prints the plan. The share with 868155213681 is not changed.
If ada fails with a Midway 401, run `mwinit` on the dev desktop. versionName cannot contain `+`.
