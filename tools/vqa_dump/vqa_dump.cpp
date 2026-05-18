// Standalone VQA decoder — dumps PPM frames + raw PCM audio.
// No external dependencies beyond libc and libstdc++.
//
// Build:
//   g++ -std=c++17 -O2 -o vqa_dump tools/vqa_dump/vqa_dump.cpp
//
// Usage:
//   ./vqa_dump <input.vqa> <outdir> [--duration N]
//
// Output:
//   <outdir>/frame_%04d.ppm
//   <outdir>/audio.pcm        (raw 16-bit signed LE PCM, interleaved stereo)
//   <outdir>/metadata.json    (decode params)

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cassert>
#include <vector>
#include <algorithm>
#include <string>
#include <cmath>
#include <filesystem>
namespace fs = std::filesystem;

// ---------------------------------------------------------------------------
// LCW (Format80) decompressor — identical to lcw_decode_safe in vqa_player.cpp
// ---------------------------------------------------------------------------
static size_t lcw_decode_safe(const uint8_t* src, size_t src_len,
                               uint8_t* dst, size_t dst_cap)
{
    const uint8_t* src_end = src + src_len;
    uint8_t* dp = dst;
    uint8_t* dst_end = dst + dst_cap;

    while (src < src_end && dp < dst_end) {
        uint8_t op = *src++;
        if (op == 0x80) {
            break;
        } else if (!(op & 0x80)) {
            if (src >= src_end) break;
            unsigned count  = (op >> 4) + 3;
            unsigned offset = (unsigned)(op & 0x0f) << 8 | *src++;
            const uint8_t* cp = dp - offset;
            if (cp < dst) cp = dst;
            while (count-- && dp < dst_end) *dp++ = *cp++;
        } else if (!(op & 0x40)) {
            unsigned count = op & 0x3f;
            while (count-- && src < src_end && dp < dst_end) *dp++ = *src++;
        } else if (op == 0xfe) {
            if (src + 2 >= src_end) break;
            unsigned count = (unsigned)src[0] | ((unsigned)src[1] << 8);
            uint8_t  fill  = src[2];
            src += 3;
            while (count-- && dp < dst_end) *dp++ = fill;
        } else if (op == 0xff) {
            if (src + 3 >= src_end) break;
            unsigned count  = (unsigned)src[0] | ((unsigned)src[1] << 8);
            unsigned offset = (unsigned)src[2] | ((unsigned)src[3] << 8);
            src += 4;
            const uint8_t* cp = dst + offset;
            while (count-- && dp < dst_end) {
                *dp++ = (cp < dst_end) ? *cp++ : 0;
            }
        } else {
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
    size_t alloc = std::max(src_len * 4 + 4096, dst_hint) + 65536;
    std::vector<uint8_t> dst(alloc, 0);
    size_t out = lcw_decode_safe(src, src_len, dst.data(), alloc);
    if (out > 0) dst.resize(out);
    else         dst.clear();
    return dst;
}

// ---------------------------------------------------------------------------
// IFF helpers
// ---------------------------------------------------------------------------
static bool chunk_eq(const uint8_t* id, const char* tag) {
    return id[0]==(uint8_t)tag[0] && id[1]==(uint8_t)tag[1]
        && id[2]==(uint8_t)tag[2] && id[3]==(uint8_t)tag[3];
}
static uint32_t be32(const uint8_t* p) {
    return ((uint32_t)p[0]<<24)|((uint32_t)p[1]<<16)
         | ((uint32_t)p[2]<< 8)|(uint32_t)p[3];
}
static uint16_t le16(const uint8_t* p) {
    return (uint16_t)p[0] | ((uint16_t)p[1]<<8);
}

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
static const int8_t snd1_delta[16] = {
    -9, -8, -6, -5, -4, -3, -2, -1, 0, 1, 2, 3, 4, 5, 6, 8
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

// ---------------------------------------------------------------------------
// Audio decoders — identical to vqa_player.cpp
// ---------------------------------------------------------------------------
static std::vector<int16_t> decode_snd1(const uint8_t* src, size_t src_len)
{
    if (src_len < 2) return {};
    std::vector<int16_t> out;
    out.reserve(src_len * 2);
    int predictor = 0x80;
    for (size_t i = 2; i < src_len; ++i) {
        uint8_t b = src[i];
        int nibble_lo = b & 0xF;
        predictor += snd1_delta[nibble_lo];
        predictor = std::max(0, std::min(255, predictor));
        out.push_back((int16_t)((predictor - 128) * 256));
        int nibble_hi = (b >> 4) & 0xF;
        predictor += snd1_delta[nibble_hi];
        predictor = std::max(0, std::min(255, predictor));
        out.push_back((int16_t)((predictor - 128) * 256));
    }
    return out;
}

static std::vector<int16_t> decode_snd2(const uint8_t* src, size_t src_len, ImaState& st)
{
    std::vector<int16_t> out;
    out.reserve(src_len * 2);
    for (size_t i = 0; i < src_len; ++i) {
        out.push_back(ima_decode_nibble(st, src[i] & 0x0F));
        out.push_back(ima_decode_nibble(st, src[i] >> 4));
    }
    return out;
}

// ---------------------------------------------------------------------------
// WAV writer
// ---------------------------------------------------------------------------
static bool write_wav(const std::string& path, const int16_t* pcm, size_t num_samples,
                      int freq, int channels)
{
    FILE* fp = fopen(path.c_str(), "wb");
    if (!fp) return false;

    int bits_per_sample = 16;
    int byte_rate = freq * channels * bits_per_sample / 8;
    int block_align = channels * bits_per_sample / 8;
    uint32_t data_size = (uint32_t)num_samples * block_align;

    struct WavHeader {
        char     riff[4]     = {'R','I','F','F'};
        uint32_t file_size;
        char     wave[4]     = {'W','A','V','E'};
        char     fmt_[4]     = {'f','m','t',' '};
        uint32_t fmt_len     = 16;
        uint16_t audio_fmt   = 1; // PCM
        uint16_t num_ch;
        uint32_t sample_rate;
        uint32_t byte_rt;
        uint16_t blk_align;
        uint16_t bits_per;
        char     data_id[4]  = {'d','a','t','a'};
        uint32_t data_sz;
    } hdr;

    hdr.file_size  = 36 + data_size;
    hdr.num_ch     = (uint16_t)channels;
    hdr.sample_rate = (uint32_t)freq;
    hdr.byte_rt    = (uint32_t)byte_rate;
    hdr.blk_align  = (uint16_t)block_align;
    hdr.bits_per   = (uint16_t)bits_per_sample;
    hdr.data_sz    = data_size;

    fwrite(&hdr, sizeof(hdr), 1, fp);
    fwrite(pcm, sizeof(int16_t), num_samples, fp);
    fclose(fp);
    return true;
}

// ---------------------------------------------------------------------------
// PPM writer
// ---------------------------------------------------------------------------
static bool write_ppm(const std::string& path, const uint8_t* framebuf,
                      const uint8_t* palette, int w, int h)
{
    FILE* fp = fopen(path.c_str(), "wb");
    if (!fp) return false;
    fprintf(fp, "P6\n%d %d\n255\n", w, h);
    for (int y = 0; y < h; ++y) {
        for (int x = 0; x < w; ++x) {
            uint8_t idx = framebuf[(size_t)y * w + x];
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
    return true;
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------
int main(int argc, char** argv)
{
    if (argc < 3) {
        fprintf(stderr, "Usage: %s <input.vqa> <outdir> [--duration N]\n", argv[0]);
        return 1;
    }

    const char* vqa_path = argv[1];
    const char* outdir   = argv[2];
    double max_seconds = 20.0;

    for (int i = 3; i < argc; ++i) {
        if (strcmp(argv[i], "--duration") == 0 && i + 1 < argc) {
            max_seconds = atof(argv[i + 1]);
            ++i;
        }
    }

    FILE* fp = fopen(vqa_path, "rb");
    if (!fp) { fprintf(stderr, "FAIL: cannot open %s\n", vqa_path); return 1; }

    fseek(fp, 0, SEEK_END);
    long fsize = ftell(fp);
    fseek(fp, 0, SEEK_SET);
    if (fsize < 12) { fprintf(stderr, "FAIL: file too small\n"); fclose(fp); return 1; }

    std::vector<uint8_t> file_data((size_t)fsize);
    (void)fread(file_data.data(), 1, (size_t)fsize, fp);
    fclose(fp);

    const uint8_t* d = file_data.data();
    if (!chunk_eq(d, "FORM") || !chunk_eq(d+8, "WVQA")) {
        fprintf(stderr, "FAIL: not a WVQA file\n"); return 1;
    }

    // -----------------------------------------------------------------------
    // Parse VQHD
    // -----------------------------------------------------------------------
    int vqaW = 0, vqaH = 0, blockW = 4, blockH = 2, fps = 15;
    int numFrames = 0, cbParts = 1;
    int audio_freq = 22050, audio_channels = 1, audio_bits = 16;
    bool has_audio = false;

    size_t pos = 12;
    while (pos + 8 <= file_data.size()) {
        const uint8_t* chdr = d + pos;
        uint32_t sz = be32(chdr + 4);
        if (chunk_eq(chdr, "VQHD")) {
            const uint8_t* body = chdr + 8;
            uint32_t to_read = std::min(sz, (uint32_t)36u);
            if (to_read >= 14) {
                numFrames = (int)le16(body + 4);
                vqaW      = (int)le16(body + 6);
                vqaH      = (int)le16(body + 8);
                if (to_read >= 13) {
                    blockW = (int)body[10];
                    blockH = (int)body[11];
                }
                if (to_read >= 14) {
                    fps     = (int)body[12];
                    cbParts = (int)body[13];
                    if (!cbParts) cbParts = 1;
                }
                if (to_read >= 28) {
                    has_audio    = (le16(body + 2) & 1) != 0;
                    audio_freq   = (int)le16(body + 24);
                    audio_channels = (int)body[26];
                    audio_bits   = (int)body[27];
                }
            }
            break;
        }
        pos += 8 + sz + (sz & 1);
    }

    if (!vqaW || !vqaH) {
        fprintf(stderr, "FAIL: no valid VQHD\n"); return 1;
    }

    // Clamp to first N seconds
    int max_frames = (int)(max_seconds * fps + 0.5);
    int decode_frames = std::min(numFrames, max_frames);

    // Create output directory
    fs::create_directories(outdir);

    fprintf(stderr, "[VQA] %dx%d blk=%dx%d frames=%d/%d fps=%d cbParts=%d audio=%d (%dHz %dch %dbit)\n",
            vqaW, vqaH, blockW, blockH, decode_frames, numFrames, fps, cbParts,
            has_audio, audio_freq, audio_channels, audio_bits);

    // -----------------------------------------------------------------------
    // Prepare decode buffers
    // -----------------------------------------------------------------------
    int blocksX   = vqaW / blockW;
    int blocksY   = vqaH / blockH;
    int numBlocks = blocksX * blocksY;
    int cbEntrySize = blockW * blockH;

    const size_t MAX_CB = 0xFF00u + 0x100u;
    std::vector<uint8_t> codebook(MAX_CB * cbEntrySize, 0);
    for (int ci = 0; ci < 256; ++ci) {
        memset(codebook.data() + (0xFF00u + ci) * cbEntrySize, (uint8_t)ci, cbEntrySize);
        memset(codebook.data() + (0x0F00u + ci) * cbEntrySize, (uint8_t)ci, cbEntrySize);
    }

    std::vector<uint8_t> framebuf((size_t)vqaW * vqaH, 0);
    std::vector<uint8_t> palette(768, 0);
    std::vector<uint8_t> next_codebook_buffer;
    size_t next_cb_idx = 0;
    int partial_countdown = cbParts;

    // Audio state
    std::vector<int16_t> all_audio_pcm;
    ImaState ima_state;

    // -----------------------------------------------------------------------
    // Frame decode loop
    // -----------------------------------------------------------------------
    pos = 12;
    // Skip to first VQFR
    while (pos + 8 <= file_data.size()) {
        const uint8_t* chdr = d + pos;
        uint32_t sz = be32(chdr + 4);
        if (chunk_eq(chdr, "VQHD")) {
            pos += 8 + sz + (sz & 1);
            break;
        }
        pos += 8 + sz + (sz & 1);
    }
    // Skip FINF
    if (pos + 8 <= file_data.size()) {
        const uint8_t* chdr = d + pos;
        uint32_t sz = be32(chdr + 4);
        if (chunk_eq(chdr, "FINF"))
            pos += 8 + sz + (sz & 1);
    }

    int frame_num = 0;
    bool palette_set = false;

    // Collect audio from top-level SND chunks before/after VQFR frames
    auto handle_audio = [&](const uint8_t* chdr, uint32_t sz) -> bool {
        if (!has_audio) return false;
        if (sz == 0) return false;
        const uint8_t* body = d + pos;
        if (chunk_eq(chdr, "SND0")) {
            // Raw PCM
            if (audio_bits == 16) {
                size_t ns = sz / 2;
                const int16_t* src = (const int16_t*)body;
                all_audio_pcm.insert(all_audio_pcm.end(), src, src + ns);
            } else {
                // 8-bit unsigned -> 16-bit signed
                for (uint32_t i = 0; i < sz; ++i)
                    all_audio_pcm.push_back((int16_t)(((int)body[i] - 128) * 256));
            }
            return true;
        } else if (chunk_eq(chdr, "SND1")) {
            auto pcm = decode_snd1(body, sz);
            all_audio_pcm.insert(all_audio_pcm.end(), pcm.begin(), pcm.end());
            return true;
        } else if (chunk_eq(chdr, "SND2")) {
            auto pcm = decode_snd2(body, sz, ima_state);
            all_audio_pcm.insert(all_audio_pcm.end(), pcm.begin(), pcm.end());
            return true;
        }
        return false;
    };

    // Main loop — handle top-level chunks (CPL0, SND*, VQFR)
    while (frame_num < decode_frames && pos + 8 <= file_data.size()) {
        const uint8_t* chdr = d + pos;
        uint32_t chk_sz = be32(chdr + 4);
        pos += 8;

        // Handle audio chunks at top level (between VQFRs)
        if (handle_audio(chdr, chk_sz)) {
            pos += chk_sz + (chk_sz & 1);
            continue;
        }

        // Handle top-level CPL0
        if (chunk_eq(chdr, "CPL0")) {
            long rd = (long)std::min(768u, chk_sz);
            memcpy(palette.data(), d + pos, rd);
            palette_set = true;
            pos += chk_sz + (chk_sz & 1);
            continue;
        }

        if (!chunk_eq(chdr, "VQFR")) {
            pos += chk_sz + (chk_sz & 1);
            continue;
        }

        if (pos + chk_sz > file_data.size()) break;
        const uint8_t* body = d + pos;
        pos += chk_sz + (chk_sz & 1);

        // Iterate sub-chunks
        auto iter_sub = [&](auto fn) {
            size_t sp = 0;
            while (sp + 8 <= chk_sz) {
                const uint8_t* shdr = body + sp;
                uint32_t ssz = be32(shdr + 4);
                if (sp + 8 + ssz > chk_sz) break;
                fn(shdr, ssz, shdr + 8);
                sp += 8 + ssz + (ssz & 1);
            }
        };

        // Pass 1: CPL0 + full codebook
        iter_sub([&](const uint8_t* shdr, uint32_t ssz, const uint8_t* sbody) {
            if (chunk_eq(shdr, "CPL0")) {
                long rd = (long)std::min(768u, ssz);
                memcpy(palette.data(), sbody, rd);
                palette_set = true;
            } else if (chunk_eq(shdr, "CBF0")) {
                long rd = (long)std::min((size_t)ssz, codebook.size());
                memcpy(codebook.data(), sbody, rd);
                next_codebook_buffer.clear();
                next_cb_idx = 0;
                partial_countdown = cbParts;
            } else if (chunk_eq(shdr, "CBFZ")) {
                auto dec = lcw_decompress(sbody, ssz, codebook.size());
                if (!dec.empty())
                    memcpy(codebook.data(), dec.data(),
                           std::min(dec.size(), codebook.size()));
                next_codebook_buffer.clear();
                next_cb_idx = 0;
                partial_countdown = cbParts;
            }
        });

        // Pass 2: render frame
        iter_sub([&](const uint8_t* shdr, uint32_t ssz, const uint8_t* sbody) {
            if (!chunk_eq(shdr, "VPT0") && !chunk_eq(shdr, "VPTZ") &&
                !chunk_eq(shdr, "VPTR") && !chunk_eq(shdr, "VPRZ")) return;

            const uint8_t* vpt = sbody;
            size_t vpt_sz = ssz;
            if (chunk_eq(shdr, "VPTZ") || chunk_eq(shdr, "VPRZ")) {
                auto vpt_dec = lcw_decompress(sbody, ssz, (size_t)numBlocks * 2);
                if (!vpt_dec.empty()) { vpt = vpt_dec.data(); vpt_sz = vpt_dec.size(); }
            }
            if (vpt_sz < (size_t)numBlocks * 2) return;

            const uint8_t* lo_tbl = vpt;
            const uint8_t* hi_tbl = vpt + numBlocks;

            for (int bi = 0; bi < numBlocks; ++bi) {
                int bx = bi % blocksX, by = bi / blocksX;
                uint8_t lo = lo_tbl[bi], hi = hi_tbl[bi];
                int cb_idx = (int)lo | ((int)hi << 8);
                const uint8_t* src = codebook.data() + (size_t)cb_idx * cbEntrySize;
                for (int fy = 0; fy < blockH; ++fy)
                    memcpy(framebuf.data() + (size_t)(by*blockH+fy)*vqaW + bx*blockW,
                           src + fy * blockW, blockW);
            }
        });

        // Pass 3: accumulate partial codebook
        iter_sub([&](const uint8_t* shdr, uint32_t ssz, const uint8_t* sbody) {
            if (chunk_eq(shdr, "CBP0")) {
                next_codebook_buffer.insert(next_codebook_buffer.end(),
                                            sbody, sbody + ssz);
                next_cb_idx += ssz;
                if (--partial_countdown <= 0) {
                    size_t n = std::min(next_cb_idx, codebook.size());
                    memcpy(codebook.data(), next_codebook_buffer.data(), n);
                    next_codebook_buffer.clear();
                    next_cb_idx = 0;
                    partial_countdown = cbParts;
                }
            } else if (chunk_eq(shdr, "CBPZ")) {
                next_codebook_buffer.insert(next_codebook_buffer.end(),
                                            sbody, sbody + ssz);
                next_cb_idx += ssz;
                if (--partial_countdown <= 0) {
                    auto dec = lcw_decompress(next_codebook_buffer.data(),
                                              next_codebook_buffer.size(),
                                              codebook.size());
                    if (!dec.empty())
                        memcpy(codebook.data(), dec.data(),
                               std::min(dec.size(), codebook.size()));
                    next_codebook_buffer.clear();
                    next_cb_idx = 0;
                    partial_countdown = cbParts;
                }
            }
        });

        // Handle audio chunks inside VQFR
        iter_sub([&](const uint8_t* shdr, uint32_t ssz, const uint8_t* sbody) {
            if (!has_audio) return;
            if (chunk_eq(shdr, "SND0")) {
                if (audio_bits == 16) {
                    size_t ns = ssz / 2;
                    const int16_t* src = (const int16_t*)sbody;
                    all_audio_pcm.insert(all_audio_pcm.end(), src, src + ns);
                } else {
                    for (uint32_t i = 0; i < ssz; ++i)
                        all_audio_pcm.push_back((int16_t)(((int)sbody[i] - 128) * 256));
                }
            } else if (chunk_eq(shdr, "SND1")) {
                auto pcm = decode_snd1(sbody, ssz);
                all_audio_pcm.insert(all_audio_pcm.end(), pcm.begin(), pcm.end());
            } else if (chunk_eq(shdr, "SND2")) {
                auto pcm = decode_snd2(sbody, ssz, ima_state);
                all_audio_pcm.insert(all_audio_pcm.end(), pcm.begin(), pcm.end());
            }
        });

        // Write PPM frame
        if (palette_set) {
            char ppm_path[512];
            snprintf(ppm_path, sizeof(ppm_path), "%s/frame_%04d.ppm", outdir, frame_num + 1);
            write_ppm(ppm_path, framebuf.data(), palette.data(), vqaW, vqaH);
        }

        frame_num++;
    }

    // Write audio PCM
    if (!all_audio_pcm.empty()) {
        char audio_path[512];
        snprintf(audio_path, sizeof(audio_path), "%s/audio.pcm", outdir);
        FILE* afp = fopen(audio_path, "wb");
        if (afp) {
            fwrite(all_audio_pcm.data(), sizeof(int16_t), all_audio_pcm.size(), afp);
            fclose(afp);
        }
        char wav_path[512];
        snprintf(wav_path, sizeof(wav_path), "%s/audio.wav", outdir);
        write_wav(wav_path, all_audio_pcm.data(), all_audio_pcm.size(),
                  audio_freq, audio_channels);
    }

    // Write metadata
    {
        char meta_path[512];
        snprintf(meta_path, sizeof(meta_path), "%s/metadata.json", outdir);
        FILE* mfp = fopen(meta_path, "w");
        if (mfp) {
            fprintf(mfp, "{\n");
            fprintf(mfp, "  \"width\": %d,\n", vqaW);
            fprintf(mfp, "  \"height\": %d,\n", vqaH);
            fprintf(mfp, "  \"fps\": %d,\n", fps);
            fprintf(mfp, "  \"numFrames\": %d,\n", decode_frames);
            fprintf(mfp, "  \"totalFrames\": %d,\n", numFrames);
            fprintf(mfp, "  \"hasAudio\": %s,\n", has_audio ? "true" : "false");
            fprintf(mfp, "  \"audioFreq\": %d,\n", audio_freq);
            fprintf(mfp, "  \"audioChannels\": %d,\n", audio_channels);
            fprintf(mfp, "  \"audioBits\": %d,\n", audio_bits);
            fprintf(mfp, "  \"audioSamples\": %zu\n", all_audio_pcm.size());
            fprintf(mfp, "}\n");
            fclose(mfp);
        }
    }

    fprintf(stderr, "[VQA] Done: %d frames, %zu audio samples → %s\n",
            frame_num, all_audio_pcm.size(), outdir);

    return 0;
}
