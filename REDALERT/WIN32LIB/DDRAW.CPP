//
// Copyright 2020 Electronic Arts Inc.
//
// TiberianDawn.DLL and RedAlert.dll and corresponding source code is free 
// software: you can redistribute it and/or modify it under the terms of 
// the GNU General Public License as published by the Free Software Foundation, 
// either version 3 of the License, or (at your option) any later version.

// TiberianDawn.DLL and RedAlert.dll and corresponding source code is distributed 
// in the hope that it will be useful, but with permitted additional restrictions 
// under Section 7 of the GPL. See the GNU General Public License in LICENSE.TXT 
// distributed with this program. You should have received a copy of the 
// GNU General Public License along with permitted additional restrictions 
// with this program. If not, see https://github.com/electronicarts/CnC_Remastered_Collection

/***************************************************************************
 **   C O N F I D E N T I A L --- W E S T W O O D   A S S O C I A T E S   **
 ***************************************************************************
 *                                                                         *
 *                 Project Name : Westwood Win32 Library                   *
 *                                                                         *
 *                    File Name : DDRAW.CPP                                *
 *                                                                         *
 *                   Programmer : Philip W. Gorrow                         *
 *                                                                         *
 *                   Start Date : October 10, 1995                         *
 *                                                                         *
 *                  Last Update : October 10, 1995   []                    *
 *                                                                         *
 *-------------------------------------------------------------------------*
 * Functions:                                                              *
 * - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - */

/*=========================================================================*/
/* The following PRIVATE functions are in this file:                       */
/*=========================================================================*/


/*= = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = =*/


#include "misc.h"
#include <gbuffer.h>
#include <palette.h>
#include "stdio.h"

// TIM-141: Linux native SDL2 path. Replaces the (already-no-op'd) DirectDraw
// runtime in Set_Video_Mode / Reset_Video_Mode / Set_DD_Palette / Wait_*. The
// MSVC build keeps the upstream DirectDraw COM path; on Linux we drive an
// SDL_Window + SDL_Renderer + 8-bit indexed SDL_Surface directly. See plan
// document on TIM-141 for the full mapping.
#ifndef _MSC_VER
#include <SDL2/SDL.h>
#include <climits>      // TIM-141 commit 2: Get_Free_Video_Memory uses INT_MAX
#include <cstdint>      // TIM-908: uint32_t for palette LUT
#include <cstring>       // TIM-908: memcmp/memcpy for palette dirty-check
#include "sdl_input.h"  // TIM-145 pass-43A: SDL_Process_Input_Events()
#include "sdl_window.h" // TIM-152 pass-46B: SDL_Set_Main_Window registration
static SDL_Window*   SDL_VideoWindow    = nullptr;
static SDL_Renderer* SDL_VideoRenderer  = nullptr;
static SDL_Surface*  SDL_PrimarySurface = nullptr;
static SDL_Color     SDL_PaletteEntries[256] = {};
// TIM-908: precomputed 32-bit ARGB LUT to avoid per-pixel shift/OR in
// the Wait_Vert_Blank indexed→ARGB conversion loop. Rebuilt whenever
// Set_DD_Palette or Set_DD_Palette_8bit updates SDL_PaletteEntries.
static uint32_t       SDL_PaletteLUT[256] = {};

static void Rebuild_Palette_LUT(void)
{
	for (int i = 0; i < 256; ++i) {
		const SDL_Color& c = SDL_PaletteEntries[i];
		SDL_PaletteLUT[i] = ((uint32_t)0xFF << 24) |
		                    ((uint32_t)c.r  << 16) |
		                    ((uint32_t)c.g  <<  8) |
		                    ((uint32_t)c.b);
	}
}
// TIM-141 commit 5: present-pump caches. Texture is the GPU streaming
// destination; PrimaryARGB is the CPU-side 32-bit blit target that holds
// SDL_BlitSurface's indexed->ARGB conversion using the palette set by
// Set_DD_Palette. Both are recreated when the primary surface's size
// changes; both are freed in Reset_Video_Mode.
static SDL_Texture*  SDL_PrimaryTexture = nullptr;
static SDL_Surface*  SDL_PrimaryARGB    = nullptr;
static int           SDL_CachedW        = 0;
static int           SDL_CachedH        = 0;
static bool          SDL_FirstPresentDone = false;
static int           SDL_PresentCount     = 0;  // TIM-237: counts presents after game loop starts

// TIM-619: set to 1 by vqa_player.cpp while a VQA cinematic is playing with
// VQA_SCANLINES enabled. Wait_Vert_Blank reads this flag to apply the overlay.
extern int vqa_scanlines_active;

// TIM-141 commit 4: typed accessors over the file-static SDL_PrimarySurface
// for GBUFFER.CPP's GraphicBufferClass::Lock/Unlock. Keeps <SDL.h> out of
// every TU that includes DDRAW.H/GBUFFER.H. Indexed (8-bit) SDL surfaces
// have CPU-resident pixels; SDL_LockSurface is unnecessary for the
// non-RLE software-rendered case the engine drives.
bool SDL_Has_Primary_Surface(void)
{
    return SDL_PrimarySurface != nullptr && SDL_PrimarySurface->pixels != nullptr;
}

unsigned char * SDL_Get_Primary_Pixels(void)
{
    return SDL_PrimarySurface ? static_cast<unsigned char *>(SDL_PrimarySurface->pixels) : nullptr;
}

int SDL_Get_Primary_Pitch(void)
{
    return SDL_PrimarySurface ? SDL_PrimarySurface->pitch : 0;
}

void RA_Save_Gameplay_BMP_Path(int game_frame, char const * path)
{
    if (SDL_PrimaryARGB == nullptr) return;
    if (path == nullptr || path[0] == '\0') return;
    int rc = SDL_SaveBMP(SDL_PrimaryARGB, path);
    const uint32_t* px = (const uint32_t*)SDL_PrimaryARGB->pixels;
    int total = SDL_PrimaryARGB->w * SDL_PrimaryARGB->h;
    int nz = 0;
    for (int i = 0; i < total; ++i)
        if (px[i] & 0x00FFFFFF) ++nz;
    fprintf(stderr, "[RA] gameplay BMP frame=%d rc=%d nz_pixels=%d path=%s\n",
            game_frame, rc, nz, path);
    fflush(stderr);
}

// TIM-490: save a BMP snapshot of the current rendered frame, keyed by game loop frame.
void RA_Save_Gameplay_BMP(int game_frame)
{
    char path[512];
    const char* capture_path = getenv("RA_CAPTURE_BMP_FILE");
    const char* capture_frame = getenv("RA_CAPTURE_FRAME");
    int capture_target = (capture_frame && capture_frame[0]) ? atoi(capture_frame) : -1;
    if (capture_path && capture_path[0] && capture_target == game_frame) {
        snprintf(path, sizeof(path), "%s", capture_path);
    } else {
        snprintf(path, sizeof(path), "/tmp/redalert-gameplay-f%03d.bmp", game_frame);
    }
    RA_Save_Gameplay_BMP_Path(game_frame, path);
}

// TIM-141 commit 6: window-class event pump. Drives
// SurfaceMonitorClass::Set_Surface_Focus from SDL_WINDOWEVENT_FOCUS_*
// and captures SDL_QUIT into SDL_QuitRequested for the game loop to
// poll via SDL_Quit_Requested(). SDL_PeepEvents with a tight type
// filter is used (NOT SDL_PollEvent) so keyboard, mouse and joystick
// events stay queued for the DINPUT lane. This mirrors what Wine's
// winex11 driver does for the same separation.
static bool SDL_QuitRequested = false;

extern bool GameInFocus;

static void SDL_Process_Window_Events(void)
{
    SDL_PumpEvents();

    SDL_Event events[16];
    int drained;
    do {
        drained = SDL_PeepEvents(events, 16, SDL_GETEVENT,
                                 SDL_WINDOWEVENT, SDL_WINDOWEVENT);
        for (int i = 0; i < drained; ++i) {
            switch (events[i].window.event) {
            case SDL_WINDOWEVENT_FOCUS_LOST:
            case SDL_WINDOWEVENT_MINIMIZED:
                AllSurfaces.Set_Surface_Focus(FALSE);
                GameInFocus = false;
                break;
            case SDL_WINDOWEVENT_FOCUS_GAINED:
            case SDL_WINDOWEVENT_RESTORED:
                AllSurfaces.Set_Surface_Focus(TRUE);
                GameInFocus = true;
                break;
            case SDL_WINDOWEVENT_CLOSE:
                fprintf(stderr, "[SDL] SDL_WINDOWEVENT_CLOSE received\n"); fflush(stderr);
                break;
            default:
                break;
            }
        }
    } while (drained == 16);

    do {
        drained = SDL_PeepEvents(events, 16, SDL_GETEVENT,
                                 SDL_QUIT, SDL_QUIT);
        if (drained > 0) {
            SDL_QuitRequested = true;
            fprintf(stderr, "[SDL] SDL_QUIT drained (count=%d)\n", drained); fflush(stderr);
        }
    } while (drained == 16);
}

extern "C" bool SDL_Quit_Requested(void)
{
    return SDL_QuitRequested;
}

/* TIM-237: clear the sticky quit flag on game restart so Select_Game
   restarts (e.g. after SIGTERM from timeout) don't immediately exit. */
extern "C" void SDL_Clear_Quit(void)
{
    SDL_QuitRequested = false;
}

// TIM-145 pass-43D: SDL window-bring-up accessors that back the
// ShowWindow / SetForegroundWindow stubs in linux/win32-stubs/
// windows.h. INIT.CPP:1104-1105 (WChat-spawned launch path) and
// NETDLG.CPP host/join paths use these to raise the engine's
// top-level window when returning from a network dialog. The SDL
// window is created lazily in Set_Video_Mode and only shown for
// real on the first present (SDL_FirstPresentDone latch). These
// accessors no-op safely before that point, matching the Win32
// behaviour where ShowWindow on a non-existent HWND is a soft
// failure rather than a crash.
extern "C" void SDL_Window_Show(int sw_command)
{
    if (SDL_VideoWindow == nullptr) return;

    // SW_ values are defined in linux/win32-stubs/windows.h. Branch
    // by behavioural family rather than chaining every constant —
    // SW_SHOWNORMAL / SW_SHOWNOACTIVATE / SW_SHOW / SW_SHOWNA all
    // collapse to "show the window without changing minimize/
    // maximize state".
    switch (sw_command) {
    case 0:  // SW_HIDE
        SDL_HideWindow(SDL_VideoWindow);
        break;
    case 2:  // SW_SHOWMINIMIZED
    case 6:  // SW_MINIMIZE
    case 7:  // SW_SHOWMINNOACTIVE
        SDL_MinimizeWindow(SDL_VideoWindow);
        break;
    case 3:  // SW_SHOWMAXIMIZED / SW_MAXIMIZE
        SDL_MaximizeWindow(SDL_VideoWindow);
        SDL_ShowWindow(SDL_VideoWindow);
        break;
    default: // SW_SHOWNORMAL=1, SW_SHOWNOACTIVATE=4, SW_SHOW=5, SW_SHOWNA=8
        SDL_ShowWindow(SDL_VideoWindow);
        break;
    }
}

extern "C" void SDL_Window_Raise(void)
{
    if (SDL_VideoWindow == nullptr) return;
    SDL_RaiseWindow(SDL_VideoWindow);
}

// TIM-152 pass-46B: SDL_Get_Main_Window body moved to
// linux/win32-stubs/sdl_window.cpp so the substrate owns the lifecycle
// (and the weak `MainWindow` / `ShowCommand` shims live next to it).
// Set_Video_Mode below registers `SDL_VideoWindow` with the substrate
// via SDL_Set_Main_Window after creation; Reset_Video_Mode unregisters
// before destroy. The substrate's lazy fall-back create never fires in
// practice because Set_Video_Mode is always reached before any
// SDL_Get_Main_Window() consumer.
#endif

LPDIRECTDRAW		DirectDrawObject=NULL;	// Pointer to the direct draw object
LPDIRECTDRAW2	DirectDraw2Interface = NULL;  	// Pointer to direct draw 2 interface

HWND			MainWindow;					// Handle to programs main window
												// this is passed to SetCooperativeLevel
												// so DirectDraw knows which window is ours


PALETTEENTRY				PaletteEntries[256];		// 256 windows palette entries
LPDIRECTDRAWPALETTE	PalettePtr;					// Pointer to direct draw palette object
BOOL						FirstPaletteSet=FALSE;	// Is this the first time 'Set_Palette' has been called?
LPDIRECTDRAWSURFACE	PaletteSurface=NULL;
SurfaceMonitorClass	AllSurfaces;				//List of all direct draw surfaces
BOOL						CanVblankSync = TRUE;

BOOL						SystemToVideoBlits =FALSE;	// Does hardware support system mem to video mem blits?
BOOL						VideoToSystemBlits =FALSE;	// Does hardware support video mem to system mem blits?
BOOL						SystemToSystemBlits = FALSE; 	// Does hardware support system mem to system mem blits?
BOOL						OverlappedVideoBlits = TRUE;	// Can video driver blit overlapped regions?

/*
** Function to call if we detect focus loss
*/
extern	void (*Misc_Focus_Loss_Function)(void) = NULL;
extern	void (*Misc_Focus_Restore_Function)(void) = NULL;


/***********************************************************************************************
 * Process_DD_Result -- Does a message box based on the result of a DD command                 *
 *                                                                                             *
 * INPUT:		HRESULT result				- the result returned from the direct draw command		  *
 *             int     display_ok_msg	- should a message be displayed if command ok			  *                                                                                      *
 *                                                                                             *
 * OUTPUT:		none																									  *
 *                                                                                             *
 * HISTORY:                                                                                    *
 *   09/27/1995 PWG : Created.                                                                 *
 *=============================================================================================*/
void Process_DD_Result(HRESULT result, int display_ok_msg)
{
	switch (result) {
		case DD_OK:
			if (display_ok_msg) {
				MessageBox(MainWindow, "Direct Draw request went ok.", "Note", MB_ICONEXCLAMATION|MB_OK);
         }
			break;
		case DDERR_ALREADYINITIALIZED:
			MessageBox(MainWindow, "This object is already initialized ","Note", MB_ICONEXCLAMATION|MB_OK);
			break;
		case DDERR_BLTFASTCANTCLIP:
			MessageBox(MainWindow, "Return if a clipper object is attached to the source surface passed into a BltFast call.","Note", MB_ICONEXCLAMATION|MB_OK);
			break;
		case DDERR_CANNOTATTACHSURFACE:
			MessageBox(MainWindow, "This surface can not be attached to the requested surface.	","Note", MB_ICONEXCLAMATION|MB_OK);
			break;
		case DDERR_CANNOTDETACHSURFACE:
			MessageBox(MainWindow, "This surface can not be detached from the requested surface.	","Note", MB_ICONEXCLAMATION|MB_OK);
			break;
		case DDERR_CANTCREATEDC:
			MessageBox(MainWindow, "Windows can not create any more DCs","Note", MB_ICONEXCLAMATION|MB_OK);
			break;
		case DDERR_CANTDUPLICATE:
			MessageBox(MainWindow, "Can't duplicate primary & 3D surfaces, or surfaces that are implicitly created.","Note", MB_ICONEXCLAMATION|MB_OK);
			break;
		case DDERR_CANTLOCKSURFACE:
			MessageBox(MainWindow, "Unable to lock surface because no driver exists which can supply a pointer to the surface.","Note", MB_ICONEXCLAMATION|MB_OK);
			break;
		case DDERR_CLIPPERISUSINGHWND:
			MessageBox(MainWindow, "An attempt was made to set a cliplist for a clipper object that is already monitoring an hwnd.","Note", MB_ICONEXCLAMATION|MB_OK);
			break;
		case DDERR_COLORKEYNOTSET:
			MessageBox(MainWindow, "No src color key specified for this operation.","Note", MB_ICONEXCLAMATION|MB_OK);
			break;
		case DDERR_CURRENTLYNOTAVAIL:
			MessageBox(MainWindow, "Support is currently not available.	","Note", MB_ICONEXCLAMATION|MB_OK);
			break;
		case DDERR_DIRECTDRAWALREADYCREATED:
			MessageBox(MainWindow, "A DirectDraw object representing this driver has already been created for this process.	","Note", MB_ICONEXCLAMATION|MB_OK);
			break;
		case DDERR_EXCEPTION:
			MessageBox(MainWindow, "An exception was encountered while performing the requested operation.	","Note", MB_ICONEXCLAMATION|MB_OK);
			break;
		case DDERR_EXCLUSIVEMODEALREADYSET:
			MessageBox(MainWindow, "An attempt was made to set the cooperative level when it was already set to exclusive.","Note", MB_ICONEXCLAMATION|MB_OK);
			break;
		case DDERR_GENERIC:
			MessageBox(MainWindow, "Generic failure.","Note", MB_ICONEXCLAMATION|MB_OK);
			break;
		case DDERR_HEIGHTALIGN:
			MessageBox(MainWindow, "Height of rectangle provided is not a multiple of reqd alignment.","Note", MB_ICONEXCLAMATION|MB_OK);
			break;
		case DDERR_HWNDALREADYSET:
			MessageBox(MainWindow, "The CooperativeLevel HWND has already been set. It can not be reset while the process has surfaces or palettes created.","Note", MB_ICONEXCLAMATION|MB_OK);
			break;
		case DDERR_HWNDSUBCLASSED:
			MessageBox(MainWindow, "HWND used by DirectDraw CooperativeLevel has been subclassed, this prevents DirectDraw from restoring state.","Note", MB_ICONEXCLAMATION|MB_OK);
			break;
		case DDERR_IMPLICITLYCREATED:
			MessageBox(MainWindow, "This surface can not be restored because it is an implicitly created surface.","Note", MB_ICONEXCLAMATION|MB_OK);
			break;
		case DDERR_INCOMPATIBLEPRIMARY:
			MessageBox(MainWindow, "Unable to match primary surface creation request with existing primary surface.","Note", MB_ICONEXCLAMATION|MB_OK);
			break;
		case DDERR_INVALIDCAPS:
			MessageBox(MainWindow, "One or more of the caps bits passed to the callback are incorrect.","Note", MB_ICONEXCLAMATION|MB_OK);
			break;
		case DDERR_INVALIDCLIPLIST:
			MessageBox(MainWindow, "DirectDraw does not support the provided cliplist.","Note", MB_ICONEXCLAMATION|MB_OK);
			break;
		case DDERR_INVALIDDIRECTDRAWGUID:
			MessageBox(MainWindow, "The GUID passed to DirectDrawCreate is not a valid DirectDraw driver identifier.","Note", MB_ICONEXCLAMATION|MB_OK);
			break;
		case DDERR_INVALIDMODE:
			MessageBox(MainWindow, "DirectDraw does not support the requested mode.","Note", MB_ICONEXCLAMATION|MB_OK);
			break;
		case DDERR_INVALIDOBJECT:
			MessageBox(MainWindow, "DirectDraw received a pointer that was an invalid DIRECTDRAW object.","Note", MB_ICONEXCLAMATION|MB_OK);
			break;
		case DDERR_INVALIDPARAMS:
			MessageBox(MainWindow, "One or more of the parameters passed to the function are incorrect.","Note", MB_ICONEXCLAMATION|MB_OK);
			break;
		case DDERR_INVALIDPIXELFORMAT:
			MessageBox(MainWindow, "The pixel format was invalid as specified.","Note", MB_ICONEXCLAMATION|MB_OK);
			break;
		case DDERR_INVALIDPOSITION:
			MessageBox(MainWindow, "Returned when the position of the overlay on the destination is no longer legal for that destination.","Note", MB_ICONEXCLAMATION|MB_OK);
			break;
		case DDERR_INVALIDRECT:
			MessageBox(MainWindow, "Rectangle provided was invalid.","Note", MB_ICONEXCLAMATION|MB_OK);
			break;

		case DDERR_INVALIDSURFACETYPE:
			MessageBox(MainWindow, "The requested action could not be performed because the surface was of the wrong type.","Note", MB_ICONEXCLAMATION|MB_OK);
			break;
		case DDERR_LOCKEDSURFACES:
			MessageBox(MainWindow, "Operation could not be carried out because one or more surfaces are locked.","Note", MB_ICONEXCLAMATION|MB_OK);
			break;
		case DDERR_NO3D:
			MessageBox(MainWindow, "There is no 3D present.","Note", MB_ICONEXCLAMATION|MB_OK);
			break;
		case DDERR_NOALPHAHW:
			MessageBox(MainWindow, "Operation could not be carried out because there is no alpha accleration hardware present or available.","Note", MB_ICONEXCLAMATION|MB_OK);
			break;
#if(0)
		case DDERR_NOANTITEARHW:
			MessageBox(MainWindow, "Operation could not be carried out because there is no hardware support for synchronizing blts to avoid tearing.	","Note", MB_ICONEXCLAMATION|MB_OK);
			break;
#endif
		case DDERR_NOBLTHW:
			MessageBox(MainWindow, "No blter hardware present.","Note", MB_ICONEXCLAMATION|MB_OK);
			break;
#if(0)
		case DDERR_NOBLTQUEUEHW:
			MessageBox(MainWindow, "Operation could not be carried out because there is no hardware support for asynchronous blting.	","Note", MB_ICONEXCLAMATION|MB_OK);
			break;
#endif
		case DDERR_NOCLIPLIST:
			MessageBox(MainWindow, "No cliplist available.","Note", MB_ICONEXCLAMATION|MB_OK);
			break;
		case DDERR_NOCLIPPERATTACHED:
			MessageBox(MainWindow, "No clipper object attached to surface object.","Note", MB_ICONEXCLAMATION|MB_OK);
			break;
		case DDERR_NOCOLORCONVHW:
			MessageBox(MainWindow, "Operation could not be carried out because there is no color conversion hardware present or available.","Note", MB_ICONEXCLAMATION|MB_OK);
			break;
		case DDERR_NOCOLORKEY:
			MessageBox(MainWindow, "Surface doesn't currently have a color key","Note", MB_ICONEXCLAMATION|MB_OK);
			break;
		case DDERR_NOCOLORKEYHW:
			MessageBox(MainWindow, "Operation could not be carried out because there is no hardware support of the destination color key.","Note", MB_ICONEXCLAMATION|MB_OK);
			break;
		case DDERR_NOCOOPERATIVELEVELSET:
			MessageBox(MainWindow, "Create function called without DirectDraw object method SetCooperativeLevel being called.","Note", MB_ICONEXCLAMATION|MB_OK);
			break;
		case DDERR_NODC:
			MessageBox(MainWindow, "No DC was ever created for this surface.","Note", MB_ICONEXCLAMATION|MB_OK);
			break;
		case DDERR_NODDROPSHW:
			MessageBox(MainWindow, "No DirectDraw ROP hardware.","Note", MB_ICONEXCLAMATION|MB_OK);
			break;
		case DDERR_NODIRECTDRAWHW:
			MessageBox(MainWindow, "A hardware-only DirectDraw object creation was attempted but the driver did not support any hardware.","Note", MB_ICONEXCLAMATION|MB_OK);
			break;
		case DDERR_NODIRECTDRAWSUPPORT:
			MessageBox(MainWindow, "No DirectDraw support possible with current display driver.","Note", MB_ICONEXCLAMATION|MB_OK);
			break;
		case DDERR_NOEMULATION:
			MessageBox(MainWindow, "Software emulation not available.","Note", MB_ICONEXCLAMATION|MB_OK);
			break;
		case DDERR_NOEXCLUSIVEMODE:
			MessageBox(MainWindow, "Operation requires the application to have exclusive mode but the application does not have exclusive mode.","Note", MB_ICONEXCLAMATION|MB_OK);
			break;
		case DDERR_NOFLIPHW:
			MessageBox(MainWindow, "Flipping visible surfaces is not supported.","Note", MB_ICONEXCLAMATION|MB_OK);
			break;
		case DDERR_NOGDI:
			MessageBox(MainWindow, "There is no GDI present.","Note", MB_ICONEXCLAMATION|MB_OK);
			break;
		case DDERR_NOHWND:
			MessageBox(MainWindow, "Clipper notification requires an HWND or no HWND has previously been set as the CooperativeLevel HWND.","Note", MB_ICONEXCLAMATION|MB_OK);
			break;
		case DDERR_NOMIRRORHW:
			MessageBox(MainWindow, "Operation could not be carried out because there is no hardware present or available.","Note", MB_ICONEXCLAMATION|MB_OK);
			break;
		case DDERR_NOOVERLAYDEST:
			MessageBox(MainWindow, "Returned when GetOverlayPosition is called on an overlay that UpdateOverlay has never been called on to establish a destination.","Note", MB_ICONEXCLAMATION|MB_OK);
			break;
		case DDERR_NOOVERLAYHW:
			MessageBox(MainWindow, "Operation could not be carried out because there is no overlay hardware present or available.","Note", MB_ICONEXCLAMATION|MB_OK);
			break;
		case DDERR_NOPALETTEATTACHED:
			MessageBox(MainWindow, "No palette object attached to this surface.	","Note", MB_ICONEXCLAMATION|MB_OK);
			break;
		case DDERR_NOPALETTEHW:
			MessageBox(MainWindow, "No hardware support for 16 or 256 color palettes.","Note", MB_ICONEXCLAMATION|MB_OK);
			break;
		case DDERR_NORASTEROPHW:
			MessageBox(MainWindow, "Operation could not be carried out because there is no appropriate raster op hardware present or available.","Note", MB_ICONEXCLAMATION|MB_OK);
			break;
		case DDERR_NOROTATIONHW:
			MessageBox(MainWindow, "Operation could not be carried out because there is no rotation hardware present or available.","Note", MB_ICONEXCLAMATION|MB_OK);
			break;
		case DDERR_NOSTRETCHHW:
			MessageBox(MainWindow, "Operation could not be carried out because there is no hardware support for stretching.","Note", MB_ICONEXCLAMATION|MB_OK);
			break;
		case DDERR_NOT4BITCOLOR:
			MessageBox(MainWindow, "DirectDrawSurface is not in 4 bit color palette and the requested operation requires 4 bit color palette.","Note", MB_ICONEXCLAMATION|MB_OK);
			break;
		case DDERR_NOT4BITCOLORINDEX:
			MessageBox(MainWindow, "DirectDrawSurface is not in 4 bit color index palette and the requested operation requires 4 bit color index palette.","Note", MB_ICONEXCLAMATION|MB_OK);
			break;
		case DDERR_NOT8BITCOLOR:
			MessageBox(MainWindow, "DirectDrawSurface is not in 8 bit color mode and the requested operation requires 8 bit color.","Note", MB_ICONEXCLAMATION|MB_OK);
			break;
		case DDERR_NOTAOVERLAYSURFACE:
			MessageBox(MainWindow, "Returned when an overlay member is called for a non-overlay surface.","Note", MB_ICONEXCLAMATION|MB_OK);
			break;
		case DDERR_NOTEXTUREHW:
			MessageBox(MainWindow, "Operation could not be carried out because there is no texture mapping hardware present or available.","Note", MB_ICONEXCLAMATION|MB_OK);
			break;
		case DDERR_NOTFLIPPABLE:
			MessageBox(MainWindow, "An attempt has been made to flip a surface that is not flippable.","Note", MB_ICONEXCLAMATION|MB_OK);
			break;
		case DDERR_NOTFOUND:
			MessageBox(MainWindow, "Requested item was not found.","Note", MB_ICONEXCLAMATION|MB_OK);
			break;
		case DDERR_NOTLOCKED:
			MessageBox(MainWindow, "Surface was not locked.  An attempt to unlock a surface that was not locked at all, or by this process, has been attempted.","Note", MB_ICONEXCLAMATION|MB_OK);
			break;
		case DDERR_NOTPALETTIZED:
			MessageBox(MainWindow, "The surface being used is not a palette-based surface.","Note", MB_ICONEXCLAMATION|MB_OK);
			break;
		case DDERR_NOVSYNCHW:
			MessageBox(MainWindow, "Operation could not be carried out because there is no hardware support for vertical blank synchronized operations.","Note", MB_ICONEXCLAMATION|MB_OK);
			break;
		case DDERR_NOZBUFFERHW:
			MessageBox(MainWindow, "Operation could not be carried out because there is no hardware support for zbuffer blting.","Note", MB_ICONEXCLAMATION|MB_OK);
			break;
		case DDERR_NOZOVERLAYHW:
			MessageBox(MainWindow, "Overlay surfaces could not be z layered based on their BltOrder because the hardware does not support z layering of overlays.","Note", MB_ICONEXCLAMATION|MB_OK);
			break;
		case DDERR_OUTOFCAPS:
			MessageBox(MainWindow, "The hardware needed for the requested operation has already been allocated.","Note", MB_ICONEXCLAMATION|MB_OK);
			break;
		case DDERR_OUTOFMEMORY:
			MessageBox(MainWindow, "DirectDraw does not have enough memory to perform the operation.","Note", MB_ICONEXCLAMATION|MB_OK);
			break;
		case DDERR_OUTOFVIDEOMEMORY:
			MessageBox(MainWindow, "DirectDraw does not have enough memory to perform the operation.","Note", MB_ICONEXCLAMATION|MB_OK);
			break;
		case DDERR_OVERLAYCANTCLIP:
			MessageBox(MainWindow, "The hardware does not support clipped overlays.","Note", MB_ICONEXCLAMATION|MB_OK);
			break;
		case DDERR_OVERLAYCOLORKEYONLYONEACTIVE:
			MessageBox(MainWindow, "Can only have ony color key active at one time for overlays.","Note", MB_ICONEXCLAMATION|MB_OK);
			break;
		case DDERR_OVERLAYNOTVISIBLE:
			MessageBox(MainWindow, "Returned when GetOverlayPosition is called on a hidden overlay.","Note", MB_ICONEXCLAMATION|MB_OK);
			break;
		case DDERR_PALETTEBUSY:
			MessageBox(MainWindow, "Access to this palette is being refused because the palette is already locked by another thread.","Note", MB_ICONEXCLAMATION|MB_OK);
			break;
		case DDERR_PRIMARYSURFACEALREADYEXISTS:
			MessageBox(MainWindow, "This process already has created a primary surface.","Note", MB_ICONEXCLAMATION|MB_OK);
			break;
		case DDERR_REGIONTOOSMALL:
			MessageBox(MainWindow, "Region passed to Clipper::GetClipList is too small.","Note", MB_ICONEXCLAMATION|MB_OK);
			break;
		case DDERR_SURFACEALREADYATTACHED:
			MessageBox(MainWindow, "This surface is already attached to the surface it is being attached to.","Note", MB_ICONEXCLAMATION|MB_OK);
			break;
		case DDERR_SURFACEALREADYDEPENDENT:
			MessageBox(MainWindow, "This surface is already a dependency of the surface it is being made a dependency of.","Note", MB_ICONEXCLAMATION|MB_OK);
			break;
		case DDERR_SURFACEBUSY:
			MessageBox(MainWindow, "Access to this surface is being refused because the surface is already locked by another thread.","Note", MB_ICONEXCLAMATION|MB_OK);
			break;
		case DDERR_SURFACEISOBSCURED:
			MessageBox(MainWindow, "Access to surface refused because the surface is obscured.","Note", MB_ICONEXCLAMATION|MB_OK);
			break;
		case DDERR_SURFACELOST:
			MessageBox(MainWindow, "Access to this surface is being refused because the surface memory is gone. The DirectDrawSurface object representing this surface should have Restore called on it.","Note", MB_ICONEXCLAMATION|MB_OK);
			break;
		case DDERR_SURFACENOTATTACHED:
			MessageBox(MainWindow, "The requested surface is not attached.","Note", MB_ICONEXCLAMATION|MB_OK);
			break;
		case DDERR_TOOBIGHEIGHT:
			MessageBox(MainWindow, "Height requested by DirectDraw is too large.","Note", MB_ICONEXCLAMATION|MB_OK);
			break;
		case DDERR_TOOBIGSIZE:
			MessageBox(MainWindow, "Size requested by DirectDraw is too large --	the individual height and width are OK.","Note", MB_ICONEXCLAMATION|MB_OK);
			break;
		case DDERR_TOOBIGWIDTH:
			MessageBox(MainWindow, "Width requested by DirectDraw is too large.","Note", MB_ICONEXCLAMATION|MB_OK);
			break;
		case DDERR_UNSUPPORTED:
			MessageBox(MainWindow, "Action not supported.","Note", MB_ICONEXCLAMATION|MB_OK);
			break;
		case DDERR_UNSUPPORTEDFORMAT:
			MessageBox(MainWindow, "FOURCC format requested is unsupported by DirectDraw.","Note", MB_ICONEXCLAMATION|MB_OK);
			break;
		case DDERR_UNSUPPORTEDMASK:
			MessageBox(MainWindow, "Bitmask in the pixel format requested is unsupported by DirectDraw.","Note", MB_ICONEXCLAMATION|MB_OK);
			break;
		case DDERR_VERTICALBLANKINPROGRESS:
			MessageBox(MainWindow, "Vertical blank is in progress.","Note", MB_ICONEXCLAMATION|MB_OK);
			break;
		case DDERR_WASSTILLDRAWING:
			MessageBox(MainWindow, "Informs DirectDraw that the previous Blt which is transfering information to or from this Surface is incomplete.","Note", MB_ICONEXCLAMATION|MB_OK);
			break;
		case DDERR_WRONGMODE:
			MessageBox(MainWindow, "This surface can not be restored because it was created in a different mode.","Note", MB_ICONEXCLAMATION|MB_OK);
			break;
		case DDERR_XALIGN:
			MessageBox(MainWindow, "Rectangle provided was not horizontally aligned on required boundary.","Note", MB_ICONEXCLAMATION|MB_OK);
			break;
		default:
			char string[256];
			sprintf (string, "Unrecognised Direct Draw result code: %d", result & 0xffff);
			MessageBox(MainWindow, string,"Note", MB_ICONEXCLAMATION|MB_OK);
			break;
	}
}



/***********************************************************************************************
 * Check_Overlapped_Blit_Capability -- See if video driver supports blitting overlapped regions*
 *                                                                                             *
 *  We will check for this by drawing something to a video page and blitting it over itself.   *
 * If we end up with the top line repeating then overlapped region blits dont work.            *
 *                                                                                             *
 * INPUT:    Nothing                                                                           *
 *                                                                                             *
 * OUTPUT:   Nothing                                                                           *
 *                                                                                             *
 * WARNINGS: None                                                                              *
 *                                                                                             *
 * HISTORY:                                                                                    *
 *    6/7/96 5:06PM ST : Created                                                               *
 *=============================================================================================*/
void Check_Overlapped_Blit_Capability(void)
{

	/*
	** Assume we can until we find out otherwise
	*/
	OverlappedVideoBlits = TRUE;

	GraphicBufferClass test_buffer;

	test_buffer.Init (64, 64, NULL, 0, (GBC_Enum)GBC_VIDEOMEM);

	test_buffer.Clear();

	/*
	** Plot a pixel in the top left corner of the buffer.
	*/
	test_buffer.Put_Pixel(0, 0, 255);

	/*
	** Blit the buffer down by one line. If we end up with a vertical strip of pixel 255's then
	** overlapped blits dont work
	*/

	test_buffer.Blit(test_buffer, 0, 0, 0, 1, test_buffer.Get_Width(), test_buffer.Get_Height()-1);

	if (test_buffer.Get_Pixel (0 ,5) == 255) OverlappedVideoBlits = FALSE;
}



/***********************************************************************************************
 * Set_Video_Mode -- Initializes Direct Draw and sets the required Video Mode                  *
 *                                                                                             *
 * INPUT:  		int width   			- the width of the video mode in pixels						  *
 *					int height           - the height of the video mode in pixels                   *
 *					int bits_per_pixel	- the number of bits per pixel the video mode supports     *
 *                                                                                             *
 * OUTPUT:     none                                                                            *
 *                                                                                             *
 * HISTORY:                                                                                    *
 *   09/26/1995 PWG : Created.                                                                 *
 *=============================================================================================*/
BOOL Set_Video_Mode(HWND hwnd, int w, int h, int bits_per_pixel)
{
// ST - 1/3/2019 10:41AM
#ifndef _MSC_VER
	// TIM-141: Linux native SDL2 entry. The original DirectDraw path below
	// (#if(0)) is dead on every platform after Steve Tall's 2019 stub.
	// On the MSVC build this function still returns TRUE without doing
	// anything; on Linux we open a real SDL window + renderer + indexed
	// primary surface so the rest of the engine has something to talk to
	// once the GBUFFER consumers migrate (TIM-141 commit 2-3).
	if (SDL_VideoWindow == nullptr) {
		// TIM-152 pass-46B: adopt a window the substrate already owns
		// (rare — would only fire if SDL_Get_Main_Window() ran before
		// us). Fall through to the create-and-register path otherwise.
		SDL_VideoWindow = static_cast<SDL_Window *>(SDL_Get_Main_Window());
		if (SDL_VideoWindow != nullptr) {
			SDL_SetWindowSize(SDL_VideoWindow, w, h);
		} else {
			if (SDL_WasInit(SDL_INIT_VIDEO) == 0) {
				if (SDL_InitSubSystem(SDL_INIT_VIDEO) != 0) {
					return FALSE;
				}
			}
#ifdef __EMSCRIPTEN__
			// TIM-582: set keyboard-element hint before SDL_CreateWindow so the
			// Emscripten backend registers key listeners on #canvas, not #window.
			SDL_SetHint(SDL_HINT_EMSCRIPTEN_KEYBOARD_ELEMENT, "#canvas");
			SDL_SetHint(SDL_HINT_TOUCH_MOUSE_EVENTS, "1");
#endif
			SDL_VideoWindow = SDL_CreateWindow(
				"Red Alert",
				SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
				w, h,
#ifdef __EMSCRIPTEN__
				SDL_WINDOW_SHOWN);  // canvas is always visible in browser
#else
				SDL_WINDOW_HIDDEN);  // hidden until the engine drives a frame
#endif
			if (SDL_VideoWindow == nullptr) {
				return FALSE;
			}
			SDL_Set_Main_Window(SDL_VideoWindow);
		}
#ifdef __EMSCRIPTEN__
		// TIM-399: Use software renderer — SDL_RENDERER_ACCELERATED requires
		// OffscreenCanvas + WebGL from a PROXY_TO_PTHREAD Worker, which crashes
		// with GLctx=undefined (no -sOFFSCREENCANVAS_SUPPORT link flag).
		// SDL2's software renderer uses the canvas 2D API via Emscripten's
		// proxy mechanism and avoids WebGL entirely.
		SDL_VideoRenderer = SDL_CreateRenderer(SDL_VideoWindow, -1,
		                                       SDL_RENDERER_SOFTWARE);
		if (SDL_VideoRenderer == nullptr) {
			SDL_VideoRenderer = SDL_CreateRenderer(SDL_VideoWindow, -1, 0);
		}
#else
		// TIM-908: prefer hardware-accelerated rendering when available.
		// TIM-250 originally forced SOFTWARE because SDL_RENDERER_ACCELERATED
		// crashed under Xvfb at 640×480. The new strategy tries accelerated
		// first and falls back to software when the driver isn't available
		// (Xvfb, headless CI, missing GPU drivers). Set RA_SOFTWARE_RENDERER=1
		// to force the software path regardless.
		{
			const char* forceSw = getenv("RA_SOFTWARE_RENDERER");
			if (forceSw && forceSw[0] == '1') {
				SDL_VideoRenderer = SDL_CreateRenderer(
					SDL_VideoWindow, -1, SDL_RENDERER_SOFTWARE);
			} else {
				SDL_VideoRenderer = SDL_CreateRenderer(
					SDL_VideoWindow, -1,
					SDL_RENDERER_ACCELERATED | SDL_RENDERER_PRESENTVSYNC);
				if (SDL_VideoRenderer == nullptr) {
					fprintf(stderr, "[RA] accelerated renderer unavailable, trying software\n");
					SDL_VideoRenderer = SDL_CreateRenderer(
						SDL_VideoWindow, -1, SDL_RENDERER_SOFTWARE);
				} else {
					fprintf(stderr, "[RA] using hardware-accelerated renderer\n");
				}
			}
		}
#endif
		fprintf(stderr, "[RA] SDL window %dx%d renderer=%p\n",
		        w, h, (void *)SDL_VideoRenderer);
		SDL_Set_Main_Renderer(SDL_VideoRenderer); // TIM-675: expose for integer-scale fullscreen
		// Indexed 8-bit primary surface; palette is filled in by
		// Set_DD_Palette and applied via SDL_SetPaletteColors.
		SDL_PrimarySurface = SDL_CreateRGBSurfaceWithFormat(
			0, w, h, 8, SDL_PIXELFORMAT_INDEX8);
	}
	return TRUE;
#else
	return TRUE;
#endif
#if (0)
	HRESULT result;
	//
	// If there is not currently a direct draw object then we need to define one.
	//
	if ( DirectDrawObject == NULL ){
		//MessageBox(MainWindow, "In Set_Video_Mode. About to call DirectDrawCreate.","Note", MB_ICONEXCLAMATION|MB_OK);
		result = DirectDrawCreate(NULL, &DirectDrawObject, NULL);
		Process_DD_Result(result, FALSE);
		if (result == DD_OK){
			if (w==320){
				result = DirectDrawObject->SetCooperativeLevel(hwnd, DDSCL_EXCLUSIVE | DDSCL_FULLSCREEN | DDSCL_ALLOWMODEX);
			} else {
				//MessageBox(MainWindow, "In Set_Video_Mode. About to call SetCooperativeLevel.","Note", MB_ICONEXCLAMATION|MB_OK);
				result = DirectDrawObject->SetCooperativeLevel(hwnd, DDSCL_EXCLUSIVE | DDSCL_FULLSCREEN);
			}
			Process_DD_Result(result, FALSE);
		}else{
			return (FALSE);
		}
	}

	//
	// Set the required display mode with 8 bits per pixel
	//
	//MessageBox(MainWindow, "In Set_Video_Mode. About to call call SetDisplayMode.","Note", MB_ICONEXCLAMATION|MB_OK);
	result = DirectDrawObject->SetDisplayMode ( w , h , bits_per_pixel );
	if (result != DD_OK){
//		Process_DD_Result(result, FALSE);
		DirectDrawObject->Release();
		DirectDrawObject = NULL;
		return(FALSE);
	}

	//
	// Create a direct draw palette object
	//
	//MessageBox(MainWindow, "In Set_Video_Mode. About to call CreatePalette.","Note", MB_ICONEXCLAMATION|MB_OK);
	result = DirectDrawObject->CreatePalette( DDPCAPS_8BIT | DDPCAPS_ALLOW256, &PaletteEntries[0] , &PalettePtr ,NULL);
	Process_DD_Result(result, FALSE);
	if (result != DD_OK){
		return (FALSE);
	}

	Check_Overlapped_Blit_Capability();

	//MessageBox(MainWindow, "In Set_Video_Mode. About to return success.","Note", MB_ICONEXCLAMATION|MB_OK);
#if (0)
	/*
	** Find out if DirectX 2 extensions are available
	*/
	result = DirectDrawObject->QueryInterface (IID_IDirectDraw2, (LPVOID*)&DirectDraw2Interface);
	SystemToVideoBlits = FALSE;
	VideoToSystemBlits = FALSE;
	SystemToSystemBlits= FALSE;
	if (result != DD_OK){
		DirectDraw2Interface = NULL;
	}else{
		DDCAPS capabilities;
		DDCAPS emulated_capabilities;

		memset ((char*)&capabilities, 0, sizeof(capabilities));
		memset ((char*)&emulated_capabilities, 0, sizeof(emulated_capabilities));
		capabilities.dwSize = sizeof (capabilities);
		emulated_capabilities.dwSize = sizeof (emulated_capabilities);

		DirectDrawObject->GetCaps (&capabilities, &emulated_capabilities);

		if (capabilities.dwCaps & DDCAPS_CANBLTSYSMEM){
			SystemToVideoBlits = (capabilities.dwSVBCaps & DDCAPS_BLT) ? TRUE : FALSE;
			VideoToSystemBlits = (capabilities.dwVSBCaps & DDCAPS_BLT) ? TRUE : FALSE;
			SystemToSystemBlits = (capabilities.dwSSBCaps & DDCAPS_BLT) ? TRUE : FALSE;
		}
	}
#endif	//(0)

	//MessageBox(MainWindow, "In Set_Video_Mode. About to return success.","Note", MB_ICONEXCLAMATION|MB_OK);

	return (TRUE);
#endif
}

/***********************************************************************************************
 * Reset_Video_Mode -- Resets video mode and deletes Direct Draw Object                        *
 *                                                                                             *
 * INPUT:		none                                                                            *
 *                                                                                             *
 * OUTPUT:     none                                                                            *
 *                                                                                             *
 * WARNINGS:                                                                                   *
 *                                                                                             *
 * HISTORY:                                                                                    *
 *   09/26/1995 PWG : Created.                                                                 *
 *=============================================================================================*/
void Reset_Video_Mode(void)
{
#ifndef _MSC_VER
	// TIM-141: Linux SDL2 teardown. Mirrors the open path in Set_Video_Mode.
	// Texture and ARGB intermediate are commit-5 present-pump caches and
	// must be freed before the renderer they were created against.
	if (SDL_PrimaryTexture) {
		SDL_DestroyTexture(SDL_PrimaryTexture);
		SDL_PrimaryTexture = nullptr;
	}
	if (SDL_PrimaryARGB) {
		SDL_FreeSurface(SDL_PrimaryARGB);
		SDL_PrimaryARGB = nullptr;
	}
	SDL_CachedW = 0;
	SDL_CachedH = 0;
	SDL_FirstPresentDone = false;
	if (SDL_PrimarySurface) {
		SDL_FreeSurface(SDL_PrimarySurface);
		SDL_PrimarySurface = nullptr;
	}
	if (SDL_VideoRenderer) {
		SDL_Set_Main_Renderer(nullptr); // TIM-675: unregister before destroy
		SDL_DestroyRenderer(SDL_VideoRenderer);
		SDL_VideoRenderer = nullptr;
	}
	if (SDL_VideoWindow) {
		// TIM-152 pass-46B: unregister with the substrate before
		// destroy so any later SDL_Get_Main_Window() caller sees the
		// teardown rather than a dangling pointer.
		SDL_Set_Main_Window(nullptr);
		SDL_DestroyWindow(SDL_VideoWindow);
		SDL_VideoWindow = nullptr;
	}
	if (SDL_WasInit(SDL_INIT_VIDEO)) {
		SDL_QuitSubSystem(SDL_INIT_VIDEO);
	}
#else
	HRESULT result;

	//
	// If a direct draw object has been declared and a video mode has been set
	// then reset the video mode and release the direct draw object.
	//
	if ( DirectDrawObject ) {
		result = DirectDrawObject->RestoreDisplayMode();
		Process_DD_Result(result, FALSE);
		result = DirectDrawObject->Release();
		Process_DD_Result(result, FALSE);

		DirectDrawObject = NULL;
	}
#endif
}




/***********************************************************************************************
 * Get_Free_Video_Memory -- returns amount of free video memory                                *
 *                                                                                             *
 *                                                                                             *
 *                                                                                             *
 * INPUT:    Nothing                                                                           *
 *                                                                                             *
 * OUTPUT:   bytes of available video RAM                                                      *
 *                                                                                             *
 * WARNINGS: None                                                                              *
 *                                                                                             *
 * HISTORY:                                                                                    *
 *    11/29/95 12:52PM ST : Created                                                            *
 *=============================================================================================*/
unsigned int Get_Free_Video_Memory(void)
{
#ifndef _MSC_VER
	// TIM-141: SDL2 has no fixed VRAM ceiling on Linux; report effectively
	// unlimited. The only call sites (STARTUP.CPP stats logging) just record
	// the value, so this is safe.
	return (unsigned int)INT_MAX;
#else
	DDCAPS	video_capabilities;

	if (DirectDrawObject){

		video_capabilities.dwSize = sizeof (video_capabilities);

		//MessageBox(MainWindow, "In Get_Free_Video_Memory. About to call GetCaps","Note", MB_ICONEXCLAMATION|MB_OK);
		if (DD_OK == DirectDrawObject->GetCaps (&video_capabilities , NULL)){
			char string [256];
			sprintf (string, "In Get_Free_Video_Memory. About to return %d bytes",video_capabilities.dwVidMemFree);
			//MessageBox(MainWindow, string,"Note", MB_ICONEXCLAMATION|MB_OK);
			return (video_capabilities.dwVidMemFree);
		}
	}

	//MessageBox(MainWindow, "In Get_Free_Video_Memory. About to return failure","Note", MB_ICONEXCLAMATION|MB_OK);
	return (0);
#endif
}




/***********************************************************************************************
 * Get_Video_Hardware_Caps -- returns bitmask of direct draw video hardware support            *
 *                                                                                             *
 *                                                                                             *
 *                                                                                             *
 * INPUT:    Nothing                                                                           *
 *                                                                                             *
 * OUTPUT:   hardware flags                                                                    *
 *                                                                                             *
 * WARNINGS: Must call Set_Video_Mode 1st to create the direct draw object                     *
 *                                                                                             *
 * HISTORY:                                                                                    *
 *    1/12/96 9:14AM ST : Created                                                              *
 *=============================================================================================*/
unsigned Get_Video_Hardware_Capabilities(void)
{
#ifndef _MSC_VER
	// TIM-141: SDL2 doesn't expose DirectDraw hardware-blit caps. Report no
	// hardware acceleration so callers fall through to the software paths
	// they already implement (STARTUP.CPP stats logging, INIT.CPP feature
	// gates). The native renderer in commit 3+ will surface real caps.
	return 0;
#else
	DDCAPS	video_capabilities;
	unsigned	video;

	/*
	** Fail if the direct draw object has not been initialised
	*/
	if (!DirectDrawObject) return (0);

	/*
	** Get the capabilities of the direct draw object
	*/
	video_capabilities.dwSize = sizeof(video_capabilities);
	//MessageBox(MainWindow, "In Get_Video_Hardware_Capabilities. About to call GetCaps","Note", MB_ICONEXCLAMATION|MB_OK);
	HRESULT result = DirectDrawObject->GetCaps (&video_capabilities, NULL);
	if (result != DD_OK){
		Process_DD_Result(result, FALSE);
		return (0);
	}

	/*
	** Set flags to indicate the presence of the features we are interested in
	*/
	video = 0;

	/* Hardware blits supported? */
	if (video_capabilities.dwCaps & DDCAPS_BLT) 				video |= VIDEO_BLITTER;

	/* Hardware blits asyncronous? */
	if (video_capabilities.dwCaps & DDCAPS_BLTQUEUE) 		video |= VIDEO_BLITTER_ASYNC;

	/* Can palette changes be synced to vertical refresh? */
	if (video_capabilities.dwCaps & DDCAPS_PALETTEVSYNC) 	video |= VIDEO_SYNC_PALETTE;

	/* Is the video cards memory bank switched? */
	if (video_capabilities.dwCaps & DDCAPS_BANKSWITCHED) 	video |= VIDEO_BANK_SWITCHED;

	/* Can the blitter do filled rectangles? */
	if (video_capabilities.dwCaps & DDCAPS_BLTCOLORFILL)	video |= VIDEO_COLOR_FILL;

	/* Is there no hardware assistance avaailable at all? */
	if (video_capabilities.dwCaps & DDCAPS_NOHARDWARE) 	video |= VIDEO_NO_HARDWARE_ASSIST;

	//MessageBox(MainWindow, "In Get_Video_Hardware_Capabilities. About to return success.","Note", MB_ICONEXCLAMATION|MB_OK);
	return (video);
#endif
}




/***********************************************************************************************
 * Wait_Vert_Blank -- Waits for the start (leading edge) of a vertical blank                   *
 *                                                                                             *
 * INPUT:                                                                                      *
 *                                                                                             *
 * OUTPUT:                                                                                     *
 *                                                                                             *
 * WARNINGS:                                                                                   *
 *                                                                                             *
 * HISTORY:                                                                                    *
 *=============================================================================================*/
extern int ScreenWidth;
void Wait_Vert_Blank(void)
{
#ifndef _MSC_VER
	// TIM-141 commit 6: pump window-class events first so focus
	// transitions and SDL_QUIT are observed on the actual frame
	// heartbeat. Must run before the early-out below — focus state
	// needs to flip even on the first call, when the renderer is
	// still being brought up.
	SDL_Process_Window_Events();

	// TIM-145 pass-43A: drain SDL_KEYDOWN/SDL_KEYUP into the
	// WWKeyboardClass ring. Producer is REDALERT/KEYBOARD.CPP. Order
	// after the window pump so a quit or focus event in the same
	// batch is observed first. Mouse buttons / motion stay queued
	// for pass-43B.
	SDL_Process_Input_Events();

	// TIM-141 commit 5: present pump. Indexed primary surface ->
	// SDL_BlitSurface (palette-aware) -> ARGB intermediate ->
	// SDL_UpdateTexture -> SDL_RenderCopy -> SDL_RenderPresent. The
	// renderer was created with SDL_RENDERER_PRESENTVSYNC in
	// Set_Video_Mode, so SDL_RenderPresent blocks to vblank — the
	// function name remains accurate.
	if (SDL_PrimarySurface == nullptr || SDL_VideoRenderer == nullptr) {
		return;
	}

	int w = SDL_PrimarySurface->w;
	int h = SDL_PrimarySurface->h;

	if (SDL_PrimaryTexture == nullptr || SDL_PrimaryARGB == nullptr ||
	    SDL_CachedW != w || SDL_CachedH != h) {
		if (SDL_PrimaryTexture) {
			SDL_DestroyTexture(SDL_PrimaryTexture);
			SDL_PrimaryTexture = nullptr;
		}
		if (SDL_PrimaryARGB) {
			SDL_FreeSurface(SDL_PrimaryARGB);
			SDL_PrimaryARGB = nullptr;
		}
		SDL_PrimaryTexture = SDL_CreateTexture(
			SDL_VideoRenderer,
			SDL_PIXELFORMAT_ARGB8888,
			SDL_TEXTUREACCESS_STREAMING,
			w, h);
		SDL_PrimaryARGB = SDL_CreateRGBSurfaceWithFormat(
			0, w, h, 32, SDL_PIXELFORMAT_ARGB8888);
		SDL_CachedW = w;
		SDL_CachedH = h;
		if (SDL_PrimaryTexture == nullptr || SDL_PrimaryARGB == nullptr) {
			return;
		}
	}

	// Palette-aware indexed->ARGB conversion.
	// TIM-573: Manual expansion using SDL_PaletteEntries[] instead of
	// SDL_BlitSurface. Emscripten's USE_SDL=2 port does not reliably use the
	// SDL surface palette when blitting INDEX8→ARGB8888 from a Worker thread,
	// producing wrong colours in VQA cinematics. SDL_PaletteEntries[] is
	// populated directly by Set_DD_Palette / Set_DD_Palette_8bit, so it is
	// always authoritative regardless of SDL surface-palette state.
	// TIM-250 debug: sanity-check surfaces before blit
	if (!SDL_PrimarySurface || !SDL_PrimarySurface->pixels ||
	    !SDL_PrimaryARGB || !SDL_PrimaryARGB->pixels) {
		fprintf(stderr, "[RA] Wait_Vert_Blank: null surface prim=%p/%p argb=%p/%p\n",
		        (void*)SDL_PrimarySurface,
		        SDL_PrimarySurface ? SDL_PrimarySurface->pixels : nullptr,
		        (void*)SDL_PrimaryARGB,
		        SDL_PrimaryARGB ? SDL_PrimaryARGB->pixels : nullptr);
		fflush(stderr);
		return;
	}
	int blit_rc = 0;
	// TIM-908: indexed→ARGB conversion using precomputed LUT.
	// Replaces the per-pixel SDL_Color dereference + three-shift
	// pattern with a single 256-entry uint32_t table lookup.
	{
		const uint8_t* src     = (const uint8_t*)SDL_PrimarySurface->pixels;
		uint32_t*      dst     = (uint32_t*)SDL_PrimaryARGB->pixels;
		int            srcPitch = SDL_PrimarySurface->pitch;
		int            dstPitch32 = SDL_PrimaryARGB->pitch / 4;
		const uint32_t* lut     = SDL_PaletteLUT;

		// TIM-908: profile conversion cost every 60 presents (~1s at 60fps)
		Uint64 t0 = 0;
		if (SDL_PresentCount % 60 == 0)
			t0 = SDL_GetPerformanceCounter();

		for (int y = 0; y < h; ++y) {
			const uint8_t* srcRow = src + y * srcPitch;
			uint32_t*      dstRow = dst + y * dstPitch32;
			for (int x = 0; x < w; ++x) {
				dstRow[x] = lut[srcRow[x]];
			}
		}

		if (SDL_PresentCount % 60 == 0) {
			Uint64 t1 = SDL_GetPerformanceCounter();
			Uint64 freq = SDL_GetPerformanceFrequency();
			long us = freq ? (long)(((t1 - t0) * 1000000ULL) / freq) : 0;
			fprintf(stderr, "[RA] frame%4d indexed→ARGB conv: %7ld µs (%dx%d)\n",
			        SDL_PresentCount, us, w, h);
		}
	}
	SDL_UpdateTexture(SDL_PrimaryTexture, nullptr,
	                  SDL_PrimaryARGB->pixels, SDL_PrimaryARGB->pitch);
	SDL_RenderClear(SDL_VideoRenderer);
	SDL_RenderCopy(SDL_VideoRenderer, SDL_PrimaryTexture, nullptr, nullptr);

	// TIM-619: CRT scanline overlay — horizontal dim rows at ~50% opacity.
	// Only active during VQA playback when VQA_SCANLINES env var is set.
	if (vqa_scanlines_active) {
		SDL_SetRenderDrawBlendMode(SDL_VideoRenderer, SDL_BLENDMODE_BLEND);
		SDL_SetRenderDrawColor(SDL_VideoRenderer, 0, 0, 0, 128);
		for (int sl = 1; sl < h; sl += 2)
			SDL_RenderDrawLine(SDL_VideoRenderer, 0, sl, w - 1, sl);
		SDL_SetRenderDrawBlendMode(SDL_VideoRenderer, SDL_BLENDMODE_NONE);
	}

	SDL_RenderPresent(SDL_VideoRenderer);

	// TIM-247: save frame 500 as BMP; also log raw indexed-surface samples
	// and palette to distinguish "all-zero surface" from "bad palette".
	// TIM-283: also save frame 1000 for tac-bottom zone audit.
	// TIM-490: also save frames 100 and 300 for post-radar gameplay audit.
	if (SDL_FirstPresentDone) ++SDL_PresentCount;
	if (SDL_FirstPresentDone && (SDL_PresentCount == 100 || SDL_PresentCount == 300 ||
	                              SDL_PresentCount == 500 || SDL_PresentCount == 1000)) {
		const char* bmp_path =
			(SDL_PresentCount == 100)  ? "/tmp/redalert-frame100.bmp"  :
			(SDL_PresentCount == 300)  ? "/tmp/redalert-frame300.bmp"  :
			(SDL_PresentCount == 500)  ? "/tmp/redalert-frame500.bmp"  :
			                             "/tmp/redalert-frame1000.bmp";
		int bmp_rc = SDL_SaveBMP(SDL_PrimaryARGB, bmp_path);
		const uint32_t* px = (const uint32_t*)SDL_PrimaryARGB->pixels;
		int total = SDL_PrimaryARGB->w * SDL_PrimaryARGB->h;
		int nz = 0;
		for (int i = 0; i < total; ++i)
			if (px[i] & 0x00FFFFFF) ++nz;
		fprintf(stderr, "[RA] frame%d BMP: rc=%d nz_pixels=%d path=%s\n",
			SDL_PresentCount, bmp_rc, nz, bmp_path);
		if (SDL_PresentCount == 500) {
			const uint8_t* idx = (const uint8_t*)SDL_PrimarySurface->pixels;
			int total_idx = SDL_PrimarySurface->w * SDL_PrimarySurface->h;
			int nz_idx = 0;
			for (int i = 0; i < total_idx; ++i)
				if (idx[i]) ++nz_idx;
			fprintf(stderr, "[RA] frame500 indexed: nz_bytes=%d\n", nz_idx);
			SDL_Color* pal = SDL_PrimarySurface->format->palette
			                 ? SDL_PrimarySurface->format->palette->colors : nullptr;
			if (pal)
				fprintf(stderr, "[RA] frame500 palette[0]=%u,%u,%u pal[1]=%u,%u,%u pal[128]=%u,%u,%u\n",
					pal[0].r, pal[0].g, pal[0].b,
					pal[1].r, pal[1].g, pal[1].b,
					pal[128].r, pal[128].g, pal[128].b);
		}
		fflush(stderr);
	}

	if (!SDL_FirstPresentDone) {
#ifndef __EMSCRIPTEN__
		// TIM-377: under Emscripten the canvas is always visible (SDL_WINDOW_SHOWN
		// at create time); SDL_ShowWindow is a no-op there and the SDL_WINDOW_HIDDEN
		// → show-on-first-present flow only applies to the native Linux build.
		SDL_ShowWindow(SDL_VideoWindow);
#endif
		SDL_FirstPresentDone = true;
		/* TIM-226: SDL_WINDOW_HIDDEN means no FOCUS_GAINED fires before the
		 * first show; set GameInFocus here so Main_Loop renders immediately. */
		GameInFocus = true;
		// TIM-172: save first frame as BMP for offline verification (bypasses X11 capture)
		{
			const char* bmp_path = "/tmp/redalert-frame0.bmp";
			int save_rc = SDL_SaveBMP(SDL_PrimaryARGB, bmp_path);
			const uint32_t* px = (const uint32_t*)SDL_PrimaryARGB->pixels;
			uint32_t first_nz = 0; int nz_idx = -1;
			int total = SDL_PrimaryARGB->w * SDL_PrimaryARGB->h;
			for (int pi = 0; pi < total; ++pi) {
				if (px[pi] & 0x00FFFFFF) { first_nz = px[pi]; nz_idx = pi; break; }
			}
			const uint8_t* src = (const uint8_t*)SDL_PrimarySurface->pixels;
			SDL_Color* pal = SDL_PrimarySurface->format->palette
			                 ? SDL_PrimarySurface->format->palette->colors : nullptr;
			fprintf(stderr, "[RA] first SDL frame: blit_rc=%d save_rc=%d bmp=%s nz_idx=%d first_nz=0x%08x idx[0]=%u pal[0]=%u,%u,%u\n",
				blit_rc, save_rc, bmp_path, nz_idx, first_nz, src[0],
				pal ? pal[0].r : 0, pal ? pal[0].g : 0, pal ? pal[0].b : 0);
			fflush(stderr);
		}
		fprintf(stderr, "[RA] first SDL frame presented — window now visible\n");
	}

	// TIM-1053: Frame rate limiter for software renderer fallback.
	// When the hardware-accelerated renderer with PRESENTVSYNC is active,
	// SDL_RenderPresent already blocks for ~16.6ms at 60Hz.  On the
	// software fallback (Xvfb, headless CI, no GPU), RenderPresent returns
	// immediately and the main loop runs at CPU speed, making the game
	// play far too fast.  This limiter uses wall-clock timing to throttle
	// to ~60 FPS regardless of renderer type.
	{
		static Uint64 _wv_prev = 0;
		static bool _wv_initialized = false;
		Uint64 _wv_now = SDL_GetPerformanceCounter();
		Uint64 _wv_freq = SDL_GetPerformanceFrequency();

		if (!_wv_initialized) {
			_wv_prev = _wv_now;
			_wv_initialized = true;
		} else {
			// Compute elapsed ns since last frame.
			Uint64 elapsed_ns = _wv_freq
			                   ? ((_wv_now - _wv_prev) * 1000000000ULL) / _wv_freq
			                   : 0;
			// Target: 16.666 ms per frame (~60 FPS).  If we're running
			// faster than that (e.g. software renderer with no vsync),
			// delay for the remaining time.
			const Uint64 TARGET_NS = 16666667ULL;  // 1/60 second in ns
			if (elapsed_ns < TARGET_NS) {
				Uint64 delay_ms = (TARGET_NS - elapsed_ns + 999999ULL) / 1000000ULL;
				if (delay_ms > 0) {
					SDL_Delay((Uint32)delay_ms);
				}
			}
			// After any delay, update reference for next frame.
			_wv_now = SDL_GetPerformanceCounter();
			_wv_prev = _wv_now;
		}
	}

	return;
#else
	if (DirectDrawObject == NULL) {
		return;
	}
	if( ScreenWidth!=320 && CanVblankSync){
		HRESULT result = DirectDrawObject->WaitForVerticalBlank(DDWAITVB_BLOCKBEGIN, 0);
		if (result == E_NOTIMPL){
			CanVblankSync = FALSE;
			return;
		}
		Process_DD_Result(result, FALSE);
	}
#endif
}





/***********************************************************************************************
 * Set_Palette -- set a direct draw palette                                                    *
 *                                                                                             *
 *                                                                                             *
 *                                                                                             *
 * INPUT:    ptr to 768 rgb palette bytes                                                      *
 *                                                                                             *
 * OUTPUT:   Nothing                                                                           *
 *                                                                                             *
 * WARNINGS: None                                                                              *
 *                                                                                             *
 * HISTORY:                                                                                    *
 *    10/11/95 3:33PM ST : Created                                                             *
 *=============================================================================================*/
void Set_DD_Palette ( void *palette )
{

	/*
	** Trap null ptr
	*/
	if (!palette) return;

#ifndef _MSC_VER
	// TIM-908: skip redundant palette updates. Color_Cycle calls
	// Set_DD_Palette every busy-wait tick during Sync_Delay even when
	// the palette hasn't changed. memcmp against the last-set raw 6-bit
	// bytes and early-return avoids useless SDL_PaletteEntries copies,
	// LUT rebuilds, and SDL_SetPaletteColors calls.
	static uint8_t lastPaletteRaw[768] = {};
	static bool    lastPaletteValid = false;
	if (lastPaletteValid && memcmp(lastPaletteRaw, palette, 768) == 0) {
		return;
	}
	memcpy(lastPaletteRaw, palette, 768);
	lastPaletteValid = true;
#endif

	int	j;
	int	k;
	char	*palette_get;

	// TIM-141: always populate the Westwood 6-bit palette table (was
	// previously gated behind `DirectDrawObject && PaletteSurface`, which
	// meant the table never got filled on Linux). The SDL2 path below
	// reads from PaletteEntries[]; the MSVC DirectDraw path keeps its
	// own SetPalette/SetEntries flow under #ifdef _MSC_VER.
	k=0;
	palette_get = (char*)palette;
	for( j=0 ; j<768 ; j+=3 )
	{
		PaletteEntries[k].peRed = (unsigned char)((*palette_get++)<<2);
		PaletteEntries[k].peGreen = (unsigned char)((*palette_get++)<<2);
		PaletteEntries[k].peBlue = (unsigned char)((*palette_get++)<<2);
		k++;
	}

#ifndef _MSC_VER
	// Mirror into SDL_Color[256] and apply to the indexed primary surface
	// (if Set_Video_Mode has opened one). 8-bit 6→8 expansion already
	// happened above via the `<<2` shift on each channel.
	for (int i = 0; i < 256; ++i) {
		SDL_PaletteEntries[i].r = PaletteEntries[i].peRed;
		SDL_PaletteEntries[i].g = PaletteEntries[i].peGreen;
		SDL_PaletteEntries[i].b = PaletteEntries[i].peBlue;
		SDL_PaletteEntries[i].a = 255;
	}
	Rebuild_Palette_LUT();
	if (SDL_PrimarySurface && SDL_PrimarySurface->format && SDL_PrimarySurface->format->palette) {
		SDL_SetPaletteColors(SDL_PrimarySurface->format->palette,
		                     SDL_PaletteEntries, 0, 256);
	}
#else
	if ( DirectDrawObject && PaletteSurface ){
		if ( !FirstPaletteSet ){
			PaletteSurface->SetPalette( PalettePtr );
			FirstPaletteSet=TRUE;
		}
		PalettePtr->SetEntries( 0 , 0 , 256 , &PaletteEntries[0] );
	}
#endif
}

#ifndef _MSC_VER
// TIM-580: VQA CPL0 palette is 6-bit VGA after all.  TIM-523 misread the
// bimodal byte distribution (538 bytes in 0-31, 230 bytes in 224-255) as
// proof of 8-bit encoding, but ffmpeg's vqavideo.c handles it as 6-bit
// VGA with byte truncation: r = (cpl0[i] * 4) & 0xFF, plus bottom-bit
// replication so 6'b111111 maps to 8'b11111111 instead of 8'b11111100.
//
// Empirically (TIM-580 frame 20/75 vs ffmpeg reference): the 6-bit
// interpretation produces the correct metallic-gray backgrounds and clean
// snow/sky in the targeting reticle.  The TIM-523 "8-bit direct" path made
// background palette entries (CPL0 values 4-31) appear black, leaving only
// the gold-text indices (values 224-255) visible and producing the cyan
// scatter the issue reports.
//
// This variant only writes SDL_PaletteEntries[] — it does NOT touch
// the legacy Westwood `PaletteEntries[]` global, so VQA playback does not
// disturb the game's palette state.
extern "C" void Set_DD_Palette_8bit(const uint8_t* cpl0, int ncolors)
{
	if (!cpl0 || ncolors <= 0) return;
	if (ncolors > 256) ncolors = 256;
	for (int i = 0; i < ncolors; ++i) {
		uint8_t r = (uint8_t)(cpl0[i * 3 + 0] << 2);
		uint8_t g = (uint8_t)(cpl0[i * 3 + 1] << 2);
		uint8_t b = (uint8_t)(cpl0[i * 3 + 2] << 2);
		// Bottom-bit replication: r |= (r >> 6) & 0x3 (matches ffmpeg).
		SDL_PaletteEntries[i].r = (uint8_t)(r | ((r >> 6) & 0x3));
		SDL_PaletteEntries[i].g = (uint8_t)(g | ((g >> 6) & 0x3));
		SDL_PaletteEntries[i].b = (uint8_t)(b | ((b >> 6) & 0x3));
		SDL_PaletteEntries[i].a = 255;
	}
	Rebuild_Palette_LUT();
	if (SDL_PrimarySurface && SDL_PrimarySurface->format &&
	    SDL_PrimarySurface->format->palette)
		SDL_SetPaletteColors(SDL_PrimarySurface->format->palette,
		                     SDL_PaletteEntries, 0, ncolors);
}
#endif // !_MSC_VER



/***********************************************************************************************
 * Wait_Blit -- waits for the DirectDraw blitter to become idle                                *
 *                                                                                             *
 *                                                                                             *
 *                                                                                             *
 * INPUT:    Nothing                                                                           *
 *                                                                                             *
 * OUTPUT:   Nothing                                                                           *
 *                                                                                             *
 * WARNINGS: None                                                                              *
 *                                                                                             *
 * HISTORY:                                                                                    *
 *   07-25-95 03:53pm ST : Created                                                             *
 *=============================================================================================*/

void Wait_Blit (void)
{
#ifdef _MSC_VER
	// TIM-141 commit 3: hardware blit-completion poll retained on MSVC.
	// On Linux this is a no-op — vsync rides the SDL_RENDERER_PRESENTVSYNC
	// renderer (created in Set_Video_Mode) and IDirectDrawSurface is
	// incomplete in the Linux build.
	HRESULT	return_code;

	do {
		return_code=PaletteSurface->GetBltStatus (DDGBS_ISBLTDONE);
	} while (return_code != DD_OK && return_code != DDERR_SURFACELOST);
#endif
}



/***********************************************************************************************
 * SMC::SurfaceMonitorClass -- constructor for surface monitor class                           *
 *                                                                                             *
 *                                                                                             *
 *                                                                                             *
 * INPUT:    Nothing                                                                           *
 *                                                                                             *
 * OUTPUT:   Nothing                                                                           *
 *                                                                                             *
 * WARNINGS: None                                                                              *
 *                                                                                             *
 * HISTORY:                                                                                    *
 *    11/3/95 3:23PM ST : Created                                                              *
 *=============================================================================================*/

SurfaceMonitorClass::SurfaceMonitorClass(void)
{
	for (int i=0 ; i<MAX_SURFACES ; i++)
	{
		Surface[i]=NULL;
	}
	InFocus=FALSE;
	SurfacesRestored=FALSE;
}


/***********************************************************************************************
 * SMC::Add_DD_Surface -- add a new surface to the list                                        *
 *                                                                                             *
 *                                                                                             *
 *                                                                                             *
 * INPUT:    ptr to surface                                                                    *
 *                                                                                             *
 * OUTPUT:   Nothing                                                                           *
 *                                                                                             *
 * WARNINGS: None                                                                              *
 *                                                                                             *
 * HISTORY:                                                                                    *
 *                 11/3/95 3:24PM ST : Created                                                 *
 *=============================================================================================*/
void SurfaceMonitorClass::Add_DD_Surface (LPDIRECTDRAWSURFACE new_surface)
{
	if ( !Got_Surface_Already (new_surface) ){
		for (int i=0 ; i<MAX_SURFACES ; i++)
		{
			if ( Surface[i]==NULL ){
				Surface[i]=new_surface;
				return;
			}
		}
	}
}


/***********************************************************************************************
 * SMC::Remove_DD_Surface -- remove a direct draw surface from the list                        *
 *                                                                                             *
 *                                                                                             *
 *                                                                                             *
 * INPUT:    ptr to Surface                                                                    *
 *                                                                                             *
 * OUTPUT:   Nothing                                                                           *
 *                                                                                             *
 * WARNINGS: None                                                                              *
 *                                                                                             *
 * HISTORY:                                                                                    *
 *    11/3/95 3:25PM ST : Created                                                              *
 *=============================================================================================*/

void SurfaceMonitorClass::Remove_DD_Surface (LPDIRECTDRAWSURFACE old_surface)
{
	for (int i=0 ; i<MAX_SURFACES ; i++)
	{
		if ( Surface[i]==old_surface ){
			Surface[i]=NULL;
			return;
		}
	}
}


/***********************************************************************************************
 * SMC::Got_Surface_Already -- check if a surface is already in the list                       *
 *                                                                                             *
 *                                                                                             *
 *                                                                                             *
 * INPUT:    ptr to surface                                                                    *
 *                                                                                             *
 * OUTPUT:   True if surface is in list                                                        *
 *                                                                                             *
 * WARNINGS: None                                                                              *
 *                                                                                             *
 * HISTORY:                                                                                    *
 *    11/3/95 3:25PM ST : Created                                                              *
 *=============================================================================================*/

BOOL SurfaceMonitorClass::Got_Surface_Already (LPDIRECTDRAWSURFACE test_surface)
{
	for (int i=0 ; i<MAX_SURFACES ; i++)
	{
		if ( Surface[i]==test_surface ){
			return(TRUE);
		}
	}
	return (FALSE);
}

/***********************************************************************************************
 * SMC::Restore_Surfaces -- restore the direct draw surfaces in the list                       *
 *                                                                                             *
 *                                                                                             *
 *                                                                                             *
 * INPUT:    Nothing                                                                           *
 *                                                                                             *
 * OUTPUT:   Nothing                                                                           *
 *                                                                                             *
 * WARNINGS: None                                                                              *
 *                                                                                             *
 * HISTORY:                                                                                    *
 *    11/3/95 3:26PM ST : Created                                                              *
 *=============================================================================================*/

void SurfaceMonitorClass::Restore_Surfaces (void)
{
	if (InFocus){
		/*
		** Call restore for each Direct Draw surface
		*/
		for (int i=0 ; i<MAX_SURFACES ; i++)
		{
			if ( Surface[i] ){
#ifdef _MSC_VER
				// TIM-141 commit 3: IDirectDrawSurface::Restore is
				// MSVC-only; SDL2 doesn't lose surfaces on focus
				// loss the way DDRAW does, so the Linux path treats
				// every entry as already-restored and falls through
				// to the Misc_Focus_Restore_Function notification.
				if (Surface[i]->Restore() != DD_OK){
					if (Misc_Focus_Loss_Function){
						Misc_Focus_Loss_Function();
					}
					return;
				}
#endif
			}
		}

		/*
		** PWG/ST: Now that we know all the surfaces are restored call
		** the function pointer to notify the program that it has
		** happened.  This function pointer is used to clear the pages,
		** etc.
		*/
		if (Misc_Focus_Restore_Function){
			Misc_Focus_Restore_Function();
		}

		SurfacesRestored = TRUE;

		/*
		** Restore the palette
		*/
		Set_DD_Palette (CurrentPalette);
	}
}


/***********************************************************************************************
 * SMC::Set_Surface_Focus -- set the InFocus flag to the given state                           *
 *                                                                                             *
 *  The InFocus flag is used to keep track of whether our application is currently in focus.   *
 *  We dont want to be restoring video surfaces when we are supposed to be running in the      *
 *  background.                                                                                *
 *                                                                                             *
 * INPUT:    bool in focus                                                                     *
 *                                                                                             *
 * OUTPUT:   Nothing                                                                           *
 *                                                                                             *
 * WARNINGS: None                                                                              *
 *                                                                                             *
 * HISTORY:                                                                                    *
 *    11/6/95 12:21PM ST : Created                                                             *
 *=============================================================================================*/

void SurfaceMonitorClass::Set_Surface_Focus ( BOOL in_focus )
{
	InFocus=in_focus;
}




/***********************************************************************************************
 * SMC::Release -- releases all direct draw surfaces                                           *
 *                                                                                             *
 *  Call this at the end of the game before called RestoreDisplayMode                          *
 *                                                                                             *
 * INPUT:    Nothing                                                                           *
 *                                                                                             *
 * OUTPUT:   Nothing                                                                           *
 *                                                                                             *
 * WARNINGS: None                                                                              *
 *                                                                                             *
 * HISTORY:                                                                                    *
 *    6/6/96 12:23PM ST : Created                                                              *
 *=============================================================================================*/

void SurfaceMonitorClass::Release(void)
{
	/*
	** Call release for each Direct Draw surface
	*/
	for (int i=0 ; i<MAX_SURFACES ; i++)
	{
		if ( Surface[i] ){
#ifdef _MSC_VER
			// TIM-141 commit 3: IDirectDrawSurface::Release is MSVC-only
			// (forward decl on Linux). On Linux nothing ever populates
			// Surface[] because GBUFFER.CPP DD_Init's CreateSurface is
			// MSVC-gated, so the loop body is unreachable at runtime.
			Surface[i]->Release();
#endif
			Surface[i] = 0;
		}
	}

}
