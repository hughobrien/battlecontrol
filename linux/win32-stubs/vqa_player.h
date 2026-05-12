// VQA cinematic player seam for the native Linux / SDL2 build.
// Called from CONQUER.CPP::Play_Movie on !_MSC_VER builds.
// If the VQA file is missing the call is a silent no-op.
#ifndef LINUX_WIN32_STUBS_VQA_PLAYER_H
#define LINUX_WIN32_STUBS_VQA_PLAYER_H

#if !defined(_MSC_VER)

#ifdef __cplusplus
extern "C" {
#endif

// Play the named VQA file (without extension).  Blocks until playback
// finishes or the user presses a key/ESC.  Returns immediately if the
// file cannot be found (logs a warning and continues — no crash).
void Play_Movie_Linux(const char* name);

#ifdef __cplusplus
}
#endif

#endif // !_MSC_VER
#endif // LINUX_WIN32_STUBS_VQA_PLAYER_H
