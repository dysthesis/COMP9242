#pragma once

#include <stdint.h>

// Forward declarations
struct client;

/*
 * Initialise the continuation pool allocator.
 * Must be called during SOS bootstrap, before any syscall processing begins.
 */
void continuation_bootstrap(void);

/*
 * Resume all continuations waiting on I/O readiness for a file descriptor.
 *
 * This should be called from interrupt handlers or event loops when data
 * becomes available on a file descriptor. All blocked read/write operations
 * on the specified FD will be resumed.
 */
void continuation_resume_io(int fd);

/*
 * Resume a continuation waiting on a specific timer.
 *
 * This should be called from timer interrupt handlers when a registered
 * timer expires. The continuation associated with the timer_id will be
 * resumed and removed from the wait queue.
 */
void continuation_resume_timer(uint32_t timer_id);

/*
 * Cancel all continuations belonging to a specific client.
 *
 * This should be called when a client process terminates or crashes to
 * clean up any pending asynchronous operations. All continuations for
 * the client will be removed from wait queues and their resources freed
 * without sending replies.
 */
void continuation_cancel_client(struct client *client);
