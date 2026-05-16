// TIM-833: Native C++ VQA decoder verification.
// Decodes test.vqa and compares per-frame pixel hashes against known-good values
// from the Python reference decoder (which itself matches ffmpeg).
//
// Build: g++ -std=c++17 -O0 -o test_vqa_native linux/test_vqa_native.cpp
// Run:   ./test_vqa_native e2e/goldens/vqa/test.vqa

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cassert>
#include <vector>
#include <algorithm>

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
// IFF helpers — match vqa_player.cpp
// ---------------------------------------------------------------------------
static bool chunk_eq(const uint8_t* id, const char* tag) {
    return id[0]==(uint8_t)tag[0] && id[1]==(uint8_t)tag[1]
        && id[2]==(uint8_t)tag[2] && id[3]==(uint8_t)tag[3];
}
static uint32_t be32(const uint8_t* p) {
    return ((uint32_t)p[0]<<24)|((uint32_t)p[1]<<16)
         | ((uint32_t)p[2]<< 8)|(uint32_t)p[3];
}
static uint32_t fnv1a(const uint8_t* p, size_t n) {
    uint32_t h = 0x811c9dc5u;
    for (size_t i = 0; i < n; ++i) { h ^= p[i]; h *= 0x01000193u; }
    return h;
}

// ---------------------------------------------------------------------------
// Main test
// ---------------------------------------------------------------------------
int main(int argc, char** argv) {
    const char* path = (argc >= 2) ? argv[1] : "e2e/goldens/vqa/test.vqa";

    FILE* fp = fopen(path, "rb");
    if (!fp) { fprintf(stderr, "FAIL: cannot open %s\n", path); return 1; }

    fseek(fp, 0, SEEK_END);
    long fsize = ftell(fp);
    fseek(fp, 0, SEEK_SET);
    if (fsize < 12) { fprintf(stderr, "FAIL: file too small\n"); fclose(fp); return 1; }

    std::vector<uint8_t> file_data((size_t)fsize);
    fread(file_data.data(), 1, (size_t)fsize, fp);
    fclose(fp);

    const uint8_t* d = file_data.data();
    const uint8_t* d_end = d + file_data.size();

    // Check FORM/WVQA
    if (!chunk_eq(d, "FORM") || !chunk_eq(d+8, "WVQA")) {
        fprintf(stderr, "FAIL: not a WVQA file\n"); return 1;
    }

    size_t pos = 12;

    // Find VQHD and parse header
    int vqaW = 0, vqaH = 0, blockW = 4, blockH = 2, fps = 15;
    int numFrames = 0, cbParts = 1;
    bool has_audio = false;

    while (pos + 8 <= file_data.size()) {
        const uint8_t* chdr = d + pos;
        uint32_t sz = be32(chdr + 4);
        if (chunk_eq(chdr, "VQHD")) {
            // Parse VQHD body (little-endian, packed)
            const uint8_t* body = chdr + 8;
            uint32_t to_read = std::min(sz, (uint32_t)42u);
            if (to_read >= 14) {
                // Fields we need start at offset 0 in body:
                // 0: version(H), 2: flags(H), 4: numFrames(H), 6: width(H), 8: height(H)
                auto le16 = [](const uint8_t* p){ return (uint16_t)p[0] | ((uint16_t)p[1]<<8); };
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
                if (to_read >= 25) {
                    has_audio = (le16(body + 2) & 1) != 0;
                }
            }
            break;
        }
        pos += 8 + sz + (sz & 1);
    }

    if (!vqaW || !vqaH) {
        fprintf(stderr, "FAIL: no valid VQHD\n"); return 1;
    }

    printf("[TEST] %dx%d blk=%dx%d frames=%d cbParts=%d audio=%d\n",
           vqaW, vqaH, blockW, blockH, numFrames, cbParts, has_audio);

    int blocksX   = vqaW / blockW;
    int blocksY   = vqaH / blockH;
    int numBlocks = blocksX * blocksY;
    int cbEntrySize = blockW * blockH;

    // Codebook pre-fill (matches vqa_player.cpp)
    const size_t MAX_CB = 0xFF00u + 0x100u;
    std::vector<uint8_t> codebook(MAX_CB * cbEntrySize, 0);
    for (int ci = 0; ci < 256; ++ci) {
        memset(codebook.data() + (0xFF00u + ci) * cbEntrySize, (uint8_t)ci, cbEntrySize);
        memset(codebook.data() + (0x0F00u + ci) * cbEntrySize, (uint8_t)ci, cbEntrySize);
    }

    std::vector<uint8_t> framebuf((size_t)vqaW * vqaH, 0);
    std::vector<uint8_t> next_codebook_buffer;
    size_t next_cb_idx = 0;
    int partial_countdown = cbParts;

    int pass = 0, fail = 0;

    // Known-good FNV-1a hashes from Python reference decoder (verified against ffmpeg)
    uint32_t expected[3] = {0xa11c51c5u, 0xa379d025u, 0xf1f76b05u};

    // Skip to first VQFR (advance past VQHD + FINF)
    pos = 12;
    bool found_vqhd = false;
    while (pos + 8 <= file_data.size()) {
        const uint8_t* chdr = d + pos;
        uint32_t sz = be32(chdr + 4);
        if (chunk_eq(chdr, "VQHD")) {
            pos += 8 + sz + (sz & 1);
            found_vqhd = true;
            break;
        }
        pos += 8 + sz + (sz & 1);
    }
    (void)found_vqhd;

    // Skip FINF
    if (pos + 8 <= file_data.size()) {
        const uint8_t* chdr = d + pos;
        uint32_t sz = be32(chdr + 4);
        if (chunk_eq(chdr, "FINF"))
            pos += 8 + sz + (sz & 1);
    }

    int frame_num = 0;

    while (frame_num < numFrames && pos + 8 <= file_data.size()) {
        const uint8_t* chdr = d + pos;
        uint32_t chk_sz = be32(chdr + 4);
        pos += 8;

        // Skip audio / non-VQFR chunks
        if (chunk_eq(chdr, "SND0") || chunk_eq(chdr, "SND1") || chunk_eq(chdr, "SND2")) {
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

        // Iterate sub-chunks via lambda (same structure as vqa_player.cpp)
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

        // Pass 1: palette + full codebook
        iter_sub([&](const uint8_t* shdr, uint32_t ssz, const uint8_t* sbody) {
            if (chunk_eq(shdr, "CBF0")) {
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
            std::vector<uint8_t> vpt_dec;
            if (chunk_eq(shdr, "VPTZ") || chunk_eq(shdr, "VPRZ")) {
                vpt_dec = lcw_decompress(sbody, ssz, (size_t)numBlocks * 2);
                if (!vpt_dec.empty()) { vpt = vpt_dec.data(); ssz = (uint32_t)vpt_dec.size(); }
            }
            if (ssz < (uint32_t)numBlocks * 2) return;

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

        // Verify hash
        uint32_t hash = fnv1a(framebuf.data(), framebuf.size());
        uint32_t exp = (frame_num < 3) ? expected[frame_num] : 0;

        if (hash == exp) {
            printf("  frame %d: PASS  hash=0x%08x\n", frame_num + 1, hash);
            pass++;
        } else {
            printf("  frame %d: FAIL  hash=0x%08x  expected=0x%08x\n",
                   frame_num + 1, hash, exp);
            // Dump pixels for diagnosis
            printf("    pixels: ");
            for (size_t pi = 0; pi < framebuf.size() && pi < 64; ++pi)
                printf("%02x", framebuf[pi]);
            printf("\n");
            fail++;
        }

        frame_num++;
    }

    printf("\nDecoded %d/%d frames: %d PASS  %d FAIL\n",
           frame_num, numFrames, pass, fail);

    if (fail > 0) {
        printf("\nFAILURE: %d frame(s) did not match Python/ffmpeg reference\n", fail);
        return 1;
    }
    printf("\nOK: Native C++ VQA decoder matches Python/ffmpeg reference\n");
    return 0;
}
