# shellcheck shell=bash
# A static site's publish to S3 behind CloudFront: the one implementation,
# used by the site driver (a deploy's Web targets) and `deploykit
# publish-site` (an app's CI). The caller has built it.

# dk_site_sync <out> <bucket> <distribution id or ""> <immutable dir> [<keep pattern> ...]
#   Content-hashed assets under <immutable dir> (_next/static) are cached
#   for a year; everything else must revalidate, so a deploy shows up at
#   once. --delete removes what the build no longer has, except the keep
#   patterns (files another owner, such as Terraform, puts in the bucket).
#   Then CloudFront's cache is cleared.
dk_site_sync() {
  local out=$1 bucket=$2 distribution=$3 immutable=$4 pattern
  local -a exclude=()
  shift 4
  [[ -d "$out" ]] || die "No $out to publish: build it first."
  step Upload "Upload to s3://$bucket"
  spinner_label "uploading"
  if [[ -n "$immutable" && -d "$out/$immutable" ]]; then
    aws s3 sync "$out/$immutable" "s3://$bucket/$immutable" \
      --cache-control "public,max-age=31536000,immutable"
    exclude+=(--exclude "$immutable/*")
  fi
  for pattern in "$@"; do exclude+=(--exclude "$pattern"); done
  aws s3 sync "$out" "s3://$bucket" --delete ${exclude[@]+"${exclude[@]}"} \
    --cache-control "public,max-age=0,must-revalidate"
  step Invalidate "Clear the CloudFront cache"
  [[ -z "$distribution" ]] || aws cloudfront create-invalidation --distribution-id "$distribution" --paths "/*" >/dev/null
}
