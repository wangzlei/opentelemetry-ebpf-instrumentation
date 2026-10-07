#!/usr/bin/env bash
# Run ci/run.sh on the Linux dev desktop from a Mac: sync this repo (incl. the
# upstream submodule git dir) and the cwagent checkout, run, copy logs back.
#   DEVDSK=<host> CWAGENT=<local cwagent checkout> ci/run-remote.sh [stage ...]
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
H=${DEVDSK:?set DEVDSK=<linux build host> (ssh-reachable)}
CW=${CWAGENT:-"$ROOT/../adot-obi-work/cwagent"}
R=${REMOTE_DIR:-adot-obi-work}
rsync -a --delete --exclude build --exclude ci/logs "$ROOT/" "$H:$R/adot-obi/"
rsync -a --delete --exclude .git "$CW/" "$H:$R/cwagent/"
ssh "$H" "cd $R/adot-obi && CWAGENT=$R/cwagent ${GOPROXY:+GOPROXY=$GOPROXY} ${GOSUMDB:+GOSUMDB=$GOSUMDB} ci/run.sh $*" ; rc=$?
rsync -a "$H:$R/adot-obi/ci/logs/" "$ROOT/ci/logs/"
exit $rc
