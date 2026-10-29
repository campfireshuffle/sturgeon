// wmhb.c — the far side of the in-memory control plane. Root, task_for_pid, no debugger.
//
// Every address this helper needs is handed to it on the command line, derived at install time
// from the binary's content (wmlocate) and from the build's object-layout profile (profile.json),
// and verified against the live process before use.  Nothing here is a compiled-in VA.
//
// The payload cannot read a file and cannot walk the WM's heap safely, so this helper does both
// out of process and publishes the results *into the payload's own rw page*:
//
//   io_ids  "<wid-hex> <serial> <epoch>"   WindowIDs seen for the first time in the last 20 s
//   io_pd   "<cgid> <owner>"...            what the user-side observer just saw appear
//   io_rg   "S <w0> <w1> <n> <wid> <ser>…" the stage-set registry
//
// and it answers the payload's census rendezvous (`io_rdv` -> `io_rdv_ack`). While the payload
// waits, WindowManager is stopped inside the driver call — the in-memory equivalent of the lldb
// mode's census inside a breakpoint callback, and the reason identification can happen at the
// birth call at all.
//
// usage: wmhb --map FILE --widmeta 0xN --widtable 0xN [--ivar-reg 0xN --ivar-comp 0xN]
//             [--interval 0.01] [--once]
//        wmhb --verify --widmeta 0xN --widtable 0xN [--ivar-reg ... --ivar-comp ...]
//             (validates the profile against the live process and exits)
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <stdint.h>
#include <time.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <libproc.h>

#define TEXT_VA    0x100000000ULL
static uint64_t g_widmeta;               /* WindowID class metadata (unslid file VA) */
static uint64_t g_widtable;              /* WindowIDTable class metadata */
static uint64_t g_ivar_reg;              /* ivar-offset globals (registry diagnostic only) */
static uint64_t g_ivar_comp;
static const char *g_map = "/tmp/wmship/map.txt";

static pid_t g_pid;
static task_t g_task;
static uint64_t g_slide;
static uint64_t g_body;                  /* payload body base */
static uint64_t g_io[64];                /* io field addresses */
enum { IO_CFG, IO_CFG_LEN, IO_CFG_GEN, IO_ST, IO_ST_LEN, IO_ST_GEN, IO_RQ, IO_RQ_LEN,
       IO_RQ_GEN, IO_IDS, IO_IDS_LEN, IO_IDS_GEN, IO_PD, IO_PD_LEN, IO_PD_GEN, IO_RG,
       IO_RG_LEN, IO_RG_GEN, IO_RDV, IO_RDV_ACK, IO_HB, IO_HB_LEN, IO_LOG, IO_LOG_W,
       IO_RES, IO_RES_LEN, IO_SS, IO_SS_LEN, IO_SELF, IO_SELF_LEN, IO_MAGIC,
       IO_WIDS, IO_WIDS_LEN, IO_WIDS_GEN, IO_WIDCG, IO_WIDCG_LEN, IO_WIDCG_GEN, IO_N };
static const char *g_ioname[IO_N] = {
    "cfg", "cfg_len", "cfg_gen", "st", "st_len", "st_gen", "rq", "rq_len", "rq_gen",
    "ids", "ids_len", "ids_gen", "pd", "pd_len", "pd_gen", "rg", "rg_len", "rg_gen",
    "rdv", "rdv_ack", "hb", "hb_len", "log", "log_w", "res", "res_len", "ss", "ss_len",
    "self", "self_len", "magic", "wids", "wids_len", "wids_gen",
    "widcg", "widcg_len", "widcg_gen" };

static double tt(void) {
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

static pid_t find_pid(void) {
    int n = proc_listpids(PROC_ALL_PIDS, 0, NULL, 0);
    if (n <= 0) return 0;
    pid_t *p = malloc(n);
    n = proc_listpids(PROC_ALL_PIDS, 0, p, n);
    pid_t found = 0;
    for (int i = 0; i < n / (int)sizeof(pid_t); i++) {
        char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
        if (proc_pidpath(p[i], path, sizeof(path)) <= 0) continue;
        if (strstr(path, "WindowManager.app/Contents/MacOS/WindowManager")) { found = p[i]; break; }
    }
    free(p);
    return found;
}

static uint64_t text_base(pid_t pid) {
    uint64_t a = 0, best = 0;
    struct proc_regionwithpathinfo rp;
    while (a < 0x00007fffffffffffULL) {
        if (proc_pidinfo(pid, PROC_PIDREGIONPATHINFO, a, &rp, sizeof(rp)) != sizeof(rp)) break;
        if (strstr(rp.prp_vip.vip_path, "WindowManager.app/Contents/MacOS/WindowManager")) {
            uint64_t b = rp.prp_prinfo.pri_address;
            if (!best || b < best) best = b;
        }
        uint64_t nx = rp.prp_prinfo.pri_address + rp.prp_prinfo.pri_size;
        if (nx <= a) break;
        a = nx;
    }
    return best;
}

static int attach(void) {
    g_pid = find_pid();
    if (!g_pid) return 0;
    g_task = MACH_PORT_NULL;
    if (task_for_pid(mach_task_self(), g_pid, &g_task) != KERN_SUCCESS) return 0;
    uint64_t tb = text_base(g_pid);
    g_slide = tb ? tb - TEXT_VA : 0;
    return g_slide != 0;
}

static void detach(void) {
    if (g_task) { mach_port_deallocate(mach_task_self(), g_task); g_task = MACH_PORT_NULL; }
}

static void *rd(uint64_t a, size_t n, size_t *got) {
    vm_offset_t d = 0;
    mach_msg_type_number_t sz = 0;
    if (mach_vm_read(g_task, a, n, &d, &sz) != KERN_SUCCESS) { if (got) *got = 0; return NULL; }
    void *p = malloc(sz);
    memcpy(p, (void *)d, sz);
    mach_vm_deallocate(mach_task_self(), d, sz);
    if (got) *got = sz;
    return p;
}
static uint64_t rq(uint64_t a) {
    size_t got = 0;
    uint64_t *p = rd(a, 8, &got);
    if (!p || got < 8) { free(p); return 0; }
    uint64_t v = *p;
    free(p);
    return v;
}
static uint32_t r32(uint64_t a) {
    size_t got = 0;
    uint32_t *p = rd(a, 4, &got);
    if (!p || got < 4) { free(p); return 0; }
    uint32_t v = *p;
    free(p);
    return v;
}
static int wr(uint64_t a, const void *b, size_t n) {
    return mach_vm_write(g_task, a, (vm_offset_t)b, (mach_msg_type_number_t)n) == KERN_SUCCESS;
}
static void w32(uint64_t a, uint32_t v) { wr(a, &v, 4); }

static int is_wid(uint64_t a) {
    if (a < 0x10000 || a > 0x900000000000ULL || (a & 7)) return 0;
    uint64_t isa = rq(a);
    return (isa & 0x7FFFFFFFFFFFULL) == ((g_widmeta + g_slide) & 0x7FFFFFFFFFFFULL);
}

// ---------------------------------------------------------------- census (rolling, 20 s)
#define MAXW 256
static struct { uint64_t a, ser; double t0; int fresh; } W[MAXW];
static int nW;
// Addresses this helper has ever censused.  Without this, an object that lives longer than the
// 20 s window is pruned and then re-added by the next census - and would look "new" to the
// payload, which is exactly the false identity that must not happen.
#define MAXEVER 8192
static struct { uint64_t a, ser; } EVER[MAXEVER];
static int nEver;
static int ever_seen(uint64_t a, uint64_t ser) {
    for (int i = 0; i < nEver; i++) if (EVER[i].a == a && EVER[i].ser == ser) return 1;
    return 0;
}
static void ever_add(uint64_t a, uint64_t ser) {
    if (nEver < MAXEVER) { EVER[nEver].a = a; EVER[nEver].ser = ser; nEver++; }
}

static int known(uint64_t a, uint64_t ser) {
    for (int i = 0; i < nW; i++) if (W[i].a == a && W[i].ser == ser) return 1;
    return 0;
}
static void prune(double t) {
    int j = 0;
    for (int i = 0; i < nW; i++) if (t - W[i].t0 < 20.0) W[j++] = W[i];
    nW = j;
}
static int add(uint64_t a, uint64_t ser, double t) {
    if (nW >= MAXW) { memmove(W, W + 1, sizeof(W[0]) * (MAXW - 1)); nW = MAXW - 1; }
    W[nW].a = a; W[nW].ser = ser; W[nW].t0 = t;
    W[nW].fresh = !ever_seen(a, ser);
    ever_add(a, ser);
    return nW++;
}

static int region(uint64_t a, uint64_t *addr, uint64_t *size, int *prot) {
    mach_vm_address_t at = a;
    mach_vm_size_t sz = 0;
    vm_region_basic_info_data_64_t info;
    mach_msg_type_number_t cnt = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t obj = MACH_PORT_NULL;
    if (mach_vm_region(g_task, &at, &sz, VM_REGION_BASIC_INFO_64,
                       (vm_region_info_t)&info, &cnt, &obj) != KERN_SUCCESS) return 0;
    *addr = at; *size = sz; *prot = info.protection;
    return 1;
}

static int census(double t) {
    uint64_t meta = g_widmeta + g_slide;
    uint32_t want = (uint32_t)(meta & 0xffffffff);
    int added = 0;
    for (uint64_t base = 0x7000000000ULL; base < 0x8000000000ULL; ) {
        uint64_t ra, rs; int prot;
        if (!region(base, &ra, &rs, &prot)) break;
        if (prot & VM_PROT_READ) {
            for (uint64_t off = 0; off < rs; off += 0x100000) {
                size_t sz = (size_t)(rs - off > 0x100000 ? 0x100000 : rs - off), got = 0;
                unsigned char *d = rd(ra + off, sz, &got);
                if (!d) continue;
                for (size_t i = 0; i + 8 <= got; i += 4) {
                    uint64_t a;
                    if (memcmp(d + i, &want, 4)) continue;
                    a = ra + off + i;
                    if (a % 8) continue;
                    uint64_t isa;
                    memcpy(&isa, d + i, 8);
                    if ((isa & 0x7FFFFFFFFFFFULL) != meta) continue;
                    uint64_t ser = rq(a + 0x10);
                    if (!ser || ser >= 0x100000) continue;
                    if (!known(a, ser)) { add(a, ser, t); added++; }
                }
                free(d);
            }
        }
        if (ra + rs <= base) break;
        base = ra + rs;
    }
    return added;
}

// Only candidates *just* discovered are published. A WindowID that has been alive for seconds
// may already be gone, and sending -description to a freed object took WindowManager down once
// during this round (EXC_ARM_PAC_FAIL inside objc_msgSend) — so the list is deliberately short
// and young.
#define IDS_FRESH 1.2
static int publish_ids(double t) {
    char b[3000];
    int p = 0;
    prune(t);
    // newest first: the payload stops at the first match, and the newborn is the newest
    for (int i = nW - 1; i >= 0 && p < 2800; i--) {
        if (!W[i].fresh || t - W[i].t0 > IDS_FRESH) continue;
        int n = snprintf(b + p, sizeof(b) - p, "%llx %llu %.3f\n",
                         (unsigned long long)W[i].a, (unsigned long long)W[i].ser, W[i].t0);
        if (n <= 0) break;
        p += n;
    }
    if (!p) return 0;
    wr(g_io[IO_IDS], b, (size_t)p);
    w32(g_io[IO_IDS_LEN], (uint32_t)p);
    w32(g_io[IO_IDS_GEN], r32(g_io[IO_IDS_GEN]) + 1);
    return 1;
}

// The set the payload matches against must be "CGWindowIDs that appeared in the last few
// seconds", not "every window on screen": a wrong match would substitute an unrelated window
// into a placement operation. `pending.txt` has no timestamps, but `obs.log` has one per NEW
// event, so the helper reads that and keeps only the last PD_WINDOW seconds.
#define PD_WINDOW 3.0
static const char *SYSOWN[] = {"Window Server", "WindowManager", "Dock", "Control Center",
    "ControlCenter", "CursorUIViewService", "AutoFill", "Open and Save Panel Service",
    "Notification Center", "Spotlight", "Siri", "SystemUIServer", "Universal Control",
    "TextInputMenuAgent", "loginwindow", "WeatherMenu", "SecurityAgent", "Window"};
static int sysowner(const char *o) {
    for (unsigned i = 0; i < sizeof(SYSOWN) / sizeof(SYSOWN[0]); i++) {
        const char *a = o, *b = SYSOWN[i];
        while (*a && *b && *a == *b) { a++; b++; }
        if (!*b) return 1;
    }
    return 0;
}
static int publish_pd_cut(double cutoff) {
    char b[1024];
    int p = 0, n = 0;
    double t = tt();
    FILE *f = fopen("/tmp/wm/obs.log", "r");
    if (f) {
        if (fseek(f, -8192, SEEK_END) != 0) fseek(f, 0, SEEK_SET);
        char line[512];
        while (fgets(line, sizeof(line), f)) {
            double ts;
            int cg = 0, pid = 0;
            char owner[64] = {0};
            if (sscanf(line, "%lf NEW wid=%d owner=%63s pid=%d", &ts, &cg, owner, &pid) != 4) continue;
            if (t - ts > PD_WINDOW || cg <= 0 || ts < cutoff) continue;
            if (pid <= 0 || sysowner(owner)) continue;
            // owner up to the first space, so "Open_and_Save" style names stay parseable
            for (char *q = owner; *q; q++) if (*q == ' ') *q = '_';
            if (p < (int)sizeof(b) - 80)
                p += snprintf(b + p, sizeof(b) - (size_t)p, "%d %.3f %d %s\n", cg, ts, pid, owner);
            n++;
        }
        fclose(f);
    }
    if (!p) return 0;
    wr(g_io[IO_PD], b, (size_t)p);
    w32(g_io[IO_PD_LEN], (uint32_t)p);
    w32(g_io[IO_PD_GEN], r32(g_io[IO_PD_GEN]) + 1);
    return n;
}
static int publish_pd(void) { return publish_pd_cut(0.0); }

// Every WindowID object the census has seen recently, as "addr serial" lines.  The payload uses
// this as a *safe* membership test: a word in the WM's model is only dereferenced if it appears
// here, and every address here was read successfully by this process first.
static int publish_wids(double t) {
    char b[8192];
    int p = 0;
    prune(t);
    for (int i = 0; i < nW && p < 8000; i++) {
        if (t - W[i].t0 > 20.0) continue;
        int n = snprintf(b + p, sizeof(b) - p, "%llx %llu\n",
                         (unsigned long long)W[i].a, (unsigned long long)W[i].ser);
        if (n <= 0) break;
        p += n;
    }
    wr(g_io[IO_WIDS], b, (size_t)p);
    w32(g_io[IO_WIDS_LEN], (uint32_t)p);
    w32(g_io[IO_WIDS_GEN], r32(g_io[IO_WIDS_GEN]) + 1);
    return p;
}

// ---------------------------------------------------------------- WindowIDTable map
//
// WindowManagerAgent.WindowIDTable is the WM's own table of windows:
//   class WindowIDTable { let _lock; var _serial: UInt64; var _map: [UInt32: External];
//                         let _externalRepresentations }
// `_map` is keyed by the WindowID's own `serial` and its value starts with
// { cgWindowID: UInt32, stageID: UInt32 } (measured: 0x28-byte values, keys and values as
// separate arrays whose pointers sit in the dictionary header at +0x30/+0x38).  That is the
// numeric WindowID -> CGWindowID association the payload needs, and it can be read here, out of
// process, where a bad read is a failed mach_vm_read instead of a WindowManager fault.
static uint64_t g_tab;

static int tab_ok(void) {
    if (!g_tab) return 0;
    uint64_t isa = rq(g_tab);
    if ((isa & 0x7FFFFFFFFFFFULL) != ((g_widtable + g_slide) & 0x7FFFFFFFFFFFULL)) return 0;
    uint64_t map = rq(g_tab + 0x20);
    if (!map) return 0;
    uint64_t cnt = rq(map + 0x10);
    return cnt <= 4096;
}
static int cand_ok(uint64_t a) {
    size_t got = 0;
    unsigned char *o = rd(a, 0x30, &got);
    if (!o || got < 0x30) { free(o); return 0; }
    uint64_t map = 0;
    memcpy(&map, o + 0x20, 8);
    free(o);
    if (!map) return 0;
    unsigned char *h = rd(map, 0x40, &got);
    if (!h || got < 0x40) { free(h); return 0; }
    uint64_t count = 0, keys = 0, vals = 0;
    int scale = h[0x20];
    memcpy(&count, h + 0x10, 8);
    memcpy(&keys, h + 0x30, 8);
    memcpy(&vals, h + 0x38, 8);
    free(h);
    if (!count || count > 4096 || scale < 3 || scale > 18 || !keys || !vals) return 0;
    size_t g2 = 0;
    unsigned char *K = rd(keys, 64, &g2);
    if (!K) return 0;
    free(K);
    unsigned char *V = rd(vals, 64, &g2);
    if (!V) return 0;
    free(V);
    return 1;
}
static int find_table(void) {
    uint64_t tmeta = (g_widtable + g_slide) & 0x7FFFFFFFFFFFULL;
    g_tab = 0;
    for (uint64_t base = 0x7000000000ULL; base < 0x8000000000ULL; ) {
        uint64_t ra, rs;
        int prot;
        if (!region(base, &ra, &rs, &prot)) break;
        if (prot & VM_PROT_READ) {
            for (uint64_t off = 0; off < rs; off += 0x100000) {
                size_t sz = (size_t)(rs - off > 0x100000 ? 0x100000 : rs - off), g2 = 0;
                unsigned char *d = rd(ra + off, sz, &g2);
                if (!d) continue;
                for (size_t i = 0; i + 0x30 <= g2; i += 8) {
                    uint64_t isa;
                    memcpy(&isa, d + i, 8);
                    if ((isa & 0x7FFFFFFFFFFFULL) != tmeta) continue;
                    uint64_t a = ra + off + i;
                    if (!cand_ok(a)) continue;
                    g_tab = a;
                    free(d);
                    return 1;
                }
                free(d);
            }
        }
        if (ra + rs <= base) break;
        base = ra + rs;
    }
    return 0;
}
static uint64_t tab_map(void) {
    if (!tab_ok() && !find_table()) return 0;
    return rq(g_tab + 0x20);
}
static int publish_widcg(void) {
    uint64_t map = tab_map();
    if (!map) return 0;
    size_t got = 0;
    unsigned char *h = rd(map, 0x40, &got);
    if (!h || got < 0x40) { free(h); return 0; }
    uint64_t count = 0, keys = 0, vals = 0;
    int scale = h[0x20];
    memcpy(&count, h + 0x10, 8);
    memcpy(&keys, h + 0x30, 8);
    memcpy(&vals, h + 0x38, 8);
    free(h);
    if (!count || count > 4096 || scale < 3 || scale > 18 || !keys || !vals) return 0;
    uint64_t nb = 1ULL << scale;
    size_t ksz = 0, vsz = 0;
    unsigned char *K = rd(keys, (size_t)(nb * 8), &ksz);
    if (!K || ksz < nb * 8) { free(K); return 0; }
    unsigned char *V = rd(vals, (size_t)(nb * 0x28), &vsz);
    if (!V || vsz < nb * 0x28) { free(K); free(V); return 0; }
    char b[8192];
    int p = 0, n = 0;
    for (uint64_t i = 0; i < nb && p < (int)sizeof(b) - 32; i++) {
        uint64_t key;
        memcpy(&key, K + 8 * i, 8);
        if (!key || key >= 0x100000) continue;
        uint32_t cg;
        memcpy(&cg, V + 0x28 * i, 4);
        if (!cg || cg >= 0x1000000) continue;
        p += snprintf(b + p, sizeof(b) - (size_t)p, "%u %llu\n", cg, (unsigned long long)key);
        n++;
    }
    free(K);
    free(V);
    if (!p) return 0;
    wr(g_io[IO_WIDCG], b, (size_t)p);
    w32(g_io[IO_WIDCG_LEN], (uint32_t)p);
    w32(g_io[IO_WIDCG_GEN], r32(g_io[IO_WIDCG_GEN]) + 1);
    return n;
}

// ---------------------------------------------------------------- registry
static void members(char *b, int *pp, size_t max, uint64_t sp) {
    if (!sp) return;
    uint64_t cnt = 0;
    size_t got = 0;
    unsigned char *h = rd(sp, 0x20, &got);
    if (h && got >= 0x20) memcpy(&cnt, h + 0x10, 8);
    free(h);
    if (!cnt || cnt > 64) return;
    uint64_t want = 0x20 + 0x20 * (cnt + 8);
    unsigned char *blob = rd(sp, want, &got);
    if (!blob) return;
    int printed = 0;
    for (size_t off = 0; off + 8 <= got && printed < 64 && (size_t)*pp < max - 48; off += 8) {
        uint64_t v;
        memcpy(&v, blob + off, 8);
        if (!is_wid(v)) continue;
        int dup = 0;
        for (size_t o2 = 0; o2 < off; o2 += 8) {
            uint64_t w2;
            memcpy(&w2, blob + o2, 8);
            if (w2 == v) { dup = 1; break; }
        }
        if (dup) continue;
        *pp += snprintf(b + *pp, max - (size_t)*pp, " %llx %llu",
                        (unsigned long long)v, (unsigned long long)rq(v + 0x10));
        printed++;
    }
    free(blob);
}

// The registry in this build is a Swift Dictionary *storage* directly at (component + ivar_reg):
// count at +0x10, scale at +0x20, key array at +0x30, value array at +0x38 (the same "large
// dictionary" shape as the WindowIDTable map).  Rather than model the value type, publish every
// WindowID reachable from the dictionary two pointers deep: that is exactly the set of windows
// that are members of *some* stage set, which is what the payload must exclude.
static void rg_scan(char *b, int *pp, size_t max, uint64_t a, size_t n, int depth) {
    if (a < 0x10000 || a > 0x900000000000ULL || !n || *pp >= (int)max - 32) return;
    size_t got = 0;
    unsigned char *d = rd(a, n, &got);
    if (!d) return;
    for (size_t i = 0; i + 8 <= got && *pp < (int)max - 32; i += 8) {
        uint64_t v;
        memcpy(&v, d + i, 8);
        if (v < 0x7000000000ULL || v >= 0x8000000000ULL) continue;
        if (is_wid(v)) {
            int dup = 0;
            for (int k = 0; k + 20 < *pp; k++) {
                /* cheap duplicate check: the text so far, exact hex token */
                char tok[24];
                int m = snprintf(tok, sizeof(tok), " %llx ", (unsigned long long)v);
                for (const char *q = b; q + m < b + *pp; q++)
                    if (!memcmp(q, tok, (size_t)m)) { dup = 1; break; }
                if (dup) break;
            }
            if (!dup)
                *pp += snprintf(b + *pp, max - (size_t)*pp, "%llx %llu ",
                                (unsigned long long)v, (unsigned long long)rq(v + 0x10));
        } else if (depth > 0) {
            rg_scan(b, pp, max, v, 0x200, depth - 1);
        }
    }
    free(d);
}
static int publish_rg(void) {
    size_t got = 0;
    unsigned char *sb = rd(g_io[IO_SELF], 40, &got);
    if (!sb || got < 3) { free(sb); return 0; }
    sb[got < 39 ? got : 39] = 0;
    uint64_t self = strtoull((char *)sb, NULL, 0);
    free(sb);
    if (!self) return 0;
    uint64_t offc = rq(g_ivar_comp + g_slide);
    if (!offc) return 0;
    uint64_t comp = rq(self + offc);
    if (!comp) return 0;
    uint64_t offr = rq(g_ivar_reg + g_slide);
    if (!offr) return 0;
    uint64_t h = rq(comp + offr);
    if (!h) return 0;
    uint64_t cnt = rq(h + 0x10);
    int scale = (int)rq(h + 0x20 + 0) & 0xff;
    (void)scale;
    if (!cnt || cnt > 4096) return 0;
    char b[3000];
    int p = 0;
    p += snprintf(b + p, sizeof(b) - (size_t)p, "R n=%llu ", (unsigned long long)cnt);
    rg_scan(b, &p, sizeof(b), h, 0x2000, 2);
    b[p++] = '\n';
    wr(g_io[IO_RG], b, (size_t)p);
    w32(g_io[IO_RG_LEN], (uint32_t)p);
    w32(g_io[IO_RG_GEN], r32(g_io[IO_RG_GEN]) + 1);
    return 1;
}

// The keeper half of the payload needs to know which CGWindowIDs are strip tiles and which are
// in the left rail right now.  r21obs publishes exactly that; copy it into the payload page.
//
// Round 32 measured the document at 1814 B with seven stages while the copy was capped at 1535 B,
// and JSONSerialization's key order is not stable, so every snapshot was a different *prefix*
// (`flush` xor `rail_now`, never both).  The copy is now 16 KB, and the write is a seqlock: the
// generation goes odd before the bytes and even after them, so the payload can tell a whole,
// stable document from a torn one and simply keep its last good document otherwise.
#define ST_MAX 16384
static int publish_st(void) {
    FILE *f = fopen("/tmp/wm/state.json", "r");
    if (!f) return 0;
    static char b[ST_MAX];
    size_t n = fread(b, 1, sizeof(b) - 1, f);
    fclose(f);
    if (!n) return 0;
    if (n == sizeof(b) - 1) {
        // larger than we can carry: publish it anyway (the payload rejects an incomplete
        // document), but say so once in the helper log so the operator sees the bound.
        static int warned;
        if (!warned) { warned = 1; fprintf(stderr, "state.json >= %zu B: truncated\n", n); }
    }
    uint32_t g = r32(g_io[IO_ST_GEN]);
    w32(g_io[IO_ST_GEN], g + 1);              // odd: writing
    wr(g_io[IO_ST], b, n);
    w32(g_io[IO_ST_LEN], (uint32_t)n);
    w32(g_io[IO_ST_GEN], g + 2);              // even: stable
    return 1;
}

// ---------------------------------------------------------------- map file
static int load_map(void) {
    FILE *f = fopen(g_map, "r");
    if (!f) return 0;
    char line[256];
    uint64_t body = 0;
    uint64_t io[IO_N] = {0};
    while (fgets(line, sizeof(line), f)) {
        char k[64]; unsigned long long v;
        if (sscanf(line, "%63s %llx", k, &v) != 2) continue;
        if (!strcmp(k, "body")) body = v;
        for (int i = 0; i < IO_N; i++) {
            char want[64];
            snprintf(want, sizeof(want), "io_%s", g_ioname[i]);
            if (!strcmp(k, want)) io[i] = v;
        }
    }
    fclose(f);
    if (!body || !io[IO_RDV]) return 0;
    g_body = body;
    memcpy(g_io, io, sizeof(io));
    return 1;
}

// Count how many WindowID objects with the profile's isa exist, and how many of the WM's own
// table serials have such an object.  This is what makes the object-layout profile *verified*
// rather than trusted: a wrong metadata address agrees with nothing.
static int verify(uint64_t *nobj, uint64_t *nser, uint64_t *nmatch, uint64_t *nmap) {
    *nobj = *nser = *nmatch = *nmap = 0;
    if (!attach()) return 0;
    census(tt() - 100.0);
    *nobj = (uint64_t)nW;
    for (int i = 0; i < nW; i++) if (W[i].ser) (*nser)++;
    uint64_t map = tab_map();
    if (!map) return 0;
    size_t got = 0;
    unsigned char *h = rd(map, 0x40, &got);
    if (!h || got < 0x40) { free(h); return 0; }
    uint64_t count = 0, keys = 0;
    int scale = h[0x20];
    memcpy(&count, h + 0x10, 8);
    memcpy(&keys, h + 0x30, 8);
    free(h);
    if (!count || count > 4096 || scale < 3 || scale > 18 || !keys) return 0;
    uint64_t nb = 1ULL << scale;
    size_t ksz = 0;
    unsigned char *K = rd(keys, (size_t)(nb * 8), &ksz);
    if (!K || ksz < nb * 8) { free(K); return 0; }
    for (uint64_t i = 0; i < nb; i++) {
        uint64_t key;
        memcpy(&key, K + 8 * i, 8);
        if (!key || key >= 0x100000) continue;
        (*nmap)++;
        for (int j = 0; j < nW; j++)
            if (W[j].ser == key) { (*nmatch)++; break; }
    }
    free(K);
    return 1;
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);
    double interval = 0.01;
    int once = 0, do_verify = 0;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--once")) once = 1;
        else if (!strcmp(argv[i], "--verify")) do_verify = 1;
        else if (!strcmp(argv[i], "--interval") && i + 1 < argc) interval = atof(argv[++i]);
        else if (!strcmp(argv[i], "--map") && i + 1 < argc) g_map = argv[++i];
        else if (!strcmp(argv[i], "--widmeta") && i + 1 < argc) g_widmeta = strtoull(argv[++i], 0, 0);
        else if (!strcmp(argv[i], "--widtable") && i + 1 < argc) g_widtable = strtoull(argv[++i], 0, 0);
        else if (!strcmp(argv[i], "--ivar-reg") && i + 1 < argc) g_ivar_reg = strtoull(argv[++i], 0, 0);
        else if (!strcmp(argv[i], "--ivar-comp") && i + 1 < argc) g_ivar_comp = strtoull(argv[++i], 0, 0);
    }
    if (!g_widmeta || !g_widtable) {
        fprintf(stderr, "wmhb: --widmeta and --widtable are required (build profile)\n");
        return 2;
    }
    if (!strcmp(argv[1], "--pdtest")) {
        attach();
        FILE *f = fopen("/tmp/wm/obs.log", "r");
        int lines = 0, parsed = 0, fresh = 0;
        if (f) {
            if (fseek(f, -8192, SEEK_END) != 0) fseek(f, 0, SEEK_SET);
            char line[512];
            double t = tt();
            double first = 0, last = 0;
            while (fgets(line, sizeof(line), f)) {
                double ts; int cg = 0, pid = 0; char owner[64] = {0};
                lines++;
                if (sscanf(line, "%lf NEW wid=%d owner=%63s pid=%d", &ts, &cg, owner, &pid) != 4) continue;
                parsed++;
                if (!first) first = ts;
                last = ts;
                if (t - ts > PD_WINDOW) continue;
                fresh++;
            }
            fclose(f);
            printf("pdtest t=%.3f lines=%d parsed=%d fresh=%d first=%.3f last=%.3f direct=%d\n",
                   t, lines, parsed, fresh, first, last, publish_pd_cut(0.0));
        }
        detach();
        return 0;
    }
    if (do_verify) {
        uint64_t nobj = 0, nser = 0, nmatch = 0, nmap = 0;
        int ok = verify(&nobj, &nser, &nmatch, &nmap);
        uint64_t iv_r = rq(g_ivar_reg + g_slide);
        uint64_t iv_c = rq(g_ivar_comp + g_slide);
        printf("{\"profile_ok\":%s,\"pid\":%d,\"slide\":%llu,\"objects\":%llu,\"serials\":%llu,"
               "\"map_entries\":%llu,\"map_matched\":%llu,\"ivar_reg\":%llu,\"ivar_comp\":%llu}\n",
               ok && nobj && nmatch ? "true" : "false", (int)g_pid,
               (unsigned long long)g_slide, (unsigned long long)nobj,
               (unsigned long long)nser, (unsigned long long)nmap,
               (unsigned long long)nmatch, (unsigned long long)iv_r, (unsigned long long)iv_c);
        detach();
        return (ok && nobj && nmatch) ? 0 : 1;
    }
    if (!load_map()) { fprintf(stderr, "no map at %s — install first\n", g_map); return 1; }
    uint32_t ack = 0;
    double t_reg = 0, t_pd = 0, t_cen = 0;
    int served = 0;
    fprintf(stderr, "hb: body=%#llx ids=%#llx rdv=%#llx\n",
            (unsigned long long)g_body, (unsigned long long)g_io[IO_IDS],
            (unsigned long long)g_io[IO_RDV]);
    for (;;) {
        if (!g_task || g_pid != find_pid()) {
            detach();
            if (!attach()) { if (once) return 1; usleep(500000); continue; }
            census(tt() - 100.0);        // baseline: everything now is old, so nothing is offered
            ack = r32(g_io[IO_RDV_ACK]);
            fprintf(stderr, "hb: attached pid=%d slide=%#llx baseline=%d\n", g_pid,
                    (unsigned long long)g_slide, nW);
        }
        double t = tt();
        uint32_t rdv = r32(g_io[IO_RDV]);
        int did = 0;
        if (rdv != ack) {
            double t0 = tt();
            int n = census(t);
            publish_ids(t);
            publish_pd_cut(t0 - 0.10);
            // A birth creates a new WindowID *and* a new CGWindowID, but the user-side observer
            // sees the CGWindowID on its own 20 ms poll. When the census has just found a new
            // WindowID, give the observer that one poll before answering: that is what makes
            // "the window that just appeared" a tight set instead of "everything on screen".
            if (n > 0) {
                double deadline = tt() + 0.20;
                while (tt() < deadline) {
                    usleep(5000);
                    if (publish_pd_cut(t0 - 0.10)) break;
                }
            }
            // Round 37: the 0.10 s set above is only the *probe* that lets the observer publish a
            // window created just before this call; it must not be what the payload reads.  The
            // payload decides freshness itself (BIRTH_MAX_AGE, 2.5 s), so publish the same
            // PD_WINDOW set the periodic path publishes.  Two measured consequences of sending
            // the narrow set instead: a candidate the payload was still allowed to act on was
            // dropped, and when the probe found nothing the *previous*, older publication stayed
            // in the page -- a multi-document launch then injected a restored document while the
            // requested one (83 ms newer, already in obs.log) was invisible to the payload.
            publish_pd();
            publish_rg();
            publish_wids(t);
            publish_widcg();
            publish_st();
            ack = rdv;
            w32(g_io[IO_RDV_ACK], ack);
            double el = (tt() - t0) * 1000.0;
            served++;
            printf("rdv %u: census +%d (total %d) %.1f ms\n", rdv, n, nW, el);
            did = 1;
        }
        if (!did && t - t_pd > 0.02) { t_pd = t; publish_pd(); publish_st(); }
        if (!did && t - t_reg > 0.25) { t_reg = t; publish_rg(); }
        if (!did && t - t_cen > 2.0) { t_cen = t; census(t); publish_wids(t); publish_widcg(); }
        if (once) { printf("once: served=%d W=%d\n", served, nW); break; }
        usleep((useconds_t)(interval * 1e6));
    }
    detach();
    return 0;
}
