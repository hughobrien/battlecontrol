// TIM-142: forward declaration for the SDL_QUIT poll.
//
// The producer lives in REDALERT/WIN32LIB/DDRAW.CPP (TIM-141 pass-41F,
// commit bda1104): SDL_Process_Window_Events() drains SDL_QUIT into a
// sticky file-static flag and exposes it via the C accessor below.
// Consumers (currently REDALERT/CONQUER.CPP::Main_Loop) include this
// header instead of <SDL2/SDL.h> so the SDL include surface stays
// localised to DDRAW.CPP. The flag is sticky — once true it stays
// true until process exit, matching WM_DESTROY semantics on Win32.
#ifndef LINUX_WIN32_STUBS_SDL_QUIT_H
#define LINUX_WIN32_STUBS_SDL_QUIT_H

#if !defined(_MSC_VER)

#ifdef __cplusplus
extern "C" {
#endif

bool SDL_Quit_Requested(void);
void SDL_Clear_Quit(void);

#ifdef __cplusplus
}
#endif

#endif // !_MSC_VER

#endif // LINUX_WIN32_STUBS_SDL_QUIT_H
