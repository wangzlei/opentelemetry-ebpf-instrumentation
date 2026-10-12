#!/usr/bin/env bash
# Run ci/run.sh on the Linux dev desktop from a Mac: copy this repo (incl. the
# upstream submodule git dir) and the cwagent checkout, run, copy logs back.
#   DEVDSK=<host> CWAGENT=<local cwagent checkout> ci/run-remote.sh [stage ...]
#
# Copies with tar over ssh, not rsync: the Mac's rsync silently skipped changed
# files (same size and mtime), so the remote ran stale code. Every run replaces
# the remote trees, keeping only adot-obi/build (outputs) and adot-obi/ci/logs.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
H=${DEVDSK:?set DEVDSK=<linux build host> (ssh-reachable)}
CW=${CWAGENT:-"$ROOT/../adot-obi-work/cwagent"}
R=${REMOTE_DIR:-adot-obi-work}
SSH=(ssh -o BatchMode=yes "$H")
export COPYFILE_DISABLE=1 # no macOS ._* / xattr entries in the archives
"${SSH[@]}" "set -e; mkdir -p $R/adot-obi $R/cwagent; cd $R/adot-obi
  find . -mindepth 1 -maxdepth 1 ! -name build ! -name ci -exec rm -rf {} +
  if [ -d ci ]; then find ci -mindepth 1 -maxdepth 1 ! -name logs -exec rm -rf {} +; fi
  rm -rf ~/$R/cwagent && mkdir -p ~/$R/cwagent"
tar -C "$ROOT" --no-xattrs --exclude ./build --exclude ./ci/logs -czf - . | "${SSH[@]}" "tar -C $R/adot-obi -xzf -"
tar -C "$CW" --no-xattrs --exclude ./.git -czf - . | "${SSH[@]}" "tar -C $R/cwagent -xzf -"
"${SSH[@]}" "cd $R/adot-obi && git -C . rev-parse --short HEAD && sha256sum patches/*.patch | sha256sum" | sed 's/^/remote: /'
( cd "$ROOT" && git rev-parse --short HEAD && shasum -a 256 patches/*.patch | shasum -a 256 ) | sed 's/^/local:  /' 
# Detached (nohup) and polled: a long ssh session to the dev desktop can be cut
# by the SSH proxy, which used to kill ci/run.sh halfway (e.g. during e2e).
"${SSH[@]}" "cd $R/adot-obi && mkdir -p ci/logs && rm -f ci/logs/run.rc && (CWAGENT=\$HOME/$R/cwagent ${GOPROXY:+GOPROXY=$GOPROXY} ${GOSUMDB:+GOSUMDB=$GOSUMDB} nohup bash -c 'ci/run.sh $*; echo \$? > ci/logs/run.rc' > ci/logs/run.out 2>&1 < /dev/null &)"
seen=0
while :; do
  sleep 20
  out=$("${SSH[@]}" "cd $R/adot-obi/ci/logs && tail -n +$((seen + 1)) run.out; echo; echo \"@@rc=\$(cat run.rc 2>/dev/null)\"" 2>/dev/null) || continue
  body=${out%@@rc=*}; body=${body%$'\n'}; body=${body%$'\n'}; rcl=${out##*@@rc=}
  if [[ -n $body ]]; then printf '%s\n' "$body"; seen=$((seen + $(printf '%s\n' "$body" | wc -l))); fi
  [[ -n ${rcl//[[:space:]]/} ]] && { rc=${rcl//[[:space:]]/}; break; }
done
mkdir -p "$ROOT/ci/logs"
"${SSH[@]}" "tar -C $R/adot-obi/ci/logs -czf - ." | tar -C "$ROOT/ci/logs" -xzf -
exit $rc
