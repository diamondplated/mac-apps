#include "MixBarDSP.h"
#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

struct MBRenderState {
    _Atomic uint32_t targetGainBits;
    _Atomic uint32_t currentGainBits;
    _Atomic uint64_t framesRendered;
    _Atomic bool sawSignal;
    /// Touched only by the IO callback after creation.
    float gain;
    float stepPerFrame;
};

static inline uint32_t bits_of(float value) { uint32_t bits; memcpy(&bits, &value, sizeof bits); return bits; }
static inline float float_of(uint32_t bits) { float value; memcpy(&value, &bits, sizeof value); return value; }

static float clamp_gain(float gain) {
    if (!(gain == gain) || gain < 0) return 0;  // NaN or negative
    return gain > MB_MAXIMUM_GAIN ? MB_MAXIMUM_GAIN : gain;
}

MBRenderState *mb_render_state_create(double sampleRate, float initialGain) {
    MBRenderState *state = calloc(1, sizeof *state);
    if (!state) return NULL;
    float start = clamp_gain(initialGain);
    state->gain = start;
    double rate = sampleRate > 0 ? sampleRate : 48000;
    state->stepPerFrame = (float)(1.0 / (MB_RAMP_SECONDS * rate));
    atomic_init(&state->targetGainBits, bits_of(start));
    atomic_init(&state->currentGainBits, bits_of(start));
    atomic_init(&state->framesRendered, 0);
    atomic_init(&state->sawSignal, false);
    return state;
}

void mb_render_state_destroy(MBRenderState *state) { free(state); }

void mb_set_target_gain(MBRenderState *state, float gain) {
    atomic_store_explicit(&state->targetGainBits, bits_of(clamp_gain(gain)), memory_order_relaxed);
}

float mb_target_gain(const MBRenderState *state) {
    return float_of(atomic_load_explicit(&((MBRenderState *)state)->targetGainBits, memory_order_relaxed));
}

float mb_current_gain(const MBRenderState *state) {
    return float_of(atomic_load_explicit(&((MBRenderState *)state)->currentGainBits, memory_order_relaxed));
}

uint64_t mb_frames_rendered(const MBRenderState *state) {
    return atomic_load_explicit(&((MBRenderState *)state)->framesRendered, memory_order_relaxed);
}

bool mb_saw_signal(const MBRenderState *state) {
    return atomic_load_explicit(&((MBRenderState *)state)->sawSignal, memory_order_relaxed);
}

float mb_soft_limit(float sample) {
    if (!(sample == sample)) return 0;
    float magnitude = fabsf(sample);
    if (magnitude <= MB_LIMIT_THRESHOLD) return sample;
    const float headroom = 1.0f - MB_LIMIT_THRESHOLD;
    float limited = MB_LIMIT_THRESHOLD + headroom * tanhf((magnitude - MB_LIMIT_THRESHOLD) / headroom);
    if (limited > 1.0f) limited = 1.0f;
    return sample < 0 ? -limited : limited;
}

/// Where each channel lives: a base pointer and the stride between frames.
typedef struct { float *base[MB_MAXIMUM_CHANNELS]; uint32_t stride[MB_MAXIMUM_CHANNELS]; uint32_t channels; uint32_t frames; } ChannelMap;

static void map_channels(const AudioBufferList *list, ChannelMap *map) {
    map->channels = 0;
    map->frames = UINT32_MAX;
    if (!list) { map->frames = 0; return; }
    for (UInt32 b = 0; b < list->mNumberBuffers; b++) {
        const AudioBuffer *buffer = &list->mBuffers[b];
        if (!buffer->mData || buffer->mNumberChannels == 0) continue;
        uint32_t frames = buffer->mDataByteSize / (uint32_t)(sizeof(float) * buffer->mNumberChannels);
        if (frames < map->frames) map->frames = frames;
        for (UInt32 c = 0; c < buffer->mNumberChannels && map->channels < MB_MAXIMUM_CHANNELS; c++) {
            map->base[map->channels] = (float *)buffer->mData + c;
            map->stride[map->channels] = buffer->mNumberChannels;
            map->channels++;
        }
    }
    if (map->channels == 0) map->frames = 0;
}

void mb_render(MBRenderState *state, const AudioBufferList *input, AudioBufferList *output) {
    // Every output byte starts silent, so frames and channels the input does not cover
    // (short or missing input, extra channels) never replay stale data.
    if (output) {
        for (UInt32 b = 0; b < output->mNumberBuffers; b++) {
            if (output->mBuffers[b].mData) memset(output->mBuffers[b].mData, 0, output->mBuffers[b].mDataByteSize);
        }
    }
    ChannelMap in, out;
    map_channels(input, &in);
    map_channels(output, &out);
    uint32_t frames = in.frames < out.frames ? in.frames : out.frames;
    float target = mb_target_gain(state);
    float gain = state->gain;
    const float step = state->stepPerFrame;
    bool signal = false;
    for (uint32_t frame = 0; frame < frames; frame++) {
        if (gain < target) { gain += step; if (gain > target) gain = target; }
        else if (gain > target) { gain -= step; if (gain < target) gain = target; }
        float folded = 0;
        if (out.channels == 1 && in.channels >= 2) {
            float left = in.base[0][frame * in.stride[0]], right = in.base[1][frame * in.stride[1]];
            signal |= left != 0 || right != 0;
            folded = (left + right) * 0.5f;
        }
        for (uint32_t channel = 0; channel < out.channels; channel++) {
            float sample;
            if (out.channels == 1 && in.channels >= 2) sample = folded;
            else if (channel < in.channels) sample = in.base[channel][frame * in.stride[channel]];
            else if (in.channels == 1) sample = in.base[0][frame * in.stride[0]];
            else sample = 0;
            signal |= sample != 0;
            out.base[channel][frame * out.stride[channel]] = mb_soft_limit(sample * gain);
        }
    }
    // With no output to fill, still notice signal so capture permission is learned.
    if (!signal && frames == 0) {
        for (uint32_t channel = 0; channel < in.channels && !signal; channel++)
            for (uint32_t frame = 0; frame < in.frames && !signal; frame++) signal = in.base[channel][frame * in.stride[channel]] != 0;
    }
    state->gain = gain;
    atomic_store_explicit(&state->currentGainBits, bits_of(gain), memory_order_relaxed);
    uint32_t progressed = out.frames ? out.frames : in.frames;
    atomic_fetch_add_explicit(&state->framesRendered, progressed, memory_order_relaxed);
    if (signal) atomic_store_explicit(&state->sawSignal, true, memory_order_relaxed);
}
