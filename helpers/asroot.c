// asroot.c — the one privileged entry point, limited to fixed verbs.
//
// This used to be `#!/bin/zsh` + `exec /bin/zsh "$@"`: with the sudoers rule in place, anyone who
// could run the file had passwordless root with any argv (including an interactive shell over
// stdin).  The tool's real privileged surface is small, so the helper now parses argv itself and
// refuses everything it does not implement:
//
//   doctor [--json]        resolve + validate the six sites and the object-layout profile
//   status [--json]        build, armed/disarmed, capabilities, debugger, processes
//   pristine               every site still holds the on-disk image's bytes
//   install                write the patch
//   uninstall              restore every site byte-exactly
//   pristine/install/uninstall/log
//   daemon-load | arm      write /Library/LaunchDaemons/com.stagemgr.wmshipd.plist and bootstrap it
//   daemon-unload | disarm bootout the daemon and delete its plist
//   move <stage> [<stage>] move the frontmost window (validated, no shell)
//   resize <scale>         numeric, 0.2 … 2.0
//   level <0|3>
//   cfg <json>             the configuration document, size- and shape-checked
//   warm|measure|state|poses
//   --uid                  print the state-directory uid passed to the python children (no root)
//
// Every path is derived from this binary's own real location (bin/asroot -> the tool tree), never
// from argv or the environment.  There is no `sh -c`, no script file, no stdin and no inherited
// environment: the child is exec'd with a fixed PATH and HOME.
//
// The app still speaks the older `sudo -n asroot -c '<fixed command>'` shape for three commands
// (`true`, `install.py status --json`, `install.py cfg '<json>'`).  Those exact shapes are matched
// as strings and nothing else in the `-c` space is accepted; new callers use the verbs above.
//
// The escape hatch for repair is not this binary: it is `sudo /bin/zsh` with a password, or the
// bundled scripts run through osascript.  Nothing here grants a shell.
//
// Build: clang -O2 -arch arm64 (scripts/build-helpers.sh).  Signed like every other Mach-O.

#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

static const char *PY = "/usr/bin/python3";
static const char *PLIST = "/Library/LaunchDaemons/com.stagemgr.wmshipd.plist";
static const char *PLIST_LABEL = "com.stagemgr.wmshipd";

static char g_tree[PATH_MAX];
static char g_install[PATH_MAX];
static char g_ctl[PATH_MAX];
static char g_layout[PATH_MAX];
static char g_daemon[PATH_MAX];

// The child environment is fixed: no PATH, HOME or shell functions from the caller survive.
// The one fact that must survive is *which user this install belongs to*, because wmlayout derives
// the writable cache from a uid and this child cannot see the caller's HOME or USER.
// Same precedence as wmlayout.resolve_uid(): a real /dev/console login (never uid 0, which only
// means "headless/SSH/CI"), else sudo's record of the caller, else this process's uid.  uid 0 is
// used only when every one of those is root or absent.
static uid_t resolve_uid(void) {
    struct stat st;
    if (stat("/dev/console", &st) == 0 && st.st_uid != 0) return st.st_uid;
    const char *s = getenv("SUDO_UID");
    if (s && *s) {
        char *end = NULL;
        errno = 0;
        unsigned long v = strtoul(s, &end, 10);
        if (errno == 0 && end != s && *end == '\0' && v > 0 && v <= 0xFFFFFFFFul)
            return (uid_t)v;
    }
    return getuid();
}

static char g_uid_env[32];

static char *g_env[] = {
    (char *)"PATH=/usr/bin:/bin:/usr/sbin:/sbin",
    (char *)"HOME=/var/root",
    (char *)"LANG=en_US.UTF-8",
    g_uid_env,
    NULL,
};

static void refuse(const char *fmt, ...) {
    va_list ap;
    fputs("asroot: refused: ", stderr);
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fputc('\n', stderr);
    fputs("asroot: see `asroot --verbs` — this helper implements a fixed list of verbs and does "
          "not run shell commands.\n", stderr);
    exit(2);
}

static void need_root(void) {
    if (geteuid() != 0) {
        fprintf(stderr, "asroot: this verb must run as root (the sudoers rule grants exactly this "
                        "binary: sudo -n %s/bin/asroot <verb>)\n", g_tree);
        exit(1);
    }
}

static void join(char *out, size_t n, const char *a, const char *b) {
    if (snprintf(out, n, "%s/%s", a, b) >= (int)n) {
        fprintf(stderr, "asroot: path too long\n");
        exit(2);
    }
}

static int path_exists(const char *p) {
    struct stat st;
    return stat(p, &st) == 0;
}

// ---------------------------------------------------------------- argv validators
static int is_json_arg(const char *s) {
    size_t n = strlen(s);
    if (n < 2 || n > 8192) return 0;
    if (s[0] != '{' || s[n - 1] != '}') return 0;
    for (size_t i = 0; i < n; i++) {
        unsigned char c = (unsigned char)s[i];
        if (c == '\n' || c == '\r' || c == '\0' || c < 0x20) return 0;
    }
    return 1;
}

static int is_stage_arg(const char *s) {
    size_t n = strlen(s);
    if (n < 1 || n > 64) return 0;
    if (s[0] == '-') return 0;
    for (size_t i = 0; i < n; i++) {
        unsigned char c = (unsigned char)s[i];
        if (!isprint(c) || c == '\'' || c == '\\' || c == ';' || c == '|' ||
            c == '&' || c == '$' || c == '`' || c == '\n')
            return 0;
    }
    return 1;
}

static int is_scale_arg(const char *s) {
    char *end = NULL;
    size_t n = strlen(s);
    if (n < 1 || n > 16) return 0;
    errno = 0;
    double v = strtod(s, &end);
    if (errno != 0 || end == s || *end != '\0') return 0;
    // the shipped promise: the strip renders at 0.4 … 1.5 (1.0 = natural)
    return v >= 0.4 && v <= 1.5;
}

static int is_index_arg(const char *s) {
    size_t n = strlen(s);
    if (n < 1 || n > 9) return 0;
    for (size_t i = 0; i < n; i++)
        if (!isdigit((unsigned char)s[i])) return 0;
    return 1;
}

// ---------------------------------------------------------------- exec of the python tools
static void run_python(const char *script, char *const *args) {
    char *argv[16];
    int i = 0;
    argv[i++] = (char *)PY;
    argv[i++] = (char *)script;
    for (int j = 0; args[j] && i < 15; j++) argv[i++] = args[j];
    argv[i] = NULL;
    execve(PY, argv, g_env);
    fprintf(stderr, "asroot: cannot execute %s: %s\n", PY, strerror(errno));
    exit(1);
}

static void run_install(char *const *args) { run_python(g_install, args); }
static void run_ctl(char *const *args) { run_python(g_ctl, args); }

// Same fixed argv as run_python, but wait for it (teardown must know whether the restore worked).
static int run_python_wait(const char *script, char *const *args) {
    pid_t pid = fork();
    if (pid == 0) {
        char *argv[16];
        int i = 0;
        argv[i++] = (char *)PY;
        argv[i++] = (char *)script;
        for (int j = 0; args[j] && i < 15; j++) argv[i++] = args[j];
        argv[i] = NULL;
        execve(PY, argv, g_env);
        _exit(127);
    }
    if (pid < 0) return 1;
    int st = 0;
    waitpid(pid, &st, 0);
    return WIFEXITED(st) ? WEXITSTATUS(st) : 1;
}

// ---------------------------------------------------------------- daemon plist
static int read_file(const char *path, char *buf, size_t n) {
    int fd = open(path, O_RDONLY);
    if (fd < 0) return -1;
    ssize_t got = read(fd, buf, n - 1);
    close(fd);
    if (got < 0) return -1;
    buf[got] = '\0';
    return (int)got;
}

// Render the plist with wmlayout and prove it points at this tree before installing it.  The
// template lives in the (user-writable) tree, so the rendered text is checked, not trusted.
static void daemon_load(void) {
    char tmp[] = "/tmp/asroot-plist.XXXXXX";
    int fd = mkstemp(tmp);
    if (fd < 0) {
        fprintf(stderr, "asroot: cannot create a scratch plist: %s\n", strerror(errno));
        exit(1);
    }
    close(fd);

    pid_t pid = fork();
    if (pid == 0) {
        char *argv[] = {(char *)PY, g_layout, (char *)"plist", tmp, NULL};
        execve(PY, argv, g_env);
        _exit(127);
    }
    int st = 0;
    waitpid(pid, &st, 0);
    if (!WIFEXITED(st) || WEXITSTATUS(st) != 0) {
        unlink(tmp);
        fprintf(stderr, "asroot: wmlayout could not render the plist\n");
        exit(1);
    }

    char text[65536];
    if (read_file(tmp, text, sizeof text) <= 0) {
        unlink(tmp);
        fprintf(stderr, "asroot: rendered plist is empty\n");
        exit(1);
    }
    char daemon_py[PATH_MAX + 32];
    snprintf(daemon_py, sizeof daemon_py, "<string>%s</string>", g_daemon);
    if (!strstr(text, daemon_py) || !strstr(text, "<string>/usr/bin/python3</string>") ||
        !strstr(text, "/tmp/wmship/")) {
        unlink(tmp);
        fprintf(stderr, "asroot: refusing to install a plist that does not name this tree's "
                        "daemon and /tmp/wmship (relocation guard)\n");
        exit(1);
    }

    // Explicit mode/ownership: the plist template's own bits are not trusted.
    chmod(tmp, 0644);
    if (rename(tmp, PLIST) != 0) {
        // rename across filesystems is impossible here, but a restricted /Library could fail
        int in = open(tmp, O_RDONLY);
        int out = (in >= 0) ? open(PLIST, O_WRONLY | O_CREAT | O_TRUNC, 0644) : -1;
        if (in < 0 || out < 0) {
            fprintf(stderr, "asroot: cannot install %s: %s\n", PLIST, strerror(errno));
            if (in >= 0) close(in);
            if (out >= 0) close(out);
            unlink(tmp);
            exit(1);
        }
        char buf[8192];
        ssize_t n;
        while ((n = read(in, buf, sizeof buf)) > 0) {
            if (write(out, buf, (size_t)n) != n) {
                fprintf(stderr, "asroot: short write to %s\n", PLIST);
                close(in);
                close(out);
                unlink(tmp);
                exit(1);
            }
        }
        close(in);
        close(out);
        unlink(tmp);
    }
    chown(PLIST, 0, 0);
    chmod(PLIST, 0644);

    char target[PATH_MAX + 64];
    snprintf(target, sizeof target, "system/%s", PLIST_LABEL);
    pid = fork();
    if (pid == 0) {
        char *argv[] = {(char *)"/bin/launchctl", (char *)"bootout", target, NULL};
        execve("/bin/launchctl", argv, g_env);
        _exit(127);
    }
    st = 0;
    waitpid(pid, &st, 0);          // bootout of a job that is not loaded is expected to fail

    pid = fork();
    if (pid == 0) {
        char *argv[] = {(char *)"/bin/launchctl", (char *)"bootstrap", (char *)"system",
                        (char *)PLIST, NULL};
        execve("/bin/launchctl", argv, g_env);
        _exit(127);
    }
    st = 0;
    waitpid(pid, &st, 0);
    if (!WIFEXITED(st) || WEXITSTATUS(st) != 0) {
        fprintf(stderr, "asroot: launchctl bootstrap failed (%d)\n", WEXITSTATUS(st));
        exit(1);
    }
    printf("asroot: daemon %s loaded from %s\n", PLIST_LABEL, PLIST);
}

static void daemon_unload(void) {
    char target[PATH_MAX + 64];
    snprintf(target, sizeof target, "system/%s", PLIST_LABEL);
    pid_t pid = fork();
    if (pid == 0) {
        char *argv[] = {(char *)"/bin/launchctl", (char *)"bootout", target, NULL};
        execve("/bin/launchctl", argv, g_env);
        _exit(127);
    }
    int st = 0;
    waitpid(pid, &st, 0);
    unlink(PLIST);
    printf("asroot: daemon %s booted out and %s removed\n", PLIST_LABEL, PLIST);
}

static int wait_child(pid_t pid) {
    int st = 0;
    waitpid(pid, &st, 0);
    return WIFEXITED(st) ? WEXITSTATUS(st) : 1;
}

static int run_fixed(const char *path, char *const *argv) {
    pid_t pid = fork();
    if (pid == 0) {
        execve(path, argv, g_env);
        _exit(127);
    }
    return pid < 0 ? 1 : wait_child(pid);
}

static void pkill_name(const char *name) {
    char *argv[] = {(char *)"/usr/bin/pkill", (char *)"-x", (char *)name, NULL};
    run_fixed("/usr/bin/pkill", argv);
}

// Is there a live WindowManager to restore?  A clean "nothing to verify" is not a failed restore:
// after a crash or a logout the six sites went away with the process, and refusing to uninstall
// in that state would leave the app with no way out.
static int wm_running(void) {
    char *argv[] = {(char *)"/usr/bin/pkill", (char *)"-0", (char *)"-x", (char *)"WindowManager", NULL};
    return run_fixed("/usr/bin/pkill", argv) == 0;
}

// `launchctl bootout` returns before the job has actually exited, and wmshipd writes daemon.json
// into /tmp/wmship on its way out: removing the directory first lets the dying daemon recreate it
// (observed: an uninstall "removed /tmp/wmship" and left daemon.json behind).  Wait for the
// process, then remove.  The pattern is a constant, not input.
static int daemon_process_running(void) {
    char *argv[] = {(char *)"/usr/bin/pgrep", (char *)"-f", (char *)"wmshipd.py", NULL};
    return run_fixed("/usr/bin/pgrep", argv) == 0;
}

static void wait_for_daemon_exit(void) {
    for (int i = 0; i < 30 && daemon_process_running(); i++) usleep(100000);
    if (!daemon_process_running()) return;
    char *kill[] = {(char *)"/usr/bin/pkill", (char *)"-f", (char *)"wmshipd.py", NULL};
    run_fixed("/usr/bin/pkill", kill);
    for (int i = 0; i < 20 && daemon_process_running(); i++) usleep(100000);
}

// teardown [--keep-state]: the cask's privileged undo.  Fixed order: restore and verify while the
// helper that can restore still exists, then stop the daemon, then remove the plist and the rule.
// Every target is a constant or derived from this binary's own tree; nothing comes from argv.
static int verb_teardown(int keep_state) {
    int rc = 0;
    int live = wm_running();
    if (path_exists("/tmp/wmship/state.json")) {
        printf("patch: restoring the six sites before removal\n");
        char *a1[] = {(char *)"uninstall", NULL};
        int r1 = run_python_wait(g_install, a1);
        char *a2[] = {(char *)"pristine", NULL};
        int r2 = (r1 == 0) ? run_python_wait(g_install, a2) : 1;
        if (r1 == 0 && r2 == 0) {
            printf("patch: disarmed — every site verified byte-exact\n");
        } else if (!live) {
            printf("patch: WindowManager is not running; its sites went with the process\n");
        } else {
            printf("PATCH: WARNING the restore could not be verified (install.py rc %d/%d)\n", r1, r2);
            printf("PATCH: UNVERIFIED — the six sites may still be patched\n");
            rc = 1;
        }
    } else {
        printf("patch: no /tmp/wmship/state.json — nothing was armed\n");
    }

    char target[PATH_MAX + 64];
    snprintf(target, sizeof target, "system/%s", PLIST_LABEL);
    char *boot[] = {(char *)"/bin/launchctl", (char *)"bootout", target, NULL};
    if (run_fixed("/bin/launchctl", boot) == 0) {
        printf("daemon: booted out %s\n", target);
    } else {
        printf("daemon: %s was not loaded\n", target);
    }
    wait_for_daemon_exit();
    printf("daemon: no wmshipd.py process remains\n");

    pkill_name("wmhb");
    pkill_name("wmobs");
    pkill_name("r21obs");
    printf("helper: wmhb, wmobs and r21obs stopped\n");

    // Re-check after the daemon is gone: its periodic re-apply must not have run between the
    // restore above and the bootout.  This is the last moment the tree can still verify itself.
    char *a3[] = {(char *)"pristine", NULL};
    if (run_python_wait(g_install, a3) != 0) {
        if (!live) {
            printf("patch: WindowManager is not running; nothing live can still be patched\n");
        } else {
            printf("PATCH: WARNING a site was re-patched between the restore and the daemon stop\n");
            printf("PATCH: UNVERIFIED — the six sites may still be patched\n");
            rc = 1;
        }
    } else {
        printf("patch: verified pristine again after the daemon stop\n");
    }

    if (unlink(PLIST) == 0) printf("plist: removed %s\n", PLIST);

    char rule[65536];
    int rn = read_file("/etc/sudoers.d/stage-pilot", rule, sizeof rule);
    if (rn > 0) {
        char grant[PATH_MAX + 32];
        snprintf(grant, sizeof grant, "%s/bin/asroot", g_tree);
        if (strstr(rule, grant)) {
            if (unlink("/etc/sudoers.d/stage-pilot") == 0)
                printf("rule: removed /etc/sudoers.d/stage-pilot\n");
            else
                printf("rule: WARNING could not remove /etc/sudoers.d/stage-pilot\n");
        } else {
            printf("rule: LEFT IN PLACE — it does not grant %s\n", grant);
        }
    } else {
        printf("rule: /etc/sudoers.d/stage-pilot was not present\n");
    }

    if (keep_state) {
        printf("state: kept /tmp/wmship (--keep-state)\n");
    } else if (path_exists("/tmp/wmship")) {
        char *rm[] = {(char *)"/bin/rm", (char *)"-rf", (char *)"/tmp/wmship", NULL};
        if (run_fixed("/bin/rm", rm) == 0)
            printf("state: removed /tmp/wmship\n");
        else
            printf("state: WARNING could not remove /tmp/wmship\n");
    } else {
        printf("state: /tmp/wmship was not present\n");
    }
    return rc;
}

static int daemon_status(void) {
    char target[PATH_MAX + 64];
    snprintf(target, sizeof target, "system/%s", PLIST_LABEL);
    pid_t pid = fork();
    if (pid == 0) {
        char *argv[] = {(char *)"/bin/launchctl", (char *)"print", target, NULL};
        execve("/bin/launchctl", argv, g_env);
        _exit(127);
    }
    int st = 0;
    waitpid(pid, &st, 0);
    return WIFEXITED(st) ? WEXITSTATUS(st) : 1;
}

// The runtime state directory is a fixed, allow-listed path; rm is exec'd with a fixed argv, so
// this is not a general "delete a path" verb.
static void remove_state(void) {
    pid_t pid = fork();
    if (pid == 0) {
        char *argv[] = {(char *)"/bin/rm", (char *)"-rf", (char *)"/tmp/wmship", NULL};
        execve("/bin/rm", argv, g_env);
        _exit(127);
    }
    int st = 0;
    waitpid(pid, &st, 0);
    if (!WIFEXITED(st) || WEXITSTATUS(st) != 0) {
        fprintf(stderr, "asroot: could not remove /tmp/wmship\n");
        exit(1);
    }
    printf("asroot: removed /tmp/wmship\n");
}

// ---------------------------------------------------------------- the legacy app shapes
// The Swift app (Sources/SturgeonKit/Commands.swift) still builds:
//   sudo -n asroot -c "true"
//   sudo -n asroot -c "/usr/bin/python3 '<install.py>' status --json"
//   sudo -n asroot -c "/usr/bin/python3 '<install.py>' cfg '<json>'"
// Those three exact shapes are accepted so this hardening does not need a lock-step app release.
// Everything else in the `-c` space is refused, including `-c true; ...`.
static void legacy_command(const char *cmd) {
    // Validate the whole string first, so a hostile invocation is refused even when it is run
    // without sudo (and therefore says "refused", not "must run as root").
    if (strcmp(cmd, "true") == 0) {
        need_root();
        exit(0);
    }

    const char *prefix = "/usr/bin/python3 '";
    if (strncmp(cmd, prefix, strlen(prefix)) != 0) {
        refuse("unsupported -c command; use a verb (doctor, status, install, …)");
    }
    const char *path = cmd + strlen(prefix);
    const char *close = strchr(path, '\'');
    if (!close) refuse("malformed -c command (unterminated path)");
    char found[PATH_MAX];
    size_t n = (size_t)(close - path);
    if (n == 0 || n >= sizeof found) refuse("malformed -c command (empty path)");
    memcpy(found, path, n);
    found[n] = '\0';

    char real[PATH_MAX];
    if (!realpath(found, real)) refuse("-c command names a path that does not exist");
    if (strcmp(real, g_install) != 0) refuse("-c command names something other than this tree's "
                                             "install.py");
    const char *rest = close + 1;

    char json[8192];
    int is_status = (strcmp(rest, " status --json") == 0);
    int is_cfg = 0;
    const char *cfg_prefix = " cfg '";
    if (!is_status && strncmp(rest, cfg_prefix, strlen(cfg_prefix)) == 0) {
        const char *js = rest + strlen(cfg_prefix);
        size_t jn = strlen(js);
        if (jn < 2 || js[jn - 1] != '\'') refuse("malformed cfg command");
        if (jn - 1 >= sizeof json) refuse("cfg command is too long");
        memcpy(json, js, jn - 1);
        json[jn - 1] = '\0';
        if (!is_json_arg(json)) refuse("cfg command does not carry a JSON object");
        is_cfg = 1;
    }
    if (!is_status && !is_cfg) {
        refuse("unsupported -c command; use a verb (doctor, status, install, …)");
    }

    need_root();
    if (is_status) {
        char *args[] = {(char *)"status", (char *)"--json", NULL};
        run_install(args);
    }
    char *args[] = {(char *)"cfg", json, NULL};
    run_install(args);
}

static int verb_known(const char *v) {
    static const char *known[] = {
        "doctor", "status", "pristine", "install", "uninstall", "log", "counters",
        "probe", "daemon-load", "arm", "daemon-unload", "disarm", "daemon-status",
        "remove-state", "teardown", "move", "resize", "teach", "selfcheck",
        "level", "cfg", "warm", "measure", "state", "poses", "trace", NULL,
    };
    for (int i = 0; known[i]; i++)
        if (strcmp(v, known[i]) == 0) return 1;
    return 0;
}

static void verbs(void) {
    puts("asroot — privileged verbs (no shell):\n"
         "  doctor [--json] [--no-live] [--mode pristine|armed|auto]\n"
         "  status [--json]   pristine   install   uninstall   log   counters   selfcheck   teach\n"
         "  probe   daemon-load|arm   daemon-unload|disarm   daemon-status   remove-state\n"
         "  teardown [--keep-state]\n"
         "  move <stage> [--cgid N]   resize <0.4..1.5> [--teach]   level <0|3>   cfg [<json>]\n"
         "  warm | measure | state | poses | trace [--reset]\n"
         "Every path is derived from this binary's location; there is no sh -c and no stdin.\n"
         "  --uid             print the uid this helper passes to its python children\n"
         "verbs: doctor status pristine install uninstall log counters selfcheck teach probe "
         "daemon-load arm daemon-unload disarm daemon-status remove-state teardown move resize "
         "level cfg warm measure state poses trace");
}

// ---------------------------------------------------------------- argument parsing
int main(int argc, char **argv) {
    snprintf(g_uid_env, sizeof g_uid_env, "STURGEON_UID=%u", (unsigned)resolve_uid());

    char exe[PATH_MAX];
    uint32_t size = sizeof exe;
    if (_NSGetExecutablePath(exe, &size) != 0) {
        fprintf(stderr, "asroot: cannot resolve its own path\n");
        return 2;
    }
    char real[PATH_MAX];
    if (!realpath(exe, real)) {
        fprintf(stderr, "asroot: cannot resolve its own path: %s\n", strerror(errno));
        return 2;
    }
    char *slash = strrchr(real, '/');
    if (!slash) return 2;
    *slash = '\0';                 // .../bin
    slash = strrchr(real, '/');
    if (!slash) return 2;
    *slash = '\0';                 // the tool tree
    snprintf(g_tree, sizeof g_tree, "%s", real);
    join(g_install, sizeof g_install, g_tree, "wmship/install.py");
    join(g_ctl, sizeof g_ctl, g_tree, "wmship/ctl.py");
    join(g_layout, sizeof g_layout, g_tree, "wmlayout.py");
    join(g_daemon, sizeof g_daemon, g_tree, "wmship/wmshipd.py");

    if (argc < 2) refuse("no verb given (this is not a shell)");

    const char *verb = argv[1];

    if (strcmp(verb, "--verbs") == 0 || strcmp(verb, "help") == 0) {
        verbs();
        return 0;
    }

    // The one non-privileged query: which uid the python children will name for the state
    // directory.  It exposes nothing but /dev/console ownership, SUDO_UID or this uid.
    if (strcmp(verb, "--uid") == 0) {
        if (argc != 2) refuse("--uid takes no arguments");
        printf("%u\n", (unsigned)resolve_uid());
        return 0;
    }

    if (strcmp(verb, "-c") == 0) {
        if (argc != 3) refuse("-c takes exactly one command string");
        legacy_command(argv[2]);
    }

    // Anything beginning with '-' that is not a verb is an attempt to make this a shell.
    if (verb[0] == '-') refuse("options are not accepted (no -i, -l, -s, -c except the app shapes)");
    if (!verb_known(verb)) refuse("unknown verb '%s'", verb);

    if (!path_exists(g_install) || !path_exists(g_layout)) {
        fprintf(stderr, "asroot: broken install — %s or %s is missing\n", g_install, g_layout);
        return 2;
    }
    need_root();

    char *a1 = NULL;
    int nargs = argc - 2;
    if (nargs > 0) a1 = argv[2];

    if (strcmp(verb, "doctor") == 0) {
        // doctor [--json] [--no-live] [--mode pristine|armed|auto]
        char *args[8];
        int n = 0;
        args[n++] = (char *)"doctor";
        int json = 0, mode = 0;
        for (int i = 0; i < nargs; i++) {
            const char *a = argv[2 + i];
            if (strcmp(a, "--json") == 0) {
                if (json) refuse("doctor: --json given twice");
                json = 1;
                args[n++] = (char *)"--json";
            } else if (strcmp(a, "--no-live") == 0) {
                args[n++] = (char *)"--no-live";
            } else if (strcmp(a, "--mode") == 0) {
                if (mode || i + 1 >= nargs) refuse("doctor: --mode needs pristine|armed|auto");
                const char *m = argv[2 + ++i];
                if (strcmp(m, "pristine") != 0 && strcmp(m, "armed") != 0 &&
                    strcmp(m, "auto") != 0)
                    refuse("doctor: --mode must be pristine, armed or auto");
                mode = 1;
                args[n++] = (char *)"--mode";
                args[n++] = (char *)m;
            } else {
                refuse("doctor: unsupported argument '%s'", a);
            }
            if (n > 6) refuse("doctor: too many arguments");
        }
        args[n] = NULL;
        run_install(args);
    }
    if (strcmp(verb, "status") == 0) {
        int json = 0;
        if (nargs == 1) {
            if (strcmp(a1, "--json") != 0) refuse("status accepts only --json");
            json = 1;
        } else if (nargs != 0) {
            refuse("status takes no arguments other than --json");
        }
        char *args[3] = {(char *)"status", NULL, NULL};
        if (json) {
            args[1] = (char *)"--json";
            args[2] = NULL;
        }
        run_install(args);
    }
    if (strcmp(verb, "probe") == 0) {
        if (nargs != 0) refuse("probe takes no arguments");
        return 0;                               // reached only after need_root()
    }
    if (strcmp(verb, "pristine") == 0 || strcmp(verb, "install") == 0 ||
        strcmp(verb, "uninstall") == 0 || strcmp(verb, "log") == 0 ||
        strcmp(verb, "counters") == 0) {
        if (nargs != 0) refuse("%s takes no arguments", verb);
        char *args[] = {(char *)verb, NULL};
        run_install(args);
    }
    if (strcmp(verb, "teach") == 0 || strcmp(verb, "selfcheck") == 0) {
        if (nargs != 0) refuse("%s takes no arguments", verb);
        char *args[] = {(char *)verb, NULL};
        run_ctl(args);
    }
    if (strcmp(verb, "daemon-load") == 0 || strcmp(verb, "arm") == 0) {
        if (nargs != 0) refuse("%s takes no arguments", verb);
        daemon_load();
        return 0;
    }
    if (strcmp(verb, "daemon-unload") == 0 || strcmp(verb, "disarm") == 0) {
        if (nargs != 0) refuse("%s takes no arguments", verb);
        daemon_unload();
        return 0;
    }
    if (strcmp(verb, "teardown") == 0) {          // the cask's privileged undo
        int keep = 0;
        if (nargs == 1 && strcmp(a1, "--keep-state") == 0) keep = 1;
        else if (nargs != 0) refuse("teardown accepts only --keep-state");
        return verb_teardown(keep);
    }
    if (strcmp(verb, "daemon-status") == 0) {
        if (nargs != 0) refuse("%s takes no arguments", verb);
        return daemon_status();
    }
    if (strcmp(verb, "remove-state") == 0) {
        if (nargs != 0) refuse("%s takes no arguments", verb);
        remove_state();
        return 0;
    }
    if (strcmp(verb, "move") == 0) {
        // move <stage> [--cgid N]
        const char *stage = NULL, *cgid = NULL;
        for (int i = 0; i < nargs; i++) {
            const char *a = argv[2 + i];
            if (strcmp(a, "--cgid") == 0) {
                if (cgid || i + 1 >= nargs) refuse("move: --cgid needs a numeric window id");
                cgid = argv[2 + ++i];
                if (!is_index_arg(cgid)) refuse("move: --cgid must be a decimal window id");
            } else if (!stage && a[0] != '-') {
                if (!is_stage_arg(a)) refuse("move: stage name is not printable or is too long");
                stage = a;
            } else {
                refuse("move: unsupported argument '%s'", a);
            }
        }
        if (!stage) stage = "current";
        char *args[] = {(char *)"move", (char *)stage, (char *)"--cgid", (char *)cgid, NULL};
        if (cgid) run_ctl(args);
        char *plain[] = {(char *)"move", (char *)stage, NULL};
        run_ctl(plain);
    }
    if (strcmp(verb, "resize") == 0) {
        // resize <0.4..1.5> [--teach]
        const char *scale = NULL;
        int teach = 0;
        for (int i = 0; i < nargs; i++) {
            const char *a = argv[2 + i];
            if (strcmp(a, "--teach") == 0) {
                if (teach) refuse("resize: --teach given twice");
                teach = 1;
            } else if (!scale && a[0] != '-') {
                if (!is_scale_arg(a)) refuse("resize: scale must be a number in 0.4 … 1.5");
                scale = a;
            } else {
                refuse("resize: unsupported argument '%s'", a);
            }
        }
        if (!scale) scale = "1.0";
        char *args[] = {(char *)"resize", (char *)scale, (char *)"--teach", NULL};
        if (teach) run_ctl(args);
        char *plain[] = {(char *)"resize", (char *)scale, NULL};
        run_ctl(plain);
    }
    if (strcmp(verb, "level") == 0) {
        if (nargs != 1) refuse("level takes exactly one value");
        if (strcmp(a1, "0") != 0 && strcmp(a1, "3") != 0) refuse("level accepts only 0 or 3");
        char *args[] = {(char *)"level", a1, NULL};
        run_ctl(args);
    }
    if (strcmp(verb, "cfg") == 0) {
        if (nargs == 0) {                       // `wmship.sh cfg` reads the configuration
            char *args[] = {(char *)"cfg", NULL};
            run_ctl(args);
        }
        if (nargs != 1) refuse("cfg takes either no argument (read) or one JSON document (write)");
        if (!is_json_arg(a1)) refuse("cfg: argument is not a JSON object under 8 KiB");
        char *args[] = {(char *)"cfg", a1, NULL};
        run_install(args);                      // the write path is install.py cfg
    }
    if (strcmp(verb, "warm") == 0 || strcmp(verb, "measure") == 0 ||
        strcmp(verb, "state") == 0 || strcmp(verb, "poses") == 0) {
        if (nargs != 0) refuse("%s takes no arguments", verb);
        char *args[] = {(char *)verb, NULL};
        run_ctl(args);
    }
    if (strcmp(verb, "trace") == 0) {
        // trace [--reset] -- the keeper's diagnostic ring; a read plus an optional zeroing write
        int reset = 0;
        if (nargs == 1 && strcmp(a1, "--reset") == 0) reset = 1;
        else if (nargs != 0) refuse("trace accepts only --reset");
        char *args[] = {(char *)"trace", (char *)"--reset", NULL};
        if (reset) run_ctl(args);
        char *plain[] = {(char *)"trace", NULL};
        run_ctl(plain);
    }

    refuse("unknown verb '%s'", verb);
    return 2;
}
