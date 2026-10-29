# Narrowing the NOPASSWD helper (issue #10)

## Before

`setup.sh` installed one sudoers line:

```
<user> ALL=(root) NOPASSWD: /Applications/Sturgeon.app/Contents/Resources/wmship/bin/asroot
```

and `bin/asroot` was a two-line zsh script:

```sh
#!/bin/zsh
exec /bin/zsh "$@"
```

That is passwordless root for anyone who can execute that path: `sudo -n asroot` with no arguments
reads commands from stdin, `-c` runs any command, and `-i` starts a login shell. The rule also
matched any argv because the sudoers line names no arguments.

## After (landed in this branch)

`bin/asroot` is a compiled arm64 binary (`helpers/asroot.c`) at the **same path**, so the sudoers
line, `setup.sh`, `teardown.sh`, the cask and the current Swift app need no path change. It parses
argv itself and exposes only fixed verbs:

| verb | what it does |
|---|---|
| `doctor [--json] [--no-live] [--mode pristine\|armed\|auto]` | `install.py doctor`; the mode is validated before it reaches the tool (`--mode armed` is the read-only check for a live install) |
| `status [--json]` | `install.py status` |
| `pristine` | `install.py pristine` (byte-exact site check) |
| `install` / `uninstall` | write / restore the six sites |
| `log` | `install.py log` |
| `counters` | `install.py counters` — the daemon's keep/learn/replay/dil counters, read by the app's diagnostics panel (the app is not a shell script, so selftest checks this verb against an explicit list) |
| `probe` | the NOPASSWD root probe: exits 0 as root, 1 otherwise; this replaced `-c true` so the shipped shell scripts no longer use the passthrough shape at all |
| `selfcheck` | `ctl.py selfcheck` — the app's slider preflight: proves the strip can be measured and restored at 1.0 before it is offered |
| `teach` | `ctl.py teach` — record the strip's natural widths once |
| `daemon-load`, `arm` | render + validate the LaunchDaemon plist, install it 0644 root:wheel, `launchctl bootout` then `bootstrap` |
| `daemon-unload`, `disarm` | `bootout`, delete the plist |
| `daemon-status` | exit status of `launchctl print system/com.stagemgr.wmshipd` |
| `teardown [--keep-state]` | the cask's undo: restore + verify, stop daemon/helpers, remove plist, rule, `/tmp/wmship` |
| `move <stage> [--cgid N]` | `ctl.py move`; the stage is validated (printable, ≤64, no shell metacharacters) and `--cgid` must be a decimal window id |
| `resize <0.4…1.5> [--teach]` | `ctl.py resize`; numeric parse and the documented 0.4–1.5 range, with the optional one-shot teach flag |
| `level <0\|3>` | `ctl.py level` |
| `cfg [<json>]` | no argument = read (`ctl.py cfg`); one JSON object ≤8 KiB = write (`install.py cfg`) |
| `warm`, `measure`, `state`, `poses` | the corresponding `ctl.py` read/sweep verbs |

`asroot --verbs` ends with a machine-readable `verbs: …` line. `scripts/selftest.sh` parses the
`asroot <verb>` calls out of `wmship.sh` and fails if any of them is missing from that line, and it
runs every published verb without root expecting exit 1 (a root-check refusal, not an unknown-verb
refusal). It also fails on a `-c` passthrough or a direct `install.py`/`ctl.py` invocation in
`wmship.sh`, `setup.sh` or `teardown.sh`: the helper is the only privileged path, and it takes
verbs only. That is the check that catches a caller landing a new verb before the helper does, and
the regression from #29 where `start`/`status` still spoke the old passthrough shape.

The scale range is **0.4–1.5**, matching `wmship.sh resize`, `ctl.py` and the cask's documentation.
The helper deliberately rejects anything outside it rather than passing a value the tool would
clamp or reject later.


Properties that make this narrower than the shell:

- **No `-c` pass-through** except the three exact strings the shipped Swift app still builds
  (`true`, `install.py status --json`, `install.py cfg '<json>'`). Anything else beginning with
  `-c` is refused, including `-c 'true; id'`.
- **No shell, no stdin, no scripts.** `-i`, `-l`, `-s`, a script path, no arguments, or any
  unknown verb exits 2 without executing anything. A valid verb run without sudo exits 1 with
  "must run as root", so it does not rely on the caller being root to be safe.
- **No inherited environment.** Children are exec'd with `PATH=/usr/bin:/bin:/usr/sbin:/sbin`,
  `HOME=/var/root` and nothing else.
- **Paths are allow-listed.** The tree is derived from the binary's own real path
  (`bin/asroot` → tree); the plist target is the constant
  `/Library/LaunchDaemons/com.stagemgr.wmshipd.plist`; the sudoers target is the constant
  `/etc/sudoers.d/stage-pilot`; `/tmp/wmship` is the only directory `remove-state`/`teardown` can
  delete. Argument values are lengths and shapes, never paths.
- **The rendered plist is checked, not trusted.** `daemon-load` refuses to install a plist that
  does not name this tree's `wmshipd.py`, `/usr/bin/python3` and `/tmp/wmship/`.
- **The sudoers rule is only deleted when it grants this copy** (`teardown` searches for
  `<tree>/bin/asroot` in the file). A rule for a moved app is left in place.
- **`teardown` disarms before it deletes anything** (issue #21): restore the sites, verify
  byte-exact, boot the daemon out, stop the helpers, verify again, then remove the plist and rule.
  A pid change (WindowManager restarted) is a clean "nothing to restore"; an unverifiable restore
  prints `PATCH: UNVERIFIED` and the removal still proceeds, with a non-zero exit.  If
  WindowManager is not running at all there is nothing live to check, so that is reported as
  "nothing live to restore" and is not a failure — a machine with a dead WindowManager must still
  be uninstallable.
- **The elevation ladder has exactly two rungs.** `teardown.sh` runs the verb directly as root, or
  through `sudo -n` on this rule; there is no `osascript` administrator prompt, because a GUI
  dialog in a non-interactive `brew uninstall` can block forever (issue #44).  With neither rung it
  exits 3, changes nothing, and prints `sudo <app>/…/teardown.sh`.  When nothing privileged exists
  (no plist, no rule, nothing armed) `teardown.sh` exits 0 without root at all.

### One environment consequence: `HOME=/var/root`

The helper replaces the caller's environment with `PATH=/usr/bin:/bin:/usr/sbin:/sbin` and
`HOME=/var/root`, so `SUDO_USER`/`USER`/`LOGNAME` no longer reach `wmlayout.py`. It resolves the
console user from `/dev/console` first; when that is owned by root — a headless machine, an SSH
session with no console login, or a CI runner — it falls back to the effective uid's passwd entry,
which through the helper is `root`. The bundle's writable state directory then resolves to
`/var/root/Library/Application Support/Sturgeon` instead of
`~/Library/Application Support/Sturgeon`. Arming is unaffected (the control block and `state.json`
live in `/tmp/wmship`, and the sites are process-global), but an unprivileged `doctor`/`status`
after a privileged run on such a machine may read a root-owned cache. The old `-c` passthrough
inherited the caller's environment and did not have this wrinkle. If this matters on a target
machine, the fix is for `wmlayout.py` to take the uid from an explicit argument rather than from
the environment — a CLI-stream change, not a helper one.

`setup.sh` now refuses to write a rule for a path that does not answer `--verbs`, so a stale
script copy cannot be granted. `wmship.sh` calls verbs (`asroot doctor`, `asroot install`,
`asroot daemon-load`, …) instead of building shell strings.

## Threat model: what an attacker with user-level write access can still do

The trusted computing base is still the app tree, because the sudoers rule names a **path** and
sudo does not bind the rule to a code signature or a hash:

1. **Write into the app bundle → replace `bin/asroot` → silent root.** `/Applications` is
   admin-writable; a user who can write the bundle can replace the granted binary. The verbs stop
   an attacker who can only *execute* the path (the usual "local user runs sudo -n" case); they do
   not stop an attacker who can also *modify* it. Closing that needs either an immutable copy in
   `/Library/PrivilegedHelperTools` installed `root:wheel 0755` (and the rule pointing there), or a
   sudoers rule plus a `codesign` designated-requirement check that cannot be satisfied by a
   re-signed replacement. Neither is in this change; it is the next step, and it is a larger
   change because the helper currently derives everything from its location inside the app.
2. **Replace the tree's Python tools** (`install.py`, `wmlayout.py`, `ctl.py`, `wmshipd.py`). The
   helper execs them with fixed argv, but they are the same user-writable tree. A verb-limited
   helper reduces the *argv* attack surface, not the *tree* trust.
3. **Use the verbs themselves.** `install`/`uninstall` write kernel memory in WindowManager; a
   local user who can invoke the grant can still arm or disarm the patch, or run `teardown`
   (removing the rule and daemon — a denial of service, not escalation). That is inherent to a
   tool whose job is to patch another process; the verbs do not create a path to a shell or to
   arbitrary file writes.
4. **The three legacy `-c` shapes stay for the current app.** They are exact-string matches, but
   `cfg '<json>'` carries a JSON document to `install.py cfg`; the document is shape-checked, not
   semantically audited. Once the app calls verbs (`status`, `cfg`), delete this compatibility
   block — it is the only remaining `-c` surface.

What is **not** possible any more: `sudo -n asroot` (stdin shell), `-c 'anything'`, `-i`, `-l`,
`/bin/zsh -c …`, running a script file, `PATH`/`HOME` injection, or deleting a path other than the
one plist, one sudoers file and `/tmp/wmship`.

## Not done / follow-ups

- The Swift app still speaks the three legacy `-c` shapes (`Sources/SturgeonKit/Commands.swift`).
  They are accepted for compatibility; the follow-up is to call the verbs and then remove the
  legacy branch from `helpers/asroot.c`.
- The helper is still inside the app bundle. Moving it to `/Library/PrivilegedHelperTools` with a
  root-owned copy (and pointing the sudoers rule there) is the change that removes threat 1.
- `setup.sh` still writes the sudoers file from a root-side shell script run through osascript
  (one administrator prompt). That script is not reachable through the NOPASSWD rule.
- There is no automated privileged test: this branch proves the refusal paths without root. The
  success paths (`install`, `daemon-load`, `teardown`) need a machine with SIP off and are
  exercised by `scripts/test-uninstall.sh`, which the owner runs.

## Suggested docs/TECHNICAL.md section (docs stream owns that file)

> **Privilege.** One sudoers rule grants one compiled binary, `bin/asroot`. It accepts a fixed
> verb list (doctor, status, pristine, install, uninstall, selfcheck, teach, arm, disarm, teardown,
> move, resize, level, cfg) and validates every argument; it never runs a shell, never reads stdin
> and does not inherit the caller's environment. The repair escape hatch is `sudo` with a password,
> not `asroot`. The rule names a path inside the app, so an attacker who can write the bundle can
> replace the helper: the helper narrows what a local *executor* can do, not what a bundle
> *writer* can do.
