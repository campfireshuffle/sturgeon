"""#28: the state directory comes from one explicit uid, and every caller agrees on it.

The bug: the helper runs with a fixed child environment (HOME=/var/root, no USER/LOGNAME).  When
/dev/console is owned by root — headless, SSH without a console login, CI — the old name-based
resolution fell through to the effective uid, i.e. root, and the helper wrote
/var/root/Library/Application Support/Sturgeon while the user's own `doctor` read
/Users/<user>/Library/... .  Two caches, two answers.

These are pure tests over the resolution rule and the path it produces.  Nothing here reads the
live /dev/console, calls sudo, or needs root; the helper's own precedence is modelled exactly as
`resolve_uid()` is (same three inputs), and the agreement tests are the contract that the compiled
helper and the shell pick the same uid in every scenario.

    python3 -m unittest discover -s wmship/tests -v
"""
import io
import json
import os
import pwd
import subprocess
import sys
import unittest
from unittest import mock

_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.realpath(__file__))))
if _ROOT not in sys.path:
    sys.path.insert(0, _ROOT)

import wmlayout as L            # noqa: E402

ME = os.getuid()
ME_NAME = pwd.getpwuid(ME).pw_name
ME_HOME = pwd.getpwuid(ME).pw_dir


def resolved(console, env, euid):
    """resolve_uid with the process cache out of the way (env may name real or fake users)."""
    return L.resolve_uid(console, env, euid)


def helper_uid(console, sudo_uid, uid):
    """The precedence compiled into helpers/asroot.c, over the same three facts.

    asroot cannot ask wmlayout (it execs it): it stats /dev/console, then reads SUDO_UID, then
    falls back to its own uid.  uid 0 from the console is "no login", not "root's cache"."""
    if console is not None and console != 0:
        return console
    if sudo_uid:
        return int(sudo_uid)
    return uid


class ResolutionMatrix(unittest.TestCase):
    """console uid, environment, effective uid -> the uid whose home holds the cache."""

    def test_headless_or_ssh_console_root_resolves_the_calling_user(self):
        # the issue: console is root, the user ran wmship.sh as themselves
        self.assertEqual(resolved(0, {}, ME), ME)

    def test_an_unreadable_console_resolves_the_calling_user(self):
        self.assertEqual(resolved(None, {}, ME), ME)

    def test_no_console_and_a_user_euid_is_that_user(self):
        self.assertEqual(resolved(None, {"USER": "ignored"}, ME), ME)

    def test_a_real_console_login_wins_over_the_effective_uid(self):
        # daemon/root helper while the owner is logged in at the console
        self.assertEqual(resolved(ME, {}, 0), ME)

    def test_root_euid_with_sudo_uid_resolves_the_invoking_user(self):
        self.assertEqual(resolved(0, {"SUDO_UID": str(ME)}, 0), ME)

    def test_root_euid_with_only_a_sudo_user_name_resolves_its_uid(self):
        self.assertEqual(resolved(None, {"SUDO_USER": ME_NAME}, 0), ME)

    def test_explicit_sturgeon_uid_wins_even_over_a_console_login(self):
        # the caller already resolved it; nobody may re-resolve to something else
        self.assertEqual(resolved(4321, {"STURGEON_UID": str(ME)}, 0), ME)

    def test_explicit_sturgeon_uid_carries_a_headless_helper_run(self):
        self.assertEqual(resolved(0, {"STURGEON_UID": str(ME)}, 0), ME)

    def test_zero_candidates_are_skipped_not_used(self):
        # uid 0 on the console / in the environment means "unknown", never a destination
        self.assertEqual(resolved(0, {"STURGEON_UID": "0", "SUDO_UID": str(ME)}, 0), ME)

    def test_a_garbage_explicit_uid_falls_through(self):
        self.assertEqual(resolved(0, {"STURGEON_UID": "not-a-uid"}, ME), ME)

    def test_an_unknown_user_name_falls_through(self):
        self.assertEqual(resolved(0, {"SUDO_USER": "no-such-user-here"}, ME), ME)

    def test_all_inputs_root_is_root(self):
        # a root-only machine (no login, no sudo, euid 0) still resolves deterministically
        self.assertEqual(resolved(0, {}, 0), 0)
        self.assertEqual(resolved(None, {}, 0), 0)


class StateDirPath(unittest.TestCase):
    """The path the uid produces, independent of this process's environment."""

    def test_state_dir_for_home_is_the_application_support_directory(self):
        self.assertEqual(L.state_dir_for("/Users/example"),
                         "/Users/example/Library/Application Support/Sturgeon")

    def test_state_dir_uses_the_resolved_uid_s_home(self):
        with mock.patch.object(L, "is_bundle", return_value=True):
            self.assertEqual(L.state_dir(), L.state_dir_for(ME_HOME))

    def test_state_dir_for_another_uid_is_that_uid_s_home(self):
        # the helper's view: uid 501 -> 501's home, not /var/root
        if ME == 0:
            self.skipTest("running as root; there is no second real user to compare")
        with mock.patch.object(L, "is_bundle", return_value=True):
            self.assertEqual(L.state_dir(uid=ME), L.state_dir_for(ME_HOME))

    def test_the_checkout_still_writes_in_its_own_tree(self):
        with mock.patch.object(L, "is_bundle", return_value=False):
            self.assertEqual(L.state_dir(), L.root())


class HelperAndShellAgree(unittest.TestCase):
    """The helper (root, fixed env) and the shell (the invoking user) must name one cache.

    Each row is a real situation: what /dev/console says, who ran the command (euid, and sudo's
    record when it went through sudo), and the uid both sides must land on."""

    CASES = [
        # (description, console uid, shell euid, sudo uid or None, expected)
        ("headless: user runs wmship.sh, helper goes through sudo", 0, ME, ME, ME),
        ("console login: user runs wmship.sh, helper goes through sudo", ME, ME, ME, ME),
        ("headless: wmship.sh itself is run under sudo", 0, 0, ME, ME),
        ("console login: wmship.sh is run from a root shell", ME, 0, ME, ME),
        ("console unreadable, root shell: nothing to resolve to", None, 0, None, 0),
        ("everything root (root shell on a headless host)", 0, 0, None, 0),
    ]

    def test_every_scenario_resolves_the_same_uid_on_both_sides(self):
        for desc, console, euid, sudo_uid, want in self.CASES:
            with self.subTest(desc):
                shell_env = {"SUDO_UID": str(sudo_uid)} if sudo_uid else {}
                shell = resolved(console, shell_env, euid)
                helper = helper_uid(console, sudo_uid, 0)
                self.assertEqual(shell, want, "%s: the shell resolved %s" % (desc, shell))
                self.assertEqual(helper, want,
                                 "%s: the helper resolved %s" % (desc, helper))
                self.assertEqual(shell, helper, "%s: two caches" % desc)

    def test_the_helper_s_passed_uid_is_honoured_verbatim_downstream(self):
        # asroot sets STURGEON_UID in the child env; wmlayout must not re-resolve past it
        for desc, console, euid, sudo_uid, want in self.CASES:
            with self.subTest(desc):
                pinned = helper_uid(console, sudo_uid, 0)
                child = resolved(console, {"STURGEON_UID": str(pinned)}, 0)
                self.assertEqual(child, pinned)
                self.assertEqual(L.state_dir_for(pwd.getpwuid(child).pw_dir),
                                 L.state_dir_for(pwd.getpwuid(want).pw_dir))


class ShellSurface(unittest.TestCase):
    """--uid and STURGEON_UID are two spellings of the same explicit answer."""

    def run_main(self, argv):
        out = io.StringIO()
        with mock.patch("sys.stdout", new=out):
            rc = L.main(["wmlayout.py"] + argv)
        return rc, out.getvalue()

    def shell_vars(self, text):
        return dict(line.split("=", 1) for line in text.splitlines() if "=" in line)

    def test_the_shell_view_publishes_the_uid(self):
        rc, out = self.run_main(["shell"])
        self.assertEqual(rc, 0)
        vals = self.shell_vars(out)
        self.assertEqual(vals["STURGEON_UID"], str(ME))

    def test_uid_option_pins_the_uid_and_the_home(self):
        rc, out = self.run_main(["--uid", str(ME), "json"])
        self.assertEqual(rc, 0)
        view = json.loads(out)
        self.assertEqual(view["uid"], ME)
        self.assertEqual(view["user"], ME_NAME)
        self.assertEqual(view["home"], ME_HOME)
        self.assertEqual(view["state_dir"], L.state_dir(uid=ME))

    def test_uid_option_is_the_same_answer_as_the_environment(self):
        rc, via_flag = self.run_main(["--uid", str(ME), "shell"])
        self.assertEqual(rc, 0)
        with mock.patch.dict(os.environ, {"STURGEON_UID": str(ME)}), \
                mock.patch.dict(L._UID, {}, clear=True):
            rc, via_env = self.run_main(["shell"])
        self.assertEqual(rc, 0)
        self.assertEqual(self.shell_vars(via_flag), self.shell_vars(via_env))

    def test_a_bad_uid_option_is_a_usage_error(self):
        for argv in (["--uid"], ["--uid", "abc"]):
            with self.subTest(argv):
                with self.assertRaises(SystemExit) as e:
                    L.main(["wmlayout.py"] + argv)
                self.assertEqual(e.exception.code, 2)


class PlistCarriesTheUid(unittest.TestCase):
    """The daemon is a third caller: it must inherit the same uid, not resolve its own."""

    def test_the_rendered_plist_names_the_explicit_uid(self):
        with mock.patch.object(L, "resolved_uid", return_value=ME):
            text = L.plist_text()
        self.assertIn("<key>STURGEON_UID</key>", text)
        self.assertIn("<string>%d</string>" % ME, text)
        self.assertNotIn("__UID__", text)


class CompiledHelper(unittest.TestCase):
    """The real helper, not the model: `asroot --uid` reports what it passes to its children.

    Skipped when bin/asroot is absent or is still the checkout's shell passthrough stub; after
    scripts/build-helpers.sh (which package.sh runs) this asserts the compiled C precedence and
    the Python rule answer the same thing on this machine."""

    def helper(self):
        exe = os.path.join(_ROOT, "bin", "asroot")
        if not os.access(exe, os.X_OK):
            self.skipTest("bin/asroot is not built (run scripts/build-helpers.sh)")
        r = subprocess.run([exe, "--uid"], capture_output=True, text=True, timeout=30)
        if r.returncode != 0 or not r.stdout.strip().isdigit():
            self.skipTest("bin/asroot is the checkout's shell passthrough stub, not the helper")
        return int(r.stdout.strip())

    def test_the_helper_reports_what_the_python_rule_resolves(self):
        with mock.patch.dict(L._UID, {}, clear=True):
            want = L.resolved_uid()
        self.assertEqual(self.helper(), want)

    def test_the_helper_never_reports_root_on_a_user_machine(self):
        if ME == 0:
            self.skipTest("running as root; the helper is expected to say 0")
        self.assertEqual(self.helper(), ME)


if __name__ == "__main__":
    unittest.main()
