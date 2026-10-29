# Homebrew packaging

The cask ships from **github.com/campfireshuffle/homebrew-tap** (short name `campfireshuffle/tap`).

| file | what it is |
|---|---|
| `Casks/sturgeon.rb.in` | the template; `scripts/package.sh` fills `@@VERSION@@`, `@@SHA256@@`, `@@URL@@` |
| `Casks/sturgeon.rb` | generated: `url` points at the GitHub release `sturgeon-<version>-macos-arm64.zip`, with the sha256 of the **stapled** zip. Never edit by hand. |
| `Casks/sturgeon-local.rb` | generated for local proof: same cask with a `file://` URL |

`sturgeon.rb` is git-ignored because the tap is the source of truth; the release workflow writes the
version and sha256 there after notarization.

There is no formula. A formula installs command-line software into `/opt/homebrew`; Sturgeon is a
`.app` with one privileged setup step (`/Library/LaunchDaemons` and a sudoers rule), which formulae
do not do. The cask is the only supported install path.

## Release

1. Bump `CFBundleShortVersionString` and `CFBundleVersion` in `companion/Info.plist`.
2. Run the **Release** workflow with that version.
3. It signs and notarizes, staples, publishes the zip and its sha256, and opens a PR against the tap
   that updates the cask.

## Local proof

```sh
./scripts/build-helpers.sh
./scripts/package.sh 1.0.0 36            # unsigned unless SIGN_IDENTITY is set
brew install --cask ./homebrew/Casks/sturgeon-local.rb
```
