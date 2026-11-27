# Dependencies

Template: none
Changes land by: push to main
Checks: (cd tui && test -z "$(gofmt -l .)" && go vet ./... && go test ./...) && shellcheck -x -S warning deploykit.sh lib/*.sh stages/*.sh drivers/*.sh bin/*.sh bin/deploykit scripts/*.sh test/run.sh test/stubs/* && bash test/run.sh

## Held back

| Upgrade | Why | Revisit when |
| --- | --- | --- |

## Notes

- Never run `scripts/release.sh` from an update, not even `--dry-run`: a release is the owner's to make. An update's commits stay under `## Unreleased` in CHANGELOG.md, which becomes the release's notes.
- The apps pin the kit by tag (`github:SeligLabs/deploykit#v<version>`), so they move only to a released tag, never to an unreleased commit.
- A dependency update leaves CONTRACT.md alone: any change there is a major.
- The Go version has one source, the `go` line in `tui/go.mod` (CI reads it with `go-version-file`).
- `github.com/rivo/uniseg` rides an untagged commit because bubbles 2.2.2 requires it, and `github.com/charmbracelet/ultraviolet` has no tags at all: let `go get` and `go mod tidy` choose both.
- `go list -m -u all` also names modules that aren't in `tui/go.mod` (other modules' test dependencies: `x/exp/golden`, `go-udiff`, `bitset`, `go-humanize`, `golang.org/x/exp`). The build doesn't use them; there is nothing to move.
- `bash test/run.sh` deploys nothing, but on a machine with a Gradle under `~/.gradle/wrapper/dists` its Android preflight runs that Gradle's `--status` and `--stop` (the kit's daemon stop: idle daemons on the machine end, busy ones are spared). With `HOME` pointed at an empty folder it stays inside its scratch copy.

## Log

- 2026-11-27: routine (bubbles 2.2.2, `x/ansi` 0.11.10, current `ultraviolet` and `uniseg`).
