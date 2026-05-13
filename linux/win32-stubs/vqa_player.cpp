// TIM-441: Minimal VQA cinematic player for the native Linux / SDL2 build.
//
// Replaces the Play_Movie_GlyphX → EventCallback==NULL early-return path.
// Reads VQA files via CCFileClass (MIX-aware), decodes with the in-tree
// LCW decompressor, renders into the game's primary SDL surface, and plays
// raw-PCM audio via SDL2.
//
// Format reference: Westwood VQA version 2 (C&C: Red Alert intro files).
// LCW decompression: LCW.CPP (Format80 variant).
// Palette convention: CPL0 stores 6-bit VGA DAC values (0-63); Set_DD_Palette applies <<2.
//
// Include pattern: function.h first (same as REDALERT/*.cpp), then SDL2.

#ifndef _MSC_VER

#include "function.h"

#include <SDL2/SDL.h>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <algorithm>
#include <vector>

#include "vqa_player.h"
#include "sdl_audio.h"

#ifdef __EMSCRIPTEN__
// TIM-517: proxy VQA SDL audio calls to the main browser thread (same as AUDIO.CPP/TIM-428).
#include <emscripten/threading.h>
#include <emscripten/proxying.h>
#endif

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
    SDL_AudioSpec want = {}, have = {};
    want.freq     = a->freq;
    want.format   = AUDIO_S16LSB;
    want.channels = (uint8_t)a->channels;
    want.samples  = 1024;
    vqa_audio_dev = SDL_OpenAudioDevice(nullptr, 0, &want, &have,
                                         SDL_AUDIO_ALLOW_FREQUENCY_CHANGE);
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

static void vqa_audio_queue_s16(const int16_t* pcm, size_t count)
{
    if (vqa_audio_dev && pcm && count)
        SDL_QueueAudio(vqa_audio_dev, pcm, (uint32_t)(count * sizeof(int16_t)));
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

    // VQA v2: 0x0000..0xFEFF = codebook indices; hi==0xFF = block unchanged
    // from the previous frame.  The render loop skips hi==0xFF blocks so we
    // only need 0xFF00 codebook slots here.
    const size_t MAX_CB_VECTORS = 0xFF00u;
    std::vector<uint8_t> codebook(MAX_CB_VECTORS * cbEntrySize, 0);

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
        // hi==0xFF: block unchanged from previous frame — skip (framebuf
        // already holds the previous frame content for that block).
        // hi<0xFF: index into codebook (0x0000..0xFEFF).
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

            for (int bi = 0; bi < numBlocks; ++bi) {
                int bx = bi % blocksX, by = bi / blocksX;
                uint8_t lo = lo_tbl[bi], hi = hi_tbl[bi];
                if (hi == 0xFF) continue;  // block unchanged from previous frame
                int cb_idx = (int)lo | ((int)hi << 8);
                const uint8_t* src = codebook.data() + (size_t)cb_idx * cbEntrySize;
                for (int fy = 0; fy < blockH; ++fy)
                    memcpy(framebuf.data() + (size_t)(by*blockH+fy)*vqaW + bx*blockW,
                           src + fy * blockW, blockW);
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

        // ---- Present frame ----
        if (SDL_Has_Primary_Surface()) {
            int scrW = (ScreenWidth  > 0) ? ScreenWidth  : 640;
            int scrH = (ScreenHeight > 0) ? ScreenHeight : 480;
            Set_DD_Palette(palette);  // CPL0 is 6-bit VGA; <<2 expansion is correct
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
                    for (int py = 0; py < vqaH; ++py) {
                        for (int px = 0; px < vqaW; ++px) {
                            uint8_t idx = framebuf[(size_t)py * vqaW + px];
                            uint8_t r = (palette[idx*3+0] << 2) & 0xFF;
                            uint8_t g = (palette[idx*3+1] << 2) & 0xFF;
                            uint8_t b = (palette[idx*3+2] << 2) & 0xFF;
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
