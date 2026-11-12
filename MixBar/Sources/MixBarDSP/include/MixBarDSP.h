#ifndef MIXBAR_DSP_H
#define MIXBAR_DSP_H

#include <CoreAudio/CoreAudioTypes.h>
#include <stdbool.h>
#include <stdint.h>

/// State shared between the main thread and one tap's IO callback. The main thread
/// writes the target gain; the callback ramps towards it and reports progress. Every
/// shared field is a lock-free atomic, and the callback never allocates.
typedef struct MBRenderState MBRenderState;

/// The longest a gain change takes to complete, in seconds, so a slider drag does not click.
#define MB_RAMP_SECONDS 0.02
/// Below this magnitude samples pass unchanged; above it the soft limiter bends them
/// towards full scale, which they never reach.
#define MB_LIMIT_THRESHOLD 0.9f
#define MB_MAXIMUM_GAIN 2.0f
#define MB_MAXIMUM_CHANNELS 64

/// Starts at `initialGain` so a new tap begins exactly where the untapped app was (100 percent)
/// and ramps to its target. Returns NULL only when memory is exhausted.
MBRenderState *_Nullable mb_render_state_create(double sampleRate, float initialGain);
void mb_render_state_destroy(MBRenderState *_Nullable state);

/// Main thread. Clamped to 0...MB_MAXIMUM_GAIN; NaN becomes 0.
void mb_set_target_gain(MBRenderState *_Nonnull state, float gain);
float mb_target_gain(const MBRenderState *_Nonnull state);
/// The gain the callback reached at the end of its last cycle.
float mb_current_gain(const MBRenderState *_Nonnull state);
/// Frames rendered since creation; a counter that stops moving means the IO stalled.
uint64_t mb_frames_rendered(const MBRenderState *_Nonnull state);
/// True once any non-zero input sample arrived: audio capture is allowed.
bool mb_saw_signal(const MBRenderState *_Nonnull state);

/// The soft limiter: identity up to the threshold, then a tanh knee that approaches
/// but never exceeds 1.0 in magnitude.
float mb_soft_limit(float sample);

/// The IO callback body. Reads 32-bit float input (the tap's stereo mixdown; buffers
/// whose mData is NULL are skipped), applies the ramped gain and the limiter, and
/// writes 32-bit float output. Output channels beyond the input's are silent, except
/// that mono input feeds every output channel and stereo input folds to a mono output.
/// Frames the input does not cover are left as the HAL provided them (zeroed).
void mb_render(MBRenderState *_Nonnull state, const AudioBufferList *_Nullable input, AudioBufferList *_Nullable output);

#endif
