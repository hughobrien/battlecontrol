/*
 * TIM-708 — Capture the "Red Alert" window from inside Wine via BitBlt.
 *
 * Why this exists:
 *   On Wine 11.x, RA's DirectDraw primary surface is created by wined3d
 *   and rendered into a GL context. The X11 backing window stays black
 *   from ffmpeg x11grab's point of view, because wined3d never writes the
 *   composed surface back into the X11 window pixmap that x11grab reads.
 *   BitBlt from a Win32 DC, however, hits wined3d's CPU-side mirror of
 *   the primary surface, which DOES contain the game frame.
 *
 *   In practice: running this helper inside the same Wine prefix as
 *   RA95.EXE produces a BMP that contains the actual rendered menu /
 *   gameplay, regardless of whether x11grab sees anything.
 *
 * Build (mingw32):
 *   i686-w64-mingw32-gcc -o ra-screenshot.exe ra-screenshot.c -lgdi32 -luser32
 *
 * Usage:
 *   wine ra-screenshot.exe <OUTPUT.BMP> [DELAY_MS]
 *
 * Output:
 *   24-bit BMP of the "Red Alert" client area, or of the desktop if the
 *   window is missing. ImageMagick `convert` can convert this to PNG on
 *   the host.
 */
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int save_bmp(const char *path, HBITMAP bmp, int w, int h) {
    HDC scr = GetDC(NULL);
    if (!scr) { fprintf(stderr, "GetDC failed\n"); return 1; }

    BITMAPFILEHEADER fh = {0};
    BITMAPINFOHEADER bh = {0};
    bh.biSize        = sizeof(bh);
    bh.biWidth       = w;
    bh.biHeight      = h;
    bh.biPlanes      = 1;
    bh.biBitCount    = 24;
    bh.biCompression = BI_RGB;
    DWORD row = ((w * 3 + 3) & ~3u);
    DWORD pixels_sz = row * h;

    fh.bfType    = 0x4D42;
    fh.bfOffBits = sizeof(fh) + sizeof(bh);
    fh.bfSize    = fh.bfOffBits + pixels_sz;

    void *pixels = malloc(pixels_sz);
    if (!pixels) { ReleaseDC(NULL, scr); return 1; }

    BITMAPINFO bi = {0};
    bi.bmiHeader = bh;
    int lines = GetDIBits(scr, bmp, 0, h, pixels, &bi, DIB_RGB_COLORS);
    fprintf(stderr, "GetDIBits returned %d lines\n", lines);

    FILE *f = fopen(path, "wb");
    if (!f) {
        fprintf(stderr, "fopen %s failed\n", path);
        free(pixels);
        ReleaseDC(NULL, scr);
        return 1;
    }
    fwrite(&fh, sizeof(fh), 1, f);
    fwrite(&bh, sizeof(bh), 1, f);
    fwrite(pixels, pixels_sz, 1, f);
    fclose(f);
    free(pixels);
    ReleaseDC(NULL, scr);
    fprintf(stderr, "wrote %s (%lu bytes payload)\n", path, (unsigned long)pixels_sz);
    return 0;
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s <OUT.BMP> [DELAY_MS]\n", argv[0]);
        return 1;
    }
    const char *out = argv[1];
    int delay = (argc > 2) ? atoi(argv[2]) : 0;
    if (delay > 0) Sleep(delay);

    HWND hwnd = FindWindowA(NULL, "Red Alert");
    if (!hwnd) {
        fprintf(stderr, "no 'Red Alert' window — capturing desktop\n");
        hwnd = GetDesktopWindow();
    }

    RECT r;
    if (!GetClientRect(hwnd, &r)) {
        fprintf(stderr, "GetClientRect failed\n");
        return 1;
    }
    int w = r.right - r.left;
    int h = r.bottom - r.top;
    if (w <= 0 || h <= 0) {
        fprintf(stderr, "bad client rect %dx%d — falling back to GetSystemMetrics\n", w, h);
        w = GetSystemMetrics(SM_CXSCREEN);
        h = GetSystemMetrics(SM_CYSCREEN);
        hwnd = GetDesktopWindow();
    }
    fprintf(stderr, "target hwnd=%p size=%dx%d\n", hwnd, w, h);

    HDC src = GetDC(hwnd);
    HDC mem = CreateCompatibleDC(src);
    HBITMAP bmp = CreateCompatibleBitmap(src, w, h);
    HBITMAP old = (HBITMAP)SelectObject(mem, bmp);

    /* BitBlt from the HWND's DC. cnc-ddraw with renderer=gdi renders
     * windowed DDraw surfaces directly to the Win32 window's HDC, so
     * BitBlt from that DC produces the actual rendered frame.
     *
     * PrintWindow is unreliable here: on a window that has no
     * WM_PRINT handler (typical for game windows), Wine returns 1
     * but writes nothing — the resulting bitmap is all-zero. We tried
     * it first historically; switching to BitBlt-only matches what
     * cnc-ddraw + GDI gives back. */
    BOOL bb = BitBlt(mem, 0, 0, w, h, src, 0, 0, SRCCOPY);
    fprintf(stderr, "BitBlt returned %d\n", bb);

    /* If BitBlt fails, fall back to PrintWindow (rare path; kept for
     * the case where the source DC is locked by the renderer). */
    if (!bb) {
        BOOL pw_ok = PrintWindow(hwnd, mem, 0);
        fprintf(stderr, "PrintWindow fallback returned %d\n", pw_ok);
    }

    int rc = save_bmp(out, bmp, w, h);

    SelectObject(mem, old);
    DeleteObject(bmp);
    DeleteDC(mem);
    ReleaseDC(hwnd, src);
    return rc;
}
