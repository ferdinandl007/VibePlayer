#pragma once
#include <stddef.h>
#include <stdint.h>

typedef struct yu_engine yu_engine;
typedef struct yu_result yu_result;

enum { YU_PREVIEW_WINDOW_FRAMES = 100, YU_PREVIEW_OVERLAP_FRAMES = 16 };

yu_engine *yu_open(const char *library, const char *weights, const char *spec, int preview);
void yu_close(yu_engine *engine);
const char *yu_error(void);

yu_result *yu_render(yu_engine *engine, const char *lyrics, const char *style,
                     uint64_t seed, int frames, int steps, int minimum_frames, const char *prefix);
const float *yu_samples(const yu_result *result);
size_t yu_frames(const yu_result *result);
int yu_channels(const yu_result *result);
int yu_sample_rate(const yu_result *result);
const uint8_t *yu_tokens(const yu_result *result, size_t *size);
void yu_result_close(yu_result *result);
