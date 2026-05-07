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

/* $Header:   F:\projects\c&c\vcs\code\monoc.h_v   2.16   06 Sep 1995 16:29:02   JOE_BOSTIC  $ */
/***********************************************************************************************
 ***              C O N F I D E N T I A L  ---  W E S T W O O D  S T U D I O S               *** 
 ***********************************************************************************************
 *                                                                                             *
 *                 Project Name : Command & Conquer                                            *
 *                                                                                             *
 *                    File Name : MONO.H                                                       *
 *                                                                                             *
 *                   Programmer : Joe L. Bostic                                                *
 *                                                                                             *
 *                   Start Date : July 2, 1994                                                 *
 *                                                                                             *
 *                  Last Update : July 2, 1994   [JLB]                                         *
 *                                                                                             *
 *---------------------------------------------------------------------------------------------*
 * Functions:                                                                                  *
 * - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - */

#ifndef MONOC_H
#define MONOC_H

// TIM-20: WIN32LIB/MONO.H historically defined `class MonoClass` -- a
// DOS-era stub left over from the original Westwood library. The same
// class name is also defined (with a richer feature set) by
// REDALERT/MONOC.H, which is the version game code actually uses
// (Fill_Attrib, Sub_Window, MonoAttribute enum, MAX_MONO_PAGES=16,
// COLUMNS/LINES enums, etc.). When a TU pulls in `<wwlib32.h>` (which
// includes this header) before `"monoc.h"`, both definitions land and
// g++ rejects the second with `redefinition of class MonoClass`.
//
// No code inside WIN32LIB itself names the class -- this header was the
// only consumer (verified via repo-wide grep). Stripping the local
// class definition and forward-declaring it instead (so the canonical
// definition comes from REDALERT/MONOC.H) eliminates the redefinition
// without disturbing gameplay code that depends on the richer API.
//
// The TIM-20 ticket text suggested the inverse change (have MONOC.H
// `#include <mono.h>` and stop redefining locally), but that direction
// would silently break Fill_Attrib / Sub_Window / Pan / MonoAttribute
// usage in BUILDING.CPP / FOOT.CPP / HOUSE.CPP / etc. (gated by
// CHEAT_KEYS) and also leave MONOC.CPP's out-of-line method definitions
// orphaned. Same goal -- fix the redefinition -- via the path that
// preserves the existing call sites.
//
// The free Mono_* C functions are kept here; they're the only thing
// downstream of `<wwlib32.h>` actually relied on, and they don't clash
// with any REDALERT declaration.

class MonoClass;		// Canonical definition lives in REDALERT/MONOC.H.

void Mono_Set_Cursor(int x, int y);
int Mono_Printf(char const *string, ...);
void Mono_Clear_Screen(void);
void Mono_Text_Print(void const *text, int x, int y, int attrib);
void Mono_Draw_Rect(int x, int y, int w, int h, int attrib, int thick);
void Mono_Print(void const *text);
int Mono_X(void);
int Mono_Y(void);

#endif

