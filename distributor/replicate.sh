#!/usr/bin/env bash
# Replicate the SSM Distributor package ADOT-CloudWatchAgent-eBPF-Beta from its home region
# (us-west-2, where publish.sh builds and publishes) to another region of account 292779133546,
# unchanged: same zips, same manifest, same versionName. Distributor documents are regional, so
# each region needs its own copy. Idempotent: a versionName already present is skipped.
#
#   distributor/replicate.sh <region> [--share <account-id>]...
#
#   default version of the home region -> s3://adot-obi-distributor-292779133546-<short>/<version>/
#   -> create-document (first time) or update-document (new version) -> make it the default.
#   --share adds account ids to the document's share list ($DEFAULT, i.e. always the default).
set -euo pipefail
export AWS_PAGER=""
unset AWS_PROFILE
PKG=ADOT-CloudWatchAgent-eBPF-Beta ACCOUNT=292779133546 HOME_REGION=us-west-2
HOME_BUCKET=adot-obi-distributor-$ACCOUNT-usw2
DST=${1:?usage: $0 <region> [--share <account-id>]...}; shift
SHARE=()
while [ $# -gt 0 ]; do case $1 in --share) SHARE+=("${2:?}"); shift 2;; *) echo "bad arg $1" >&2; exit 2;; esac; done
short() { echo "$1" | sed -E 's/^([a-z]{2})-([a-z])[a-z]*-([0-9])$/\1\2\3/'; }  # us-east-1 -> use1
BUCKET=adot-obi-distributor-$ACCOUNT-$(short "$DST")
log() { echo "[$(date +%H:%M:%S)] $*"; }
[ "$(aws sts get-caller-identity --query Account --output text)" = $ACCOUNT ] || { echo "wrong account"; exit 1; }
[ "$DST" != "$HOME_REGION" ] || { echo "$DST is the home region (use publish.sh)"; exit 1; }

read -r DOCV VERSION < <(aws ssm describe-document --region $HOME_REGION --name $PKG \
  --query 'Document.[DefaultVersion,VersionName]' --output text)
log "home $HOME_REGION default: doc $DOCV $VERSION"
TMP=$(mktemp -d); trap 'rm -rf $TMP' EXIT
aws ssm get-document --region $HOME_REGION --name $PKG --document-version "$DOCV" --query Content --output text > $TMP/manifest.json

if ! aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
  aws s3api create-bucket --bucket "$BUCKET" --region "$DST" \
    $([ "$DST" = us-east-1 ] || echo --create-bucket-configuration LocationConstraint=$DST) >/dev/null
  aws s3api put-public-access-block --bucket "$BUCKET" --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
  aws s3api put-bucket-encryption --bucket "$BUCKET" --server-side-encryption-configuration \
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
  aws s3api put-bucket-tagging --bucket "$BUCKET" --tagging 'TagSet=[{Key=purpose,Value=adot-obi-distributor}]'
  log "created bucket $BUCKET (private, SSE-S3)"
fi
aws s3 sync --only-show-errors --source-region $HOME_REGION "s3://$HOME_BUCKET/$VERSION/" "s3://$BUCKET/$VERSION/" --region "$DST"
aws s3 ls "s3://$BUCKET/$VERSION/" --region "$DST"

if ! aws ssm describe-document --region "$DST" --name $PKG >/dev/null 2>&1; then
  aws ssm create-document --region "$DST" --name $PKG --document-type Package --content file://$TMP/manifest.json \
    --attachments "Key=SourceUrl,Values=s3://$BUCKET/$VERSION" --version-name "$VERSION" \
    --tags Key=purpose,Value=adot-obi-distributor >/dev/null
  log "created $PKG in $DST"
elif [ "$(aws ssm list-document-versions --region "$DST" --name $PKG --query "length(DocumentVersions[?VersionName=='$VERSION'])")" = 0 ]; then
  aws ssm update-document --region "$DST" --name $PKG --content file://$TMP/manifest.json \
    --attachments "Key=SourceUrl,Values=s3://$BUCKET/$VERSION" --version-name "$VERSION" --document-version '$LATEST' >/dev/null
  log "new version $VERSION in $DST"
else
  log "$VERSION already in $DST"
fi
NEW=$(aws ssm list-document-versions --region "$DST" --name $PKG --query "DocumentVersions[?VersionName=='$VERSION'].DocumentVersion | [0]" --output text)
for _ in $(seq 1 60); do
  ST=$(aws ssm describe-document --region "$DST" --name $PKG --document-version "$NEW" --query Document.Status --output text)
  [ "$ST" = Active ] && break; [ "$ST" = Failed ] && { echo "doc $NEW failed"; exit 1; }; sleep 5
done
aws ssm update-document-default-version --region "$DST" --name $PKG --document-version "$NEW" >/dev/null 2>&1 || true
for a in "${SHARE[@]}"; do
  aws ssm modify-document-permission --region "$DST" --name $PKG --permission-type Share --account-ids-to-add "$a"
done
log "$DST: default $(aws ssm describe-document --region "$DST" --name $PKG --query 'Document.[DefaultVersion,VersionName,Status]' --output text)"
log "$DST: shared with $(aws ssm describe-document-permission --region "$DST" --name $PKG --permission-type Share --query 'AccountIds' --output text)"
