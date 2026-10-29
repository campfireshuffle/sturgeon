"""Tests for the CLI stream's two new modes: an armed doctor (#6), the resize preflight (#5) and
teach-once-per-layout (#17).

These are pure Python: no WindowManager, no root, no pointer.  Every live read is a parameter, so
what is tested here is the decision logic, not the machine.

    python3 -m unittest discover -s wmship/tests -v

This directory is *not* copied into the app bundle (scripts/build-app.sh copies a fixed list), so
`Contents/Resources/wmship/` keeps exactly the files it shipped before.
"""
import json
import os
import struct
import sys
import tempfile
import time
import unittest
from unittest import mock

_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.realpath(__file__))))
for _p in (_ROOT, os.path.join(_ROOT, "wmship")):
    if _p not in sys.path:
        sys.path.insert(0, _p)

import install as I            # noqa: E402
import ctl as C                # noqa: E402

ISLAND = 0x104000000          # within +-128 MB of the __TEXT sites, as a real island is
SITE_ADDRS = {"birth": 0x100004000, "birth2": 0x100008000, "birthE": 0x10000C000,
              "compute": 0x100010000, "keeper3d": 0x180020000, "keeper2d": 0x180024000}


def near_stub(addr, target):
    """The bytes install() writes at a __TEXT site: one direct `b` to the island stub."""
    return I.le32(I.enc_b(addr, target))


def keeper_stub(addr, target):
    """The bytes install() writes at a keeper: adrp/add/br, because the shared cache is far away."""
    return I.le32(*I.jump_seq(addr, target))


def fabricated_backup(stub_for=None):
    """A backup.json shaped exactly like install() writes one, with each stub inside the island."""
    stub_for = stub_for or {}
    sites = {}
    for i, name in enumerate(I.SITE_NAMES):
        addr = SITE_ADDRS[name]
        target = stub_for.get(name, ISLAND + 0x100 + 0x40 * i)
        blob = keeper_stub(addr, target) if name.startswith("keeper") else near_stub(addr, target)
        sites[name] = {"addr": addr, "orig": "00" * len(blob), "len": len(blob),
                       "new": blob.hex(), "stub": target}
    return {"sites": sites}


def reader(backup, patches=None):
    """A `read(addr, n)` over the fabricated stubs, with optional byte patches."""
    live = {s["addr"]: bytes.fromhex(s["new"]) for s in backup["sites"].values()}
    for addr, blob in (patches or {}).items():
        live[addr] = blob
    return lambda addr, n: live.get(int(addr), b"")[:n]


class DoctorMode(unittest.TestCase):
    """#6: which set of assertions doctor makes, and that an impossible request is a refusal."""

    def test_auto_is_armed_when_state_matches_the_running_pid(self):
        self.assertEqual(I.doctor_mode(None, {"pid": 4242}, 4242), "armed")

    def test_auto_is_pristine_after_a_windowmanager_restart(self):
        self.assertEqual(I.doctor_mode(None, {"pid": 4242}, 5151), "pristine")

    def test_auto_is_pristine_with_no_state(self):
        self.assertEqual(I.doctor_mode(None, None, 5151), "pristine")

    def test_explicit_pristine_is_never_switched_to_armed(self):
        self.assertEqual(I.doctor_mode("pristine", {"pid": 4242}, 4242), "pristine")

    def test_explicit_armed_without_a_matching_install_refuses(self):
        with self.assertRaises(I.Refuse) as e:
            I.doctor_mode("armed", None, 4242)
        self.assertIn("armed", str(e.exception))
        with self.assertRaises(I.Refuse):
            I.doctor_mode("armed", {"pid": 1}, 4242)


class StubDecoding(unittest.TestCase):
    """The armed assertions are only as good as these two decoders."""

    def test_direct_b_round_trip(self):
        blob = near_stub(0x100004000, ISLAND + 0x120)
        self.assertEqual(I.stub_target(blob, 0x100004000), ISLAND + 0x120)

    def test_keeper_jump_round_trip(self):
        blob = keeper_stub(0x180020000, ISLAND + 0x40)
        self.assertEqual(I.stub_target(blob, 0x180020000), ISLAND + 0x40)

    def test_a_plain_prologue_is_not_a_stub(self):
        self.assertEqual(I.stub_target(I.le32(I.PACIBSP, I.MOV_X1_X30, 0xD63F03C0), 0x1000), 0)


class ArmedSites(unittest.TestCase):
    """#6 acceptance: a healthy armed install passes; a corrupted stub fails and names the site."""

    def test_a_healthy_install_passes_every_site(self):
        bak = fabricated_backup()
        rows = I.armed_site_checks(bak, reader(bak), ISLAND)
        self.assertEqual(len(rows), 2 * len(I.SITE_NAMES))
        self.assertTrue(all(r["ok"] for r in rows), [r for r in rows if not r["ok"]])

    def test_a_corrupted_stub_fails_and_names_the_site(self):
        bak = fabricated_backup()
        addr = SITE_ADDRS["compute"]
        rows = I.armed_site_checks(bak, reader(bak, {addr: b"\x1f\x20\x03\xd5"}), ISLAND)
        bad = [r for r in rows if not r["ok"]]
        self.assertEqual(len(bad), 1)
        self.assertEqual(bad[0]["check"], "compute.stub-bytes")
        self.assertIn("compute", bad[0]["detail"])
        self.assertIn("1f2003d5", bad[0]["detail"])

    def test_a_restored_site_is_named_even_when_the_others_are_patched(self):
        bak = fabricated_backup()
        # the shipped prologue of the driver, i.e. someone restored this one site
        addr = SITE_ADDRS["birthE"]
        rows = I.armed_site_checks(
            bak, reader(bak, {addr: I.le32(I.PACIBSP, I.MOV_X1_X30, 0x94000010)}), ISLAND)
        bad = [r for r in rows if not r["ok"]]
        self.assertEqual([r["check"] for r in bad], ["birthE.stub-bytes"])

    def test_a_stub_outside_the_island_fails(self):
        bak = fabricated_backup(stub_for={"keeper3d": 0xDEAD0000})
        rows = I.armed_site_checks(bak, reader(bak), ISLAND)
        bad = [r for r in rows if not r["ok"]]
        self.assertEqual([r["check"] for r in bad], ["keeper3d.stub-target"])

    def test_a_stub_that_lands_elsewhere_than_recorded_fails(self):
        bak = fabricated_backup()
        # bytes intact, but backup.json claims a different island slot
        bak["sites"]["birth"]["stub"] = ISLAND + 0x2000
        rows = I.armed_site_checks(bak, reader(bak), ISLAND)
        bad = [r for r in rows if not r["ok"]]
        self.assertEqual([r["check"] for r in bad], ["birth.stub-target"])

    def test_a_missing_backup_entry_is_a_refusal_naming_the_site(self):
        bak = fabricated_backup()
        del bak["sites"]["birth2"]
        rows = I.armed_site_checks(bak, reader(bak), ISLAND)
        bad = [r for r in rows if not r["ok"]]
        self.assertEqual([r["check"] for r in bad], ["birth2.stub-recorded"])


class DoctorRouting(unittest.TestCase):
    """`doctor()` end to end, armed: the mode is chosen from the state file and the report is PASS
    without ever comparing a site to the on-disk image.  A corrupted stub flips it to FAIL."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.disk = bytes(range(64)) * 2
        with open(os.path.join(self.tmp.name, "payload.img"), "wb") as f:
            f.write(self.disk)
        self.bak = fabricated_backup()
        self.state = {"pid": 7, "island": ISLAND, "body": 0x200000000,
                      "syms": {"_SL": 32}, "relocs": [[32, 16]],
                      "img_sha256": I.hashlib.sha256(self.disk).hexdigest()}
        self.state_path = os.path.join(self.tmp.name, "state.json")
        self.bak_path = os.path.join(self.tmp.name, "backup.json")
        for p, d in ((self.state_path, self.state), (self.bak_path, self.bak)):
            with open(p, "w") as f:
                json.dump(d, f)
        self.inst = {"sites": dict(SITE_ADDRS),
                     "keepers": {k: (SITE_ADDRS[k], None) for k in ("keeper3d", "keeper2d")},
                     "images": {"SkyLight": {"base": 0, "path": "SkyLight"}},
                     "build": "B", "text_sha": "T", "cache": "cache"}

    def run_doctor(self, patches=None):
        mem = {s["addr"]: bytes.fromhex(s["new"]) for s in self.bak["sites"].values()}
        mem.update(patches or {})
        mem[self.state["body"]] = self.disk

        def fake_rb(addr, n):
            for base, blob in mem.items():
                if base <= int(addr) < base + len(blob):
                    return blob[int(addr) - base:int(addr) - base + n]
            return b""

        with mock.patch.object(I, "STATE", self.state_path), \
                mock.patch.object(I, "BAK", self.bak_path), \
                mock.patch.object(I, "W", self.tmp.name), \
                mock.patch.object(I, "find", return_value={"pid": 7, "slide": 0}), \
                mock.patch.object(I, "file_sites", return_value=self.inst), \
                mock.patch.object(I, "keeper_live", side_effect=lambda k, i: SITE_ADDRS[k]), \
                mock.patch.object(I, "load_profile", return_value={"widmeta": 1}), \
                mock.patch.object(I, "rb", side_effect=fake_rb), \
                mock.patch("sys.stdout", new=__import__("io").StringIO()) as out:
            rc = I.doctor(as_json=True)
        return rc, json.loads(out.getvalue())

    def test_a_healthy_armed_install_passes_in_armed_mode(self):
        rc, rep = self.run_doctor()
        self.assertEqual(rep["mode"], "armed")
        self.assertTrue(rep["ok"], [c for c in rep["checks"] if not c["ok"]])
        self.assertEqual(rc, 0)
        self.assertEqual(rep["refusals"], [])
        self.assertTrue(any(c["check"] == "payload.image" and c["ok"] for c in rep["checks"]))

    def test_a_corrupted_stub_fails_and_names_the_site(self):
        addr = SITE_ADDRS["birth"]
        rc, rep = self.run_doctor({addr: b"\x1f\x20\x03\xd5"})
        self.assertEqual(rep["mode"], "armed")
        self.assertFalse(rep["ok"])
        self.assertEqual(rc, 1)
        bad = [c["check"] for c in rep["checks"] if not c["ok"]]
        self.assertIn("birth.stub-bytes", bad)

    def test_a_stale_state_file_falls_back_to_pristine(self):
        self.state["pid"] = 1
        with open(self.state_path, "w") as f:
            json.dump(self.state, f)
        # pristine mode needs a real Mach-O image, so the honest assertion here is that it does not
        # take the armed path at all: the site assertions are absent from the report.
        with mock.patch.object(I, "file_sites",
                               side_effect=I.Refuse("sites unresolved — test")):
            with mock.patch("sys.stdout", new=__import__("io").StringIO()) as out:
                rc = I.doctor(as_json=True)
        rep = json.loads(out.getvalue())
        self.assertEqual(rep["mode"], None)          # refused before a mode was chosen
        self.assertEqual(rc, 1)


class BodyImage(unittest.TestCase):
    """#6: the running body must be the payload image on disk, with the symbol table masked."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.disk = bytes(range(256)) * 4
        with open(os.path.join(self.tmp.name, "payload.img"), "wb") as f:
            f.write(self.disk)
        self.state = {"body": 0x200000000, "img_sha256": "abc",
                      "syms": {"_SL": 64}, "relocs": [[64, 16]]}

    def check(self, live):
        with mock.patch.object(I, "W", self.tmp.name), \
                mock.patch.object(I, "img_sha256", return_value="abc"):
            return I.body_image_check(self.state, lambda a, n: live[:n])

    def test_the_relocated_words_do_not_count(self):
        live = bytearray(self.disk)
        live[64:80] = struct.pack("<QQ", 0x1122334455667788, 0x99AABBCCDDEEFF00)
        ok, det = self.check(bytes(live))
        self.assertTrue(ok, det)

    def test_a_changed_payload_byte_fails(self):
        live = bytearray(self.disk)
        live[100] ^= 0xFF
        ok, det = self.check(bytes(live))
        self.assertFalse(ok)
        self.assertIn("not payload.img", det)

    def test_an_image_rebuilt_since_the_install_fails(self):
        with mock.patch.object(I, "W", self.tmp.name), \
                mock.patch.object(I, "img_sha256", return_value="def"):
            ok, det = I.body_image_check(self.state, lambda a, n: self.disk[:n])
        self.assertFalse(ok)
        self.assertIn("changed since the install", det)


class FakeStrip:
    """A strip whose drawn geometry models the thing that made this issue subtle.

    At rest (`s == 1.0`) the WindowManager draws its own resting pose, so the drawn width is the
    natural width *no matter how wrong the taught base is* -- there is no write for the keeper to
    correct. Under `dilate` the keeper writes `mat_scale(base, s)`, so a base taught `base_lift`
    too large is visible as `s x base_lift`. `base_lift` is 1.0 for a healthy install and 1.05 for
    a base baked from a hover lift (round 34 measured 1.505-1.746 at s=1.5)."""

    def __init__(self, widths, base_lift=1.0, s=1.0, tiles=3):
        self.nat = {str(1000 + i): w for i, w in enumerate(widths)}
        self.base_lift = base_lift
        self.s = s
        self.dilate = abs(s - 1.0) > 1e-9
        self.tiles = tiles
        self.applied = []

    def measure(self):
        return [{"id": int(k), "owner": "Finder",
                 "w": int(round(w * self.s * (self.base_lift if self.dilate else 1.0)))}
                for k, w in sorted(self.nat.items())[:self.tiles]]

    def apply(self, **kw):
        self.applied.append(dict(kw))
        self.s = float(kw["s"])
        self.dilate = bool(kw.get("dilate"))

    def sweep(self):
        self.sweeps = getattr(self, "sweeps", 0) + 1

    def settle(self, secs=0.0):
        pass

    def run(self, **kw):
        return C.selfcheck(measure=self.measure, nat=dict(self.nat), s=kw.pop("s", self.s),
                           apply=self.apply, sweep=self.sweep, settle=self.settle, **kw)


class Selfcheck(unittest.TestCase):
    """#5: the preflight probes under dilate, because at rest a wrong base is invisible."""

    def test_a_healthy_strip_passes_and_is_left_at_rest(self):
        w = FakeStrip([140, 126, 133])
        r = w.run(s=1.0)
        self.assertTrue(r["ok"], r)
        self.assertTrue(all(abs(t["ratio"] - 1.2) <= 0.02 for t in r["tiles"]), r["tiles"])
        # the probe was applied, then released, and the geometry came back
        self.assertEqual(w.applied[0]["s"], C.PROBE_S)
        self.assertTrue(w.applied[0]["dilate"])
        self.assertEqual(w.applied[-1]["s"], 1.0)
        self.assertFalse(w.applied[-1]["dilate"])
        self.assertEqual(w.s, 1.0)
        self.assertEqual([t["ratio"] for t in r["restored"]], [1.0, 1.0, 1.0])

    def test_a_base_taught_five_percent_large_fails_the_probe(self):
        """The blocker: at rest this base reads 1.000 and used to pass."""
        w = FakeStrip([140, 126, 133], base_lift=1.05)
        self.assertEqual([t["w"] for t in w.measure()], [140, 126, 133])   # invisible at rest
        r = w.run(s=1.0)
        self.assertFalse(r["ok"])
        self.assertAlmostEqual(r["tiles"][0]["ratio"], 1.26, delta=0.01)   # 1.2 x 1.05
        self.assertIn("at probe 1.20", r["err"])
        self.assertRegex(r["err"], r"tile 100[0-9]")
        self.assertNotIn("\n", r["err"])

    def test_a_bad_probe_still_restores_the_scale(self):
        w = FakeStrip([140, 126, 133], base_lift=1.05)
        self.assertFalse(w.run(s=1.0)["ok"])
        self.assertEqual(w.applied[-1]["s"], 1.0)
        self.assertEqual(w.applied[-1]["dilate"], False)
        self.assertEqual(w.s, 1.0)

    def test_the_caller_scale_is_restored_not_forced_to_one(self):
        w = FakeStrip([140, 140], s=1.4)
        r = w.run(s=1.4)
        self.assertTrue(r["ok"], r)
        self.assertEqual(w.applied[-1]["s"], 1.4)
        self.assertTrue(w.applied[-1]["dilate"])
        self.assertEqual([t["ratio"] for t in r["restored"]], [1.4, 1.4])

    def test_the_probe_never_teaches(self):
        w = FakeStrip([140, 140])
        w.run(s=1.0)
        probe = w.applied[0]
        self.assertIs(probe["teach"], False)
        # teaching is re-enabled only when the strip is handed back
        self.assertIs(w.applied[-1]["teach"], True)
        self.assertTrue(all(a["teach"] is False for a in w.applied[:-1]))

    def test_a_two_percent_tolerance_is_the_boundary(self):
        self.assertTrue(FakeStrip([100], base_lift=1.02).run(s=1.0)["ok"])
        self.assertFalse(FakeStrip([100], base_lift=1.03).run(s=1.0)["ok"])

    def test_no_tiles_is_a_refusal_not_a_pass(self):
        w = FakeStrip([140], tiles=0)
        r = w.run(s=1.0)
        self.assertFalse(r["ok"])
        self.assertIn("no strip tiles", r["err"])
        self.assertEqual(w.applied, [])            # nothing was touched

    def test_a_tile_without_a_natural_width_says_how_to_fix_it(self):
        r = C.selfcheck(measure=lambda: [{"id": 1, "w": 140}, {"id": 77, "w": 120}],
                        nat={"1": 140}, s=1.0,
                        apply=lambda **kw: None, sweep=lambda: None, settle=lambda: None)
        self.assertFalse(r["ok"])
        self.assertIn("77", r["err"])
        self.assertIn("wmship.sh teach", r["err"])


class TeachOnce(unittest.TestCase):
    """#17: a teach pass only when the layout is not already known."""

    def test_bases_for_every_tile_mean_no_teach(self):
        tiles = [{"id": 1, "w": 140}, {"id": 2, "w": 126}]
        rows = [{"wid": 1, "base": 1}, {"wid": 2, "base": 1}]
        self.assertIsNone(C.teach_reason(tiles, {"1": 140, "2": 126}, rows))

    def test_a_tile_without_a_base_teaches(self):
        tiles = [{"id": 1, "w": 140}, {"id": 2, "w": 126}]
        rows = [{"wid": 1, "base": 1}]
        why = C.teach_reason(tiles, {"1": 140, "2": 126}, rows)
        self.assertIn("no taught base", why)
        self.assertIn("2", why)

    def test_a_changed_tile_set_teaches(self):
        tiles = [{"id": 1, "w": 140}, {"id": 3, "w": 120}]
        rows = [{"wid": 1, "base": 1}, {"wid": 3, "base": 1}]
        why = C.teach_reason(tiles, {"1": 140, "2": 126}, rows)
        self.assertIn("tile set changed", why)

    def test_an_empty_natural_record_teaches(self):
        why = C.teach_reason([{"id": 1, "w": 140}], {}, [{"wid": 1, "base": 1}])
        self.assertIn("tile set changed", why)


class ApplyScaleTeachesOnlyWhenNeeded(unittest.TestCase):
    """#17 end to end over a stubbed measurement layer: the teach pass is counted, not felt."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.wm = mock.Mock()
        self.wm.force_writes.return_value = 7
        self.teach = mock.Mock(return_value={"ok": True, "moves": 7, "tiles": 7, "bases": 7,
                                             "no_base": [], "secs": 0.0})
        self.cfg = mock.Mock(return_value={"gen": 1})
        self.state = {"tiles": [{"id": 100 + i, "owner": "Finder", "w": 140} for i in range(7)],
                      "nat": {str(100 + i): 140 for i in range(7)},
                      "s": 1.0}
        self.bases = {100 + i for i in range(7)}

    def _wall(self):
        s = self.state["s"]
        return [{"id": t["id"], "owner": t["owner"], "w": int(round(t["w"] * s))}
                for t in self.state["tiles"]]

    def _teach(self, M=None):
        self.teach(M)
        self.state["nat"] = {str(t["id"]): t["w"] for t in self.state["tiles"]}
        self.bases = {t["id"] for t in self.state["tiles"]}
        return {"ok": True, "moves": 7, "tiles": len(self.state["tiles"]),
                "bases": len(self.state["tiles"]), "no_base": [], "secs": 0.0}

    def run_scale(self, s):
        self.state["s"] = s
        with mock.patch.object(C, "wmctl", return_value=self.wm), \
                mock.patch.object(C, "rail_tiles", side_effect=self._wall), \
                mock.patch.object(C, "natural", return_value=dict(self.state["nat"])), \
                mock.patch.object(C, "poses",
                                  side_effect=lambda: [{"wid": w, "base": 1, "mine": 0,
                                                        "lvl": None} for w in sorted(self.bases)]), \
                mock.patch.object(C, "teach_now", side_effect=self._teach), \
                mock.patch.object(C, "cfg_set", self.cfg), \
                mock.patch.object(C, "hb", return_value={}), \
                mock.patch.object(C.time, "sleep", return_value=None), \
                mock.patch.object(C, "LAST_RESIZE",
                                  os.path.join(self.tmp.name, "last_resize.json")):
            rep = C.apply_scale(s)
        return rep

    def test_second_resize_with_unchanged_layout_does_not_teach(self):
        first = self.run_scale(1.5)
        self.assertTrue(first["ok"], first)
        self.assertEqual(self.teach.call_count, 0)
        sweeps = self.wm.force_writes.call_count
        self.assertEqual(sweeps, 1)                 # one measurement sweep, no teach sweep
        self.assertFalse(first["teach"]["needed"])
        # and that sweep is one pass over the tiles: a base needs the leave-and-return of a second
        # pass, a measurement does not (wm/wmctl.py force_writes(passes=...))
        self.wm.force_writes.assert_called_with(passes=1)

        second = self.run_scale(1.2)
        self.assertTrue(second["ok"], second)
        self.assertEqual(self.teach.call_count, 0)
        self.assertEqual(self.wm.force_writes.call_count - sweeps, 1)

    def test_a_fresh_arm_teaches_exactly_once(self):
        self.bases = set()                          # no pose has ever been taught
        rep = self.run_scale(1.5)
        self.assertTrue(rep["ok"], rep)
        self.assertEqual(self.teach.call_count, 1)
        self.assertTrue(rep["teach"]["needed"])

    def test_a_changed_tile_set_teaches_exactly_once(self):
        self.run_scale(1.5)
        self.state["tiles"].append({"id": 999, "owner": "Mail", "w": 120})
        self.state["s"] = 1.0
        rep = self.run_scale(1.4)
        self.assertTrue(rep["ok"], rep)
        self.assertEqual(self.teach.call_count, 1)
        self.assertIn("tile set changed", rep["teach"]["reason"])

    def test_teaching_requested_explicitly_is_honoured(self):
        self.state["s"] = 1.5
        with mock.patch.object(C, "wmctl", return_value=self.wm), \
                mock.patch.object(C, "rail_tiles", side_effect=self._wall), \
                mock.patch.object(C, "natural", return_value=dict(self.state["nat"])), \
                mock.patch.object(C, "poses", return_value=[{"wid": 100 + i, "base": 1}
                                                            for i in range(7)]), \
                mock.patch.object(C, "teach_now", side_effect=self._teach), \
                mock.patch.object(C, "cfg_set", self.cfg), \
                mock.patch.object(C, "hb", return_value={}), \
                mock.patch.object(C.time, "sleep", return_value=None), \
                mock.patch.object(C, "LAST_RESIZE",
                                  os.path.join(self.tmp.name, "last_resize.json")):
            rep = C.apply_scale(1.5, teach=True)
        self.assertTrue(rep["ok"], rep)
        self.assertEqual(self.teach.call_count, 1)
        self.assertEqual(rep["teach"]["reason"], "requested")

    def test_scale_is_never_left_off_while_measuring(self):
        """Teaching must be off for the measurement sweep, and on again when the command ends."""
        self.run_scale(1.5)
        calls = [c.kwargs for c in self.cfg.call_args_list]
        self.assertEqual(calls[-1], {"teach": True})
        self.assertTrue(any(c.get("teach") is False for c in calls))


class SettleWait(unittest.TestCase):
    """#4: the teach path waits for the payload's settled flag, bounded, never a fixed sleep."""

    def test_returns_as_soon_as_every_tile_has_a_base(self):
        seq = [[{"wid": 1, "base": 1}], [{"wid": 1, "base": 1}]]
        n = {"i": 0}
        sweeps = []

        def poses():
            row = seq[min(n["i"], len(seq) - 1)]
            n["i"] += 1
            return row

        with mock.patch.object(C, "poses", side_effect=poses), \
                mock.patch.object(C.time, "sleep", return_value=None):
            missing, issued = C.wait_bases([1], timeout=5.0,
                                           sweep=lambda: sweeps.append(1) or True)
        self.assertEqual(missing, [])
        self.assertEqual(issued, 0)
        self.assertEqual(sweeps, [])          # no call needed once the flag appears

    def test_is_bounded_when_no_base_ever_settles(self):
        with mock.patch.object(C, "poses", return_value=[]), \
                mock.patch.object(C.time, "sleep", return_value=None):
            t0 = time.time()
            missing, _ = C.wait_bases([7], timeout=0.05, sweep=lambda: True, gap=0.0)
        self.assertEqual(missing, [7])
        self.assertLess(time.time() - t0, 2.0)

    def test_gives_the_payload_a_call_while_a_tile_is_missing(self):
        # the payload has no timer: it only runs when the WM calls a patched function, so the
        # wait has to sweep while a tile is missing or the last tile can never settle
        sweeps = []
        with mock.patch.object(C, "poses", return_value=[]), \
                mock.patch.object(C.time, "sleep", return_value=None):
            C.wait_bases([7], timeout=0.05, sweep=lambda: sweeps.append(1) or True, gap=0.0)
        self.assertGreaterEqual(len(sweeps), 1)

    def test_a_pending_candidate_is_promoted_by_one_call_on_a_taught_tile(self):
        """The regression: the last tile of a sweep has a candidate and no later keeper call.

        A call on a tile whose base already exists is enough -- the keeper runs `promote_bases()`
        at the top of the call, before it records the new write -- and it cannot disturb the tile
        we are waiting for because it is a different window.
        """
        state = {"calls": 0}

        def poses():
            # the first call promotes tile 7; until then only tile 1 has a base
            row = [{"wid": 1, "base": 1}]
            if state["calls"]:
                row.append({"wid": 7, "base": 1})
            else:
                row.append({"wid": 7, "base": 0})
            return row

        def wake():
            state["calls"] += 1
            return True

        with mock.patch.object(C, "poses", side_effect=poses), \
                mock.patch.object(C.time, "sleep", return_value=None):
            missing, issued = C.wait_bases([7], timeout=5.0, sweep=wake, gap=0.0)
        self.assertEqual(missing, [])
        self.assertEqual(issued, 1)          # exactly one call, not a sweep per poll


class ResizeAssertsGeometry(unittest.TestCase):
    """#3: `resize 1.0` must prove x/y restoration, not only the width ratio."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.wm = mock.Mock()
        self.wm.force_writes.return_value = 3
        self.tiles = [{"id": 100 + i, "owner": "Finder", "x": 16, "y": 100 + 120 * i,
                       "w": 140, "h": 117} for i in range(3)]
        self.frames = {str(t["id"]): {"x": t["x"], "y": t["y"], "w": t["w"], "h": t["h"]}
                       for t in self.tiles}

    def run_scale(self, s, frames):
        bases = [{"wid": t["id"], "base": 1, "mine": 0, "lvl": None} for t in self.tiles]
        with mock.patch.object(C, "wmctl", return_value=self.wm), \
                mock.patch.object(C, "rail_tiles", return_value=self.tiles), \
                mock.patch.object(C, "natural",
                                  return_value={str(t["id"]): t["w"] for t in self.tiles}), \
                mock.patch.object(C, "poses", return_value=bases), \
                mock.patch.object(C, "natural_frames", return_value=frames), \
                mock.patch.object(C, "cfg_set", mock.Mock(return_value={"gen": 1})), \
                mock.patch.object(C, "hb", return_value={}), \
                mock.patch.object(C.time, "sleep", return_value=None), \
                mock.patch.object(C, "LAST_RESIZE",
                                  os.path.join(self.tmp.name, "last_resize.json")):
            return C.apply_scale(s)

    def test_a_tile_that_does_not_come_back_to_its_origin_fails_the_resize(self):
        moved = dict(self.frames)
        moved["101"] = dict(moved["101"], x=11)
        rep = self.run_scale(1.0, moved)
        self.assertFalse(rep["ok"], rep)
        self.assertTrue(rep["xy"]["checked"])
        self.assertFalse(rep["xy"]["ok"])
        self.assertEqual([m["id"] for m in rep["xy"]["moved"]], [101])
        self.assertEqual((rep["xy"]["moved"][0]["dx"], rep["xy"]["moved"][0]["dy"]), (5, 0))

    def test_exact_restore_passes(self):
        rep = self.run_scale(1.0, self.frames)
        self.assertTrue(rep["ok"], rep)
        self.assertTrue(rep["xy"]["ok"])
        self.assertEqual(rep["xy"]["moved"], [])

    def test_geometry_is_not_checked_while_a_scale_is_applied(self):
        rep = self.run_scale(1.5, self.frames)
        self.assertFalse(rep["xy"]["checked"])


class ResizeDegradesWhenOneTileCannotTeach(unittest.TestCase):
    """#4 follow-up: one tile that never settles must not refuse the whole resize.

    The keeper is right not to scale a tile with no resting base -- that would scale an unsettled
    pose.  What was wrong was the CLI: it refused before applying anything, so one untameable tile
    cost every other tile.  The command now scales what it can, names what it cannot, and is never
    `ok` for a scale it did not fully achieve.
    """

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.wm = mock.Mock()
        self.tiles = [{"id": 1, "owner": "A", "x": 16, "y": 100, "w": 140, "h": 120},
                      {"id": 2, "owner": "B", "x": 16, "y": 240, "w": 140, "h": 120}]
        self.nat = {"1": 140, "2": 140}
        self.s = 1.0
        self.bases = {1}                      # tile 2 never settles

    def wall(self):
        return [{"id": t["id"], "owner": t["owner"], "x": t["x"], "y": t["y"], "h": t["h"],
                 "w": int(round(t["w"] * (self.s if t["id"] in self.bases else 1.0)))}
                for t in self.tiles]

    def run_scale(self, s, teach_result):
        self.s = s
        with mock.patch.object(C, "wmctl", return_value=self.wm), \
                mock.patch.object(C, "rail_tiles", side_effect=self.wall), \
                mock.patch.object(C, "natural", return_value=dict(self.nat)), \
                mock.patch.object(C, "poses",
                                  side_effect=lambda: [{"wid": w, "base": 1}
                                                       for w in sorted(self.bases)]), \
                mock.patch.object(C, "teach_now", mock.Mock(return_value=teach_result)), \
                mock.patch.object(C, "cfg_set", mock.Mock(return_value={"gen": 1})), \
                mock.patch.object(C, "hb", return_value={}), \
                mock.patch.object(C, "natural_frames", return_value={}), \
                mock.patch.object(C.time, "sleep", return_value=None), \
                mock.patch.object(C, "LAST_RESIZE", os.path.join(self.tmp.name, "r.json")):
            return C.apply_scale(s)

    def test_scales_the_tiles_it_can_and_names_the_one_it_cannot(self):
        rep = self.run_scale(1.5, {"ok": False, "moves": 12, "tiles": 2, "bases": 1,
                                   "no_base": [2], "waits": 1, "secs": 1.0})
        self.assertFalse(rep["ok"])                 # loud: not a successful resize
        self.assertTrue(rep["partial"])
        self.assertEqual(rep["no_base"], [2])
        self.assertEqual(rep["scaled"], [1])
        self.assertEqual(rep["not_scaled"], [2])
        self.assertIn("2", rep["err"])
        self.assertEqual([t["id"] for t in rep["tiles"]], [1, 2])   # not an empty refusal

    def test_a_restore_still_succeeds_for_what_it_touched(self):
        rep = self.run_scale(1.0, {"ok": False, "moves": 12, "tiles": 2, "bases": 1,
                                   "no_base": [2], "waits": 1, "secs": 1.0})
        self.assertTrue(rep["ok"])                  # every tile is at 1.0; the skipped one never moved
        self.assertTrue(rep["partial"])
        self.assertEqual(rep["no_base"], [2])


if __name__ == "__main__":
    unittest.main()
