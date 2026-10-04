// The C surface of adblock/src/lib.rs. Strings returned are owned by the
// caller and released with mizu_string_free; byte buffers with mizu_bytes_free.
#ifndef MIZU_ADBLOCK_H
#define MIZU_ADBLOCK_H

#include <stddef.h>
#include <stdint.h>

typedef struct MizuEngine MizuEngine;

char *mizu_content_rules(const uint8_t *filters, size_t len, size_t chunk);

MizuEngine *mizu_engine_new(const uint8_t *filters, size_t len);
MizuEngine *mizu_engine_load(const uint8_t *data, size_t len);
uint8_t *mizu_engine_serialize(const MizuEngine *engine, size_t *len);
size_t mizu_engine_use_resources(MizuEngine *engine, const uint8_t *json, size_t len);
char *mizu_engine_cosmetics(const MizuEngine *engine, const char *url);
char *mizu_engine_hidden_selectors(const MizuEngine *engine, const char *seen);
void mizu_engine_free(MizuEngine *engine);

void mizu_string_free(char *s);
void mizu_bytes_free(uint8_t *data, size_t len);

#endif
