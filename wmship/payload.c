// payload.c — the in-WindowManager payload, round 29: in-memory control plane, and identity
// WITHOUT objc_msgSend.
//
// Round 27's two defects and what replaces them here:
//
//  * identity.  The only way to turn a WindowID object into the CGWindowID the window server
//    just created used to be `-description` through objc_msgSend, which always dies in this
//    payload's hands (EXC_ARM_PAC_FAIL at objc_msgSend+0x818, same fault address in three
//    processes).  This file resolves the same method with *plain C runtime calls* —
//    objc_getClass("_TtC18WindowManagerAgent8WindowID"), sel_registerName("description"),
//    class_getInstanceMethod(), method_getImplementation() — strips the arm64e signature from
//    the returned IMP and calls it with a plain `blr`.  No message dispatch, no cache walk, no
//    slow path.  The resulting "(0x<cgid>)" is matched against the CGWindowIDs the user-side
//    observer saw appear, and the object is re-checked (isa, live-instance marker, serial)
//    before it is used.
//  * ownership.  The 1-element Array<TransientWindowSetOperation> we hand back has an element
//    whose +0x00 is a *strong* reference to the WindowID; the WM destroys the array later and
//    swift_arrayDestroy releases that field.  A byte-copied element never retained it, so the
//    release is an over-release (SIGSEGV in SwiftRetainableBox::destroy).  build_array()
//    therefore calls swift_retain() once — the same retain the WM's own array would hold — so
//    the WM's destroy is balanced.  `retain:false` in the cfg is the A/B control for this.
//
// Everything else (in-memory control plane, near island, rendezvous) is round 27's.
//
// The round-24/25 payload read its inputs from /tmp/wm/*.json and wrote its outputs there.
// Inside WindowManager *every* file syscall fails (round 26 §3), so that payload ran blind and
// mute. This one never opens a file:
//
//   IN   every input is a text buffer in this image's rw page (`io_cfg`, `io_st`, `io_rq`,
//        `io_ids`, `io_pd`, `io_rg`), written through the task port by the installer/helper.
//        The payload reads them with a plain load, gated by a generation counter.
//   OUT  every output is a buffer in the same page (`io_hb`, `io_log` ring, `io_res`,
//        `io_ss`, `io_self`) plus the counters in `struct globals`, read out by the installer.
//
// The only kernel calls left are `gettimeofday` (which always worked) and the two runtime
// helpers the WM owns (objc_msgSend / SkyLight slots the installer resolves in the WM).
//
// Two structural changes versus round 25:
//   * `identify()` can *rendezvous* with the helper: it bumps `io_rdv` and spins (bounded,
//     250 ms) until the helper answers `io_rdv_ack`, which is what makes a census possible at
//     the birth call — the WM is stopped inside the driver for the duration, exactly as it was
//     inside the lldb breakpoint — without either side touching a file.
//   * the entry stubs live in the near island page (island.s); this file is the far half and
//     is reached with one `blr`.
typedef unsigned char u8;
typedef unsigned int u32;
typedef unsigned long u64;
typedef long i64;

#define OKA(a) ((a) > 0x10000UL && (a) < 0x900000000000UL)

// ---------------------------------------------------------------- kernel interface
static long sys4(long n, long a, long b, long c, long d) {
    register long x16 __asm__("x16") = n;
    register long x0 __asm__("x0") = a;
    register long x1 __asm__("x1") = b;
    register long x2 __asm__("x2") = c;
    register long x3 __asm__("x3") = d;
    __asm__ volatile("svc #0x80" : "+r"(x0) : "r"(x16), "r"(x1), "r"(x2), "r"(x3) : "memory");
    return x0;
}
#define SYS_gettimeofday 116

void *memcpy(void *d, const void *s, u64 n) {
    u8 *a = d; const u8 *b = s;
    while (n--) *a++ = *b++;
    return d;
}
void *memset(void *d, int c, u64 n) {
    u8 *a = d;
    while (n--) *a++ = (u8)c;
    return d;
}
int memcmp(const void *a, const void *b, u64 n) {
    const u8 *x = a, *y = b;
    for (u64 i = 0; i < n; i++) if (x[i] != y[i]) return x[i] - y[i];
    return 0;
}
static u64 slen(const char *s) { u64 n = 0; while (s[n]) n++; return n; }

static double now(void) {
    long tv[2] = {0, 0};
    sys4(SYS_gettimeofday, (long)tv, 0, 0, 0);
    return (double)tv[0] + (double)tv[1] / 1e6;
}
static int feq(double a, double b) { double d = a - b; if (d < 0) d = -d; return d < 1e-12; }

// ---------------------------------------------------------------- installer-filled slots
struct Slots {
    u64 driver, compute;
    u64 objc_getClass, sel_registerName, class_getInstanceMethod, method_getImplementation;
    u64 swift_retain, objc_retain;
    u64 txn_set3d, txn_set2d, txn_create, txn_level, txn_commit, cgid_main;
    u64 widmeta;
    u64 entry3d, entry2d;
    u64 magic;
};
struct Slots SL;

// ---------------------------------------------------------------- the memory control plane
// Every field is its own symbol so the installer never guesses an offset.
// How old a "window just appeared" observation may be, in seconds.  0.6 s was round 30's
// choice; on this machine the WM's placement burst for a newly launched app can end *before* the
// CGWindowID reaches CGWindowList, so every call in that burst misses.  The identity itself is
// unambiguous at any age (a CGWindowID that appeared, the WM's own serial for it, and a live
// object with that serial); what a longer window risks is acting on a *late* call, which places
// the window in its own stage instead of beside the current one - a visible wrong result, so the
// value is measured here (round 31) rather than assumed.
#define BIRTH_MAX_AGE 2.5

#define IOCFG   1536
// The state document is the keeper's whole input, and it is produced by JSONSerialization, whose
// key order is not stable.  Round 32 measured the document at 1814 B with seven stages while this
// buffer (and the helper's copy size) was 1536, so every snapshot was a *prefix*: 10/20 arrived
// with `flush` and no `rail_now`, 10/20 the mirror image, 0/20 with both.  Round 33 raises the
// buffer to 16 KB (≈60 stages of headroom at the measured 260 B/stage) and makes the publisher a
// seqlock, so a document is only accepted whole and stable (see read_state).
#define IOST    16384
#define IORQ    512
#define IOIDS   3072
#define IOPD    1024
#define IORG    3072
#define IOLOG   4096

u32  io_cfg_gen; u32 io_cfg_len; char io_cfg[IOCFG];      // cfg.json text
u32  io_st_gen;  u32 io_st_len;  char io_st[IOST];        // state.json text
u32  io_rq_gen;  u32 io_rq_len;  char io_rq[IORQ];        // one control request
u32  io_ids_gen; u32 io_ids_len; char io_ids[IOIDS];      // "<wid-hex> <serial> <epoch>" lines
u32  io_pd_gen;  u32 io_pd_len;  char io_pd[IOPD];        // cgids the observer just saw appear
u32  io_rg_gen;  u32 io_rg_len;  char io_rg[IORG];        // stage registry text
u32  io_wids_gen; u32 io_wids_len; char io_wids[8192];    // every WindowID the census knows
u32  io_widcg_gen; u32 io_widcg_len; char io_widcg[8192]; // "<cgid> <serial>" from the WM's own
                                                          // WindowIDTable map (round 30)
u32  io_rdv;  u32 io_rdv_ack;                             // census rendezvous
u32  io_ss_len;  char io_ss[64];                          // request state: new/running/done
u32  io_res_len; char io_res[256];                        // last result JSON
u32  io_hb_len;  char io_hb[1024];                        // status JSON
u32  io_poses_len; char io_poses[2048];                   // per-pose diagnostic "wid base mine lvl"
u32  io_self_len; char io_self[64];                       // self pointer, hex text
u32  io_log_w;  char io_log[IOLOG];                       // byte ring, io_log_w monotonic
u64  io_magic;
u32  io_inj_n;  u64 io_inj_wid[8]; u32 io_inj_cg[8];
u32  io_mw_n;   u64 io_mw[64];                            // diagnostic: the model at the call

static u32 iolen(u32 n, u32 max) { return n < max ? n : max - 1; }
// NEVER write into a shared io_* buffer: its length field and its text are published by another
// process in more than one write, so a NUL written at a stale length would land in the middle of
// a newer text (measured: one byte of the cfg json, and the key after it, disappeared).
// Every reader copies what it needs into a private buffer and terminates the copy.
static char B_cfg[IOCFG], B_st[IOST], B_rq[IORQ], B_ids[IOIDS], B_pd[IOPD], B_rg[IORG],
            B_wids[8192], B_widcg[8192];
static char *snap(char *dst, const char *src, u32 n, u32 max) {
    u32 k = iolen(n, max);
    for (u32 i = 0; i < k; i++) dst[i] = src[i];
    dst[k] = 0;
    return dst;
}

// ---------------------------------------------------------------- state
// One pose per window the strip has shown in the last 10 s: seven app tiles + their seven WM
// blockers + the stage's own windows already exceed round 32's 24, and `pose_get` evicts round
// robin when the table is full -- which silently dropped a tile's learned base (measured: one
// tile of six was missing from the replay).  48 leaves room for a ten-tile stage.
#define MAXP 48
#define MAXIDS 32
#define MAXUSED 24

// Two poses per window, because strip-on-top and resize want different things from a pose and
// coupling them made one capability regress whenever the other was tightened (issue #20):
//
//   base  the RESTING pose -- the one the WM writes and then stops writing.  Set only by the
//         teach gate, reset when the strip retracts.  This is the only pose that may be scaled.
//   rp    the REPLAY transform -- the last pose the WM wrote that draws the tile on screen.
//         Taught from any settled write while the strip is drawn, kept across a hide so a flush
//         has something to put back, and never scaled.
struct pose {
    u64 wid;
    u8 used, hasbase, hasmine, haslvl;
    u8 lvl;
    u8 hasrp;
    u8 pad[2];
    double t_base;      // when the resting base was taught
    u8 base[128];
    u8 rp[128];
    u8 mine[128];
    // A base is promoted, not captured: `cand` is the last legal write and `cand_ok` says a later
    // write has not contradicted it.  A hover lift and a mid-animation frame are superseded within
    // milliseconds; the resting pose is followed by silence (this build: no writes while idle).
    double cand[16];
    double t_cand;
    u8 cand_ok;
    u8 pad3[7];
    // The replay transform is promoted the same way -- a pose the WM stops writing -- but from
    // looser candidates, because on-top must not depend on the strict resting base at all.
    double rpcand[16];
    double t_rpcand;
    u8 rpcand_ok;
    u8 pad4[7];
};
struct globals {
    double t_cfg, t_state, t_req, t_pend, t_log, t_hb;
    int births, replay, dilate, levels, level_manual;
    int use_desc, retain, probe;
    int widcg;
    double s, qx, qy;
    long gen, gen_applied;
    int force, strip_on;
    // ---- state-channel health (round 33): a document is acted on only when it arrived whole
    // (seqlock-stable, complete JSON, both `flush` and `rail_now` present) and is fresh.
    int has_flush, has_rail, has_strip_on, has_frontx, st_complete, st_ok, st_trunc;
    int force_prev;
    double st_age, rail_x, hold_until, st_logged;
    double last_mx;
    int teach;             // 0 while a tool is sweeping: a hover lift must never become a base
    u64 n_st_ok, n_st_bad, n_st_busy;
    int was_out;
    int inited;
    int dump_model;
    int model_id;
    int verbose;
    int use_desc2;
    u64 dbg_x20;
    double front_x;
    u32 strip_ids[MAXIDS]; int n_strip;
    u32 rail_ids[MAXIDS]; int n_rail;
    u64 self;
    int move_pending;
    u64 mw0, mw1;
    u64 msubj;
    u64 used_ser[MAXUSED]; int n_used;
    u32 done_cgid[MAXUSED]; int n_done;
    u64 n_keep, n_learn, n_dil, n_replay, n_level, n_apply, n_inject, n_drv, n_cmp, n_miss;
    u64 n_rp;              // replay transforms refreshed (issue #20's coverage counter)
    // what the last replay actually put back: without this "the strip did not come back" cannot be
    // told apart from "the strip came back at the hidden pose" (diagnostic only)
    double dbg_rp0, dbg_rpx, dbg_rpy, dbg_b0;
    double t_out_since;    // when the document last said the strip is out (candidate validity floor)
    u64 n_rdv, n_cfg, n_birth_call, n_birth_empty, n_desc_try;
    u64 n_desc_ok, n_desc_bad, n_ret, n_rej;
    u64 n_pdwait;          // attempts deferred because no young CGWindowID was published yet
    long rdv_ms, rdv_ms_max;
    u64 last_inject_wid, last_inject_cgid, last_ser;
    double t_last_inject, t_rdv;
    int busy;
    u32 cfg_seen, st_seen, rq_seen, ids_seen;
    u32 rdv_cg;            // the candidate the last rendezvous was spent on (one per candidate)
    u64 calls_at_site[4];
    char arrp[8][0x350];
    struct pose pose[MAXP];
};
static struct globals G;

// ---------------------------------------------------------------- logging (in-memory ring)
static void logf(const char *a, const char *b, i64 v) {
    char o[200];
    int p = 0;
    double t = now();
    i64 sec = (i64)t;
    i64 ms = (i64)((t - (double)sec) * 1000.0);
    char tmp[24];
    int k = 0;
    o[p++] = '[';
    if (!sec) tmp[k++] = '0';
    while (sec) { tmp[k++] = (char)('0' + (int)(sec % 10)); sec /= 10; }
    while (k) o[p++] = tmp[--k];
    o[p++] = '.';
    k = 0;
    if (!ms) tmp[k++] = '0';
    while (ms) { tmp[k++] = (char)('0' + (int)(ms % 10)); ms /= 10; }
    while (k < 3) tmp[k++] = '0';
    while (k) o[p++] = tmp[--k];
    o[p++] = ']';
    o[p++] = ' ';
    while (*a && p < 150) o[p++] = *a++;
    if (b) while (*b && p < 176) o[p++] = *b++;
    if (v >= 0) {
        k = 0;
        if (!v) tmp[k++] = '0';
        while (v) { tmp[k++] = (char)('0' + (int)(v % 10)); v /= 10; }
        o[p++] = ' ';
        while (k) o[p++] = tmp[--k];
    }
    o[p++] = '\n';
    u32 w = io_log_w;
    for (int i = 0; i < p; i++) io_log[(w + (u32)i) % IOLOG] = o[i];
    io_log_w = w + (u32)p;
}

// ---------------------------------------------------------------- status heartbeat
static int uip(char *o, int p, u64 v) {
    char t[20];
    int k = 0;
    if (!v) t[k++] = '0';
    while (v) { t[k++] = (char)('0' + (int)(v % 10)); v /= 10; }
    while (k) o[p++] = t[--k];
    return p;
}
static int key64(char *o, int p, const char *key, u64 v) {
    o[p++] = '"';
    while (*key) o[p++] = *key++;
    o[p++] = '"';
    o[p++] = ':';
    return uip(o, p, v);
}
static void out_res(const char *s) {
    int n = (int)slen(s);
    int k = iolen((u32)n, sizeof(io_res));
    for (int i = 0; i < k; i++) io_res[i] = s[i];
    io_res_len = (u32)k;
}
static void out_res2(const char *a, u64 v, const char *b) {
    char o[160]; int p = 0;
    while (*a && p < 140) o[p++] = *a++;
    p = uip(o, p, v);
    while (*b && p < 156) o[p++] = *b++;
    for (int i = 0; i < p; i++) io_res[i] = o[i];
    io_res_len = (u32)p;
}
static void out_state(const char *s) {
    int k = 0; while (s[k] && k < 63) { io_ss[k] = s[k]; k++; }
    io_ss_len = (u32)k;
}
// Per-pose state, so "which tile was taught, which was replayed" is an observation rather than an
// inference from aggregate counters.  One line per pose: <wid> <base> <mine> <lvl>.
static void poses_write(void) {
    int p = 0;
    for (int i = 0; i < MAXP && p < (int)sizeof(io_poses) - 48; i++) {
        struct pose *q = &G.pose[i];
        if (!q->used) continue;
        p = uip(io_poses, p, q->wid); io_poses[p++] = ' ';
        p = uip(io_poses, p, q->hasbase); io_poses[p++] = ' ';
        p = uip(io_poses, p, q->hasmine); io_poses[p++] = ' ';
        p = uip(io_poses, p, q->haslvl ? q->lvl : 9); io_poses[p++] = '\n';
    }
    io_poses_len = (u32)p;
}

static void hb_write(void) {
    char *o = io_hb;
    int p = 0;
    int nb = 0, nr = 0, nrp = 0;
    for (int i = 0; i < MAXP; i++) {
        if (!G.pose[i].used) continue;
        if (G.pose[i].hasbase) nb++;
        if (G.pose[i].hasrp) nrp++;
        if (G.pose[i].haslvl && G.pose[i].lvl == 3) nr++;
    }
    o[p++] = '{';
    p = key64(o, p, "bases", (u64)nb);      o[p++] = ',';
    p = key64(o, p, "rps", (u64)nrp);       o[p++] = ',';
    p = key64(o, p, "raised", (u64)nr);     o[p++] = ',';
    p = key64(o, p, "keep", G.n_keep);      o[p++] = ',';
    p = key64(o, p, "learn", G.n_learn);    o[p++] = ',';
    p = key64(o, p, "dil", G.n_dil);        o[p++] = ',';
    p = key64(o, p, "replay", G.n_replay);  o[p++] = ',';
    p = key64(o, p, "rpn", G.n_rp);         o[p++] = ',';
    p = key64(o, p, "rp0", (u64)(i64)(G.dbg_rp0 * 1e4)); o[p++] = ',';
    p = key64(o, p, "rpx", (u64)(i64)G.dbg_rpx); o[p++] = ',';
    p = key64(o, p, "rpy", (u64)(i64)G.dbg_rpy); o[p++] = ',';
    p = key64(o, p, "b0", (u64)(i64)(G.dbg_b0 * 1e4)); o[p++] = ',';
    p = key64(o, p, "level", G.n_level);    o[p++] = ',';
    p = key64(o, p, "apply", G.n_apply);    o[p++] = ',';
    p = key64(o, p, "inject", G.n_inject);  o[p++] = ',';
    p = key64(o, p, "drv", G.n_drv);        o[p++] = ',';
    p = key64(o, p, "cmp", G.n_cmp);        o[p++] = ',';
    p = key64(o, p, "miss", G.n_miss);      o[p++] = ',';
    p = key64(o, p, "pdwait", G.n_pdwait);  o[p++] = ',';
    p = key64(o, p, "gen", (u64)G.gen);     o[p++] = ',';
    p = key64(o, p, "gen_applied", (u64)G.gen_applied); o[p++] = ',';
    p = key64(o, p, "s_milli", (u64)(G.s * 1000.0 + 0.5)); o[p++] = ',';
    p = key64(o, p, "flush", (u64)G.force); o[p++] = ',';
    p = key64(o, p, "rail", (u64)G.n_rail); o[p++] = ',';
    p = key64(o, p, "strip", (u64)G.n_strip); o[p++] = ',';
    // ---- state-channel health (round 33): read back both gate values and the document's state
    p = key64(o, p, "stok", (u64)G.st_ok); o[p++] = ',';
    p = key64(o, p, "stgood", G.n_st_ok); o[p++] = ',';
    p = key64(o, p, "stbad", G.n_st_bad); o[p++] = ',';
    p = key64(o, p, "stbusy", G.n_st_busy); o[p++] = ',';
    p = key64(o, p, "stlen", (u64)io_st_len); o[p++] = ',';
    p = key64(o, p, "stms", (u64)(i64)(G.st_age > 0 ? G.st_age * 1000.0 : 0));
    o[p++] = ',';
    p = key64(o, p, "stflush", (u64)G.has_flush); o[p++] = ',';
    p = key64(o, p, "strail", (u64)G.has_rail); o[p++] = ',';
    p = key64(o, p, "ston", (u64)G.strip_on); o[p++] = ',';
    p = key64(o, p, "stx", (u64)(i64)(G.rail_x > -1e8 ? G.rail_x : -1));
    o[p++] = ',';
    p = key64(o, p, "fx", (u64)(i64)G.front_x); o[p++] = ',';
    p = key64(o, p, "mx", (u64)(i64)G.last_mx);
    o[p++] = ',';
    p = key64(o, p, "rdv", G.n_rdv);        o[p++] = ',';
    p = key64(o, p, "rdvms", (u64)G.rdv_ms_max); o[p++] = ',';
    p = key64(o, p, "descok", G.n_desc_ok); o[p++] = ',';
    p = key64(o, p, "descbad", G.n_desc_bad); o[p++] = ',';
    p = key64(o, p, "ret", G.n_ret);        o[p++] = ',';
    p = key64(o, p, "rej", G.n_rej);        o[p++] = ',';
    p = key64(o, p, "probe", (u64)G.probe); o[p++] = ',';
    p = key64(o, p, "cfg", G.n_cfg);        o[p++] = ',';
    p = key64(o, p, "self", G.self % 1000000007UL); o[p++] = ',';
    p = key64(o, p, "t", (u64)now());
    if (p > (int)sizeof(io_hb) - 2) p = (int)sizeof(io_hb) - 2;   // never overrun the page
    o[p++] = '}';
    o[p++] = '\n';
    io_hb_len = (u32)p;
    poses_write();
}

// ---------------------------------------------------------------- tiny JSON
static const char *jkey(const char *s, const char *key) {
    int kl = 0;
    while (key[kl]) kl++;
    for (const char *p = s; *p; p++) {
        if (*p != '"') continue;
        int i = 0;
        while (i < kl && p[1 + i] == key[i]) i++;
        if (i == kl && p[1 + kl] == '"') {
            const char *q = p + 2 + kl;
            while (*q && *q != ':') q++;
            if (*q == ':') return q + 1;
        }
    }
    return 0;
}
static int jint(const char *s, const char *key, long *out) {
    const char *p = jkey(s, key);
    if (!p) return 0;
    while (*p == ' ') p++;
    int neg = 0;
    if (*p == '-') { neg = 1; p++; }
    if (*p < '0' || *p > '9') return 0;
    long v = 0;
    while (*p >= '0' && *p <= '9') v = v * 10 + (*p++ - '0');
    *out = neg ? -v : v;
    return 1;
}
static int jbool(const char *s, const char *key, int *out) {
    const char *p = jkey(s, key);
    if (!p) return 0;
    while (*p == ' ') p++;
    if (*p == 't') { *out = 1; return 1; }
    if (*p == 'f') { *out = 0; return 1; }
    return 0;
}
static int jdbl(const char *s, const char *key, double *out) {
    const char *p = jkey(s, key);
    if (!p) return 0;
    while (*p == ' ') p++;
    int neg = 0;
    if (*p == '-') { neg = 1; p++; }
    if (*p < '0' || *p > '9') return 0;
    double v = 0;
    while (*p >= '0' && *p <= '9') v = v * 10.0 + (double)(*p++ - '0');
    if (*p == '.') {
        p++;
        double f = 0.1;
        while (*p >= '0' && *p <= '9') { v += (double)(*p++ - '0') * f; f *= 0.1; }
    }
    *out = neg ? -v : v;
    return 1;
}
static int jstr(const char *s, const char *key, char *out, int max) {
    const char *p = jkey(s, key);
    if (!p) return 0;
    while (*p == ' ') p++;
    if (*p != '"') return 0;
    p++;
    int i = 0;
    while (*p && *p != '"' && i < max - 1) out[i++] = *p++;
    out[i] = 0;
    return 1;
}
static int jints(const char *s, const char *key, u32 *out, int max) {
    const char *p = jkey(s, key);
    if (!p) return 0;
    while (*p == ' ') p++;
    if (*p != '[') return 0;
    p++;
    int n = 0;
    while (*p && *p != ']' && n < max) {
        if (*p >= '0' && *p <= '9') {
            long v = 0;
            while (*p >= '0' && *p <= '9') v = v * 10 + (*p++ - '0');
            out[n++] = (u32)v;
        } else p++;
    }
    return n;
}

// ---------------------------------------------------------------- control plane, in memory
static void read_cfg(void) {
    if (!G.inited) { G.inited = 1; G.use_desc = 0; G.retain = 1; G.births = 1; G.replay = 1; G.levels = 1; G.teach = 1; G.s = 1.0; G.qx = 16.0; G.qy = 490.0; G.widcg = 1; }
    if (G.cfg_seen == io_cfg_gen) return;
    G.cfg_seen = io_cfg_gen;
    char *cfg = snap(B_cfg, io_cfg, io_cfg_len, sizeof(B_cfg));
    if (!io_cfg_len) return;
    G.n_cfg++;
    G.t_cfg = now();
    long v;
    if (jbool(cfg, "births", (int *)&v)) G.births = (int)v;
    if (jbool(cfg, "replay", (int *)&v)) G.replay = (int)v;
    if (jbool(cfg, "dilate", (int *)&v)) G.dilate = (int)v;
    if (jbool(cfg, "levels", (int *)&v)) G.levels = (int)v;
    if (jbool(cfg, "teach", (int *)&v)) G.teach = (int)v;
    if (jbool(cfg, "use_desc", (int *)&v)) G.use_desc = (int)v;
    if (jbool(cfg, "widcg", (int *)&v)) G.widcg = (int)v;
    if (jbool(cfg, "desc1", (int *)&v)) { if (v) G.use_desc = 2; }
    if (jbool(cfg, "retain", (int *)&v)) G.retain = (int)v;
    if (jbool(cfg, "probe", (int *)&v)) G.probe = (int)v;
    if (jbool(cfg, "dump_model", (int *)&v)) G.dump_model = (int)v;
    if (jbool(cfg, "model_id", (int *)&v)) G.model_id = (int)v;
    if (jbool(cfg, "verbose", (int *)&v)) G.verbose = (int)v;
    if (jint(cfg, "level_manual", &v)) G.level_manual = (int)v;
    jdbl(cfg, "s", &G.s);
    jdbl(cfg, "qx", &G.qx);
    jdbl(cfg, "qy", &G.qy);
    if (jint(cfg, "gen", &v)) G.gen = v;
}
static int in_ids(u32 wid, const u32 *ids, int n) {
    for (int i = 0; i < n; i++) if (ids[i] == wid) return 1;
    return 0;
}

// The strip's own rect x, taken from the `rail` array for a window that is drawn in the gutter
// right now.  `rail_now` already implies minX >= 0, but the on-top / learn gate is stated as
// "the strip rect x >= 0", so it is read and asserted rather than inferred.  JSONSerialization
// does not preserve key order, so each item is isolated before its keys are read.
//
// The answer is the **minimum** x over every window in `rail_now`, not the maximum (round 34):
// with the maximum, one tile that had not retracted yet kept the gate open while the other five
// walked to the hidden pose, and the keeper learned the retract (measured: learn +1317 in a 2 s
// flush and 4 of 6 tiles lost).  The strip is out only when *every* window in the rail is drawn
// at x >= 0.
static double rail_rect_x(const char *st) {
    double best = 1e9;
    if (!G.n_rail) return -1e9;
    const char *p = jkey(st, "rail");
    if (!p) return best;
    for (const char *q = p; *q && *q != ']'; q++) {
        if (*q != '{') continue;
        const char *e = q;
        int depth = 0;
        while (*e) {
            if (*e == '{') depth++;
            else if (*e == '}' && --depth == 0) break;
            e++;
        }
        if (*e != '}') break;
        int len = (int)(e - q + 1);
        if (len > 1 && len < 256) {
            char it[256];
            for (int i = 0; i < len; i++) it[i] = q[i];
            it[len] = 0;
            long id = 0;
            double x = 0;
            if (jint(it, "id", &id) && jdbl(it, "x", &x) && in_ids((u32)id, G.rail_ids, G.n_rail)
                && x < best) best = x;
        }
        q = e;
    }
    return best == 1e9 ? -1e9 : best;
}

// Accept a state document only if the helper's seqlock is even (not mid-write) and did not change
// under the copy, it is complete JSON, and it carries both of the keys the keeper acts on.
static void state_freshness(void) {
    G.st_age = G.t_state > 0 ? now() - G.t_state : 1e9;
    G.st_ok = G.st_complete && !G.st_trunc && G.has_flush && G.has_rail
              && G.st_age <= 0.5 && G.t_state > 0;
}
static void read_state(void) {
    u32 g0 = io_st_gen;
    if (g0 == G.st_seen) { state_freshness(); return; }
    if (g0 & 1) { G.n_st_busy++; state_freshness(); return; }   // publisher mid-write
    if (!io_st_len) { state_freshness(); return; }
    G.st_trunc = io_st_len >= IOST;
    char *st = snap(B_st, io_st, io_st_len, sizeof(B_st));
    u32 g1 = io_st_gen;
    if (g1 != g0) { G.n_st_busy++; state_freshness(); return; }  // torn: keep the last good doc
    G.st_seen = g0;
    G.t_state = now();
    // completeness: the last non-space byte of the document is its closing brace
    int done = 0;
    for (int i = (int)iolen(io_st_len, sizeof(B_st)) - 1; i >= 0; i--) {
        char c = st[i];
        if (c == ' ' || c == '\n' || c == '\r' || c == '\t') continue;
        done = (c == '}');
        break;
    }
    G.st_complete = done;
    long v;
    G.has_flush = jbool(st, "flush", (int *)&v);
    if (G.has_flush) G.force = (int)v;
    G.has_strip_on = jbool(st, "strip_on", (int *)&v);
    if (G.has_strip_on) G.strip_on = (int)v;
    G.has_frontx = jdbl(st, "front_x", &G.front_x);
    G.n_strip = jints(st, "strip_ids", G.strip_ids, MAXIDS);
    G.has_rail = jkey(st, "rail_now") != 0;
    G.n_rail = jints(st, "rail_now", G.rail_ids, MAXIDS);
    G.rail_x = rail_rect_x(st);
    state_freshness();
    if (G.st_ok) G.n_st_ok++;
    else {
        G.n_st_bad++;
        if (now() - G.st_logged > 1.0) {
            G.st_logged = now();
            logf("STATE not-ok len=", 0, (i64)io_st_len);
        }
    }
}

// Ask the helper for a fresh census and wait (bounded) for the answer. Nobody blocks forever:
// a dead helper costs one 250 ms stall and no injection.
static int rendezvous(int ms) {
    u32 s = ++io_rdv;
    double t0 = now();
    for (;;) {
        if (io_rdv_ack == s) break;
        if ((now() - t0) * 1000.0 > (double)ms) break;
    }
    long el = (long)((now() - t0) * 1000.0);
    G.n_rdv++;
    G.rdv_ms = el;
    if (el > G.rdv_ms_max) G.rdv_ms_max = el;
    return io_rdv_ack == s;
}

static struct pose *pose_get(u32 wid, int make) {
    for (int i = 0; i < MAXP; i++)
        if (G.pose[i].used && G.pose[i].wid == wid) return &G.pose[i];
    if (!make) return 0;
    for (int i = 0; i < MAXP; i++)
        if (!G.pose[i].used) {
            memset(&G.pose[i], 0, sizeof(struct pose));
            G.pose[i].used = 1;
            G.pose[i].wid = wid;
            return &G.pose[i];
        }
    static int rr;
    struct pose *p = &G.pose[rr++ % MAXP];
    memset(p, 0, sizeof(struct pose));
    p->used = 1;
    p->wid = wid;
    return p;
}

// ---------------------------------------------------------------- in-process helpers
static u64 rd64(u64 a) { return *(volatile u64 *)a; }
static u32 rd32(u64 a) { return *(volatile u32 *)a; }
static void wr64(u64 a, u64 v) { *(volatile u64 *)a = v; }

// ---------------------------------------------------------------- identity, without objc_msgSend
//
// A WindowID is a 0x18-byte Swift object: isa, refcount|flags, serial.  Round 30 measured
// instanceSize == 0x18, so there is NO fourth word: an earlier build tested `+0x18 == 0` and was
// in fact reading the *next* object in the malloc zone, which made identification depend on
// allocation order (round 31: 8 misses in a row, "WIDCG noobj ser=119" while all three data
// sources agreed).  The isa carries a PAC/tag in its top 16 bits, so it is compared masked; that
// is what distinguishes a real instance from the ~300 heap words that merely *contain* the class
// pointer, together with the live-instance marker at +8 and the serial range.  The candidate is
// never trusted on this test alone: it is the serial the WM's own WindowIDTable gave for the
// CGWindowID that just appeared, and a serial is never used twice.
static int is_wid(u64 a) {
    if (!OKA(a) || (a & 7)) return 0;
    if ((rd64(a) & 0x7FFFFFFFFFFFUL) != (SL.widmeta & 0x7FFFFFFFFFFFUL)) return 0;
    if ((rd32(a + 8) & 7) != 3) return 0;               // live instance marker (…0003)
    u64 ser = rd64(a + 0x10);
    if (!ser || ser >= 0x100000) return 0;              // serial: small, non-zero
    return 1;
}

// Resolve "-description" with plain C runtime calls and call the IMP directly.  Nothing here is
// a message send: objc_getClass / sel_registerName / class_getInstanceMethod /
// method_getImplementation are ordinary C functions, and `blr` to the unsigned IMP is the same
// transfer round 26 proved safe for any callee.  The method returns an NSString; UTF8String is
// resolved the same way.
static u64 g_cls, g_desc_sel, g_desc_imp, g_utf8_sel, g_utf8_imp;
static int g_desc_state;                 // 0 = untried, 1 = ready, -1 = unavailable
static int desc_init(void) {
    if (g_desc_state) return g_desc_state > 0;
    g_desc_state = -1;
    if (!SL.objc_getClass || !SL.sel_registerName || !SL.class_getInstanceMethod ||
        !SL.method_getImplementation) return 0;
    u64 (*gc)(const char *) = (u64 (*)(const char *))SL.objc_getClass;
    u64 (*sr)(const char *) = (u64 (*)(const char *))SL.sel_registerName;
    u64 (*gm)(u64, u64) = (u64 (*)(u64, u64))SL.class_getInstanceMethod;
    u64 (*gi)(u64) = (u64 (*)(u64))SL.method_getImplementation;
    u64 cls = gc("_TtC18WindowManagerAgent8WindowID");
    if (!cls) return 0;
    g_cls = cls;
    g_desc_sel = sr("description");
    if (!g_desc_sel) return 0;
    u64 m = gm(cls, g_desc_sel);
    if (!m) return 0;
    u64 imp = gi(m) & 0x7FFFFFFFFFFFUL;                 // strip the arm64e signature
    if (!OKA(imp)) return 0;
    g_desc_imp = imp;
    u64 ns = gc("NSString");
    g_utf8_sel = sr("UTF8String");
    if (ns && g_utf8_sel) {
        u64 m2 = gm(ns, g_utf8_sel);
        if (m2) {
            u64 i2 = gi(m2) & 0x7FFFFFFFFFFFUL;
            if (OKA(i2)) g_utf8_imp = i2;
        }
    }
    g_desc_state = 1;
    return 1;
}
static const char *wid_desc(u64 wid) {
    if (!desc_init()) return 0;
    if (!is_wid(wid)) return 0;
    u64 s = ((u64 (*)(u64, u64))g_desc_imp)(wid, g_desc_sel);
    if (!OKA(s)) return 0;
    if (!g_utf8_imp) return 0;
    u64 u = ((u64 (*)(u64, u64))g_utf8_imp)(s, g_utf8_sel);
    if (!OKA(u)) return 0;
    return (const char *)u;
}
// "(0x<hex>)" out of "TextEdit(0x1409): title"
static u32 cgid_from_desc(const char *s) {
    if (!s) return 0;
    for (const char *p = s; *p; p++) {
        if (p[0] == '(' && p[1] == '0' && p[2] == 'x') {
            u32 v = 0; int any = 0;
            for (const char *q = p + 3; ; q++) {
                char c = *q; int d = -1;
                if (c >= '0' && c <= '9') d = c - '0';
                else if (c >= 'a' && c <= 'f') d = c - 'a' + 10;
                else break;
                v = v * 16 + (u32)d;
                any = 1;
            }
            if (any) return v;
        }
    }
    return 0;
}
static u32 wid_cgid_raw(u64 wid) { return cgid_from_desc(wid_desc(wid)); }
#define CGID_CACHE 24
static u64 cc_wid[CGID_CACHE];
static u32 cc_cg[CGID_CACHE];
static int cc_n;
static u32 wid_cgid(u64 wid) {
    for (int i = 0; i < cc_n; i++) if (cc_wid[i] == wid) return cc_cg[i];
    u32 r = wid_cgid_raw(wid);
    if (r && cc_n < CGID_CACHE) { cc_wid[cc_n] = wid; cc_cg[cc_n] = r; cc_n++; }
    return r;
}
static void desc_copy(u64 wid, char *out, int max) {
    out[0] = 0;
    const char *s = wid_desc(wid);
    if (!s) return;
    int i = 0;
    while (*s && i < max - 1) out[i++] = *s++;
    out[i] = 0;
}

// the 1-element Array<TransientWindowSetOperation>; the header comes from the WM's own array
static const u64 ELEM[18] = {
    0x0000000000000000UL, 0x001200316F77AE00UL, 0x0001010000120000UL, 0x000000016F000001UL,
    0x4040000000000000UL, 0x002E006D01010101UL, 0xC63F000000160000UL, 0x4048000000000000UL,
    0x3FF0000000000000UL, 0x3FD0000000000000UL, 0x3FC0000000000000UL, 0x4014000000000000UL,
    0x3FD0000000000000UL, 0x3FF0000000000000UL, 0x3F50624DD2F1A9FCUL, 0x3F50624DD2F1A9FCUL,
    0x0000000000000332UL, 0x0000000000000000UL};

static u64 build_array(u64 src, u64 wid) {
    if (!OKA(src) || !wid) return 0;
    // validate identity BEFORE the object is used for anything
    if (!is_wid(wid)) { G.n_rej++; return 0; }
    static int arr_i;
    char *a = G.arrp[arr_i++ & 7];
    memset(a, 0, sizeof(G.arrp[0]));
    memcpy(a, (const void *)src, 0x20);
    for (int i = 0; i < 18; i++) memcpy(a + 0x20 + 8 * i, &ELEM[i], 8);
    memcpy(a + 0x20, &wid, 8);
    u64 w;
    w = 0x3F; memcpy(a + 0x08, &w, 8);          // array refcount: never deallocated
    w = 1;    memcpy(a + 0x10, &w, 8);          // count
    w = 2;    memcpy(a + 0x18, &w, 8);          // capacity
    u64 chk = 0; memcpy(&chk, a + 0x20, 8);
    if (chk != wid) return 0;
    // The element's +0x00 is a strong reference.  A byte copy does not retain it; the WM's
    // swift_arrayDestroy will release it, so the array must own one reference of its own.
    // swift_retain is a plain function (no dispatch); the A/B control `retain:false` skips it.
    if (G.retain) {
        if (!SL.swift_retain) return 0;
        ((u64 (*)(u64))SL.swift_retain)(wid);
        G.n_ret++;
    }
    return (u64)a;
}

#define MAXTRIED 16
static u64 g_tried[MAXTRIED];
static int g_ntried;
static int tried_wid(u64 wid) {
    for (int i = 0; i < g_ntried; i++) if (g_tried[i] == wid) return 1;
    return 0;
}
static void mark_tried(u64 wid) {
    if (g_ntried < MAXTRIED) g_tried[g_ntried++] = wid;
    else { for (int i = 1; i < MAXTRIED; i++) g_tried[i - 1] = g_tried[i]; g_tried[MAXTRIED - 1] = wid; }
}
static int used_wid(u64 wid) {
    for (int i = 0; i < G.n_used; i++) if (G.used_ser[i] == wid) return 1;
    return 0;
}
static void mark_wid(u64 wid) {
    if (G.n_used < MAXUSED) G.used_ser[G.n_used++] = wid;
    else { for (int i = 1; i < MAXUSED; i++) G.used_ser[i - 1] = G.used_ser[i]; G.used_ser[MAXUSED - 1] = wid; }
}
static int done_cgid(u32 cg) {
    for (int i = 0; i < G.n_done; i++) if (G.done_cgid[i] == cg) return 1;
    return 0;
}
static void mark_cgid(u32 cg) {
    if (G.n_done < MAXUSED) G.done_cgid[G.n_done++] = cg;
    else { for (int i = 1; i < MAXUSED; i++) G.done_cgid[i - 1] = G.done_cgid[i]; G.done_cgid[MAXUSED - 1] = cg; }
}

// CGWindowID -> WindowID, data only: the WM's own WindowIDTable map gives the serial, and the
// helper's census gives an object with that serial.  This replaces the round-24/27 version, which
// walked the registry and called -description per member (unusable in this payload).
static u64 resolve_cgid(u32 cgid) {
    if (!cgid) return 0;
    snap(B_widcg, io_widcg, io_widcg_len, sizeof(B_widcg));
    snap(B_wids, io_wids, io_wids_len, sizeof(B_wids));
    u64 ser = 0;
    {
        const char *m = B_widcg;
        while (*m) {
            u32 c = 0, se = 0; int any = 0;
            while (*m >= '0' && *m <= '9') { c = c * 10 + (u32)(*m++ - '0'); any = 1; }
            while (*m == ' ') m++;
            while (*m >= '0' && *m <= '9') { se = se * 10 + (u32)(*m++ - '0'); }
            while (*m && *m != '\n') m++;
            if (*m == '\n') m++;
            if (any && c == cgid) { ser = se; break; }
        }
    }
    if (!ser) return 0;
    const char *q = B_wids;
    while (*q) {
        u64 a = 0, s2 = 0; int any = 0;
        while (*q && *q != ' ' && *q != '\n') { char c = *q; int d = -1;
            if (c >= '0' && c <= '9') d = c - '0';
            else if (c >= 'a' && c <= 'f') d = c - 'a' + 10;
            if (d < 0) break; a = (a << 4) | (u64)d; q++; any = 1; }
        while (*q == ' ') q++;
        while (*q >= '0' && *q <= '9') s2 = s2 * 10 + (u64)(*q++ - '0');
        while (*q && *q != '\n') q++;
        if (*q == '\n') q++;
        if (!any || s2 != ser) continue;
        if (is_wid(a)) return a;
    }
    return 0;
}

// The newborn: the newest WindowID the helper discovered in this very rendezvous.
//
// The lldb round-18 module matched on the WM's own `-description` ("(0x<cgid>)"). This payload
// cannot: sending objc_msgSend to a freshly allocated, possibly already released WindowID took
// WindowManager down twice in this round (EXC_ARM_PAC_FAIL inside objc_msgSend, identical fault
// both times), so identification is done on the *serial* instead — WindowIDs are allocated with
// monotonically increasing serials, the newborn is the highest one seen since the last census,
// and the census that produced the list ran 10-40 ms ago inside the same rendezvous. Freshness
// is enforced (< 1.0 s), usage is remembered, and nothing is dereferenced here: the helper
// validated isa and serial out of process, where a bad read is just a failed mach_vm_read.
// The newborn is the one fresh WindowID that is *not yet a member of any stage set*: every other
// live window is in one. This replaces the round-18 `-description` match, because calling
// objc_msgSend from this payload is not safe (measured four times this round: the first cache
// miss dies with EXC_ARM_PAC_FAIL at objc_msgSend+0x818, same fault address every time).
static int rg_member(u64 wid) {
    snap(B_rg, io_rg, io_rg_len, sizeof(B_rg));
    char hex[20];
    int k = 0;
    u64 v = wid;
    if (!v) hex[k++] = '0';
    while (v) { hex[k++] = "0123456789abcdef"[v & 15]; v >>= 4; }
    char pat[24];
    int n = 0;
    pat[n++] = ' ';
    while (k) pat[n++] = hex[--k];
    pat[n++] = ' ';
    pat[n] = 0;
    for (const char *p = B_rg; *p; p++) {
        int i = 0;
        while (pat[i] && p[i] == pat[i]) i++;
        if (!pat[i]) return 1;
    }
    return 0;
}

// Membership in the helper's census list.  This is the *only* way the payload may look at a
// pointer it did not itself obtain from the census: every address in io_wids was read
// successfully by the helper first, so dereferencing it here cannot fault on an unmapped page
// (measuring that the hard way cost one WindowManager: a model word that happened to be a page
// base was dereferenced by a blind is_wid() scan and the WM took SIGSEGV at that page).
static u64 in_wids(u64 a) {
    if (!a || (a & 7)) return 0;
    const char *p = snap(B_wids, io_wids, io_wids_len, sizeof(B_wids));
    while (*p) {
        u64 v = 0, ser = 0; int any = 0;
        while (*p && *p != ' ' && *p != '\n') { char c = *p; int d = -1;
            if (c >= '0' && c <= '9') d = c - '0';
            else if (c >= 'a' && c <= 'f') d = c - 'a' + 10;
            if (d < 0) break; v = (v << 4) | (u64)d; p++; any = 1; }
        if (any && v == a) {
            while (*p == ' ') p++;
            while (*p >= '0' && *p <= '9') ser = ser * 10 + (u64)(*p++ - '0');
            return ser ? ser : 1;
        }
        while (*p && *p != '\n') p++;
        if (*p == '\n') p++;
    }
    return 0;
}

// Scan the WM's model (x20 at the driver call) for WindowID addresses that the census knows.
// Only membership is tested here — no pointer is dereferenced until it is known to be one.
static int model_scan(u64 *out, int max, int *n_out) {
    *n_out = 0;
    if (!OKA(G.dbg_x20) || max < 1) return 0;
    int n = 0;
    for (int i = 0; i < 64; i++) {
        u64 v = rd64(G.dbg_x20 + 8 * i);
        if (!in_wids(v)) continue;
        int dup = 0;
        for (int j = 0; j < n; j++) if (out[j] == v) dup = 1;
        if (dup) continue;
        if (n < max) out[n++] = v;
    }
    *n_out = n;
    return n;
}

// io_pd lines are "<cgid> <first_seen_epoch>"; the epoch is the user-side observer's NEW
// timestamp, which is the only ordering the payload has for "which of these appeared last".
static double pd_ts(u32 cg) {
    if (!cg) return 0;
    const char *p = snap(B_pd, io_pd, io_pd_len, sizeof(B_pd));
    while (*p) {
        u32 v = 0; int any = 0;
        while (*p >= '0' && *p <= '9') { v = v * 10 + (u32)(*p++ - '0'); any = 1; }
        if (any && v == cg) {
            while (*p == ' ') p++;
            double ts = 0;
            while (*p >= '0' && *p <= '9') ts = ts * 10 + (double)(*p++ - '0');
            if (*p == '.') { p++; double f = 0.1; while (*p >= '0' && *p <= '9') { ts += (double)(*p++ - '0') * f; f *= 0.1; } }
            return ts;
        }
        while (*p && *p != '\n') p++;
        if (*p == '\n') p++;
    }
    return 0;
}
static int pd_has(u32 cg) { return pd_ts(cg) != 0.0; }

// Windows owned by the window server's own helper services are never the newborn we want;
// injecting one (measured: an "Open and Save Panel Service" panel) is harmless here but it is
// noise, and a panel is not an app window.
static int sys_desc(const char *d) {
    static const char *bad[] = {"Open and Save", "CursorUIViewService", "Window Server",
                                "Dock(", "Notification Center", "Control Center", "Spotlight",
                                "AutoFill", "TextInputMenu", "WeatherMenu", "Siri", "loginwindow"};
    for (unsigned i = 0; i < sizeof(bad) / sizeof(bad[0]); i++) {
        const char *a = d, *b = bad[i];
        while (*a && *b && *a == *b) { a++; b++; }
        if (!*b) return 1;
    }
    return 0;
}

// The *cheap* half of the identity: does io_pd already publish a window young enough to be the
// newborn, and not already placed?  One 1 KiB page snapshot — no census, no rendezvous, nothing
// that stops WindowManager.  It decides only whether an attempt is worth making; it never
// chooses a window.
static int fresh_candidate(void) {
    double t = now();
    const char *q = snap(B_pd, io_pd, io_pd_len, sizeof(B_pd));
    while (*q) {
        u32 cg = 0; int any = 0;
        while (*q >= '0' && *q <= '9') { cg = cg * 10 + (u32)(*q++ - '0'); any = 1; }
        while (*q == ' ') q++;
        double ts = 0;
        while (*q >= '0' && *q <= '9') ts = ts * 10 + (double)(*q++ - '0');
        if (*q == '.') { q++; double f = 0.1; while (*q >= '0' && *q <= '9') { ts += (double)(*q++ - '0') * f; f *= 0.1; } }
        while (*q && *q != '\n') q++;
        if (*q == '\n') q++;
        if (any && cg && !done_cgid(cg) && t - ts <= BIRTH_MAX_AGE) return 1;
    }
    return 0;
}

// (1)+(2)+(3) of the shipped identity, decided from buffers the helper has already published:
// the newest young CGWindowID that is not placed, its serial from the WM's own WindowIDTable, and
// a live WindowID object with that serial.  Returns the object to inject, or 0.
//
// `*need` says why 0 came back, because the two answers need different actions:
//   0  nothing to identify            — a rendezvous cannot help;
//   1  a young CGWindowID has no serial in the table yet;
//   2  a serial has no live object in the census yet.
// Both 1 and 2 mean the published buffers are from before this window existed, which is what a
// rendezvous (one helper pass with the WM parked) fixes.
static u64 pick_widcg(u32 *out_cg, u32 *newest_cg, int *need) {
    *out_cg = 0; *newest_cg = 0; *need = 0;
    u32 tgt_cg = 0; u64 tgt_ser = 0; double tgt_ts = -1.0;
    u32 young = 0; double young_ts = -1.0;
    const char *q = B_pd;
    while (*q) {
        u32 cg = 0; int any = 0;
        while (*q >= '0' && *q <= '9') { cg = cg * 10 + (u32)(*q++ - '0'); any = 1; }
        while (*q == ' ') q++;
        double ts = 0;
        while (*q >= '0' && *q <= '9') ts = ts * 10 + (double)(*q++ - '0');
        if (*q == '.') { q++; double f = 0.1; while (*q >= '0' && *q <= '9') { ts += (double)(*q++ - '0') * f; f *= 0.1; } }
        while (*q && *q != '\n') q++;
        if (*q == '\n') q++;
        if (!any || !cg || done_cgid(cg)) continue;
        // Only act at the birth moment.  A late identify (after the WM has already surfaced the
        // app's new stage) would be applied to *that* stage, which looks like a full-size window
        // all by itself; BIRTH_MAX_AGE is ~7x the measured create->inject latency and still well
        // inside the WM's placement tail.
        if (now() - ts > BIRTH_MAX_AGE) continue;
        if (ts > young_ts) { young_ts = ts; young = cg; }
        // the WM's map: serial for this CGWindowID
        u64 ser = 0;
        if (io_widcg_len) {
            const char *m = B_widcg;
            while (*m) {
                u32 c = 0, se = 0; int a2 = 0;
                while (*m >= '0' && *m <= '9') { c = c * 10 + (u32)(*m++ - '0'); a2 = 1; }
                while (*m == ' ') m++;
                while (*m >= '0' && *m <= '9') { se = se * 10 + (u32)(*m++ - '0'); }
                while (*m && *m != '\n') m++;
                if (*m == '\n') m++;
                if (a2 && c == cg) { ser = se; break; }
            }
        }
        if (!ser) continue;
        if (ts > tgt_ts) { tgt_ts = ts; tgt_cg = cg; tgt_ser = ser; }
    }
    *newest_cg = young;
    if (!tgt_cg) { *need = 1; return 0; }          // the window is not in the WM's table yet
    // (3) a live WindowID object with that serial, straight out of the helper's census
    const char *w = B_wids;
    while (*w) {
        u64 a = 0, s2 = 0; int any2 = 0;
        while (*w && *w != ' ' && *w != '\n') { char c = *w; int d = -1;
            if (c >= '0' && c <= '9') d = c - '0';
            else if (c >= 'a' && c <= 'f') d = c - 'a' + 10;
            if (d < 0) break; a = (a << 4) | (u64)d; w++; any2 = 1; }
        while (*w == ' ') w++;
        while (*w >= '0' && *w <= '9') s2 = s2 * 10 + (u64)(*w++ - '0');
        while (*w && *w != '\n') w++;
        if (*w == '\n') w++;
        if (!any2 || s2 != tgt_ser) continue;
        if (used_wid(a) || tried_wid(a)) continue;
        if (!is_wid(a)) continue;
        // The WM puts a newborn in its own new stage set almost immediately, so "not a member of
        // any set" is not a usable gate here (measured: rejecting on it made 2 of 3 births miss).
        // Membership is logged instead; the gate is the three-way agreement above plus "never
        // used twice".
        if (rg_member(a)) G.n_rej++;   // diagnostic only
        G.last_ser = tgt_ser;
        *out_cg = tgt_cg;
        logf("PICKCG serial=", 0, (i64)tgt_ser);
        logf("PICKCG cgid=", 0, (i64)tgt_cg);
        return a;
    }
    *need = 2;                                     // serial known, object census is stale
    return 0;
}

// identify the newborn at the birth call.
//
// The census the helper runs during the rendezvous is exact: WindowManager is parked inside this
// function, so no object can be freed between the helper's read and our use.  io_ids therefore
// lists objects that are alive *right now*; io_pd lists CGWindowIDs the user-side observer saw
// appear in the last few seconds.  A candidate is accepted only when all of these hold:
//   * is_wid()  — masked isa, live-instance marker, serial range, zero tail;
//   * its own -description (called through the resolved IMP, never objc_msgSend) parses to a
//     CGWindowID;
//   * that CGWindowID is in io_pd — two independent views of the same window agree.
// Measured this round: reading descriptions *inside* WindowManager is unsafe even when it
// returns the right string; repeated use makes the WM exit within seconds (see round29.md §3).
// The shipped identity is therefore the data-only path: `use_desc:false` — newest serial from a
// census of validated WindowID objects, never in the WM's stage registry, never dereferenced
// unless the helper read it first.
static u64 identify(u32 *out_cg) {
    *out_cg = 0;
    double t0 = now();

    // ---- round 37: an attempt is only worth making once the observer has published a window
    // young enough to be the newborn.
    //
    // Measured on this machine: for a new document in an *already running* app the WM's
    // placement burst is ~110 ms (10 driver calls) and it starts before the CGWindowID reaches
    // CGWindowList, so the first call is always too early.  Spending the one attempt allowed per
    // 400 ms there loses the whole burst even though the observer publishes the window *inside*
    // it (9805: published 7871.626, burst 7871.626-7871.738, one attempt, 8 calls suppressed,
    // the window became a strip tile).  A call that has no young CGWindowID in io_pd cannot
    // identify anything, so it is deferred here without touching t_rdv and without a census: the
    // attempt is still available when the data arrives.
    if (G.widcg && !G.model_id && !fresh_candidate()) { G.n_pdwait++; G.n_miss++; return 0; }

    // One attempt every 400 ms, whatever the outcome.  This site is entered ~20 times for one
    // birth *and* for every unrelated empty placement call, and each attempt stops the WM while
    // the helper censuses; an earlier build that re-armed on every miss spent most of a second
    // inside this function and WindowManager was restarted (no crash report - a watchdog kill).
    if (G.t_rdv > 0 && now() - G.t_rdv < 0.40) { G.n_miss++; return 0; }
    G.t_rdv = now();
    t0 = G.t_rdv;

    // ---- round 37: ask for a fresh helper pass when the published buffers cannot complete the
    // identity yet, not merely when io_ids_gen happens to have moved.
    //
    // io_ids_gen is bumped by the helper's 2 s census; it says nothing about whether the table
    // and the object census already *contain this window*.  The old rule skipped the rendezvous
    // exactly when the census was recent — which on a short burst means the one attempt reads a
    // table from before the newborn existed (9805: its serial reached io_widcg at 7872.85, the
    // burst ended at 7871.74) and the window is lost.  Deciding from the data instead keeps the
    // cost bounded: at most one rendezvous per 400 ms and at most one per candidate, because a
    // candidate that is missing after a rendezvous will not appear later either.
    u64 sel = 0;
    if (G.widcg && !G.model_id) {
        u32 newest = 0; int need = 0;
        snap(B_pd, io_pd, io_pd_len, sizeof(B_pd));
        snap(B_widcg, io_widcg, io_widcg_len, sizeof(B_widcg));
        snap(B_wids, io_wids, io_wids_len, sizeof(B_wids));
        sel = pick_widcg(out_cg, &newest, &need);
        if (!sel && need && newest && newest != G.rdv_cg) {
            G.rdv_cg = newest;
            if (!rendezvous(120)) { G.n_miss++; return 0; }
            G.ids_seen = io_ids_gen;
            snap(B_pd, io_pd, io_pd_len, sizeof(B_pd));
            snap(B_widcg, io_widcg, io_widcg_len, sizeof(B_widcg));
            snap(B_wids, io_wids, io_wids_len, sizeof(B_wids));
            sel = pick_widcg(out_cg, &newest, &need);
        }
        if (!sel) {
            G.n_miss++;
            if (need) logf("WIDCG incomplete cg=", 0, (i64)newest);
            return 0;
        }
        G.n_desc_ok++;
        return sel;
    }

    if (G.ids_seen == io_ids_gen) {
        if (!rendezvous(120)) { G.n_miss++; return 0; }
    }
    G.ids_seen = io_ids_gen;
    snap(B_ids, io_ids, io_ids_len, sizeof(B_ids));
    snap(B_pd, io_pd, io_pd_len, sizeof(B_pd));
    snap(B_wids, io_wids, io_wids_len, sizeof(B_wids));
    if (!io_ids_len || !io_pd_len) { G.n_miss++; return 0; }

    // ---- 0. identity straight out of the WM's own model (no census ranking, no description
    // needed to *find* it; the description is still used to confirm the CGWindowID).
    u64 mv[8]; int mn = 0;
    model_scan(mv, 8, &mn);
    if (G.model_id) {
        if (mn != 1) { G.n_rej++; G.n_miss++; logf("MODEL noid n=", 0, (i64)mn); return 0; }
        u64 wid = mv[0];
        if (!is_wid(wid)) { G.n_rej++; G.n_miss++; return 0; }
        u32 cg = 0;
        if (G.use_desc) {
            const char *d = wid_desc(wid);
            cg = cgid_from_desc(d);
            if (!cg || !pd_has(cg)) {
                G.n_rej++; G.n_miss++;
                logf("MODEL-DESC-MISS ", d ? d : "<none>", (i64)cg);
                return 0;
            }
            if (d) logf("MODEL-DESC ", d, (i64)cg);
        }
        *out_cg = cg;
        return wid;
    }

    if (G.use_desc == 2) {
        // One description call per birth: choose the newest WindowID by serial first, then
        // validate exactly that one.  Reading many descriptions inside the WM is what killed it.
        const char *q = B_ids;
        double tt = now();
        u64 wid = 0, ser = 0;
        while (*q) {
            u64 w = 0, sr = 0; int any = 0;
            while (*q == ' ' || *q == '\n') q++;
            while (*q && *q != ' ' && *q != '\n') { char c = *q; int d = -1;
                if (c >= '0' && c <= '9') d = c - '0';
                else if (c >= 'a' && c <= 'f') d = c - 'a' + 10;
                if (d < 0) break; w = (w << 4) | (u64)d; q++; any = 1; }
            while (*q == ' ') q++;
            while (*q >= '0' && *q <= '9') sr = sr * 10 + (u64)(*q++ - '0');
            while (*q == ' ') q++;
            double ts = 0;
            while (*q >= '0' && *q <= '9') ts = ts * 10 + (double)(*q++ - '0');
            if (*q == '.') { q++; double f = 0.1; while (*q >= '0' && *q <= '9') { ts += (double)(*q++ - '0') * f; f *= 0.1; } }
            while (*q && *q != '\n') q++;
            if (*q == '\n') q++;
            if (!any || !w || used_wid(w) || tried_wid(w)) continue;
            if (ts + 0.05 < t0 || tt - ts > 1.5) continue;
            if (!is_wid(w)) { mark_tried(w); continue; }
            if (rg_member(w)) { mark_tried(w); continue; }
            if (!wid || sr > ser) { wid = w; ser = sr; }
        }
        if (wid) {
            mark_tried(wid);                       // one attempt per object
            const char *d = wid_desc(wid);
            u32 cg = cgid_from_desc(d);
            double pts = pd_ts(cg);
            logf("DESC1 ", d ? d : "<none>", (i64)cg);
            if (cg && pts > 0 && !sys_desc(d ? d : "")) {
                G.n_desc_ok++;
                *out_cg = cg;
                G.last_ser = ser;
                logf("PICK1 ", 0, (i64)cg);
                return wid;
            }
            G.n_desc_bad++;
        }
        G.n_miss++;
        return 0;
    }
    const char *p = B_ids;
    double t = now();
    u64 pick = 0, pick_ser = 0;
    u32 pick_cg = 0;
    char dbuf[64];
    double best_score = -1.0;
    int ndesc = 0;
    while (*p) {
        u64 wid = 0, ser = 0;
        int any = 0;
        while (*p == ' ' || *p == '\n') p++;
        while (*p && *p != ' ' && *p != '\n') { char c = *p; int d = -1;
            if (c >= '0' && c <= '9') d = c - '0';
            else if (c >= 'a' && c <= 'f') d = c - 'a' + 10;
            if (d < 0) break; wid = (wid << 4) | (u64)d; p++; any = 1; }
        while (*p == ' ') p++;
        while (*p >= '0' && *p <= '9') ser = ser * 10 + (u64)(*p++ - '0');
        while (*p == ' ') p++;
        double ts = 0;
        { int neg = 0; if (*p == '-') { neg = 1; p++; }
          while (*p >= '0' && *p <= '9') ts = ts * 10 + (double)(*p++ - '0');
          if (*p == '.') { p++; double f = 0.1; while (*p >= '0' && *p <= '9') { ts += (double)(*p++ - '0') * f; f *= 0.1; } }
          if (neg) ts = -ts; }
        while (*p && *p != '\n') p++;
        if (*p == '\n') p++;
        if (!any || !wid || used_wid(wid) || tried_wid(wid)) continue;
        // only objects this very rendezvous discovered (the census is exact because the WM is
        // parked in here; an entry from an earlier census may already be dead)
        if (ts + 0.05 < t0) continue;
        if (t - ts > 1.5) continue;
        if (!is_wid(wid)) { mark_tried(wid); G.n_rej++; continue; }
        u32 cg = 0;
        if (G.use_desc) {
            if (ndesc >= 8) break;              // bound the work done inside the WM
            ndesc++;
            const char *d = wid_desc(wid);
            if (!d) { mark_tried(wid); G.n_desc_bad++; continue; }
            int k = 0; while (d[k] && k < 63) { dbuf[k] = d[k]; k++; } dbuf[k] = 0;
            cg = cgid_from_desc(dbuf);
            if (sys_desc(dbuf)) { mark_tried(wid); G.n_desc_bad++; continue; }
            if (!cg || !pd_has(cg)) {
                mark_tried(wid); G.n_desc_bad++;
                logf("DESC-MISS ", dbuf, (i64)cg);
                continue;
            }
            G.n_desc_ok++;
            logf("DESC ", dbuf, (i64)cg);
            if (G.dump_model && OKA(G.dbg_x20)) {
                for (int i = 0; i < 64; i++) io_mw[i] = rd64(G.dbg_x20 + 8 * i);
                io_mw_n++;
                u64 mv[8]; int mn = 0;
                model_scan(mv, 8, &mn);
                logf("MODEL n=", 0, (i64)mn);
                for (int i = 0; i < mn; i++) {
                    const char *md = wid_desc(mv[i]);
                    if (md) logf("MW-DESC ", md, (i64)in_wids(mv[i]));
                    else logf("MW-DESC <none>", 0, (i64)in_wids(mv[i]));
                }
            }
            // More than one WindowID can claim a CGWindowID the observer just saw appear (a
            // launch allocates a 0x0 helper window a few ms before the real one).  The newborn
            // is the *last* of them to appear, and a titled window beats a title-less helper;
            // that is a strict ordering, not a guess between equals.
            int tlen = 0;
            { const char *q = dbuf;
              while (*q) {
                  if (q[0] == ')' && q[1] == ':') {
                      q += 2; while (*q == ' ') q++;
                      while (*q) { tlen++; q++; }
                      break;
                  }
                  q++;
              } }
            double ts_pd = pd_ts(cg);
            double score = ts_pd + (tlen > 0 ? 0.0005 : 0.0);
            if (score > best_score) { best_score = score; pick = wid; pick_ser = ser; pick_cg = cg; }
        } else {
            // no description: WindowIDs are allocated in creation order, so the newest serial is
            // the window that just appeared.  Anything already in a stage set is not a newborn.
            if (rg_member(wid)) { mark_tried(wid); continue; }
            if (!pick || ser > pick_ser) { pick = wid; pick_ser = ser; pick_cg = 0; }
        }
    }
    if (pick) {
        G.last_ser = pick_ser;
        G.n_desc_try++;
        *out_cg = pick_cg;
        logf("PICK ", 0, (i64)pick_cg);
        return pick;
    }
    G.n_miss++;
    return 0;
}

// ---------------------------------------------------------------- driver site
static u64 drv_body(u64 x0, u64 x20, u64 ret) {
    G.n_drv++;
    G.dbg_x20 = x20;
    if (G.verbose) {
        // 1 = birth site, 2 = second birth site, 3 = driver entry (any caller)
        i64 site = (ret == SL.driver + 0x5940) ? 1 : ((ret == SL.driver - 0xA7C4) ? 2 : 3);
        i64 cnt = (OKA(x0) ? (i64)rd32(x0 + 0x10) : -1);
        logf("CALL site=", 0, site);
        logf("     cnt=", 0, cnt);
    }
    G.n_birth_call++;
    if (OKA(x20) && !G.self) {
        G.self = x20;
        char b[24]; int k = 0;
        b[k++] = '0'; b[k++] = 'x';
        char t[20]; int m = 0; u64 v = x20;
        if (!v) t[m++] = '0';
        while (v) { t[m++] = "0123456789abcdef"[v & 15]; v >>= 4; }
        while (m) b[k++] = t[--m];
        b[k++] = '\n';
        for (int i = 0; i < k && i < 63; i++) io_self[i] = b[i];
        io_self_len = (u32)k;
        io_magic = 0x77334D4F4E4559UL;
    }
    read_cfg();
    hb_write();
    if (x0 && OKA(x0) && rd32(x0 + 0x10) == 0) G.n_birth_empty++;

    // ---- one control request (move), read from the page
    if (G.rq_seen != io_rq_gen) {
        char *rq = snap(B_rq, io_rq, io_rq_len, sizeof(B_rq));
        if (!io_rq_len || rq[0] != '{') {
            G.rq_seen = io_rq_gen;
        } else {
            char op[16];
            if (!(jstr(rq, "op", op, sizeof(op)) && memcmp(op, "move", 4) == 0)) {
                G.rq_seen = io_rq_gen;
                out_res("{\"ok\":false,\"err\":\"op\"}");
                out_state("done");
            } else if (!G.move_pending && OKA(x0) && rd32(x0 + 0x10) == 0) {
                // consumed only here: a request that arrives on a call with a non-empty op
                // array is retried on the next call instead of being dropped (round 30 fix)
                G.rq_seen = io_rq_gen;
                long cg = 0;
                jint(rq, "cgid", &cg);
                u64 wid = 0;
                long wl = 0;
                if (jint(rq, "wid", &wl) && wl) wid = (u64)wl;
                if (!wid) wid = resolve_cgid((u32)cg);
                if (!wid || !is_wid(wid)) {
                    G.n_miss++;
                    out_res("{\"ok\":false,\"op\":\"move\",\"err\":\"nowid\"}");
                    out_state("done");
                } else {
                    u64 a = build_array(x0, wid);
                    if (a) {
                        G.mw0 = G.mw1 = 0;
                        char mode[16], w0[24], w1[24];
                        if (!jstr(rq, "mode", mode, sizeof(mode))) mode[0] = 0;
                        if (!(mode[0] == 'n' && mode[1] == 'a') &&
                            jstr(rq, "w0", w0, sizeof(w0)) && jstr(rq, "w1", w1, sizeof(w1))) {
                            u64 v2 = 0;
                            for (int i = 0; w0[i]; i++) { char c = w0[i]; int d = -1;
                                if (c >= '0' && c <= '9') d = c - '0';
                                else if (c >= 'a' && c <= 'f') d = c - 'a' + 10;
                                if (d < 0) break; v2 = (v2 << 4) | (u64)d; }
                            G.mw0 = v2; v2 = 0;
                            for (int i = 0; w1[i]; i++) { char c = w1[i]; int d = -1;
                                if (c >= '0' && c <= '9') d = c - '0';
                                else if (c >= 'a' && c <= 'f') d = c - 'a' + 10;
                                if (d < 0) break; v2 = (v2 << 4) | (u64)d; }
                            G.mw1 = v2;
                        }
                        G.move_pending = 1;
                        G.msubj = wid;
                        out_state("running");
                        logf("MOVE INJECT wid=", 0, wid);
                        return a;
                    }
                }
            }
        }
    }

    // ---- feature 1: a birth with an empty op array
    if (!G.births) return x0;
    if (!OKA(x0)) return x0;
    if (rd32(x0 + 0x10) != 0) return x0;
    // one injection per birth event: this site is entered ~24 times for one birth, and the
    // op-array is empty on several of those calls, so without this a single birth would inject
    // several different windows (measured: 4 injections for one birth before the gate)
    if (now() - G.t_last_inject < 1.0 && G.t_last_inject > 0) return x0;
    u32 cg = 0;
    u64 wid = identify(&cg);
    if (!wid) return x0;
    if (cg && done_cgid(cg)) return x0;   // this CGWindowID was already placed once
    G.last_inject_cgid = cg;
    if (G.probe) {
        // identify only: record that the WM's own description and the user-side window list
        // agree, then leave the WM's array untouched (zero risk, and it is the identity proof)
        mark_wid(wid);
        G.t_last_inject = now();
        out_res2("{\"ok\":true,\"op\":\"probe\",\"wid\":", wid, "}");
        return x0;
    }
    u64 a = build_array(x0, wid);
    if (!a) return x0;
    if (cg) mark_cgid(cg);
    mark_wid(wid);
    G.last_inject_wid = wid;
    {
        u32 i = io_inj_n++ & 7;
        io_inj_wid[i] = wid;
        io_inj_cg[i] = G.last_inject_cgid;
    }
    G.n_inject++;
    G.t_last_inject = now();
    logf("INJECT wid=", 0, wid);
    out_res2("{\"ok\":true,\"op\":\"inject\",\"wid\":", wid, "}");
    return a;
}

u64 p_drv(u64 x0, u64 x20, u64 ret) {
    if (__atomic_exchange_n(&G.busy, 1, __ATOMIC_ACQUIRE)) return x0;
    u64 r = drv_body(x0, x20, ret);
    __atomic_store_n(&G.busy, 0, __ATOMIC_RELEASE);
    return r;
}

// ---------------------------------------------------------------- compute site
u64 p_build_array(u64 src, u64 wid) { return build_array(src, wid); }

void p_compute(u64 x20) {
    G.n_cmp++;
    if (!G.move_pending) return;
    if (G.mw0 && OKA(x20)) {
        wr64(x20 + 0x10, G.mw0);
        wr64(x20 + 0x18, G.mw1);
        wr64(x20 + 0x40, G.mw0);
        wr64(x20 + 0x48, G.mw1);
        logf("MOVE PATCH model+10/+40 wid=", 0, G.msubj);
        out_res("{\"ok\":true,\"op\":\"move\",\"patch\":\"done\"}");
    } else {
        out_res("{\"ok\":true,\"op\":\"move\",\"patch\":\"none\"}");
    }
    out_state("done");
    G.move_pending = 0;
}

// ---------------------------------------------------------------- strip keeper
static void mat_scale(const double *m, double s, double qx, double qy, double *o) {
    double se = 1.0 / s;
    double dx = (1.0 - se) * qx, dy = (1.0 - se) * qy;
    for (int i = 0; i < 4; i++) o[i] = se * m[i];
    for (int i = 0; i < 4; i++) o[4 + i] = se * m[4 + i];
    for (int i = 0; i < 4; i++) o[8 + i] = m[8 + i];
    for (int i = 0; i < 4; i++) o[12 + i] = dx * m[i] + dy * m[4 + i] + m[12 + i];
}
static int is_identity(const double *m) {
    static const double id[16] = {1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1};
    for (int i = 0; i < 16; i++) if (!feq(m[i], id[i])) return 0;
    return 1;
}

static void apply_all(void) {
    if (!SL.txn_create || !SL.txn_commit || !SL.txn_set3d || !SL.cgid_main) return;
    if (!G.st_ok || !G.n_rail) return;      // never act on a partial or stale document
    double mm[MAXP][16];
    u32 ids[MAXP];
    int n = 0;
    double s = G.dilate ? G.s : 1.0;
    for (int i = 0; i < G.n_rail && n < MAXP; i++) {
        struct pose *p = pose_get(G.rail_ids[i], 0);
        if (!p || !p->used) continue;
        // A pose can exist before it has a base -- a written window whose write was not a legal
        // resting candidate.  Replaying `p->base` for one of those hands the WM the zero matrix,
        // which is not a no-op: it is a degenerate transform, and it is how apply_all used to be
        // able to hurt WindowManager.  Scaling needs the resting base; a level-only apply can use
        // the replay transform, which every drawn tile has.
        int scaled = !feq(s, 1.0);
        if (scaled ? !p->hasbase : !(p->hasbase || p->hasrp)) continue;
        double base[16];
        memcpy(base, (scaled || p->hasbase) ? p->base : p->rp, 128);
        if (scaled) mat_scale(base, s, G.qx, G.qy, mm[n]);
        else memcpy(mm[n], base, 128);
        ids[n++] = G.rail_ids[i];
    }
    if (!n) return;
    u64 cid = ((u64(*)(void))SL.cgid_main)();
    u64 txn = ((u64(*)(u64))SL.txn_create)(cid);
    if (!txn) return;
    for (int i = 0; i < n; i++) {
        ((int(*)(u64, u32, const double *))SL.txn_set3d)(txn, ids[i], mm[i]);
        struct pose *p = pose_get(ids[i], 1);
        if (p) { memcpy(p->mine, mm[i], 128); p->hasmine = 1; }
    }
    int lvl = (G.force || G.level_manual == 3) ? 3 : 0;
    if (G.levels && SL.txn_level)
        for (int i = 0; i < n; i++) {
            ((int(*)(u64, u32, int))SL.txn_level)(txn, ids[i], lvl);
            struct pose *p = pose_get(ids[i], 1);
            if (p) { p->lvl = (u8)lvl; p->haslvl = 1; }
        }
    ((int(*)(u64, int))SL.txn_commit)(txn, 1);
    G.n_apply++;
    logf("APPLYCFG n=", 0, n);
}

// ---- round 33: the teach gate ---------------------------------------------------------------
// The WM hides the strip with the *same* write as the visible pose plus an extra rotation about
// the strip pivot and the gutter translation: round 20 measured the difference as exactly
// 286.92 x row 0, i.e. a ~287 px leftward shift.  A write that sits more than 80 px to the left of
// the taught base is therefore the hidden pose, whatever else has changed -- a hover lift, a
// settle, or the last frame of the reveal animation is not.
static int is_retract(const double *m, const u8 *b) {
    double o[16];
    memcpy(o, b, 128);
    return (m[12] - o[12]) < -80.0;
}

// The retract walk itself is stopped by `out` above (min rail x and front_x, both read from the
// document), not by a threshold on a single write: the retract arrives as a run of small leftward
// steps, each below the 80 px signature, and any absolute-x test on the write is wrong because the
// pose translation is not in screen coordinates (round 34 measured a gate built on m[12] >= 0
// refuse *every* write: learn +0 over two full sweeps).

// ---- a resting base is a pose the WM stops writing -------------------------------------------
// Measured on this build: one hover animates a tile through hundreds of distinct scale values in
// ~0.5 s, the resting pose is written once, and the next write for that window comes ~0.3 s later
// or never (idle produces no writes at all).  So "is this write the rest pose" is answered by
// time, not by a value.  Record every legal write as a candidate and promote it only when the
// window has been written nothing else for QUIET.  A lift cannot pass that test -- it is followed
// by the settle writes when the pointer leaves -- and neither can a mid-animation frame.
//
// The round-34 rule this replaces ("keep the smallest pose") never gated at all: `p->base` is a
// u8[128], so `p->base[0]` is ONE BYTE of the base's first double, an integer no scale can be
// smaller than.  It kept the last write of a sweep -- a hover lift -- which is where 1.58 came
// from.  Cast to double before comparing, always.
#define QUIET   0.22    // longer than the longest gap inside one animation (measured 0.13 s)
#define CAND_TTL 3.00   // longer than one sweep's period (2 passes over tiles, measured ~3 s)
static int strip_out_now(void) {
    return G.st_ok && G.strip_on && G.n_rail > 0 && G.rail_x >= 0.0
           && G.has_frontx && G.front_x > 60.0;
}
// Promote one settled candidate.  The document is re-read HERE, not at write time: a retract that
// started after the write has closed the strip by now (25 ms ticks), so the candidate the keeper
// stopped hearing about is only trusted while the strip is still drawn.
static void promote_one(struct pose *p, double t, int out) {
    p->cand_ok = 0;
    if (!out) return;                       // candidates are recorded only at scale 1.0, strip out
    if (p->hasbase && memcmp(p->base, p->cand, 128) == 0) return;
    // A base is the LARGEST m0 a tile shows.  m0 is natural divided by drawn, so a hover lift --
    // the tile drawn ~6% larger -- is the *smaller* value, and the resting pose is the largest.
    // Quiet promotion alone cannot tell them apart: a pointer that comes to rest on a tile lifts
    // it and the WM then stops writing, which is exactly the shape of a settle (measured: 1.883 at
    // rest, 1.775 lifted).  Without this test that lift becomes the base and `resize 1.5` renders
    // `1.5 x 1.06` -- round 34 by another route.  Cast to double: `p->base` is a u8[128], and
    // `p->base[0]` is one byte of the double, which is how round 34 shipped a 5% error.
    if (p->hasbase && ((const double *)p->cand)[0] < ((const double *)p->base)[0] - 1e-9) return;
    memcpy(p->base, p->cand, 128);
    p->hasbase = 1;
    p->t_base = t;
    G.n_learn++;
}
// Called (a) before this window's next write -- a write that arrives QUIET after a candidate is
// the proof that the candidate was the end of its animation -- and (b) at a cfg generation change,
// which is where the base is actually consumed.  Idle produces no writes at all, so (b) is what
// settles the last tile of a sweep.
static void promote_one_rp(struct pose *p, double t, int out) {
    p->rpcand_ok = 0;
    if (!out) return;                       // never take the hidden pose, whatever it looked like
    if (p->t_rpcand < G.t_out_since) return; // written before the strip came out: not this drawing
    if (p->hasrp && memcmp(p->rp, p->rpcand, 128) == 0) return;
    memcpy(p->rp, p->rpcand, 128);
    p->hasrp = 1;
    G.n_rp++;
}

static void promote_bases(void) {
    double t = now();
    int out = strip_out_now();
    for (int i = 0; i < MAXP; i++) {
        struct pose *p = &G.pose[i];
        if (!p->used) continue;
        if (p->cand_ok) {
            if (t - p->t_cand > CAND_TTL) p->cand_ok = 0;
            else if (t - p->t_cand >= QUIET) promote_one(p, t, out);
        }
        if (p->rpcand_ok) {
            if (t - p->t_rpcand > CAND_TTL) p->rpcand_ok = 0;
            else if (t - p->t_rpcand >= QUIET) promote_one_rp(p, t, out);
        }
    }
}

// No leaked level: once the phase is over (or the window is no longer a strip member) every window
// this keeper raised goes back to 0 -- even one that left `strip_ids` meanwhile, which would
// otherwise never see another write it is a member of (round 32 measured Orca and r20win stuck at
// layer 3, and a stage window at layer 3 hides the front from the phase observer, which then stops
// reporting `flush` at all: one leak kills the next trial).
static void level_sweep(u64 txn) {
    if (!G.levels || !SL.txn_level) return;
    for (int i = 0; i < MAXP; i++) {
        struct pose *q = &G.pose[i];
        if (!q->used || !q->haslvl || q->lvl != 3) continue;
        if (G.level_manual == 3 && in_ids(q->wid, G.strip_ids, G.n_strip)) continue;
        ((int(*)(u64, u32, int))SL.txn_level)(txn, q->wid, 0);
        q->lvl = 0;
        G.n_level++;
    }
}

static void keeper_body(u64 txn, u32 wid, u64 matp) {
    read_cfg();
    read_state();
    if (now() - G.t_hb > 0.20) { G.t_hb = now(); hb_write(); }   // live gate values, ~5 Hz
    int fresh = G.st_ok;
    int force = G.force && G.replay && fresh;
    int strip = in_ids(wid, G.strip_ids, G.n_strip);
    int rail = in_ids(wid, G.rail_ids, G.n_rail);
    if (!force && fresh) level_sweep(txn);      // no-op while a flush is replaying
    if (!force && fresh) promote_bases();       // any write can settle another window's candidate
    if (!strip && !rail) return;
    double m[16];
    memcpy(m, (const void *)matp, 128);
    struct pose *p = pose_get(wid, 1);
    if (!p) return;
    double s = G.dilate ? G.s : 1.0;
    // "the strip is genuinely out": a fresh document, the strip is on, every window in the rail is
    // drawn on screen (min x >= 0) and the front window is not flush.  `front_x > 60` is the
    // round-20 gate and it is the one that actually fires first: the observer sees the flush
    // window at x = 0 within one 25 ms tick, whereas the rail array is only re-read with it.
    int out = fresh && G.strip_on && G.n_rail > 0 && G.rail_x >= 0.0
              && G.has_frontx && G.front_x > 60.0;
    int ours = p->hasmine && memcmp(m, p->mine, 128) == 0;

    // ---- the teach gate (D2) -------------------------------------------------------------------
    // The WM retracts the strip *before* the observer's `flush` flag can reach the payload, so the
    // first writes of a flush are the retract itself.  Learning is allowed only while the strip is
    // genuinely out (fresh document, strip_on, tiles drawn in the gutter with rect x >= 0), never
    // within a hold that starts when the strip leaves or when a write jumps the pose by more than
    // a tile's own jitter, and never from a write that is our own last write.
    int prev = G.was_out;
    if (!out) {
        G.hold_until = now() + 0.35;              // the retract writes are still arriving
    } else if (!prev) {
        G.hold_until = now() + 0.30;              // let the reveal animation settle
    }
    if (out && !prev) G.t_out_since = now();
    G.was_out = out;
    int retract = (p->hasbase && is_retract(m, p->base)) || (p->hasrp && is_retract(m, p->rp));
    if (retract && !force) G.hold_until = now() + 0.50;
    // A base describes the drawing that is on screen right now, so it is dropped when that
    // drawing goes away -- for strip members too.  That is what makes "keep the largest m0" safe:
    // a layout change (fewer tiles, a different stage, a different strip scale) arrives through a
    // hide, so the next teach pass starts from an empty base instead of being pinned to a pose
    // from a drawing that no longer exists.  The replay transform is what has to survive the
    // hide, and `rp` is a separate field precisely so this one does not have to.
    if (prev && !out && !force)
        for (int i = 0; i < MAXP; i++) {
            struct pose *q = &G.pose[i];
            if (!q->used) continue;
            q->hasbase = 0;
            if (in_ids(q->wid, G.strip_ids, G.n_strip)) continue;
            q->hasrp = 0;
            q->hasmine = 0;
            q->haslvl = 0;
        }

    // ---- the replay transform (issue #20) ------------------------------------------------------
    // Strip-on-top needs a pose that keeps the tile drawn, for every tile, immediately.  The
    // resting base cannot do that job: it is deliberately strict and a tile that has not been
    // taught yet has none, which is exactly why tightening the teach gate took on-top from 7/7 to
    // 3/7.  So the two uses have two fields.
    //
    // The rule, stated exactly as the code implements it -- there is no geometric test on the
    // write, and an earlier version of this comment claimed one that did not exist:
    //
    //   1. every write that arrives while the document says the strip is drawn and that is not our
    //      own becomes the *candidate* (`rpcand`);
    //   2. a candidate is promoted only after QUIET (0.22 s) with no newer write for that window,
    //      and only if the document still says the strip is drawn at promotion time;
    //   3. a candidate written before the strip last came out (`t_out_since`) is never promoted.
    //
    // The margins that make that safe against a retract, which is what it has to survive:
    //   * the longest gap *inside* one animation is 0.13 s (measured on this build), so a frame of
    //     an animation is always superseded before QUIET elapses;
    //   * the document is republished every ~25 ms (`r21obs`), and a retract is ~0.3 s of writes,
    //     so `out` goes false within a tick or two of the retract starting: the last retract frame
    //     would have to be followed by 0.22 s of silence *and* the document would have to still
    //     say "drawn", which is 25 ms of lag against 220 ms of quiet -- it cannot be both;
    //   * and if it somehow were, rule 3 rejects it: after the next reveal `t_out_since` is newer
    //     than that candidate.
    // This replaced a per-write refresh, which does follow the strip out: measured, six tiles
    // replayed at the retracted pose and never came back.
    //
    // `ours` stays part of THIS one: a replay transform only has to keep the tile drawn, so a
    // lift pose is acceptable, while our own scaled matrix (written during a resize) is not.
    if (!ours && !is_identity(m) && out) {
        memcpy(p->rpcand, m, 128);
        p->t_rpcand = now();
        p->rpcand_ok = 1;
    } else {
        p->rpcand_ok = 0;
    }

    // The resting base: the last write the WM made for this window and then stopped writing for
    // QUIET seconds.  Every gate above still decides *what may become a candidate* -- never a
    // retract pose, never a write while the scale is not 1.0, never our own write, never inside a
    // strip-transition hold -- and promotion happens in promote_bases(), where the document is
    // re-read.  Promotion, not capture, is what makes the base a settled pose rather than a frame.
    int hold_ok = now() >= G.hold_until;
    // `!ours` is deliberately NOT part of this: the pose that matters most is the one the WM writes
    // when it settles, and after a replay that pose is byte-identical to our own last write.  With
    // `!ours` in the gate, teaching the resting pose failed whenever on-top had run first (measured:
    // learn 0 across a full teach sweep, bases 0, resize a no-op).  Teaching our own 1.0 write is a
    // no-op by construction (promote_one returns when the candidate already is the base), and at
    // any other scale the `feq(s, 1.0)` term already excludes it.
    int legal = feq(s, 1.0) && !is_identity(m) && out && hold_ok && !retract;
    if (p->cand_ok && now() - p->t_cand >= QUIET && now() - p->t_cand <= CAND_TTL && G.teach)
        promote_one(p, now(), out);      // this write proves the candidate ended its burst
    if (!G.teach) {
        // the tool is sweeping or measuring: record nothing, and do not throw away a candidate it
        // taught earlier -- the scale change that follows promotes it.
    } else if (legal) {
        memcpy(p->cand, m, 128);
        p->t_cand = now();
        p->cand_ok = 1;
    } else {
        p->cand_ok = 0;                  // this write supersedes anything pending for this window
    }
    G.last_mx = m[12];
    if (force) {
        // Replay what was last drawn on screen, not what the tile rests at: under a flush the
        // strip is behind a window, the resting pose is not what was there, and a tile that has a
        // replay transform but no resting base still has to come back.  The base is the fallback
        // for a tile that has not been drawn since this payload was installed.
        const u8 *src = p->hasrp ? p->rp : (p->hasbase ? p->base : 0);
        if (strip && src && !ours) {
            G.dbg_rp0 = ((const double *)src)[0];
            G.dbg_rpx = ((const double *)src)[12];
            G.dbg_rpy = ((const double *)src)[13];
            G.dbg_b0 = p->hasbase ? ((const double *)p->base)[0] : 0.0;
            memcpy((void *)matp, src, 128);
            memcpy(p->mine, src, 128);
            p->hasmine = 1;
            G.n_replay++;
        }
    } else if (rail && p->hasbase && fresh) {
        if (feq(s, 1.0)) {
            if (ours && memcmp(m, p->base, 128) != 0) {
                memcpy((void *)matp, p->base, 128);
                memcpy(p->mine, p->base, 128);
                G.n_dil++;
            }
        } else if (G.dilate) {
            // always from the base, never gated on `ours` (round 34): a tile that already carries
            // our *1.0* matrix from the previous phase gets its own matrix written back by the WM,
            // `ours` is then true, and the old `!ours` gate skipped it -- so it kept the old scale
            // and the strip scaled 5 of 6 tiles.  Recomputing from the base is idempotent when the
            // write already carries the right matrix.
            double o[16];
            mat_scale((const double *)p->base, s, G.qx, G.qy, o);
            if (memcmp(m, o, 128) != 0) {
                memcpy((void *)matp, o, 128);
                memcpy(p->mine, o, 128);
                p->hasmine = 1;
                G.n_dil++;
            }
        }
    }
    // Raise only a window we can actually keep on screen.  Under a flush that means one we have a
    // pose for at all (`rp` before the install's first teach), because a window lifted over the
    // stage with nothing to replay is the "3 of 7 tiles" regression.  The user's explicit
    // `level 3` still raises the whole set.
    int want = (strip && ((force && (p->hasrp || p->hasbase))
                          || (G.level_manual == 3 && fresh))) ? 3 : 0;
    if (strip && G.levels && fresh && SL.txn_level && (!p->haslvl || p->lvl != want)) {
        ((int(*)(u64, u32, int))SL.txn_level)(txn, wid, want);
        p->lvl = (u8)want;
        p->haslvl = 1;
        G.n_level++;
    }
    if (G.gen != G.gen_applied) {
        G.gen_applied = G.gen;
        promote_bases();     // settle anything pending before a base is used to scale
        apply_all();
    }
}

void p_keeper(u64 txn, u32 wid, u64 matp) {
    G.n_keep++;
    if (!OKA(matp)) return;
    if (__atomic_exchange_n(&G.busy, 1, __ATOMIC_ACQUIRE)) return;
    keeper_body(txn, wid, matp);
    __atomic_store_n(&G.busy, 0, __ATOMIC_RELEASE);
}
