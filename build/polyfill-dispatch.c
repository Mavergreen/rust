/* 10.9 back-fill for 4 modern-libdispatch symbols that dispatch2 (pulled by ctrlc, a rustc_driver dep
 * for Ctrl-C handling) LINKS into the native compiler but never CALLS on this path.
 *
 * ctrlc's macOS backend uses ONLY dispatch_semaphore_* (present since 10.6) + a POSIX signal handler
 * (verified in ctrlc's platform/unix source). But the dispatch2 bindings crate compiles its
 * DispatchWorkloop / DispatchQueue code into the same rlib, so the linker drags in these four extern
 * references even though the semaphore-only code path never reaches them. They are HARD undefined
 * imports, so on real 10.9 dyld would abort at LOAD (not call time) unless they are DEFINED --
 * assert_binary_compatible.sh rejects them for exactly this dyld-239 reason.
 *
 *   dispatch_workloop_create            10.14+  ABSENT on 10.9
 *   dispatch_workloop_create_inactive   10.14+  ABSENT on 10.9
 *   dispatch_set_qos_class_floor        10.10+  ABSENT on 10.9
 *   dispatch_queue_create_with_target$V2  the ABI-variant symbol is absent, but 10.9 exports the base
 *                                         _dispatch_queue_create_with_target -> forward to it
 *
 * The three absent ones are defined as abort-if-called stubs: they are never invoked on ctrlc's path,
 * so aborting is safe AND loud if that assumption ever breaks (a future dep that really needs workloops
 * would fail obviously rather than silently misbehave). The $V2 variant forwards to the present base,
 * which is a reasonable create() even if ever reached.
 *
 * Home: mavericks-compat (generically useful to any 10.9 Rust build that links dispatch2). Lives here,
 * compiled into the shim by lib-rust.sh's augment_shim(), until rust consumes mavericks-compat.
 */
#include <stdlib.h>
#include <stdio.h>

static void mav_dispatch_unavailable(const char *name) {
	fprintf(stderr, "mavericks: %s is unavailable on Mac OS X 10.9 and was not expected to be called\n", name);
	abort();
}

void *dispatch_workloop_create(const char *label) {
	(void)label; mav_dispatch_unavailable("dispatch_workloop_create"); return 0;
}
void *dispatch_workloop_create_inactive(const char *label) {
	(void)label; mav_dispatch_unavailable("dispatch_workloop_create_inactive"); return 0;
}
void dispatch_set_qos_class_floor(void *queue, int qos_class, int relative_priority) {
	(void)queue; (void)qos_class; (void)relative_priority;
	mav_dispatch_unavailable("dispatch_set_qos_class_floor");
}

/* Forward the $V2 ABI variant to the base symbol 10.9 does export. The asm label carries the exact
 * Mach-O name (leading underscore + the $V2 suffix) that lld reported undefined. */
extern void *dispatch_queue_create_with_target(const char *label, const void *attr, void *target);
void *mav_dispatch_queue_create_with_target_v2(const char *label, const void *attr, void *target)
	__asm__("_dispatch_queue_create_with_target$V2");
void *mav_dispatch_queue_create_with_target_v2(const char *label, const void *attr, void *target) {
	return dispatch_queue_create_with_target(label, attr, target);
}
