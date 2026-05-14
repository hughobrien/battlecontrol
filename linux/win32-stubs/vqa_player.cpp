// TIM-441: Minimal VQA cinematic player for the native Linux / SDL2 build.
//
// Replaces the Play_Movie_GlyphX → EventCallback==NULL early-return path.
// Reads VQA files via CCFileClass (MIX-aware), decodes with the in-tree
// LCW decompressor, renders into the game's primary SDL surface, and plays
// raw-PCM audio via SDL2.
//
// Format reference: Westwood VQA version 2 (C&C: Red Alert intro files).
// LCW decompression: LCW.CPP (Format80 variant).
// Palette convention: CPL0 stores 6-bit VGA DAC values; Set_DD_Palette_8bit applies
// `<<2` plus bottom-bit replication (matches ffmpeg vqavideo.c).  TIM-523's "8-bit
// direct" reading was wrong (TIM-580): values 4-31 were rendered nearly-black,
// leaving codebook-driven backgrounds invisible and only gold-text indices visible.
//
// Include pattern: function.h first (same as REDALERT/*.cpp), then SDL2.

#ifndef _MSC_VER

#include "function.h"

#include <SDL2/SDL.h>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <algorithm>
#include <vector>

#include "vqa_player.h"
#include "sdl_audio.h"

#ifdef __EMSCRIPTEN__
// TIM-517: proxy VQA SDL audio calls to the main browser thread (same as AUDIO.CPP/TIM-428).
#include <emscripten.h>
#include <emscripten/threading.h>
#include <emscripten/proxying.h>
#endif

// -------------------------------------------------------------------------
// TIM-587: per-frame decoder trace (RA_VQA_TRACE=1 enables).
// Used to diagnose block-aligned palette/codebook artifacts.
// -------------------------------------------------------------------------

static bool vqa_trace_enabled()
{
    static int cached = -1;
    if (cached < 0) {
        const char* e = std::getenv("RA_VQA_TRACE");
        cached = (e && *e && *e != '0') ? 1 : 0;
    }
    return cached != 0;
}

// FNV-1a 32-bit hash of a byte range — used to print compact codebook snapshots.
static uint32_t vqa_fnv1a(const uint8_t* p, size_t n)
{
    uint32_t h = 0x811c9dc5u;
    for (size_t i = 0; i < n; ++i) { h ^= p[i]; h *= 0x01000193u; }
    return h;
}

// -------------------------------------------------------------------------
// Chunk-ID helpers (IFF: 4 ASCII bytes, sizes big-endian)
// -------------------------------------------------------------------------

static bool chunk_eq(const uint8_t* id, const char* tag)
{
    return id[0]==tag[0] && id[1]==tag[1] && id[2]==tag[2] && id[3]==tag[3];
}

static uint32_t be32(const uint8_t* p)
{
    return ((uint32_t)p[0]<<24)|((uint32_t)p[1]<<16)|
           ((uint32_t)p[2]<< 8)|(uint32_t)p[3];
}

// -------------------------------------------------------------------------
// VQAHeader (VQHD body, 36 bytes, all little-endian)
//
// VQA v2 layout from Westwood documentation:
//   offset  size  field
//    0       2    version
//    2       2    flags   (bit 0 = audio present)
//    4       2    numFrames
//    6       2    width
//    8       2    height
//   10       1    blockW
//   11       1    blockH
//   12       1    fps
//   13       1    cbParts
//   14       2    numColors
//   16       2    maxBlocks
//   18       2    unknown1
//   20       2    unknown2
//   22       2    freq     (audio sample rate)
//   24       1    channels (1=mono, 2=stereo)
//   25       1    bits     (bits per sample)
//   26       4    unknown3
//   30       2    maxCBFZSize
//   32       4    unknown4
//  = 36 bytes total
// -------------------------------------------------------------------------
#pragma pack(push,1)
struct VQAHeader {
    uint16_t version;
    uint16_t flags;
    uint16_t numFrames;
    uint16_t width;
    uint16_t height;
    uint8_t  blockW;
    uint8_t  blockH;
    uint8_t  fps;
    uint8_t  cbParts;
    uint16_t numColors;
    uint16_t maxBlocks;
    uint16_t unknown1;
    uint16_t unknown2;
    uint16_t unknown3;  // offset 22: not freq — empirically 0x55D3 in ENGLISH.VQA
    uint16_t freq;      // offset 24: LE uint16 = 22050 in ENGLISH.VQA
    uint8_t  channels;  // offset 26: 1=mono, 2=stereo
    uint8_t  bits;      // offset 27: bits per sample (16)
    uint32_t unknown4;  // offset 28
    uint16_t maxCBFZSize; // offset 32
    uint16_t unknown5;  // offset 34
};  // 36 bytes with pack(1)
#pragma pack(pop)

// -------------------------------------------------------------------------
// Bounds-checked LCW (Format80) decompressor for VQA use.
// LCW_Uncomp from LCW.CPP has no destination bounds checking: a single
// 0xFE "long run" command writes up to 65535 bytes, so even a short
// compressed stream can produce megabytes if the data is malformed or
// we are reading from the wrong file position.  This local implementation
// stops writing when dst_end is reached, preventing heap corruption.
// -------------------------------------------------------------------------
static size_t lcw_decode_safe(const uint8_t* src, size_t src_len,
                               uint8_t* dst, size_t dst_cap)
{
    const uint8_t* src_end = src + src_len;
    uint8_t* dp = dst;
    uint8_t* dst_end = dst + dst_cap;

    while (src < src_end && dp < dst_end) {
        uint8_t op = *src++;

        if (op == 0x80) {
            // End of stream
            break;
        } else if (!(op & 0x80)) {
            // Short copy from dest: count = hi-nybble+3, offset = lo-nybble<<8 | next
            if (src >= src_end) break;
            unsigned count  = (op >> 4) + 3;
            unsigned offset = (unsigned)(op & 0x0f) << 8 | *src++;
            const uint8_t* cp = dp - offset;
            if (cp < dst) cp = dst;  // clamp to valid history
            while (count-- && dp < dst_end) *dp++ = *cp++;
        } else if (!(op & 0x40)) {
            // Medium copy from source: next op & 0x3f bytes literal
            unsigned count = op & 0x3f;
            while (count-- && src < src_end && dp < dst_end) *dp++ = *src++;
        } else if (op == 0xfe) {
            // Long run: 2-byte LE count, 1-byte fill
            if (src + 2 >= src_end) break;
            unsigned count = (unsigned)src[0] | ((unsigned)src[1] << 8);
            uint8_t  fill  = src[2];
            src += 3;
            while (count-- && dp < dst_end) *dp++ = fill;
        } else if (op == 0xff) {
            // Long copy from dest: 2-byte LE count, 2-byte LE absolute offset
            if (src + 3 >= src_end) break;
            unsigned count  = (unsigned)src[0] | ((unsigned)src[1] << 8);
            unsigned offset = (unsigned)src[2] | ((unsigned)src[3] << 8);
            src += 4;
            const uint8_t* cp = dst + offset;
            while (count-- && dp < dst_end) {
                *dp++ = (cp < dst_end) ? *cp++ : 0;
            }
        } else {
            // Medium copy from dest: count = (op & 0x3f)+3, 2-byte LE absolute offset
            if (src + 1 >= src_end) break;
            unsigned count  = (op & 0x3f) + 3;
            unsigned offset = (unsigned)src[0] | ((unsigned)src[1] << 8);
            src += 2;
            const uint8_t* cp = dst + offset;
            while (count-- && dp < dst_end) {
                *dp++ = (cp < dst_end) ? *cp++ : 0;
            }
        }
    }
    return (size_t)(dp - dst);
}

static std::vector<uint8_t> lcw_decompress(const uint8_t* src, size_t src_len,
                                            size_t dst_hint)
{
    // Allocate a destination sized to dst_hint + safety margin.
    // The safe decoder above stops when dst_cap is reached, so no overflow.
    size_t alloc = std::max(src_len * 4 + 4096, dst_hint) + 65536;
    std::vector<uint8_t> dst(alloc, 0);
    size_t out = lcw_decode_safe(src, src_len, dst.data(), alloc);
    if (out > 0) dst.resize(out);
    else         dst.clear();
    return dst;
}

// -------------------------------------------------------------------------
// Westwood SND1 ADPCM decoder (4-bit nibbles, 8-bit predictor)
// -------------------------------------------------------------------------
static const int8_t snd1_delta[16] = {
    -9, -8, -6, -5, -4, -3, -2, -1, 0, 1, 2, 3, 4, 5, 6, 8
};

static std::vector<int16_t> decode_snd1(const uint8_t* src, size_t src_len)
{
    if (src_len < 2) return {};
    std::vector<int16_t> out;
    out.reserve(src_len * 2);
    int predictor = 0x80;
    for (size_t i = 2; i < src_len; ++i) {
        uint8_t b = src[i];
        for (int shift : {0, 4}) {
            int nibble = (b >> shift) & 0xF;
            predictor += snd1_delta[nibble];
            predictor = std::max(0, std::min(255, predictor));
            out.push_back((int16_t)((predictor - 128) * 256));
        }
    }
    return out;
}

// -------------------------------------------------------------------------
// Westwood SND2 IMA ADPCM decoder (standard Intel/DVI IMA ADPCM)
//
// Red Alert VQA files use SND2 for all audio.  Each SND2 chunk is raw
// 4-bit nibble data with NO per-chunk header — the predictor and step
// index persist across chunks for the lifetime of the movie (reset to
// 0/0 at the start of each Play_Movie_Linux call).
//
// Nibble order: low nibble first, then high nibble (VQA v2 format).
// Formula: diff = ((2*(nibble&7)+1)*step) >> 3  (ffmpeg adpcm_ima_ws)
// -------------------------------------------------------------------------
static const int ima_step_table[89] = {
    7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31, 34,
    37, 41, 45, 50, 55, 60, 66, 73, 80, 88, 97, 107, 118, 130, 143,
    157, 173, 190, 209, 230, 253, 279, 307, 337, 371, 408, 449, 494,
    544, 598, 658, 724, 796, 876, 963, 1060, 1166, 1282, 1411, 1552,
    1707, 1878, 2066, 2272, 2499, 2749, 3024, 3327, 3660, 4026, 4428,
    4871, 5358, 5894, 6484, 7132, 7845, 8630, 9493, 10442, 11487,
    12635, 13899, 15289, 16818, 18500, 20350, 22385, 24623, 27086,
    29794, 32767
};

static const int8_t ima_index_table[16] = {
    -1, -1, -1, -1, 2, 4, 6, 8,
    -1, -1, -1, -1, 2, 4, 6, 8
};

struct ImaState {
    int32_t predictor  = 0;
    int32_t step_index = 0;
};

static int16_t ima_decode_nibble(ImaState& st, int nibble)
{
    int step  = ima_step_table[st.step_index];
    int diff  = ((2 * (nibble & 7) + 1) * step) >> 3;
    if (nibble & 8) st.predictor -= diff;
    else            st.predictor += diff;
    st.predictor   = std::max(-32768, std::min(32767, (int)st.predictor));
    st.step_index  = std::max(0, std::min(88, (int)(st.step_index + ima_index_table[nibble])));
    return (int16_t)st.predictor;
}

static std::vector<int16_t> decode_snd2(const uint8_t* src, size_t src_len, ImaState& st)
{
    std::vector<int16_t> out;
    out.reserve(src_len * 2);
    for (size_t i = 0; i < src_len; ++i) {
        out.push_back(ima_decode_nibble(st, src[i] & 0x0F));  // low nibble first
        out.push_back(ima_decode_nibble(st, src[i] >> 4));    // then high nibble
    }
    return out;
}

// -------------------------------------------------------------------------
// SDL2 audio queue (dedicated device, non-callback / SDL_QueueAudio)
//
// In WASM/browser only one SDL audio device may be open at a time.
// If the game audio device is already open we close it before opening the
// VQA device, then reopen it when playback ends.
// -------------------------------------------------------------------------
static SDL_AudioDeviceID vqa_audio_dev = 0;

// Saved game-audio params for reopening after VQA finishes.
static bool vqa_stole_game_audio   = false;
static int  vqa_saved_rate         = 22050;
static int  vqa_saved_channels     = 1;
static int  vqa_saved_bits         = 16;

// TIM-602: resampler state.  WASM opens the audio device at the browser's
// native rate (e.g. 44100 Hz) while VQA source PCM is 22050 Hz; without
// resampling SDL_QueueAudio plays the source at 2× speed / one octave high.
// TIM-555's TD callback mixer solves this with stride = src_rate / dst_rate;
// VQA uses the push model (SDL_QueueAudio) so we resample at the queue
// boundary instead.  Set in vqa_audio_open from the source freq and have.freq.
static int    vqa_source_rate     = 22050;
static int    vqa_have_rate       = 22050;
static int    vqa_have_channels   = 1;
static double vqa_resample_cursor = 0.0;  // fractional source-frame position; persists across SND chunks

// TIM-517: proxy VQA audio device open/close to the main browser thread,
// mirroring the AUDIO.CPP trampoline pattern (TIM-428).
// SDL_OpenAudioDevice / SDL_CloseAudioDevice / SDL_InitSubSystem(SDL_INIT_AUDIO)
// must run on the Emscripten main runtime thread; calling them from a Web Worker
// crashes with an uncaught TypeError on AudioContext.sampleRate (TIM-513).
#ifdef __EMSCRIPTEN__
struct VqaAudioOpenArgs {
    int freq;
    int channels;
    bool result;
};

static void vqa_audio_open_on_main(void* arg)
{
    auto* a = static_cast<VqaAudioOpenArgs*>(arg);
    vqa_stole_game_audio = SDL_Audio_Is_Open();
    if (vqa_stole_game_audio) {
        SDL_Audio_Get_Params(&vqa_saved_rate, &vqa_saved_channels, &vqa_saved_bits);
        SDL_Audio_Close();
    }
    SDL_InitSubSystem(SDL_INIT_AUDIO);
    // TIM-602: capture the source rate (from the VQA header) before we override
    // a->freq with the native browser rate.  Used to drive the queue-time
    // resampler so 22050 Hz source PCM doesn't play 2× fast on a 44100 Hz device.
    int source_rate = a->freq;
    // TIM-583: query browser native AudioContext.sampleRate before SDL_OpenAudioDevice.
    // Old Emscripten SDL2 sets have.freq = want.freq even when the browser AudioContext
    // runs at its native rate; if sampleRate is 0 at open time, the resampling ratio
    // divide-by-zero traps the WASM worker.  Same fix as TIM-555/TIBERIANDAWN/AUDIO.CPP.
    {
        int native = EM_ASM_INT({
            var Ctx = window.AudioContext || window.webkitAudioContext;
            if (!Ctx) return $0;
            try {
                var c = new Ctx();
                var r = c.sampleRate | 0;
                c.close();
                return r;
            } catch(e) { return $0; }
        }, a->freq);
        if (native > 0) a->freq = native;
    }
    fprintf(stderr, "[VQA] WASM audio: opening at %d Hz (browser native rate, source=%d Hz)\n",
            a->freq, source_rate);
    fflush(stderr);
    SDL_AudioSpec want = {}, have = {};
    want.freq     = a->freq;
    want.format   = AUDIO_S16LSB;
    want.channels = (uint8_t)a->channels;
    want.samples  = 1024;
    // TIM-593: do NOT pass SDL_AUDIO_ALLOW_FREQUENCY_CHANGE here.
    // That flag permits SDL to set a different frequency and activate its internal
    // resampler, which registers a function pointer into the WASM indirect-call table.
    // In emcc 5.0.6 (emsdk release) that slot is absent/null, causing a
    // "null function" WASM trap downstream of SDL_OpenAudioDevice.  Since we already
    // queried the browser native AudioContext.sampleRate and pass it as want.freq,
    // SDL does not need to resample — opening at exactly want.freq is correct.
    // If SDL cannot open at this exact rate the call fails gracefully (return 0)
    // and VQA plays silently rather than crashing.
    vqa_audio_dev = SDL_OpenAudioDevice(nullptr, 0, &want, &have, 0);
    if (!vqa_audio_dev) {
        fprintf(stderr, "[VQA] SDL audio open failed: %s\n", SDL_GetError());
        SDL_QuitSubSystem(SDL_INIT_AUDIO);
        if (vqa_stole_game_audio) {
            SDL_Audio_Open(vqa_saved_rate, vqa_saved_channels, vqa_saved_bits);
            vqa_stole_game_audio = false;
        }
        a->result = false;
        return;
    }
    // TIM-602: prime the queue-time resampler.
    vqa_source_rate     = source_rate > 0 ? source_rate : a->freq;
    vqa_have_rate       = have.freq > 0 ? have.freq : a->freq;
    vqa_have_channels   = have.channels > 0 ? have.channels : a->channels;
    vqa_resample_cursor = 0.0;
    fprintf(stderr, "[VQA] resampler: source=%d Hz device=%d Hz channels=%d\n",
            vqa_source_rate, vqa_have_rate, vqa_have_channels);
    fflush(stderr);
    SDL_PauseAudioDevice(vqa_audio_dev, 0);
    a->result = true;
}

static void vqa_audio_close_on_main(void* /*arg*/)
{
    if (vqa_audio_dev) {
        SDL_CloseAudioDevice(vqa_audio_dev);
        vqa_audio_dev = 0;
    }
    SDL_QuitSubSystem(SDL_INIT_AUDIO);
    if (vqa_stole_game_audio) {
        SDL_Audio_Open(vqa_saved_rate, vqa_saved_channels, vqa_saved_bits);
        vqa_stole_game_audio = false;
    }
}

static bool vqa_audio_open(int freq, int channels)
{
    if (channels < 1 || channels > 2) channels = 1;
    if (freq < 8000 || freq > 48000) freq = 22050;
    VqaAudioOpenArgs args = { freq, channels, false };
    emscripten_proxy_sync(
        emscripten_proxy_get_system_queue(),
        emscripten_main_runtime_thread_id(),
        vqa_audio_open_on_main, &args);
    return args.result;
}

static void vqa_audio_close()
{
    emscripten_proxy_sync(
        emscripten_proxy_get_system_queue(),
        emscripten_main_runtime_thread_id(),
        vqa_audio_close_on_main, nullptr);
}
#else
static bool vqa_audio_open(int freq, int channels)
{
    // Clamp to safe values before passing to SDL2
    if (channels < 1 || channels > 2) channels = 1;
    if (freq < 8000 || freq > 48000) freq = 22050;

    // If game audio is already open, close it so SDL can open the VQA device.
    // SDL_Audio_Close() calls SDL_QuitSubSystem(SDL_INIT_AUDIO), deiniting the
    // audio subsystem entirely.  We re-init it unconditionally before calling
    // SDL_OpenAudioDevice — this also covers the case where game audio hasn't
    // been opened yet (e.g. ENGLISH.VQA at Play_Intro time). (TIM-496)
    vqa_stole_game_audio = SDL_Audio_Is_Open();
    if (vqa_stole_game_audio) {
        SDL_Audio_Get_Params(&vqa_saved_rate, &vqa_saved_channels, &vqa_saved_bits);
        SDL_Audio_Close();
    }
    SDL_InitSubSystem(SDL_INIT_AUDIO);

    SDL_AudioSpec want = {}, have = {};
    want.freq     = freq;
    want.format   = AUDIO_S16LSB;
    want.channels = (uint8_t)channels;
    want.samples  = 1024;
    vqa_audio_dev = SDL_OpenAudioDevice(nullptr, 0, &want, &have,
                                         SDL_AUDIO_ALLOW_FREQUENCY_CHANGE);
    if (!vqa_audio_dev) {
        fprintf(stderr, "[VQA] SDL audio open failed: %s\n", SDL_GetError());
        // Restore audio state on failure.
        SDL_QuitSubSystem(SDL_INIT_AUDIO);
        if (vqa_stole_game_audio) {
            SDL_Audio_Open(vqa_saved_rate, vqa_saved_channels, vqa_saved_bits);
            vqa_stole_game_audio = false;
        }
        return false;
    }
    // TIM-602: prime the queue-time resampler from the actual device rate.
    vqa_source_rate     = freq > 0 ? freq : 22050;
    vqa_have_rate       = have.freq > 0 ? have.freq : freq;
    vqa_have_channels   = have.channels > 0 ? have.channels : channels;
    vqa_resample_cursor = 0.0;
    SDL_PauseAudioDevice(vqa_audio_dev, 0);
    return true;
}

static void vqa_audio_close()
{
    if (vqa_audio_dev) {
        SDL_CloseAudioDevice(vqa_audio_dev);
        vqa_audio_dev = 0;
    }
    // Balance the SDL_InitSubSystem(SDL_INIT_AUDIO) from vqa_audio_open, then
    // let SDL_Audio_Open re-init the subsystem through its own Init call.
    SDL_QuitSubSystem(SDL_INIT_AUDIO);
    if (vqa_stole_game_audio) {
        SDL_Audio_Open(vqa_saved_rate, vqa_saved_channels, vqa_saved_bits);
        vqa_stole_game_audio = false;
    }
}

#endif // __EMSCRIPTEN__

// TIM-586: SDL_PollEvent on the worker thread does not surface canvas key/
// mouse events under PROXY_TO_PTHREAD (the browser delivers them to the main
// thread's JS handlers but they never reach the worker's SDL event queue,
// so the user_abort path in the frame loop never trips).  Bypass SDL for
// VQA skip detection by installing JS-side canvas listeners that flip a
// global flag; the worker polls the flag once per frame.
//
// MAIN_THREAD_EM_ASM is required because EM_ASM/EM_JS bind to the calling
// thread, and the worker thread cannot reach `document`/`window`.
#ifdef __EMSCRIPTEN__
static void vqa_install_abort_listeners()
{
    MAIN_THREAD_EM_ASM({
        if (window._vqa_abort_installed) {
            window._vqa_aborted = false;
            return;
        }
        window._vqa_abort_installed = true;
        window._vqa_aborted = false;
        var fire = function() { window._vqa_aborted = true; };
        var canvas = document.getElementById('canvas');
        if (canvas) {
            canvas.addEventListener('mousedown', fire);
            canvas.addEventListener('touchstart', fire, { passive: true });
        }
        // Keydown on document — focus may not be on canvas yet (TIM-582 only
        // focuses on first mousedown), but document captures all key events.
        document.addEventListener('keydown', fire);
    });
}

static bool vqa_check_abort_flag()
{
    return MAIN_THREAD_EM_ASM_INT({
        return window._vqa_aborted ? 1 : 0;
    }) != 0;
}

static void vqa_clear_abort_flag()
{
    MAIN_THREAD_EM_ASM({
        window._vqa_aborted = false;
    });
}
#endif // __EMSCRIPTEN__

// TIM-602: nearest-neighbour stride resample from source rate to device rate.
// Mirrors TIBERIANDAWN/AUDIO.CPP::td_sound_callback (TIM-555).  The cursor is
// kept in source frames and persists across SND chunks so the predictor-continuous
// ADPCM stream stays phase-coherent across chunk boundaries.
//
// `count` is the total number of int16 samples in `pcm` (= frames * channels).
// For 22050 Hz source on a 44100 Hz device, stride = 0.5 and the cursor advances
// half a source frame per output frame, duplicating each source frame — i.e. a
// pitch-correct 2× upsample.
static void vqa_audio_queue_s16(const int16_t* pcm, size_t count)
{
    if (!vqa_audio_dev || !pcm || !count) return;

    // Identity passthrough when rates match (or are unknown).
    if (vqa_have_rate <= 0 || vqa_source_rate <= 0 ||
        vqa_source_rate == vqa_have_rate) {
        SDL_QueueAudio(vqa_audio_dev, pcm, (uint32_t)(count * sizeof(int16_t)));
        return;
    }

    int ch = vqa_have_channels > 0 ? vqa_have_channels : 1;
    if ((size_t)ch > count) {
        // Pathologically short chunk — nothing to resample.
        return;
    }
    size_t in_frames = count / (size_t)ch;
    if (!in_frames) return;

    double stride = (double)vqa_source_rate / (double)vqa_have_rate;

    // Upper bound on output frames: (in_frames - cursor) / stride + 1.
    double remaining = (double)in_frames - vqa_resample_cursor;
    if (remaining <= 0.0) {
        // Cursor sits past end of this chunk (carry-over from previous call).
        vqa_resample_cursor -= (double)in_frames;
        if (vqa_resample_cursor < 0.0) vqa_resample_cursor = 0.0;
        return;
    }
    size_t out_frames_cap = (size_t)(remaining / stride) + 2;
    std::vector<int16_t> out;
    out.reserve(out_frames_cap * (size_t)ch);

    double c = vqa_resample_cursor;
    while (c < (double)in_frames) {
        size_t idx = (size_t)c;
        if (idx >= in_frames) break;
        const int16_t* src = pcm + idx * (size_t)ch;
        for (int k = 0; k < ch; ++k) out.push_back(src[k]);
        c += stride;
    }
    // Carry residual cursor into next chunk (relative to its frame 0).
    vqa_resample_cursor = c - (double)in_frames;
    if (vqa_resample_cursor < 0.0) vqa_resample_cursor = 0.0;

    if (!out.empty())
        SDL_QueueAudio(vqa_audio_dev, out.data(),
                       (uint32_t)(out.size() * sizeof(int16_t)));
}

static void vqa_audio_queue_u8(const uint8_t* data, size_t len)
{
    std::vector<int16_t> pcm16(len);
    for (size_t i = 0; i < len; ++i)
        pcm16[i] = (int16_t)((data[i] - 128) * 256);
    vqa_audio_queue_s16(pcm16.data(), len);
}

// -------------------------------------------------------------------------
// Frame blitter: write decoded indexed pixels into the game's primary surface
// -------------------------------------------------------------------------
static void blit_vqa_frame(const uint8_t* pixels, int vqaW, int vqaH,
                            uint8_t* dst, int dstPitch, int scrW, int scrH)
{
    for (int y = 0; y < scrH; ++y)
        memset(dst + (size_t)y * dstPitch, 0, (size_t)scrW);

    int scale = std::min(scrW / vqaW, scrH / vqaH);
    if (scale < 1) scale = 1;
    if (scale > 2) scale = 2;

    int dstW   = vqaW * scale;
    int dstH   = vqaH * scale;
    int startX = (scrW - dstW) / 2;
    int startY = (scrH - dstH) / 2;

    for (int sy = 0; sy < vqaH; ++sy) {
        for (int sx = 0; sx < vqaW; ++sx) {
            uint8_t px = pixels[(size_t)sy * vqaW + sx];
            for (int dy = 0; dy < scale; ++dy) {
                int row = startY + sy * scale + dy;
                if (row < 0 || row >= scrH) continue;
                for (int dx = 0; dx < scale; ++dx) {
                    int col = startX + sx * scale + dx;
                    if (col >= 0 && col < scrW)
                        dst[(size_t)row * dstPitch + col] = px;
                }
            }
        }
    }
}

// -------------------------------------------------------------------------
// Play_Movie_Linux — public entry point (declared in vqa_player.h)
// -------------------------------------------------------------------------

extern "C" void Play_Movie_Linux(const char* name)
{
    if (!name || !*name) return;

    // TIM-506/TIM-507: skip all VQA playback when RA_AUTOSTART is active.
    // PROXY_TO_PTHREAD makes getenv() return NULL in the worker thread, so
    // check the MEMFS flag file (TIM-471 pattern).  This prevents ALLY1.VQA
    // (mission briefing) from crashing via SDL_InitSubSystem in vqa_audio_open
    // (TIM-496 regression: Emscripten leaves SDL.audioContext undefined after
    // SDL_QuitSubSystem, causing TypeError on the subsequent InitSubSystem call).
    bool dump_frames = (getenv("RA_VQA_DUMP_FRAMES") != nullptr);
    if (!dump_frames &&
        (getenv("RA_AUTOSTART") || RawFileClass("RA_AUTOSTART.FLAG").Is_Available())) {
        fprintf(stderr, "[VQA] RA_AUTOSTART active — skipping '%s.VQA'\n", name);
        return;
    }

    char filename[128];
    snprintf(filename, sizeof(filename), "%s.VQA", name);

    CCFileClass f(filename);
    if (!f.Is_Available()) {
        fprintf(stderr, "[VQA] '%s' not found in game data — skipping\n", filename);
        return;
    }
    if (!f.Open(READ)) {
        fprintf(stderr, "[VQA] Failed to open '%s'\n", filename);
        return;
    }

    // ---- Validate FORM/WVQA header ----
    uint8_t form_hdr[12] = {};
    if (f.Read(form_hdr, 12) != 12
        || !chunk_eq(form_hdr,     "FORM")
        || !chunk_eq(form_hdr + 8, "WVQA")) {
        fprintf(stderr, "[VQA] '%s': not a WVQA file (got %c%c%c%c/%c%c%c%c)\n",
                filename,
                form_hdr[0],form_hdr[1],form_hdr[2],form_hdr[3],
                form_hdr[8],form_hdr[9],form_hdr[10],form_hdr[11]);
        f.Close();
        return;
    }

    // ---- Scan for VQHD ----
    VQAHeader hdr = {};
    bool hdr_found = false;
    {
        uint8_t chk[8];
        while (f.Read(chk, 8) == 8) {
            uint32_t sz = be32(chk + 4);
            if (chunk_eq(chk, "VQHD")) {
                long to_read = (long)std::min((uint32_t)sizeof(VQAHeader), sz);
                f.Read(&hdr, to_read);
                if (sz > (uint32_t)sizeof(VQAHeader))
                    f.Seek((long)(sz - sizeof(VQAHeader)), SEEK_CUR);
                hdr_found = true;
                break;
            }
            if (sz > 0) f.Seek((long)sz + (sz & 1), SEEK_CUR);
        }
    }

    if (!hdr_found || hdr.width == 0 || hdr.height == 0) {
        fprintf(stderr, "[VQA] '%s': missing or empty VQHD\n", filename);
        f.Close();
        return;
    }

    int vqaW     = hdr.width;
    int vqaH     = hdr.height;
    int blockW   = hdr.blockW  ? hdr.blockW  : 4;
    int blockH   = hdr.blockH  ? hdr.blockH  : 2;
    int fps      = hdr.fps     ? hdr.fps     : 15;
    int maxBlocks = hdr.maxBlocks ? hdr.maxBlocks : 512;

    // Audio: flags bit 0 = audio present; clamp parameters defensively
    bool has_audio = (hdr.flags & 1) != 0;
    int  freq      = (hdr.freq     >= 8000 && hdr.freq     <= 48000) ? hdr.freq     : 22050;
    int  channels  = (hdr.channels == 1    || hdr.channels == 2)     ? hdr.channels : 1;

    int blocksX   = vqaW / blockW;
    int blocksY   = vqaH / blockH;
    int numBlocks = blocksX * blocksY;
    int cbEntrySize = blockW * blockH;

    fprintf(stderr, "[VQA] Playing '%s': %dx%d blk=%dx%d fps=%d "
            "flags=0x%x audio=%d hz=%d ch=%d frames=%d\n",
            filename, vqaW, vqaH, blockW, blockH, fps,
            hdr.flags, has_audio, freq, channels, hdr.numFrames);

    // TIM-587: VQA v2 pointer table uses 0xFF** entries as "solid colour"
    // blocks where the lo byte is the palette index.  Pre-fill codebook
    // slots 0xFF00..0xFFFF with a solid byte of `i` so a VPT entry
    // (lo=i, hi=0xFF) renders as palette[i] without any special case in the
    // render loop.  This matches ffmpeg's vqa_decode_frame_pal8.  TIM-549
    // had replaced this with `if (hi == 0xFF) continue;` (skip), which
    // worked accidentally for the Einstein briefing (lo==0 background) but
    // left stale prior-frame content wherever the encoder wanted a non-zero
    // solid fill — visible as block-aligned cyan scatter through the title
    // and prologue cinematics (TIM-587).
    const size_t MAX_CB_VECTORS = 0xFF00u + 0x100u;
    std::vector<uint8_t> codebook(MAX_CB_VECTORS * cbEntrySize, 0);
    for (int ci = 0; ci < 256; ++ci)
        memset(codebook.data() + (0xFF00u + ci) * cbEntrySize, (uint8_t)ci, cbEntrySize);

    std::vector<uint8_t> framebuf((size_t)vqaW * vqaH, 0);
    std::vector<uint8_t> prevbuf((size_t)vqaW * vqaH, 0);
    uint8_t palette[768] = {};
    std::vector<uint8_t> decomp_buf;

    // CBPZ accumulation: raw compressed chunks are collected over cbParts frames,
    // then decompressed together as one LCW stream replacing the full codebook.
    // Rendering happens BEFORE accumulation so the new codebook takes effect on
    // the NEXT frame — exactly matching ffmpeg's vqa_decode_frame_pal8.
    std::vector<uint8_t> next_codebook_buffer;
    size_t next_cb_idx    = 0;
    int partial_countdown = hdr.cbParts ? hdr.cbParts : 1;

    bool audio_ok = has_audio && vqa_audio_open(freq, channels);
    ImaState ima_state;  // predictor=0, step_index=0; persists across SND2 chunks

    uint32_t frame_ms = (fps > 0) ? (1000u / (uint32_t)fps) : 67u;
    bool user_abort   = false;
    int  frame_num    = 0;

#ifdef __EMSCRIPTEN__
    // TIM-586: install JS-side canvas listeners and reset the flag so a click
    // during the previous movie doesn't insta-skip this one.
    vqa_install_abort_listeners();
    vqa_clear_abort_flag();
#endif

    // Skip FINF (frame offsets — not needed for sequential playback)
    {
        uint8_t chk[8];
        if (f.Read(chk, 8) == 8) {
            uint32_t sz = be32(chk + 4);
            if (chunk_eq(chk, "FINF")) {
                if (sz > 0) f.Seek((long)sz + (sz & 1), SEEK_CUR);
            } else {
                f.Seek(-8L, SEEK_CUR);  // not FINF — rewind
            }
        }
    }

    // ---- Main frame loop ----
    while (frame_num < hdr.numFrames && !user_abort) {

        uint32_t t0 = SDL_GetTicks();

        uint8_t chk[8];
        if (f.Read(chk, 8) != 8) break;
        uint32_t chk_sz = be32(chk + 4);

        // ---- Audio chunks ----
        if (chunk_eq(chk, "SND0")) {
            if (chk_sz) {
                std::vector<uint8_t> raw(chk_sz);
                f.Read(raw.data(), (long)chk_sz);
                if (audio_ok) vqa_audio_queue_u8(raw.data(), raw.size());
                if (chk_sz & 1) f.Seek(1, SEEK_CUR);
            }
            continue;
        }
        if (chunk_eq(chk, "SND1")) {
            if (chk_sz) {
                std::vector<uint8_t> raw(chk_sz);
                f.Read(raw.data(), (long)chk_sz);
                if (audio_ok) {
                    auto pcm = decode_snd1(raw.data(), raw.size());
                    vqa_audio_queue_s16(pcm.data(), pcm.size());
                }
                if (chk_sz & 1) f.Seek(1, SEEK_CUR);
            }
            continue;
        }
        if (chunk_eq(chk, "SND2")) {
            if (chk_sz) {
                std::vector<uint8_t> raw(chk_sz);
                f.Read(raw.data(), (long)chk_sz);
                if (audio_ok) {
                    auto pcm = decode_snd2(raw.data(), raw.size(), ima_state);
                    vqa_audio_queue_s16(pcm.data(), pcm.size());
                }
                if (chk_sz & 1) f.Seek(1, SEEK_CUR);
            }
            continue;
        }
        if (!chunk_eq(chk, "VQFR")) {
            // Unknown top-level chunk — skip
            if (chk_sz) f.Seek((long)chk_sz + (chk_sz & 1), SEEK_CUR);
            continue;
        }

        // ---- VQFR video frame — read whole body, three-pass processing ----
        // Reading the full VQFR body enables ffmpeg-compatible chunk ordering:
        // render (VPT*) BEFORE accumulating CBPZ so the new codebook takes
        // effect only on the next frame.
        std::vector<uint8_t> vqfr_body((size_t)chk_sz);
        if ((long)f.Read(vqfr_body.data(), (long)chk_sz) != (long)chk_sz) {
            if (chk_sz & 1) f.Seek(1, SEEK_CUR);
            break;
        }
        if (chk_sz & 1) f.Seek(1, SEEK_CUR);

        // Helper: walk VQFR sub-chunk table and call fn(tag_ptr, ssz, body_ptr).
        auto iter_sub = [&](auto fn) {
            size_t fp = 0;
            while (fp + 8 <= vqfr_body.size()) {
                const uint8_t* shdr = vqfr_body.data() + fp;
                uint32_t ssz = be32(shdr + 4);
                if (fp + 8 + ssz > vqfr_body.size()) break;
                fn(shdr, ssz, shdr + 8);
                fp += 8 + ssz + (ssz & 1);
            }
        };

        // TIM-587: trace VQFR sub-chunk layout for the first 40 frames.
        bool trace = vqa_trace_enabled() && frame_num < 40;
        int  trc_cpl0 = 0, trc_cbf = 0, trc_cbp = 0, trc_vpt = 0;
        uint32_t trc_vpt_ssz = 0, trc_cb_ssz = 0;
        char trc_vpt_tag[5] = "", trc_cb_tag[5] = "";
        if (trace) {
            iter_sub([&](const uint8_t* shdr, uint32_t ssz, const uint8_t* /*sb*/) {
                char t[5]; memcpy(t, shdr, 4); t[4] = 0;
                if (chunk_eq(shdr, "CPL0")) { trc_cpl0 = 1; }
                else if (chunk_eq(shdr, "CBF0") || chunk_eq(shdr, "CBFZ")) {
                    trc_cbf = 1; memcpy(trc_cb_tag, t, 5); trc_cb_ssz = ssz;
                }
                else if (chunk_eq(shdr, "CBP0") || chunk_eq(shdr, "CBPZ")) {
                    trc_cbp = 1; memcpy(trc_cb_tag, t, 5); trc_cb_ssz = ssz;
                }
                else if (chunk_eq(shdr, "VPT0") || chunk_eq(shdr, "VPTZ") ||
                         chunk_eq(shdr, "VPTR") || chunk_eq(shdr, "VPRZ")) {
                    trc_vpt = 1; memcpy(trc_vpt_tag, t, 5); trc_vpt_ssz = ssz;
                }
            });
        }

        // Pass 1: CPL0 palette + full codebook (CBF0 / CBFZ)
        iter_sub([&](const uint8_t* shdr, uint32_t ssz, const uint8_t* sbody) {
            if (chunk_eq(shdr, "CPL0")) {
                long rd = (long)std::min((uint32_t)768u, ssz);
                memcpy(palette, sbody, rd);

            } else if (chunk_eq(shdr, "CBF0")) {
                long rd = (long)std::min((size_t)ssz, codebook.size());
                memcpy(codebook.data(), sbody, rd);
                next_codebook_buffer.clear();
                next_cb_idx = 0;
                partial_countdown = hdr.cbParts ? hdr.cbParts : 1;

            } else if (chunk_eq(shdr, "CBFZ")) {
                decomp_buf = lcw_decompress(sbody, ssz, codebook.size());
                if (!decomp_buf.empty())
                    memcpy(codebook.data(), decomp_buf.data(),
                           std::min(decomp_buf.size(), codebook.size()));
                next_codebook_buffer.clear();
                next_cb_idx = 0;
                partial_countdown = hdr.cbParts ? hdr.cbParts : 1;
            }
        });

        // Pass 2: Render frame (VPT0 / VPTZ / VPTR / VPRZ)
        // hi<0xFF: index into codebook (0x0000..0xFEFF).
        // hi==0xFF: index 0xFF**, routes to pre-filled solid-colour blocks
        // (codebook[0xFF00+lo] = palette[lo] for each pixel).  TIM-587.
        iter_sub([&](const uint8_t* shdr, uint32_t ssz, const uint8_t* sbody) {
            if (!chunk_eq(shdr, "VPT0") && !chunk_eq(shdr, "VPTZ") &&
                !chunk_eq(shdr, "VPTR") && !chunk_eq(shdr, "VPRZ")) return;

            const uint8_t* vpt = sbody;
            size_t vpt_sz = ssz;
            if (chunk_eq(shdr, "VPTZ") || chunk_eq(shdr, "VPRZ")) {
                decomp_buf = lcw_decompress(sbody, ssz, (size_t)numBlocks * 2);
                if (!decomp_buf.empty()) { vpt = decomp_buf.data(); vpt_sz = decomp_buf.size(); }
            }
            if (vpt_sz < (size_t)numBlocks * 2) return;

            const uint8_t* lo_tbl = vpt;
            const uint8_t* hi_tbl = vpt + numBlocks;
            memcpy(prevbuf.data(), framebuf.data(), framebuf.size());

            int trc_rendered = 0, trc_solid = 0;
            int trc_max_cb_idx = 0;
            for (int bi = 0; bi < numBlocks; ++bi) {
                int bx = bi % blocksX, by = bi / blocksX;
                uint8_t lo = lo_tbl[bi], hi = hi_tbl[bi];
                int cb_idx = (int)lo | ((int)hi << 8);
                if (cb_idx > trc_max_cb_idx) trc_max_cb_idx = cb_idx;
                const uint8_t* src = codebook.data() + (size_t)cb_idx * cbEntrySize;
                for (int fy = 0; fy < blockH; ++fy)
                    memcpy(framebuf.data() + (size_t)(by*blockH+fy)*vqaW + bx*blockW,
                           src + fy * blockW, blockW);
                if (hi == 0xFF) ++trc_solid; else ++trc_rendered;
            }
            if (trace) {
                fprintf(stderr, "[VQA-TRACE] f=%d cb=%d solid=%d "
                                "max_cb_idx=0x%04x (entries_used<=%d) "
                                "cb_hash_front=%08x cb_hash_back=%08x\n",
                        frame_num, trc_rendered, trc_solid, trc_max_cb_idx,
                        trc_max_cb_idx + 1,
                        vqa_fnv1a(codebook.data(), std::min<size_t>(2048, codebook.size())),
                        vqa_fnv1a(codebook.data() + codebook.size() - std::min<size_t>(2048, codebook.size()),
                                  std::min<size_t>(2048, codebook.size())));
            }
        });

        // Pass 3: Accumulate partial codebook AFTER rendering.
        // CBP0: uncompressed — concat, replace codebook after cbParts frames.
        // CBPZ: compressed   — concat raw bytes, decompress entire buffer as
        //        one LCW stream after cbParts frames (ffmpeg algorithm).
        iter_sub([&](const uint8_t* shdr, uint32_t ssz, const uint8_t* sbody) {
            int parts = hdr.cbParts ? hdr.cbParts : 1;
            if (chunk_eq(shdr, "CBP0")) {
                next_codebook_buffer.insert(next_codebook_buffer.end(), sbody, sbody + ssz);
                next_cb_idx += ssz;
                if (--partial_countdown <= 0) {
                    size_t n = std::min(next_cb_idx, codebook.size());
                    memcpy(codebook.data(), next_codebook_buffer.data(), n);
                    next_codebook_buffer.clear();
                    next_cb_idx = 0;
                    partial_countdown = parts;
                }
            } else if (chunk_eq(shdr, "CBPZ")) {
                next_codebook_buffer.insert(next_codebook_buffer.end(), sbody, sbody + ssz);
                next_cb_idx += ssz;
                if (--partial_countdown <= 0) {
                    decomp_buf = lcw_decompress(next_codebook_buffer.data(),
                                                next_codebook_buffer.size(), codebook.size());
                    if (!decomp_buf.empty())
                        memcpy(codebook.data(), decomp_buf.data(),
                               std::min(decomp_buf.size(), codebook.size()));
                    next_codebook_buffer.clear();
                    next_cb_idx = 0;
                    partial_countdown = parts;
                }
            }
        });

        if (trace) {
            fprintf(stderr, "[VQA-TRACE] f=%d chunks: cpl0=%d cbf=%s(%u) "
                            "cbp=%s(%u) vpt=%s(%u) countdown=%d acc=%zu cbParts=%u\n",
                    frame_num, trc_cpl0,
                    trc_cbf ? trc_cb_tag : "-", trc_cbf ? trc_cb_ssz : 0u,
                    trc_cbp ? trc_cb_tag : "-", trc_cbp ? trc_cb_ssz : 0u,
                    trc_vpt ? trc_vpt_tag : "-", trc_vpt ? trc_vpt_ssz : 0u,
                    partial_countdown, next_codebook_buffer.size(),
                    (unsigned)(hdr.cbParts ? hdr.cbParts : 1));
        }

        // ---- Present frame ----
        if (SDL_Has_Primary_Surface()) {
            int scrW = (ScreenWidth  > 0) ? ScreenWidth  : 640;
            int scrH = (ScreenHeight > 0) ? ScreenHeight : 480;
            Set_DD_Palette_8bit(palette, 256);  // TIM-580: 6-bit VGA *4 + bottom-bit fill (ffmpeg-compatible)
            blit_vqa_frame(framebuf.data(), vqaW, vqaH,
                           SDL_Get_Primary_Pixels(),
                           SDL_Get_Primary_Pitch(),
                           scrW, scrH);
            Wait_Vert_Blank();
        }

        // ---- Optional PPM frame dump (RA_VQA_DUMP_FRAMES=<dir>) ----
        {
            static const char* dump_dir = nullptr;
            static bool dump_checked = false;
            if (!dump_checked) { dump_dir = getenv("RA_VQA_DUMP_FRAMES"); dump_checked = true; }
            if (dump_dir && (frame_num == 0 || frame_num == 29 || frame_num == 59)) {
                char path[512];
                snprintf(path, sizeof(path), "%s/%s_frame_%03d.ppm",
                         dump_dir, name, frame_num + 1);
                FILE* fp = fopen(path, "wb");
                if (fp) {
                    fprintf(fp, "P6\n%d %d\n255\n", vqaW, vqaH);
                    // TIM-580: PPM uses same 6-bit→8-bit scaling as the live render
                    // (Set_DD_Palette_8bit in DDRAW.CPP), so PPMs match what the
                    // player puts on screen and what ffmpeg outputs.
                    for (int py = 0; py < vqaH; ++py) {
                        for (int px = 0; px < vqaW; ++px) {
                            uint8_t idx = framebuf[(size_t)py * vqaW + px];
                            uint8_t r = (uint8_t)(palette[idx*3+0] << 2);
                            uint8_t g = (uint8_t)(palette[idx*3+1] << 2);
                            uint8_t b = (uint8_t)(palette[idx*3+2] << 2);
                            r |= (uint8_t)((r >> 6) & 0x3);
                            g |= (uint8_t)((g >> 6) & 0x3);
                            b |= (uint8_t)((b >> 6) & 0x3);
                            fputc(r, fp); fputc(g, fp); fputc(b, fp);
                        }
                    }
                    fclose(fp);
                    fprintf(stderr, "[VQA] Dumped %s frame %d → %s\n", name, frame_num + 1, path);
                }
            }
        }

        ++frame_num;

        // ---- Poll for keypress / ESC to skip ----
        SDL_Event ev;
        SDL_PumpEvents();
        while (SDL_PollEvent(&ev)) {
            if (ev.type == SDL_KEYDOWN
                || ev.type == SDL_MOUSEBUTTONDOWN
                || ev.type == SDL_QUIT) {
                user_abort = true;
                break;
            }
        }
#ifdef __EMSCRIPTEN__
        // TIM-586: SDL_PollEvent above does not see canvas events on the
        // worker thread; consult the JS-side flag set by our canvas listeners.
        if (!user_abort && vqa_check_abort_flag()) {
            user_abort = true;
            fprintf(stderr, "[VQA] '%s' aborted by user (canvas event)\n", filename);
        }
#endif

        // ---- Frame pacing ----
        uint32_t elapsed = SDL_GetTicks() - t0;
        if (elapsed < frame_ms) SDL_Delay(frame_ms - elapsed);
    }

    // Drain remaining audio before returning
    if (audio_ok) {
        while (SDL_GetQueuedAudioSize(vqa_audio_dev) > 4096)
            SDL_Delay(10);
    }

    vqa_audio_close();
    f.Close();

    fprintf(stderr, "[VQA] '%s' done (%d/%d frames)\n",
            filename, frame_num, hdr.numFrames);
}

#endif // !_MSC_VER
