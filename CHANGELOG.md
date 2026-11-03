# Changelog

Semver. A change to anything in CONTRACT.md is a major (API) change: `DK_API` goes up and the entry says how to move. New work goes under `## Unreleased`; `bash scripts/release.sh` turns that into the release's heading.

## 0.0.2 (2026-11-03)

- **Fix:** a fastlane target with no `--env` printed the whole environment (secrets included) into its lane log at Prepare. Every app on 0.0.1 should move to this release before its next store deploy; delete `apps/*/build/deploy-*.log` and `~/.cache/<slug>/deploy-logs/` from runs made on 0.0.1.

## 0.0.1 (2026-11-03)

The first kit, from freebox's deploy of 2026-11-03 (itself merged with iris's of the same day):

- **The engine:**
  - groups and targets (`dk_group`, `dk_target`) with one lifecycle (build, gate, publish), each target its own lane
  - the commands `yarn deploy [<group>[:<target>] | infra | settings | demo]`
  - one sitting at the start, ending in Start with the plan and the store note
  - the bump taken back on a Cancel or a failed Lint
  - one deploy at a time per machine
- **The grouped checklist**, in the plain prompts and the deploy UI.
- **Drivers:** `site` (S3 + CloudFront), `fastlane` (TestFlight, Play, App Store Connect), `fn` (the app's own).
- **Stages:** Preflight, Version, Notes, Lint (over the app's check list), Infra (Terraform with hooks; secrets only in the plan's thread), Release.
- **Settings:** normalized names; sources are the environment, aliases, a hook, files, and defaults.
- **The deploy UI** (Go, Bubble Tea): stages, steps, lanes, time left, the output paged by thread, a finished panel, notifications.
- **`deploykit`:** `checks`, `aws-session`, `tui-build`, `version`.
