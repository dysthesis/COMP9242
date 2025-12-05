// Minimal interface to inspect the static SOS heap (morecore area).
// This header intentionally mirrors the definitions in morecore.c so both
// C and Zig code can query remaining heap for diagnostics and guardrails.
#pragma once

#include <stddef.h>

// Total size in bytes of the statically allocated heap arena.
size_t morecore_total_bytes(void);

// Free bytes currently available in the morecore arena.
size_t morecore_free_bytes(void);
