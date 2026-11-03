# shellcheck shell=bash disable=SC2034 # globals read by deploy.sh
# Release: push the release commit, tag v<version>+<build> and create the
# GitHub release, as the release job in .github/workflows/ci.yml does, with
# notes from the changes since the last release (stages/notes.sh). Each step
# checks origin first, so re-running after a failure only does what is left.
# gh finds the repository from the origin remote.

RELEASE_RESULT=""

release_stage() {
  if ((RELEASED)); then
    stage_skip Release "tag $TAG already exists"
    RELEASE_RESULT="tag $TAG already existed"
    return 0
  fi
  if [[ "$BUMP" == skip || "$BUMP" == drop ]]; then
    stage_skip Release "skipped as chosen: no tag for $TAG"
    RELEASE_RESULT="not released (skipped)"
    return 0
  fi
  stage Release

  step Push "Push main"
  git -C "$ROOT" fetch --quiet origin main
  if git -C "$ROOT" merge-base --is-ancestor HEAD origin/main; then
    echo "origin/main already has $(git -C "$ROOT" rev-parse --short HEAD)."
  else
    # Only chore(release) commits can be ahead (Preflight), and they carry
    # [skip ci], so this doesn't start the Actions deploy.
    git -C "$ROOT" push origin HEAD:main
  fi

  step Tag "Tag $TAG"
  if tag_exists "$TAG"; then
    echo "origin already has $TAG."
  else
    git -C "$ROOT" tag -f "$TAG" HEAD
    git -C "$ROOT" push origin "refs/tags/$TAG"
  fi

  step GitHub "GitHub release"
  if gh release view "$TAG" >/dev/null 2>&1; then
    echo "Release $TAG exists."
  else
    notes_generate "$VERSION" "$BUILD" "$TAG" >"$WORK/release-notes.md"
    gh release create "$TAG" --verify-tag \
      --title "v$VERSION ($BUILD)" --notes-file "$WORK/release-notes.md"
  fi
  RELEASE_RESULT="released $TAG"
}
