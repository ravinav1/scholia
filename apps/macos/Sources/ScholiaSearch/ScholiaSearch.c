#include "ScholiaSearch.h"
#include <string.h>
#if defined(__aarch64__) && defined(__ARM_NEON)
#include <arm_neon.h>
#endif

int scholia_contains(const uint8_t *text, size_t length, const uint8_t *term, size_t term_length) {
    if (!term_length) return 1;
    if (term_length > length) return 0;
    if (term_length == 1) return memchr(text, term[0], length) != NULL;
#if defined(__aarch64__) && defined(__ARM_NEON)
    // Apple Silicon's baseline 128-bit NEON checks 16 possible starting
    // positions together. Pick a differing interior byte to reject repetitive
    // prefixes; verify surviving lanes exactly. No alignment/padding required.
    size_t pivot = term_length / 2;
    while (pivot + 1 < term_length && term[pivot] == term[0]) pivot++;
    const uint8x16_t first = vdupq_n_u8(term[0]);
    const uint8x16_t middle = vdupq_n_u8(term[pivot]);
    const uint8x16_t last = vdupq_n_u8(term[term_length - 1]);
    const size_t end = length - term_length;
    size_t offset = 0, false_positives = 0;
    while (end - offset >= 15) {
        uint8x16_t match = vandq_u8(vceqq_u8(vld1q_u8(text + offset), first),
                                 vceqq_u8(vld1q_u8(text + offset + pivot), middle));
        match = vandq_u8(match, vceqq_u8(vld1q_u8(text + offset + term_length - 1), last));
        if (vmaxvq_u8(match)) {
            uint8_t lanes[16];
            vst1q_u8(lanes, match);
            for (size_t lane = 0; lane < 16; lane++) if (lanes[lane]) {
                if (!memcmp(text + offset + lane, term, term_length)) return 1;
                if (++false_positives == 64)
                    return memmem(text + offset + lane + 1, length - offset - lane - 1, term, term_length) != NULL;
            }
        }
        offset += 16;
        if (offset > end) return 0;
    }
    return memmem(text + offset, length - offset, term, term_length) != NULL;
#else
    return memmem(text, length, term, term_length) != NULL;
#endif
}

static void contains_sql(sqlite3_context *context, int argc, sqlite3_value **argv) {
    (void)argc;
    const uint8_t *text = sqlite3_value_text(argv[0]), *term = sqlite3_value_text(argv[1]);
    if (!text || !term) { sqlite3_result_int(context, 0); return; }
    sqlite3_result_int(context, scholia_contains(text, (size_t)sqlite3_value_bytes(argv[0]),
                                               term, (size_t)sqlite3_value_bytes(argv[1])));
}

int scholia_register_search(sqlite3 *db) {
    return sqlite3_create_function_v2(db, "needle_contains", 2,
        SQLITE_UTF8 | SQLITE_DETERMINISTIC | SQLITE_INNOCUOUS, NULL, contains_sql, NULL, NULL, NULL);
}
