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

/* $Header:   F:\projects\c&c\vcs\code\mixfile.h_v   2.18   16 Oct 1995 16:47:22   JOE_BOSTIC  $ */
/***********************************************************************************************
 ***              C O N F I D E N T I A L  ---  W E S T W O O D  S T U D I O S               *** 
 ***********************************************************************************************
 *                                                                                             *
 *                 Project Name : Command & Conquer                                            *
 *                                                                                             *
 *                    File Name : MIXFILE.H                                                    *
 *                                                                                             *
 *                   Programmer : Joe L. Bostic                                                *
 *                                                                                             *
 *                   Start Date : October 18, 1994                                             *
 *                                                                                             *
 *                  Last Update : October 18, 1994   [JLB]                                     *
 *                                                                                             *
 *---------------------------------------------------------------------------------------------*
 * Functions:                                                                                  *
 * - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - */

#ifndef MIXFILE_H
#define MIXFILE_H

#include	<wwlib32.h>
#include	"link.h"
#ifndef _MSC_VER
#include <stdint.h>
#endif

class MixFileClass : public LinkClass 
{
	public:
		char const *Filename;			// Filename of mixfile.

		MixFileClass(char const *filename);
		~MixFileClass(void);

		static bool Free(char const *filename);
		static void Free_All(void);
		void Free(void);
		bool Cache(void);
		static bool Cache(char const *filename);
		static bool Offset(char const *filename, void ** realptr = 0, MixFileClass ** mixfile = 0, long * offset = 0, long * size = 0);
		static void const * Retrieve(char const *filename);

		/* TIM-343: on-disk layout uses int32 fields (LP64 `long` = 8 bytes
		 * on Linux, but MIX files are 32-bit Win32 format).  Use explicit
		 * int32_t + packed to match the binary layout exactly. */
#ifndef _MSC_VER
		struct SubBlock {
			int32_t CRC;
			int32_t Offset;
			int32_t Size;

			int operator < (SubBlock & two) const {return (CRC < two.CRC);};
			int operator > (SubBlock & two) const {return (CRC > two.CRC);};
			int operator == (SubBlock & two) const {return (CRC == two.CRC);};
		} __attribute__((packed));
#else
		struct SubBlock {
			long CRC;				// CRC code for embedded file.
			long Offset;			// Offset from start of data section.
			long Size;				// Size of data subfile.

			int operator < (SubBlock & two) const {return (CRC < two.CRC);};
			int operator > (SubBlock & two) const {return (CRC > two.CRC);};
			int operator == (SubBlock & two) const {return (CRC == two.CRC);};
		};
#endif

	private:
		static MixFileClass * Finder(char const *filename);
		long Offset(long crc, long *size = 0);

#ifndef _MSC_VER
		typedef struct {
			int16_t	count;
			int32_t	size;
		} __attribute__((packed)) FileHeader;
#else
		typedef struct {
			short	count;
			long	size;
		} FileHeader;
#endif

		int Count;							// Number of sub-blocks.
		int32_t DataSize;				// Size of raw data (int32 — MIX is 32-bit format).
		SubBlock * Buffer;				// Array of sub blocks (could be in EMS).
		void *Data;							// Pointer to raw data.

		static MixFileClass * First;
};

#endif
