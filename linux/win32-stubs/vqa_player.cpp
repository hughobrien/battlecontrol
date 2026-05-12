// TIM-441: Minimal VQA cinematic player for the native Linux / SDL2 build.
//
// Replaces the Play_Movie_GlyphX → EventCallback==NULL early-return path.
// Reads VQA files via CCFileClass (MIX-aware), decodes with the in-tree
// LCW decompressor, renders into the game's primary SDL surface, and plays
// raw-PCM audio via SDL2.
//
// Format reference: Westwood VQA version 2 (C&C: Red Alert intro files).
// LCW decompression: LCW.CPP (Format80 variant).
// Palette convention: CPL0 stores 6-bit VGA values; scaled ×4 to 8-bit.
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

static bool vqa_audio_open(int freq, int channels)
{
    // Clamp to safe values before passing to SDL2
    if (channels < 1 || channels > 2) channels = 1;
    if (freq < 8000 || freq > 48000) freq = 22050;

    // If game audio is already open, close it so SDL can reuse the device.
    vqa_stole_game_audio = SDL_Audio_Is_Open();
    if (vqa_stole_game_audio) {
        SDL_Audio_Get_Params(&vqa_saved_rate, &vqa_saved_channels, &vqa_saved_bits);
        SDL_Audio_Close();
    }

    SDL_AudioSpec want = {}, have = {};
    want.freq     = freq;
    want.format   = AUDIO_S16LSB;
    want.channels = (uint8_t)channels;
    want.samples  = 1024;
    vqa_audio_dev = SDL_OpenAudioDevice(nullptr, 0, &want, &have,
                                         SDL_AUDIO_ALLOW_FREQUENCY_CHANGE);
    if (!vqa_audio_dev) {
        fprintf(stderr, "[VQA] SDL audio open failed: %s\n", SDL_GetError());
        // Restore game audio immediately if we failed.
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
    // Reopen game audio device if we closed it for VQA.
    if (vqa_stole_game_audio) {
        SDL_Audio_Open(vqa_saved_rate, vqa_saved_channels, vqa_saved_bits);
        vqa_stole_game_audio = false;
    }
}

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

    std::vector<uint8_t> codebook((size_t)maxBlocks * cbEntrySize, 0);
    std::vector<uint8_t> framebuf((size_t)vqaW * vqaH, 0);
    std::vector<uint8_t> prevbuf((size_t)vqaW * vqaH, 0);
    uint8_t palette[768] = {};
    std::vector<uint8_t> decomp_buf;

    bool audio_ok = has_audio && vqa_audio_open(freq, channels);

    uint32_t frame_ms = (fps > 0) ? (1000u / (uint32_t)fps) : 67u;
    bool user_abort   = false;
    int  frame_num    = 0;
    int  cbp_accum    = 0;

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
            // IMA ADPCM — unsupported, skip
            if (chk_sz) f.Seek((long)chk_sz + (chk_sz & 1), SEEK_CUR);
            continue;
        }
        if (!chunk_eq(chk, "VQFR")) {
            // Unknown top-level chunk — skip
            if (chk_sz) f.Seek((long)chk_sz + (chk_sz & 1), SEEK_CUR);
            continue;
        }

        // ---- VQFR video frame — manual position tracking ----
        long vqfr_remaining = (long)chk_sz;

        while (vqfr_remaining >= 8) {
            uint8_t sub[8];
            if (f.Read(sub, 8) != 8) break;
            vqfr_remaining -= 8;
            uint32_t sub_sz = be32(sub + 4);

            // Sub-chunk size must not exceed the remaining VQFR bytes.
            // Some files use little-endian sub-chunk sizes; fall back to LE
            // if the BE interpretation is out of range.
            if ((long)sub_sz > vqfr_remaining) {
                uint32_t le_sz = (uint32_t)sub[4] | ((uint32_t)sub[5]<<8)
                                | ((uint32_t)sub[6]<<16) | ((uint32_t)sub[7]<<24);
                if ((long)le_sz <= vqfr_remaining) {
                    sub_sz = le_sz;
                } else {
                    break;  // corrupt VQFR; skip to next frame
                }
            }

            if (chunk_eq(sub, "CBF0")) {
                long rd = (long)std::min((size_t)sub_sz, codebook.size());
                f.Read(codebook.data(), rd);
                long skip = (long)sub_sz - rd;
                if (skip > 0) f.Seek(skip, SEEK_CUR);
                cbp_accum = 0;

            } else if (chunk_eq(sub, "CBFZ")) {
                std::vector<uint8_t> comp(sub_sz);
                f.Read(comp.data(), (long)sub_sz);
                decomp_buf = lcw_decompress(comp.data(), comp.size(), codebook.size());
                if (!decomp_buf.empty())
                    memcpy(codebook.data(), decomp_buf.data(),
                           std::min(decomp_buf.size(), codebook.size()));
                cbp_accum = 0;

            } else if (chunk_eq(sub, "CBP0")) {
                int parts     = hdr.cbParts ? hdr.cbParts : 1;
                size_t part_b = codebook.size() / (size_t)parts;
                size_t off    = (size_t)cbp_accum * part_b;
                long   rd     = (long)std::min((size_t)sub_sz, codebook.size() - off);
                f.Read(codebook.data() + off, rd);
                long skip = (long)sub_sz - rd;
                if (skip > 0) f.Seek(skip, SEEK_CUR);
                cbp_accum = (cbp_accum + 1) % parts;

            } else if (chunk_eq(sub, "CBPZ")) {
                std::vector<uint8_t> comp(sub_sz);
                f.Read(comp.data(), (long)sub_sz);
                int parts     = hdr.cbParts ? hdr.cbParts : 1;
                size_t part_b = codebook.size() / (size_t)parts;
                size_t off    = (size_t)cbp_accum * part_b;
                decomp_buf = lcw_decompress(comp.data(), comp.size(), part_b);
                if (!decomp_buf.empty())
                    memcpy(codebook.data() + off, decomp_buf.data(),
                           std::min(decomp_buf.size(), codebook.size() - off));
                cbp_accum = (cbp_accum + 1) % parts;

            } else if (chunk_eq(sub, "CPL0")) {
                uint8_t raw[768] = {};
                long rd = (long)std::min((uint32_t)768u, sub_sz);
                f.Read(raw, rd);
                long skip = (long)sub_sz - rd;
                if (skip > 0) f.Seek(skip, SEEK_CUR);
                for (int i = 0; i < 768; ++i)
                    palette[i] = (uint8_t)(raw[i] << 2);  // 6-bit → 8-bit

            } else if (chunk_eq(sub, "VPT0") || chunk_eq(sub, "VPTZ")
                    || chunk_eq(sub, "VPTR") || chunk_eq(sub, "VPRZ")) {
                std::vector<uint8_t> vpt_raw(sub_sz);
                f.Read(vpt_raw.data(), (long)sub_sz);

                const std::vector<uint8_t>* vpt = &vpt_raw;
                if (chunk_eq(sub, "VPTZ") || chunk_eq(sub, "VPRZ")) {
                    decomp_buf = lcw_decompress(vpt_raw.data(), vpt_raw.size(),
                                                 (size_t)numBlocks * 2);
                    if (!decomp_buf.empty()) vpt = &decomp_buf;
                }

                if (vpt->size() >= (size_t)numBlocks * 2) {
                    const uint8_t* lo_tbl = vpt->data();
                    const uint8_t* hi_tbl = vpt->data() + numBlocks;

                    memcpy(prevbuf.data(), framebuf.data(), framebuf.size());

                    for (int bi = 0; bi < numBlocks; ++bi) {
                        int bx = bi % blocksX;
                        int by = bi / blocksX;
                        uint8_t lo = lo_tbl[bi];
                        uint8_t hi = hi_tbl[bi];

                        if (hi == 0xFF) {
                            if (lo == 0xFF) {
                                for (int fy = 0; fy < blockH; ++fy)
                                    memcpy(framebuf.data()
                                           + (size_t)(by*blockH+fy)*vqaW + bx*blockW,
                                           prevbuf.data()
                                           + (size_t)(by*blockH+fy)*vqaW + bx*blockW,
                                           blockW);
                            } else {
                                for (int fy = 0; fy < blockH; ++fy)
                                    memset(framebuf.data()
                                           + (size_t)(by*blockH+fy)*vqaW + bx*blockW,
                                           lo, blockW);
                            }
                            continue;
                        }

                        int cb_idx = (int)lo | ((int)hi << 8);
                        if (cb_idx >= maxBlocks) cb_idx = 0;
                        const uint8_t* src = codebook.data()
                                             + (size_t)cb_idx * cbEntrySize;
                        for (int fy = 0; fy < blockH; ++fy)
                            memcpy(framebuf.data()
                                   + (size_t)(by*blockH+fy)*vqaW + bx*blockW,
                                   src + fy*blockW, blockW);
                    }
                }

            } else {
                // Unknown sub-chunk: skip body
                if (sub_sz > 0) f.Seek((long)sub_sz, SEEK_CUR);
            }

            vqfr_remaining -= (long)sub_sz;
            if (sub_sz & 1) { f.Seek(1, SEEK_CUR); --vqfr_remaining; }
        }

        // Seek past any unprocessed VQFR bytes (including IFF VQFR padding)
        if (vqfr_remaining > 0) f.Seek(vqfr_remaining, SEEK_CUR);
        if (chk_sz & 1) f.Seek(1, SEEK_CUR);

        // ---- Present frame ----
        if (SDL_Has_Primary_Surface()) {
            int scrW = (ScreenWidth  > 0) ? ScreenWidth  : 640;
            int scrH = (ScreenHeight > 0) ? ScreenHeight : 480;
            Set_DD_Palette(palette);
            blit_vqa_frame(framebuf.data(), vqaW, vqaH,
                           SDL_Get_Primary_Pixels(),
                           SDL_Get_Primary_Pitch(),
                           scrW, scrH);
            Wait_Vert_Blank();
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
