// herdr-core-launcher — the LaunchAgent's own program for com.jkrumm.herdr-core.
//
// macOS TCC attributes a launchd job's file access to the job's program and every descendant that does
// not disclaim. The core is ad-hoc signed and moves with each release, so a Full Disk Access grant on it
// dies on every upgrade. This launcher is built once and lives at a stable path: the grant goes to it, and
// the core runs as its child. See docs/tcc.md.
//
// usage: herdr-core-launcher <program> [args...]
// <program> is resolved with realpath() first: the core reads its own path to decide whether a package manager
// owns it (`/Cellar/` -> homebrew), and a symlink such as /opt/homebrew/opt/herdr-core/bin/herdr-core would hide that.
// Spawns <program> as a child (never exec: exec would make the core the responsible process again),
// does NOT disclaim responsibility, forwards SIGTERM/SIGINT/SIGHUP, exits with the child.
//
// Sets HC_LAUNCHD_DIRECT=<own pid> for the child. Since 0.1.17 a macOS `herdr-core serve` re-launches itself as a
// one-shot launchd job (its own coalition, its own TCC responsibility), exits 0 and leaves the core running as an
// orphan: launchd then respawns this job every ThrottleInterval and never sees it running. The core skips that
// escape when HC_LAUNCHD_DIRECT names its parent's pid (upstream crates/herdr-core/src/platform/macos_launchd.rs,
// prepare_core) and removes the variable before it spawns anything, so terminals never see it. Any other child
// ignores it.
//
// Reclaims the lock. Every holder supervises the core too: when its core is gone for 3 s (HC_HOLDER_GRACE_MS), it starts
// one itself, through the same escape, so the core ends up outside this job. A `serve` that finds core.lock taken exits 0
// at once. When the child is `herdr-core serve` and exits 0 while another herdr-core process of this user holds this
// session's core.lock, the launcher SIGTERMs that process (a core's planned stop: holders keep every terminal), waits
// for it to go and starts its own `serve` at once, up to 3 times per run. It never touches anything else.
// See docs/herdr-core.md §Core as a LaunchAgent.
#include <errno.h>
#include <libproc.h>
#include <limits.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/proc_info.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

extern char **environ;
static volatile sig_atomic_t child = 0;
static volatile sig_atomic_t stopping = 0;

static void forward(int sig) {
    stopping = 1;
    if (child > 0) kill((pid_t)child, sig);
}

static void say(const char *fmt, long a) {
    char at[32];
    time_t now = time(NULL);
    strftime(at, sizeof at, "%Y-%m-%dT%H:%M:%S", localtime(&now));
    fprintf(stderr, "%s herdr-core-launcher: ", at);
    fprintf(stderr, fmt, a);
    fputc('\n', stderr);
}

static const char *base(const char *path) {
    const char *b = strrchr(path, '/');
    return b ? b + 1 : path;
}

static int is_core(const char *path) {
    return strcmp(base(path), "herdr-core") == 0 || strcmp(base(path), "hc") == 0;
}

// This session's core.lock, as hc computes it: $XDG_STATE_HOME (else ~/.local/state)/herdr-core/<HC_SESSION or default>.
static int lock_path(char *out, size_t size) {
    const char *state = getenv("XDG_STATE_HOME"), *session = getenv("HC_SESSION"), *home = getenv("HOME");
    char path[PATH_MAX];
    int n;
    if (state && *state) n = snprintf(path, sizeof path, "%s/herdr-core/%s/core.lock", state, session && *session ? session : "default");
    else if (home && *home) n = snprintf(path, sizeof path, "%s/.local/state/herdr-core/%s/core.lock", home, session && *session ? session : "default");
    else return 0;
    if (n <= 0 || (size_t)n >= sizeof path) return 0;
    if (!realpath(path, out)) snprintf(out, size, "%s", path);
    return 1;
}

// The pid of another herdr-core process of this user that has `lock` open, else 0. libproc only: no hc call (one would
// start a core), no lsof.
static pid_t lock_holder(const char *lock) {
    int bytes = proc_listpids(PROC_UID_ONLY, getuid(), NULL, 0);
    if (bytes <= 0) return 0;
    int cap = bytes / (int)sizeof(pid_t) + 256;
    pid_t *pids = calloc((size_t)cap, sizeof(pid_t));
    if (!pids) return 0;
    int count = proc_listpids(PROC_UID_ONLY, getuid(), pids, cap * (int)sizeof(pid_t)) / (int)sizeof(pid_t);
    pid_t found = 0;
    for (int i = 0; i < count && !found; i++) {
        pid_t p = pids[i];
        char exe[PROC_PIDPATHINFO_MAXSIZE];
        if (p <= 1 || p == getpid() || proc_pidpath(p, exe, sizeof exe) <= 0 || !is_core(exe)) continue;
        int size = proc_pidinfo(p, PROC_PIDLISTFDS, 0, NULL, 0);
        if (size <= 0) continue;
        struct proc_fdinfo *fds = malloc((size_t)size);
        if (!fds) continue;
        int nfds = proc_pidinfo(p, PROC_PIDLISTFDS, 0, fds, size) / (int)sizeof(struct proc_fdinfo);
        for (int j = 0; j < nfds && !found; j++) {
            if (fds[j].proc_fdtype != PROX_FDTYPE_VNODE) continue;
            struct vnode_fdinfowithpath vi;
            if (proc_pidfdinfo(p, fds[j].proc_fd, PROC_PIDFDVNODEPATHINFO, &vi, sizeof vi) == (int)sizeof vi
                && strcmp(vi.pvip.vip_path, lock) == 0)
                found = p;
        }
        free(fds);
    }
    free(pids);
    return found;
}

// Spawn the program as a child with the forwarded signals blocked until its pid is published, wait for it, and map
// its end to an exit code: the child's code, 128 + signal, or 70.
static int run(const char *real, char **args, sigset_t *fwd) {
    sigset_t none;
    sigemptyset(&none);
    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    posix_spawnattr_setsigmask(&attr, &none);
    posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETSIGMASK);
    sigprocmask(SIG_BLOCK, fwd, NULL);
    pid_t pid;
    int rc = posix_spawn(&pid, real, NULL, &attr, args, environ);
    posix_spawnattr_destroy(&attr);
    if (rc != 0) {
        sigprocmask(SIG_UNBLOCK, fwd, NULL);
        fprintf(stderr, "herdr-core-launcher: cannot spawn %s: %s\n", real, strerror(rc));
        return 127;
    }
    child = pid;
    sigprocmask(SIG_UNBLOCK, fwd, NULL);
    // a SIGTERM that arrived while blocked was forwarded to the old (dead) child: hand it to this one
    if (stopping) kill(pid, SIGTERM);
    int status;
    for (;;) {
        pid_t w = waitpid(pid, &status, 0);
        if (w == pid) break;
        if (w < 0 && errno != EINTR) {
            child = 0;
            return 70;
        }
    }
    child = 0;
    if (WIFEXITED(status)) return WEXITSTATUS(status);
    if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
    return 70;
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s <program> [args...]\n", argv[0]);
        return 64;
    }
    // Block the forwarded signals before the handlers exist and until a child pid is published: a SIGTERM that
    // lands earlier would be dropped and the core would start after termination was requested. The child starts
    // with an empty mask.
    sigset_t fwd;
    sigemptyset(&fwd);
    sigaddset(&fwd, SIGTERM);
    sigaddset(&fwd, SIGINT);
    sigaddset(&fwd, SIGHUP);
    sigprocmask(SIG_BLOCK, &fwd, NULL);

    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_handler = forward;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGTERM, &sa, NULL);
    sigaction(SIGINT, &sa, NULL);
    sigaction(SIGHUP, &sa, NULL);

    char real[PATH_MAX];
    if (!realpath(argv[1], real)) {
        fprintf(stderr, "%s: cannot resolve %s: %s\n", argv[0], argv[1], strerror(errno));
        return 127;
    }
    argv[1] = real;

    char self[24];
    snprintf(self, sizeof self, "%ld", (long)getpid());
    if (setenv("HC_LAUNCHD_DIRECT", self, 1) != 0) {
        fprintf(stderr, "%s: cannot set HC_LAUNCHD_DIRECT: %s\n", argv[0], strerror(errno));
        return 71;
    }

    char lock[PATH_MAX];
    int core = is_core(real) && argc >= 3 && strcmp(argv[2], "serve") == 0 && lock_path(lock, sizeof lock);
    for (int reclaimed = 0;; reclaimed++) {
        int code = run(real, &argv[1], &fwd);
        if (stopping || !core || code != 0 || reclaimed >= 3) return code;
        pid_t other = lock_holder(lock);
        if (other <= 0) return code;
        say("core.lock is held by pid %ld, a core outside this job (a holder's restart or a client's start): "
            "stopping it with SIGTERM (its terminals are kept) and starting this job's core", (long)other);
        kill(other, SIGTERM);
        int gone = 0;
        for (int i = 0; i < 600 && !stopping; i++) {
            if (kill(other, 0) != 0 && errno == ESRCH) {
                gone = 1;
                break;
            }
            usleep(50000);
        }
        if (stopping) return 0;
        if (!gone) {
            say("pid %ld did not stop within 30 s; leaving it to launchd's next start", (long)other);
            return 75;
        }
    }
}
