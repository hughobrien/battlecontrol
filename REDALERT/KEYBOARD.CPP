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

/* $Header:   F:\projects\c&c0\vcs\code\conquer.cpv   4.74   23 Sep 1996 12:36:00   JOE_BOSTIC  $ */
/***********************************************************************************************
 *                                                                                             *
 *                 Project Name : Westwood Keyboard Library                                    *
 *                                                                                             *
 *                    File Name : KEYBOARD.CPP                                                 *
 *                                                                                             *
 *                   Programmer : Philip W. Gorrow                                             *
 *                                                                                             *
 *                   Start Date : 10/16/95                                                     *
 *                                                                                             *
 *                  Last Update : September 24, 1996 [JLB]                                     *
 *                                                                                             *
 *---------------------------------------------------------------------------------------------*
 * Functions:                                                                                  *
 *   WWKeyboardClass::Put -- Logic to insert a key into the keybuffer]                         *
 *   WWKeyboardClass::Get -- Logic to get a metakey from the buffer                            *
 *   WWKeyboardClass::Check -- Checks to see if a key is in the buffer                         *
 *   WWKeyboardClass::Put_Key_Message -- Translates and inserts wParam into Keyboard Buffer    *
 *   WWKeyboardClass::Buff_Get -- Lowlevel function to get a key from key buffer               *
 *   WWKeyboardClass::Get_Mouse_X -- Returns the mouses current x position in pixels           *
 *   WWKeyboardClass::Get_Mouse_Y -- returns the mouses current y position in pixels           *
 *   WWKeyboardClass::Get_Mouse_XY -- Returns the mouses x,y position via reference vars       *
 *   Check_Key -- compatability routine for old 32 bit library                                 *
 * - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - */

#include "keyboard.h"

#include	"monoc.h"

// TIM-145 pass-43A: SDL keyboard pump lives in this TU because
// _Kbd and the VK_ codes are already in scope here. The companion
// header forward-declares the extern "C" entry point for DDRAW.CPP.
#ifndef _MSC_VER
#include <SDL2/SDL.h>
#include "sdl_input.h"

// TIM-145 pass-43C: storage for the cursor cells GetCursorPos reads
// from. Declared extern "C" in linux/win32-stubs/windows.h so every
// TU that includes windows.h sees the same cells. Updated by the
// SDL_MOUSEMOTION drain below.
extern "C" {
int SDL_Cursor_X = 0;
int SDL_Cursor_Y = 0;
}
#endif

//void Message_Loop(void);

WWKeyboardClass * _Kbd = NULL;


#define	ARRAY_SIZE(x)		int(sizeof(x)/sizeof(x[0]))


#ifndef _MSC_VER
// TIM-145 pass-43A: map an SDL_Keycode to the Westwood/Win32 VK_
// code the engine already uses everywhere (see KEYBOARD.H VK_*).
// Returns 0 for keysyms with no engine equivalent — the caller
// drops those events. Coverage is the subset the original game
// actually consumes: letters, digits, function keys, arrow keys,
// modifiers, and editing keys. Numpad and OEM punctuation map to
// the same VK_ values the upstream Win32 build receives via
// WM_KEYDOWN, so downstream KN_/KA_ translation is unchanged.
static unsigned short SDL_Keysym_To_VK(SDL_Keycode k)
{
	if (k >= SDLK_a && k <= SDLK_z) return (unsigned short)(VK_A + (k - SDLK_a));
	if (k >= SDLK_0 && k <= SDLK_9) return (unsigned short)(VK_0 + (k - SDLK_0));
	if (k >= SDLK_F1 && k <= SDLK_F12) return (unsigned short)(VK_F1 + (k - SDLK_F1));

	switch (k) {
	case SDLK_ESCAPE:       return VK_ESCAPE;
	case SDLK_RETURN:       return VK_RETURN;
	case SDLK_KP_ENTER:     return VK_RETURN;
	case SDLK_BACKSPACE:    return VK_BACK;
	case SDLK_TAB:          return VK_TAB;
	case SDLK_SPACE:        return VK_SPACE;
	case SDLK_LEFT:         return VK_LEFT;
	case SDLK_RIGHT:        return VK_RIGHT;
	case SDLK_UP:           return VK_UP;
	case SDLK_DOWN:         return VK_DOWN;
	case SDLK_HOME:         return VK_HOME;
	case SDLK_END:          return VK_END;
	case SDLK_PAGEUP:       return VK_PRIOR;
	case SDLK_PAGEDOWN:     return VK_NEXT;
	case SDLK_INSERT:       return VK_INSERT;
	case SDLK_DELETE:       return VK_DELETE;
	case SDLK_LSHIFT:
	case SDLK_RSHIFT:       return VK_SHIFT;
	case SDLK_LCTRL:
	case SDLK_RCTRL:        return VK_CONTROL;
	case SDLK_LALT:
	case SDLK_RALT:         return VK_MENU;
	case SDLK_PAUSE:        return VK_PAUSE;
	case SDLK_CAPSLOCK:     return VK_CAPITAL;
	case SDLK_NUMLOCKCLEAR: return VK_NUMLOCK;
	case SDLK_SCROLLLOCK:   return VK_SCROLL;
	case SDLK_PRINTSCREEN:  return VK_PRINT;
	case SDLK_KP_0:         return VK_NUMPAD0;
	case SDLK_KP_1:         return VK_NUMPAD1;
	case SDLK_KP_2:         return VK_NUMPAD2;
	case SDLK_KP_3:         return VK_NUMPAD3;
	case SDLK_KP_4:         return VK_NUMPAD4;
	case SDLK_KP_5:         return VK_NUMPAD5;
	case SDLK_KP_6:         return VK_NUMPAD6;
	case SDLK_KP_7:         return VK_NUMPAD7;
	case SDLK_KP_8:         return VK_NUMPAD8;
	case SDLK_KP_9:         return VK_NUMPAD9;
	case SDLK_KP_PLUS:      return VK_ADD;
	case SDLK_KP_MINUS:     return VK_SUBTRACT;
	case SDLK_KP_MULTIPLY:  return VK_MULTIPLY;
	case SDLK_KP_DIVIDE:    return VK_DIVIDE;
	case SDLK_KP_PERIOD:    return VK_DECIMAL;
	default:                return 0;
	}
}

// TIM-145 pass-43A: drain SDL_KEYDOWN/SDL_KEYUP from the SDL event
// queue and inject the packed VK + modifier + release-bit value
// into the existing WWKeyboardClass ring. Uses SDL_PeepEvents with
// a tight type filter to leave joystick and window events queued
// for their own pumps. The mouse-button + motion drain runs in the
// same call after the keyboard drain (pass-43B). Drained in
// batches of 16 to keep stack pressure bounded.
extern "C" void SDL_Process_Input_Events(void)
{
	if (_Kbd == NULL) return;

	SDL_PumpEvents();

	SDL_Event events[16];
	int drained;
	do {
		drained = SDL_PeepEvents(events, 16, SDL_GETEVENT,
		                         SDL_KEYDOWN, SDL_KEYUP);
		for (int i = 0; i < drained; ++i) {
			const SDL_KeyboardEvent &ke = events[i].key;
			unsigned short vk = SDL_Keysym_To_VK(ke.keysym.sym);
			if (vk == 0) continue;

			Uint16 mod = ke.keysym.mod;
			if (mod & KMOD_SHIFT) vk |= WWKEY_SHIFT_BIT;
			if (mod & KMOD_CTRL)  vk |= WWKEY_CTRL_BIT;
			if (mod & KMOD_ALT)   vk |= WWKEY_ALT_BIT;
			if (events[i].type == SDL_KEYUP) vk |= WWKEY_RLS_BIT;

			_Kbd->Put(vk);
		}
	} while (drained == 16);

	// TIM-145 pass-43B: drain SDL_MOUSEMOTION / SDL_MOUSEBUTTONDOWN
	// / SDL_MOUSEBUTTONUP. Buttons translate to VK_LBUTTON /
	// VK_MBUTTON / VK_RBUTTON and follow the Win32 protocol used by
	// WWKeyboardClass::Message_Handler (KEYBOARD.CPP:398-465 in the
	// MSVC build): Put(vk) followed by Put(x), Put(y). The matching
	// drain on the read side is Buff_Get at line 95-99. Modifier
	// bits are intentionally NOT applied to mouse keys per
	// Put_Key_Message (line 193: "we do not want to set the shift,
	// ctrl and alt bits for Mouse keypresses as this would be
	// incompatible with the dos version"). Motion events are
	// drained but not yet wired to WWMouseClass — pass-43C.
	do {
		drained = SDL_PeepEvents(events, 16, SDL_GETEVENT,
		                         SDL_MOUSEMOTION, SDL_MOUSEBUTTONUP);
		for (int i = 0; i < drained; ++i) {
			Uint32 type = events[i].type;
			if (type == SDL_MOUSEBUTTONDOWN || type == SDL_MOUSEBUTTONUP) {
				const SDL_MouseButtonEvent &be = events[i].button;
				unsigned short vk = 0;
				switch (be.button) {
				case SDL_BUTTON_LEFT:   vk = VK_LBUTTON; break;
				case SDL_BUTTON_MIDDLE: vk = VK_MBUTTON; break;
				case SDL_BUTTON_RIGHT:  vk = VK_RBUTTON; break;
				default: continue;
				}
				if (type == SDL_MOUSEBUTTONUP) vk |= WWKEY_RLS_BIT;

				_Kbd->Put(vk);
				_Kbd->Put((unsigned short)be.x);
				_Kbd->Put((unsigned short)be.y);
			}
			else if (type == SDL_MOUSEMOTION) {
				// TIM-145 pass-43C: capture cursor position so the
				// stubbed GetCursorPos in linux/win32-stubs/windows.h
				// returns the real SDL cursor instead of (0,0). All
				// six WWMouseClass query sites (Get_Mouse_X, Get_Mouse_Y,
				// Get_Mouse_XY, Show_Mouse, Conditional_Hide_Mouse,
				// Draw_Mouse) read through GetCursorPos.
				SDL_Cursor_X = events[i].motion.x;
				SDL_Cursor_Y = events[i].motion.y;
			}
		}
	} while (drained == 16);
}
#endif


/***********************************************************************************************
 * WWKeyboardClass::WWKeyBoardClass -- Construction for Westwood Keyboard Class                *
 *                                                                                             *
 * INPUT:		none							                                                        *
 *                                                                                             *
 * OUTPUT:     none							                                                        *
 *                                                                                             *
 * HISTORY:                                                                                    *
 *   10/16/1995 PWG : Created.                                                                 *
 *=============================================================================================*/
WWKeyboardClass::WWKeyboardClass(void) :
	MouseQX(0),
	MouseQY(0),
	Head(0),
	Tail(0)
//	MState(0),
//	Conditional(0),
//	CurrentCursor(0)
{
	_Kbd = this;

	memset(KeyState, '\0', sizeof(KeyState));
}


/***********************************************************************************************
 * WWKeyboardClass::Buff_Get -- Lowlevel function to get a key from key buffer                 *
 *                                                                                             *
 * INPUT:		none                                                        						  *
 *                                                                                             *
 * OUTPUT:     int		- the key value that was pulled from buffer (includes bits)				  *                                                                                *
 *                                                                                             *
 * WARNINGS:   If the key was a mouse event MouseQX and MouseQY will be updated                *
 *                                                                                             *
 * HISTORY:                                                                                    *
 *   10/17/1995 PWG : Created.                                                                 *
 *=============================================================================================*/
unsigned short WWKeyboardClass::Buff_Get(void)
{
	while (!Check()) {}										// wait for key in buffer

	unsigned short temp = Fetch_Element();
	if (Is_Mouse_Key(temp)) {
		MouseQX = Fetch_Element();
		MouseQY = Fetch_Element();
	}
	return(temp);
}


bool WWKeyboardClass::Is_Mouse_Key(unsigned short key)
{
	key &= 0xFF;
	return (key == VK_LBUTTON || key == VK_MBUTTON || key == VK_RBUTTON);
}


/***********************************************************************************************
 * WWKeyboardClass::Check -- Checks to see if a key is in the buffer                           *
 *                                                                                             *
 * INPUT:                                                                                      *
 *                                                                                             *
 * OUTPUT:                                                                                     *
 *                                                                                             *
 * WARNINGS:                                                                                   *
 *                                                                                             *
 * HISTORY:                                                                                    *
 *   10/16/1995 PWG : Created.                                                                 *
 *   09/24/1996 JLB : Converted to new style keyboard system.                                  *
 *=============================================================================================*/
unsigned short WWKeyboardClass::Check(void) const
{
	((WWKeyboardClass *)this)->Fill_Buffer_From_System();
	if (Is_Buffer_Empty()) return(false);
	return(Peek_Element());
}


/***********************************************************************************************
 * WWKeyboardClass::Get -- Logic to get a metakey from the buffer                              *
 *                                                                                             *
 * INPUT:		none                                                        						  *
 *                                                                                             *
 * OUTPUT:     int		- the meta key taken from the buffer.											  *
 *                                                                                             *
 * WARNINGS:	This routine will not return until a keypress is received							  *
 *                                                                                             *
 * HISTORY:                                                                                    *
 *   10/16/1995 PWG : Created.                                                                 *
 *=============================================================================================*/
unsigned short WWKeyboardClass::Get(void)
{
	while (!Check()) {}								// wait for key in buffer
	return (Buff_Get());
}


/***********************************************************************************************
 * WWKeyboardClass::Put -- Logic to insert a key into the keybuffer]                           *
 *                                                                                             *
 * INPUT:		int	 	- the key to insert into the buffer          								  *
 *                                                                                             *
 * OUTPUT:     bool		- true if key is sucessfuly inserted.							              *
 *                                                                                             *
 * WARNINGS:   none							                                                        *
 *                                                                                             *
 * HISTORY:                                                                                    *
 *   10/16/1995 PWG : Created.                                                                 *
 *=============================================================================================*/
bool WWKeyboardClass::Put(unsigned short key)
{
	if (!Is_Buffer_Full()) {
		Put_Element(key);
		return(true);
	}
	return(false);
}


/***********************************************************************************************
 * WWKeyboardClass::Put_Key_Message -- Translates and inserts wParam into Keyboard Buffer      *
 *                                                                                             *
 * INPUT:                                                                                      *
 *                                                                                             *
 * OUTPUT:                                                                                     *
 *                                                                                             *
 * WARNINGS:                                                                                   *
 *                                                                                             *
 * HISTORY:                                                                                    *
 *   10/16/1995 PWG : Created.                                                                 *
 *=============================================================================================*/
bool WWKeyboardClass::Put_Key_Message(unsigned short vk_key, bool release)
{
	//
	// Get the status of all of the different keyboard modifiers.  Note, only pay attention
	// to numlock and caps lock if we are dealing with a key that is affected by them.  Note
	// that we do not want to set the shift, ctrl and alt bits for Mouse keypresses as this
	// would be incompatible with the dos version.
	//
	if (!Is_Mouse_Key(vk_key)) {
		if (((GetKeyState(VK_SHIFT) & 0x8000) != 0) ||
			((GetKeyState(VK_CAPITAL) & 0x0008) != 0) ||
			((GetKeyState(VK_NUMLOCK) & 0x0008) != 0)) {

			vk_key |= WWKEY_SHIFT_BIT;
		}
		if ((GetKeyState(VK_CONTROL) & 0x8000) != 0) {
			vk_key |= WWKEY_CTRL_BIT;
		}
		if ((GetKeyState(VK_MENU) & 0x8000) != 0) {
			vk_key |= WWKEY_ALT_BIT;
		}
	}

	if (release) {
		vk_key |= WWKEY_RLS_BIT;
	}

	//
	// Finally use the put command to enter the key into the keyboard
	// system.
	//
	return(Put(vk_key));



}

#pragma warning (disable : 4065)
char WWKeyboardClass::To_ASCII(unsigned short key)
{
	/*
	**	Released keys never translate into an ASCII value.
	*/
	if (key & WWKEY_RLS_BIT) {
		return('\0');
	}

	/*
	**	Set the KeyState buffer to reflect the shift bits stored in the key value.
	*/
	if (key & WWKEY_SHIFT_BIT) {
		KeyState[VK_SHIFT] = 0x80;
	}
	if (key & WWKEY_CTRL_BIT) {
		KeyState[VK_CONTROL] = 0x80;
	}
	if (key & WWKEY_ALT_BIT) {
		KeyState[VK_MENU] = 0x80;
	}

	/*
	**	Ask windows to translate the key into an ASCII equivalent.
	*/
	char buffer[10];
	int result = 1;
	int scancode = 0;
	char override = '\0';

	switch (key & 0xFF) {
//		case KN_RETURN:
//			override = KA_RETURN;
//			break;

//		case KN_BACKSPACE:
//			override = KA_BACKSPACE;
//			break;

		default:
			scancode = MapVirtualKey(key & 0xFF, 0);
			result = ToAscii((UINT)(key & 0xFF), (UINT)scancode, (PBYTE)KeyState, (LPWORD)buffer, (UINT)0);
			break;
	}

	/*
	**	Restore the KeyState buffer back to pristine condition.
	*/
	if (key & WWKEY_SHIFT_BIT) {
		KeyState[VK_SHIFT] = 0;
	}
	if (key & WWKEY_CTRL_BIT) {
		KeyState[VK_CONTROL] = 0;
	}
	if (key & WWKEY_ALT_BIT) {
		KeyState[VK_MENU] = 0;
	}

	/*
	**	If Windows could not perform the translation as expected, then
	**	return with a null ASCII value.
	*/
	if (result != 1) {
		return('\0');
	}

	if (override != 0) {
		return(override);
	}

	return(buffer[0]);
}


bool WWKeyboardClass::Down(unsigned short key)
{
	return(GetAsyncKeyState(key & 0xFF) == 0 ? false : true);
}


extern "C" {
	void __cdecl Stop_Execution (void);
}



unsigned short WWKeyboardClass::Fetch_Element(void)
{
	unsigned short val = 0;
	if (Head != Tail) {
		val = Buffer[Head];

		Head = (Head + 1) % ARRAY_SIZE(Buffer);
	}
	return(val);
}


unsigned short WWKeyboardClass::Peek_Element(void) const
{
	if (!Is_Buffer_Empty()) {
		return(Buffer[Head]);
	}
	return(0);
}


bool WWKeyboardClass::Put_Element(unsigned short val)
{
	if (!Is_Buffer_Full()) {
		int temp = (Tail+1) % ARRAY_SIZE(Buffer);
		Buffer[Tail] = val;
		Tail = temp;
		return(true);
	}
	return(false);
}


bool WWKeyboardClass::Is_Buffer_Full(void) const
{
	if ((Tail + 1) % ARRAY_SIZE(Buffer) == Head) {
		return(true);
	}
	return(false);
}


bool WWKeyboardClass::Is_Buffer_Empty(void) const
{
	if (Head == Tail) {
		return(true);
	}
	return(false);
}


void WWKeyboardClass::Fill_Buffer_From_System(void)
{
	if (!Is_Buffer_Full()) {
		MSG	msg;
		while (PeekMessage(&msg, NULL, 0, 0, PM_NOREMOVE)) {
		  	if (!GetMessage( &msg, NULL, 0, 0 )) {
				return;
			}
			TranslateMessage(&msg);
			DispatchMessage(&msg);
		}
	}
}


void WWKeyboardClass::Clear(void)
{
	Head = Tail;
}


void WWKeyboardClass::Message_Handler(HWND , UINT message, UINT wParam, LONG lParam)
{
	switch (message) {
		case WM_SYSKEYDOWN:
		case WM_KEYDOWN:
			if ( wParam==VK_SCROLL ){
				Stop_Execution();
			} else {
				Put_Key_Message((unsigned short)wParam);
			}
			break;

		case WM_SYSKEYUP:
		case WM_KEYUP:
			Put_Key_Message((unsigned short)wParam, true);
			break;

		case WM_LBUTTONDOWN:
			Put_Key_Message(VK_LBUTTON);
			Put(LOWORD(lParam));
			Put(HIWORD(lParam));
			break;

		case WM_LBUTTONUP:
			Put_Key_Message(VK_LBUTTON, true);
			Put(LOWORD(lParam));
			Put(HIWORD(lParam));
			break;

		case WM_LBUTTONDBLCLK:
			Put_Key_Message(VK_LBUTTON, true);
			Put(LOWORD(lParam));
			Put(HIWORD(lParam));
			Put_Key_Message(VK_LBUTTON, true);
			Put(LOWORD(lParam));
			Put(HIWORD(lParam));
			break;

		case WM_MBUTTONDOWN:
			Put_Key_Message(VK_MBUTTON);
			Put(LOWORD(lParam));
			Put(HIWORD(lParam));
			break;

		case WM_MBUTTONUP:
			Put_Key_Message(VK_MBUTTON, true);
			Put(LOWORD(lParam));
			Put(HIWORD(lParam));
			break;

		case WM_MBUTTONDBLCLK:
			Put_Key_Message(VK_MBUTTON, true);
			Put(LOWORD(lParam));
			Put(HIWORD(lParam));
			Put_Key_Message(VK_MBUTTON, true);
			Put(LOWORD(lParam));
			Put(HIWORD(lParam));
			break;

		case WM_RBUTTONDOWN:
			Put_Key_Message(VK_RBUTTON);
			Put(LOWORD(lParam));
			Put(HIWORD(lParam));
			break;

		case WM_RBUTTONUP:
			Put_Key_Message(VK_RBUTTON, true);
			Put(LOWORD(lParam));
			Put(HIWORD(lParam));
			break;

		case WM_RBUTTONDBLCLK:
			Put_Key_Message(VK_RBUTTON, true);
			Put(LOWORD(lParam));
			Put(HIWORD(lParam));
			Put_Key_Message(VK_RBUTTON, true);
			Put(LOWORD(lParam));
			Put(HIWORD(lParam));
			break;

//		case WM_MOUSEMOVE:
//			if (CurrentCursor)
//				SetCursor(CurrentCursor);
//			break;
	}
}
