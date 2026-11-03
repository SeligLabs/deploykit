# The deploykit contract (API 1)

Everything an app may declare, configure, hook into and rely on. Anything not here is the kit's to change. A change to anything here is a breaking release: `DK_API` goes up, and CHANGELOG.md carries the migration.

## An app's deploy

`scripts/deploy/deploy.sh` sources the kit, declares, and calls `dk_main`:

```bash
#!/usr/bin/env bash
DK="${DEPLOYKIT_DEV:-$(dirname "$0")/../../node_modules/@seliglabs/deploykit}"
source "$DK/deploykit.sh"

dk_config api 1 env_loader "bash scripts/with-env.sh" version_cmd "node scripts/version.mjs"

dk_group web "Web"
dk_target web app --driver site --label "app.example.com   the web app" \
  --build "yarn turbo run build --filter=@repo/web" --out apps/web/out \
  --bucket WEB_BUCKET --distribution WEB_DISTRIBUTION_ID --url WEB_URL

dk_group mobile "Mobile"
dk_target mobile ios --driver fastlane --platform ios --dir apps/mobile \
  --artifact "apps/mobile/build/deploy/{slug}.ipa" --lock xcode --reuse \
  --prepare "dk_expo_prebuild ios @repo/mobile" --waits-for outputs

outputs_ready() { [[ -n "${API_URL:-}" ]]; }

dk_main "$@"
```

`package.json` has one script, `"deploy": "bash scripts/deploy/deploy.sh"`. `DEPLOYKIT_DEV=../deploykit` points the app at a working copy of the kit.

## Commands

| Command | Runs |
| --- | --- |
| `yarn deploy` | the grouped checklist (API + Infra, every group and target, Release), the version, then Start with the plan and the store note; then everything ticked, nothing asked |
| `yarn deploy <group>` | that group's targets: Preflight, Start, build and publish. No version change, no Infra |
| `yarn deploy <group>:<target>` | one target, the same way |
| `yarn deploy infra [plan args]` | Preflight → API → Infra, with a `[y/n]` before the apply |
| `yarn deploy settings` | every setting the declared targets need, its value (masked) and source, or what's missing (exit 1) |
| `yarn deploy demo` | this app's targets through the engine and the UI, touching nothing |
| `yarn deploy help` | the app's groups and targets |

In a terminal every run is under the deploy UI. Set `DEPLOY_TUI=0` for the plain output, and `DEPLOY_NOTIFY=0` to turn off the macOS notification at the end. `DEPLOY_SKIP_GIT_CHECK=1` skips the origin/main check, for testing on a branch only.

## Config: `dk_config <key> <value> ...`

| Key | Default | Meaning |
| --- | --- | --- |
| `api` | (required) | the API the app is written for; must equal the kit's |
| `env_loader` | none | a command line the deploy re-runs itself under to load the app's env files, e.g. `env APP_ENV=prod bash scripts/with-env.sh` |
| `reload_env` | none | env files read again, over the shell, after the apply has synced outputs into them (or define `reload_env_hook`) |
| `slug`, `name`, `bundle_id` | package.json `app.slug`, `app.displayName`, `app.bundleId` | the app's names |
| `aws_profile` | none | AWS_PROFILE when the environment has none |
| `version_cmd` | `node scripts/version.mjs` | `<build\|patch\|minor\|major> [--breaking]` or `set <version> <build> [--breaking]`, writing package.json `version` and `build` |
| `version_files` | `package.json` | what the bump commit adds |
| `min_build` | `no` | `yes`: a bump asks whether it breaks older builds (`--breaking`), when API + Infra is ticked |
| `checks` | `scripts/checks.list` | the check list (see Checks) |
| `lint` | `yes` | `no`: no Lint stage |
| `release` | `yes` | `no`: no Release stage (push main, tag `v<version>+<build>`, GitHub release) |
| `release_default`, `infra_default` | `on` | `off`: start unticked in the checklist |
| `infra_dir` | none | Terraform's directory; without it there is no Infra |
| `infra_label` | `build the API, terraform plan + apply` | its checklist text |
| `state_bucket` | none | the S3 backend bucket (`{slug}` is replaced), for `release_own_lock` and `state_bucket_ensure` |
| `state_key` | `prod.tfstate` | the state object's key |
| `tf_parallelism` | 30 | Terraform's `-parallelism` |
| `settings_files` | `env/release.env` | where settings are read from (see Settings) |

## Groups and targets

```bash
dk_group <group> <label>
dk_target <group> <id> --driver site|fastlane|fn [--<option> <value> | --<flag>] ...
```

Group ids and target ids are lowercase words, and a target's id is unique in the app. Ticking a group ticks its targets, and each target can still be unticked on its own. Every target follows one lifecycle in a background lane of its own, whatever its driver:

```text
build (check → prepare → build → verify)  ── gate ──  publish
```

- In `yarn deploy`, the gate opens once Infra is out (Lint has passed by then).
- In a group or single-target command, the gate is open from the start.
- A lane that finds nothing to publish (the store already has this build) hands its result back without waiting.

**Options every driver reads:**
- `--name <Name>`: the tracker's stage name. The defaults are iOS, Android, tvOS, AndroidTV, macOS and MSStore for those ids, else the id itself.
- `--label <text>`: the checklist's text.
- `--default off`: start unticked.
- `--waits-for outputs`: the lane starts only once `outputs_ready` says Infra's outputs exist. On a first deploy it starts after the apply, and a single-target command stops instead.
- `--steps "<A B ...>"`: replaces the driver's steps. Keep `Gate`; hooks may `step` the extra ones.
- `--log <path>`: the lane's log.
- `--tools "<cmd ...>"`: extra tools Preflight requires.

### Driver `site`: a static export to S3 behind CloudFront

- `--build "<command>"`: run from the app's root.
- `--out <dir>`: where the build writes.
- `--bucket`, `--distribution` and `--url`: the names of environment variables, read at publish time.
- `--keep "<pattern ...>"`: excluded from `--delete`.
- `--immutable <dir>`: default `_next/static`, cached for a year.
- `--early`: build beside Lint. By default the site builds after the gate.

Steps: `Gate Build Upload Invalidate`.

### Driver `fastlane`: a store build through the app's Fastfile

- `--platform ios|tvos|android|mac`
- `--dir <fastlane's directory>`
- `--artifact <path>`: `{slug}` is replaced.
- `--prepare "<command>"`, for example `dk_expo_prebuild <platform> <workspace> [VAR=value ...]`, which takes turns on the prebuild lock.
- `--lock xcode|gradle`
- `--play`: Play's checks and uploads take turns.
- `--reuse`: keep the artifact with a `.meta.json` recording version, build, commit, env and embedded values, and reuse it on a later run.
- `--embeds "<VAR ...>"`: values the build must contain.
- `--env "<VAR=value ...>"`
- `--gemfile <path>`
- `--version-offset <n>`
- `--bundle-id <id>`
- `--upload-key settings|none`
- `--progress "<regex>"`

Steps: `Check Prepare Build Verify Gate Upload`.

**The Fastfile contract.** In `--dir`, under `platform :<platform>`, the Fastfile has three lanes:
- `check_build [version:<v>] build:<b> out:<file>` writes `<state> <latest>` on the file's first line. The state is one of `new`, `uploaded`, `behind` or `rejected`, and a rejected build's reasons follow, one per line. Android lanes take no version.
- `build` makes `--artifact`.
- `upload ipa:|aab:|pkg:<artifact> changelog_file:<file>`.

Lanes read their settings from `ENV` (the kit exports them), get no stdin, and run with `FASTLANE_SKIP_UPDATE_CHECK=1`.

**What the kit verifies:**
- **ios and tvos:** the platform (`iphoneos` or `appletvos`), the bundle id, the version and build, and `--embeds`.
- **android:** the upload key's signature (unless `--upload-key none`) and `--embeds`.
- **mac:** only the app's `<id>_verify`.

### Driver `fn`: the app's own functions

- `<id>_build`: in the lane, before the gate. Call `dk_result <id> "<text>"` when there is nothing to publish.
- `<id>_publish`: after the gate, ending with `dk_result`.
- Options: `--steps` (default `Build Gate Publish`), `--needs-aws yes`, `--note yes` (takes the store note), `--reuses yes`.

## Hooks: optional functions the app defines

The engine calls each hook only when the app has defined it.

| Hook | Runs | Use |
| --- | --- | --- |
| `outputs_ready` | Preflight, the lanes | true once Infra's outputs exist |
| `reload_env_hook` | after the apply, at the gate | re-read env files, re-export copies |
| `settings_source_hook <NAME>` | settings lookups | print a value (keychain, 1Password) |
| `infra_preflight_hook` | Preflight, before the plan | `state_bucket_ensure` |
| `infra_build_hook` | a thread, before the plan | build the API |
| `infra_secrets_hook` | inside the plan thread only | export `TF_VAR_*` (never seen by Lint) |
| `infra_init_hook` | after `terraform init`, in `infra_dir` | `state_bucket_adopt` |
| `infra_check_hook` | after the plan, before Start | stop on a plan you refuse (`dk_plan_json`) |
| `after_apply_hook` | after the apply | sync outputs into env files |
| `summary_hook` | Start | extra lines |
| `<id>_preflight` | Preflight | the target's own setup checks |
| `<id>_check <version> <build>` | Preflight (a thread) | an extra store check |
| `<id>_after_prepare` | lane, after Prepare | check the generated project |
| `<id>_before_build` | lane, inside the build lock | tests before the build (`step` an extra step) |
| `<id>_after_build` | lane, after Build | copy a second artifact out |
| `<id>_verify <app dir or unzipped>` | lane, Verify | the app's own checks of the artifact |
| `<id>_before_publish` | lane, after the gate | anything before the upload |
| `<id>_after_publish` | foreground, after the lanes join | a note to the person deploying |
| `<id>_summary` | Start | the target's line |

Helpers an app may call: `step`, `step_mark`, `spinner_label`, `progress_total`, `progress_set`, `thread_run`, `with_lock`, `dk_result`, `dk_setting`, `dk_setting_path`, `dk_expo_prebuild`, `state_bucket_ensure`, `state_bucket_adopt`, `dk_plan_json`, `dk_plist`, `die`, `warn`, `confirm`. Variables an app may read: `ROOT`, `WORK`, `VERSION`, `BUILD`, `TAG`, `NOTES_FILE`, `APP_SLUG`, `APP_NAME`, `APP_BUNDLE_ID`, `DO_INFRA`, `DO_RELEASE`. Any kit function can be redefined after `source` as a last resort, at the app's own risk across upgrades.

## Settings

`dk_setting <NAME>` returns the first value it finds, from:
1. the environment
2. an alias's old name (`dk_alias NAME OLD ...`, which warns once per run)
3. `settings_source_hook NAME`
4. `settings_files`
5. the declared default

Paths are taken relative to the app's root, and `~` is expanded. Drivers declare what they need, and Preflight requires it for ticked targets only.

| Name | For | freebox (old) | iris (old) | template-app (old) |
| --- | --- | --- | --- | --- |
| `APP_STORE_CONNECT_API_KEY_ID` | Apple targets | same | `APP_STORE_CONNECT_API_KEY_KEY_ID` | same |
| `APP_STORE_CONNECT_API_KEY_ISSUER_ID` | Apple targets | same | same | same |
| `APP_STORE_CONNECT_API_KEY_PATH` | Apple targets (default `~/.appstoreconnect/private_keys/AuthKey_<ID>.p8`) | `APP_STORE_CONNECT_API_KEY_KEY_PATH` | `APP_STORE_CONNECT_API_KEY_KEY_FILEPATH` | `APP_STORE_CONNECT_API_KEY_KEY_PATH` |
| `APPLE_TEAM_ID` | Apple targets | same | — | same |
| `PLAY_JSON_KEY_PATH` | Android targets | `GOOGLE_PLAY_JSON_KEY_PATH` | `PLAY_SERVICE_ACCOUNT_JSON` | — |
| `ANDROID_UPLOAD_KEYSTORE_PATH`, `_KEYSTORE_PASSWORD`, `_KEY_ALIAS` (default `upload`), `_KEY_PASSWORD` | Android targets with `--upload-key settings` | same | `IRIS_UPLOAD_*` in `~/.gradle/gradle.properties` (`--upload-key none`) | — |

## Checks

The check list (`dk_config checks`) has one check per line, `name|lang|lock|command`; `#` comments and blank lines are skipped.

| Field | Values |
| --- | --- |
| `lang` | `js`, `go` or `tf`, the toolchain a CI runner needs; `local` stays out of CI's matrix |
| `lock` | `*` runs alone; any other word makes checks sharing it take turns; `-` runs beside anything |
| `command` | run by `bash -c` from the app's root; exit 77 means skipped |

`deploykit checks list|matrix|run <name>|run-all` runs the list. The app's CI builds its verify matrix from `matrix` and runs `run <name>`; the deploy's Lint stage runs `run-all`.

## What the UI reads (between the kit's own parts; listed for completeness)

Files under `$WORK`:
- `status/`: `stages`, `plan`, `mode`, `lanes_planned`, `bg/<Name>/`, `threads/<key>/`
- `ask/question` and `ask/answer-<id>`
- `<name>-result`, `lint/<check>.log` and `threads/<key>.log`

Elsewhere:
- timings: `~/.cache/<slug>/deploy-timings`
- logs: `~/.cache/<slug>/deploy-logs/`, keeping the last `DEPLOY_KEEP_LOGS`
