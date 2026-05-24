/*
 * Poll RA95.EXE's in-process game frame counter under Wine.
 *
 * Usage:
 *   wine ra-frameprobe.exe <target_frame> [addr_hex]
 *   wine ra-frameprobe.exe --state [frame_addr_hex]
 *
 * The default address is the current RA95.EXE candidate for the global
 * `Frame` variable.  This is a diagnostic helper for parity captures.
 */
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <ctype.h>
#include <tlhelp32.h>

static DWORD find_ra_pid(void) {
    HWND hwnd = FindWindowA(NULL, "Red Alert");
    DWORD pid = 0;
    if (hwnd) {
        GetWindowThreadProcessId(hwnd, &pid);
    }
    return pid;
}

static int page_readable(DWORD protect) {
    if (protect & PAGE_GUARD) return 0;
    protect &= 0xff;
    return protect == PAGE_READONLY ||
           protect == PAGE_READWRITE ||
           protect == PAGE_WRITECOPY ||
           protect == PAGE_EXECUTE_READ ||
           protect == PAGE_EXECUTE_READWRITE ||
           protect == PAGE_EXECUTE_WRITECOPY;
}

static void dump_cell_candidate(HANDLE proc, uintptr_t base, int stride) {
    int cells[] = {
        0, 129, 1000, 3000, 5000,
        6098, 6099, 6100,
        6226, 6227, 6228, 6229,
        6354, 6355, 6356, 6357,
        6483, 6484, 6485,
        6611, 6612, 6613
    };
    fprintf(stderr, "cellscan candidate base=0x%08lx stride=%d\n",
            (unsigned long)base, stride);
    for (unsigned i = 0; i < sizeof(cells) / sizeof(cells[0]); i++) {
        unsigned char bytes[96];
        SIZE_T got = 0;
        uintptr_t addr = base + (uintptr_t)cells[i] * (uintptr_t)stride;
        memset(bytes, 0, sizeof(bytes));
        ReadProcessMemory(proc, (LPCVOID)addr, bytes, sizeof(bytes), &got);
        unsigned short id = 0;
        unsigned short flags16 = 0;
        unsigned int flags32 = 0;
        if (got >= 2) memcpy(&id, bytes, 2);
        if (got >= 4) memcpy(&flags16, bytes + 2, 2);
        if (got >= 8) memcpy(&flags32, bytes + 4, 4);
        unsigned short ttype16 = 0xffffu;
        unsigned char ticon18 = 0xffu;
        unsigned short overlay20 = 0xffffu;
        unsigned char overlay22 = 0xffu;
        unsigned short smudge23 = 0xffffu;
        unsigned char smudge25 = 0xffu;
        if (got >= 18) memcpy(&ttype16, bytes + 16, 2);
        if (got >= 19) ticon18 = bytes[18];
        if (got >= 22) memcpy(&overlay20, bytes + 20, 2);
        if (got >= 23) overlay22 = bytes[22];
        if (got >= 25) memcpy(&smudge23, bytes + 23, 2);
        if (got >= 26) smudge25 = bytes[25];
        fprintf(stderr,
                "cellscan cell=%d addr=0x%08lx got=%lu id=%u flags16=0x%04x m16=%u v16=%u "
                "flags32=0x%08x m32=%u v32=%u ttype16=%u ticon18=%u overlay20=%u "
                "overlay22=%u smudge23=%u smudge25=%u bytes=",
                cells[i],
                (unsigned long)addr,
                (unsigned long)got,
                (unsigned)id,
                flags16,
                (flags16 >> 2) & 1u,
                (flags16 >> 3) & 1u,
                flags32,
                (flags32 >> 2) & 1u,
                (flags32 >> 3) & 1u,
                (unsigned)ttype16,
                (unsigned)ticon18,
                (unsigned)overlay20,
                (unsigned)overlay22,
                (unsigned)smudge23,
                (unsigned)smudge25);
        for (unsigned j = 0; j < got && j < 48; j++) {
            fprintf(stderr, "%02x", bytes[j]);
        }
        fprintf(stderr, "\n");
    }
}

static int scan_cells(HANDLE proc) {
    SYSTEM_INFO si;
    GetSystemInfo(&si);
    uintptr_t addr = (uintptr_t)si.lpMinimumApplicationAddress;
    uintptr_t max_addr = (uintptr_t)si.lpMaximumApplicationAddress;
    unsigned char *buf = NULL;
    SIZE_T bufcap = 0;
    int found = 0;

    while (addr < max_addr) {
        MEMORY_BASIC_INFORMATION mbi;
        SIZE_T q = VirtualQueryEx(proc, (LPCVOID)addr, &mbi, sizeof(mbi));
        if (!q) break;

        uintptr_t region_base = (uintptr_t)mbi.BaseAddress;
        SIZE_T region_size = mbi.RegionSize;
        if (mbi.State == MEM_COMMIT && page_readable(mbi.Protect) && region_size >= 0x10000) {
            if (region_size > bufcap) {
                unsigned char *newbuf = (unsigned char *)realloc(buf, region_size);
                if (newbuf) {
                    buf = newbuf;
                    bufcap = region_size;
                }
            }
            if (buf && region_size <= bufcap) {
                SIZE_T got = 0;
                if (ReadProcessMemory(proc, (LPCVOID)region_base, buf, region_size, &got) && got > 0x10000) {
                    for (SIZE_T off = 0; off + 160 * 128 < got; off += 2) {
                        unsigned short first = 0;
                        memcpy(&first, buf + off, 2);
                        if (first != 0) continue;
                        for (int stride = 24; stride <= 192; stride += 2) {
                            if (off + (SIZE_T)127 * (SIZE_T)stride + 2 > got) continue;
                            int ok = 1;
                            for (int i = 1; i < 128; i++) {
                                unsigned short id = 0xffffu;
                                memcpy(&id, buf + off + (SIZE_T)i * stride, 2);
                                if (id != (unsigned short)i) {
                                    ok = 0;
                                    break;
                                }
                            }
                            if (ok) {
                                dump_cell_candidate(proc, region_base + off, stride);
                                found++;
                                if (found >= 8) {
                                    free(buf);
                                    return 0;
                                }
                            }
                        }
                    }
                }
            }
        }
        addr = region_base + region_size;
        if (addr <= region_base) break;
    }
    free(buf);
    fprintf(stderr, "cellscan found=%d\n", found);
    return found ? 0 : 1;
}

static void format_byte_sample(char *out, size_t out_len, unsigned char const *b, SIZE_T got, SIZE_T offset) {
    if (offset < got) {
        snprintf(out, out_len, "%u", (unsigned)b[offset]);
    } else {
        snprintf(out, out_len, "unknown");
    }
}

static int valid_process_offset(int offset, SIZE_T got, SIZE_T needed) {
    if (offset < 0 || needed > got) return 0;
    return (SIZE_T)offset <= got - needed;
}

static void dump_template_candidate(uintptr_t addr, unsigned char const *b, SIZE_T got) {
    short w = 0, h = 0, count = 0, alloc = 0, mapw = 0, maph = 0;
    int old_size = 0, old_icons = 0, old_trans = 0, old_map = 0;
    int new_size = 0, new_icons = 0, new_trans = 0, new_cmap = 0, new_map = 0;
    memcpy(&w, b + 0, 2);
    memcpy(&h, b + 2, 2);
    memcpy(&count, b + 4, 2);
    memcpy(&alloc, b + 6, 2);
    memcpy(&mapw, b + 8, 2);
    memcpy(&maph, b + 10, 2);
    memcpy(&old_size, b + 8, 4);
    memcpy(&old_icons, b + 12, 4);
    memcpy(&old_trans, b + 24, 4);
    memcpy(&old_map, b + 28, 4);
    memcpy(&new_size, b + 12, 4);
    memcpy(&new_icons, b + 16, 4);
    memcpy(&new_trans, b + 28, 4);
    memcpy(&new_cmap, b + 32, 4);
    memcpy(&new_map, b + 36, 4);
    fprintf(stderr,
            "templatescan addr=0x%08lx got=%lu wh=%d,%d count=%d alloc=%d mapwh=%d,%d "
            "old_size=%d old_icons=%d old_trans=%d old_map=%d "
            "new_size=%d new_icons=%d new_trans=%d new_cmap=%d new_map=%d raw=",
            (unsigned long)addr, (unsigned long)got, w, h, count, alloc, mapw, maph,
            old_size, old_icons, old_trans, old_map,
            new_size, new_icons, new_trans, new_cmap, new_map);
    for (unsigned i = 0; i < got && i < 64; i++) fprintf(stderr, "%02x", b[i]);
    fprintf(stderr, "\n");
    if (valid_process_offset(new_icons, got, 3u * 24u * 24u + 32u)) {
        SIZE_T new_icons_off = (SIZE_T)new_icons;
        unsigned char const *icon3 = b + new_icons_off + 3u * 24u * 24u;
        fprintf(stderr, "templatescan icon3_new first32=");
        for (int i = 0; i < 32; i++) fprintf(stderr, "%02x", icon3[i]);
        fprintf(stderr, "\n");
        char icon3_0_4[16], icon3_12_12[16], icon4_0_0[16], icon4_12_12[16], icon8_12_12[16], icon9_0_0[16];
        format_byte_sample(icon3_0_4, sizeof(icon3_0_4), b, got, new_icons_off + 3u * 24u * 24u + 4u * 24u);
        format_byte_sample(icon3_12_12, sizeof(icon3_12_12), b, got, new_icons_off + 3u * 24u * 24u + 12u * 24u + 12u);
        format_byte_sample(icon4_0_0, sizeof(icon4_0_0), b, got, new_icons_off + 4u * 24u * 24u);
        format_byte_sample(icon4_12_12, sizeof(icon4_12_12), b, got, new_icons_off + 4u * 24u * 24u + 12u * 24u + 12u);
        format_byte_sample(icon8_12_12, sizeof(icon8_12_12), b, got, new_icons_off + 8u * 24u * 24u + 12u * 24u + 12u);
        format_byte_sample(icon9_0_0, sizeof(icon9_0_0), b, got, new_icons_off + 9u * 24u * 24u);
        fprintf(stderr,
                "templatescan clear_samples_new icon3_0_4=%s icon3_12_12=%s "
                "icon4_0_0=%s icon4_12_12=%s icon8_12_12=%s icon9_0_0=%s\n",
                icon3_0_4, icon3_12_12, icon4_0_0, icon4_12_12, icon8_12_12, icon9_0_0);
    }
    if (valid_process_offset(old_icons, got, 3u * 24u * 24u + 32u)) {
        SIZE_T old_icons_off = (SIZE_T)old_icons;
        unsigned char const *icon3 = b + old_icons_off + 3u * 24u * 24u;
        fprintf(stderr, "templatescan icon3_old first32=");
        for (int i = 0; i < 32; i++) fprintf(stderr, "%02x", icon3[i]);
        fprintf(stderr, "\n");
    }
}

static int scan_templates(HANDLE proc) {
    SYSTEM_INFO si;
    GetSystemInfo(&si);
    uintptr_t addr = (uintptr_t)si.lpMinimumApplicationAddress;
    uintptr_t max_addr = (uintptr_t)si.lpMaximumApplicationAddress;
    unsigned char *buf = NULL;
    SIZE_T bufcap = 0;
    int found = 0;

    while (addr < max_addr) {
        MEMORY_BASIC_INFORMATION mbi;
        SIZE_T q = VirtualQueryEx(proc, (LPCVOID)addr, &mbi, sizeof(mbi));
        if (!q) break;
        uintptr_t region_base = (uintptr_t)mbi.BaseAddress;
        SIZE_T region_size = mbi.RegionSize;
        if (mbi.State == MEM_COMMIT && page_readable(mbi.Protect) && region_size >= 0x3000) {
            if (region_size > bufcap) {
                unsigned char *newbuf = (unsigned char *)realloc(buf, region_size);
                if (newbuf) {
                    buf = newbuf;
                    bufcap = region_size;
                }
            }
            if (buf && region_size <= bufcap) {
                SIZE_T got = 0;
                if (ReadProcessMemory(proc, (LPCVOID)region_base, buf, region_size, &got) && got > 0x3000) {
                    for (SIZE_T off = 0; off + 0x2600 < got; off++) {
                        if (buf[off] == 0x18 && buf[off+1] == 0x00 &&
                            buf[off+2] == 0x18 && buf[off+3] == 0x00 &&
                            buf[off+4] == 0x14 && buf[off+5] == 0x00 &&
                            buf[off+6] == 0x00 && buf[off+7] == 0x00) {
                            dump_template_candidate(region_base + off, buf + off, got - off);
                            found++;
                            if (found >= 8) {
                                free(buf);
                                return 0;
                            }
                        }
                    }
                }
            }
        }
        addr = region_base + region_size;
        if (addr <= region_base) break;
    }
    free(buf);
    fprintf(stderr, "templatescan found=%d\n", found);
    return found ? 0 : 1;
}

static void format_trans_sample(char *out, size_t out_len, unsigned char const *b, SIZE_T got, unsigned control, unsigned delta) {
    if (control == 0xffu) {
        snprintf(out, out_len, "255");
        return;
    }
    SIZE_T offset = 256u + ((SIZE_T)control << 8) + (SIZE_T)delta;
    if (offset < got) {
        snprintf(out, out_len, "%u", (unsigned)b[offset]);
    } else {
        snprintf(out, out_len, "unknown");
    }
}

static void dump_translucent_candidate(uintptr_t addr, unsigned char const *b, SIZE_T got) {
    char s16_d79[16], s15_d79[16], s16_d137[16], s16_d140[16], s16_d255[16], s14_d79[16], s13_d79[16];
    format_trans_sample(s16_d79, sizeof(s16_d79), b, got, (unsigned)b[16], 79);
    format_trans_sample(s15_d79, sizeof(s15_d79), b, got, (unsigned)b[15], 79);
    format_trans_sample(s16_d137, sizeof(s16_d137), b, got, (unsigned)b[16], 137);
    format_trans_sample(s16_d140, sizeof(s16_d140), b, got, (unsigned)b[16], 140);
    format_trans_sample(s16_d255, sizeof(s16_d255), b, got, (unsigned)b[16], 255);
    format_trans_sample(s14_d79, sizeof(s14_d79), b, got, (unsigned)b[14], 79);
    format_trans_sample(s13_d79, sizeof(s13_d79), b, got, (unsigned)b[13], 79);
    fprintf(stderr,
            "transscan addr=0x%08lx got=%lu control[0]=%u control[15]=%u control[16]=%u "
            "control[13]=%u control[14]=%u samples "
            "s16_d79=%s s15_d79=%s s16_d137=%s s16_d140=%s s16_d255=%s "
            "s15_d79=%s s14_d79=%s s13_d79=%s control_nonff=",
            (unsigned long)addr,
            (unsigned long)got,
            (unsigned)b[0],
            (unsigned)b[15],
            (unsigned)b[16],
            (unsigned)b[13],
            (unsigned)b[14],
            s16_d79, s15_d79, s16_d137, s16_d140, s16_d255,
            s15_d79, s14_d79, s13_d79);
    int listed = 0;
    for (int i = 0; i < 256; i++) {
        if (b[i] != 0xff) {
            fprintf(stderr, "%s%d:%u", listed ? "," : "", i, (unsigned)b[i]);
            listed++;
        }
    }
    fprintf(stderr, "\n");
}

static int scan_translucent_tables(HANDLE proc) {
    SYSTEM_INFO si;
    GetSystemInfo(&si);
    uintptr_t addr = (uintptr_t)si.lpMinimumApplicationAddress;
    uintptr_t max_addr = (uintptr_t)si.lpMaximumApplicationAddress;
    unsigned char *buf = NULL;
    SIZE_T bufcap = 0;
    int found = 0;

    while (addr < max_addr) {
        MEMORY_BASIC_INFORMATION mbi;
        SIZE_T q = VirtualQueryEx(proc, (LPCVOID)addr, &mbi, sizeof(mbi));
        if (!q) break;
        uintptr_t region_base = (uintptr_t)mbi.BaseAddress;
        SIZE_T region_size = mbi.RegionSize;
        if (mbi.State == MEM_COMMIT && page_readable(mbi.Protect) && region_size >= 512) {
            if (region_size > bufcap) {
                unsigned char *newbuf = (unsigned char *)realloc(buf, region_size);
                if (newbuf) {
                    buf = newbuf;
                    bufcap = region_size;
                }
            }
            if (buf && region_size <= bufcap) {
                SIZE_T got = 0;
                if (ReadProcessMemory(proc, (LPCVOID)region_base, buf, region_size, &got) && got >= 512) {
                    for (SIZE_T off = 0; off + 512 <= got; off++) {
                        int nonff = 0;
                        int small = 0;
                        for (int i = 0; i < 256; i++) {
                            if (buf[off + i] != 0xff) {
                                nonff++;
                                if (buf[off + i] < 16) small++;
                            }
                        }
                        if (nonff >= 1 && nonff <= 16 && nonff == small &&
                            buf[off + 16] == 0 && buf[off + 15] == 1) {
                            dump_translucent_candidate(region_base + off, buf + off, got - off);
                            found++;
                            if (found >= 1) {
                                free(buf);
                                return 0;
                            }
                        }
                    }
                }
            }
        }
        addr = region_base + region_size;
        if (addr <= region_base) break;
    }
    free(buf);
    fprintf(stderr, "transscan found=%d\n", found);
    return found ? 0 : 1;
}

static void dump_palette_candidate(uintptr_t addr, unsigned char const *b) {
    fprintf(stderr,
            "palettescan addr=0x%08lx "
            "p0=%u,%u,%u p15=%u,%u,%u p16=%u,%u,%u p21=%u,%u,%u p79=%u,%u,%u "
            "p136=%u,%u,%u p137=%u,%u,%u p140=%u,%u,%u p141=%u,%u,%u p255=%u,%u,%u\n",
            (unsigned long)addr,
            (unsigned)b[0], (unsigned)b[1], (unsigned)b[2],
            (unsigned)b[15 * 3 + 0], (unsigned)b[15 * 3 + 1], (unsigned)b[15 * 3 + 2],
            (unsigned)b[16 * 3 + 0], (unsigned)b[16 * 3 + 1], (unsigned)b[16 * 3 + 2],
            (unsigned)b[21 * 3 + 0], (unsigned)b[21 * 3 + 1], (unsigned)b[21 * 3 + 2],
            (unsigned)b[79 * 3 + 0], (unsigned)b[79 * 3 + 1], (unsigned)b[79 * 3 + 2],
            (unsigned)b[136 * 3 + 0], (unsigned)b[136 * 3 + 1], (unsigned)b[136 * 3 + 2],
            (unsigned)b[137 * 3 + 0], (unsigned)b[137 * 3 + 1], (unsigned)b[137 * 3 + 2],
            (unsigned)b[140 * 3 + 0], (unsigned)b[140 * 3 + 1], (unsigned)b[140 * 3 + 2],
            (unsigned)b[141 * 3 + 0], (unsigned)b[141 * 3 + 1], (unsigned)b[141 * 3 + 2],
            (unsigned)b[255 * 3 + 0], (unsigned)b[255 * 3 + 1], (unsigned)b[255 * 3 + 2]);
}

static int scan_palettes(HANDLE proc) {
    SYSTEM_INFO si;
    GetSystemInfo(&si);
    uintptr_t addr = (uintptr_t)si.lpMinimumApplicationAddress;
    uintptr_t max_addr = (uintptr_t)si.lpMaximumApplicationAddress;
    unsigned char *buf = NULL;
    SIZE_T bufcap = 0;
    int found = 0;

    while (addr < max_addr) {
        MEMORY_BASIC_INFORMATION mbi;
        SIZE_T q = VirtualQueryEx(proc, (LPCVOID)addr, &mbi, sizeof(mbi));
        if (!q) break;
        uintptr_t region_base = (uintptr_t)mbi.BaseAddress;
        SIZE_T region_size = mbi.RegionSize;
        if (mbi.State == MEM_COMMIT && page_readable(mbi.Protect) && region_size >= 768) {
            if (region_size > bufcap) {
                unsigned char *newbuf = (unsigned char *)realloc(buf, region_size);
                if (newbuf) {
                    buf = newbuf;
                    bufcap = region_size;
                }
            }
            if (buf && region_size <= bufcap) {
                SIZE_T got = 0;
                if (ReadProcessMemory(proc, (LPCVOID)region_base, buf, region_size, &got) && got >= 768) {
                    for (SIZE_T off = 0; off + 768 <= got; off++) {
                        int high = 0;
                        int nonzero = 0;
                        for (int i = 0; i < 768; i++) {
                            if (buf[off + i] > 63) high++;
                            if (buf[off + i] != 0) nonzero++;
                        }
                        if (high == 0 && nonzero > 128 &&
                            buf[off + 79 * 3 + 0] == 57 &&
                            buf[off + 79 * 3 + 1] == 54 &&
                            buf[off + 79 * 3 + 2] == 57 &&
                            buf[off + 13 * 3 + 0] == 21 &&
                            buf[off + 13 * 3 + 1] == 21 &&
                            buf[off + 13 * 3 + 2] == 21 &&
                            buf[off + 14 * 3 + 0] == 42 &&
                            buf[off + 14 * 3 + 1] == 42 &&
                            buf[off + 14 * 3 + 2] == 42) {
                            dump_palette_candidate(region_base + off, buf + off);
                            found++;
                            if (found >= 64) {
                                free(buf);
                                return 0;
                            }
                        }
                    }
                }
            }
        }
        addr = region_base + region_size;
        if (addr <= region_base) break;
    }
    free(buf);
    fprintf(stderr, "palettescan found=%d\n", found);
    return found ? 0 : 1;
}

static int scan_screen_buffers(HANDLE proc) {
    SYSTEM_INFO si;
    GetSystemInfo(&si);
    uintptr_t addr = (uintptr_t)si.lpMinimumApplicationAddress;
    uintptr_t max_addr = (uintptr_t)si.lpMaximumApplicationAddress;
    unsigned char *buf = NULL;
    SIZE_T bufcap = 0;
    int found = 0;

    struct Probe { int x, y; unsigned char wine, native; };
    static const struct Probe probes[] = {
        {532,154,139,134},
        {533,154,138,14},
        {535,156,138,14},
        {577,154,134,128},
        {578,155,135,129},
        {580,156,68,228},
        {622,154,136,227},
        {624,155,136,130},
        {625,156,68,228},
    };
    static const struct Probe shadow_probes[] = {
        {313,16,0,0},
        {466,24,0,0},
        {282,70,0,0},
        {272,91,0,0},
        {262,113,0,0},
        {447,185,0,0},
        {406,228,0,0},
    };

    while (addr < max_addr) {
        MEMORY_BASIC_INFORMATION mbi;
        SIZE_T q = VirtualQueryEx(proc, (LPCVOID)addr, &mbi, sizeof(mbi));
        if (!q) break;
        uintptr_t region_base = (uintptr_t)mbi.BaseAddress;
        SIZE_T region_size = mbi.RegionSize;
        if (mbi.State == MEM_COMMIT && page_readable(mbi.Protect) && region_size >= 640u * 360u) {
            if (region_size > bufcap) {
                unsigned char *newbuf = (unsigned char *)realloc(buf, region_size);
                if (newbuf) {
                    buf = newbuf;
                    bufcap = region_size;
                }
            }
            if (buf && region_size <= bufcap) {
                SIZE_T got = 0;
                if (ReadProcessMemory(proc, (LPCVOID)region_base, buf, region_size, &got) && got >= 640u * 360u) {
                    for (int stride = 640; stride <= 1024; stride += 4) {
                        SIZE_T anchor_delta = (SIZE_T)154 * (SIZE_T)stride + 532u;
                        for (SIZE_T p = 0; p + 2 < got; p++) {
                            if (!((buf[p] == 139 && buf[p + 1] == 138) ||
                                  (buf[p] == 134 && buf[p + 1] == 14))) {
                                continue;
                            }
                            if (p < anchor_delta) continue;
                            SIZE_T off = p - anchor_delta;
                            SIZE_T max_probe = off + (SIZE_T)399 * (SIZE_T)stride + 639u;
                            if (max_probe >= got) continue;

                            int wine = 0;
                            int native = 0;
                            int mixed = 0;
                            for (unsigned i = 0; i < sizeof(probes) / sizeof(probes[0]); i++) {
                                unsigned char v = buf[off + (SIZE_T)probes[i].y * (SIZE_T)stride + probes[i].x];
                                if (v == probes[i].wine) wine++;
                                if (v == probes[i].native) native++;
                                if (v == probes[i].wine || v == probes[i].native) mixed++;
                            }
                            if (wine >= 7 || native >= 7 || mixed == (int)(sizeof(probes) / sizeof(probes[0]))) {
                                fprintf(stderr,
                                        "screenbuf candidate addr=0x%08lx stride=%d wine=%d native=%d mixed=%d values=",
                                        (unsigned long)(region_base + off), stride, wine, native, mixed);
                                for (unsigned i = 0; i < sizeof(probes) / sizeof(probes[0]); i++) {
                                    unsigned char v = buf[off + (SIZE_T)probes[i].y * (SIZE_T)stride + probes[i].x];
                                    fprintf(stderr, "%s%d,%d:%u", i ? "," : "", probes[i].x, probes[i].y, (unsigned)v);
                                }
                                fprintf(stderr, " shadow=");
                                for (unsigned i = 0; i < sizeof(shadow_probes) / sizeof(shadow_probes[0]); i++) {
                                    unsigned char v = buf[off + (SIZE_T)shadow_probes[i].y * (SIZE_T)stride + shadow_probes[i].x];
                                    fprintf(stderr, "%s%d,%d:%u", i ? "," : "", shadow_probes[i].x, shadow_probes[i].y, (unsigned)v);
                                }
                                fprintf(stderr, "\n");
                                found++;
                                if (found >= 32) {
                                    free(buf);
                                    return 0;
                                }
                            }
                        }
                    }
                }
            }
        }
        addr = region_base + region_size;
        if (addr <= region_base) break;
    }
    free(buf);
    fprintf(stderr, "screenbuf found=%d\n", found);
    return found ? 0 : 1;
}

static int scan_sidebar_top_shape_buffers(HANDLE proc) {
    SYSTEM_INFO si;
    GetSystemInfo(&si);
    uintptr_t addr = (uintptr_t)si.lpMinimumApplicationAddress;
    uintptr_t max_addr = (uintptr_t)si.lpMaximumApplicationAddress;
    unsigned char *buf = NULL;
    SIZE_T bufcap = 0;
    int found = 0;

    struct Probe { int x, y; unsigned char wine, native; };
    static const struct Probe probes[] = {
        {52,138,139,134},
        {53,138,138,14},
        {55,140,138,14},
        {97,138,134,128},
        {98,139,135,129},
        {100,140,68,228},
        {142,138,136,227},
        {144,139,136,130},
        {145,140,68,228},
    };

    while (addr < max_addr) {
        MEMORY_BASIC_INFORMATION mbi;
        SIZE_T q = VirtualQueryEx(proc, (LPCVOID)addr, &mbi, sizeof(mbi));
        if (!q) break;
        uintptr_t region_base = (uintptr_t)mbi.BaseAddress;
        SIZE_T region_size = mbi.RegionSize;
        if (mbi.State == MEM_COMMIT && page_readable(mbi.Protect) && region_size >= 160u * 141u) {
            if (region_size > bufcap) {
                unsigned char *newbuf = (unsigned char *)realloc(buf, region_size);
                if (newbuf) {
                    buf = newbuf;
                    bufcap = region_size;
                }
            }
            if (buf && region_size <= bufcap) {
                SIZE_T got = 0;
                if (ReadProcessMemory(proc, (LPCVOID)region_base, buf, region_size, &got) && got >= 160u * 141u) {
                    SIZE_T anchor_delta = (SIZE_T)138 * 160u + 52u;
                    for (SIZE_T p = 0; p + 2 < got; p++) {
                        if (!((buf[p] == 139 && buf[p + 1] == 138) ||
                              (buf[p] == 134 && buf[p + 1] == 14))) {
                            continue;
                        }
                        if (p < anchor_delta) continue;
                        SIZE_T off = p - anchor_delta;
                        SIZE_T max_probe = off + (SIZE_T)140 * 160u + 159u;
                        if (max_probe >= got) continue;
                        int wine = 0;
                        int native = 0;
                        int mixed = 0;
                        for (unsigned i = 0; i < sizeof(probes) / sizeof(probes[0]); i++) {
                            unsigned char v = buf[off + (SIZE_T)probes[i].y * 160u + probes[i].x];
                            if (v == probes[i].wine) wine++;
                            if (v == probes[i].native) native++;
                            if (v == probes[i].wine || v == probes[i].native) mixed++;
                        }
                        if (wine >= 7 || native >= 7 || mixed == (int)(sizeof(probes) / sizeof(probes[0]))) {
                            unsigned long h0 = 0, h1 = 0, h2 = 0;
                            SIZE_T hgot = 0;
                            uintptr_t raw_addr = region_base + off;
                            if (raw_addr >= 156) {
                                ReadProcessMemory(proc, (LPCVOID)(raw_addr - 156), &h0, sizeof(h0), &hgot);
                                ReadProcessMemory(proc, (LPCVOID)(raw_addr - 152), &h1, sizeof(h1), &hgot);
                                ReadProcessMemory(proc, (LPCVOID)(raw_addr - 148), &h2, sizeof(h2), &hgot);
                            }
                            fprintf(stderr,
                                    "sidebartop candidate addr=0x%08lx hdr156=%08lx,%08lx,%08lx wine=%d native=%d mixed=%d values=",
                                    (unsigned long)(region_base + off), h0, h1, h2, wine, native, mixed);
                            for (unsigned i = 0; i < sizeof(probes) / sizeof(probes[0]); i++) {
                                unsigned char v = buf[off + (SIZE_T)probes[i].y * 160u + probes[i].x];
                                fprintf(stderr, "%s%d,%d:%u", i ? "," : "", probes[i].x, probes[i].y, (unsigned)v);
                            }
                            fprintf(stderr, "\n");
                            found++;
                            if (found >= 32) {
                                free(buf);
                                return 0;
                            }
                        }
                    }
                }
            }
        }
        addr = region_base + region_size;
        if (addr <= region_base) break;
    }
    free(buf);
    fprintf(stderr, "sidebartop found=%d\n", found);
    return found ? 0 : 1;
}

static int read_dword(HANDLE proc, DWORD addr, DWORD *value) {
    SIZE_T got = 0;
    *value = 0;
    return ReadProcessMemory(proc, (LPCVOID)(uintptr_t)addr, value, sizeof(*value), &got) &&
           got == sizeof(*value);
}

static int wait_for_frame(HANDLE proc, DWORD frame_addr, long target) {
    DWORD value = 0;
    DWORD last = 0xffffffffu;
    int max_polls = 3000;
    const char *max_env = getenv("RA_FRAMEPROBE_MAX_POLLS");
    if (max_env && max_env[0]) {
        int parsed = atoi(max_env);
        if (parsed > 0) max_polls = parsed;
    }
    for (int i = 0; i < max_polls; i++) {
        SIZE_T got = 0;
        if (!ReadProcessMemory(proc, (LPCVOID)(uintptr_t)frame_addr, &value, sizeof(value), &got) || got != sizeof(value)) {
            fprintf(stderr, "ReadProcessMemory addr=0x%08lx failed err=%lu got=%lu\n",
                    (unsigned long)frame_addr, GetLastError(), (unsigned long)got);
            return 1;
        }
        if (value != last) {
            fprintf(stderr, "frameprobe wait addr=0x%08lx value=%lu target=%ld\n",
                    (unsigned long)frame_addr, (unsigned long)value, target);
            last = value;
        }
        if ((long)value >= target) return 0;
        Sleep(10);
    }
    fprintf(stderr, "timeout waiting for frame %ld; last=%lu addr=0x%08lx\n",
            target, (unsigned long)value, (unsigned long)frame_addr);
    return 1;
}

static void dump_scan_match(uintptr_t addr, unsigned char const *bytes, SIZE_T got, SIZE_T hit_off) {
    SIZE_T start = hit_off >= 64 ? hit_off - 64 : 0;
    SIZE_T end = hit_off + 128;
    if (end > got) end = got;
    fprintf(stderr, "dwordscan match addr=0x%08lx hit_offset=%lu bytes=",
            (unsigned long)addr, (unsigned long)hit_off);
    for (SIZE_T i = start; i < end; i++) {
        fprintf(stderr, "%02x", bytes[i]);
    }
    fprintf(stderr, " dwords=");
    for (SIZE_T i = start; i + 4 <= end; i += 4) {
        DWORD v = 0;
        memcpy(&v, bytes + i, sizeof(v));
        fprintf(stderr, "%s%+ld:0x%08lx", i == start ? "" : ",",
                (long)i - (long)hit_off, (unsigned long)v);
    }
    fprintf(stderr, "\n");
}

static int scan_dword_value(HANDLE proc, DWORD value, int max_matches) {
    SYSTEM_INFO si;
    GetSystemInfo(&si);
    uintptr_t addr = (uintptr_t)si.lpMinimumApplicationAddress;
    uintptr_t max_addr = (uintptr_t)si.lpMaximumApplicationAddress;
    unsigned char *buf = NULL;
    SIZE_T bufcap = 0;
    int found = 0;

    while (addr < max_addr) {
        MEMORY_BASIC_INFORMATION mbi;
        SIZE_T q = VirtualQueryEx(proc, (LPCVOID)addr, &mbi, sizeof(mbi));
        if (!q) break;
        uintptr_t region_base = (uintptr_t)mbi.BaseAddress;
        SIZE_T region_size = mbi.RegionSize;
        if (mbi.State == MEM_COMMIT && page_readable(mbi.Protect) && region_size >= 4) {
            if (region_size > bufcap) {
                unsigned char *newbuf = (unsigned char *)realloc(buf, region_size);
                if (newbuf) {
                    buf = newbuf;
                    bufcap = region_size;
                }
            }
            if (buf && region_size <= bufcap) {
                SIZE_T got = 0;
                if (ReadProcessMemory(proc, (LPCVOID)region_base, buf, region_size, &got) && got >= 4) {
                    for (SIZE_T off = 0; off + 4 <= got; off++) {
                        DWORD got_value = 0;
                        memcpy(&got_value, buf + off, sizeof(got_value));
                        if (got_value != value) continue;
                        dump_scan_match(region_base + off, buf, got, off);
                        found++;
                        if (found >= max_matches) {
                            free(buf);
                            fprintf(stderr, "dwordscan value=0x%08lx found=%d capped=1\n",
                                    (unsigned long)value, found);
                            return 0;
                        }
                    }
                }
            }
        }
        addr = region_base + region_size;
        if (addr <= region_base) break;
    }
    free(buf);
    fprintf(stderr, "dwordscan value=0x%08lx found=%d capped=0\n",
            (unsigned long)value, found);
    return found ? 0 : 1;
}

static int scan_word_pair(HANDLE proc, WORD a, WORD b, int window, int max_matches) {
    SYSTEM_INFO si;
    GetSystemInfo(&si);
    uintptr_t addr = (uintptr_t)si.lpMinimumApplicationAddress;
    uintptr_t max_addr = (uintptr_t)si.lpMaximumApplicationAddress;
    unsigned char *buf = NULL;
    SIZE_T bufcap = 0;
    int found = 0;

    while (addr < max_addr) {
        MEMORY_BASIC_INFORMATION mbi;
        SIZE_T q = VirtualQueryEx(proc, (LPCVOID)addr, &mbi, sizeof(mbi));
        if (!q) break;
        uintptr_t region_base = (uintptr_t)mbi.BaseAddress;
        SIZE_T region_size = mbi.RegionSize;
        if (mbi.State == MEM_COMMIT && page_readable(mbi.Protect) && region_size >= 4) {
            if (region_size > bufcap) {
                unsigned char *newbuf = (unsigned char *)realloc(buf, region_size);
                if (newbuf) {
                    buf = newbuf;
                    bufcap = region_size;
                }
            }
            if (buf && region_size <= bufcap) {
                SIZE_T got = 0;
                if (ReadProcessMemory(proc, (LPCVOID)region_base, buf, region_size, &got) && got >= 4) {
                    for (SIZE_T off = 0; off + 2 <= got; off++) {
                        WORD got_a = 0;
                        memcpy(&got_a, buf + off, sizeof(got_a));
                        if (got_a != a) continue;
                        SIZE_T limit = off + (SIZE_T)window;
                        if (limit > got - 2) limit = got - 2;
                        for (SIZE_T off2 = off; off2 <= limit; off2++) {
                            WORD got_b = 0;
                            memcpy(&got_b, buf + off2, sizeof(got_b));
                            if (got_b != b) continue;
                            fprintf(stderr,
                                    "wordpair match addr=0x%08lx a_off=0 b_off=%ld a=0x%04x b=0x%04x ",
                                    (unsigned long)(region_base + off),
                                    (long)off2 - (long)off,
                                    (unsigned)a,
                                    (unsigned)b);
                            dump_scan_match(region_base + off, buf, got, off);
                            found++;
                            if (found >= max_matches) {
                                free(buf);
                                fprintf(stderr, "wordpair a=0x%04x b=0x%04x found=%d capped=1\n",
                                        (unsigned)a, (unsigned)b, found);
                                return 0;
                            }
                        }
                    }
                }
            }
        }
        addr = region_base + region_size;
        if (addr <= region_base) break;
    }
    free(buf);
    fprintf(stderr, "wordpair a=0x%04x b=0x%04x found=%d capped=0\n",
            (unsigned)a, (unsigned)b, found);
    return found ? 0 : 1;
}

static int scan_coord_range(HANDLE proc, WORD xmin, WORD xmax, WORD ymin, WORD ymax, uintptr_t min_scan_addr, uintptr_t max_scan_addr, int max_matches) {
    SYSTEM_INFO si;
    GetSystemInfo(&si);
    uintptr_t addr = (uintptr_t)si.lpMinimumApplicationAddress;
    uintptr_t max_addr = (uintptr_t)si.lpMaximumApplicationAddress;
    if (max_scan_addr != 0 && max_scan_addr < max_addr) {
        max_addr = max_scan_addr;
    }
    unsigned char *buf = NULL;
    SIZE_T bufcap = 0;
    int found = 0;

    while (addr < max_addr) {
        MEMORY_BASIC_INFORMATION mbi;
        SIZE_T q = VirtualQueryEx(proc, (LPCVOID)addr, &mbi, sizeof(mbi));
        if (!q) break;
        uintptr_t region_base = (uintptr_t)mbi.BaseAddress;
        SIZE_T region_size = mbi.RegionSize;
        uintptr_t region_end = region_base + region_size;
        if (region_end <= region_base) break;
        if (region_base + region_size <= min_scan_addr) {
            addr = region_end;
            continue;
        }
        if (region_base >= max_addr) break;
        if (mbi.State == MEM_COMMIT && page_readable(mbi.Protect) && region_size >= 4) {
            if (region_size > bufcap) {
                unsigned char *newbuf = (unsigned char *)realloc(buf, region_size);
                if (newbuf) {
                    buf = newbuf;
                    bufcap = region_size;
                }
            }
            if (buf && region_size <= bufcap) {
                SIZE_T got = 0;
                if (ReadProcessMemory(proc, (LPCVOID)region_base, buf, region_size, &got) && got >= 4) {
                    SIZE_T scan_start = 0;
                    SIZE_T scan_end = got;
                    if (region_base < min_scan_addr) {
                        scan_start = (SIZE_T)(min_scan_addr - region_base);
                    }
                    if (region_base + scan_end > max_addr) {
                        scan_end = (SIZE_T)(max_addr - region_base);
                    }
                    for (SIZE_T off = scan_start; off + 4 <= scan_end; off++) {
                        DWORD coord = 0;
                        memcpy(&coord, buf + off, sizeof(coord));
                        WORD x = (WORD)(coord & 0xffffu);
                        WORD y = (WORD)((coord >> 16) & 0xffffu);
                        if (x < xmin || x > xmax || y < ymin || y > ymax) continue;
                        fprintf(stderr,
                                "coordscan addr=0x%08lx coord=0x%08lx x=%u y=%u ",
                                (unsigned long)(region_base + off),
                                (unsigned long)coord,
                                (unsigned)x,
                                (unsigned)y);
                        dump_scan_match(region_base + off, buf, got, off);
                        found++;
                        if (found >= max_matches) {
                            free(buf);
                            fprintf(stderr,
                                    "coordscan xrange=0x%04x-0x%04x yrange=0x%04x-0x%04x minaddr=0x%08lx maxaddr=0x%08lx found=%d capped=1\n",
                                    (unsigned)xmin, (unsigned)xmax, (unsigned)ymin, (unsigned)ymax,
                                    (unsigned long)min_scan_addr, (unsigned long)max_addr, found);
                            return 0;
                        }
                    }
                }
            }
        }
        addr = region_end;
    }
    free(buf);
    fprintf(stderr,
            "coordscan xrange=0x%04x-0x%04x yrange=0x%04x-0x%04x minaddr=0x%08lx maxaddr=0x%08lx found=%d capped=0\n",
            (unsigned)xmin, (unsigned)xmax, (unsigned)ymin, (unsigned)ymax,
            (unsigned long)min_scan_addr, (unsigned long)max_addr, found);
    return found ? 0 : 1;
}

static int suspend_process_threads(DWORD pid) {
    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0);
    THREADENTRY32 te;
    int count = 0;
    if (snap == INVALID_HANDLE_VALUE) return 0;
    memset(&te, 0, sizeof(te));
    te.dwSize = sizeof(te);
    if (Thread32First(snap, &te)) {
        do {
            if (te.th32OwnerProcessID != pid) continue;
            HANDLE thread = OpenThread(THREAD_SUSPEND_RESUME, FALSE, te.th32ThreadID);
            if (!thread) continue;
            if (SuspendThread(thread) != (DWORD)-1) count++;
            CloseHandle(thread);
        } while (Thread32Next(snap, &te));
    }
    CloseHandle(snap);
    fprintf(stderr, "frameprobe suspended pid=%lu threads=%d\n", (unsigned long)pid, count);
    return count;
}

static int resume_process_threads(DWORD pid) {
    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0);
    THREADENTRY32 te;
    int count = 0;
    if (snap == INVALID_HANDLE_VALUE) return 0;
    memset(&te, 0, sizeof(te));
    te.dwSize = sizeof(te);
    if (Thread32First(snap, &te)) {
        do {
            if (te.th32OwnerProcessID != pid) continue;
            HANDLE thread = OpenThread(THREAD_SUSPEND_RESUME, FALSE, te.th32ThreadID);
            if (!thread) continue;
            while (ResumeThread(thread) > 0) count++;
            CloseHandle(thread);
        } while (Thread32Next(snap, &te));
    }
    CloseHandle(snap);
    fprintf(stderr, "frameprobe resumed pid=%lu resumes=%d\n", (unsigned long)pid, count);
    return count;
}

static int valid_scenario_char(unsigned char c) {
    return isalnum(c) || c == '.' || c == '_' || c == '-';
}

static int looks_like_ra_scenario(unsigned char const *s, SIZE_T n) {
    if (n < 12) return 0;
    if (toupper(s[0]) != 'S' || toupper(s[1]) != 'C') return 0;
    if (toupper(s[2]) != 'G' && toupper(s[2]) != 'U' && toupper(s[2]) != 'M') return 0;
    if (!isdigit(s[3]) || !isdigit(s[4])) return 0;
    if (toupper(s[5]) != 'E') return 0;
    if (!isalpha(s[6])) return 0;
    if (s[7] != '.') return 0;
    if (toupper(s[8]) != 'I' || toupper(s[9]) != 'N' || toupper(s[10]) != 'I') return 0;
    if (s[11] != 0 && !isspace(s[11]) && !valid_scenario_char(s[11])) return 0;
    return 1;
}

static int find_scenario_string(HANDLE proc, char *out, size_t out_len, DWORD *out_addr) {
    SYSTEM_INFO si;
    GetSystemInfo(&si);
    uintptr_t addr = (uintptr_t)si.lpMinimumApplicationAddress;
    uintptr_t max_addr = (uintptr_t)si.lpMaximumApplicationAddress;
    unsigned char *buf = NULL;
    SIZE_T bufcap = 0;

    if (out_len == 0) return 0;
    out[0] = 0;
    *out_addr = 0;

    while (addr < max_addr) {
        MEMORY_BASIC_INFORMATION mbi;
        SIZE_T q = VirtualQueryEx(proc, (LPCVOID)addr, &mbi, sizeof(mbi));
        if (!q) break;

        uintptr_t region_base = (uintptr_t)mbi.BaseAddress;
        SIZE_T region_size = mbi.RegionSize;
        if (mbi.State == MEM_COMMIT && page_readable(mbi.Protect) && region_size >= 12) {
            if (region_size > bufcap) {
                unsigned char *newbuf = (unsigned char *)realloc(buf, region_size);
                if (newbuf) {
                    buf = newbuf;
                    bufcap = region_size;
                }
            }
            if (buf && region_size <= bufcap) {
                SIZE_T got = 0;
                if (ReadProcessMemory(proc, (LPCVOID)region_base, buf, region_size, &got) && got >= 12) {
                    for (SIZE_T off = 0; off + 12 <= got; off++) {
                        if (!looks_like_ra_scenario(buf + off, got - off)) continue;
                        size_t len = 0;
                        while (len + 1 < out_len && off + len < got &&
                               valid_scenario_char(buf[off + len])) {
                            out[len] = (char)toupper(buf[off + len]);
                            len++;
                        }
                        out[len] = 0;
                        *out_addr = (DWORD)(region_base + off);
                        free(buf);
                        return 1;
                    }
                }
            }
        }
        addr = region_base + region_size;
        if (addr <= region_base) break;
    }
    free(buf);
    return 0;
}

static int dump_state(HANDLE proc, DWORD pid, DWORD frame_addr) {
    static const DWORD frame_candidates[] = {
        0x00642080, 0x0066B68C, 0x006544C8, 0x00655D18,
        0x005EC258, 0x0068DEA0, 0x0069720C, 0x0069C41C,
        0x0069C468, 0x0069C488, 0x005F166C, 0x006D7344
    };
    DWORD frame = 0;
    char scenario[32];
    DWORD scenario_addr = 0;
    int has_frame = read_dword(proc, frame_addr, &frame);
    int has_scenario = find_scenario_string(proc, scenario, sizeof(scenario), &scenario_addr);

    printf("state ");
    if (has_scenario) {
        printf("scenario=%s ", scenario);
    } else {
        printf("scenario=unknown ");
    }
    if (has_frame) {
        printf("frame=%lu ", (unsigned long)frame);
    } else {
        printf("frame=unknown ");
    }
    printf("player_wins=unknown player_loses=unknown session=unknown ");
    printf("PlayerWins=unknown PlayerLoses=unknown Session.Type=unknown ");
    printf("player=unknown defeated=unknown ");
    printf("pid=%lu frame_addr=0x%08lx ", (unsigned long)pid, (unsigned long)frame_addr);
    for (unsigned i = 0; i < sizeof(frame_candidates) / sizeof(frame_candidates[0]); ++i) {
        DWORD value = 0;
        if (read_dword(proc, frame_candidates[i], &value)) {
            printf("cand_%08lx=%lu ", (unsigned long)frame_candidates[i], (unsigned long)value);
        }
    }
    if (has_scenario) {
        printf("scenario_addr=0x%08lx", (unsigned long)scenario_addr);
    } else {
        printf("scenario_addr=unknown");
    }
    printf("\n");
    fflush(stdout);
    return 0;
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s <target_frame>|--state [addr_hex]|--scan-dword <value> [max]|--wait-scan-dword <frame> <value> [max]|--wait-scan-wordpair <frame> <a> <b> [window] [max]|--wait-scan-coords <frame> <xmin> <xmax> <ymin> <ymax> [max] [minaddr] [maxaddr]\n", argv[0]);
        return 2;
    }

    int state_mode = strcmp(argv[1], "--state") == 0;
    int scan_dword_mode = strcmp(argv[1], "--scan-dword") == 0;
    int wait_scan_dword_mode = strcmp(argv[1], "--wait-scan-dword") == 0;
    int wait_scan_wordpair_mode = strcmp(argv[1], "--wait-scan-wordpair") == 0;
    int wait_scan_coords_mode = strcmp(argv[1], "--wait-scan-coords") == 0;
    long target = state_mode ? -8 : strtol(argv[1], NULL, 0);
    DWORD addr = (argc > 2 && !scan_dword_mode && !wait_scan_dword_mode && !wait_scan_wordpair_mode && !wait_scan_coords_mode)
        ? (DWORD)strtoul(argv[2], NULL, 0)
        : 0x006544c8u;
    DWORD pid = 0;

    for (int i = 0; i < 300 && pid == 0; i++) {
        pid = find_ra_pid();
        if (pid == 0) Sleep(100);
    }
    if (pid == 0) {
        fprintf(stderr, "no Red Alert window/process found\n");
        return 1;
    }

    HANDLE proc = OpenProcess(PROCESS_VM_READ | PROCESS_QUERY_INFORMATION, FALSE, pid);
    if (!proc) {
        fprintf(stderr, "OpenProcess pid=%lu failed err=%lu\n", (unsigned long)pid, GetLastError());
        return 1;
    }

    if (target == -2) {
        int rc = scan_cells(proc);
        CloseHandle(proc);
        return rc;
    }
    if (target == -3) {
        int rc = scan_templates(proc);
        CloseHandle(proc);
        return rc;
    }
    if (target == -4) {
        int rc = scan_translucent_tables(proc);
        CloseHandle(proc);
        return rc;
    }
    if (target == -5) {
        int rc = scan_palettes(proc);
        CloseHandle(proc);
        return rc;
    }
    if (target == -6) {
        int rc = scan_screen_buffers(proc);
        CloseHandle(proc);
        return rc;
    }
    if (target == -7) {
        int rc = scan_sidebar_top_shape_buffers(proc);
        CloseHandle(proc);
        return rc;
    }
    if (target == -8) {
        int rc = dump_state(proc, pid, addr);
        CloseHandle(proc);
        return rc;
    }
    if (scan_dword_mode) {
        DWORD value = (argc > 2) ? (DWORD)strtoul(argv[2], NULL, 0) : 0;
        int max_matches = (argc > 3) ? atoi(argv[3]) : 128;
        if (max_matches <= 0) max_matches = 128;
        int rc = scan_dword_value(proc, value, max_matches);
        CloseHandle(proc);
        return rc;
    }
    if (wait_scan_dword_mode) {
        long wait_frame = (argc > 2) ? strtol(argv[2], NULL, 0) : 0;
        DWORD value = (argc > 3) ? (DWORD)strtoul(argv[3], NULL, 0) : 0;
        int max_matches = (argc > 4) ? atoi(argv[4]) : 128;
        if (max_matches <= 0) max_matches = 128;
        int rc = wait_for_frame(proc, addr, wait_frame);
        int suspended = 0;
        if (rc == 0) {
            suspended = suspend_process_threads(pid);
            rc = scan_dword_value(proc, value, max_matches);
        }
        if (suspended > 0) resume_process_threads(pid);
        CloseHandle(proc);
        return rc;
    }
    if (wait_scan_wordpair_mode) {
        long wait_frame = (argc > 2) ? strtol(argv[2], NULL, 0) : 0;
        WORD a = (argc > 3) ? (WORD)strtoul(argv[3], NULL, 0) : 0;
        WORD b = (argc > 4) ? (WORD)strtoul(argv[4], NULL, 0) : 0;
        int window = (argc > 5) ? atoi(argv[5]) : 96;
        int max_matches = (argc > 6) ? atoi(argv[6]) : 128;
        if (window < 0) window = 96;
        if (max_matches <= 0) max_matches = 128;
        int rc = wait_for_frame(proc, addr, wait_frame);
        int suspended = 0;
        if (rc == 0) {
            suspended = suspend_process_threads(pid);
            rc = scan_word_pair(proc, a, b, window, max_matches);
        }
        if (suspended > 0) resume_process_threads(pid);
        CloseHandle(proc);
        return rc;
    }
    if (wait_scan_coords_mode) {
        long wait_frame = (argc > 2) ? strtol(argv[2], NULL, 0) : 0;
        WORD xmin = (argc > 3) ? (WORD)strtoul(argv[3], NULL, 0) : 0;
        WORD xmax = (argc > 4) ? (WORD)strtoul(argv[4], NULL, 0) : 0xffffu;
        WORD ymin = (argc > 5) ? (WORD)strtoul(argv[5], NULL, 0) : 0;
        WORD ymax = (argc > 6) ? (WORD)strtoul(argv[6], NULL, 0) : 0xffffu;
        int max_matches = (argc > 7) ? atoi(argv[7]) : 128;
        uintptr_t min_scan_addr = (argc > 8) ? (uintptr_t)strtoul(argv[8], NULL, 0) : 0;
        uintptr_t max_scan_addr = (argc > 9) ? (uintptr_t)strtoul(argv[9], NULL, 0) : 0;
        if (max_matches <= 0) max_matches = 128;
        int rc = wait_for_frame(proc, addr, wait_frame);
        int suspended = 0;
        if (rc == 0) {
            suspended = suspend_process_threads(pid);
            rc = scan_coord_range(proc, xmin, xmax, ymin, ymax, min_scan_addr, max_scan_addr, max_matches);
        }
        if (suspended > 0) resume_process_threads(pid);
        CloseHandle(proc);
        return rc;
    }

    DWORD scan_addrs[] = {
        0x00642080u, 0x0066b68cu, 0x006544c8u, 0x00655d18u,
        0x005ec258u, 0x0068dea0u, 0x0069720cu, 0x0069c41cu,
        0x0069c468u, 0x0069c488u, 0x005f166cu, 0x006d7344u
    };
    if (target < 0) {
        DWORD lastv[sizeof(scan_addrs) / sizeof(scan_addrs[0])];
        for (unsigned j = 0; j < sizeof(lastv) / sizeof(lastv[0]); j++) lastv[j] = 0xffffffffu;
        for (int i = 0; i < 3000; i++) {
            for (unsigned j = 0; j < sizeof(scan_addrs) / sizeof(scan_addrs[0]); j++) {
                DWORD v = 0;
                SIZE_T got = 0;
                if (ReadProcessMemory(proc, (LPCVOID)(uintptr_t)scan_addrs[j], &v, sizeof(v), &got) &&
                    got == sizeof(v) && v != lastv[j]) {
                    fprintf(stderr, "frameprobe-scan addr=0x%08lx value=%lu\n",
                            (unsigned long)scan_addrs[j], (unsigned long)v);
                    lastv[j] = v;
                }
            }
            Sleep(10);
        }
        CloseHandle(proc);
        return 0;
    }

    DWORD value = 0;
    DWORD last = 0xffffffffu;
    int max_polls = 3000;
    int idle_polls = 0;
    int relative = 0;
    const char *max_env = getenv("RA_FRAMEPROBE_MAX_POLLS");
    const char *idle_env = getenv("RA_FRAMEPROBE_IDLE_POLLS");
    const char *relative_env = getenv("RA_FRAMEPROBE_RELATIVE");
    if (max_env && max_env[0]) {
        int parsed = atoi(max_env);
        if (parsed > 0) max_polls = parsed;
    }
    if (idle_env && idle_env[0]) {
        int parsed = atoi(idle_env);
        if (parsed > 0) idle_polls = parsed;
    }
    if (relative_env && relative_env[0] && strcmp(relative_env, "0") != 0) {
        relative = 1;
    }
    for (int i = 0; i < max_polls; i++) {
        SIZE_T got = 0;
        if (!ReadProcessMemory(proc, (LPCVOID)(uintptr_t)addr, &value, sizeof(value), &got) || got != sizeof(value)) {
            fprintf(stderr, "ReadProcessMemory addr=0x%08lx failed err=%lu got=%lu\n",
                    (unsigned long)addr, GetLastError(), (unsigned long)got);
            CloseHandle(proc);
            return 1;
        }
        if (value != last) {
            fprintf(stderr, "frameprobe pid=%lu addr=0x%08lx value=%lu target=%ld\n",
                    (unsigned long)pid, (unsigned long)addr, (unsigned long)value, target);
            last = value;
        }
        if (relative) {
            target += (long)value;
            relative = 0;
            fprintf(stderr, "frameprobe relative target now %ld\n", target);
        }
        if ((long)value >= target) {
            CloseHandle(proc);
            return 0;
        }
        if (idle_polls > 0 && value == 0 && i >= idle_polls) {
            fprintf(stderr, "frameprobe idle at zero for %d polls; target=%ld addr=0x%08lx\n",
                    idle_polls, target, (unsigned long)addr);
            CloseHandle(proc);
            return 1;
        }
        Sleep(10);
    }

    fprintf(stderr, "timeout waiting for frame %ld; last=%lu addr=0x%08lx\n",
            target, (unsigned long)value, (unsigned long)addr);
    CloseHandle(proc);
    return 1;
}
