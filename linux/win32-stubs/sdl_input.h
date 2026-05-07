// TIM-145 pass-43A: SDL keyboard event pump.
//
// Producer is REDALERT/KEYBOARD.CPP (Linux-only block): drains
// SDL_KEYDOWN / SDL_KEYUP from the SDL queue, maps each keysym to
// the engine's VK_ code, packs WWKEY_*BIT modifier and release
// flags, and calls _Kbd->Put(packed). Mouse and motion events are
// out of scope for this pass and stay queued for pass-43B.
//
// Consumer is REDALERT/WIN32LIB/DDRAW.CPP::Wait_Vert_Blank, which
// calls this once per frame immediately after the existing window-
// event pump so keys arrive on the same heartbeat as focus/quit.
//
// This header keeps <SDL2/SDL.h> and <keyboard.h> out of the call
// site TU (DDRAW.CPP), mirroring the sdl_quit.h pattern from
// TIM-142 pass-42A.
#ifndef LINUX_WIN32_STUBS_SDL_INPUT_H
#define LINUX_WIN32_STUBS_SDL_INPUT_H

#if !defined(_MSC_VER)

#ifdef __cplusplus
extern "C" {
#endif

void SDL_Process_Input_Events(void);

#ifdef __cplusplus
}
#endif

#endif // !_MSC_VER

#endif // LINUX_WIN32_STUBS_SDL_INPUT_H
