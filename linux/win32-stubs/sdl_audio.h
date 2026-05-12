// TIM-148 pass-44A: forward declarations for the SDL2 audio substrate.
//
// The implementation will live in REDALERT/AUDIO.CPP under `#ifndef _MSC_VER`,
// mirroring the TIM-141 DDRAW.CPP / TIM-145 KEYBOARD.CPP pattern: SDL2-backed
// bodies replace the upstream EA Remastered no-op stubs (AUDIO.CPP:55-83) on
// Linux only, while the MSVC build keeps the upstream stubs byte-for-byte.
//
// This header keeps `<SDL2/SDL.h>` out of engine TUs that need to call into
// the audio substrate from outside AUDIO.CPP -- analogous to sdl_quit.h /
// sdl_input.h. Pass-44A ships the seam only; the real bodies land in 44B+.
//
// See the audio-survey document on TIM-148 for the full backend rationale,
// the per-pass split (44A..44F), and the runtime contract pulled from the
// engine's live consumers (THEME.CPP / SCORE.CPP / STARTUP.CPP).
#ifndef LINUX_WIN32_STUBS_SDL_AUDIO_H
#define LINUX_WIN32_STUBS_SDL_AUDIO_H

#if !defined(_MSC_VER)

#ifdef __cplusplus
extern "C" {
#endif

// Backend lifecycle helpers. Bodies land in pass-44B inside AUDIO.CPP's
// SDL2 block. Declared here so future cross-TU consumers (e.g. a per-frame
// Sound_Callback pump invoked from CONQUER.CPP::Main_Loop) can call into
// the substrate without dragging in <SDL2/SDL.h>.
bool SDL_Audio_Open(int rate, int channels, int bits_per_sample);
void SDL_Audio_Close(void);
bool SDL_Audio_Is_Open(void);
void SDL_Audio_Get_Params(int *rate, int *channels, int *bits);

#ifdef __cplusplus
}
#endif

#endif // !_MSC_VER

#endif // LINUX_WIN32_STUBS_SDL_AUDIO_H
