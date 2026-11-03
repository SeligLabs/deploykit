#!/usr/bin/env bash
# The fixture app's deploy: one of each kind of target, as a real app declares them.
DK="${DEPLOYKIT_DEV:?the tests point DEPLOYKIT_DEV at the kit}"
source "$DK/deploykit.sh"

dk_config api 1 env_loader "bash scripts/with-env.sh" version_cmd "node scripts/version.mjs" min_build yes \
  infra_dir infrastructure state_bucket "terraform-state-{slug}" reload_env "env/.env"

dk_group web "Web"
dk_target web app --driver site --label "app.example.com   the web app" --waits-for outputs \
  --build "mkdir -p apps/web/out/_next/static && echo app > apps/web/out/index.html" --out apps/web/out \
  --bucket WEB_BUCKET --distribution WEB_DISTRIBUTION_ID --url WEB_URL
dk_target web www --driver site --label "www.example.com   the marketing site" \
  --build "mkdir -p apps/www/out && echo www > apps/www/out/index.html" --out apps/www/out \
  --bucket WWW_BUCKET --keep ".well-known/*"

dk_group mobile "Mobile"
dk_target mobile ios --driver fastlane --platform ios --dir apps/mobile --artifact "apps/mobile/build/deploy/{slug}.ipa" \
  --lock xcode --reuse --prepare "dk_expo_prebuild ios @fixture/mobile" --waits-for outputs --embeds "API_URL" \
  --watch FixtureWatch --tests "FixtureWidgets" --extensions "FixtureWidgets.appex"
dk_target mobile android --driver fastlane --platform android --dir apps/mobile \
  --artifact apps/mobile/android/app-release.aab --lock gradle --play --waits-for outputs --embeds "API_URL"

dk_group tv "TV"
dk_target tv tvos --driver fastlane --platform tvos --dir apps/tv --artifact "apps/tv/build/deploy/{slug}-tv.ipa" \
  --lock xcode --env "EXPO_TV=1" --waits-for outputs
dk_target tv androidtv --driver fastlane --platform android --dir apps/tv --artifact apps/tv/android/app-release.aab \
  --lock gradle --play --version-offset 1000000 --env "EXPO_TV=1"

dk_group desktop "Desktop"
dk_target desktop macos --driver fn --label "the DMG feed" --steps "Package Gate Upload" --needs-aws yes

# An old name, read while the app moves to the normalized one.
dk_alias PLAY_JSON_KEY_PATH PLAY_SERVICE_ACCOUNT_JSON

# Hooks, as an app has them.
outputs_ready() { [[ -n "${API_URL:-}" ]]; }
infra_build_hook() { yarn workspace @fixture/api build; }
infra_secrets_hook() { export TF_VAR_push_key=secret-value; }
after_apply_hook() { echo "API_URL=https://api.example.invalid" >>"$ROOT/env/.env"; echo "synced"; }
ios_before_build() { echo "ios_before_build ran"; }
macos_build() { step Package "Package the Mac app"; echo "packaged"; [[ "${STUB_FAIL:-}" != macos ]] || die "macOS package failed (stub)"; }
macos_publish() { step Upload "Upload the DMG"; aws s3 cp mac.dmg s3://feed/; dk_result macos "DMG $VERSION ($BUILD)"; }
androidtv_after_publish() { echo "Fire TV: upload the APK by hand."; }

dk_main "$@"
