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
** 
**  Misc asm functions from ww lib
**  ST - 12/19/2018 1:20PM
** 
** 
** 
** 
** 
** 
** 
** 
** 
** 
** 
*/

#include "gbuffer.h"
#include "MISC.H"
#include "WSA.H"

IconCacheClass::IconCacheClass (void)
{
	IsCached			=FALSE;
	SurfaceLost		=FALSE;
	DrawFrequency	=0;
	CacheSurface	=NULL;
	IconSource		=NULL;
}

IconCacheClass::~IconCacheClass (void)
{
}		  

IconCacheClass	CachedIcons[MAX_CACHED_ICONS];

extern "C"{
IconSetType		IconSetList[MAX_ICON_SETS];
short				IconCacheLookup[MAX_LOOKUP_ENTRIES];
}

int		CachedIconsDrawn=0;		//Counter of number of cache hits
int		UnCachedIconsDrawn=0;	//Counter of number of cache misses
BOOL	CacheMemoryExhausted;	//Flag set if we have run out of video RAM


void Invalidate_Cached_Icons (void) {}
void Restore_Cached_Icons (void) {}
void Register_Icon_Set (void *icon_data , BOOL pre_cache) {};

//
// Prototypes for assembly language procedures in STMPCACH.ASM
//
extern "C" void __cdecl Clear_Icon_Pointers (void) {};
extern "C" void __cdecl Cache_Copy_Icon (void const *icon_ptr ,void * , int) {};
extern "C" int __cdecl Is_Icon_Cached (void const *icon_data , int icon) {return -1;};
extern "C" int __cdecl Get_Icon_Index (void *icon_ptr) {return 0;};
extern "C" int __cdecl Get_Free_Index (void) {return 0;};
extern "C" BOOL __cdecl Cache_New_Icon (int icon_index, void *icon_ptr) {return -1;};
extern "C" int __cdecl Get_Free_Cache_Slot(void) {return -1;}

void IconCacheClass::Draw_It (LPDIRECTDRAWSURFACE dest_surface , int x_pixel, int y_pixel, int window_left , int window_top , int window_width , int window_height) {}



extern	int	CachedIconsDrawn;
extern	int	UnCachedIconsDrawn;


extern "C" void __cdecl Set_Font_Palette_Range(void const *palette, INT start_idx, INT end_idx)
{
}		  


/*
;***************************************************************************
;* VVC::DRAW_LINE -- Scales a virtual viewport to another virtual viewport *
;*                                                                         *
;* INPUT:	WORD sx_pixel 	- the starting x pixel position		   *
;*		WORD sy_pixel	- the starting y pixel position		   *
;*		WORD dx_pixel	- the destination x pixel position	   *
;*		WORD dy_pixel   - the destination y pixel position	   *
;*		WORD color      - the color of the line to draw		   *
;*                                                                         *
;* Bounds Checking: Compares sx_pixel, sy_pixel, dx_pixel and dy_pixel	   *
;*       with the graphic viewport it has been assigned to.		   *
;*                                                                         *
;* HISTORY:                                                                *
;*   06/16/1994 PWG : Created.                                             *
;*   08/30/1994 IML : Fixed clipping bug.				   *
;*=========================================================================*
	PROC	Buffer_Draw_Line C NEAR
	USES	eax,ebx,ecx,edx,esi,edi
*/

void __cdecl Buffer_Draw_Line(void *this_object, int sx, int sy, int dx, int dy, unsigned char color)
{
	unsigned int clip_min_x;
	unsigned int clip_max_x;
	unsigned int clip_min_y;
	unsigned int clip_max_y;
	unsigned int clip_var;
	unsigned int accum;
	unsigned int bpr;
	
	static int _one_time_init = 0;

	//clip_tbl	DD	nada,a_up,a_dwn,nada
	//		DD	a_lft,a_lft,a_dwn,nada
	//		DD	a_rgt,a_up,a_rgt,nada
	//		DD	nada,nada,nada,nada

	static void *_clip_table [4*4] = {0};

	unsigned int int_color = color;
	unsigned int x1_pixel = (unsigned int) sx;
	unsigned int y1_pixel = (unsigned int) sy;
	unsigned int x2_pixel = (unsigned int) dx;
	unsigned int y2_pixel = (unsigned int) dy;
	(void)int_color; (void)_one_time_init; (void)_clip_table;
	(void)clip_var; (void)accum;

	// TIM-164: Bresenham line with unsigned clip (handles negative coords via wrap-around check)
	GraphicViewPortClass *vp = (GraphicViewPortClass*)this_object;
	clip_min_x = 0; clip_max_x = (unsigned int)vp->Get_Width();
	clip_min_y = 0; clip_max_y = (unsigned int)vp->Get_Height();
	bpr = (unsigned int)(vp->Get_Width() + vp->Get_XAdd() + (int)vp->Get_Pitch());
	unsigned char *buf = (unsigned char*)(uintptr_t)vp->Get_Offset();
	int x = (int)x1_pixel, y = (int)y1_pixel;
	int ex = (int)x2_pixel, ey = (int)y2_pixel;
	int xd = ex - x, yd = ey - y;
	int xstep = xd >= 0 ? 1 : -1;
	int ystep = yd >= 0 ? 1 : -1;
	if (xd < 0) xd = -xd;
	if (yd < 0) yd = -yd;
	if (xd >= yd) {
		int err = xd / 2;
		for (int i = 0; i <= xd; i++, x += xstep) {
			if ((unsigned int)x < clip_max_x && (unsigned int)y < clip_max_y)
				buf[y * (int)bpr + x] = color;
			err -= yd; if (err < 0) { y += ystep; err += xd; }
		}
	} else {
		int err = yd / 2;
		for (int i = 0; i <= yd; i++, y += ystep) {
			if ((unsigned int)x < clip_max_x && (unsigned int)y < clip_max_y)
				buf[y * (int)bpr + x] = color;
			err -= xd; if (err < 0) { x += xstep; err += yd; }
		}
	}
}





/*
;***************************************************************************
;**   C O N F I D E N T I A L --- W E S T W O O D   A S S O C I A T E S   **
;***************************************************************************
;*                                                                         *
;*                 Project Name : Westwood 32 bit Library                  *
;*                                                                         *
;*                    File Name : DRAWLINE.ASM                             *
;*                                                                         *
;*                   Programmer : Phil W. Gorrow                           *
;*                                                                         *
;*                   Start Date : June 16, 1994                            *
;*                                                                         *
;*                  Last Update : August 30, 1994   [IML]                  *
;*                                                                         *
;*-------------------------------------------------------------------------*
;* Functions:                                                              *
;*   VVC::Scale -- Scales a virtual viewport to another virtual viewport   *
;*   Normal_Draw -- jump loc for drawing  scaled line of normal pixel      *
;*   __DRAW_LINE -- Assembly routine to draw a line                        *
;* - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - *

IDEAL
P386
MODEL USE32 FLAT

INCLUDE ".\drawbuff.inc"
INCLUDE ".\gbuffer.inc"


CODESEG
*/


/*
;***************************************************************************
;* VVC::DRAW_LINE -- Scales a virtual viewport to another virtual viewport *
;*                                                                         *
;* INPUT:	WORD sx_pixel 	- the starting x pixel position		   *
;*		WORD sy_pixel	- the starting y pixel position		   *
;*		WORD dx_pixel	- the destination x pixel position	   *
;*		WORD dy_pixel   - the destination y pixel position	   *
;*		WORD color      - the color of the line to draw		   *
;*                                                                         *
;* Bounds Checking: Compares sx_pixel, sy_pixel, dx_pixel and dy_pixel	   *
;*       with the graphic viewport it has been assigned to.		   *
;*                                                                         *
;* HISTORY:                                                                *
;*   06/16/1994 PWG : Created.                                             *
;*   08/30/1994 IML : Fixed clipping bug.				   *
;*=========================================================================*
	PROC	Buffer_Draw_Line C NEAR
	USES	eax,ebx,ecx,edx,esi,edi

	;*==================================================================
	;* Define the arguements that the function takes.
	;*==================================================================
	ARG	this_object:DWORD	; associated graphic view port
	ARG	x1_pixel:DWORD		; the start x pixel position
	ARG	y1_pixel:DWORD		; the start y pixel position
	ARG	x2_pixel:DWORD		; the dest x pixel position
	ARG	y2_pixel:DWORD		; the dest y pixel position
	ARG	color:DWORD		; the color we are drawing

	;*==================================================================
	;* Define the local variables that we will use on the stack
	;*==================================================================
	LOCAL	clip_min_x:DWORD
	LOCAL	clip_max_x:DWORD
	LOCAL	clip_min_y:DWORD
	LOCAL	clip_max_y:DWORD
	LOCAL	clip_var:DWORD
	LOCAL	accum:DWORD
	LOCAL	bpr:DWORD

	;*==================================================================
	;* Take care of find the clip minimum and maximums
	;*==================================================================
	mov	ebx,[this_object]
	xor	eax,eax
	mov	[clip_min_x],eax
	mov	[clip_min_y],eax
	mov	eax,[(GraphicViewPort ebx).GVPWidth]
	mov	[clip_max_x],eax
	add	eax,[(GraphicViewPort ebx).GVPXAdd]
	add	eax,[(GraphicViewPort ebx).GVPPitch]
	mov	[bpr],eax
	mov	eax,[(GraphicViewPort ebx).GVPHeight]
	mov	[clip_max_y],eax

	;*==================================================================
	;* Adjust max pixels as they are tested inclusively.
	;*==================================================================
	dec	[clip_max_x]
	dec	[clip_max_y]

	;*==================================================================
	;* Set the registers with the data for drawing the line
	;*==================================================================
	mov	eax,[x1_pixel]		; eax = start x pixel position
	mov	ebx,[y1_pixel]		; ebx = start y pixel position
	mov	ecx,[x2_pixel]		; ecx = dest x pixel position
	mov	edx,[y2_pixel]		; edx = dest y pixel position

	;*==================================================================
	;* This is the section that "pushes" the line into bounds.
	;* I have marked the section with PORTABLE start and end to signify
	;* how much of this routine is 100% portable between graphics modes.
	;* It was just as easy to have variables as it would be for constants
	;* so the global vars ClipMaxX,ClipMinY,ClipMaxX,ClipMinY are used
	;* to clip the line (default is the screen)
	;* PORTABLE start
	;*==================================================================

	cmp	eax,[clip_min_x]
	jl	short ??clip_it
	cmp	eax,[clip_max_x]
	jg	short ??clip_it
	cmp	ebx,[clip_min_y]
	jl	short ??clip_it
	cmp	ebx,[clip_max_y]
	jg	short ??clip_it
	cmp	ecx,[clip_min_x]
	jl	short ??clip_it
	cmp	ecx,[clip_max_x]
	jg	short ??clip_it
	cmp	edx,[clip_min_y]
	jl	short ??clip_it
	cmp	edx,[clip_max_y]
	jle	short ??on_screen

	;*==================================================================
	;* Takes care off clipping the line.
	;*==================================================================
??clip_it:
	call	NEAR PTR ??set_bits
	xchg	eax,ecx
	xchg	ebx,edx
	mov	edi,esi
	call	NEAR PTR ??set_bits
	mov	[clip_var],edi
	or	[clip_var],esi
	jz	short ??on_screen
	test	edi,esi
	jne	short ??off_screen
	shl	esi,2
	call	[DWORD PTR cs:??clip_tbl+esi]
	jc	??clip_it
	xchg	eax,ecx
	xchg	ebx,edx
	shl	edi,2
	call	[DWORD PTR cs:??clip_tbl+edi]
	jmp	??clip_it

??on_screen:
	jmp	??draw_it

??off_screen:
	jmp	??out

	;*==================================================================
	;* Jump table for clipping conditions
	;*==================================================================
??clip_tbl	DD	??nada,??a_up,??a_dwn,??nada
		DD	??a_lft,??a_lft,??a_dwn,??nada
		DD	??a_rgt,??a_up,??a_rgt,??nada
		DD	??nada,??nada,??nada,??nada

??nada:
	clc
	retn

??a_up:
	mov	esi,[clip_min_y]
	call	NEAR PTR ??clip_vert
	stc
	retn

??a_dwn:
	mov	esi,[clip_max_y]
	neg	esi
	neg	ebx
	neg	edx
	call	NEAR PTR ??clip_vert
	neg	ebx
	neg	edx
	stc
	retn

	;*==================================================================
	;* xa'=xa+[(miny-ya)(xb-xa)/(yb-ya)]
	;*==================================================================
??clip_vert:
	push	edx
	push	eax
	mov	[clip_var],edx		; clip_var = yb
	sub	[clip_var],ebx		; clip_var = (yb-ya)
	neg	eax			; eax=-xa
	add	eax,ecx			; (ebx-xa)
	mov	edx,esi			; edx=miny
	sub	edx,ebx			; edx=(miny-ya)
	imul	edx
	idiv	[clip_var]
	pop	edx
	add	eax,edx
	pop	edx
	mov	ebx,esi
	retn

??a_lft:
	mov	esi,[clip_min_x]
	call	NEAR PTR ??clip_horiz
	stc
	retn

??a_rgt:
	mov	esi,[clip_max_x]
	neg	eax
	neg	ecx
	neg	esi
	call	NEAR PTR ??clip_horiz
	neg	eax
	neg	ecx
	stc
	retn

	;*==================================================================
	;* ya'=ya+[(minx-xa)(yb-ya)/(xb-xa)]
	;*==================================================================
??clip_horiz:
	push	edx
	mov	[clip_var],ecx		; clip_var = xb
	sub	[clip_var],eax		; clip_var = (xb-xa)
	sub	edx,ebx			; edx = (yb-ya)
	neg	eax			; eax = -xa
	add	eax,esi			; eax = (minx-xa)
	imul	edx			; eax = (minx-xa)(yb-ya)
	idiv	[clip_var]		; eax = (minx-xa)(yb-ya)/(xb-xa)
	add	ebx,eax			; ebx = xa+[(minx-xa)(yb-ya)/(xb-xa)]
	pop	edx
	mov	eax,esi
	retn

	;*==================================================================
	;* Sets the condition bits
	;*==================================================================
??set_bits:
	xor	esi,esi
	cmp	ebx,[clip_min_y]	; if y >= top its not up
	jge	short ??a_not_up
	or	esi,1

??a_not_up:
	cmp	ebx,[clip_max_y]	; if y <= bottom its not down
	jle	short ??a_not_down
	or	esi,2

??a_not_down:
	cmp	eax,[clip_min_x]   	; if x >= left its not left
	jge	short ??a_not_left
	or	esi,4

??a_not_left:
	cmp	eax,[clip_max_x]	; if x <= right its not right
	jle	short ??a_not_right
	or	esi,8

??a_not_right:
	retn

	;*==================================================================
	;* Draw the line to the screen.
	;* PORTABLE end
	;*==================================================================
??draw_it:
	sub	edx,ebx			; see if line is being draw down
	jnz	short ??not_hline	; if not then its not a hline
	jmp	short ??hline		; do special case h line

??not_hline:
	jg	short ??down		; if so there is no need to rev it
	neg	edx			; negate for actual pixel length
	xchg	eax,ecx			; swap x's to rev line draw
	sub	ebx,edx			; get old edx

??down:
	push	edx
	push	eax
	mov	eax,[bpr]
	mul	ebx
	mov	ebx,eax
	mov	eax,[this_object]
	add	ebx,[(GraphicViewPort eax).GVPOffset]
	pop	eax
	pop	edx

	mov	esi,1			; assume a right mover
	sub	ecx,eax			; see if line is right
	jnz	short ??not_vline	; see if its a vertical line
	jmp	??vline

??not_vline:
	jg	short ??right		; if so, the difference = length

??left:
	neg	ecx			; else negate for actual pixel length
	neg	esi			; negate counter to move left

??right:
	cmp	ecx,edx			; is it a horiz or vert line
	jge	short ??horiz		; if ecx > edx then |x|>|y| or horiz

??vert:
	xchg	ecx,edx			; make ecx greater and edx lesser
	mov	edi,ecx			; set greater
	mov	[accum],ecx		; set accumulator to 1/2 greater
	shr	[accum],1

	;*==================================================================
	;* at this point ...
	;* eax=xpos ; ebx=page line offset; ecx=counter; edx=lesser; edi=greater;
	;* esi=adder; accum=accumulator
	;* in a vertical loop the adder is conditional and the inc constant
	;*==================================================================
??vert_loop:
	add	ebx,eax
	mov	eax,[color]

??v_midloop:
	mov	[ebx],al
	dec	ecx
	jl	??out
	add	ebx,[bpr]
	sub	[accum],edx		; sub the lesser
	jge	??v_midloop		; any line could be new
	add	[accum],edi		; add greater for new accum
	add	ebx,esi			; next pixel over
	jmp	??v_midloop

??horiz:
	mov	edi,ecx			; set greater
	mov	[accum],ecx		; set accumulator to 1/2 greater
	shr	[accum],1

	;*==================================================================
	;* at this point ...
	;* eax=xpos ; ebx=page line offset; ecx=counter; edx=lesser; edi=greater;
	;* esi=adder; accum=accumulator
	;* in a vertical loop the adder is conditional and the inc constant
	;*==================================================================
??horiz_loop:
	add	ebx,eax
	mov	eax,[color]

??h_midloop:
	mov	[ebx],al
	dec	ecx				; dec counter
	jl	??out				; end of line
	add	ebx,esi
	sub     [accum],edx			; sub the lesser
	jge	??h_midloop
	add	[accum],edi			; add greater for new accum
	add	ebx,[bpr]			; goto next line
	jmp	??h_midloop

	;*==================================================================
	;* Special case routine for horizontal line draws
	;*==================================================================
??hline:
	cmp	eax,ecx			; make eax < ecx
	jl	short ??hl_ac
	xchg	eax,ecx

??hl_ac:
	sub	ecx,eax			; get len
	inc	ecx

	push	edx
	push	eax
	mov	eax,[bpr]
	mul	ebx
	mov	ebx,eax
	mov	eax,[this_object]
	add	ebx,[(GraphicViewPort eax).GVPOffset]
	pop	eax
	pop	edx
	add	ebx,eax
	mov	edi,ebx
	cmp	ecx,15
	jg	??big_line
	mov	al,[byte color]
	rep	stosb			; write as many words as possible
	jmp	short ??out		; get outt


??big_line:
	mov	al,[byte color]
	mov	ah,al
	mov     ebx,eax
	shl	eax,16
	mov	ax,bx
	test	edi,3
	jz	??aligned
	mov	[edi],al
	inc	edi
	dec	ecx
	test	edi,3
	jz	??aligned
	mov	[edi],al
	inc	edi
	dec	ecx
	test	edi,3
	jz	??aligned
	mov	[edi],al
	inc	edi
	dec	ecx

??aligned:
	mov	ebx,ecx
	shr	ecx,2
	rep	stosd
	mov	ecx,ebx
	and	ecx,3
	rep	stosb
	jmp	??out


	;*==================================================================
	;* a special case routine for vertical line draws
	;*==================================================================
??vline:
	mov	ecx,edx			; get length of line to draw
	inc	ecx
	add	ebx,eax
	mov	eax,[color]

??vl_loop:
	mov	[ebx],al		; store bit
	add	ebx,[bpr]
	dec	ecx
	jnz	??vl_loop

??out:
	ret
	ENDP	Buffer_Draw_Line


*/















/*

;***************************************************************************
;* GVPC::FILL_RECT -- Fills a rectangular region of a graphic view port	   *
;*                                                                         *
;* INPUT:	WORD the left hand x pixel position of region		   *
;*		WORD the upper x pixel position of region		   *
;*		WORD the right hand x pixel position of region		   *
;*		WORD the lower x pixel position of region		   *
;*		UBYTE the color (optional) to clear the view port to	   *
;*                                                                         *
;* OUTPUT:      none                                                       *
;*                                                                         *
;* NOTE:	This function is optimized to handle viewport with no XAdd *
;*		value.  It also handles DWORD aligning the destination	   *
;*		when speed can be gained by doing it.			   *
;* HISTORY:                                                                *
;*   06/07/1994 PWG : Created.                                             *
;*=========================================================================*
*/ 

/*
;******************************************************************************
; Much testing was done to determine that only when there are 14 or more bytes
; being copied does it speed the time it takes to do copies in this algorithm.
; For this reason and because 1 and 2 byte copies crash, is the special case
; used.  SKB 4/21/94.  Tested on 486 66mhz.  Copied by PWG 6/7/04.
*/ 
#define OPTIMAL_BYTE_COPY	14


void __cdecl Buffer_Fill_Rect(void *thisptr, int sx, int sy, int dx, int dy, unsigned char color)
{
/*
	;*===================================================================
	;* define the arguements that our function takes.
	;*===================================================================
	ARG    	this_object:DWORD			; this is a member function
	ARG	x1_pixel:WORD
	ARG	y1_pixel:WORD
	ARG	x2_pixel:WORD
	ARG	y2_pixel:WORD
	ARG    	color:BYTE			; what color should we clear to
*/
	
	void *this_object = thisptr;
	int x1_pixel = sx;
	int y1_pixel = sy;
	int x2_pixel = dx;
	int y2_pixel = dy;
	
/*
	;*===================================================================
	; Define some locals so that we can handle things quickly
	;*===================================================================
	LOCAL	VPwidth:DWORD		; the width of the viewport
	LOCAL	VPheight:DWORD		; the height of the viewport
	LOCAL	VPxadd:DWORD		; the additional x offset of viewport
	LOCAL	VPbpr:DWORD		; the number of bytes per row of viewport
*/

	int VPwidth;
	int VPheight;
	int VPxadd;
	int VPbpr;

	int local_ebp;	                      // Can't use ebp
	(void)VPwidth; (void)VPheight; (void)VPxadd; (void)VPbpr; (void)local_ebp;

#ifndef _MSC_VER
	// TIM-160: fill rectangle (x1_pixel,y1_pixel)..(x2_pixel,y2_pixel) with color
	{
		GraphicViewPortClass *vp = (GraphicViewPortClass*)this_object;
		int stride = vp->Get_Width() + vp->Get_XAdd() + vp->Get_Pitch();
		unsigned char *buf = (unsigned char*)(uintptr_t)vp->Get_Offset();
		int w = vp->Get_Width(), h = vp->Get_Height();
		int r0 = y1_pixel < 0 ? 0 : y1_pixel;
		int r1 = y2_pixel > h ? h : y2_pixel;
		int c0 = x1_pixel < 0 ? 0 : x1_pixel;
		int c1 = x2_pixel > w ? w : x2_pixel;
		for (int r = r0; r < r1; r++)
			memset(buf + r * stride + c0, color, c1 > c0 ? c1 - c0 : 0);
	}
#else
	{ /* TIM-164: replaced */ }
#endif
}




/*
;***************************************************************************
;* VVPC::CLEAR -- Clears a virtual viewport instance                       *
;*                                                                         *
;* INPUT:	UBYTE the color (optional) to clear the view port to	   *
;*                                                                         *
;* OUTPUT:      none                                                       *
;*                                                                         *
;* NOTE:	This function is optimized to handle viewport with no XAdd *
;*		value.  It also handles DWORD aligning the destination	   *
;*		when speed can be gained by doing it.			   *
;* HISTORY:                                                                *
;*   06/07/1994 PWG : Created.                                             *
;*   08/23/1994 SKB : Clear the direction flag to always go forward.       *
;*=========================================================================*
*/
void	__cdecl Buffer_Clear(void *this_object, unsigned char color)
{
	unsigned int local_color = color;
	(void)local_color;
	// TIM-164: memset each row accounting for pitch
	GraphicViewPortClass *vp = (GraphicViewPortClass*)this_object;
	int w = vp->Get_Width(), h = vp->Get_Height();
	int stride = w + vp->Get_XAdd() + (int)vp->Get_Pitch();
	unsigned char *buf = (unsigned char*)(uintptr_t)vp->Get_Offset();
	for (int row = 0; row < h; row++)
		memset(buf + row * stride, color, (size_t)w);
}














BOOL __cdecl Linear_Blit_To_Linear(	void *this_object, void * dest, int x_pixel, int y_pixel, int dest_x0, int dest_y0, int pixel_width, int pixel_height, BOOL trans)
{
/*
	;*===================================================================
	;* define the arguements that our function takes.
	;*===================================================================
	ARG    	this_object :DWORD		; this is a member function
	ARG	dest        :DWORD		; what are we blitting to
	ARG	x_pixel     :DWORD		; x pixel position in source
	ARG	y_pixel     :DWORD		; y pixel position in source
	ARG	dest_x0     :dword
	ARG	dest_y0     :dword
	ARG	pixel_width :DWORD		; width of rectangle to blit
	ARG	pixel_height:DWORD		; height of rectangle to blit
	ARG	trans       :DWORD			; do we deal with transparents?

	;*===================================================================
	; Define some locals so that we can handle things quickly
	;*===================================================================
	LOCAL 	x1_pixel :dword
	LOCAL	y1_pixel :dword
	LOCAL	dest_x1 : dword
	LOCAL	dest_y1 : dword
	LOCAL	scr_ajust_width:DWORD
	LOCAL	dest_ajust_width:DWORD
        LOCAL	source_area :  dword
        LOCAL	dest_area :  dword
*/
	
	int	x1_pixel;
	int	y1_pixel;
	int	dest_x1;
	int	dest_y1;
	int	scr_adjust_width;
	int	dest_adjust_width;
	int	source_area;
	int	dest_area;

#ifndef _MSC_VER
	// TIM-160: C++ pixel-blit replacing the MASM body.
	// stride = Width + XAdd + Pitch (Pitch = surface_stride - buffer_width)
	GraphicViewPortClass *src_vp = (GraphicViewPortClass*)this_object;
	GraphicViewPortClass *dst_vp = (GraphicViewPortClass*)dest;

	int src_w = src_vp->Get_Width(), src_h = src_vp->Get_Height();
	int dst_w = dst_vp->Get_Width(), dst_h = dst_vp->Get_Height();
	int src_stride = src_w + src_vp->Get_XAdd() + src_vp->Get_Pitch();
	int dst_stride = dst_w + dst_vp->Get_XAdd() + dst_vp->Get_Pitch();
	unsigned char *src_buf = (unsigned char*)(uintptr_t)src_vp->Get_Offset();
	unsigned char *dst_buf = (unsigned char*)(uintptr_t)dst_vp->Get_Offset();

	// clip source rect against source bounds
	x1_pixel = x_pixel; y1_pixel = y_pixel;
	dest_x1  = dest_x0; dest_y1  = dest_y0;
	if (x1_pixel < 0) { dest_x1 -= x1_pixel; x1_pixel = 0; }
	if (y1_pixel < 0) { dest_y1 -= y1_pixel; y1_pixel = 0; }
	int w = pixel_width  - (x1_pixel - x_pixel);
	int h = pixel_height - (y1_pixel - y_pixel);
	if (x1_pixel + w > src_w) w = src_w - x1_pixel;
	if (y1_pixel + h > src_h) h = src_h - y1_pixel;
	// clip destination rect against dest bounds
	if (dest_x1 < 0) { x1_pixel -= dest_x1; w += dest_x1; dest_x1 = 0; }
	if (dest_y1 < 0) { y1_pixel -= dest_y1; h += dest_y1; dest_y1 = 0; }
	if (dest_x1 + w > dst_w) w = dst_w - dest_x1;
	if (dest_y1 + h > dst_h) h = dst_h - dest_y1;
	if (w <= 0 || h <= 0) return FALSE;

	unsigned char *src_row = src_buf + y1_pixel * src_stride + x1_pixel;
	unsigned char *dst_row = dst_buf + dest_y1  * dst_stride + dest_x1;
	if (!trans) {
		for (int row = 0; row < h; row++, src_row += src_stride, dst_row += dst_stride)
			memcpy(dst_row, src_row, w);
	} else {
		for (int row = 0; row < h; row++, src_row += src_stride, dst_row += dst_stride)
			for (int col = 0; col < w; col++)
				if (src_row[col]) dst_row[col] = src_row[col];
	}
	return TRUE;
#else
	{ /* TIM-164: replaced */ }
#endif
}












/*
;***************************************************************************
;* VVC::SCALE -- Scales a virtual viewport to another virtual viewport     *
;*                                                                         *
;* INPUT:                                                                  *
;*                                                                         *
;* OUTPUT:                                                                 *
;*                                                                         *
;* WARNINGS:                                                               *
;*                                                                         *
;* HISTORY:                                                                *
;*   06/16/1994 PWG : Created.                                             *
;*=========================================================================*
	PROC	Linear_Scale_To_Linear C NEAR
	USES	eax,ebx,ecx,edx,esi,edi
*/

// Ran out of registers so had to use ebp. ST - 12/19/2018 6:22PM
#pragma warning (push)
#pragma warning (disable : 4731)

BOOL __cdecl Linear_Scale_To_Linear(void *this_object, void *dest, int src_x, int src_y, int dst_x, int dst_y, int src_width, int src_height, int dst_width, int dst_height, BOOL trans, char *remap)
{
/*			  

	;*===================================================================
	;* Define the arguements that our function takes.
	;*===================================================================
	ARG	this_object:DWORD		; pointer to source view port
	ARG	dest:DWORD		; pointer to destination view port
	ARG	src_x:DWORD		; source x offset into view port
	ARG	src_y:DWORD		; source y offset into view port
	ARG	dst_x:DWORD		; dest x offset into view port
	ARG	dst_y:DWORD		; dest y offset into view port
	ARG	src_width:DWORD		; width of source rectangle
	ARG	src_height:DWORD	; height of source rectangle
	ARG	dst_width:DWORD		; width of dest rectangle
	ARG	dst_height:DWORD	; width of dest height
	ARG	trans:DWORD		; is this transparent?
	ARG	remap:DWORD		; pointer to table to remap source

	;*===================================================================
	;* Define local variables to hold the viewport characteristics
	;*===================================================================
	local	src_x0 : dword
	local	src_y0 : dword
	local	src_x1 : dword
	local	src_y1 : dword

	local	dst_x0 : dword
	local	dst_y0 : dword
	local	dst_x1 : dword
	local	dst_y1 : dword

	local	src_win_width : dword
	local	dst_win_width : dword
	local	dy_intr : dword
	local	dy_frac : dword
	local	dy_acc  : dword
	local	dx_frac : dword

	local	counter_x     : dword
	local	counter_y     : dword
	local	remap_counter :dword
	local	entry : dword
*/
	
	int src_x0;
	int src_y0;
	int src_x1;
	int src_y1;

	int dst_x0;
	int dst_y0;
	int dst_x1;
	int dst_y1;

	int src_win_width;
	int dst_win_width;
	int dy_intr;
	int dy_frac;
	int dy_acc;
	int dx_frac;

	int counter_x;
	int counter_y;
	int remap_counter;
	int entry;
	(void)dst_x0; (void)dst_y0; (void)dst_x1; (void)dst_y1;
	(void)src_win_width; (void)dst_win_width; (void)dy_intr; (void)dy_frac;
	(void)dy_acc; (void)dx_frac; (void)counter_x; (void)counter_y;
	(void)remap_counter; (void)entry;

#ifndef _MSC_VER
	// TIM-160: nearest-neighbor scale blit replacing the MASM body.
	if (dst_width <= 0 || dst_height <= 0 || src_width <= 0 || src_height <= 0) return FALSE;
	{
		GraphicViewPortClass *svp = (GraphicViewPortClass*)this_object;
		GraphicViewPortClass *dvp = (GraphicViewPortClass*)dest;
		int ss = svp->Get_Width() + svp->Get_XAdd() + svp->Get_Pitch();
		int ds = dvp->Get_Width() + dvp->Get_XAdd() + dvp->Get_Pitch();
		unsigned char *sb = (unsigned char*)(uintptr_t)svp->Get_Offset();
		unsigned char *db = (unsigned char*)(uintptr_t)dvp->Get_Offset();
		for (int iy = 0; iy < dst_height; iy++) {
			int sy_idx = (iy * src_height) / dst_height;
			unsigned char *srow = sb + (src_y + sy_idx) * ss + src_x;
			unsigned char *drow = db + (dst_y + iy)     * ds + dst_x;
			for (int ix = 0; ix < dst_width; ix++) {
				unsigned char pixel = srow[(ix * src_width) / dst_width];
				if (remap) pixel = (unsigned char)((unsigned char*)remap)[(unsigned char)pixel];
				if (!trans || pixel) drow[ix] = pixel;
			}
		}
	}
	return TRUE;
#else
	{ /* TIM-164: replaced */ }
#endif
}


#pragma warning (pop)




















unsigned int LastIconset = 0;
unsigned int StampPtr = 0;	//	DD	0	; Pointer to icon data.

unsigned int IsTrans = 0;	//		DD	0	; Pointer to transparent icon flag table.

unsigned int MapPtr = 0;	//		DD	0	; Pointer to icon map.
unsigned int IconWidth = 0;	//	DD	0	; Width of icon in pixels.
unsigned int IconHeight = 0;	//	DD	0	; Height of icon in pixels.
unsigned int IconSize = 0;		//	DD	0	; Number of bytes for each icon data.
unsigned int IconCount = 0;	//	DD	0	; Number of icons in the set.



#if (0)
LastIconset	DD	0	; Pointer to last iconset initialized.
StampPtr	DD	0	; Pointer to icon data.

IsTrans		DD	0	; Pointer to transparent icon flag table.

MapPtr		DD	0	; Pointer to icon map.
IconWidth	DD	0	; Width of icon in pixels.
IconHeight	DD	0	; Height of icon in pixels.
IconSize	DD	0	; Number of bytes for each icon data.
IconCount	DD	0	; Number of icons in the set.


GLOBAL C	Buffer_Draw_Stamp:near
GLOBAL C	Buffer_Draw_Stamp_Clip:near

; 256 color icon system.
#endif


/*
;***********************************************************
; INIT_STAMPS
;
; VOID cdecl Init_Stamps(VOID *icondata);
;
; This routine initializes the stamp data.
; Bounds Checking: NONE
;
;*
*/ 
extern "C" void __cdecl Init_Stamps(unsigned int icondata)
{
	// TIM-164: populate globals from IControl_Type binary layout (Win32 DW/DD offsets).
	// Offsets: Width@0(2), Height@2(2), Count@4(2), Size@12(4), Icons@16(4), TransFlag@28(4), Map@36(4)
	LastIconset = icondata;
	if (!icondata) return;
	unsigned char *b = (unsigned char*)(uintptr_t)icondata;
	short iw, ih, ic; int isz, iicons, itrans, imap;
	memcpy(&iw, b+0, 2); memcpy(&ih, b+2, 2); memcpy(&ic, b+4, 2);
	memcpy(&isz, b+12, 4); memcpy(&iicons, b+16, 4);
	memcpy(&itrans, b+28, 4); memcpy(&imap, b+36, 4);
	IconWidth  = (unsigned int)(unsigned short)iw;
	IconHeight = (unsigned int)(unsigned short)ih;
	IconCount  = (unsigned int)(unsigned short)ic;
	IconSize   = (unsigned int)isz;
	StampPtr   = icondata + (unsigned int)iicons;
	IsTrans    = icondata + (unsigned int)itrans;
	MapPtr     = icondata + (unsigned int)imap;
}


/*
;***********************************************************

;***********************************************************
; DRAW_STAMP
;
; VOID cdecl Buffer_Draw_Stamp(VOID *icondata, WORD icon, WORD x_pixel, WORD y_pixel, VOID *remap);
;
; This routine renders the icon at the given coordinate.
;
; The remap table is a 256 byte simple pixel translation table to use when
; drawing the icon.  Transparency check is performed AFTER the remap so it is possible to
; remap valid colors to be invisible (for special effect reasons).
; This routine is fastest when no remap table is passed in.
;*
*/

void __cdecl Buffer_Draw_Stamp(void const *this_object, void const *icondata, int icon, int x_pixel, int y_pixel, void const *remap)
{
	unsigned int	modulo = 0;
	unsigned int	iwidth = 0;
	unsigned char	doremap = 0;


/*
		PROC	Buffer_Draw_Stamp C near

		ARG	this_object:DWORD		; this is a member function
		ARG	icondata:DWORD		; Pointer to icondata.
		ARG	icon:DWORD		; Icon number to draw.
		ARG	x_pixel:DWORD		; X coordinate of icon.
		ARG	y_pixel:DWORD		; Y coordinate of icon.
		ARG	remap:DWORD 		; Remap table.

		LOCAL	modulo:DWORD		; Modulo to get to next row.
		LOCAL	iwidth:DWORD		; Icon width (here for speedy access).
		LOCAL	doremap:BYTE		; Should remapping occur?
*/
	// TIM-164: render icon from IControl_Type iconset, honouring per-icon transparency flag.
	(void)modulo; (void)iwidth; (void)doremap;
	if (!icondata) return;
	unsigned char *base = (unsigned char*)(uintptr_t)icondata;
	short iw, ih; int isz, iicons, itrans;
	memcpy(&iw, base+0, 2); memcpy(&ih, base+2, 2);
	memcpy(&isz, base+12, 4); memcpy(&iicons, base+16, 4); memcpy(&itrans, base+28, 4);
	int icon_w = (int)(unsigned short)iw, icon_h = (int)(unsigned short)ih;
	int icon_sz = (isz > 0) ? (int)(unsigned int)isz : icon_w * icon_h;
	GraphicViewPortClass *vp = (GraphicViewPortClass*)this_object;
	int stride = vp->Get_Width() + vp->Get_XAdd() + (int)vp->Get_Pitch();
	unsigned char *buf = (unsigned char*)(uintptr_t)vp->Get_Offset();
	int vw = vp->Get_Width(), vh = vp->Get_Height();
	unsigned char *icon_src = base + (unsigned int)iicons + icon * icon_sz;
	unsigned char tf = (itrans != 0) ? base[(unsigned int)itrans + icon] : 0;
	for (int row = 0; row < icon_h; row++) {
		int py = y_pixel + row;
		if (py < 0 || py >= vh) continue;
		for (int col = 0; col < icon_w; col++) {
			int px = x_pixel + col;
			if (px < 0 || px >= vw) continue;
			unsigned char pixel = icon_src[row * icon_w + col];
			if (remap) pixel = ((const unsigned char*)remap)[pixel];
			if (!tf || pixel) buf[py * stride + px] = pixel;
		}
	}
}




/*
;***********************************************************
; DRAW_STAMP_CLIP
;
; VOID cdecl MCGA_Draw_Stamp_Clip(VOID *icondata, WORD icon, WORD x_pixel, WORD y_pixel, VOID *remap, LONG min_x, LONG min_y, LONG max_x, LONG max_y);
;
; This routine renders the icon at the given coordinate.
;
; The remap table is a 256 byte simple pixel translation table to use when
; drawing the icon.  Transparency check is performed AFTER the remap so it is possible to
; remap valid colors to be invisible (for special effect reasons).
; This routine is fastest when no remap table is passed in.
;*
*/	
void __cdecl Buffer_Draw_Stamp_Clip(void const *this_object, void const *icondata, int icon, int x_pixel, int y_pixel, void const *remap, int min_x, int min_y, int max_x, int max_y)
{
	
	
	unsigned int	modulo = 0;
	unsigned int	iwidth = 0;
	unsigned int	skip = 0;
	unsigned char	doremap = 0;
	
		
/*		
	ARG	this_object:DWORD	; this is a member function
	ARG	icondata:DWORD		; Pointer to icondata.
	ARG	icon:DWORD		; Icon number to draw.
	ARG	x_pixel:DWORD		; X coordinate of icon.
	ARG	y_pixel:DWORD		; Y coordinate of icon.
	ARG	remap:DWORD 		; Remap table.
	ARG	min_x:DWORD		; Clipping rectangle boundary
	ARG	min_y:DWORD		; Clipping rectangle boundary
	ARG	max_x:DWORD		; Clipping rectangle boundary
	ARG	max_y:DWORD		; Clipping rectangle boundary

	LOCAL	modulo:DWORD		; Modulo to get to next row.
	LOCAL	iwidth:DWORD		; Icon width (here for speedy access).
	LOCAL	skip:DWORD		; amount to skip per row of icon data
	LOCAL	doremap:BYTE		; Should remapping occur?
*/
	// TIM-164: render icon clipped to [min_x,max_x) x [min_y,max_y) bounds.
	(void)modulo; (void)iwidth; (void)skip; (void)doremap;
	if (!icondata) return;
	unsigned char *base = (unsigned char*)(uintptr_t)icondata;
	short iw, ih; int isz, iicons, itrans;
	memcpy(&iw, base+0, 2); memcpy(&ih, base+2, 2);
	memcpy(&isz, base+12, 4); memcpy(&iicons, base+16, 4); memcpy(&itrans, base+28, 4);
	int icon_w = (int)(unsigned short)iw, icon_h = (int)(unsigned short)ih;
	int icon_sz = (isz > 0) ? (int)(unsigned int)isz : icon_w * icon_h;
	GraphicViewPortClass *vp = (GraphicViewPortClass*)this_object;
	int stride = vp->Get_Width() + vp->Get_XAdd() + (int)vp->Get_Pitch();
	unsigned char *buf = (unsigned char*)(uintptr_t)vp->Get_Offset();
	unsigned char *icon_src = base + (unsigned int)iicons + icon * icon_sz;
	unsigned char tf = (itrans != 0) ? base[(unsigned int)itrans + icon] : 0;
	for (int row = 0; row < icon_h; row++) {
		int py = y_pixel + row;
		if (py < min_y || py >= max_y) continue;
		for (int col = 0; col < icon_w; col++) {
			int px = x_pixel + col;
			if (px < min_x || px >= max_x) continue;
			unsigned char pixel = icon_src[row * icon_w + col];
			if (remap) pixel = ((const unsigned char*)remap)[pixel];
			if (!tf || pixel) buf[py * stride + px] = pixel;
		}
	}
}















	 VOID __cdecl Buffer_Draw_Line(void *thisptr, int sx, int sy, int dx, int dy, unsigned char color);
	 VOID __cdecl Buffer_Fill_Rect(void *thisptr, int sx, int sy, int dx, int dy, unsigned char color);
	 VOID __cdecl Buffer_Remap(void * thisptr, int sx, int sy, int width, int height, void *remap);
	 VOID __cdecl Buffer_Fill_Quad(void * thisptr, VOID *span_buff, int x0, int y0, int x1, int y1,
							 	int x2, int y2, int x3, int y3, int color);
	 void __cdecl Buffer_Draw_Stamp(void const *thisptr, void const *icondata, int icon, int x_pixel, int y_pixel, void const *remap);
	 void __cdecl Buffer_Draw_Stamp_Clip(void const *thisptr, void const *icondata, int icon, int x_pixel, int y_pixel, void const *remap, int ,int,int,int);
	 void * __cdecl Get_Font_Palette_Ptr ( void );


/*
;***************************************************************************
;**   C O N F I D E N T I A L --- W E S T W O O D   A S S O C I A T E S   **
;***************************************************************************
;*                                                                         *
;*                 Project Name : Westwood 32 bit Library                  *
;*                                                                         *
;*                    File Name : REMAP.ASM                                *
;*                                                                         *
;*                   Programmer : Phil W. Gorrow                           *
;*                                                                         *
;*                   Start Date : July 1, 1994                             *
;*                                                                         *
;*                  Last Update : July 1, 1994   [PWG]                     *
;*                                                                         *
;*-------------------------------------------------------------------------*
;* Functions:                                                              *
;* - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - *
*/


VOID __cdecl Buffer_Remap(void * this_object, int sx, int sy, int width, int height, void *remap)
{
/*
	PROC	Buffer_Remap C NEAR
	USES	eax,ebx,ecx,edx,esi,edi

	;*===================================================================
	;* Define the arguements that our function takes.
	;*===================================================================
	ARG	this_object:DWORD
	ARG	x0_pixel:DWORD
	ARG	y0_pixel:DWORD
	ARG	region_width:DWORD
	ARG	region_height:DWORD
	ARG	remap	:DWORD

	;*===================================================================
	; Define some locals so that we can handle things quickly
	;*===================================================================
	local	x1_pixel  : DWORD
	local	y1_pixel  : DWORD
	local	win_width : dword
	local	counter_x : dword
*/

	unsigned int x0_pixel = (unsigned int) sx;
	unsigned int y0_pixel = (unsigned int) sy;
	unsigned int region_width = (unsigned int) width;
	unsigned int region_height = (unsigned int) height;

	unsigned int x1_pixel = 0;
	unsigned int y1_pixel = 0;
	unsigned int win_width = 0;
	unsigned int counter_x = 0;
	(void)x1_pixel; (void)y1_pixel; (void)win_width; (void)counter_x;

	// TIM-164: apply 256-byte remap table to a rectangular region of the viewport.
	if (!remap) return;
	GraphicViewPortClass *vp = (GraphicViewPortClass*)this_object;
	int stride = vp->Get_Width() + vp->Get_XAdd() + (int)vp->Get_Pitch();
	unsigned char *buf = (unsigned char*)(uintptr_t)vp->Get_Offset();
	int vw = vp->Get_Width(), vh = vp->Get_Height();
	const unsigned char *rmap = (const unsigned char*)remap;
	for (unsigned int row = 0; row < region_height; row++) {
		int py = (int)(y0_pixel + row);
		if (py < 0 || py >= vh) continue;
		for (unsigned int col = 0; col < region_width; col++) {
			int px = (int)(x0_pixel + col);
			if (px < 0 || px >= vw) continue;
			buf[py * stride + px] = rmap[buf[py * stride + px]];
		}
	}
}















/*
; **************************************************************************
; **   C O N F I D E N T I A L --- W E S T W O O D   A S S O C I A T E S   *
; **************************************************************************
; *                                                                        *
; *                 Project Name : WSA Support routines			   *
; *                                                                        *
; *                    File Name : XORDELTA.ASM                            *
; *                                                                        *
; *                   Programmer : Scott K. Bowen			   *
; *                                                                        *
; *                  Last Update :May 23, 1994   [SKB]                     *
; *                                                                        *
; *------------------------------------------------------------------------*
; * Functions:                                                             *
;*   Apply_XOR_Delta -- Apply XOR delta data to a buffer.                  *
;*   Apply_XOR_Delta_To_Page_Or_Viewport -- Calls the copy or the XOR funti*
;*   Copy_Delta_buffer -- Copies XOR Delta Data to a section of a page.    *
;*   XOR_Delta_Buffer -- Xor's the data in a XOR Delta format to a page.   *
; * - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -*

IDEAL
P386
MODEL USE32 FLAT
*/


/*
LOCALS ??

; These are used to call Apply_XOR_Delta_To_Page_Or_Viewport() to setup flags parameter.  If
; These change, make sure and change their values in wsa.cpp.
DO_XOR		equ	0
DO_COPY		equ	1
TO_VIEWPORT	equ	0
TO_PAGE		equ	2

;
; Routines defined in this module
;
;
; UWORD Apply_XOR_Delta(UWORD page_seg, BYTE *delta_ptr);
; PUBLIC Apply_XOR_Delta_To_Page_Or_Viewport(UWORD page_seg, BYTE *delta_ptr, WORD width, WORD copy)
;
;	PROC	C XOR_Delta_Buffer
;	PROC	C Copy_Delta_Buffer
;

GLOBAL 	C Apply_XOR_Delta:NEAR
GLOBAL 	C Apply_XOR_Delta_To_Page_Or_Viewport:NEAR
*/

#define DO_XOR			0
#define DO_COPY		1
#define TO_VIEWPORT	0
#define TO_PAGE		2

void __cdecl XOR_Delta_Buffer(int nextrow);
void __cdecl Copy_Delta_Buffer(int nextrow);


/*
;***************************************************************************
;* APPLY_XOR_DELTA -- Apply XOR delta data to a linear buffer.             *
;*   AN example of this in C is at the botton of the file commented out.   *
;*                                                                         *
;* INPUT:  BYTE *target - destination buffer.                              *
;*         BYTE *delta - xor data to be delta uncompress.                  *
;*                                                                         *
;* OUTPUT:                                                                 *
;*                                                                         *
;* WARNINGS:                                                               *
;*                                                                         *
;* HISTORY:                                                                *
;*   05/23/1994 SKB : Created.                                             *
;*=========================================================================*
*/
unsigned int __cdecl Apply_XOR_Delta(char *target, char *delta)
{
/* 
PROC	Apply_XOR_Delta C near
	USES 	ebx,ecx,edx,edi,esi
	ARG	target:DWORD 		; pointers.
	ARG	delta:DWORD		; pointers.
*/
#ifndef _MSC_VER
	// TIM-160: Westwood XOR-delta decoder (16-bit commands, 8-bit data bytes).
	// +cmd: skip cmd target bytes unchanged; -cmd: XOR next |cmd| delta bytes into target.
	unsigned char *t = (unsigned char*)target;
	const unsigned char *d = (const unsigned char*)delta;
	while (true) {
		short cmd = (short)((unsigned short)d[0] | ((unsigned short)d[1] << 8));
		d += 2;
		if (cmd == 0) break;
		if (cmd > 0) { t += cmd; }
		else { int n = -cmd; while (n--) *t++ ^= *d++; }
	}
	return (unsigned int)(uintptr_t)t;
#else
	{ /* TIM-164: replaced */ }
#endif
}


/*
;----------------------------------------------------------------------------

;***************************************************************************
;* APPLY_XOR_DELTA_To_Page_Or_Viewport -- Calls the copy or the XOR funtion.           *
;*                                                                         *
;*									   *
;* 	This funtion is call to either xor or copy XOR_Delta data onto a   *
;*	page instead of a buffer.  The routine will set up the registers   *
;*	need for the actual routines that will perform the copy or xor.	   *
;*									   *
;*	The registers are setup as follows :				   *
;*		es:edi - destination segment:offset onto page.		   *
;*		ds:esi - source buffer segment:offset of delta data.	   *
;*		dx,cx,ax - are all zeroed out before entry.		   *
;*                                                                         *
;* INPUT:                                                                  *
;*                                                                         *
;* OUTPUT:                                                                 *
;*                                                                         *
;* WARNINGS:                                                               *
;*                                                                         *
;* HISTORY:                                                                *
;*   03/09/1992  SB : Created.                                             *
;*=========================================================================*
*/

void __cdecl Apply_XOR_Delta_To_Page_Or_Viewport(void *target, void *delta, int width, int nextrow, int copy)
{
	/*
	USES 	ebx,ecx,edx,edi,esi
	ARG	target:DWORD		; pointer to the destination buffer.
	ARG	delta:DWORD		; pointer to the delta buffer.
	ARG	width:DWORD		; width of animation.
	ARG	nextrow:DWORD		; Page/Buffer width - anim width.
	ARG	copy:DWORD		; should it be copied or xor'd?
	*/
#ifndef _MSC_VER
	// TIM-160: row-aware XOR/copy delta decoder for viewport-bounded animations.
	// 'nextrow' = buffer_stride - width (extra bytes to advance at each row wrap).
	unsigned char *t = (unsigned char*)target;
	const unsigned char *d = (const unsigned char*)delta;
	int col = 0;
	while (true) {
		short cmd = (short)((unsigned short)d[0] | ((unsigned short)d[1] << 8));
		d += 2;
		if (cmd == 0) break;
		if (cmd > 0) {
			// skip cmd pixels, advancing past row boundaries
			int remain = cmd;
			while (remain > 0) {
				int space = width - col;
				int adv = remain < space ? remain : space;
				t += adv; col += adv; remain -= adv;
				if (col >= width) { col = 0; t += nextrow; }
			}
		} else {
			int n = -cmd;
			while (n--) {
				if (copy == DO_XOR) *t++ ^= *d++;
				else                *t++ = *d++;
				if (++col >= width) { col = 0; t += nextrow; }
			}
		}
	}
#else
	{ /* TIM-164: replaced */ }
#endif
}


/*
;----------------------------------------------------------------------------


;***************************************************************************
;* XOR_DELTA_BUFFER -- Xor's the data in a XOR Delta format to a page.     *
;*	This will only work right if the page has the previous data on it. *
;*	This function should only be called by XOR_Delta_Buffer_To_Page_Or_Viewport.   *
;*      The registers must be setup as follows :                           *
;*                                                                         *
;* INPUT:                                                                  *
;*	es:edi - destination segment:offset onto page.		 	   *
;*	ds:esi - source buffer segment:offset of delta data.	 	   *
;*	edx,ecx,eax - are all zeroed out before entry.		 	   *
;*                                                                         *
;* OUTPUT:                                                                 *
;*                                                                         *
;* WARNINGS:                                                               *
;*                                                                         *
;* HISTORY:                                                                *
;*   03/09/1992  SB : Created.                                             *
;*=========================================================================*
*/
void __cdecl XOR_Delta_Buffer(int nextrow)
{
	// TIM-160: not called — logic inlined into Apply_XOR_Delta_To_Page_Or_Viewport
	(void)nextrow;
}


/*
;----------------------------------------------------------------------------


;***************************************************************************
;* COPY_DELTA_BUFFER -- Copies XOR Delta Data to a section of a page.      *
;*	This function should only be called by XOR_Delta_Buffer_To_Page_Or_Viewport.   *
;*      The registers must be setup as follows :                           *
;*                                                                         *
;* INPUT:                                                                  *
;*	es:edi - destination segment:offset onto page.		 	   *
;*	ds:esi - source buffer segment:offset of delta data.	 	   *
;*	dx,cx,ax - are all zeroed out before entry.		 	   *
;*                                                                         *
;* OUTPUT:                                                                 *
;*                                                                         *
;* WARNINGS:                                                               *
;*                                                                         *
;* HISTORY:                                                                *
;*   03/09/1992  SB : Created.                                             *
;*=========================================================================*
*/
void __cdecl Copy_Delta_Buffer(int nextrow)
{
	// TIM-160: not called — logic inlined into Apply_XOR_Delta_To_Page_Or_Viewport
	(void)nextrow;
}
/*
;----------------------------------------------------------------------------
*/






















/*
;***************************************************************************
;**   C O N F I D E N T I A L --- W E S T W O O D    S T U D I O S        **
;***************************************************************************
;*                                                                         *
;*                 Project Name : Westwood Library                         *
;*                                                                         *
;*                    File Name : FADING.ASM                               *
;*                                                                         *
;*                   Programmer : Joe L. Bostic                            *
;*                                                                         *
;*                   Start Date : August 20, 1993                          *
;*                                                                         *
;*                  Last Update : August 20, 1993   [JLB]                  *
;*                                                                         *
;*-------------------------------------------------------------------------*
;* Functions:                                                              *
;* - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - *

IDEAL
P386
MODEL USE32 FLAT

GLOBAL	C Build_Fading_Table	:NEAR

	CODESEG

;***********************************************************
; BUILD_FADING_TABLE
;
; void *Build_Fading_Table(void *palette, void *dest, long int color, long int frac);
;
; This routine will create the fading effect table used to coerce colors
; from toward a common value.  This table is used when Fading_Effect is
; active.
;
; Bounds Checking: None
;*
*/
void * __cdecl Build_Fading_Table(void const *palette, void const *dest, long int color, long int frac)
{
	/*
	PROC	Build_Fading_Table C near
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
	*/
	
	int matchvalue = 0;	//:DWORD	; Last recorded match value.
	unsigned char targetred = 0;		//BYTE		; Target gun red.
	unsigned char targetgreen = 0;	//BYTE		; Target gun green.
	unsigned char targetblue = 0;		//BYTE		; Target gun blue.
	unsigned char idealred = 0;		//BYTE	
	unsigned char idealgreen = 0;		//BYTE	
	unsigned char idealblue = 0;		//BYTE	
	unsigned char matchcolor = 0;		//:BYTE		; Tentative match color.

#ifndef _MSC_VER
	// TIM-160: blend each palette entry toward 'color' by frac/256,
	// find nearest match across the full 256-entry palette.
	{
		const unsigned char *pal = (const unsigned char*)palette;
		unsigned char *out = const_cast<unsigned char*>((const unsigned char*)dest);
		int tred = pal[color*3], tgrn = pal[color*3+1], tblu = pal[color*3+2];
		for (int i = 0; i < 256; i++) {
			int ired = pal[i*3]   + ((tred - pal[i*3])   * (int)frac >> 8);
			int igrn = pal[i*3+1] + ((tgrn - pal[i*3+1]) * (int)frac >> 8);
			int iblu = pal[i*3+2] + ((tblu - pal[i*3+2]) * (int)frac >> 8);
			int best = 0x7FFFFFFF; matchcolor = (unsigned char)i;
			for (int j = 0; j < 256; j++) {
				int dr = pal[j*3]-ired, dg = pal[j*3+1]-igrn, db = pal[j*3+2]-iblu;
				int d = dr*dr + dg*dg + db*db;
				if (d < best) { best = d; matchcolor = (unsigned char)j; if (!d) break; }
			}
			out[i] = matchcolor;
		}
		return (void*)dest;
	}
#else
	{ /* TIM-164: replaced */ }
#endif
}
























/*
;***************************************************************************
;**   C O N F I D E N T I A L --- W E S T W O O D   A S S O C I A T E S   **
;***************************************************************************
;*                                                                         *
;*                 Project Name : Westwood Library                         *
;*                                                                         *
;*                    File Name : PAL.ASM                                  *
;*                                                                         *
;*                   Programmer : Joe L. Bostic                            *
;*                                                                         *
;*                   Start Date : May 30, 1992                             *
;*                                                                         *
;*                  Last Update : April 27, 1994   [BR]                    *
;*                                                                         *
;*-------------------------------------------------------------------------*
;* Functions:                                                              *
;*   Set_Palette_Range -- Sets changed values in the palette.              *
;*   Bump_Color -- adjusts specified color in specified palette            *
;* - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - *
;********************** Model & Processor Directives ************************
IDEAL
P386
MODEL USE32 FLAT


;include "keyboard.inc"
FALSE = 0
TRUE  = 1

;****************************** Declarations ********************************
GLOBAL 		C Set_Palette_Range:NEAR
GLOBAL 		C Bump_Color:NEAR
GLOBAL  	C CurrentPalette:BYTE:768
GLOBAL		C PaletteTable:byte:1024


;********************************** Data ************************************
LOCALS ??

	DATASEG

CurrentPalette	DB	768 DUP(255)	; copy of current values of DAC regs
PaletteTable	DB	1024 DUP(0)

IFNDEF LIB_EXTERNS_RESOLVED
VertBlank	DW	0		; !!!! this should go away
ENDIF


;********************************** Code ************************************
	CODESEG
*/

extern "C" unsigned char CurrentPalette[768] = {255};	//	DB	768 DUP(255)	; copy of current values of DAC regs
extern "C" unsigned char PaletteTable[1024] = {0};		//	DB	1024 DUP(0)


/*
;***************************************************************************
;* SET_PALETTE_RANGE -- Sets a palette range to the new pal                *
;*                                                                         *
;* INPUT:                                                                  *
;*                                                                         *
;* OUTPUT:                                                                 *
;*                                                                         *
;* PROTO:                                                                  *
;*                                                                         *
;* WARNINGS:	This routine is optimized for changing a small number of   *
;*		colors in the palette.
;*                                                                         *
;* HISTORY:                                                                *
;*   03/07/1995 PWG : Created.                                             *
;*=========================================================================*
*/
void __cdecl Set_Palette_Range(void *palette)
{
	memcpy(CurrentPalette, palette, 768);
	Set_DD_Palette(palette);

	/*
	PROC	Set_Palette_Range C NEAR
	ARG	palette:DWORD

	GLOBAL	Set_DD_Palette_:near
	GLOBAL	Wait_Vert_Blank_:near
	
	pushad
	mov	esi,[palette]
	mov	ecx,768/4
	mov	edi,offset CurrentPalette
	cld
	rep	movsd
	;call	Wait_Vert_Blank_
	mov	eax,[palette]
	push	eax
	call	Set_DD_Palette_
	pop	eax
	popad
	ret
	*/
}


/*
;***************************************************************************
;* Bump_Color -- adjusts specified color in specified palette              *
;*                                                                         *
;* INPUT:                                                                  *
;*	VOID *palette	- palette to modify				   *
;*	WORD changable	- color # to change				   *
;*	WORD target	- color to bend toward				   *
;*                                                                         *
;* OUTPUT:                                                                 *
;*                                                                         *
;* WARNINGS:                                                               *
;*                                                                         *
;* HISTORY:                                                                *
;*   04/27/1994 BR : Converted to 32-bit.                                  *
;*=========================================================================*
; BOOL cdecl Bump_Color(VOID *palette, WORD changable, WORD target);
*/ 
BOOL __cdecl Bump_Color(void *pal, int color, int desired)
{
	/*		  
PROC Bump_Color C NEAR
	USES ebx,ecx,edi,esi
	ARG	pal:DWORD, color:WORD, desired:WORD
	LOCAL	changed:WORD		; Has palette changed?
	 */ 
	
	short short_color = (short) color;
	short short_desired = (short) desired;
	bool changed = false;

	// TIM-164: nudge each RGB component of short_color one step toward short_desired.
	unsigned char *palette = (unsigned char*)pal;
	unsigned char *c = palette + (int)short_color   * 3;
	unsigned char *d = palette + (int)short_desired * 3;
	for (int i = 0; i < 3; i++) {
		if      (c[i] < d[i]) { c[i]++; changed = true; }
		else if (c[i] > d[i]) { c[i]--; changed = true; }
	}
	return changed ? TRUE : FALSE;
}















/*
;***************************************************************************
;**     C O N F I D E N T I A L --- W E S T W O O D   S T U D I O S       **
;***************************************************************************
;*                                                                         *
;*                 Project Name : GraphicViewPortClass			   *
;*                                                                         *
;*                    File Name : PUTPIXEL.ASM                             *
;*                                                                         *
;*                   Programmer : Phil Gorrow				   *
;*                                                                         *
;*                   Start Date : June 7, 1994				   *
;*                                                                         *
;*                  Last Update : June 8, 1994   [PWG]                     *
;*                                                                         *
;*-------------------------------------------------------------------------*
;* Functions:                                                              *
;*   VVPC::Put_Pixel -- Puts a pixel on a virtual viewport                 *
;* - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - *

IDEAL
P386
MODEL USE32 FLAT

INCLUDE ".\drawbuff.inc"
INCLUDE ".\gbuffer.inc"


CODESEG
*/

/*
;***************************************************************************
;* VVPC::PUT_PIXEL -- Puts a pixel on a virtual viewport                   *
;*                                                                         *
;* INPUT:	WORD the x position for the pixel relative to the upper    *
;*			left corner of the viewport			   *
;*		WORD the y pos for the pixel relative to the upper left	   *
;*			corner of the viewport				   *
;*		UBYTE the color of the pixel to write			   *
;*                                                                         *
;* OUTPUT:      none                                                       *
;*                                                                         *
;* WARNING:	If pixel is to be placed outside of the viewport then	   *
;*		this routine will abort.				   *
;*									   *
;* HISTORY:                                                                *
;*   06/08/1994 PWG : Created.                                             *
;*=========================================================================*
	PROC	Buffer_Put_Pixel C near
	USES	eax,ebx,ecx,edx,edi
*/

void __cdecl Buffer_Put_Pixel(void * this_object, int x_pixel, int y_pixel, unsigned char color)
{
	/*
	ARG    	this_object:DWORD				; this is a member function
	ARG	x_pixel:DWORD				; x position of pixel to set
	ARG	y_pixel:DWORD				; y position of pixel to set
	ARG    	color:BYTE				; what color should we clear to
	*/
	// TIM-164: write a single pixel, with bounds check.
	GraphicViewPortClass *vp = (GraphicViewPortClass*)this_object;
	if (x_pixel < 0 || x_pixel >= vp->Get_Width()) return;
	if (y_pixel < 0 || y_pixel >= vp->Get_Height()) return;
	int stride = vp->Get_Width() + vp->Get_XAdd() + (int)vp->Get_Pitch();
	unsigned char *buf = (unsigned char*)(uintptr_t)vp->Get_Offset();
	buf[y_pixel * stride + x_pixel] = color;
}








/*
;***************************************************************************
;**   C O N F I D E N T I A L --- W E S T W O O D   A S S O C I A T E S   **
;***************************************************************************
;*                                                                         *
;*                 Project Name : Support Library                          *
;*                                                                         *
;*                    File Name : cliprect.asm                             *
;*                                                                         *
;*                   Programmer : Julio R Jerez                            *
;*                                                                         *
;*                   Start Date : Mar, 2 1995                              *
;*                                                                         *
;*                                                                         *
;*-------------------------------------------------------------------------*
;* Functions:                                                              *
;* int Clip_Rect ( int * x , int * y , int * dw , int * dh , 		   *
;*	       	   int width , int height ) ;          			   *
;* int Confine_Rect ( int * x , int * y , int * dw , int * dh , 	   *
;*	       	      int width , int height ) ;          		   *
;*									   *
;* - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - *


IDEAL
P386
MODEL USE32 FLAT

GLOBAL	 C Clip_Rect	:NEAR
GLOBAL	 C Confine_Rect	:NEAR

CODESEG

;***************************************************************************
;* Clip_Rect -- clip a given rectangle against a given window		   *
;*                                                                         *
;* INPUT:   &x , &y , &w , &h  -> Pointer to rectangle being clipped       *
;*          width , height     -> dimension of clipping window             *
;*                                                                         *
;* OUTPUT: a) Zero if the rectangle is totally contained by the 	   *
;*	      clipping window.						   *
;*	   b) A negative value if the rectangle is totally outside the     *
;*            the clipping window					   *
;*	   c) A positive value if the rectangle	was clipped against the	   *
;*	      clipping window, also the values pointed by x, y, w, h will  *
;*	      be modified to new clipped values	 			   *
;*									   *
;*   05/03/1995 JRJ : added comment                                        *
;*=========================================================================*
; int Clip_Rect (int* x, int* y, int* dw, int* dh, int width, int height);          			   *
*/

extern "C" int __cdecl Clip_Rect ( int * x , int * y , int * w , int * h , int width , int height )
{
/*
	PROC	Clip_Rect C near
	uses	ebx,ecx,edx,esi,edi
	arg	x:dword
	arg	y:dword
	arg	w:dword
	arg	h:dword
	arg	width:dword
	arg	height:dword
*/
	// TIM-164: clip (x,y,w,h) to (0,0,width,height).
	// Returns 0=inside, >0=clipped, <0=entirely outside.
	int clipped = 0;
	if (*x < 0)           { *w += *x; *x = 0; clipped = 1; }
	if (*y < 0)           { *h += *y; *y = 0; clipped = 1; }
	if (*x + *w > width)  { *w = width  - *x; clipped = 1; }
	if (*y + *h > height) { *h = height - *y; clipped = 1; }
	if (*w <= 0 || *h <= 0) return -1;
	return clipped;
	//ENDP	Clip_Rect
}

/*
;***************************************************************************
;* Confine_Rect -- clip a given rectangle against a given window	   *
;*                                                                         *
;* INPUT:   &x,&y,w,h    -> Pointer to rectangle being clipped       *
;*          width,height     -> dimension of clipping window             *
;*                                                                         *
;* OUTPUT: a) Zero if the rectangle is totally contained by the 	   *
;*	      clipping window.						   *
;*	   c) A positive value if the rectangle	was shifted in position    *
;*	      to fix inside the clipping window, also the values pointed   *
;*	      by x, y, will adjusted to a new values	 		   *
;*									   *
;*  NOTE:  this function make not attempt to verify if the rectangle is	   *
;*	   bigger than the clipping window and at the same time wrap around*
;*	   it. If that is the case the result is meaningless		   *
;*=========================================================================*
; int Confine_Rect (int* x, int* y, int dw, int dh, int width, int height);          			   *
*/

extern "C" int __cdecl Confine_Rect ( int * x , int * y , int w , int h , int width , int height )
{

/*
	PROC	Confine_Rect C near
	uses	ebx, esi,edi
	arg	x:dword
	arg	y:dword
	arg	w:dword
	arg	h:dword
	arg	width :dword
	arg	height:dword
*/
#ifndef _MSC_VER
	// TIM-159 pass-48A: C++ replacement for removed MASM body.
	// Clamps the rectangle (x,y,w,h) to fit within (0,0,width,height).
	// Returns 1 if any adjustment was made.
	int moved = 0;
	if (*x + w > width) { *x = width - w; moved = 1; }
	if (*x < 0)         { *x = 0;         moved = 1; }
	if (*y + h > height) { *y = height - h; moved = 1; }
	if (*y < 0)          { *y = 0;          moved = 1; }
	return moved;
#else
	{ /* TIM-164: replaced */ }
#endif
}









/*
; $Header: //depot/Projects/Mobius/QA/Project/Run/SOURCECODE/REDALERT/WIN32LIB/DrawMisc.cpp#139 $
;***************************************************************************
;**   C O N F I D E N T I A L --- W E S T W O O D   A S S O C I A T E S   **
;***************************************************************************
;*                                                                         *
;*                 Project Name : Library routine                          *
;*                                                                         *
;*                    File Name : UNCOMP.ASM                               *
;*                                                                         *
;*                   Programmer : Christopher Yates                        *
;*                                                                         *
;*                  Last Update : 20 August, 1990   [CY]                   *
;*                                                                         *
;*-------------------------------------------------------------------------*
;* Functions:                                                              *
;*                                                                         *
; ULONG LCW_Uncompress(BYTE *source, BYTE *dest, ULONG length);		   *
;*                                                                         *
;* - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - *

IDEAL
P386
MODEL USE32 FLAT

GLOBAL            C LCW_Uncompress          :NEAR

CODESEG

; ----------------------------------------------------------------
;
; Here are prototypes for the routines defined within this module:
;
; ULONG LCW_Uncompress(BYTE *source, BYTE *dest, ULONG length);
;
; ----------------------------------------------------------------
*/
#if (0)//ST 5/10/2019
extern "C" unsigned long __cdecl LCW_Uncompress(void *source, void *dest, unsigned long length_)
{
//PROC	LCW_Uncompress C near
//
//	USES ebx,ecx,edx,edi,esi
//
//	ARG	source:DWORD
//	ARG	dest:DWORD
//	ARG	length:DWORD
//;LOCALS
//	LOCAL a1stdest:DWORD
//	LOCAL maxlen:DWORD
//	LOCAL lastbyte:DWORD
//	LOCAL lastcom:DWORD
//	LOCAL lastcom1:DWORD
		
	unsigned long a1stdest;
	unsigned long  maxlen;
	unsigned long lastbyte;
	//unsigned long lastcom;
	//unsigned long lastcom1;

	__asm {


		mov	edi,[dest]
		mov	esi,[source]
		mov	edx,[length_]

	;
	;
	; uncompress data to the following codes in the format b = byte, w = word
	; n = byte code pulled from compressed data
	;   Bit field of n		command		description
	; n=0xxxyyyy,yyyyyyyy		short run	back y bytes and run x+3
	; n=10xxxxxx,n1,n2,...,nx+1	med length	copy the next x+1 bytes
	; n=11xxxxxx,w1			med run		run x+3 bytes from offset w1
	; n=11111111,w1,w2		long copy	copy w1 bytes from offset w2
	; n=11111110,w1,b1		long run	run byte b1 for w1 bytes
	; n=10000000			end		end of data reached
	;

		mov	[a1stdest],edi
		add	edx,edi
		mov	[lastbyte],edx
		cld			; make sure all lod and sto are forward
		mov	ebx,esi		; save the source offset

	loop_label:
		mov	eax,[lastbyte]
		sub	eax,edi		; get the remaining byte to uncomp
		jz	short out_label		; were done

		mov	[maxlen],eax	; save for string commands
		mov	esi,ebx		; mov in the source index

		xor	eax,eax
		mov	al,[esi]
		inc	esi
		test	al,al		; see if its a short run
		js	short notshort

		mov	ecx,eax		;put count nibble in cl

		mov	ah,al		; put rel offset high nibble in ah
		and	ah,0Fh		; only 4 bits count

		shr	cl,4		; get run -3
		add	ecx,3		; get actual run length

		cmp	ecx,[maxlen]	; is it too big to fit?
		jbe	short rsok		; if not, its ok

		mov	ecx,[maxlen]	; if so, max it out so it does not overrun

	rsok:
		mov	al,[esi]	; get rel offset low byte
		lea	ebx,[esi+1]	; save the source offset
		mov	esi,edi		; get the current dest
		sub	esi,eax		; get relative offset

		rep	movsb

		jmp	loop_label

	notshort:
		test	al,40h		; is it a length?
		jne	short notlength	; if not it could be med or long run

		cmp	al,80h		; is it the end?
		je	short out_label		; if so its over

		mov	cl,al		; put the byte in count register
		and	ecx,3Fh		; and off the extra bits

		cmp	ecx,[maxlen]	; is it too big to fit?
		jbe	short lenok		; if not, its ok

		mov	ecx,[maxlen]	; if so, max it out so it does not overrun

	lenok:
		rep movsb

		mov	ebx,esi		; save the source offset
		jmp	loop_label

	out_label:
	      	mov	eax,edi
		sub	eax,[a1stdest]
		jmp	label_exit

	notlength:
		mov	cl,al		; get the entire code
		and	ecx,3Fh		; and off all but the size -3
		add	ecx,3		; add 3 for byte count

		cmp	al,0FEh
		jne	short notrunlength

		xor	ecx,ecx
		mov	cx,[esi]

		xor	eax,eax
		mov	al,[esi+2]
		lea	ebx,[esi+3]	;save the source offset

		cmp	ecx,[maxlen]	; is it too big to fit?
		jbe	short runlenok		; if not, its ok

		mov	ecx,[maxlen]	; if so, max it out so it does not overrun

	runlenok:
		test	ecx,0ffe0h
		jnz	dont_use_stosb
		rep	stosb
		jmp	loop_label


	dont_use_stosb:
		mov	ah,al
		mov	edx,eax
		shl	eax,16
		or	eax,edx

		test	edi,3
		jz	aligned

		mov	[edi],eax
		mov	edx,edi
		and	edi,0fffffffch
		lea	edi,[edi+4]
		and	edx,3
		dec	dl
		xor	dl,3
		sub	ecx,edx

	aligned:
		mov	edx,ecx
		shr	ecx,2
		rep	stosd

		and	edx,3
		jz	loop_label
		mov	ecx,edx
		rep	stosb
		jmp	loop_label






	notrunlength:
		cmp	al,0FFh		; is it a long run?
		jne	short notlong	; if not use the code as the size

		xor     ecx,ecx
		xor	eax,eax
		mov	cx,[esi]	; if so, get the size
		lea	esi,[esi+2]

	notlong:
		mov	ax,[esi]	;get the real index
		add	eax,[a1stdest]	;add in the 1st index
		lea	ebx,[esi+2]	;save the source offset
		cmp	ecx,[maxlen]	;compare for overrun
		mov	esi,eax		;use eax as new source
		jbe	short runok	; if not, its ok

		mov	ecx,[maxlen]	; if so, max it out so it does not overrun

	runok:
		test	ecx,0ffe0h
		jnz	dont_use_movsb
		rep	movsb
		jmp	loop_label




	dont_use_movsb:
		lea	edx,[edi+0fffffffch]
		cmp	esi,edx
		ja	use_movsb

		test	edi,3
		jz	aligned2

		mov	eax,[esi]
		mov	[edi],eax
		mov	edx,edi
		and	edi,0fffffffch
		lea	edi,[edi+4]
		and	edx,3
		dec	dl
		xor	dl,3
		sub	ecx,edx
		add	esi,edx

	aligned2:
		mov	edx,ecx
		shr	ecx,2
		and	edx,3
		rep	movsd
		mov	ecx,edx
	use_movsb:
		rep	movsb
		jmp	loop_label




	label_exit:
		mov	eax,edi
		mov	ebx,[dest]
		sub	eax,ebx

		//ret

	}
}
#endif













/*
;***************************************************************************
;**   C O N F I D E N T I A L --- W E S T W O O D   A S S O C I A T E S   **
;***************************************************************************
;*                                                                         *
;*                 Project Name : Westwood 32 bit Library                  *
;*                                                                         *
;*                    File Name : TOPAGE.ASM                               *
;*                                                                         *
;*                   Programmer : Phil W. Gorrow                           *
;*                                                                         *
;*                   Start Date : June 8, 1994                             *
;*                                                                         *
;*                  Last Update : June 15, 1994   [PWG]                    *
;*                                                                         *
;*-------------------------------------------------------------------------*
;* Functions:                                                              *
;*   Buffer_To_Page -- Copies a linear buffer to a virtual viewport	   *
;* - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - *

IDEAL
P386
MODEL USE32 FLAT

TRANSP	equ  0


INCLUDE ".\drawbuff.inc"
INCLUDE ".\gbuffer.inc"

CODESEG

;***************************************************************************
;* VVC::TOPAGE -- Copies a linear buffer to a virtual viewport		   *
;*                                                                         *
;* INPUT:	WORD	x_pixel		- x pixel on viewport to copy from *
;*		WORD	y_pixel 	- y pixel on viewport to copy from *
;*		WORD	pixel_width	- the width of copy region	   *
;*		WORD	pixel_height	- the height of copy region	   *
;*		BYTE *	src		- buffer to copy from		   *
;*		VVPC *  dest		- virtual viewport to copy to	   *
;*                                                                         *
;* OUTPUT:      none                                                       *
;*                                                                         *
;* WARNINGS:    Coordinates and dimensions will be adjusted if they exceed *
;*	        the boundaries.  In the event that no adjustment is 	   *
;*	        possible this routine will abort.  If the size of the 	   *
;*		region to copy exceeds the size passed in for the buffer   *
;*		the routine will automatically abort.			   *
;*									   *
;* HISTORY:                                                                *
;*   06/15/1994 PWG : Created.                                             *
;*=========================================================================*
 */ 

extern "C" long __cdecl Buffer_To_Page(int x_pixel, int y_pixel, int pixel_width, int pixel_height, void *src, void *dest)
{

/*
	PROC	Buffer_To_Page C near
	USES	eax,ebx,ecx,edx,esi,edi

	;*===================================================================
	;* define the arguements that our function takes.
	;*===================================================================
	ARG	x_pixel     :DWORD		; x pixel position in source
	ARG	y_pixel     :DWORD		; y pixel position in source
	ARG	pixel_width :DWORD		; width of rectangle to blit
	ARG	pixel_height:DWORD		; height of rectangle to blit
	ARG    	src         :DWORD		; this is a member function
	ARG	dest        :DWORD		; what are we blitting to

;	ARG	trans       :DWORD			; do we deal with transparents?

	;*===================================================================
	; Define some locals so that we can handle things quickly
	;*===================================================================
	LOCAL 	x1_pixel :dword
	LOCAL	y1_pixel :dword
	local	scr_x 	: dword
	local	scr_y 	: dword
	LOCAL	dest_ajust_width:DWORD
	LOCAL	scr_ajust_width:DWORD
	LOCAL	dest_area   :  dword
*/

	unsigned long x1_pixel;
	unsigned long y1_pixel;
	unsigned long scr_x;
	unsigned long scr_y;
	unsigned long dest_ajust_width;
	unsigned long scr_ajust_width;
	//unsigned long dest_area;
	(void)x1_pixel; (void)y1_pixel; (void)scr_x; (void)scr_y;
	(void)dest_ajust_width; (void)scr_ajust_width;

	// TIM-164: copy flat buffer src (pixel_width x pixel_height) into viewport dest at (x_pixel,y_pixel).
	GraphicViewPortClass *dvp = (GraphicViewPortClass*)dest;
	int dstride = dvp->Get_Width() + dvp->Get_XAdd() + (int)dvp->Get_Pitch();
	unsigned char *dbuf = (unsigned char*)(uintptr_t)dvp->Get_Offset();
	int dw = dvp->Get_Width(), dh = dvp->Get_Height();
	unsigned char *sbuf = (unsigned char*)src;
	int sx0 = 0, sy0 = 0, cx = x_pixel, cy = y_pixel;
	int w = pixel_width, h = pixel_height;
	if (cx < 0)      { sx0 = -cx; w  += cx; cx = 0; }
	if (cy < 0)      { sy0 = -cy; h  += cy; cy = 0; }
	if (cx + w > dw) { w = dw - cx; }
	if (cy + h > dh) { h = dh - cy; }
	if (w <= 0 || h <= 0) return 0;
	for (int row = 0; row < h; row++)
		memcpy(dbuf + (cy + row) * dstride + cx,
		       sbuf + (sy0 + row) * pixel_width + sx0, (size_t)w);
	return 0;
}

			//ENDP	Buffer_To_Page
		//END









/*

;***************************************************************************
;* VVPC::GET_PIXEL -- Gets a pixel from the current view port		   *
;*                                                                         *
;* INPUT:	WORD the x pixel on the screen.				   *
;*		WORD the y pixel on the screen.				   *
;*                                                                         *
;* OUTPUT:      UBYTE the pixel at the specified location		   *
;*                                                                         *
;* WARNING:	If pixel is to be placed outside of the viewport then	   *
;*		this routine will abort.				   *
;*                                                                         *
;* HISTORY:                                                                *
;*   06/07/1994 PWG : Created.                                             *
;*=========================================================================*
	PROC	Buffer_Get_Pixel C near
	USES	ebx,ecx,edx,edi

	ARG    	this_object:DWORD				; this is a member function
	ARG	x_pixel:DWORD				; x position of pixel to set
	ARG	y_pixel:DWORD				; y position of pixel to set
*/

extern "C" int __cdecl Buffer_Get_Pixel(void * this_object, int x_pixel, int y_pixel)
{
	// TIM-164: read a single pixel with bounds check.
	GraphicViewPortClass *vp = (GraphicViewPortClass*)this_object;
	if (x_pixel < 0 || x_pixel >= vp->Get_Width()) return 0;
	if (y_pixel < 0 || y_pixel >= vp->Get_Height()) return 0;
	int stride = vp->Get_Width() + vp->Get_XAdd() + (int)vp->Get_Pitch();
	unsigned char *buf = (unsigned char*)(uintptr_t)vp->Get_Offset();
	return buf[y_pixel * stride + x_pixel];
}


