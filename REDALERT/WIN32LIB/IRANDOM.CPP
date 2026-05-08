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
 *                 Project Name : LIBRARY                                  *
 *                                                                         *
 *                    File Name : IRANDOM.C                                *
 *                                                                         *
 *                   Programmer : Barry W. Green                           *
 *                                                                         *
 *                  Last Update : 10 Feb, 1995     [BWG]                   *
 *                                                                         *
 *-------------------------------------------------------------------------*
 * Functions:                                                              *
 * - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - */

#include <stdlib.h>
#include <time.h>
#include "misc.h"



extern "C" unsigned long RandNumb = 0x12349876;



/* IRANDOM ----------------------------------------------------------

   IRandom returns a random value between min and max inclusive.

   INPUTS:	int min and int max

   RETURNS:	int random number
*/

int IRandom(int minval, int maxval)
{
	int num,mask;

	// Keep minval and maxval straight.
	if (minval > maxval) {
		minval ^= maxval;
		maxval ^= minval;
		minval ^= maxval;
	}

	mask = Get_Random_Mask(maxval - minval);

	while( (num = (rand() & mask) + minval) > maxval ) ;
	return(num);
}



unsigned char Random(void)
{
	// TIM-164: portable C++ port of the 4-byte LFSR in IRANDOM.ASM.
	// Operates on the low 4 bytes of RandNumb (stored little-endian).
	unsigned char *p = (unsigned char *)&RandNumb;
	unsigned int cf;
	unsigned int al = p[0];
	// shr al,1; shr al,1 — capture carry after second shift
	cf = al & 1; al >>= 1;
	cf = al & 1; al >>= 1;
	// rcl p[2],1 then rcl p[1],1 — shift the upper two bytes left through carry
	unsigned int t;
	t = ((unsigned int)p[2] << 1) | cf; cf = t >> 8; p[2] = (unsigned char)t;
	t = ((unsigned int)p[1] << 1) | cf; cf = t >> 8; p[1] = (unsigned char)t;
	// cmc — complement carry
	cf ^= 1u;
	// sbb al, p[0] — subtract with borrow
	t = (unsigned int)al - (unsigned int)p[0] - cf;
	cf = (t > 0xFFu) ? 1u : 0u;
	al = t & 0xFF;
	// shr al,1 — carry captures LSB for rcr
	cf = al & 1;
	// rcr p[0],1 — rotate byte 0 right through carry
	p[0] = (unsigned char)(((unsigned int)p[0] >> 1) | (cf << 7));
	return p[0] ^ p[1];
}



int Get_Random_Mask(int maxval)
{
	// TIM-164: portable C++ port of the BSR-based mask builder in IRANDOM.ASM.
	if (maxval == 0) return 1;
	unsigned int v = (unsigned int)maxval;
	int bit = 0;
	unsigned int tmp = v;
	while (tmp >>= 1) bit++;
	return (1 << (bit + 1)) - 1;
}











#if (0)

RandNumb	DD	12349876H

;
; UBYTE Random(VOID);
; int Get_Random_Mask(int maxval);
;
; ----------------------------------------------------------------

;-----------------------------------------------------------------
; RANDOM
;
; UBYTE Random(VOID);
;
;*

	PROC	Random C near
	USES	esi

	lea	esi, [RandNumb]		; get offset in segment of RandNumb
	xor	eax,eax
	mov	al,[esi]
	shr	al,1			; shift right 1 bit (bit0 in carry)
	shr	al,1
	rcl	[BYTE PTR esi+2],1	; rcl byte 3 of RandNumb
	rcl	[BYTE PTR esi+1],1 	; rcl byte 2 of RandNumb
	cmc				; complement carry
	sbb	al,[esi]		; sbb byte 1 of RandNumb
	shr	al,1			; sets carry
	rcr	[BYTE PTR esi],1 	; rcr byte 1 of RandNumb
	mov	al,[esi]		; reload byte 1 of RandNumb
	xor	al,[esi+1]		; xor with byte 2 of RandNumb

	ret

	ENDP	Random


;-----------------------------------------------------------------
; GET_RANDOM_MASK - returns an AND value that is large enough that it
; encloses the 'maxval' parameter.
;
; int Get_Random_Mask(int maxval);
;
;*

	PROC	Get_Random_Mask C near
	USES	ecx
	ARG	maxval:DWORD

; This function takes as a parameter a maximum value, for example, 61.  It
; then tries to create an AND mask that is big enough to enclose that number.
; For our example case, that AND mask would be 0x3F.  It does this by scanning
; for the highest bit in the number, then making an all-1's mask from that
; bit position down to bit 0.
	bsr	ecx,[maxval]		; put bit position of highest bit in ecx
	mov	eax,1			; set one bit on in eax
	jz	??invalid		; if BSR shows maxval==0, return eax=1
	inc	ecx			; get one bit higher than count showed
	shl	eax,cl			; move our EAX bit into position
	dec	eax			; dec it to create the mask.
??invalid:
	ret
	ENDP	Get_Random_Mask
;----------------------------------------------------------------------------

	END
#endif