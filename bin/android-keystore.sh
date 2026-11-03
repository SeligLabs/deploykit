#!/usr/bin/env bash
# Creates an app's Android upload key, once, outside the repo. The owner
# runs it, from the app's root (`yarn deploykit android-keystore [<dir>]`):
#
#   <dir> defaults to ~/.<slug>/android, the slug being package.json's
#   app.slug. It writes <dir>/<slug>-upload.jks (an RSA 2048 key valid for 50
#   years, alias "upload"), prints the ANDROID_UPLOAD_* lines for
#   env/release.env and the SHA-256 fingerprint, and never touches the repo.
#   Keep a copy of the keystore and its password somewhere safe: with Play
#   App Signing this is only the upload key, so Google can reset it, but the
#   reset takes days.
#
# Refuses to overwrite an existing keystore.

set -euo pipefail

ROOT="${DK_APP_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
SLUG="$(node -p "(require('$ROOT/package.json').app || {}).slug || ''" 2>/dev/null)"
NAME="$(node -p "(require('$ROOT/package.json').app || {}).displayName || ''" 2>/dev/null)"
[[ -n "$SLUG" ]] || { echo "No app.slug in $ROOT/package.json: run this from the app's root." >&2; exit 1; }

DIR="${1:-$HOME/.$SLUG/android}"
KEYSTORE="$DIR/$SLUG-upload.jks"
ALIAS="upload"

command -v keytool >/dev/null 2>&1 || {
  echo "keytool isn't on PATH. It ships with the JDK Gradle uses (brew install --cask temurin)." >&2
  exit 1
}
if [[ -e "$KEYSTORE" ]]; then
  echo "$KEYSTORE already exists. Not overwriting it: a new upload key must be registered with Play first." >&2
  exit 1
fi

mkdir -p "$DIR"
chmod 700 "$DIR"

# One password for the store and the key: Play App Signing holds the real
# app key, and PKCS12 keystores can't tell the two apart anyway.
read -r -s -p "Password for the new keystore (12+ characters): " PASSWORD
echo
read -r -s -p "Again: " AGAIN
echo
[[ "$PASSWORD" == "$AGAIN" ]] || { echo "Passwords differ." >&2; exit 1; }
((${#PASSWORD} >= 12)) || { echo "Use at least 12 characters." >&2; exit 1; }

keytool -genkeypair -v \
  -keystore "$KEYSTORE" -storetype PKCS12 \
  -alias "$ALIAS" -keyalg RSA -keysize 2048 -validity 18250 \
  -storepass "$PASSWORD" -keypass "$PASSWORD" \
  -dname "CN=${NAME:-$SLUG} upload key, C=US" >/dev/null
chmod 600 "$KEYSTORE"

FINGERPRINT="$(keytool -list -v -keystore "$KEYSTORE" -alias "$ALIAS" -storepass "$PASSWORD" |
  sed -n 's/^[[:space:]]*SHA256: //p' | head -n 1)"

cat <<OUT

Created $KEYSTORE (alias $ALIAS).

1. Set these in env/release.env (git-ignored, never a committed file):

   ANDROID_UPLOAD_KEYSTORE_PATH=$KEYSTORE
   ANDROID_UPLOAD_KEYSTORE_PASSWORD=<the password>
   ANDROID_UPLOAD_KEY_ALIAS=$ALIAS
   ANDROID_UPLOAD_KEY_PASSWORD=<the password>

2. The upload key's SHA-256, which the deploy checks every bundle's signer
   against (yarn deploy settings shows the settings):

   $FINGERPRINT

3. Save the keystore file and the password somewhere safe.
OUT
