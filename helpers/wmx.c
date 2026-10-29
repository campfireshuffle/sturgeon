// wmx.c — the debugger-free memory lab for WindowManager.
//
//   wmx find                        pid + text base + slide + sprayed hole candidates
//   wmx rd <addr> <n>               hex dump
//   wmx q <addr> [count]            read qwords
//   wmx regions [lo] [hi]           mapped regions in a range
//   wmx holes [span]                free gaps near the binary (for a branch-reachable payload)
//   wmx allocnear <size> [span]     allocate RWX in a hole near the binary; prints the address
//   wmx alloc <size>                allocate RWX anywhere
//   wmx wf <addr> <file>            mach_vm_write from a file
//   wmx wr <addr> <hexbytes>        mach_vm_write hex
//   wmx prot <addr> <size> <r|rw|rx|rwx>
//   wmx dealloc <addr> <size>
//   wmx scan                        WindowID census over 0x70..0x80 TB (needs slide)
//   wmx obj <addr>                  describe a WindowID: isa check, serial, pointers
//   wmx findcgid <cgid>             find the WindowID whose reachable object carries <cgid>
//
// All operations need root (task_for_pid on a platform binary) and SIP off.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <stdint.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <libproc.h>
#include <sys/mman.h>

#define WIDMETA_VA 0x1005A3568ULL
#define TEXT_VA    0x100000000ULL

static pid_t find_pid(void) {
    int n = proc_listpids(PROC_ALL_PIDS, 0, NULL, 0);
    if (n <= 0) return 0;
    pid_t *pids = malloc(n);
    n = proc_listpids(PROC_ALL_PIDS, 0, pids, n);
    pid_t found = 0;
    for (int i = 0; i < n / (int)sizeof(pid_t); i++) {
        char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
        if (proc_pidpath(pids[i], path, sizeof(path)) <= 0) continue;
        if (strstr(path, "WindowManager.app/Contents/MacOS/WindowManager")) { found = pids[i]; break; }
    }
    free(pids);
    return found;
}

static uint64_t text_base(pid_t pid) {
    // the main binary's load base: its lowest region whose path is the binary, minus the file
    // offset of that region (the header page is often not reported with a path)
    uint64_t addr = 0, best = 0;
    struct proc_regionwithpathinfo rp;
    while (addr < 0x00007fffffffffffULL) {
        if (proc_pidinfo(pid, PROC_PIDREGIONPATHINFO, addr, &rp, sizeof(rp)) != sizeof(rp)) break;
        if (strstr(rp.prp_vip.vip_path, "WindowManager.app/Contents/MacOS/WindowManager")) {
            uint64_t base = rp.prp_prinfo.pri_address;
            if (!best || base < best) best = base;
        }
        uint64_t next = rp.prp_prinfo.pri_address + rp.prp_prinfo.pri_size;
        if (next <= addr) break;
        addr = next;
    }
    return best;
}

static task_t attach(void) {
    pid_t pid = find_pid();
    if (!pid) { fprintf(stderr, "WindowManager not running\n"); exit(2); }
    task_t t = MACH_PORT_NULL;
    kern_return_t kr = task_for_pid(mach_task_self(), pid, &t);
    if (kr != KERN_SUCCESS) { fprintf(stderr, "task_for_pid(%d): %s\n", pid, mach_error_string(kr)); exit(1); }
    return t;
}

static void *readmem(task_t t, uint64_t a, size_t n, size_t *got) {
    vm_offset_t data = 0;
    mach_msg_type_number_t sz = 0;
    kern_return_t kr = mach_vm_read(t, a, n, &data, &sz);
    if (kr != KERN_SUCCESS) { if (got) *got = 0; return NULL; }
    if (got) *got = sz;
    void *p = malloc(sz);
    memcpy(p, (void *)data, sz);
    mach_vm_deallocate(mach_task_self(), data, sz);
    return p;
}

static int protect(task_t t, uint64_t a, uint64_t n, int prot) {
    uint64_t page = a & ~0x3FFFULL;
    uint64_t end = (a + n + 0x3FFF) & ~0x3FFFULL;
    kern_return_t kr = mach_vm_protect(t, page, end - page, FALSE, prot);
    if (kr != KERN_SUCCESS) fprintf(stderr, "protect %#llx: %s\n", a, mach_error_string(kr));
    return kr == KERN_SUCCESS;
}

static int writemem(task_t t, uint64_t a, const void *buf, size_t n) {
    // 1) try a bare mach_vm_write (works on some r-x mappings)
    kern_return_t kr = mach_vm_write(t, a, (vm_offset_t)buf, (mach_msg_type_number_t)n);
    if (kr == KERN_SUCCESS) return 1;
    // 2) hardened processes refuse RWX in one step; RW then RX is allowed when max_prot is rwx
    if (!protect(t, a, n, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_EXECUTE) &&
        !protect(t, a, n, VM_PROT_READ | VM_PROT_WRITE)) {
        fprintf(stderr, "write %#llx: %s (and page not writable)\n", a, mach_error_string(kr));
        return 0;
    }
    kr = mach_vm_write(t, a, (vm_offset_t)buf, (mach_msg_type_number_t)n);
    if (kr != KERN_SUCCESS) fprintf(stderr, "write %#llx: %s\n", a, mach_error_string(kr));
    return kr == KERN_SUCCESS;
}

static int hexval(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

struct reg { uint64_t a, size; int prot; int maxprot; int shared; int reserved; };

static int region_at(task_t t, uint64_t a, struct reg *out) {
    mach_vm_address_t addr = a;
    mach_vm_size_t size = 0;
    vm_region_basic_info_data_64_t info;
    mach_msg_type_number_t cnt = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t obj = MACH_PORT_NULL;
    kern_return_t kr = mach_vm_region(t, &addr, &size, VM_REGION_BASIC_INFO_64,
                                      (vm_region_info_t)&info, &cnt, &obj);
    if (kr != KERN_SUCCESS) return 0;
    out->a = addr; out->size = size; out->prot = info.protection;
    out->maxprot = info.max_protection; out->shared = info.shared; out->reserved = info.reserved;
    return 1;
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);
    if (argc < 2) { fprintf(stderr, "usage: wmx <cmd> ...\n"); return 2; }
    const char *c = argv[1];
    task_t t = attach();
    pid_t pid = find_pid();
    uint64_t tb = text_base(pid);
    uint64_t slide = tb ? tb - TEXT_VA : 0;

    if (!strcmp(c, "find")) {
        printf("pid=%d text=%#llx slide=%#llx\n", pid, tb, slide);
        return 0;
    }
    if (!strcmp(c, "imgbase")) {
        /* the dyld shared cache is slid *per process*: the only way to reach a shared-cache
           symbol in WindowManager is to ask it for its own image list (TASK_DYLD_INFO) and add
           our own (symbol - image base) offset to that base. */
        const char *needle = argc > 2 ? argv[2] : "";
        struct task_dyld_info tdi;
        mach_msg_type_number_t cnt = TASK_DYLD_INFO_COUNT;
        kern_return_t kr = task_info(t, TASK_DYLD_INFO, (task_info_t)&tdi, &cnt);
        if (kr != KERN_SUCCESS) { fprintf(stderr, "task_info: %s\n", mach_error_string(kr)); return 1; }
        size_t got = 0;
        unsigned char *h = readmem(t, tdi.all_image_info_addr, 32, &got);
        if (!h || got < 16) { fprintf(stderr, "read all_image_info failed\n"); return 1; }
        uint32_t count = *(uint32_t *)(h + 4);
        uint64_t arr = *(uint64_t *)(h + 8);
        free(h);
        if (count > 8192) { fprintf(stderr, "bad image count %u\n", count); return 1; }
        size_t sz = 24 * (size_t)count;
        unsigned char *a = readmem(t, arr, sz, &got);
        if (!a || got < sz) { fprintf(stderr, "read image array failed\n"); return 1; }
        for (uint32_t i = 0; i < count; i++) {
            uint64_t base = *(uint64_t *)(a + 24 * i);
            uint64_t pathp = *(uint64_t *)(a + 24 * i + 8);
            size_t n = 0;
            char *p = readmem(t, pathp, 512, &n);
            if (!p) continue;
            p[n < 511 ? n : 511] = 0;
            if (!*needle || strstr(p, needle)) printf("%#llx %s\n", (unsigned long long)base, p);
            free(p);
        }
        free(a);
        return 0;
    }
    if (!strcmp(c, "rd")) {
        uint64_t a = strtoull(argv[2], 0, 0);
        size_t n = argc > 3 ? strtoull(argv[3], 0, 0) : 0x40;
        size_t got = 0;
        unsigned char *d = readmem(t, a, n, &got);
        if (!d) { fprintf(stderr, "read failed\n"); return 1; }
        for (size_t i = 0; i < got; i += 16) {
            printf("%#011llx  ", a + i);
            for (size_t j = 0; j < 16 && i + j < got; j++) printf("%02x ", d[i + j]);
            printf(" |");
            for (size_t j = 0; j < 16 && i + j < got; j++)
                printf("%c", d[i + j] >= 32 && d[i + j] < 127 ? d[i + j] : '.');
            printf("|\n");
        }
        return 0;
    }
    if (!strcmp(c, "q")) {
        uint64_t a = strtoull(argv[2], 0, 0);
        int n = argc > 3 ? atoi(argv[3]) : 8;
        size_t got = 0;
        uint64_t *d = readmem(t, a, n * 8, &got);
        if (!d) { fprintf(stderr, "read failed\n"); return 1; }
        for (int i = 0; i < n && (size_t)(i * 8 + 8) <= got; i++)
            printf("+%03x  %016llx\n", i * 8, d[i]);
        return 0;
    }
    if (!strcmp(c, "paths")) {
        const char *want = argc > 2 ? argv[2] : "WindowManager";
        uint64_t a = 0;
        while (a < 0x00007fffffffffffULL) {
            struct proc_regionwithpathinfo rp;
            if (proc_pidinfo(pid, PROC_PIDREGIONPATHINFO, a, &rp, sizeof(rp)) != sizeof(rp)) break;
            if (strstr(rp.prp_vip.vip_path, want))
                printf("%#011llx off=%#011llx size=%#llx prot=%d %s\n",
                       rp.prp_prinfo.pri_address, rp.prp_prinfo.pri_offset,
                       rp.prp_prinfo.pri_size, rp.prp_prinfo.pri_protection, rp.prp_vip.vip_path);
            uint64_t nx = rp.prp_prinfo.pri_address + rp.prp_prinfo.pri_size;
            if (nx <= a) break;
            a = nx;
        }
        return 0;
    }
    if (!strcmp(c, "base")) {
        // wmx base <substr> [fileoffset] — load base of the first image whose path contains substr
        const char *want = argv[2];
        uint64_t wantoff = argc > 3 ? strtoull(argv[3], 0, 0) : 0;
        uint64_t a = 0;
        while (a < 0x00007fffffffffffULL) {
            struct proc_regionwithpathinfo rp;
            if (proc_pidinfo(pid, PROC_PIDREGIONPATHINFO, a, &rp, sizeof(rp)) != sizeof(rp)) break;
            if (strstr(rp.prp_vip.vip_path, want) && rp.prp_prinfo.pri_offset == wantoff) {
                printf("%#llx\n", rp.prp_prinfo.pri_address);
                return 0;
            }
            uint64_t nx = rp.prp_prinfo.pri_address + rp.prp_prinfo.pri_size;
            if (nx <= a) break;
            a = nx;
        }
        fprintf(stderr, "not found: %s\n", want);
        return 1;
    }
    if (!strcmp(c, "regions")) {
        uint64_t a = argc > 2 ? strtoull(argv[2], 0, 0) : 0;
        uint64_t hi = argc > 3 ? strtoull(argv[3], 0, 0) : 0x00007fffffffffffULL;
        while (a < hi) {
            struct reg r;
            if (!region_at(t, a, &r)) break;
            printf("%#011llx-%#011llx %8llx prot=%s%s%s max=%s%s%s shared=%d res=%d\n",
                   r.a, r.a + r.size, r.size,
                   r.prot & VM_PROT_READ ? "r" : "-", r.prot & VM_PROT_WRITE ? "w" : "-",
                   r.prot & VM_PROT_EXECUTE ? "x" : "-",
                   r.maxprot & VM_PROT_READ ? "r" : "-", r.maxprot & VM_PROT_WRITE ? "w" : "-",
                   r.maxprot & VM_PROT_EXECUTE ? "x" : "-", r.shared, r.reserved);
            if (r.a + r.size <= a) break;
            a = r.a + r.size;
        }
        return 0;
    }
    if (!strcmp(c, "holes")) {
        uint64_t span = argc > 2 ? strtoull(argv[2], 0, 0) : 0x6000000ULL;
        uint64_t a = (tb > span ? tb - span : 0x100000000ULL), hi = tb + span;
        while (a < hi) {
            struct reg r;
            if (!region_at(t, a, &r)) break;
            if (r.a > a) {
                uint64_t gap = r.a - a;
                if (gap >= 0x4000) printf("hole %#011llx .. %#011llx  %llx\n", a, r.a, gap);
            }
            if (r.a + r.size <= a) break;
            a = r.a + r.size;
        }
        return 0;
    }
    if (!strcmp(c, "allocnear") || !strcmp(c, "alloc")) {
        uint64_t size = (strtoull(argv[2], 0, 0) + 0x3FFF) & ~0x3FFFULL;
        mach_vm_address_t addr = 0;
        kern_return_t kr;
        if (!strcmp(c, "allocnear")) {
            uint64_t span = argc > 3 ? strtoull(argv[3], 0, 0) : 0x6000000ULL;
            /* scan *above* the text only: the payload is reached by adrp (+-4 GB) and the holes
               below the binary are __PAGEZERO / reserved VA, which never allocate */
            uint64_t a = tb, hi = tb + span;
            int ok = 0;
            while (a < hi) {
                struct reg r;
                if (!region_at(t, a, &r)) break;
                if (r.a > a && r.a - a >= size) { addr = a; ok = 1; break; }
                if (r.a + r.size <= a) break;
                a = r.a + r.size;
            }
            if (!ok) { fprintf(stderr, "no hole\n"); return 1; }
            addr &= ~0x3FFFULL;
            kr = mach_vm_allocate(t, &addr, size, VM_FLAGS_FIXED);
        } else {
            kr = mach_vm_allocate(t, &addr, size, VM_FLAGS_ANYWHERE);
        }
        if (kr != KERN_SUCCESS) { fprintf(stderr, "allocate: %s\n", mach_error_string(kr)); return 1; }
        protect(t, addr, size, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_EXECUTE);
        printf("%#llx\n", (unsigned long long)addr);
        return 0;
    }
    if (!strcmp(c, "allocat")) {
        uint64_t a = strtoull(argv[2], 0, 0) & ~0x3FFFULL;
        uint64_t size = (strtoull(argv[3], 0, 0) + 0x3FFF) & ~0x3FFFULL;
        mach_vm_address_t addr = a;
        kern_return_t kr = mach_vm_allocate(t, &addr, size, VM_FLAGS_FIXED);
        if (kr != KERN_SUCCESS) { fprintf(stderr, "allocat %#llx: %s\n", a, mach_error_string(kr)); return 1; }
        protect(t, addr, size, VM_PROT_READ | VM_PROT_WRITE);
        printf("%#llx\n", (unsigned long long)addr);
        return 0;
    }
    if (!strcmp(c, "wf")) {
        uint64_t a = strtoull(argv[2], 0, 0);
        FILE *f = fopen(argv[3], "rb");
        if (!f) { perror("open"); return 1; }
        fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
        unsigned char *b = malloc(n);
        if (fread(b, 1, n, f) != (size_t)n) return 1;
        fclose(f);
        if (!writemem(t, a, b, n)) return 1;
        printf("wrote %ld bytes to %#llx\n", n, a);
        return 0;
    }
    if (!strcmp(c, "wr")) {
        uint64_t a = strtoull(argv[2], 0, 0);
        const char *h = argv[3];
        size_t n = strlen(h) / 2;
        unsigned char *b = malloc(n);
        for (size_t i = 0; i < n; i++) {
            int hi = hexval(h[2 * i]), lo = hexval(h[2 * i + 1]);
            if (hi < 0 || lo < 0) { fprintf(stderr, "bad hex\n"); return 1; }
            b[i] = (hi << 4) | lo;
        }
        if (!writemem(t, a, b, n)) return 1;
        return 0;
    }
    if (!strcmp(c, "wrx")) {
        // bare mach_vm_write only: does the kernel let us write this page as-is?
        uint64_t a = strtoull(argv[2], 0, 0);
        const char *h = argv[3];
        size_t n = strlen(h) / 2;
        unsigned char *b = malloc(n);
        for (size_t i = 0; i < n; i++) b[i] = (hexval(h[2*i]) << 4) | hexval(h[2*i+1]);
        kern_return_t kr = mach_vm_write(t, a, (vm_offset_t)b, (mach_msg_type_number_t)n);
        printf("bare write %#llx (%zu bytes): %s (%d)\n", a, n, mach_error_string(kr), kr);
        return kr == KERN_SUCCESS ? 0 : 1;
    }
    if (!strcmp(c, "prot")) {
        uint64_t a = strtoull(argv[2], 0, 0), n = strtoull(argv[3], 0, 0);
        const char *p = argv[4];
        int prot = 0;
        if (strchr(p, 'r')) prot |= VM_PROT_READ;
        if (strchr(p, 'w')) prot |= VM_PROT_WRITE;
        if (strchr(p, 'x')) prot |= VM_PROT_EXECUTE;
        return protect(t, a, n, prot) ? 0 : 1;
    }
    if (!strcmp(c, "allocmap")) {
        // wmx allocmap <nbytes> [src] — N pages of anonymous executable-capable memory in the
        // target, made by privately remapping a contiguous range of its own text
        uint64_t size = (strtoull(argv[2], 0, 0) + 0x3FFF) & ~0x3FFFULL;
        uint64_t src = argc > 3 ? (strtoull(argv[3], 0, 0) & ~0x3FFFULL) : (tb + 0x10000);
        mach_vm_address_t dst = 0;
        vm_prot_t prot = VM_PROT_READ | VM_PROT_WRITE;
        vm_prot_t maxp = VM_PROT_READ | VM_PROT_WRITE | VM_PROT_EXECUTE;
        kern_return_t kr = mach_vm_remap(t, &dst, size, 0, VM_FLAGS_ANYWHERE,
                                         t, src, TRUE, &prot, &maxp, VM_INHERIT_NONE);
        if (kr != KERN_SUCCESS) { fprintf(stderr, "allocmap: %s\n", mach_error_string(kr)); return 1; }
        protect(t, dst, size, VM_PROT_READ | VM_PROT_WRITE);
        printf("%#llx\n", (unsigned long long)dst);
        return 0;
    }
    if (!strcmp(c, "remap")) {
        // wmx remap <dst> <off> <hexbytes>   — replace the 16K page at <dst> in the target with a
        // private copy of itself carrying <hexbytes> at <off> (offset within the page).
        uint64_t dst = strtoull(argv[2], 0, 0) & ~0x3FFFULL;
        uint64_t off = strtoull(argv[3], 0, 0);
        unsigned char *pg = mmap(NULL, 0x4000, PROT_READ | PROT_WRITE,
                                 MAP_PRIVATE | MAP_ANON, -1, 0);
        if (pg == MAP_FAILED) { perror("mmap"); return 1; }
        size_t got = 0;
        unsigned char *cur = readmem(t, dst, 0x4000, &got);
        if (!cur || got != 0x4000) { fprintf(stderr, "read page failed\n"); return 1; }
        memcpy(pg, cur, 0x4000);
        if (argc > 4 && off < 0x4000) {
            const char *h = argv[4];
            for (size_t i = 0; i < strlen(h) / 2 && off + i < 0x4000; i++) {
                int hi = hexval(h[2 * i]), lo = hexval(h[2 * i + 1]);
                if (hi < 0 || lo < 0) { fprintf(stderr, "bad hex\n"); return 1; }
                pg[off + i] = (hi << 4) | lo;
            }
        }
        mach_vm_address_t target = dst;
        vm_prot_t prot = VM_PROT_READ | VM_PROT_EXECUTE;
        vm_prot_t maxp = VM_PROT_READ | VM_PROT_EXECUTE;
        kern_return_t kr = mach_vm_remap(t, &target, 0x4000, 0,
                                         VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE,
                                         mach_task_self(), (mach_vm_address_t)pg, TRUE,
                                         &prot, &maxp, VM_INHERIT_NONE);
        printf("remap %#llx -> %#llx: %s (target=%#llx)\n", dst, (uint64_t)pg,
               mach_error_string(kr), (uint64_t)target);
        return kr == KERN_SUCCESS ? 0 : 1;
    }
    if (!strcmp(c, "dealloc")) {
        uint64_t a = strtoull(argv[2], 0, 0), n = strtoull(argv[3], 0, 0);
        kern_return_t kr = mach_vm_deallocate(t, a, n);
        printf("%s\n", mach_error_string(kr));
        return kr == KERN_SUCCESS ? 0 : 1;
    }
    if (!strcmp(c, "findptr")) {
        // wmx findptr <value> [lo] [hi] — where does this 8-byte value occur? dump context
        uint64_t want = strtoull(argv[2], 0, 0);
        uint64_t lo = argc > 3 ? strtoull(argv[3], 0, 0) : 0x7000000000ULL;
        uint64_t hi = argc > 4 ? strtoull(argv[4], 0, 0) : 0x8000000000ULL;
        int n = 0;
        for (uint64_t base = lo; base < hi; ) {
            struct reg r;
            if (!region_at(t, base, &r)) break;
            if (r.prot & VM_PROT_READ) {
                for (uint64_t off = 0; off < r.size; off += 0x100000) {
                    size_t sz = (size_t)(r.size - off > 0x100000 ? 0x100000 : r.size - off), got = 0;
                    unsigned char *d = readmem(t, r.a + off, sz, &got);
                    if (!d) continue;
                    for (size_t i = 0; i + 8 <= got; i += 8) {
                        uint64_t v;
                        memcpy(&v, d + i, 8);
                        if (v != want) continue;
                        uint64_t a = r.a + off + i;
                        printf("HIT %#011llx\n", a);
                        if (n++ > 40) { free(d); return 0; }
                    }
                    free(d);
                }
            }
            if (r.a + r.size <= base) break;
            base = r.a + r.size;
        }
        fprintf(stderr, "hits=%d\n", n);
        return 0;
    }
    if (!strcmp(c, "ctx")) {
        // wmx ctx <addr> <n> — dump qwords around addr with pointer annotations
        uint64_t a = strtoull(argv[2], 0, 0);
        int n = argc > 3 ? atoi(argv[3]) : 16;
        uint64_t start = a - (uint64_t)(n / 2) * 8;
        size_t got = 0;
        uint64_t *d = readmem(t, start, n * 8, &got);
        if (!d) { fprintf(stderr, "read failed\n"); return 1; }
        uint64_t meta = WIDMETA_VA + slide;
        for (int i = 0; i * 8 + 8 <= (int)got; i++) {
            uint64_t v = d[i];
            const char *what = "";
            if (v && (v & 0x7FFFFFFFFFFFULL) == meta) what = "<WID>";
            else if (v > 0x7000000000ULL && v < 0x8000000000ULL) what = "<ptr>";
            else if (v > 0x100000000ULL && v < 0x110000000ULL) what = "<textptr>";
            printf("%#011llx %016llx %s\n", start + i * 8, v, what);
        }
        return 0;
    }
    if (!strcmp(c, "scan")) {
        uint64_t meta = WIDMETA_VA + slide;
        uint32_t want = (uint32_t)(meta & 0xffffffff);
        int total = 0;
        for (uint64_t base = 0x7000000000ULL; base < 0x8000000000ULL; ) {
            struct reg r;
            if (!region_at(t, base, &r)) break;
            if (!(r.prot & VM_PROT_READ)) { base = r.a + r.size; continue; }
            for (uint64_t off = 0; off < r.size; off += 0x100000) {
                size_t n = (size_t)(r.size - off > 0x100000 ? 0x100000 : r.size - off), got = 0;
                unsigned char *d = readmem(t, base + off, n, &got);
                if (!d) continue;
                for (size_t i = 0; i + 4 <= got; i += 4) {
                    if (memcmp(d + i, &want, 4)) continue;
                    uint64_t a = base + off + i;
                    if (a % 8) continue;
                    size_t g2 = 0;
                    uint64_t *h = readmem(t, a, 0x20, &g2);
                    if (!h || g2 < 0x20) continue;
                    if ((h[0] & 0x7FFFFFFFFFFFULL) != meta) continue;
                    if (!(h[2] > 0 && h[2] < 0x100000)) continue;
                    printf("%#011llx ser=%llu q2=%#llx q3=%#llx\n", a, h[2], h[2], h[3]);
                    total++;
                }
                free(d);
            }
            if (r.a + r.size <= base) break;
            base = r.a + r.size;
        }
        fprintf(stderr, "total=%d\n", total);
        return 0;
    }
    if (!strcmp(c, "obj")) {
        uint64_t a = strtoull(argv[2], 0, 0);
        uint64_t meta = WIDMETA_VA + slide;
        size_t got = 0;
        uint64_t *h = readmem(t, a, 0x80, &got);
        if (!h) { fprintf(stderr, "read failed\n"); return 1; }
        printf("isa=%#llx  meta=%#llx  match=%d  serial=%llu\n", h[0], meta,
               (h[0] & 0x7FFFFFFFFFFFULL) == meta, h[2]);
        for (int i = 0; i < 16; i++) printf("+%03x %016llx\n", i * 8, h[i]);
        return 0;
    }
    fprintf(stderr, "unknown cmd %s\n", c);
    return 2;
}
