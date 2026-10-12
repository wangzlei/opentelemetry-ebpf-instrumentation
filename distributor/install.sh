#!/bin/sh
# SSM Distributor install: CloudWatch Agent + ADOT OBI eBPF receiver (beta).
# By default this behaves like the official CloudWatch Agent package: it only
# installs (or upgrades) the RPM, and an agent that was running before an
# upgrade is restarted (prep-restart in uninstall.sh, cond-restart in the RPM).
# eBPF is opt-in: pass the Distributor additional argument {"SSM_EBPF":"true"}
# (AWS-ConfigureAWSPackage exposes it to this script as the env var SSM_EBPF)
# to install AND start the agent with eBPF, or run
#   amazon-cloudwatch-agent-ctl -a enable-ebpf
# later on the host. "-a disable-ebpf" turns it off.
# Distributor upgrades are uninstall + install, i.e. a full rpm erase (which
# drops the eBPF state), so uninstall.sh leaves etc/ebpf/enabled.reinstall and
# this script restores the marker from it BEFORE rpm -U: the RPM's %posttrans
# then installs the drop-in and restarts the agent with eBPF.
set -e
A=/opt/aws/amazon-cloudwatch-agent
CTL=$A/bin/amazon-cloudwatch-agent-ctl
KEEP=$A/etc/ebpf/enabled.reinstall
EBPF="${SSM_EBPF:-false}"
echo "SSM_EBPF=${EBPF}"

# Migration from the always-on versions (<= 1.300074.0-obi.e3a8675): their
# uninstall.sh stops and erases without leaving any state. If the agent's last
# start was unprivileged (only the eBPF drop-in does that) and eBPF was not
# turned off with the old etc/ebpf/disabled, keep eBPF on and running.
LOG=$A/logs/amazon-cloudwatch-agent.log
if ! rpm -q amazon-cloudwatch-agent >/dev/null 2>&1 && [ ! -f "$KEEP" ] && [ ! -f $A/etc/ebpf/disabled ] && [ -f "$LOG" ] &&
  grep -E "I! Detected runAsUser|not root: skipping run_as_user" "$LOG" | tail -1 | grep -q "not root: skipping run_as_user"; then
  echo "previous always-on eBPF install detected: keeping eBPF on"
  mkdir -p $A/etc/ebpf
  touch "$KEEP" $A/etc/restart
fi
rm -f $A/etc/ebpf/disabled
if [ -f "$KEEP" ]; then
  touch $A/etc/ebpf/enabled
  rm -f "$KEEP"
fi
# Migration: versions before 1.300074.0-obi.526f82c put the eBPF config in .d;
# with the RPM's etc/ebpf/obi.yaml it would start a second OBI receiver.
rm -f $A/etc/amazon-cloudwatch-agent.d/obi.yaml

rpm -U --replacepkgs ./amazon-cloudwatch-agent.rpm

if [ "${EBPF}" = "true" ]; then
  # Restarts the agent, or starts it (with the default config if none).
  $CTL -a enable-ebpf
  $CTL -a start
fi
$CTL -a status
