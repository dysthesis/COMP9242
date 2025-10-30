#pragma once

/*
 * Initialise the continuation pool allocator.
 * Must be called during bootstrap, before any syscall processing begins.
 */
void continuation_bootstrap(void);
