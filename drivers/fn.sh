# shellcheck shell=bash
# The fn driver: a target the app builds and publishes with its own
# functions, for a kind of target no kit driver covers yet (a Mac app's DMG
# feed, a Microsoft Store package).
#
#   dk_target desktop macos --driver fn --label "the DMG feed and App Store Connect" \
#     --steps "Export Shell Package Gate Upload Store" --tools "bundle xcrun" --needs-aws yes --note yes
#
# The app defines, in its own files:
#   macos_build    in the lane, before the gate: build and verify; call
#                  dk_result macos "<text>" when there is nothing to publish
#   macos_publish  in the lane, after the gate; ends with dk_result
# and optionally macos_preflight and macos_check (in Preflight), and the
# hooks every target has (CONTRACT.md). The steps are --steps', in the order
# the functions call `step`; keep Gate where the lane waits.

dk_fn_steps() { echo "Build Gate Publish"; }
dk_fn_tools() { :; }
dk_fn_needs_aws() { dk_t "$1" needs_aws no; }
dk_fn_takes_note() { dk_t "$1" note no; }
dk_fn_reuses() { dk_t "$1" reuses no; }
dk_fn_summary() { dk_t "$1" label "after Infra"; }

dk_fn_build() {
  dk_has_hook "$1_build" || die "Target $1 (--driver fn) has no $1_build function."
  "$1_build"
}

dk_fn_publish() {
  dk_has_hook "$1_publish" || die "Target $1 (--driver fn) has no $1_publish function."
  "$1_publish"
  [[ -f "$(dk_result_file "$1")" ]] || dk_result "$1" "published"
}
