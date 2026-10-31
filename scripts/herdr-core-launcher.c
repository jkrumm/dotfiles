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
#include <errno.h>
#include <limits.h>
#include <stdlib.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;
static volatile sig_atomic_t child = 0;

static void forward(int sig) {
    if (child > 0) kill((pid_t)child, sig);
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s <program> [args...]\n", argv[0]);
        return 64;
    }
    // Block the forwarded signals before the handlers exist and until the child pid is published: a SIGTERM that
    // lands earlier would be dropped and the core would start after termination was requested. The child starts
    // with an empty mask.
    sigset_t fwd, none;
    sigemptyset(&fwd);
    sigaddset(&fwd, SIGTERM);
    sigaddset(&fwd, SIGINT);
    sigaddset(&fwd, SIGHUP);
    sigemptyset(&none);
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

    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    posix_spawnattr_setsigmask(&attr, &none);
    posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETSIGMASK);

    pid_t pid;
    int rc = posix_spawn(&pid, real, NULL, &attr, &argv[1], environ);
    posix_spawnattr_destroy(&attr);
    if (rc != 0) {
        fprintf(stderr, "%s: cannot spawn %s: %s\n", argv[0], argv[1], strerror(rc));
        return 127;
    }
    child = pid;
    sigprocmask(SIG_UNBLOCK, &fwd, NULL);

    int status;
    for (;;) {
        pid_t w = waitpid(pid, &status, 0);
        if (w == pid) break;
        if (w < 0 && errno != EINTR) return 70;
    }
    if (WIFEXITED(status)) return WEXITSTATUS(status);
    if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
    return 70;
}
