/* birth_order.c — the birth identity's *ordering* decision, tested without root, without
 * WindowManager and without a debugger.
 *
 * The payload is a freestanding image, but `pd_newer` and `pick_widcg` are ordinary C over the
 * buffers the helper publishes, so they can be exercised on any arm64 host with the buffers
 * filled in by hand.  That is the only way to make the multi-document case deterministic: on the
 * machine it needs two windows to appear in the same 20 ms observer poll, which cannot be
 * reproduced on demand.
 *
 *   clang -O0 -arch arm64 -ffreestanding -fno-builtin -fno-stack-protector \
 *         -Wno-int-conversion -I.. tests/birth_order.c -o /tmp/birth_order && /tmp/birth_order
 *
 * Exit 0 = every case passed.
 */
#include <stdio.h>
#include "../payload.c"

static unsigned char objs[4][64] __attribute__((aligned(8)));

/* A WindowID object as `is_wid` and the census see it: isa = the profile's meta, the live-instance
 * marker at +8, the serial at +0x10. */
static u64 fake_wid(int i, u64 serial) {
    u64 a = (u64)objs[i];
    *(u64 *)a = SL.widmeta;
    *(u32 *)(a + 8) = 3;
    *(u64 *)(a + 0x10) = serial;
    return a;
}

static void put(char *dst, int cap, const char *s) {
    int i = 0;
    while (s[i] && i < cap - 1) { dst[i] = s[i]; i++; }
    dst[i] = 0;
}

static int fails;

static void check(const char *why, int want, int got) {
    printf("%s  %-64s want %d got %d\n", want == got ? "PASS" : "FAIL", why, want, got);
    if (want != got) fails++;
}

static const char *owner;

/* Fill the three published buffers the way the helper writes them, then return what the payload
 * would inject.  pd[] is "<cgid> <epoch>" (what identify parses), widcg[] "<cgid> <serial>",
 * wids[] "<addr-hex> <serial>". */
static u64 decide(const char *pd, const char *widcg, const char *wids, u32 *cg, int *need) {
    put(io_pd, sizeof(io_pd), pd);
    io_pd_len = (u32)slen(io_pd);
    put(io_widcg, sizeof(io_widcg), widcg);
    io_widcg_len = (u32)slen(io_widcg);
    put(io_wids, sizeof(io_wids), wids);
    io_wids_len = (u32)slen(io_wids);
    /* identify() copies the published buffers into its private snapshots before deciding; do the
     * same, so this test exercises the function exactly as the payload calls it. */
    snap(B_pd, io_pd, io_pd_len, sizeof(B_pd));
    snap(B_widcg, io_widcg, io_widcg_len, sizeof(B_widcg));
    snap(B_wids, io_wids, io_wids_len, sizeof(B_wids));
    u32 newest = 0;
    u64 w = pick_widcg(cg, &newest, need);
    (void)owner;
    return w;
}

static void reset(void) {
    memset(&G, 0, sizeof(G));
    SL.widmeta = 0x1005a3568UL;
    memset(io_pd, 0, sizeof(io_pd));
    memset(io_widcg, 0, sizeof(io_widcg));
    memset(io_wids, 0, sizeof(io_wids));
}

int main(void) {
    char pd[512], widcg[256], wids[256], line[128];
    double t0 = now();
    u32 cg = 0;
    int need = 0;
    u64 a, b, c, d;

    /* ---- pd_newer: which of two published windows is the newer one */
    check("same poll, larger cgid wins (the requested document)", 1, pd_newer(10.0, 9793, 10.0, 9792));
    check("same poll, smaller cgid loses", 0, pd_newer(10.0, 9792, 10.0, 9793));
    check("later poll wins even with a smaller cgid", 1, pd_newer(10.05, 100, 10.0, 999));
    check("earlier poll loses even with a larger cgid", 0, pd_newer(10.0, 999, 10.05, 100));
    check("identical entry is not newer than itself", 0, pd_newer(10.0, 9792, 10.0, 9792));

    /* ---- pick_widcg: a launch that restores three documents and then opens the requested one.
     * Restored 9790/9791/9792 at 7737.862 (serial 147/148/149), requested 9793 at 7737.945
     * (serial 150).  This is the measured shape from the round-37 multi-document trial. */
    reset();
    a = fake_wid(0, 147); b = fake_wid(1, 148); c = fake_wid(2, 149); d = fake_wid(3, 150);
    snprintf(pd, sizeof(pd), "9792 %.3f\n9791 %.3f\n9790 %.3f\n9793 %.3f\n",
             t0 - 0.15, t0 - 0.15, t0 - 0.15, t0 - 0.083);
    put(widcg, sizeof(widcg), "9792 149\n9791 148\n9790 147\n9793 150\n");
    snprintf(wids, sizeof(wids), "%llx 149\n%llx 148\n%llx 147\n%llx 150\n",
             (unsigned long long)c, (unsigned long long)b, (unsigned long long)a,
             (unsigned long long)d);
    {
        u64 w = decide(pd, widcg, wids, &cg, &need);
        check("multi-document launch picks the requested window (9793)", 9793, (int)cg);
        check("multi-document launch injects its object", 1, w == d);
    }

    /* ---- both in the same observer poll: identical timestamps, tie broken by cgid */
    reset();
    a = fake_wid(0, 148); b = fake_wid(1, 149);
    snprintf(pd, sizeof(pd), "9792 %.3f\n9793 %.3f\n", t0 - 0.10, t0 - 0.10);
    put(widcg, sizeof(widcg), "9792 148\n9793 149\n");
    snprintf(wids, sizeof(wids), "%llx 148\n%llx 149\n",
             (unsigned long long)a, (unsigned long long)b);
    {
        u64 w = decide(pd, widcg, wids, &cg, &need);
        check("same-poll tie picks the larger cgid (9793)", 9793, (int)cg);
        check("same-poll tie injects that object", 1, w == b);
    }

    /* ---- the buffer states that must NOT produce an injection */
    reset();
    a = fake_wid(0, 149);
    snprintf(pd, sizeof(pd), "9792 %.3f\n", t0 - 0.10);
    put(widcg, sizeof(widcg), "9791 148\n");        /* table does not have the candidate yet */
    snprintf(wids, sizeof(wids), "%llx 149\n", (unsigned long long)a);
    check("candidate with no serial in the table: no pick", 0, decide(pd, widcg, wids, &cg, &need) != 0);
    check("... and asks for a fresh helper pass (need 1)", 1, need);

    reset();
    a = fake_wid(0, 149);
    snprintf(pd, sizeof(pd), "9792 %.3f\n", t0 - 0.10);
    put(widcg, sizeof(widcg), "9792 149\n");
    put(wids, sizeof(wids), "");                    /* census has not seen the object yet */
    check("serial with no live object: no pick", 0, decide(pd, widcg, wids, &cg, &need) != 0);
    check("... and asks for a fresh helper pass (need 2)", 2, need);

    reset();
    a = fake_wid(0, 149);
    snprintf(pd, sizeof(pd), "9792 %.3f\n", t0 - 3.00);   /* older than BIRTH_MAX_AGE */
    put(widcg, sizeof(widcg), "9792 149\n");
    snprintf(wids, sizeof(wids), "%llx 149\n", (unsigned long long)a);
    check("candidate older than BIRTH_MAX_AGE is not used", 0,
          decide(pd, widcg, wids, &cg, &need) != 0);

    reset();
    a = fake_wid(0, 149);
    snprintf(pd, sizeof(pd), "9792 %.3f\n", t0 - 0.10);
    put(widcg, sizeof(widcg), "9792 149\n");
    snprintf(wids, sizeof(wids), "%llx 149\n", (unsigned long long)a);
    G.done_cgid[G.n_done++] = 9792;                 /* already placed once */
    check("an already-used CGWindowID is not placed again", 0,
          decide(pd, widcg, wids, &cg, &need) != 0);

    reset();
    snprintf(pd, sizeof(pd), "9792 %.3f\n", t0 - 0.10);
    put(widcg, sizeof(widcg), "");
    put(wids, sizeof(wids), "");
    check("no table at all: no pick", 0, decide(pd, widcg, wids, &cg, &need) != 0);
    check("... and need says the table is the missing leg", 1, need);

    (void)line;
    printf("%s: %d failure(s)\n", fails ? "FAILED" : "OK", fails);
    return fails != 0;
}
