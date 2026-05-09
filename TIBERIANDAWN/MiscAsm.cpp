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
#ifndef _MSC_VER
	// TIM-339: Dragon Strike distance — max(|dx|,|dy|) + min(|dx|,|dy|)/2
	int diff1 = (int)Coord_Y(coord1) - (int)Coord_Y(coord2);
	if (diff1 < 0) diff1 = -diff1;
	int diff2 = (int)Coord_X(coord1) - (int)Coord_X(coord2);
	if (diff2 < 0) diff2 = -diff2;
	if (diff1 > diff2) return diff1 + ((unsigned)diff2 >> 1);
	return diff2 + ((unsigned)diff1 >> 1);
#else
	{}
#endif
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

#ifndef _MSC_VER
	// TIM-339: port of Westwood FACING16.ASM 5-bit lookup table algorithm.
	// Bits: [4]=y2>y1(S), [3]=x2<x1(W), [2]=|y|>|x|, [1]=close-to-axis, [0]=close-to-45deg
	if (x1 == x2 && y1 == y2) return (long)-1;
	int idx = 0;
	long abs_y = y1 - y2;
	if (abs_y < 0) { idx = 1; abs_y = -abs_y; }
	idx <<= 1;
	long abs_x = x2 - x1;
	if (abs_x < 0) { idx |= 1; abs_x = -abs_x; }
	long max_val, min_val;
	if (abs_x < abs_y) { max_val = abs_y; min_val = abs_x; idx = (idx << 1) | 1; }
	else               { max_val = abs_x; min_val = abs_y; idx <<= 1; }
	long threshold = max_val; threshold++; threshold >>= 1; threshold++; threshold >>= 1;
	idx <<= 1; if (min_val < threshold) idx |= 1;
	idx <<= 1; if ((max_val - threshold) < min_val) idx |= 1;
	return ((long)(unsigned char)_new_facing16[idx]) << 4;
#else
	{}
#endif
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
#ifndef _MSC_VER
	// TIM-339: port of FACE.CPP Desired_Facing256 algorithm (long-param variant).
	int composite = 0;
	long xdiff = dstx - srcx;
	if (xdiff < 0) { composite |= 0x00C0; xdiff = -xdiff; }
	long ydiff = srcy - dsty;
	if (ydiff < 0) { composite ^= 0x0040; ydiff = -ydiff; }
	if (xdiff == 0 && ydiff == 0) return 0xFF;
	long bigger = (xdiff < ydiff) ? ydiff : xdiff;
	long smaller = (xdiff < ydiff) ? xdiff : ydiff;
	int frac = (int)((smaller * 32) / bigger);
	int adder = (composite & 0x0040);
	if (xdiff > ydiff) adder ^= 0x0040;
	if (adder) frac = (adder - frac) - 1;
	composite += frac;
	return (composite & 0xFF);
#else
	{}
#endif
}




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

#ifndef _MSC_VER
	// TIM-339: port of Westwood FACING8.ASM 4-bit lookup table algorithm.
	// Bits: [3]=y2>y1(S), [2]=x2<x1(W), [1]=|y|>|x|, [0]=close-to-axis
	if (x1 == x2 && y1 == y2) return -1;
	int idx = 0;
	long abs_y = y1 - y2;
	if (abs_y < 0) { idx = 1; abs_y = -abs_y; }
	idx <<= 1;
	long abs_x = x2 - x1;
	if (abs_x < 0) { idx |= 1; abs_x = -abs_x; }
	long max_val, min_val;
	if (abs_x < abs_y) { max_val = abs_y; min_val = abs_x; idx = (idx << 1) | 1; }
	else               { max_val = abs_x; min_val = abs_y; idx <<= 1; }
	long threshold = max_val; threshold++; threshold >>= 1;
	idx <<= 1; if (min_val < threshold) idx |= 1;
	return ((int)(unsigned char)_new_facing8[idx]) << 5;
#else
	{}
#endif
}


#if (0)
// [Old FACING16.ASM duplicate — dead code, kept for reference]
long __cdecl Desired_Facing16(long x1, long y1, long x2, long y2);
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
;*    The accuracy of the fixed point number is limited to 1/256 as the lowest and up to       *
;*    256 as the largest.                                                                      *
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
#ifndef _MSC_VER
	// TIM-339: (cardinal * 256) / base, clamped to 0xFFFF when base==0
	if (base == 0) return 0xFFFFU;
	unsigned long result = ((unsigned long)cardinal << 8) / (unsigned long)base;
	return (unsigned int)(result > 0xFFFFU ? 0xFFFFU : result);
#else
	{}
#endif
}


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
#ifndef _MSC_VER
	// TIM-339: (base * fixed + 0x80) >> 8, returns 0xFFFF on overflow
	unsigned long product = (unsigned long)base * (unsigned long)fixed + 0x80U;
	if (product & 0xFF000000UL) return 0xFFFFU;
	return (unsigned int)(product >> 8);
#else
	{}
#endif
}


void __cdecl Set_Bit(void * array, int bit, int value)
{
#ifndef _MSC_VER
	// TIM-339: portable bit-set/clear using byte array
	unsigned char *a = (unsigned char*)array;
	if (value) a[bit >> 3] |=  (unsigned char)(1 << (bit & 7));
	else       a[bit >> 3] &= ~(unsigned char)(1 << (bit & 7));
#else
	{}
#endif
}


int __cdecl Get_Bit(void const * array, int bit)
{
#ifndef _MSC_VER
	// TIM-339: portable bit-get from byte array
	const unsigned char *a = (const unsigned char*)array;
	return (a[bit >> 3] >> (bit & 7)) & 1;
#else
	{}
#endif
}

int __cdecl First_True_Bit(void const * array)
{
#ifndef _MSC_VER
	// TIM-339: portable linear scan for first set bit
	const unsigned char *a = (const unsigned char*)array;
	for (int i = 0; i < 4096; i++) {
		if (a[i >> 3] & (1 << (i & 7))) return i;
	}
	return -1;
#else
	{}
#endif
}


int __cdecl First_False_Bit(void const * array)
{
#ifndef _MSC_VER
	// TIM-339: portable linear scan for first clear bit
	const unsigned char *a = (const unsigned char*)array;
	for (int i = 0; i < 4096; i++) {
		if (!(a[i >> 3] & (1 << (i & 7)))) return i;
	}
	return -1;
#else
	{}
#endif
}

int __cdecl Bound(int original, int min, int max)
{
#ifndef _MSC_VER
	// TIM-339: portable clamp; swap min/max if out of order (matching asm behavior)
	if (min > max) { int t = min; min = max; max = t; }
	if (original < min) return min;
	if (original > max) return max;
	return original;
#else
	{}
#endif
}


CELL __cdecl Coord_Cell(COORDINATE coord)
{
#ifndef _MSC_VER
	// TIM-339: extract cell index from lepton coordinate.
	// coord = (Y_lepton << 16) | X_lepton; cell = Cell_Y*64 + Cell_X
	// where Cell_Y = Y_lepton>>8, Cell_X = X_lepton>>8, map width = 64 cells.
	int cell_y = (coord >> 24) & 0xFF;
	int cell_x = (coord >>  8) & 0xFF;
	return (CELL)(cell_y * 64 + cell_x);
#else
	{}
#endif
}


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

#define	ALLOWED_COUNT	16
#define	ALLOWED_START	(256-ALLOWED_COUNT)

void * __cdecl Conquer_Build_Fading_Table(void const *palette, void *dest, int color, int frac)
{
#ifndef _MSC_VER
	// TIM-339: C port — blend each palette entry toward 'color' by frac/256,
	// then find nearest match in the ALLOWED (shadow) range only.
	// Colors already in ALLOWED range map to themselves (no further fading).
	if (!palette || !dest) return dest;
	if (frac > 255) frac = 255;
	const unsigned char *pal = (const unsigned char*)palette;
	unsigned char *out = (unsigned char*)dest;
	int tred = pal[color * 3], tgrn = pal[color * 3 + 1], tblu = pal[color * 3 + 2];
	out[0] = 0;  // transparent black maps to itself
	for (int i = 1; i < 256; i++) {
		if (i >= ALLOWED_START) { out[i] = (unsigned char)i; continue; }
		int ired = pal[i*3]   + ((tred - pal[i*3])   * frac >> 8);
		int igrn = pal[i*3+1] + ((tgrn - pal[i*3+1]) * frac >> 8);
		int iblu = pal[i*3+2] + ((tblu - pal[i*3+2]) * frac >> 8);
		int best = 0x7FFFFFFF;
		unsigned char mc = (unsigned char)ALLOWED_START;
		for (int j = ALLOWED_START; j < 256; j++) {
			int dr = pal[j*3] - ired, dg = pal[j*3+1] - igrn, db = pal[j*3+2] - iblu;
			int d = dr*dr + dg*dg + db*db;
			if (d < best) { best = d; mc = (unsigned char)j; if (!d) break; }
		}
		out[i] = mc;
	}
	return dest;
#else
	{}
#endif
}


extern "C" long __cdecl Reverse_Long(long number)
{
#ifndef _MSC_VER
	// TIM-339: bswap32 on the low 32 bits
	unsigned long n = (unsigned long)number & 0xFFFFFFFFUL;
	n = ((n & 0xFF) << 24) | ((n & 0xFF00) << 8) | ((n >> 8) & 0xFF00) | ((n >> 24) & 0xFF);
	return (long)n;
#else
	{}
#endif
}


extern "C" short __cdecl Reverse_Short(short number)
{
#ifndef _MSC_VER
	// TIM-339: bswap16
	unsigned short n = (unsigned short)number;
	return (short)(((n & 0xFF) << 8) | ((n >> 8) & 0xFF));
#else
	{}
#endif
}


extern "C" long __cdecl Swap_Long(long number)
{
#ifndef _MSC_VER
	// TIM-339: rotate 16 — swap upper and lower 16-bit halves of 32-bit value
	unsigned long n = (unsigned long)number & 0xFFFFFFFFUL;
	return (long)(((n & 0xFFFF) << 16) | ((n >> 16) & 0xFFFF));
#else
	{}
#endif
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
;*=========================================================================*/
void __cdecl strtrim(char *buffer)
{
#ifndef _MSC_VER
	// TIM-339: portable strtrim — strip leading and trailing whitespace in-place
	if (!buffer) return;
	char *end = buffer + strlen(buffer) - 1;
	while (end >= buffer && (*end == ' ' || *end == '\t' || *end == '\n' || *end == '\r'))
		*end-- = '\0';
	char *start = buffer;
	while (*start == ' ' || *start == '\t') start++;
	if (start != buffer) memmove(buffer, start, strlen(start) + 1);
#else
	{}
#endif
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
;*=========================================================================*/
void __cdecl Fat_Put_Pixel(int x, int y, int color, int siz, GraphicViewPortClass &gpage)
{
#ifndef _MSC_VER
	// TIM-339: portable Fat_Put_Pixel — draw a siz×siz square pixel
	if (siz <= 0) return;
	int stride = gpage.Get_Width() + gpage.Get_XAdd() + (int)gpage.Get_Pitch();
	unsigned char *buf = (unsigned char*)(uintptr_t)gpage.Get_Offset();
	int w = gpage.Get_Width(), h = gpage.Get_Height();
	for (int row = y; row < y + siz; row++) {
		if (row < 0 || row >= h) continue;
		for (int col = x; col < x + siz; col++) {
			if (col < 0 || col >= w) continue;
			buf[row * stride + col] = (unsigned char)color;
		}
	}
#else
	{}
#endif
}


/*
;***************************************************************************
;* Calculate_CRC -- Computes a CRC on a block of data.                     *
;*                                                                         *
;* INPUT:   buffer   -- Pointer to the data block.                         *
;*          length   -- Length of the data block in bytes.                 *
;*                                                                         *
;* OUTPUT:  Returns the CRC value of the data block.                       *
;*                                                                         *
;* HISTORY:                                                                *
;*   06/12/1992 JLB : Created.                                             *
;*=========================================================================*/
extern "C" long __cdecl Calculate_CRC(void *buffer, long length)
{
#ifndef _MSC_VER
	// TIM-339: rotating additive CRC — for each 4-byte word: crc=ROL(crc,1)+word;
	// remainder bytes are assembled little-endian before the final accumulate step.
	unsigned long crc = 0;
	const unsigned char *src = (const unsigned char*)buffer;
	unsigned long len = (unsigned long)length;
	unsigned long full_words = len >> 2;
	unsigned long remainder  = len & 3;

	for (unsigned long i = 0; i < full_words; i++, src += 4) {
		unsigned long word;
		memcpy(&word, src, 4);  // little-endian load (x86 native order)
		crc = (crc << 1) | (crc >> 31);
		crc += word;
	}
	if (remainder) {
		unsigned long word = 0;
		for (unsigned long i = 0; i < remainder; i++)
			word |= ((unsigned long)src[i]) << (i * 8);
		crc = (crc << 1) | (crc >> 31);
		crc += word;
	}
	return (long)crc;
#else
	{}
#endif
}


extern "C" void __cdecl Set_Palette_Range(void *palette)
{
	if (palette == NULL) {
		return;
	}

	memcpy(CurrentPalette, palette, 768);
	Set_DD_Palette(palette);
}
