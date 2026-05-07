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


/*
** 
**   Misc. assembly code moved from headers
** 
** 
** 
** 
** 
*/

#include "FUNCTION.H"



extern "C" void __cdecl Mem_Copy(void const *source, void *dest, unsigned long bytes_to_copy)
{
	memcpy(dest, source, bytes_to_copy);
}			  


/***********************************************************************************************
 * Distance -- Determines the lepton distance between two coordinates.                         *
 *                                                                                             *
 *    This routine is used to determine the distance between two coordinates. It uses the      *
 *    Dragon Strike method of distance determination and thus it is very fast.                 *
 *                                                                                             *
 * INPUT:   coord1   -- First coordinate.                                                      *
 *                                                                                             *
 *          coord2   -- Second coordinate.                                                     *
 *                                                                                             *
 * OUTPUT:  Returns the lepton distance between the two coordinates.                           *
 *                                                                                             *
 * WARNINGS:   none                                                                            *
 *                                                                                             *
 * HISTORY:                                                                                    *
 *   05/27/1994 JLB : Created.                                                                 *
 *=============================================================================================*/
int Distance_Coord(COORDINATE coord1, COORDINATE coord2)
{
	{ /* __asm body removed for syntax-only build (TIM-124) */ }
}			  




/*
;***************************************************************************
;* DESIRED_FACING16 -- Converts coordinates into a facing number.          *
;*                                                                         *
;*      This converts coordinates into a desired facing number that ranges *
;*      from 0 to 15 (0 equals North and going clockwise).                 *
;*                                                                         *
;* INPUT:       x1,y1   -- Position of origin point.                       *
;*                                                                         *
;*              x2,y2   -- Position of target.                             *
;*                                                                         *
;* OUTPUT:      Returns desired facing as a number from 0 to 255 but       *
;*              accurate to 22.5 degree increments.                        *
;*                                                                         *
;* WARNINGS:    If the two coordinates are the same, then -1 will be       *
;*              returned.  It is up to you to handle this case.            *
;*                                                                         *
;* HISTORY:                                                                *
;*   08/14/1991 JLB : Created.                                             *
;*=========================================================================*
*/

long __cdecl Desired_Facing16(long x1, long y1, long x2, long y2)
{
	static const char _new_facing16[] = {
		3, 2, 4,-1, 1, 2,0,-1,
		13,14,12,-1,15,14,0,-1,
		5, 6, 4,-1, 7, 6,8,-1,
		11,10,12,-1, 9,10,8,-1
	};

	
	{ /* __asm body removed for syntax-only build (TIM-124) */ }
}















/*
;***************************************************************************
;* Desired_Facing256 -- Desired facing algorithm 0..255 resolution.        *
;*                                                                         *
;*    This is a desired facing algorithm that has a resolution of 0        *
;*    through 255.                                                         *
;*                                                                         *
;* INPUT:   srcx,srcy   -- Source coordinate.                              *
;*                                                                         *
;*          dstx,dsty   -- Destination coordinate.                         *
;*                                                                         *
;* OUTPUT:  Returns with the desired facing to face the destination        *
;*          coordinate from the position of the source coordinate.  North  *
;*          is 0, East is 64, etc.                                         *
;*                                                                         *
;* WARNINGS:   This routine is slower than the other forms of desired      *
;*             facing calculation.  Use this routine when accuracy is      *
;*             required.                                                   *
;*                                                                         *
;* HISTORY:                                                                *
;*   12/24/1991 JLB : Adapted.                                             *
;*=========================================================================*/

int __cdecl Desired_Facing256(LONG srcx, LONG srcy, LONG dstx, LONG dsty)
{
	
	{ /* __asm body removed for syntax-only build (TIM-124) */ }
}		 












/*

;***************************************************************************
;**   C O N F I D E N T I A L --- W E S T W O O D   A S S O C I A T E S   **
;***************************************************************************
;*                                                                         *
;*                 Project Name : Support Library                          *
;*                                                                         *
;*                    File Name : FACING8.ASM                              *
;*                                                                         *
;*                   Programmer : Joe L. Bostic                            *
;*                                                                         *
;*                   Start Date : May 8, 1991                              *
;*                                                                         *
;*                  Last Update : February 6, 1995  [BWG]                  *
;*                                                                         *
;*-------------------------------------------------------------------------*
;* Functions:                                                              *
;*   Desired_Facing8 -- Determines facing to reach a position.             *
;* - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - *


IDEAL
P386
MODEL USE32 FLAT

GLOBAL	 C Desired_Facing8	:NEAR
;	INCLUDE	"wwlib.i"

	DATASEG

; 8 direction desired facing lookup table.  Build the index according
; to the following bits:
;
; bit 3 = Is y2 < y1?
; bit 2 = Is x2 < x1?
; bit 1 = Is the ABS(x2-x1) < ABS(y2-y1)?
; bit 0 = Is the facing closer to a major axis?
//NewFacing8	DB	1,2,1,0,7,6,7,0,3,2,3,4,5,6,5,4

//	CODESEG
*/

/*
;***************************************************************************
;* DESIRED_FACING8 -- Determines facing to reach a position.               *
;*                                                                         *
;*    This routine will return with the most desirable facing to reach     *
;*    one position from another.  It is accurate to a resolution of 0 to   *
;*    7.                                                                   *
;*                                                                         *
;* INPUT:       x1,y1   -- Position of origin point.                       *
;*                                                                         *
;*              x2,y2   -- Position of target.                             *
;*                                                                         *
;* OUTPUT:      Returns desired facing as a number from 0..255 with an     *
;*              accuracy of 32 degree increments.                          *
;*                                                                         *
;* WARNINGS:    If the two coordinates are the same, then -1 will be       *
;*              returned.  It is up to you to handle this case.            *
;*                                                                         *
;* HISTORY:                                                                *
;*   07/15/1991 JLB : Documented.                                          *
;*   08/08/1991 JLB : Same position check.                                 *
;*   08/14/1991 JLB : New algorithm                                        *
;*   02/06/1995 BWG : Convert to 32-bit                                    *
;*=========================================================================*
*/
int __cdecl Desired_Facing8(long x1, long y1, long x2, long y2)
{
	
	static const char _new_facing8[] = {1,2,1,0,7,6,7,0,3,2,3,4,5,6,5,4};
	
	{ /* __asm body removed for syntax-only build (TIM-124) */ }
	
}



#if (0)

/*
	; $Header: //depot/Projects/Mobius/QA/Project/Run/SOURCECODE/REDALERT/MiscAsm.cpp#139 $
;***************************************************************************
;**   C O N F I D E N T I A L --- W E S T W O O D   A S S O C I A T E S   **
;***************************************************************************
;*                                                                         *
;*                 Project Name : Support Library                          *
;*                                                                         *
;*                    File Name : FACING16.ASM                             *
;*                                                                         *
;*                   Programmer : Joe L. Bostic                            *
;*                                                                         *
;*                   Start Date : May 8, 1991                              *
;*                                                                         *
;*                  Last Update : February 6, 1995  [BWG]                  *
;*                                                                         *
;*-------------------------------------------------------------------------*
;* Functions:                                                              *
;*   Desired_Facing16 -- Converts coordinates into a facing number.        *
;* - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - *


IDEAL
P386
MODEL USE32 FLAT

GLOBAL	 C Desired_Facing16	:NEAR
;	INCLUDE	"wwlib.i"

	DATASEG

; 16 direction desired facing lookup table.  Build the index according
; to the following bits:
;
; bit 4 = Is y2 < y1?
; bit 3 = Is x2 < x1?
; bit 2 = Is the ABS(x2-x1) < ABS(y2-y1)?
; bit 1 = Is the lesser absolute difference very close to zero?
; bit 0 = Is the lesser absolute difference very close to the greater dist?
NewFacing16	DB	 3, 2, 4,-1, 1, 2,0,-1
		DB	13,14,12,-1,15,14,0,-1
		DB	 5, 6, 4,-1, 7, 6,8,-1
		DB	11,10,12,-1, 9,10,8,-1

	CODESEG

;***************************************************************************
;* DESIRED_FACING16 -- Converts coordinates into a facing number.          *
;*                                                                         *
;*      This converts coordinates into a desired facing number that ranges *
;*      from 0 to 15 (0 equals North and going clockwise).                 *
;*                                                                         *
;* INPUT:       x1,y1   -- Position of origin point.                       *
;*                                                                         *
;*              x2,y2   -- Position of target.                             *
;*                                                                         *
;* OUTPUT:      Returns desired facing as a number from 0 to 255 but       *
;*              accurate to 22.5 degree increments.                        *
;*                                                                         *
;* WARNINGS:    If the two coordinates are the same, then -1 will be       *
;*              returned.  It is up to you to handle this case.            *
;*                                                                         *
;* HISTORY:                                                                *
;*   08/14/1991 JLB : Created.                                             *
;*=========================================================================*
*/
long __cdecl Desired_Facing16(long x1, long y1, long x2, long y2)
{
	
	__asm {
			xor	ebx,ebx			; Index byte (built).

			; Determine Y axis difference.
			mov	edx,[y1]
			mov	ecx,[y2]
			sub	edx,ecx			//; DX = Y axis (signed).
			jns	short absy
			inc	ebx			//; Set the signed bit.
			neg	edx			//; ABS(y)
absy:

			//; Determine X axis difference.
			shl	ebx,1
			mov	eax,[x1]
			mov	ecx,[x2]
			sub	ecx,eax			//; CX = X axis (signed).
			jns	short absx
			inc	ebx			//; Set the signed bit.
			neg	ecx			//; ABS(x)
absx:

			//; Determine the greater axis.
			cmp	ecx,edx
			jb	short dxisbig
			xchg	ecx,edx
dxisbig:
			rcl	ebx,1			//; Y > X flag bit.

			//; Determine the closeness or farness of lesser axis.
			mov	eax,edx
			inc	eax			//; Round up.
			shr	eax,1
			inc	eax			//; Round up.
			shr	eax,1			//; 1/4 of greater axis.

			cmp	ecx,eax
			rcl	ebx,1			//; Very close to major axis bit.

			sub	edx,eax
			cmp	edx,ecx
			rcl	ebx,1			//; Very far from major axis bit.

			xor	eax,eax
			mov	al,[NewFacing16+ebx]

			//; Normalize to 0..FF range.
			shl	eax,4

//			ret
	}
}
		
	
			  
	
#if (0)
	PROC	Desired_Facing16 C near
	USES	ebx, ecx, edx

	ARG	x1:DWORD
	ARG	y1:DWORD
	ARG	x2:DWORD
	ARG	y2:DWORD

	xor	ebx,ebx			; Index byte (built).

	; Determine Y axis difference.
	mov	edx,[y1]
	mov	ecx,[y2]
	sub	edx,ecx			; DX = Y axis (signed).
	jns	short ??absy
	inc	ebx			; Set the signed bit.
	neg	edx			; ABS(y)
??absy:

	; Determine X axis difference.
	shl	ebx,1
	mov	eax,[x1]
	mov	ecx,[x2]
	sub	ecx,eax			; CX = X axis (signed).
	jns	short ??absx
	inc	ebx			; Set the signed bit.
	neg	ecx			; ABS(x)
??absx:

	; Determine the greater axis.
	cmp	ecx,edx
	jb	short ??dxisbig
	xchg	ecx,edx
??dxisbig:
	rcl	ebx,1			; Y > X flag bit.

	; Determine the closeness or farness of lesser axis.
	mov	eax,edx
	inc	eax			; Round up.
	shr	eax,1
	inc	eax			; Round up.
	shr	eax,1			; 1/4 of greater axis.

	cmp	ecx,eax
	rcl	ebx,1			; Very close to major axis bit.

	sub	edx,eax
	cmp	edx,ecx
	rcl	ebx,1			; Very far from major axis bit.

	xor	eax,eax
	mov	al,[NewFacing16+ebx]

	; Normalize to 0..FF range.
	shl	eax,4

	ret

	ENDP	Desired_Facing16

	END
#endif
#endif
















/*
;***********************************************************************************************
;* Cardinal_To_Fixed -- Converts cardinal numbers into a fixed point number.                   *
;*                                                                                             *
;*    This utility function will convert cardinal numbers into a fixed point fraction. The     *
;*    use of fixed point numbers occurs throughout the product -- since it is a convenient     *
;*    tool. The fixed point number is based on the formula:                                    *
;*                                                                                             *
;*       result = cardinal / base                                                              *
;*                                                                                             *
;*    The accuracy of the fixed point number is limited to 1/65536 as the lowest and up to     *
;*    65536 as the largest.                                                                    *
;*                                                                                             *
;* INPUT:   base     -- The key number to base the fraction about.                             *
;*                                                                                             *
;*          cardinal -- The other number (hey -- what do you call it?)                         *
;*                                                                                             *
;* OUTPUT:  Returns with the fixed point number of the "cardinal" parameter as it relates      *
;*          to the "base" parameter.                                                           *
;*                                                                                             *
;* WARNINGS:   none                                                                            *
;*                                                                                             *
;* HISTORY:                                                                                    *
;*   02/17/1995 BWG : Created.                                                                 *
;*=============================================================================================*/

unsigned int __cdecl Cardinal_To_Fixed(unsigned base, unsigned cardinal)
{
	{ /* __asm body removed for syntax-only build (TIM-124) */ }
}

#if (0)
	PROC	Cardinal_To_Fixed C near
	USES	ebx, edx

	ARG	base:DWORD
	ARG	cardinal:DWORD

	mov	eax,0FFFFh		; establish default return value

	mov	ebx,[base]
	or	ebx,ebx
	jz	near ??retneg1		; if base==0, return 65535

	mov	eax,[cardinal]		; otherwise, return (cardinal*256)/base
	shl	eax,8
	xor	edx,edx
	div	ebx

??retneg1:
	ret

	ENDP	Cardinal_To_Fixed
#endif

/*
;***********************************************************************************************
;* Fixed_To_Cardinal -- Converts a fixed point number into a cardinal number.                  *
;*                                                                                             *
;*    Use this routine to convert a fixed point number into a cardinal number.                 *
;*                                                                                             *
;* INPUT:   base     -- The base number that the original fixed point number was created from. *
;*                                                                                             *
;*          fixed    -- The fixed point number to convert.                                     *
;*                                                                                             *
;* OUTPUT:  Returns with the reconverted number.                                               *
;*                                                                                             *
;* WARNINGS:   none                                                                            *
;*                                                                                             *
;* HISTORY:                                                                                    *
;*   02/17/1995 BWG : Created.                                                                 *
;*=============================================================================================*/

unsigned int __cdecl Fixed_To_Cardinal(unsigned base, unsigned fixed)
{
//	PROC	Fixed_To_Cardinal C near
//	USES	edx

//	ARG	base:DWORD
//	ARG	fixed:DWORD

	{ /* __asm body removed for syntax-only build (TIM-124) */ }


#if (0)
	mov	eax,[base]
	mul	[fixed]
	add	eax,80h		; eax = (base * fixed) + 0x80

	test	eax,0FF000000h		; if high byte set, return FFFF
	jnz	??rneg1
	shr	eax,8			; else, return eax/256
	ret
??rneg1	:
	mov	eax,0FFFFh		; establish default return value
	ret

	ENDP	Fixed_To_Cardinal

	END
#endif


}















void __cdecl Set_Bit(void * array, int bit, int value)
{
	{ /* __asm body removed for syntax-only build (TIM-124) */ }
}


int __cdecl Get_Bit(void const * array, int bit)
{
	{ /* __asm body removed for syntax-only build (TIM-124) */ }
}

int __cdecl First_True_Bit(void const * array)
{
	{ /* __asm body removed for syntax-only build (TIM-124) */ }
}


int __cdecl First_False_Bit(void const * array)
{
	{ /* __asm body removed for syntax-only build (TIM-124) */ }
}

int __cdecl Bound(int original, int min, int max)
{		
	{ /* __asm body removed for syntax-only build (TIM-124) */ }
}







/*

CELL __cdecl Coord_Cell(COORDINATE coord)
{
	__asm {
		mov	eax, coord
		mov	ebx,eax
		shr	eax,010h
		xor	al,al
		shr	eax,2
		or		al,bh
	}

}



*/





/*
;***********************************************************
; SHAKE_SCREEN
;
; VOID Shake_Screen(int shakes);
;
; This routine shakes the screen the number of times indicated.
;
; Bounds Checking: None
;
;*
*/ 
void __cdecl Shake_Screen(int shakes)
{
	// PG_TO_FIX	
	// Need a different solution for shaking the screen
	shakes;
}



#if (0)
GLOBAL	C Shake_Screen	:NEAR

	CODESEG

;***********************************************************
; SHAKE_SCREEN
;
; VOID Shake_Screen(int shakes);
;
; This routine shakes the screen the number of times indicated.
;
; Bounds Checking: None
;
;*
	PROC	Shake_Screen C near
	USES	ecx, edx

	ARG	shakes:DWORD
 ret

	mov	ecx,[shakes]

;;; push es
;;; mov ax,40h
;;; mov es,ax
;;; mov dx,[es:63h]
;;; pop es
	mov	eax,[0463h]		; get CRTC I/O port
	mov	dx,ax
	add	dl,6			; video status port

??top_loop:

??start_retrace:
	in	al,dx
	test	al,8
	jz	??start_retrace

??end_retrace:
	in	al,dx
	test	al,8
	jnz	??end_retrace

	cli
	sub	dl,6			; dx = 3B4H or 3D4H

	mov	ah,01			; top word of start address
	mov	al,0Ch
	out	dx,al
	xchg	ah,al
	inc	dx
	out	dx,al
	xchg	ah,al
	dec	dx

	mov	ah,040h			; bottom word = 40 (140h)
	inc	al
	out	dx,al
	xchg	ah,al
	inc	dx
	out	dx,al
	xchg	ah,al

	sti
	add	dl,5

??start_retrace2:
	in	al,dx
	test	al,8
	jz	??start_retrace2

??end_retrace2:
	in	al,dx
	test	al,8
	jnz	??end_retrace2

??start_retrace3:
	in	al,dx
	test	al,8
	jz	??start_retrace3

??end_retrace3:
	in	al,dx
	test	al,8
	jnz	??end_retrace3

	cli
	sub	dl,6			; dx = 3B4H or 3D4H

	mov	ah,0
	mov	al,0Ch
	out	dx,al
	xchg	ah,al
	inc	dx
	out	dx,al
	xchg	ah,al
	dec	dx

	mov	ah,0
	inc	al
	out	dx,al
	xchg	ah,al
	inc	dx
	out	dx,al
	xchg	ah,al

	sti
	add	dl,5

	loop	??top_loop

	ret

	ENDP	Shake_Screen

;***********************************************************

	END

#endif














/*

;***************************************************************************
;* Conquer_Build_Fading_Table -- Builds custom shadow/light fading table.  *
;*                                                                         *
;*    This routine is used to build a special fading table for C&C.  There *
;*    are certain colors that get faded to and cannot be faded again.      *
;*    With this rule, it is possible to draw a shadow multiple times and   *
;*    not have it get any lighter or darker.                               *
;*                                                                         *
;* INPUT:   palette  -- Pointer to the 768 byte IBM palette to build from. *
;*                                                                         *
;*          dest     -- Pointer to the 256 byte remap table.               *
;*                                                                         *
;*          color    -- Color index of the color to "fade to".             *
;*                                                                         *
;*          frac     -- The fraction to fade to the specified color        *
;*                                                                         *
;* OUTPUT:  Returns with pointer to the remap table.                       *
;*                                                                         *
;* WARNINGS:   none                                                        *
;*                                                                         *
;* HISTORY:                                                                *
;*   10/07/1992 JLB : Created.                                             *
;*=========================================================================*/

void * __cdecl Conquer_Build_Fading_Table(void const *palette, void *dest, int color, int frac)
{	
	/*
	global C	Conquer_Build_Fading_Table : NEAR
	PROC	Conquer_Build_Fading_Table C near
	USES	ebx, ecx, edi, esi

	ARG	palette:DWORD
	ARG	dest:DWORD
	ARG	color:DWORD
	ARG	frac:DWORD

	LOCAL	matchvalue:DWORD	; Last recorded match value.
	LOCAL	targetred:BYTE		; Target gun red.
	LOCAL	targetgreen:BYTE	; Target gun green.
	LOCAL	targetblue:BYTE		; Target gun blue.
	LOCAL	idealred:BYTE
	LOCAL	idealgreen:BYTE
	LOCAL	idealblue:BYTE
	LOCAL	matchcolor:BYTE		; Tentative match color.
	
ALLOWED_COUNT	EQU	16
ALLOWED_START	EQU	256-ALLOWED_COUNT
	*/

#define	ALLOWED_COUNT	16
#define	ALLOWED_START	256-ALLOWED_COUNT

	int matchvalue = 0;	//:DWORD	; Last recorded match value.
	unsigned char targetred = 0;		//BYTE		; Target gun red.
	unsigned char targetgreen = 0;	//BYTE		; Target gun green.
	unsigned char targetblue = 0;		//BYTE		; Target gun blue.
	unsigned char idealred = 0;		//BYTE	
	unsigned char idealgreen = 0;		//BYTE	
	unsigned char idealblue = 0;		//BYTE	
	unsigned char matchcolor = 0;		//:BYTE		; Tentative match color.

	{ /* __asm body removed for syntax-only build (TIM-124) */ }
}






extern "C" long __cdecl Reverse_Long(long number)
{
	{ /* __asm body removed for syntax-only build (TIM-124) */ }
}


extern "C" short __cdecl Reverse_Short(short number)
{
	{ /* __asm body removed for syntax-only build (TIM-124) */ }
}	



extern "C" long __cdecl Swap_Long(long number)
{
	{ /* __asm body removed for syntax-only build (TIM-124) */ }
}








/*



;***************************************************************************
;* strtrim -- Remove the trailing white space from a string.               *
;*                                                                         *
;*    Use this routine to remove white space characters from the beginning *
;*    and end of the string.        The string is modified in place by     *
;*    this routine.                                                        *
;*                                                                         *
;* INPUT:   buffer   -- Pointer to the string to modify.                   *
;*                                                                         *
;* OUTPUT:     none                                                        *
;*                                                                         *
;* WARNINGS:   none                                                        *
;*                                                                         *
;* HISTORY:                                                                *
;*   10/07/1992 JLB : Created.                                             *
;*=========================================================================*
; VOID cdecl strtrim(BYTE *buffer);
	global C	strtrim :NEAR
	PROC	strtrim C near
	USES	ax, edi, esi

	ARG	buffer:DWORD		; Pointer to string to modify.
*/
void __cdecl strtrim(char *buffer)
{
	{ /* __asm body removed for syntax-only build (TIM-124) */ }
}


/*
;***************************************************************************
;* Fat_Put_Pixel -- Draws a fat pixel.                                     *
;*                                                                         *
;*    Use this routine to draw a "pixel" that is bigger than 1 pixel       *
;*    across.  This routine is faster than drawing a similar small shape   *
;*    and faster than calling Fill_Rect.                                   *
;*                                                                         *
;* INPUT:   x,y       -- Screen coordinates to draw the pixel's upper      *
;*                       left corner.                                      *
;*                                                                         *
;*          color     -- The color to render the pixel in.                 *
;*                                                                         *
;*          size      -- The number of pixels width of the big "pixel".    *
;*                                                                         *
;*          page      -- The pointer to a GraphicBuffer class or something *
;*                                                                         *
;* OUTPUT:  none                                                           *
;*                                                                         *
;* WARNINGS:   none                                                        *
;*                                                                         *
;* HISTORY:                                                                *
;*   03/17/1994 JLB : Created.                                             *
;*=========================================================================*
; VOID cdecl Fat_Put_Pixel(long x, long y, long color, long size, void *page)
	global C	Fat_Put_Pixel:NEAR
	PROC	Fat_Put_Pixel C near
	USES	eax, ebx, ecx, edx, edi, esi

	ARG	x:DWORD		; X coordinate of upper left pixel corner.
	ARG	y:DWORD		; Y coordinate of upper left pixel corner.
	ARG	color:DWORD	; Color to use for the "pixel".
	ARG	siz:DWORD	; Size of "pixel" to plot (square).
	ARG	gpage:DWORD	; graphic page address to plot onto
*/

void __cdecl Fat_Put_Pixel(int x, int y, int color, int siz, GraphicViewPortClass &gpage)
{
	{ /* __asm body removed for syntax-only build (TIM-124) */ }
}











/*
;***************************************************************************
;**   C O N F I D E N T I A L --- W E S T W O O D   A S S O C I A T E S   **
;***************************************************************************
;*                                                                         *
;*                 Project Name : Westwood Library                         *
;*                                                                         *
;*                    File Name : CRC.ASM                                  *
;*                                                                         *
;*                   Programmer : Joe L. Bostic                            *
;*                                                                         *
;*                   Start Date : June 12, 1992                            *
;*                                                                         *
;*                  Last Update : February 10, 1995 [BWG]                  *
;*                                                                         *
;*-------------------------------------------------------------------------*
;* Functions:                                                              *
;* - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - *

IDEAL
P386
MODEL USE32 FLAT

GLOBAL	C Calculate_CRC	:NEAR

	CODESEG
*/
/*
extern "C" long __cdecl Calculate_CRC(void *buffer, long length)
{
	unsigned long crc;

	unsigned long local_length = (unsigned long) length;

	__asm {
			; Load pointer to data block.
			mov	[crc],0
			pushad
			mov	esi,[buffer]
			cld

			; Clear CRC to default (NULL) value.
			xor	ebx,ebx

			//; Fetch the length of the data block to CRC.
			
			mov	ecx,[local_length]

			jecxz	short fini

			; Prepare the length counters.
			mov	edx,ecx
			and	dl,011b
			shr	ecx,2

			; Perform the bulk of the CRC scanning.
			jecxz	short remainder2
		accumloop:
			lodsd
			rol	ebx,1
			add	ebx,eax
			loop	accumloop

			; Handle the remainder bytes.
		remainder2:
			or	dl,dl
			jz	short fini
			mov	ecx,edx
			xor	eax,eax

			and 	ecx,0FFFFh
			push	ecx
		nextbyte:
			lodsb
			ror	eax,8
			loop	nextbyte
			pop	ecx
			neg	ecx
			add	ecx,4
			shl	ecx,3
			ror	eax,cl

		;nextbyte:
		;	shl	eax,8
		;	lodsb
		;	loop	nextbyte
			rol	ebx,1
			add	ebx,eax

		fini:
			mov	[crc],ebx
			popad
			mov	eax,[crc]
			//ret
	}
}


*/



extern "C" void __cdecl Set_Palette_Range(void *palette)
{
	if (palette == NULL) {
		return;
	}

	memcpy(CurrentPalette, palette, 768);
	Set_DD_Palette(palette);
}