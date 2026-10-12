#!/usr/bin/env bash
# Publish a new version of the SSM Distributor package ADOT-CloudWatchAgent-eBPF-Beta
# (account 292779133546, us-west-2) from the Mac. Builds on the dev desktop.
#
#   distributor/publish.sh [--set-default] [--dry-run]
#
#   --set-default  make the new document version the default (what "Install" without a
#                  version, and the 868155213681 share via $DEFAULT, get)
#   --dry-run      check the local trees, dev-dsk connectivity and AWS credentials, pick the
#                  version name, print the plan; no copy, no build, no upload, no AWS write
#
# Steps:
#  0) local preflight: the cwagent worktree ($CWAGENT, default ../adot-obi-work/cwagent) must be
#     clean; version = 1.300074.0-obi.<cwagent short sha>
#  1) dev-dsk: ada credentials (Admin, 292779133546); pick a free versionName (adds -r<N> if the
#     name already exists in Distributor; versionName must match ^[a-zA-Z0-9_\-.]{1,128}$, no '+')
#  2) dev-dsk: current adot-obi tree via ci/run-remote.sh apply (tar copy + apply-patches.sh ->
#     build/obi), then generate the BPF bindings (scripts/generate-bpf.sh, SKIP_REPRO=1); the
#     cwagent go.mod replaces point at ../adot-obi/build/obi and ../adot-obi/receiver/obireceiver
#  3) dev-dsk: cwagent tree copied with tar over ssh (no .git, no build; NOT rsync: the Mac's
#     rsync silently skipped changed files), verified by sha256 of key files
#  4) dev-dsk: make package-rpm (log /tmp/cw-rpm.log); check RPM version + etc/ebpf payload
#  5) dev-dsk: stage zips in ~/distributor-pkg with install.sh/uninstall.sh from THIS repo,
#     write manifest.json
#  6) AWS: upload zips to s3://adot-obi-distributor-292779133546-usw2/<version>/,
#     ssm update-document (new version), wait Active, optional default; the share with
#     868155213681 is not touched. Writes the published manifest to distributor/manifest.json.
set -euo pipefail
T0=$SECONDS
trap 'rc=$?; echo; echo "total time: $(( (SECONDS-T0)/60 ))m$(( (SECONDS-T0)%60 ))s (exit $rc)"' EXIT

SET_DEFAULT=0 DRY=0
for a in "$@"; do
  case $a in
    --set-default) SET_DEFAULT=1;;
    --dry-run) DRY=1;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0;;
    *) echo "unknown argument: $a (usage: $0 [--set-default] [--dry-run])" >&2; exit 2;;
  esac
done

ROOT=$(cd "$(dirname "$0")/.." && pwd)          # adot-obi repo
DIST="$ROOT/distributor"
CW=${CWAGENT:-"$(cd "$ROOT/.." && pwd)/adot-obi-work/cwagent"}
H=${DEVDSK:-dev-dsk-wangzl-2b-8ea796f6.us-west-2.amazon.com}
R=adot-obi-work                                   # remote dir (relative to ~) used by ci/run-remote.sh
STAGE=distributor-pkg                             # remote staging dir (relative to ~)
PKG=ADOT-CloudWatchAgent-eBPF-Beta
ACCOUNT=292779133546 REGION=us-west-2 SHARE_ACCOUNT=868155213681
BUCKET=adot-obi-distributor-292779133546-usw2
BASE_VERSION=1.300074.0
KEY_FILES=(packaging/linux/amazon-cloudwatch-agent.spec
           packaging/dependencies/amazon-cloudwatch-agent-ebpf.yaml
           cmd/start-amazon-cloudwatch-agent/path.go)
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=15 -o LogLevel=ERROR "$H")
export COPYFILE_DISABLE=1 # no macOS ._* / xattr entries in the archives

step() { echo; echo "=== [$(date +%H:%M:%S) +$((SECONDS-T0))s] $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }
rsh() { "${SSH[@]}" "$@"; }
# remote aws with the ada credentials (default profile on dev-dsk)
raws() { rsh "AWS_REGION=$REGION AWS_PAGER= aws $(printf '%q ' "$@")"; }

# ---------------------------------------------------------------------------
step "0) local preflight"
[[ -d $CW/.git || -f $CW/.git ]] || die "cwagent worktree not found: $CW"
for f in install.sh uninstall.sh manifest.json; do [[ -f $DIST/$f ]] || die "missing $DIST/$f"; done
if [[ -n $(git -C "$CW" status --porcelain) ]]; then
  git -C "$CW" status --short | head -20
  die "cwagent tree $CW is dirty: commit or stash first (the version name is its HEAD sha)"
fi
CW_SHA=$(git -C "$CW" rev-parse --short=7 HEAD)
CW_BRANCH=$(git -C "$CW" branch --show-current || true)
OBI_SHA=$(git -C "$ROOT" rev-parse --short=8 HEAD)
OBI_DIRTY=$(git -C "$ROOT" status --porcelain --untracked-files=no -- . ':!distributor/manifest.json' | wc -l | tr -d ' ')
PATCH_SUM=$(cd "$ROOT" && shasum -a 256 patches/*.patch | shasum -a 256 | cut -c1-12)
echo "cwagent: $CW  branch=$CW_BRANCH HEAD=$CW_SHA ($(git -C "$CW" log -1 --format=%s))"
echo "adot-obi: $ROOT HEAD=$OBI_SHA patches-sha256=$PATCH_SUM ($(git -C "$ROOT" log -1 --format=%s))"
if [[ $OBI_DIRTY != 0 ]]; then
  echo "WARNING: adot-obi has $OBI_DIRTY uncommitted tracked change(s); the build uses the working tree as is:"
  git -C "$ROOT" status --short --untracked-files=no | head -20
fi
VERSION_BASE="$BASE_VERSION-obi.$CW_SHA"

# ---------------------------------------------------------------------------
step "1) dev-dsk $H: connectivity + AWS credentials"
rsh 'echo "host: $(hostname) $(uname -r)"; for t in go zip jq rpm rpm2cpio cpio sha256sum aws ada docker; do command -v $t >/dev/null || { echo "missing tool: $t"; exit 1; }; done; go version'
set +e
ADA_OUT=$(rsh "ada credentials update --account $ACCOUNT --role Admin --provider isengard --once" 2>&1); ADA_RC=$?
set -e
if [[ $ADA_RC != 0 ]]; then
  echo "$ADA_OUT" | tail -5
  if grep -qiE '401|midway|mwinit|unauthori[sz]ed|cookie' <<<"$ADA_OUT"; then
    die "Midway authentication failed on the dev desktop. Run 'mwinit' ON THE DEV-DSK ($H), not on the Mac, then re-run."
  fi
  die "ada credentials update failed on $H (rc=$ADA_RC)"
fi
ACCT=$(raws sts get-caller-identity --query Arn --output text)
echo "caller: $ACCT"
[[ $ACCT == *":$ACCOUNT:"* ]] || die "dev-dsk credentials are not for account $ACCOUNT"

EXISTING=$(raws ssm list-document-versions --name "$PKG" --query 'DocumentVersions[].[DocumentVersion,VersionName,Status]' --output text)
DEFAULT_BEFORE=$(raws ssm describe-document --name "$PKG" --query 'Document.[DefaultVersion,VersionName]' --output text | tr '\t' ' ')
echo "current versions (doc version, versionName, status):"; sed 's/^/  /' <<<"$EXISTING" | sort -n
echo "current default: $DEFAULT_BEFORE"
echo "share: $(raws ssm describe-document-permission --name "$PKG" --permission-type Share --query 'AccountSharingInfoList[].[AccountId,SharedDocumentVersion]' --output text | tr '\t\n' ': ') (left untouched)"
NAMES=$(awk '{print $2}' <<<"$EXISTING")
VERSION=$VERSION_BASE; N=2
while grep -qxF "$VERSION" <<<"$NAMES"; do VERSION="$VERSION_BASE-r$N"; N=$((N+1)); done
[[ $VERSION =~ ^[a-zA-Z0-9_.-]{1,128}$ ]] || die "invalid versionName: $VERSION"
RPM_VERSION=${VERSION//-/+}   # Tools/src/create_rpm.sh turns '-' into '+'
S3="s3://$BUCKET/$VERSION"
echo "new versionName: $VERSION   (RPM version $RPM_VERSION, S3 $S3/)"

if [[ $DRY == 1 ]]; then
  step "dry run: plan (nothing copied, built, uploaded or changed)"
  cat <<EOF
  2) DEVDSK=$H CWAGENT=$CW ci/run-remote.sh apply   # tar-copies adot-obi ($OBI_SHA) to ~/$R/adot-obi, apply-patches.sh -> build/obi
     ssh: cd ~/$R/adot-obi && SKIP_REPRO=1 scripts/generate-bpf.sh                   # BPF bindings into build/obi
  3) tar (excl .git, build) $CW -> $H:~/$R/cwagent; sha256 check: ${KEY_FILES[*]}
  4) ssh: GOPROXY=direct GOSUMDB=off GOTOOLCHAIN=local GOFLAGS=-mod=mod BS=~/$R/cwagent-rpm-build
          make package-rpm BUILD_SPACE=\$BS VERSION=$VERSION  > /tmp/cw-rpm.log
     check rpm -qp %{VERSION} == $RPM_VERSION; payload has etc/ebpf/obi.yaml + etc/ebpf/systemd-dropin.conf
  5) ~/$STAGE/stage/{x86_64,arm64}: rpm + install.sh/uninstall.sh from $DIST
     zip -q -X ~/$STAGE/amazon-cloudwatch-agent-ebpf-beta_{x86_64,arm64}.zip ...; manifest.json version=$VERSION
  6) aws s3 cp <zips> $S3/
     aws ssm update-document --name $PKG --content file://manifest.json \\
       --attachments Key=SourceUrl,Values=$S3 --version-name $VERSION --document-version '\$LATEST'
     wait Active$( [[ $SET_DEFAULT == 1 ]] && echo "; aws ssm update-document-default-version --name $PKG --document-version <new>" || echo "; default stays $DEFAULT_BEFORE (no --set-default)")
     write the published manifest to $DIST/manifest.json
EOF
  exit 0
fi

# ---------------------------------------------------------------------------
step "2) dev-dsk: current adot-obi tree -> build/obi (ci/run-remote.sh apply) + BPF generation"
DEVDSK=$H CWAGENT=$CW GOPROXY=direct GOSUMDB=off "$ROOT/ci/run-remote.sh" apply \
  || die "ci/run-remote.sh apply failed (see $ROOT/ci/logs/apply.log)"
rsh "cd $R/adot-obi && SKIP_REPRO=1 scripts/generate-bpf.sh > /tmp/obi-bpf.log 2>&1" \
  || { rsh 'tail -30 /tmp/obi-bpf.log' || true; die "BPF generation failed on $H (/tmp/obi-bpf.log)"; }
rsh 'tail -1 /tmp/obi-bpf.log'
OBI_REMOTE=$(rsh "cd $R/adot-obi && echo \"adot-obi \$(git rev-parse --short=8 HEAD)\$(git diff --quiet HEAD -- patches config receiver || echo ' (working tree differs from HEAD)'); build/obi: \$(git -C build/obi log --oneline -1)\"")
echo "obi used: $OBI_REMOTE"

# ---------------------------------------------------------------------------
step "3) cwagent tree -> $H:~/$R/cwagent (tar over ssh, no .git/build)"
rsh "rm -rf ~/$R/cwagent && mkdir -p ~/$R/cwagent"
tar -C "$CW" --no-xattrs --exclude ./.git --exclude ./build -czf - . | rsh "tar -C ~/$R/cwagent -xzf -"
LOCAL_SUMS=$(cd "$CW" && shasum -a 256 "${KEY_FILES[@]}")
REMOTE_SUMS=$(rsh "cd ~/$R/cwagent && sha256sum ${KEY_FILES[*]}")
echo "$REMOTE_SUMS" | sed 's/^/  remote /'
[[ $LOCAL_SUMS == "$REMOTE_SUMS" ]] || { echo "$LOCAL_SUMS" | sed 's/^/  local  /'; die "cwagent copy mismatch on $H"; }
LC=$(cd "$CW" && find . -path ./.git -prune -o -path ./build -prune -o -type f -print | wc -l | tr -d ' ')
RC=$(rsh "cd ~/$R/cwagent && find . -type f | wc -l")
[[ $LC == "$RC" ]] || die "cwagent file count differs: local $LC remote $RC"
echo "  key files identical, $LC files"

# ---------------------------------------------------------------------------
step "4) dev-dsk: make package-rpm VERSION=$VERSION (log /tmp/cw-rpm.log)"
rsh bash -s -- "$VERSION" "$RPM_VERSION" "$R" <<'EOF'
set -euo pipefail
VERSION=$1 RPM_VERSION=$2 R=$3
export GOPROXY=direct GOSUMDB=off GOTOOLCHAIN=local GOFLAGS=-mod=mod BS=$HOME/$R/cwagent-rpm-build
cd ~/$R/cwagent
rm -rf $BS/private; mkdir -p $BS/bin; rm -f $BS/bin/linux/*/amazon-cloudwatch-agent.rpm
start=$SECONDS
if ! make package-rpm BUILD_SPACE=$BS VERSION=$VERSION > /tmp/cw-rpm.log 2>&1; then
  echo "BUILD FAILED, last 40 lines of /tmp/cw-rpm.log:"; tail -40 /tmp/cw-rpm.log; exit 1
fi
echo "built in $((SECONDS-start))s"
for a in amd64 arm64; do
  f=$BS/bin/linux/$a/amazon-cloudwatch-agent.rpm
  [ -f "$f" ] || { echo "missing $f"; exit 1; }
  v=$(rpm -qp --qf '%{VERSION}' "$f" 2>/dev/null); arch=$(rpm -qp --qf '%{ARCH}' "$f" 2>/dev/null)
  [ "$v" = "$RPM_VERSION" ] || { echo "$f: version $v, expected $RPM_VERSION"; exit 1; }
  list=$(rpm2cpio "$f" | cpio -t --quiet)
  for p in etc/ebpf/obi.yaml etc/ebpf/systemd-dropin.conf; do
    grep -q "/opt/aws/amazon-cloudwatch-agent/$p\$" <<<"$list" || { echo "$f: $p missing from the payload"; exit 1; }
  done
  echo "  $a: $v $arch $(du -h "$f" | cut -f1), has etc/ebpf/obi.yaml + etc/ebpf/systemd-dropin.conf"
done
EOF

# ---------------------------------------------------------------------------
step "5) stage zips + manifest.json in $H:~/$STAGE"
rsh "mkdir -p ~/$STAGE/stage/x86_64 ~/$STAGE/stage/arm64 ~/$STAGE/scripts.new && rm -f ~/$STAGE/scripts.new/*"
tar -C "$DIST" --no-xattrs -czf - install.sh uninstall.sh | rsh "tar -C ~/$STAGE/scripts.new -xzf -"
SCRIPT_SUMS=$(cd "$DIST" && shasum -a 256 install.sh uninstall.sh)
rsh bash -s -- "$VERSION" "$R" "$STAGE" "$SCRIPT_SUMS" <<'EOF'
set -euo pipefail
VERSION=$1 R=$2 STAGE=$3 WANT=$4
BS=$HOME/$R/cwagent-rpm-build
cd ~/$STAGE
[ "$(cd scripts.new && sha256sum install.sh uninstall.sh)" = "$WANT" ] || { echo "install/uninstall.sh copy mismatch"; exit 1; }
if [ -f manifest.json ]; then
  old=$(jq -r .version manifest.json); [ -f "manifest.json.$old" ] || cp manifest.json "manifest.json.$old"
fi
for pair in amd64:x86_64 arm64:arm64; do
  a=${pair%%:*} d=${pair##*:}
  cp "$BS/bin/linux/$a/amazon-cloudwatch-agent.rpm" stage/$d/
  install -m 0755 scripts.new/install.sh scripts.new/uninstall.sh stage/$d/
  rm -f amazon-cloudwatch-agent-ebpf-beta_$d.zip
  (cd stage/$d && zip -q -X ../../amazon-cloudwatch-agent-ebpf-beta_$d.zip amazon-cloudwatch-agent.rpm install.sh uninstall.sh)
done
X=$(sha256sum amazon-cloudwatch-agent-ebpf-beta_x86_64.zip | cut -d' ' -f1)
A=$(sha256sum amazon-cloudwatch-agent-ebpf-beta_arm64.zip | cut -d' ' -f1)
jq -n --arg v "$VERSION" --arg x "$X" --arg a "$A" '{
  schemaVersion: "2.0", version: $v, publisher: "ADOT OBI (beta)",
  packages: {amazon: {_any: {
    x86_64: {file: "amazon-cloudwatch-agent-ebpf-beta_x86_64.zip"},
    arm64:  {file: "amazon-cloudwatch-agent-ebpf-beta_arm64.zip"}}}},
  files: {
    "amazon-cloudwatch-agent-ebpf-beta_x86_64.zip": {checksums: {sha256: $x}},
    "amazon-cloudwatch-agent-ebpf-beta_arm64.zip":  {checksums: {sha256: $a}}}}' > manifest.json
ls -la amazon-cloudwatch-agent-ebpf-beta_*.zip | awk '{print "  "$5"  "$9}'
for d in x86_64 arm64; do unzip -Z1 amazon-cloudwatch-agent-ebpf-beta_$d.zip | tr '\n' ' ' | sed "s/^/  $d: /"; echo; done
cat manifest.json
EOF

# ---------------------------------------------------------------------------
step "6) AWS: upload to $S3/ + update-document $PKG ($VERSION)"
rsh bash -s -- "$PKG" "$VERSION" "$S3" "$STAGE" "$REGION" <<'EOF'
set -euo pipefail
PKG=$1 VERSION=$2 S3=$3 STAGE=$4
export AWS_REGION=$5 AWS_PAGER=""
cd ~/$STAGE
for d in x86_64 arm64; do aws s3 cp --only-show-errors amazon-cloudwatch-agent-ebpf-beta_$d.zip "$S3/"; done
aws s3 ls "$S3/"
aws ssm update-document --name "$PKG" --content file://manifest.json \
  --attachments "Key=SourceUrl,Values=$S3" --version-name "$VERSION" --document-version '$LATEST' \
  --query 'DocumentDescription.[DocumentVersion,VersionName,Status]' --output text
EOF
NEW_DOC=$(raws ssm list-document-versions --name "$PKG" \
  --query "DocumentVersions[?VersionName=='$VERSION'].DocumentVersion | [0]" --output text)
[[ $NEW_DOC =~ ^[0-9]+$ ]] || die "could not find the document version for $VERSION"
for _ in $(seq 1 60); do
  ST=$(raws ssm describe-document --name "$PKG" --document-version "$NEW_DOC" --query Document.Status --output text)
  case $ST in
    Active) break;;
    Failed) die "document version $NEW_DOC failed: $(raws ssm describe-document --name "$PKG" --document-version "$NEW_DOC" --query Document.StatusInformation --output text)";;
  esac
  sleep 5
done
[[ $ST == Active ]] || die "document version $NEW_DOC still $ST after 5 min"
echo "doc version $NEW_DOC ($VERSION) is Active"
if [[ $SET_DEFAULT == 1 ]]; then
  raws ssm update-document-default-version --name "$PKG" --document-version "$NEW_DOC" \
    --query 'Description.[DefaultVersion,DefaultVersionName]' --output text
fi
rsh "cat ~/$STAGE/manifest.json" > "$DIST/manifest.json.new"
jq -e --arg v "$VERSION" '.version == $v' "$DIST/manifest.json.new" >/dev/null || die "bad manifest copied back"
mv "$DIST/manifest.json.new" "$DIST/manifest.json"
echo "wrote $DIST/manifest.json (commit it with the release)"

step "done"
echo "package:  $PKG ($ACCOUNT $REGION)"
echo "new:      doc version $NEW_DOC = $VERSION (RPM $RPM_VERSION) from cwagent $CW_SHA, $OBI_REMOTE"
echo "default:  $(raws ssm describe-document --name "$PKG" --query 'Document.[DefaultVersion,VersionName]' --output text | tr '\t' ' ')  (before: $DEFAULT_BEFORE)"
echo "share:    $(raws ssm describe-document-permission --name "$PKG" --permission-type Share --query 'AccountSharingInfoList[].[AccountId,SharedDocumentVersion]' --output text | tr '\t\n' ': ')"
[[ $SET_DEFAULT == 1 ]] || echo "not default yet: re-run with --set-default, or aws ssm update-document-default-version --name $PKG --document-version $NEW_DOC"
