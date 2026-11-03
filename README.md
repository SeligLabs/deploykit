# deploykit

The shared deploy engine for SeligLabs apps. An app declares what it ships, as groups of targets, and the hooks only it needs. The kit runs the deploy:
- the checklist, the version and one Start
- every target's lane, beside the plan and Lint
- the gate after Infra, the publishes and the release
- the deploy UI over all of it

Start with [CONTRACT.md](CONTRACT.md).

## Using it in an app

1. `package.json`: `"@seliglabs/deploykit": "github:SeligLabs/deploykit#v0.0.1"` and `"deploy": "bash scripts/deploy/deploy.sh"`.
2. CI: a read-only deploy key on this repo, added to the app's repo as the secret `DEPLOYKIT_SSH_KEY`, and before `yarn install`:

   ```yaml
   - uses: webfactory/ssh-agent@v0.9.1
     with: { ssh-private-key: "${{ secrets.DEPLOYKIT_SSH_KEY }}" }
   ```

3. `scripts/deploy/deploy.sh` (CONTRACT.md, "An app's deploy") and `scripts/checks.list` (CONTRACT.md, "Checks").
4. On each machine, `env/release.env` (from `env/release.env.example`). `yarn deploy settings` shows what's missing.

## Working on the kit

- `DEPLOYKIT_DEV=../deploykit yarn deploy demo` points an app at this checkout.
- `bash test/run.sh` runs the scenarios against `test/fixture` with stub tools.
- `cd tui && go test ./...` runs the UI's tests.
- To release: write what changed under `## Unreleased` in CHANGELOG.md, then `bash scripts/release.sh [patch|minor|major|<x.y.z>]` (no argument: package.json's version, when it isn't tagged yet). It checks git, runs every check and the scenarios, commits `Release v<version>`, asks once, then tags, pushes and creates the GitHub release. `--dry-run` does the checks and changes nothing. Then bump each app's dependency to the new tag.
