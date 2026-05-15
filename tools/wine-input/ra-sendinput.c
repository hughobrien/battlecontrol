/*
 * TIM-728 — Inject keystrokes into RA95.EXE via SendInput.
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
 *   wine ra-sendinput.exe <VK_HEX> <DELAY_MS>
 *   e.g. wine ra-sendinput.exe 0x0D 500   # Return after 500ms
 */
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void send_vk(WORD vk) {
    INPUT in[2] = {0};
    in[0].type = INPUT_KEYBOARD;
    in[0].ki.wVk = vk;
    in[0].ki.dwFlags = 0;
    in[1] = in[0];
    in[1].ki.dwFlags = KEYEVENTF_KEYUP;
    UINT n = SendInput(2, in, sizeof(INPUT));
    fprintf(stderr, "SendInput vk=0x%02X returned %u\n", vk, n);
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s <VK_HEX> [DELAY_MS]\n", argv[0]);
        fprintf(stderr, "  VK_RETURN = 0x0D, VK_SPACE = 0x20, VK_N = 0x4E\n");
        return 1;
    }
    WORD vk = (WORD)strtol(argv[1], NULL, 0);
    int delay = (argc > 2) ? atoi(argv[2]) : 0;
    if (delay > 0) {
        fprintf(stderr, "waiting %d ms before send...\n", delay);
        Sleep(delay);
    }
    HWND hwnd = FindWindowA(NULL, "Red Alert");
    fprintf(stderr, "FindWindow(\"Red Alert\") = %p\n", hwnd);
    if (hwnd) {
        SetForegroundWindow(hwnd);
        SetActiveWindow(hwnd);
        Sleep(100);
    }
    send_vk(vk);
    Sleep(100);
    return 0;
}
