// TIM-152 pass-46B: SDL2 main-window substrate body.
//
// Owns the engine-wide SDL_Window* and the Linux-side definitions of
// `MainWindow` (HWND) and `ShowCommand` (int) that the upstream Win32
// build provides via DDRAW.CPP and INTERNET.CPP respectively.
//
// Window lifecycle
// ----------------
//
// `SDL_Get_Main_Window()` lazily creates an SDL_Window on first call
// (size 640x400 — Red Alert's native mode, SDL_WINDOW_HIDDEN until the
// engine drives its first present). Callers that already own a window
// (notably DDRAW.CPP::Set_Video_Mode under the TIM-141 SDL2 path) hand
// theirs in via `SDL_Set_Main_Window()`; the substrate then routes
// future `SDL_Get_Main_Window()` callers to that window without
// double-creating. `SDL_Set_Main_Window(nullptr)` is the dispose-side
// of the contract — DDRAW.CPP::Reset_Video_Mode calls it after
// destroying its own window so a subsequent SDL_Get_Main_Window() will
// fall back to the lazy-create path or return null.
//
// Naming follows the sdl_quit / sdl_audio / sdl_input substrate seams
// declared in `linux/win32-stubs/sdl_window.h` (TIM-152 pass-46A).
//
// MainWindow / ShowCommand shims
// ------------------------------
//
// Pre-substrate, MainWindow and ShowCommand were the "elided" globals
// from the TIM-140 link-side survey: `HWND MainWindow;` lives in
// REDALERT/WIN32LIB/DDRAW.CPP outside any guard, but DDRAW.CPP itself
// failed to compile until TIM-141 landed the SDL2 path. `int ShowCommand;`
// lives in REDALERT/INTERNET.CPP behind that file's outer `#ifdef WIN32`
// — under the link survey CXXFLAGS (no -DWIN32), the entire INTERNET.CPP
// body elides and ShowCommand stays undefined.
//
// Both are declared **weak** here so the strong upstream definitions
// win whenever they are present in the link set:
//   * MSVC build: weak shims are not compiled (`!defined(_MSC_VER)` gate).
//   * Linux per-TU compile floor: substrate isn't compiled (the floor
//     pass enumerates only REDALERT/*.cpp and REDALERT/WIN32LIB/*.cpp).
//   * Linux first-link-pass-151 (no -DWIN32): DDRAW.o supplies a strong
//     MainWindow; INTERNET.o is empty so the substrate's weak ShowCommand
//     wins. Net: -1 undef site (ShowCommand) closed without adding a
//     multidef.
//   * Future link variant that flips -DWIN32 on at link compile-time:
//     INTERNET.o would supply a strong ShowCommand; weak substrate def
//     defers to it. No multidef regression.
//
// `__attribute__((weak))` is GCC/Clang only — fine, this whole TU is
// gated `!_MSC_VER`.

#if !defined(_MSC_VER)

#include <SDL2/SDL.h>

#include "sdl_window.h"
#include "windows.h"  // HWND typedef

namespace {

SDL_Window *   g_main_window   = nullptr;
SDL_Renderer * g_main_renderer = nullptr;
bool           g_is_fullscreen = false;

// Red Alert's native primary mode is 640x400. The substrate creates the
// window hidden so DDRAW.CPP's first-present latch (TIM-141 commit 5)
// is what actually maps it on screen — matches the upstream Win32
// behaviour where ShowWindow(SW_HIDE) is the default in
// Create_Main_Window until the engine has something to draw.
constexpr int  RA_DEFAULT_W = 640;
constexpr int  RA_DEFAULT_H = 400;
constexpr char RA_WINDOW_TITLE[] = "Red Alert";

bool ensure_video_init()
{
    if (SDL_WasInit(SDL_INIT_VIDEO) != 0) {
        return true;
    }
    return SDL_InitSubSystem(SDL_INIT_VIDEO) == 0;
}

}  // namespace

extern "C" void * SDL_Get_Main_Window(void)
{
    if (g_main_window != nullptr) {
        return g_main_window;
    }

    if (!ensure_video_init()) {
        return nullptr;
    }

#ifdef __EMSCRIPTEN__
    // TIM-582: SDL2's Emscripten backend reads this hint during SDL_CreateWindow
    // when registering keyboard event listeners. Without it, events go to #window
    // and may not reach the canvas if it does not have browser focus.
    SDL_SetHint(SDL_HINT_EMSCRIPTEN_KEYBOARD_ELEMENT, "#canvas");
    // TIM-582: Translate touch events to synthetic SDL mouse events (mobile WASM).
    SDL_SetHint(SDL_HINT_TOUCH_MOUSE_EVENTS, "1");
#endif

    g_main_window = SDL_CreateWindow(
        RA_WINDOW_TITLE,
        SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
        RA_DEFAULT_W, RA_DEFAULT_H,
#ifdef __EMSCRIPTEN__
        SDL_WINDOW_SHOWN);  // TIM-377: canvas always visible in browser
#else
        SDL_WINDOW_HIDDEN);
#endif

    return g_main_window;
}

extern "C" void SDL_Set_Main_Window(void * window)
{
    g_main_window = static_cast<SDL_Window *>(window);
    g_is_fullscreen = false;  // reset on window reassignment
}

extern "C" void * SDL_Get_Main_Renderer(void)
{
    return g_main_renderer;
}

extern "C" void SDL_Set_Main_Renderer(void * renderer)
{
    g_main_renderer = static_cast<SDL_Renderer *>(renderer);
}

#ifndef __EMSCRIPTEN__
extern "C" void SDL_Toggle_Fullscreen(void)
{
    if (g_main_window == nullptr) return;
    g_is_fullscreen = !g_is_fullscreen;

    if (g_is_fullscreen && g_main_renderer != nullptr) {
        // TIM-675: integer scaling — largest integer multiple of the game
        // resolution that fits the display, centred with black bars.
        int win_w = 0, win_h = 0;
        SDL_GetWindowSize(g_main_window, &win_w, &win_h);
        SDL_RenderSetLogicalSize(g_main_renderer, win_w, win_h);
        SDL_RenderSetIntegerScale(g_main_renderer, SDL_TRUE);
    }

    SDL_SetWindowFullscreen(g_main_window,
        g_is_fullscreen ? SDL_WINDOW_FULLSCREEN_DESKTOP : 0);

    if (!g_is_fullscreen && g_main_renderer != nullptr) {
        SDL_RenderSetIntegerScale(g_main_renderer, SDL_FALSE);
        SDL_RenderSetLogicalSize(g_main_renderer, 0, 0);
    }
}
#endif

// Weak shims for the engine globals upstream defines in DDRAW.CPP
// (MainWindow) and INTERNET.CPP (ShowCommand). See the file header
// comment for the strong-vs-weak resolution semantics.
__attribute__((weak)) HWND MainWindow  = nullptr;
__attribute__((weak)) int  ShowCommand = 1;  // SW_SHOWNORMAL

#endif  // !_MSC_VER
