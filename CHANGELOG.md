# Changelog

Semver. A change to anything in CONTRACT.md is a major (API) change: `DK_API` goes up and the entry says how to move. New work goes under `## Unreleased`; `bash scripts/release.sh` turns that into the release's heading.

## 0.0.3 (2026-11-03)

The deploy reads Terraform's outputs live, and the scripts every app kept a copy of are the kit's.

- **Live outputs:** `dk_config outputs "API_URL=api_url ... NAME_*=map"`, read from the state in Preflight and after the apply (a data directory of its own, so no race with the plan or Lint), exported over the env files. `--waits-for outputs` waits on them by default, reading the state, not the shell; `NAME?=output` marks one optional (never waited on). An app's `outputs_ready`, `reload_env_hook` and env-sync-after-apply can go.
- **`yarn deploy env-sync`:** the same outputs into the env files for local dev (`outputs_files`), in place; replaces each app's `scripts/env-sync.mjs`.
- **`yarn deploy bump`** and the kit's version bump (`bin/version.mjs`), writing package.json and a committed native project's plist, pbxproj and build.gradle (`version_files`); `version_cmd` is now optional. Byte for byte what iris's `version.js` wrote.
- **`yarn deploy secrets`** and `dk_config tf_secrets`: Terraform's keychain secrets, loaded by the kit inside the plan's thread; replaces each app's `infrastructure/scripts/tf-secrets.sh`.
- **`deploykit publish-site`:** the site driver's S3 + CloudFront sync for an app's CI (one implementation, `lib/site.sh`); replaces each app's `apps/web/scripts/deploy.sh`.
- **`deploykit android-keystore`:** the one-time upload key, printing the `ANDROID_UPLOAD_*` lines for the app's base env file.
- **Settings live in the base env file:** `settings_files` defaults to `env/.env` (was `env/release.env`); the release settings sit with the rest of the machine's settings. An app reading `env/release.env` lists it in `settings_files`.
- **The deploy's own settings in deploy.sh:** `dk_config tui`, `notify`, `keep_logs` (the env still overrides for one run); `env_files` loads env files without a loader script.
- **`--tv`:** an Android TV bundle must declare leanback.

## 0.0.3 (unreleased)

New options; apps keep working:

- **The watch, as part of the iOS target:** `--watch <scheme>` runs the watch app's XCTests on a watchOS simulator before the archive and checks the watch app and its extensions in the archive (bundle ID, version and build). `--tests "<scheme ...>"` runs more XCTest schemes (widgets, say) on the platform's simulator, and `--extensions "<Name.appex ...>"` checks the app's own extensions. A `Tests` step comes before `Build` when either is set. An app's hand-written watch tests and archive checks can go.
- **Per-stage Terraform:** `dk_config tf_init_args` and `tf_plan_args`, expanded in the plan's thread (`-backend-config=key=$STAGE.tfstate`, `-var-file=environments/$STAGE.tfvars`). An app that redefined `infra_init` or `infra_plan_lane`, or set `TF_CLI_ARGS_*`, for this can declare it instead.
- **No version question for sites alone:** with only site targets ticked and Release unticked, `yarn deploy` keeps the version and asks nothing about it, as the apps' deploys did before the kit.
- **Locks:** `dk_config lint_lock <name>` holds a lock for Lint's whole run, and a site target's `--lock <name>` builds under it, for checks and builds that share a directory (iris's `apps/web/.next`).
- **`dk_config aws_region`:** the stack's region when the env files don't set it.
- **The SSO token outlives the deploy:** `bin/aws-session.sh` logs in again when the token has under `AWS_SESSION_MIN_SECONDS` (1800) left; the CLI's cached role credentials used to pass the check while Terraform's token lapsed mid-run.
- **Fix:** an old setting name in one settings file beat the new name in another; the new name in any file now comes first. The old-name warning came once per lookup; now once per run.
- **Fix:** `yarn deploy demo` wrote its pretend output over the app's real lane logs (`<dir>/build/deploy-<id>.log`); they now go to the demo's scratch cache.
- **Fix:** a missing `Payload/*.app` stopped Verify without a message (an empty glob under pipefail); it now says what's missing.

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
