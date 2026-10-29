// wmcls.c — resolve Objective-C / Swift class *metadata* addresses in the live WindowManager,
// by class name, with no debugger.
//
//   wmcls <classlist_addr> <size> <name> [<name> ...]
//
// `<classlist_addr>`/`<size>` are the file-VA range of the image's __objc_classlist section,
// read from the binary on disk by the caller (wmlocate) and slid to the live process... no: the
// address is the *live* address, the caller adds the slide.  Every pointer read here is already
// fixed up by dyld in the target, so nothing in this file decodes chained fixups; a pointer that
// does not land in a readable mapping simply fails a read and is skipped.
//
// Why this exists: the payload and the helper must recognise a live WindowID object by comparing
// its isa with the class metadata, and must find the WindowIDTable instance.  Those two
// addresses used to be constants compiled into every artefact, which is exactly what makes a
// patch silently wrong after an OS update.  They are build data, not behaviour: this tool derives
// them from the class *names* the runtime itself uses, and validates the class layout it finds
// (instance size) against the layout the payload relies on.
//
// Root + task_for_pid (platform binary), SIP off; no ptrace, no lldb, no code written.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <libproc.h>

#define NAME_MAXC 192

static pid_t find_pid(void) {
    int n = proc_listpids(PROC_ALL_PIDS, 0, NULL, 0);
    if (n <= 0) return 0;
    pid_t *pids = malloc((size_t)n);
    n = proc_listpids(PROC_ALL_PIDS, 0, pids, (uint32_t)n);
    pid_t found = 0;
    for (int i = 0; i < n / (int)sizeof(pid_t); i++) {
        char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
        if (proc_pidpath(pids[i], path, sizeof(path)) <= 0) continue;
        if (strstr(path, "WindowManager.app/Contents/MacOS/WindowManager")) {
            found = pids[i];
            break;
        }
    }
    free(pids);
    return found;
}

static void *readmem(task_t t, uint64_t a, size_t n, size_t *got) {
    vm_offset_t data = 0;
    mach_msg_type_number_t sz = 0;
    if (got) *got = 0;
    if (mach_vm_read(t, a, n, &data, &sz) != KERN_SUCCESS) return NULL;
    void *p = malloc(sz ? sz : 1);
    if (!p) return NULL;
    memcpy(p, (void *)data, sz);
    mach_vm_deallocate(mach_task_self(), data, sz);
    if (got) *got = sz;
    return p;
}

static uint64_t ptr(uint64_t v) { return v & 0x00007FFFFFFFFFFFULL; }

// The ObjC name of a class object: class->data (ro) -> name.
static int class_name(task_t t, uint64_t cls, char *out, size_t n, uint32_t *inst) {
    size_t got = 0;
    unsigned char *h = readmem(t, cls, 0x28, &got);
    if (!h || got < 0x28) { free(h); return 0; }
    uint64_t ro = ptr(*(uint64_t *)(h + 0x20));
    free(h);
    if (!ro) return 0;
    unsigned char *r = readmem(t, ro, 0x20, &got);
    if (!r || got < 0x20) { free(r); return 0; }
    uint64_t namep = ptr(*(uint64_t *)(r + 0x18));
    if (inst) *inst = *(uint32_t *)(r + 0x14);
    free(r);
    if (!namep) return 0;
    unsigned char *s = readmem(t, namep, NAME_MAXC, &got);
    if (!s || got < 2) { free(s); return 0; }
    ((char *)s)[got - 1 < NAME_MAXC - 1 ? got - 1 : NAME_MAXC - 1] = 0;
    size_t k = 0;
    while (k + 1 < n && ((char *)s)[k]) { out[k] = ((char *)s)[k]; k++; }
    out[k] = 0;
    free(s);
    return k != 0;
}

int main(int argc, char **argv) {
    if (argc < 4) {
        fprintf(stderr, "usage: wmcls <live_classlist_addr> <size> <name> [<name> ...]\n");
        return 2;
    }
    uint64_t list = strtoull(argv[1], NULL, 0);
    size_t size = (size_t)strtoull(argv[2], NULL, 0);
    pid_t pid = find_pid();
    if (!pid) { fprintf(stderr, "WindowManager not running\n"); return 2; }
    task_t t = MACH_PORT_NULL;
    kern_return_t kr = task_for_pid(mach_task_self(), pid, &t);
    if (kr != KERN_SUCCESS) {
        fprintf(stderr, "task_for_pid(%d): %s (root + SIP off required)\n", pid,
                mach_error_string(kr));
        return 1;
    }
    if (size == 0 || size > 0x100000) {
        fprintf(stderr, "classlist size %#zx out of range\n", size);
        return 2;
    }
    size_t got = 0;
    unsigned char *raw = readmem(t, list, size, &got);
    if (!raw || got < 8) {
        fprintf(stderr, "cannot read __objc_classlist at %#llx (%zu bytes)\n",
                (unsigned long long)list, size);
        return 1;
    }
    unsigned ncls = (unsigned)(got / 8);
    int want = argc - 3;
    int found = 0;
    if (!strcmp(argv[3], "--all")) {                 // diagnostic: every class in the list
        for (unsigned i = 0; i < ncls; i++) {
            uint64_t cls = ptr(*(uint64_t *)(raw + 8 * i));
            char nm[NAME_MAXC];
            uint32_t isz = 0;
            if (!cls) continue;
            if (!class_name(t, cls, nm, sizeof(nm), &isz)) { printf("%u %#llx <noname>\n", i,
                                                                     (unsigned long long)cls); continue; }
            printf("%u %#llx %u %s\n", i, (unsigned long long)cls, isz, nm);
        }
        free(raw);
        mach_port_deallocate(mach_task_self(), t);
        return 0;
    }
    // resolve each requested name, scanning the class list once per name (cheap: ~300 classes)
    for (int w = 0; w < want; w++) {
        const char *wanted = argv[3 + w];
        uint64_t at = 0;
        uint32_t inst = 0;
        for (unsigned i = 0; i < ncls; i++) {
            uint64_t cls = ptr(*(uint64_t *)(raw + 8 * i));
            if (!cls) continue;
            char nm[NAME_MAXC];
            uint32_t isz = 0;
            if (!class_name(t, cls, nm, sizeof(nm), &isz)) continue;
            if (!strcmp(nm, wanted)) { at = cls; inst = isz; break; }
        }
        if (at) { printf("%s %#llx %u\n", wanted, (unsigned long long)at, inst); found++; }
        else printf("%s 0 0\n", wanted);
    }
    fprintf(stderr, "wmcls: pid %d classes %u found %d/%d\n", pid, ncls, found, want);
    free(raw);
    mach_port_deallocate(mach_task_self(), t);
    return found == want ? 0 : 1;
}
