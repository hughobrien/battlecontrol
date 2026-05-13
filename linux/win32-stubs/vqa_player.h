// VQA cinematic player seam for the native Linux / SDL2 build.
// Called from CONQUER.CPP::Play_Movie on !_MSC_VER builds.
// If the VQA file is missing the call is a silent no-op.
#ifndef LINUX_WIN32_STUBS_VQA_PLAYER_H
#define LINUX_WIN32_STUBS_VQA_PLAYER_H

#if !defined(_MSC_VER)

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Play the named VQA file (without extension).  Blocks until playback
// finishes or the user presses a key/ESC.  Returns immediately if the
// file cannot be found (logs a warning and continues — no crash).
void Play_Movie_Linux(const char* name);

// Apply a pre-scaled 8-bit RGB palette (ncolors entries) directly to the
// SDL indexed surface, bypassing the 6-bit->8-bit <<2 shift in Set_DD_Palette.
// Used by the VQA CPL0 handler (CPL0 stores 8-bit values, not 6-bit VGA).
void Set_DD_Palette_8bit(const uint8_t* rgb8, int ncolors);

#ifdef __cplusplus
}
#endif

#endif // !_MSC_VER
#endif // LINUX_WIN32_STUBS_VQA_PLAYER_H
