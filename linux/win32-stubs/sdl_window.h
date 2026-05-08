// TIM-152 pass-46A: forward declaration for the SDL2 main-window accessor.
//
// The producer lives in REDALERT/WIN32LIB/DDRAW.CPP (TIM-141 pass-41 series):
// `SDL_VideoWindow` is the file-static SDL_Window* created lazily inside
// Set_Video_Mode and torn down in Reset_Video_Mode. This header exposes a
// C-callable accessor so cross-TU consumers can fetch the active window
// handle without dragging in <SDL2/SDL.h>, mirroring the sdl_quit.h /
// sdl_audio.h / sdl_input.h pattern from TIM-142 / TIM-148 / TIM-145.
//
// Returned pointer is the moral equivalent of `MainWindow` (HWND) on the
// Win32 build: opaque to callers, valid only between Set_Video_Mode and
// Reset_Video_Mode, NULL otherwise. Callers MUST NOT cast back to a
// concrete SDL2 type unless they include <SDL2/SDL.h> directly. NULL is
// returned before the engine has driven its first frame, matching the
// Win32 "ShowWindow on a non-existent HWND is a soft failure" semantic.
//
// Pass-46A ships the seam only. No engine TU includes this header yet;
// follow-up passes (46B+) wire consumers (e.g. focus-loss callbacks,
// SetForegroundWindow paths) onto the accessor as needed.
#ifndef LINUX_WIN32_STUBS_SDL_WINDOW_H
#define LINUX_WIN32_STUBS_SDL_WINDOW_H

#if !defined(_MSC_VER)

#ifdef __cplusplus
extern "C" {
#endif

void * SDL_Get_Main_Window(void);

#ifdef __cplusplus
}
#endif

#endif // !_MSC_VER

#endif // LINUX_WIN32_STUBS_SDL_WINDOW_H
