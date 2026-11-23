/*
 * Seridian: layout of the C library / OS types that Raven's Zig code takes from std.c and hands to the C library
 * (pthread_*_t inside rvn_mutex_t / rvn_cond_t / rvn_rwlock_t / rvn_thread_t, timespec, pollfd, dirent).
 * The C compiler is the oracle here: these are the system headers' structs. Compared by check.sh (step 3b) with
 * layout/system_layout.zig, which prints the same lines from std.c. Replaces the private-header layout checks
 * (core_layout.c and the others), which compared C headers that no C code compiles any more.
 */
#if !defined(_GNU_SOURCE)
#define _GNU_SOURCE
#endif
#include <dirent.h>
#include <poll.h>
#include <pthread.h>
#include <stddef.h>
#include <stdio.h>
#include <time.h>

#define TYPE(T) printf("sizeof " #T " %zu\nalignof " #T " %zu\n", sizeof(T), _Alignof(T))
#define FIELD(T, F, NAME) printf("offsetof " #T "." NAME " %zu\n", offsetof(T, F))

int main(void) {
	TYPE(pthread_t);
	TYPE(pthread_mutex_t);
	TYPE(pthread_cond_t);
	TYPE(pthread_rwlock_t);
	TYPE(time_t);
	TYPE(struct timespec);
	FIELD(struct timespec, tv_sec, "sec");
	FIELD(struct timespec, tv_nsec, "nsec");
	TYPE(struct pollfd);
	FIELD(struct pollfd, fd, "fd");
	FIELD(struct pollfd, events, "events");
	FIELD(struct pollfd, revents, "revents");
	FIELD(struct dirent, d_name, "name");
	printf("sizeof dirent.name %zu\n", sizeof(((struct dirent*)0)->d_name));
	return 0;
}
