#define _GNU_SOURCE
#define _LARGEFILE64_SOURCE

#include <fcntl.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <unistd.h>

#if !defined(__x86_64__)
#error "The bundled node_repl compatibility bridge is x86-64 only."
#endif

int codex_fstat64(int fd, struct stat64 *buffer) __asm__("fstat64");
int codex_stat64(const char *path, struct stat64 *buffer) __asm__("stat64");
int codex_lstat64(const char *path, struct stat64 *buffer) __asm__("lstat64");

/* x86-64 uses the same kernel stat layout for the stat and stat64 APIs. */
int codex_fstat64(int fd, struct stat64 *buffer) {
    return (int)syscall(SYS_fstat, fd, buffer);
}

int codex_stat64(const char *path, struct stat64 *buffer) {
    return (int)syscall(SYS_newfstatat, AT_FDCWD, path, buffer, 0);
}

int codex_lstat64(const char *path, struct stat64 *buffer) {
    return (int)syscall(SYS_newfstatat, AT_FDCWD, path, buffer, AT_SYMLINK_NOFOLLOW);
}
