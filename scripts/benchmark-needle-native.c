#include "ScholiaSearch.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static uint32_t seed = 7291;
static uint32_t next(void) { seed = seed * 1664525u + 1013904223u; return seed; }
static double now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec * 1000.0 + t.tv_nsec / 1e6; }
static int cmp(const void *a, const void *b) { double x = *(const double *)a, y = *(const double *)b; return (x > y) - (x < y); }
static int reference(const uint8_t *s, size_t n, const uint8_t *t, size_t m) {
    if (m > n) return 0;
    for (size_t i = 0; i <= n - m; ++i) if (!memcmp(s + i, t, m)) return 1;
    return 0;
}
static void correctness(void) {
    for (int round = 0; round < 60000; ++round) {
        size_t n = next() % 513, m = next() % 130;
        uint8_t *s = malloc(n ? n : 1), *t = malloc(m ? m : 1);
        for (size_t i = 0; i < n; i++) s[i] = next() % (round % 2 ? 256 : 3);
        for (size_t i = 0; i < m; i++) t[i] = next() % (round % 2 ? 256 : 3);
        if (m && m <= n && round % 3 == 0) memcpy(t, s + next() % (n - m + 1), m);
        assert(scholia_contains(s, n, t, m) == reference(s, n, t, m));
        free(s); free(t);
    }
    // Repetitive near-misses exercise the scalar fallback, including end lanes.
    uint8_t s[4096], t[127]; memset(s, 'a', sizeof s); memset(t, 'a', sizeof t); t[7] = 'b';
    assert(!scholia_contains(s, sizeof s, t, sizeof t));
    memcpy(s + sizeof s - sizeof t, t, sizeof t);
    assert(scholia_contains(s, sizeof s, t, sizeof t));
}
int main(int argc, char **argv) {
    correctness();
    if (argc > 1 && !strcmp(argv[1], "--test")) { puts("PASS: 60000 binary/UTF-8-safe matcher comparisons and repetitive tails"); return 0; }
    enum { PAGES = 9600, SIZE = 2400, ROUNDS = 31 };
    uint8_t *text = malloc((size_t)PAGES * SIZE);
    sqlite3 *db; assert(sqlite3_open(":memory:", &db) == SQLITE_OK);
    assert(scholia_register_search(db) == SQLITE_OK);
    assert(sqlite3_exec(db, "CREATE TABLE p(text TEXT); BEGIN", NULL, NULL, NULL) == SQLITE_OK);
    sqlite3_stmt *insert; sqlite3_prepare_v2(db, "INSERT INTO p VALUES(?)", -1, &insert, NULL);
    for (size_t p = 0; p < PAGES; p++) {
        uint8_t *page = text + p * SIZE;
        for (size_t j = 0; j < SIZE; j++) page[j] = 'a' + next() % 26;
        memcpy(page, "common introduction ", 20);
        if (p % 317 == 0) memcpy(page + 1800, "needlemarker change of basis", 28);
        sqlite3_bind_text(insert, 1, (const char *)page, SIZE, SQLITE_STATIC);
        assert(sqlite3_step(insert) == SQLITE_DONE); sqlite3_reset(insert);
    }
    sqlite3_finalize(insert); sqlite3_exec(db, "COMMIT", NULL, NULL, NULL);
    sqlite3_stmt *sql[2];
    sqlite3_prepare_v2(db, "SELECT count(*) FROM p WHERE instr(text,?)>0", -1, &sql[0], NULL);
    sqlite3_prepare_v2(db, "SELECT count(*) FROM p WHERE needle_contains(text,?)", -1, &sql[1], NULL);
    const char *queries[] = { "common", "ab", "needlemarker", "change of basis", "unfindablequartz" };
    printf("{\"pages\":%d,\"textBytes\":%d,\"rounds\":%d,\"architecture\":\"%s\",\"results\":[", PAGES, PAGES * SIZE, ROUNDS,
#if defined(__aarch64__)
        "arm64-neon"
#else
        "libc"
#endif
    );
    for (size_t q = 0; q < 5; q++) {
        size_t m = strlen(queries[q]); double times[4][ROUNDS]; int expected = -1;
        for (int round = 0; round < ROUNDS; round++) for (int method = 0; method < 4; method++) {
            double start = now(); int count = 0;
            if (method < 2) {
                sqlite3_bind_text(sql[method], 1, queries[q], -1, SQLITE_STATIC);
                assert(sqlite3_step(sql[method]) == SQLITE_ROW); count = sqlite3_column_int(sql[method], 0); sqlite3_reset(sql[method]);
            } else for (size_t p = 0; p < PAGES; p++) {
                const uint8_t *page = text + p * SIZE;
                count += method == 2 ? memmem(page, SIZE, queries[q], m) != NULL : scholia_contains(page, SIZE, (const uint8_t *)queries[q], m);
            }
            times[method][round] = now() - start;
            if (expected == -1) expected = count; else assert(expected == count);
        }
        for (int method = 0; method < 4; method++) qsort(times[method], ROUNDS, sizeof(double), cmp);
        printf("%s{\"query\":\"%s\",\"matches\":%d,\"sqliteInstrP50Ms\":%.4f,\"sqliteNeonP50Ms\":%.4f,\"sqliteNeonP95Ms\":%.4f,\"libcP50Ms\":%.4f,\"directNeonP50Ms\":%.4f}",
            q ? "," : "", queries[q], expected, times[0][15], times[1][15], times[1][29], times[2][15], times[3][15]);
    }
    puts("]}");
    sqlite3_finalize(sql[0]); sqlite3_finalize(sql[1]); sqlite3_close(db); free(text);
}
