/* progrez demo — exercises the C FFI. */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#include <windows.h>
#define SLEEP_MS(ms) Sleep(ms)
#else
#include <unistd.h>
#define SLEEP_MS(ms) usleep((ms) * 1000)
#endif

#include "progrez.h"

int main(void) {
    /* Phase 1: Indeterminate (scanning) */
    progrez_ctx *ctx = progrez_create("Scanning");
    if (!ctx) {
        fprintf(stderr, "Failed to create progress context\n");
        return 1;
    }
    progrez_set_identity(ctx, "progrez-demo", "demo directory scan");
    progrez_set_indeterminate(ctx);

    for (uint64_t i = 0; i < 50; i++) {
        progrez_update(ctx, i + 1, (i + 1) * 1024);
        SLEEP_MS(50);
    }

    /* Phase 2: Determinate (processing) */
    progrez_set_determinate(ctx, 50, 50 * 1024);

    for (uint64_t i = 0; i < 50; i++) {
        progrez_update(ctx, i + 1, (i + 1) * 1024);
        SLEEP_MS(100);
    }

    progrez_finish(ctx);
    progrez_destroy(ctx);

    return 0;
}
