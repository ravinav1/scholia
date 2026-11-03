#ifndef SCHOLIA_SEARCH_H
#define SCHOLIA_SEARCH_H
#include <stddef.h>
#include <stdint.h>
#include <sqlite3.h>
// Length-delimited UTF-8, already normalized by the caller. No locale changes,
// allocations, or reads outside the supplied buffers.
int scholia_contains(const uint8_t *text, size_t length, const uint8_t *term, size_t term_length);
int scholia_register_search(sqlite3 *db);
#endif
