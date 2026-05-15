/*
 * winclick — Win32 SendInput-based click injector for Wine RA gameplay tests.
 *
 * Modes (env WC_MODE):
 *   batch       — single SendInput() with MOVE+LEFTDOWN+LEFTUP (default)
 *   legacy      — mouse_event() API
 *   foreground  — SetForegroundWindow(RA window) then batch
 *
 * Usage:  winclick.exe <x> <y> [<x> <y> ...]
 *
 * Build:
 *   i686-w64-mingw32-gcc -mwindows -O2 -o winclick.exe winclick.c -luser32
 */
#define _WIN32_WINNT 0x0500
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int g_sw = 0;
static int g_sh = 0;

static LONG to_abs_x(int x) { return (LONG)((x * 65535L + g_sw / 2) / (g_sw - 1)); }
static LONG to_abs_y(int y) { return (LONG)((y * 65535L + g_sh / 2) / (g_sh - 1)); }

static void click_batch(int x, int y) {
    INPUT ip[3] = {0};
    ip[0].type = INPUT_MOUSE;
    ip[0].mi.dx = to_abs_x(x);
    ip[0].mi.dy = to_abs_y(y);
    ip[0].mi.dwFlags = MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE;
    ip[1].type = INPUT_MOUSE;
    ip[1].mi.dx = to_abs_x(x);
    ip[1].mi.dy = to_abs_y(y);
    ip[1].mi.dwFlags = MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE |
                       MOUSEEVENTF_LEFTDOWN;
    ip[2].type = INPUT_MOUSE;
    ip[2].mi.dx = to_abs_x(x);
    ip[2].mi.dy = to_abs_y(y);
    ip[2].mi.dwFlags = MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE |
                       MOUSEEVENTF_LEFTUP;
    UINT sent = SendInput(3, ip, sizeof(INPUT));
    fprintf(stderr, "winclick: SendInput batch sent=%u/3 err=%lu\n",
            sent, (unsigned long)GetLastError());
}

static void click_legacy(int x, int y) {
    SetCursorPos(x, y);
    Sleep(20);
    mouse_event(MOUSEEVENTF_LEFTDOWN, 0, 0, 0, 0);
    Sleep(40);
    mouse_event(MOUSEEVENTF_LEFTUP, 0, 0, 0, 0);
}

static HWND find_ra(void) {
    HWND h = FindWindowA(NULL, "Red Alert");
    if (!h) h = FindWindowA(NULL, "Command & Conquer Red Alert");
    return h;
}

static void click_foreground(int x, int y) {
    HWND ra = find_ra();
    if (ra) {
        fprintf(stderr, "winclick: foreground RA hwnd=%p\n", (void*)ra);
        SetForegroundWindow(ra);
        BringWindowToTop(ra);
        Sleep(50);
    } else {
        fprintf(stderr, "winclick: RA window not found by name\n");
    }
    click_batch(x, y);
}

int main(int argc, char **argv) {
    if (argc < 3 || (argc - 1) % 2 != 0) {
        fprintf(stderr, "usage: winclick <x> <y> [<x> <y> ...]\n");
        return 1;
    }
    const char *mode = getenv("WC_MODE");
    if (!mode) mode = "batch";

    g_sw = GetSystemMetrics(SM_CXSCREEN);
    g_sh = GetSystemMetrics(SM_CYSCREEN);
    fprintf(stderr, "winclick: screen %dx%d mode=%s\n", g_sw, g_sh, mode);

    for (int i = 1; i + 1 < argc; i += 2) {
        int x = atoi(argv[i]);
        int y = atoi(argv[i + 1]);
        fprintf(stderr, "winclick: click (%d, %d)\n", x, y);
        if (strcmp(mode, "legacy") == 0) {
            click_legacy(x, y);
        } else if (strcmp(mode, "foreground") == 0) {
            click_foreground(x, y);
        } else {
            click_batch(x, y);
        }
        Sleep(250);
    }
    return 0;
}
