// TIM-152 SDL2 main-window substrate seam.
//
// The substrate body lives in `linux/win32-stubs/sdl_window.cpp`
// (TIM-152 pass-46B). It owns the engine-wide SDL_Window pointer, plus
// weak shim definitions of `MainWindow` (HWND) and `ShowCommand` (int)
// that the upstream Win32 build provides via DDRAW.CPP and INTERNET.CPP.
//
// `SDL_Get_Main_Window()` returns the active window handle as `void*`
// to keep <SDL2/SDL.h> out of consumer TUs. Lazily creates an SDL_Window
// of the engine's expected size (640x400, hidden) on first call when no
// caller has registered one. `SDL_Set_Main_Window()` lets a caller hand
// in their own SDL_Window* — DDRAW.CPP::Set_Video_Mode under the TIM-141
// SDL2 path uses this to register its post-`SDL_CreateWindow` pointer so
// later `SDL_Get_Main_Window()` queries see DDRAW's window rather than
// double-creating. Pass `nullptr` to dispose (Reset_Video_Mode side).
//
// Pre-substrate, the only `Get` accessor lived inside DDRAW.CPP
// (pass-46A); pass-46B moved the body out so the substrate seam matches
// the sdl_quit.h / sdl_audio.h / sdl_input.h shape from TIM-142 / TIM-148
// / TIM-145.
#ifndef LINUX_WIN32_STUBS_SDL_WINDOW_H
#define LINUX_WIN32_STUBS_SDL_WINDOW_H

#if !defined(_MSC_VER)

#ifdef __cplusplus
extern "C" {
#endif

void * SDL_Get_Main_Window(void);
void   SDL_Set_Main_Window(void * window);

// TIM-675: renderer handle so SDL_Toggle_Fullscreen can apply integer scaling.
void * SDL_Get_Main_Renderer(void);
void   SDL_Set_Main_Renderer(void * renderer);

#ifndef __EMSCRIPTEN__
void SDL_Toggle_Fullscreen(void);
#endif

#ifdef __cplusplus
}
#endif

#endif // !_MSC_VER

#endif // LINUX_WIN32_STUBS_SDL_WINDOW_H
