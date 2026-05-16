/*
 * TIM-728/TIM-708 — Inject input into RA95.EXE via SendInput.
 *
 * Why SendInput (not xdotool / PostMessage):
 *   RA's CD prompt and menu read input state from DirectInput, which is
 *   populated by Wine's dinput.dll via a WH_KEYBOARD_LL low-level hook.
 *   Synthetic X events (xdotool, XTestFakeKeyEvent) do NOT trigger LL
 *   hooks — they generate WM_CHAR via x11drv but never reach DInput's
 *   keyboard-state array.
 *
 *   SendInput, by contrast, dispatches via the kernel input pipeline,
 *   which DOES fire LL hooks. Wine's dinput.dll then sees the keypress
 *   and updates the per-key state array that RA reads.
 *
 * Build (mingw32):
 *   i686-w64-mingw32-gcc -o ra-sendinput.exe ra-sendinput.c -luser32
 *
 * Usage (under same Wine prefix as RA95.EXE):
 *   wine ra-sendinput.exe <CMD> [ARGS...]
 *
 *   key   <VK_HEX> [DELAY_MS]            — single keypress (KEY_DOWN+KEY_UP)
 *   click <X> <Y> [DELAY_MS]             — move + left-click at client (x,y)
 *   move  <X> <Y> [DELAY_MS]             — move only
 *   seq   <STEP>[;<STEP>]...             — chained ops separated by ';'
 *                                          step is 'k=VK[@DELAY]' or
 *                                          'c=X,Y[@DELAY]' or
 *                                          's=MS' (sleep)
 *
 * Coordinates: client area of the "Command & Conquer" top-level window.
 *
 * Examples:
 *   wine ra-sendinput.exe key 0x0D                       # Enter
 *   wine ra-sendinput.exe click 322 183                  # main menu New Campaign
 *   wine ra-sendinput.exe seq 's=2000;c=322,183;s=2000;c=470,244'
 */
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static HWND g_hwnd = NULL;
static RECT g_client_screen = {0};
/* When non-zero, send_move / send_click treat their (x,y) arguments as
 * already in X-server screen coordinates and skip the ClientToScreen
 * offset.  Set via the RA_SENDINPUT_ABS env var or by the *_abs commands.
 * Reason: under Wine 11 + Xvfb + openbox, ClientToScreen for the cnc-ddraw
 * window returns an offset that doesn't match the actual X-server window
 * geometry (xwininfo reports (0,0); ClientToScreen reports (192,184)).
 * Absolute mode bypasses that bug and uses the raw screen coords. */
static int g_absolute_mode = 0;

static void resolve_window(void) {
    g_hwnd = FindWindowA(NULL, "Command & Conquer");
    if (!g_hwnd) {
        fprintf(stderr, "FindWindow(\"Red Alert\") = NULL — game window missing\n");
        return;
    }
    SetForegroundWindow(g_hwnd);
    SetActiveWindow(g_hwnd);
    Sleep(80);
    POINT origin = {0, 0};
    ClientToScreen(g_hwnd, &origin);
    GetClientRect(g_hwnd, &g_client_screen);
    g_client_screen.left   += origin.x;
    g_client_screen.top    += origin.y;
    g_client_screen.right  += origin.x;
    g_client_screen.bottom += origin.y;
    const char *env = getenv("RA_SENDINPUT_ABS");
    if (env && env[0] && env[0] != '0') {
        g_absolute_mode = 1;
    }
    fprintf(stderr, "window=%p client_screen=(%ld,%ld)-(%ld,%ld) abs=%d\n",
            g_hwnd,
            g_client_screen.left, g_client_screen.top,
            g_client_screen.right, g_client_screen.bottom,
            g_absolute_mode);
}

static void send_vk(WORD vk) {
    INPUT in[2] = {0};
    in[0].type = INPUT_KEYBOARD;
    in[0].ki.wVk = vk;
    in[0].ki.dwFlags = 0;
    in[1] = in[0];
    in[1].ki.dwFlags = KEYEVENTF_KEYUP;
    UINT n = SendInput(2, in, sizeof(INPUT));
    fprintf(stderr, "key vk=0x%02X -> %u events\n", vk, n);
}

static void send_move(int cx, int cy) {
    int sx = g_absolute_mode ? cx : (g_client_screen.left + cx);
    int sy = g_absolute_mode ? cy : (g_client_screen.top  + cy);
    /* SendInput MOUSEEVENTF_ABSOLUTE coords are normalized to 0..65535 over
     * the virtual screen, but Wine on a single-screen X server treats raw
     * screen pixel deltas from SetCursorPos identically — and that path is
     * far simpler and exercises the same WH_MOUSE_LL hooks that DInput
     * listens on. */
    SetCursorPos(sx, sy);
    Sleep(40);
    INPUT in = {0};
    in.type = INPUT_MOUSE;
    in.mi.dwFlags = MOUSEEVENTF_MOVE;
    in.mi.dx = 0;
    in.mi.dy = 0;
    SendInput(1, &in, sizeof(INPUT));
    fprintf(stderr, "move client=(%d,%d) screen=(%d,%d)\n", cx, cy, sx, sy);
}

static void send_click(int cx, int cy) {
    send_move(cx, cy);
    Sleep(60);
    INPUT in[2] = {0};
    in[0].type = INPUT_MOUSE;
    in[0].mi.dwFlags = MOUSEEVENTF_LEFTDOWN;
    in[1] = in[0];
    in[1].mi.dwFlags = MOUSEEVENTF_LEFTUP;
    UINT n = SendInput(2, in, sizeof(INPUT));
    fprintf(stderr, "click client=(%d,%d) -> %u events\n", cx, cy, n);
}

static int parse_step(const char *s) {
    /* k=VK[@DELAY] / c=X,Y[@DELAY] / m=X,Y[@DELAY] / s=MS */
    if (s[0] == 's' && s[1] == '=') {
        int ms = atoi(s + 2);
        fprintf(stderr, "sleep %d ms\n", ms);
        Sleep(ms);
        return 0;
    }
    const char *eq = strchr(s, '=');
    if (!eq) return -1;
    char tag = s[0];
    const char *body = eq + 1;
    const char *at = strchr(body, '@');
    int delay = at ? atoi(at + 1) : 0;
    if (tag == 'k') {
        WORD vk = (WORD)strtol(body, NULL, 0);
        send_vk(vk);
    } else if (tag == 'c' || tag == 'm') {
        int x, y;
        if (sscanf(body, "%d,%d", &x, &y) != 2) return -1;
        if (tag == 'c') send_click(x, y);
        else            send_move(x, y);
    } else {
        return -1;
    }
    if (delay > 0) Sleep(delay);
    return 0;
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr,
            "usage: %s key   <VK_HEX> [DELAY_MS]\n"
            "       %s click <X> <Y>  [DELAY_MS]\n"
            "       %s move  <X> <Y>  [DELAY_MS]\n"
            "       %s seq   <STEP>[;<STEP>]...\n"
            "       step: k=VK[@DELAY] | c=X,Y[@DELAY] | m=X,Y[@DELAY] | s=MS\n",
            argv[0], argv[0], argv[0], argv[0]);
        return 1;
    }
    const char *cmd = argv[1];

    if (!strcmp(cmd, "key")) {
        if (argc < 3) return 1;
        WORD vk = (WORD)strtol(argv[2], NULL, 0);
        int delay = (argc > 3) ? atoi(argv[3]) : 0;
        if (delay > 0) Sleep(delay);
        resolve_window();
        send_vk(vk);
    } else if (!strcmp(cmd, "click") || !strcmp(cmd, "move")) {
        if (argc < 4) return 1;
        int x = atoi(argv[2]);
        int y = atoi(argv[3]);
        int delay = (argc > 4) ? atoi(argv[4]) : 0;
        if (delay > 0) Sleep(delay);
        resolve_window();
        if (!strcmp(cmd, "click")) send_click(x, y);
        else                       send_move(x, y);
    } else if (!strcmp(cmd, "seq")) {
        if (argc < 3) return 1;
        resolve_window();
        char *buf = strdup(argv[2]);
        char *save = NULL;
        for (char *tok = strtok_r(buf, ";", &save); tok; tok = strtok_r(NULL, ";", &save)) {
            if (parse_step(tok) != 0) {
                fprintf(stderr, "bad step: %s\n", tok);
            }
        }
        free(buf);
    } else {
        /* Backward-compat: bare VK like old TIM-728 helper */
        WORD vk = (WORD)strtol(argv[1], NULL, 0);
        int delay = (argc > 2) ? atoi(argv[2]) : 0;
        if (delay > 0) Sleep(delay);
        resolve_window();
        send_vk(vk);
    }
    Sleep(80);
    return 0;
}
