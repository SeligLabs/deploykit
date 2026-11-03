# shellcheck shell=bash
# The site driver: a static export, synced to an S3 bucket behind CloudFront.
#
#   dk_target web www --driver site --label "www.example.com  the marketing site" \
#     --build "yarn turbo run build --filter=@repo/www" --out apps/www/out \
#     --bucket WWW_BUCKET --distribution WWW_DISTRIBUTION_ID --url WWW_URL \
#     --keep ".well-known/*"
#
# --bucket, --distribution and --url name environment variables (an env sync
# after the apply fills them in), read at publish time, after the gate.
# --build runs after the gate too, from the app's root: the export embeds the
# deployed outputs, and building beside Lint would race Lint's own build in
# the same directory (turbo restores Lint's build when nothing changed).
# --early builds beside Lint instead, for a build that reads no outputs.
#
# Content-hashed assets (--immutable, default _next/static) are cached for a
# year; everything else must revalidate, so a deploy shows at once. --delete
# removes what the export no longer has, except --keep's patterns (files
# Terraform owns in the bucket, say). Then the whole distribution is cleared.

dk_site_steps() {
  if [[ "$(dk_t "$1" early)" == 1 ]]; then echo "Build Gate Upload Invalidate"; else echo "Gate Build Upload Invalidate"; fi
}
dk_site_tools() { echo aws; }
# A site has no version of its own: ticked alone, it asks none.
dk_site_versioned() { echo no; }
dk_site_needs_aws() { echo yes; }
dk_site_summary() {
  local url
  url="$(dk_t "$1" url)"
  echo "build and publish${url:+ ${!url:-}}${url:+,} after Infra"
}

dk_site_build() { [[ "$(dk_t "$1" early)" != 1 ]] || dk_site_make "$1"; }

# dk_site_make <id>: Build, into --out.
dk_site_make() {
  local id=$1 build out
  build="$(dk_t "$id" build)"
  out="$ROOT/$(dk_t "$id" out)"
  step Build "Build $(dk_t "$id" name)"
  spinner_label "building"
  if [[ -n "$build" && -n "$(dk_t "$id" lock)" ]]; then
    # --lock <name>: the build takes turns with whatever else holds it (Lint's
    # lint_lock, another target's export into the same directory).
    spinner_label "waiting for the $(dk_t "$id" lock) lock"
    with_lock "$(dk_t "$id" lock)" bash -c "cd '$ROOT' && $build" || die "The build failed ($build)."
  elif [[ -n "$build" ]]; then
    (cd "$ROOT" && bash -c "$build") || die "The build failed ($build)."
  fi
  [[ -d "$out" ]] || die "The build wrote no $out."
}

dk_site_publish() {
  local id=$1 out bucket distribution url immutable keep pattern
  local -a exclude=()
  [[ "$(dk_t "$id" early)" == 1 ]] || dk_site_make "$id"
  out="$ROOT/$(dk_t "$id" out)"
  bucket="$(dk_t "$id" bucket)"
  distribution="$(dk_t "$id" distribution)"
  url="$(dk_t "$id" url)"
  [[ -n "$bucket" && -n "${!bucket:-}" ]] ||
    die "${bucket:---bucket} is empty: deploy the infrastructure first (its outputs name the bucket)."
  immutable="$(dk_t "$id" immutable _next/static)"
  step Upload "Upload to s3://${!bucket}"
  spinner_label "uploading"
  if [[ -d "$out/$immutable" ]]; then
    aws s3 sync "$out/$immutable" "s3://${!bucket}/$immutable" \
      --cache-control "public,max-age=31536000,immutable"
    exclude+=(--exclude "$immutable/*")
  fi
  keep="$(dk_t "$id" keep)"
  for pattern in $keep; do exclude+=(--exclude "$pattern"); done
  aws s3 sync "$out" "s3://${!bucket}" --delete ${exclude[@]+"${exclude[@]}"} \
    --cache-control "public,max-age=0,must-revalidate"
  step Invalidate "Clear the CloudFront cache"
  if [[ -n "$distribution" && -n "${!distribution:-}" ]]; then
    aws cloudfront create-invalidation --distribution-id "${!distribution}" --paths "/*" >/dev/null
  else
    echo "No ${distribution:---distribution}: nothing to clear."
  fi
  if [[ -n "$url" && -n "${!url:-}" ]]; then
    dk_result "$id" "published to ${!url}"
  else
    dk_result "$id" "published to s3://${!bucket}"
  fi
}
