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
typedef int (*yu_pcm_callback)(void *context, const float *samples, size_t frames,
                               int sample_rate, int channels, size_t offset, size_t total);
int yu_supports_pcm(const yu_engine *engine);
yu_result *yu_render_observing_pcm(yu_engine *engine, const char *lyrics, const char *style,
                                   uint64_t seed, int frames, int steps, int minimum_frames,
                                   const char *prefix, yu_pcm_callback callback, void *context);
const float *yu_samples(const yu_result *result);
size_t yu_frames(const yu_result *result);
int yu_channels(const yu_result *result);
int yu_sample_rate(const yu_result *result);
const uint8_t *yu_tokens(const yu_result *result, size_t *size);
void yu_result_close(yu_result *result);
