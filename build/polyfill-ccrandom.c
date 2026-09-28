/* CCRandomGenerateBytes for Mac OS X 10.9.
 *
 * Rust's std uses CommonCrypto's CCRandomGenerateBytes as its entropy source on every Apple target
 * (library/std/src/sys/random/apple.rs, reached from std::sys::random::hashmap_random_keys and
 * <std::random::DefaultRandomSource>::fill_bytes). That API arrived in 10.10: 10.9 ships no
 * CommonCrypto/CommonRandom.h and no 10.9 system library exports the symbol, so linking std for
 * x86_64-apple-darwin @ 10.9 fails with
 *
 *   ld64.lld: error: undefined symbol: CCRandomGenerateBytes
 *
 * arc4random_buf IS available on 10.9 -- stdlib.h declares it __OSX_AVAILABLE_STARTING(__MAC_10_7,
 * __IPHONE_4_3) and libsystem_c exports it. Substituting it is faithful rather than weakening:
 * apple.rs's own comment notes that arc4random_buf "calls into the same system service anyway", and
 * both ultimately draw from the kernel CSPRNG. CCRandomGenerateBytes returns CCRNGStatus, where
 * kCCSuccess == 0; arc4random_buf cannot fail, so success is unconditional.
 *
 * This belongs upstream in macports-legacy-support alongside clock_gettime and getentropy. It lives
 * here until it lands there; at that point delete this file and its augment_shim() call, and let the
 * MLS_VERSION pin carry the symbol instead.
 */
#include <stdlib.h>
#include <stddef.h>

int
CCRandomGenerateBytes(void *bytes, size_t count)
{
	arc4random_buf(bytes, count);
	return 0;	/* kCCSuccess */
}
