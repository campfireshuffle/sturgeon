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

1. Bump `CFBundleShortVersionString` and `CFBundleVersion` in `Resources/Info.plist`.
2. Run the **Release** workflow with that version.
3. It signs and notarizes, staples, publishes the zip and its sha256, and opens a PR against the tap
   that updates the cask.

## Local proof

```sh
./scripts/build-helpers.sh
SIGN_IDENTITY=- ./scripts/package.sh 1.0.0 36       # unsigned unless SIGN_IDENTITY is set

# Homebrew 5 and later refuse `brew install --cask ./dist/sturgeon.rb` ("requires casks to be in a
# tap") and refuse an untrusted tap, so stage the generated cask in a throw-away local tap:
TAP_DIR="$(brew --repository)/Library/Taps/sturgeon-proof/homebrew-local"
mkdir -p "$TAP_DIR/Casks" && cp dist/sturgeon.rb "$TAP_DIR/Casks/sturgeon.rb"
brew trust --cask sturgeon-proof/local/sturgeon
brew install --cask sturgeon-proof/local/sturgeon
```

The end-to-end uninstall proof (`scripts/test-uninstall.sh`) is described in that script's header.
It installs, arms the live patch, and uninstalls, so it is not part of CI and is never run by a
release.

## The uninstall stanza

`uninstall script:` names `/bin/zsh`, not the app's `teardown.sh`, and passes the bundle script as
an argument.  Homebrew raises `uninstall script … does not exist` for a missing executable *before*
it consults `must_succeed:`, so a cask pointing into `Sturgeon.app` could not be removed at all
once the app had been dragged to the Trash — `--force` was the only way out (#44).  With `/bin/zsh`
the stanza always runs:

* bundle present — `exec`s the bundled `teardown.sh`, whose non-zero exit aborts the uninstall
  (`must_succeed: true`) so a failed WindowManager restore cannot delete the only copy of the tool;
* bundle absent — prints the exact privileged cleanup commands, exits 0, and the cask record and the
  `zap` stanza still run.

The ordering (restore → verify → bootout → stop helpers → verify again → delete rule/plist →
remove `/tmp/wmship`) lives in `helpers/asroot.c`'s `teardown` verb, not in the cask, because a cask
cannot run arbitrary ordered steps as root before the app is deleted (#21).  `teardown.sh` never
raises an `osascript` administrator dialog: with no root and no NOPASSWD rule it exits 3 with the
one `sudo` command to run, so `brew uninstall` fails within a second instead of blocking forever.

Two state helpers worth knowing: if nothing privileged exists (no plist, no rule, nothing armed)
`teardown.sh` exits 0 without asking for a password, and a restore that cannot be verified because
WindowManager is not running is reported as "nothing live to restore" rather than a failure.
