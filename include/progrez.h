#ifndef PROGREZ_H
#define PROGREZ_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct progrez_ctx progrez_ctx;

progrez_ctx *progrez_create(const char *label);
void progrez_destroy(progrez_ctx *ctx);
void progrez_set_identity(progrez_ctx *ctx, const char *caller_name, const char *context_name);
void progrez_set_indeterminate(progrez_ctx *ctx);
void progrez_set_determinate(progrez_ctx *ctx, uint64_t files_total, uint64_t bytes_total);
void progrez_set_guess(progrez_ctx *ctx, uint64_t guess_files, uint64_t guess_bytes);
void progrez_update(progrez_ctx *ctx, uint64_t files_processed, uint64_t bytes_processed);
void progrez_finish(progrez_ctx *ctx);
void progrez_set_interval_ms(progrez_ctx *ctx, uint32_t ms);

#ifdef __cplusplus
}
#endif

#endif /* PROGREZ_H */
