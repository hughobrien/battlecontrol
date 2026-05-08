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

/* $Header: /CounterStrike/MIXFILE.CPP 2     3/13/97 2:06p Steve_tall $ */
/***********************************************************************************************
 ***              C O N F I D E N T I A L  ---  W E S T W O O D  S T U D I O S               ***
 ***********************************************************************************************
 *                                                                                             *
 *                 Project Name : Command & Conquer                                            *
 *                                                                                             *
 *                    File Name : MIXFILE.CPP                                                  *
 *                                                                                             *
 *                   Programmer : Joe L. Bostic                                                *
 *                                                                                             *
 *                   Start Date : August 8, 1994                                               *
 *                                                                                             *
 *                  Last Update : July 12, 1996 [JLB]                                          *
 *                                                                                             *
 *                                                                                             *
 *                  Modified by Vic Grippi for WwXlat Tool 10/14/96                            *
 *                                                                                             *
 *---------------------------------------------------------------------------------------------*
 * Functions:                                                                                  *
 *   MixFileClass::Cache -- Caches the named mixfile into RAM.                                 *
 *   MixFileClass::Cache -- Loads this particular mixfile's data into RAM.                     *
 *   MixFileClass::Finder -- Finds the mixfile object that matches the name specified.         *
 *   MixFileClass::Free -- Uncaches a cached mixfile.                                          *
 *   MixFileClass::MixFileClass -- Constructor for mixfile object.                             *
 *   MixFileClass::Offset -- Searches in mixfile for matching file and returns offset if found.*
 *   MixFileClass::Retrieve -- Retrieves a pointer to the specified data file.                 *
 *   MixFileClass::~MixFileClass -- Destructor for the mixfile object.                         *
 * - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - */


#include	"buff.h"
#include	"function.h"
#ifndef _MSC_VER
#include <stdio.h>
#endif
#include	<direct.h>
#include	<fcntl.h>
#include	<io.h>
#include	<dos.h>
#include	<errno.h>
#include	<share.h>
#include	"mixfile.h"

#include	"cdfile.h"
extern MFCD temp;

//template<class T> int Compare(T const *obj1, T const *obj2) {
//	if (*obj1 < *obj2) return(-1);
//	if (*obj1 > *obj2) return(1);
//	return(0);
//};


/*
**	This is the pointer to the first mixfile in the list of mixfiles registered
**	with the mixfile system.
*/
template<class T>
List<MixFileClass<T> > MixFileClass<T>::List;

template class MixFileClass<CCFileClass>;

/***********************************************************************************************
 * MixFileClass::Free -- Uncaches a cached mixfile.                                            *
 *                                                                                             *
 *    Use this routine to uncache a mixfile that has been cached.                              *
 *                                                                                             *
 * INPUT:   filename -- Pointer to the filename of the mixfile that is to be uncached.         *
 *                                                                                             *
 * OUTPUT:  bool; Was the mixfile found and freed?                                             *
 *                                                                                             *
 * WARNINGS:   none                                                                            *
 *                                                                                             *
 * HISTORY:                                                                                    *
 *   01/23/1995 JLB : Created.                                                                 *
 *=============================================================================================*/
template<class T>
bool MixFileClass<T>::Free(char const * filename)
{
	MixFileClass * ptr = Finder(filename);

	if (ptr) {
		ptr->Free();
		return(true);
	}
	return(false);
}


/***********************************************************************************************
 * MixFileClass::~MixFileClass -- Destructor for the mixfile object.                           *
 *                                                                                             *
 *    This destructor will free all memory allocated by this mixfile and will remove it from   *
 *    the system. A mixfile removed in this fashion must be created anew in order to be        *
 *    subsequent used.                                                                         *
 *                                                                                             *
 * INPUT:   none                                                                               *
 *                                                                                             *
 * OUTPUT:  none                                                                               *
 *                                                                                             *
 * WARNINGS:   none                                                                            *
 *                                                                                             *
 * HISTORY:                                                                                    *
 *   08/08/1994 JLB : Created.                                                                 *
 *   01/06/1995 JLB : Puts mixfile header table into EMS.                                      *
 *=============================================================================================*/
template<class T>
MixFileClass<T>::~MixFileClass(void)
{
	/*
	**	Deallocate any allocated memory.
	*/
	if (Filename) {
		free((char *)Filename);
	}
	if (Data != NULL && IsAllocated) {
		delete [] Data;
		IsAllocated = false;
	}
	Data = NULL;

	if (HeaderBuffer != NULL) {
		delete [] HeaderBuffer;
		HeaderBuffer = NULL;
	}

	/*
	**	Unlink this mixfile object from the chain.
	*/
	this->Unlink();
}


/***********************************************************************************************
 * MixFileClass::MixFileClass -- Constructor for mixfile object.                               *
 *                                                                                             *
 *    This is the constructor for the mixfile object. It takes a filename and a memory         *
 *    handler object and registers the mixfile object with the system. The index block is      *
 *    allocated and loaded from disk by this routine.                                          *
 *                                                                                             *
 * INPUT:   filename -- Pointer to the filename of the mixfile object.                         *
 *                                                                                             *
 * OUTPUT:  none                                                                               *
 *                                                                                             *
 * WARNINGS:   none                                                                            *
 *                                                                                             *
 * HISTORY:                                                                                    *
 *   08/08/1994 JLB : Created.                                                                 *
 *   07/12/1996 JLB : Handles compressed file header.                                          *
 *=============================================================================================*/
template<class T>
MixFileClass<T>::MixFileClass(char const * filename, PKey const * key) :
	IsDigest(false),
	IsEncrypted(false),
	IsAllocated(false),
	Filename(0),
	Count(0),
	DataSize(0),
	DataStart(0),
	HeaderBuffer(0),
	Data(0)
{
	if (filename == NULL) return;	// ST - 5/9/2019

	/*
	**	Check to see if the file is available. If it isn't, then
	**	no further processing is needed or possible.
	*/
#ifndef _MSC_VER
	fprintf(stderr, "[MIX] ctor-A: %s before Force_CD_Available(%d)\n", filename, RequiredCD); fflush(stderr);
#endif
	if (!Force_CD_Available(RequiredCD)) {
		Prog_End("MixFileClass Force_CD_Available failed", true);
		if (!RunningAsDLL) {	//PG
			Emergency_Exit(EXIT_FAILURE);
		}
	}
#ifndef _MSC_VER
	fprintf(stderr, "[MIX] ctor-B: %s after Force_CD_Available, before T file\n", filename); fflush(stderr);
#endif

	T file(filename);		// Working file object.
#ifndef _MSC_VER
	fprintf(stderr, "[MIX] ctor: %s\n", filename); fflush(stderr);
	{ const char *_fn = file.File_Name();
	  fprintf(stderr, "[MIX] ctor: %s File_Name=%p\n", filename, _fn); fflush(stderr);
	}
#endif
	Filename = strdup(file.File_Name());
#ifndef _MSC_VER
	fprintf(stderr, "[MIX] ctor: %s Filename=%p\n", filename, Filename); fflush(stderr);
#endif
#ifndef _MSC_VER
	fprintf(stderr, "[MIX] ctor: %s B Filename='%s'\n", filename, Filename ? Filename : "(null)"); fflush(stderr);
#endif
	FileStraw fstraw(file);
#ifndef _MSC_VER
	fprintf(stderr, "[MIX] ctor: %s C fstraw done\n", filename); fflush(stderr);
#endif
	PKStraw pstraw(PKStraw::DECRYPT, CryptRandom);
#ifndef _MSC_VER
	fprintf(stderr, "[MIX] ctor: %s D pstraw done\n", filename); fflush(stderr);
#endif
	Straw * straw = &fstraw;

	if (!file.Is_Available()) {
#ifndef _MSC_VER
		fprintf(stderr, "[MIX] ctor: %s NOT available\n", filename); fflush(stderr);
#endif
		return;
	}
#ifndef _MSC_VER
	fprintf(stderr, "[MIX] ctor: %s available, reading header\n", filename); fflush(stderr);
	fprintf(stderr, "[MIX] ctor: %s before straw->Get: file.Is_Open=%d file.Handle=%p\n",
		filename, (int)file.Is_Open(), (void*)file.Get_File_Handle()); fflush(stderr);
#endif

	/*
	**	Stuctures used to hold the various file headers.
	*/
	FileHeader fileheader;
	struct {
		short First;		// Always zero for extended mixfile format.
		short Second;		// Bitfield of extensions to this mixfile.
	} alternate;

	/*
	**	Fetch the first bit of the file. From this bit, it is possible to detect
	**	whether this is an extended mixfile format or the plain format. An
	**	extended format may have extra options or data layout.
	*/
	int got = straw->Get(&alternate, sizeof(alternate));
#ifndef _MSC_VER
	fprintf(stderr, "[MIX] ctor: %s got=%d alt.First=%d alt.Second=0x%04x\n",
		filename, got, (int)alternate.First, (unsigned)alternate.Second); fflush(stderr);
#endif

	/*
	**	Detect if this is an extended mixfile. If so, then see if it is encrypted
	**	and/or has a message digest attached. Otherwise, just retrieve the
	**	plain mixfile header.
	*/
	if (alternate.First == 0) {
		IsDigest = ((alternate.Second & 0x01) != 0);
		IsEncrypted = ((alternate.Second & 0x02) != 0);
#ifndef _MSC_VER
		fprintf(stderr, "[MIX] ctor: %s IsEncrypted=%d IsDigest=%d\n",
			filename, (int)IsEncrypted, (int)IsDigest); fflush(stderr);
#endif

		if (IsEncrypted) {
#ifndef _MSC_VER
			fprintf(stderr, "[MIX] ctor: %s calling pstraw.Key\n", filename); fflush(stderr);
#endif
			pstraw.Key(key);
#ifndef _MSC_VER
			fprintf(stderr, "[MIX] ctor: %s calling pstraw.Get_From\n", filename); fflush(stderr);
#endif
			pstraw.Get_From(&fstraw);
			straw = &pstraw;
#ifndef _MSC_VER
			fprintf(stderr, "[MIX] ctor: %s calling straw->Get fileheader\n", filename); fflush(stderr);
#endif
		}
		straw->Get(&fileheader, sizeof(fileheader));
#ifndef _MSC_VER
		{ unsigned char *_fh = (unsigned char *)&fileheader; size_t _sz = sizeof(fileheader);
		  fprintf(stderr, "[MIX] ctor: %s fileheader sizeof=%zu raw: %02x %02x %02x %02x %02x %02x\n",
		          filename, _sz,
		          _fh[0],_fh[1],_fh[2],_fh[3],
		          _sz>4?_fh[4]:0, _sz>5?_fh[5]:0); fflush(stderr); }
		fprintf(stderr, "[MIX] ctor: %s fileheader done, count=%d size=%d\n",
			filename, (int)fileheader.count, (int)fileheader.size); fflush(stderr);
#endif

	} else {
		memmove(&fileheader, &alternate, sizeof(alternate));
		straw->Get(((char*)&fileheader)+sizeof(alternate), sizeof(fileheader)-sizeof(alternate));
	}

	Count = fileheader.count;
	DataSize = fileheader.size;
#ifndef _MSC_VER
	fprintf(stderr, "[MIX] ctor: %s Count=%d DataSize=%d\n", filename, Count, DataSize); fflush(stderr);
#endif
//BGMono_Printf("Mixfileclass %s DataSize: %08x   \n",filename,DataSize);Get_Key();
	/*
	**	Load up the offset control array. If RAM is exhausted, then the mixfile is invalid.
	*/
	HeaderBuffer = new SubBlock [Count];
	if (HeaderBuffer == NULL) return;
#ifndef _MSC_VER
	fprintf(stderr, "[MIX] ctor: %s HeaderBuffer allocated, reading index\n", filename); fflush(stderr);
#endif
	straw->Get(HeaderBuffer, Count * sizeof(SubBlock));
#ifndef _MSC_VER
	fprintf(stderr, "[MIX] ctor: %s index read done\n", filename); fflush(stderr);
	for (int _i = 0; _i < Count && _i < 8; _i++)
		fprintf(stderr, "[MIX] ctor: %s idx[%d] crc=%08x off=%d sz=%d\n",
		        filename, _i, (unsigned)HeaderBuffer[_i].CRC,
		        HeaderBuffer[_i].Offset, HeaderBuffer[_i].Size); fflush(stderr);
	/* TIM-195: TITLE.PCX located at HIRES.MIX idx[47] crc=b7f18233 — full dump no longer needed */
#endif

	/*
	**	The start of the embedded mixfile data will be at the current file offset.
	**	This should be true even if the file header has been encrypted because the file
	**	header was cleverly written with just the sufficient number of padding bytes so
	**	that this condition would be true.
	*/
	DataStart = file.Seek(0, SEEK_CUR) + file.BiasStart;
//	DataStart = file.Seek(0, SEEK_CUR);
#ifndef _MSC_VER
	fprintf(stderr, "[MIX] ctor: %s DataStart=%d, added to list\n", filename, DataStart); fflush(stderr);
#endif

	/*
	**	Attach to list of mixfiles.
	*/
	List.Add_Tail(this);
}


/***********************************************************************************************
 * MixFileClass::Retrieve -- Retrieves a pointer to the specified data file.                   *
 *                                                                                             *
 *    This routine will return with a pointer to the specified data file if the file resides   *
 *    in memory. Otherwise, this routine returns NULL. Use this routine to access a resident   *
 *    file directly rather than going through the process of pseudo disk access. This will     *
 *    save both time and RAM.                                                                  *
 *                                                                                             *
 * INPUT:   filename -- Pointer to the filename of the data file to retrieve a pointer to.     *
 *                                                                                             *
 * OUTPUT:  Returns with a pointer to the data file's data. If the file is not in RAM, then    *
 *          NULL is returned.                                                                  *
 *                                                                                             *
 * WARNINGS:   none                                                                            *
 *                                                                                             *
 * HISTORY:                                                                                    *
 *   08/23/1994 JLB : Created.                                                                 *
 *=============================================================================================*/
template<class T>
void const * MixFileClass<T>::Retrieve(char const * filename)
{
	void * ptr = 0;
	Offset(filename, &ptr);
	return(ptr);
};


/***********************************************************************************************
 * MixFileClass::Finder -- Finds the mixfile object that matches the name specified.           *
 *                                                                                             *
 *    This routine will scan through all registered mixfiles and return with a pointer to      *
 *    the matching mixfile. If no mixfile could be found that matches the name specified,      *
 *    then NULL is returned.                                                                   *
 *                                                                                             *
 * INPUT:   filename -- Pointer to the filename to search for.                                 *
 *                                                                                             *
 * OUTPUT:  Returns with a pointer to the matching mixfile -- if found.                        *
 *                                                                                             *
 * WARNINGS:   none                                                                            *
 *                                                                                             *
 * HISTORY:                                                                                    *
 *   08/08/1994 JLB : Created.                                                                 *
 *   06/08/1996 JLB : Only compares filename and extension.                                    *
 *=============================================================================================*/
template<class T>
MixFileClass<T> * MixFileClass<T>::Finder(char const * filename)
{
	MixFileClass<T> * ptr = List.First();
	while (ptr->Is_Valid()) {
		char path[_MAX_PATH];
		char name[_MAX_FNAME];
		char ext[_MAX_EXT];

		/*
		**	Strip the drive and path (if present) off of the filename
		**	in the mixfile list. This enables a simple comparison to the
		**	filename specified. The filename specified won't have a path attached and
		**	the full pathname in the mixfile list WILL have a path attached. Hence, this
		** stripping of the path is necessary.
		*/
		_splitpath(ptr->Filename, NULL, NULL, name, ext);
		_makepath(path, NULL, NULL, name, ext);

		if (stricmp(path, filename) == 0) {
			return(ptr);
		}
		ptr = ptr->Next();
	}
	return(0);
}


/***********************************************************************************************
 * MixFileClass::Cache -- Caches the named mixfile into RAM.                                   *
 *                                                                                             *
 *    This routine will cache the mixfile, specified by name, into RAM.                        *
 *                                                                                             *
 * INPUT:   filename -- The name of the mixfile that should be cached.                         *
 *                                                                                             *
 * OUTPUT:  bool; Was the cache successful?                                                    *
 *                                                                                             *
 * WARNINGS:   This routine could go to disk for a very long time.                             *
 *                                                                                             *
 * HISTORY:                                                                                    *
 *   08/08/1994 JLB : Created.                                                                 *
 *=============================================================================================*/
template<class T>
bool MixFileClass<T>::Cache(char const * filename, Buffer const * buffer)
{
	MixFileClass<T> * mixer = Finder(filename);

	if (mixer != NULL) {
		return(mixer->Cache(buffer));
	}
	return(false);
}


/***********************************************************************************************
 * MixFileClass::Cache -- Loads this particular mixfile's data into RAM.                       *
 *                                                                                             *
 *    This load the mixfile data into ram for this mixfile object. This is the counterpart     *
 *    to the Free() function.                                                                  *
 *                                                                                             *
 * INPUT:   none                                                                               *
 *                                                                                             *
 * OUTPUT:  bool; Was the file load successful?  It could fail if there wasn't enough room     *
 *                to allocate the raw data block.                                              *
 *                                                                                             *
 * WARNINGS:   This routine goes to disk for a potentially very long time.                     *
 *                                                                                             *
 * HISTORY:                                                                                    *
 *   08/08/1994 JLB : Created.                                                                 *
 *   07/12/1996 JLB : Handles attached message digest.                                         *
 *=============================================================================================*/
template<class T>
bool MixFileClass<T>::Cache(Buffer const * buffer)
{
#ifndef _MSC_VER
	fprintf(stderr,"[MIX] Cache_instance(%s): Data=%p IsDigest=%d IsEncrypted=%d DataSize=%ld DataStart=%ld\n",
	        Filename ? Filename : "?", Data, (int)IsDigest, (int)IsEncrypted, DataSize, DataStart); fflush(stderr);
#endif
	/*
	**	If the mixfile is already cached, then no action needs to be performed.
	*/
	if (Data != NULL) return(true);

	/*
	**	If a buffer was supplied (and it is big enough), then use it as the data block
	**	pointer. Otherwise, the data block must be allocated.
	*/
	if (buffer != NULL) {
		if (buffer->Get_Size() == 0 || buffer->Get_Size() >= DataSize) {
			Data = buffer->Get_Buffer();
		}
	} else {
		Data = new char [DataSize];
		IsAllocated = true;
	}

	/*
	**	If there is a data buffer to fill, then fill it now.
	*/
	if (Data != NULL) {
		T file(Filename);

		FileStraw fstraw(file);
		Straw * straw = &fstraw;

		/*
		**	If a message digest is attached, then link a SHA straw segment to the data
		**	stream so that the actual SHA can be compared with the attached one.
		*/
		SHAStraw sha;
#ifndef _MSC_VER
		/* TIM-173: SHAEngine inline ctor emits LP64-mismatched layout; Hash() crashes.
		 * Bypass SHA straw chain on Linux until SHA LP64 is fixed in a dedicated pass. */
		bool const skip_sha_check = true;
#else
		bool const skip_sha_check = false;
#endif
		if (IsDigest && !skip_sha_check) {
			sha.Get_From(fstraw);
			straw = &sha;
		}

		/*
		**	Bias the file to the actual start of the data. This is necessary because the
		**	real data starts some distance (not so easily determined) from the beginning of
		**	the real file.
		*/
		file.Open(READ);
		file.Bias(0);
		file.Bias(DataStart);
#ifndef _MSC_VER
		fprintf(stderr, "[MIX] Cache: %s file.Is_Open=%d DataStart=%ld DataSize=%ld\n",
		        Filename, (int)file.Is_Open(), DataStart, DataSize); fflush(stderr);
#endif

		/*
		**	Fetch the whole mixfile data in one step. If the number of bytes retrieved
		**	does not equal that requested, then this indicates a serious error.
		*/

#ifndef _MSC_VER
		fprintf(stderr, "[MIX] Cache(%s): before straw->Get Data=%p DataSize=%ld\n",
		        Filename, Data, DataSize); fflush(stderr);
#endif
		long actual = straw->Get(Data, DataSize);
#ifndef _MSC_VER
		fprintf(stderr, "[MIX] Cache(%s): DataStart=%ld DataSize=%ld actual=%ld\n",
		        Filename, DataStart, DataSize, actual); fflush(stderr);
#endif
		if (actual != DataSize) {
			delete [] Data;
			Data = NULL;
			file.Error(EIO);
			return(false);
		}

		/*
		**	If there is a digest attached to this mixfile, then read it in and
		**	compare it to the generated digest. If they don't match, then
		**	return with the "failure to cache" error code.
		*/
		if (IsDigest && !skip_sha_check) {
			char digest1[20];
			char digest2[20];
#ifndef _MSC_VER
			fprintf(stderr,"[MIX] Cache(%s): before sha.Result\n",Filename); fflush(stderr);
#endif
			sha.Result(digest2);
#ifndef _MSC_VER
			fprintf(stderr,"[MIX] Cache(%s): before fstraw.Get digest\n",Filename); fflush(stderr);
#endif
			fstraw.Get(digest1, sizeof(digest1));
#ifndef _MSC_VER
			{ int _dm = memcmp(digest1, digest2, sizeof(digest1));
			  fprintf(stderr,"[MIX] Cache(%s): digest got=%02x%02x%02x%02x... calc=%02x%02x%02x%02x... match=%d\n",
			          Filename,
			          (unsigned char)digest1[0],(unsigned char)digest1[1],
			          (unsigned char)digest1[2],(unsigned char)digest1[3],
			          (unsigned char)digest2[0],(unsigned char)digest2[1],
			          (unsigned char)digest2[2],(unsigned char)digest2[3], _dm==0); fflush(stderr); }
#endif
			if (memcmp(digest1, digest2, sizeof(digest1)) != 0) {
				delete [] Data;
				Data = NULL;
				return(false);
			}
		}

		return(true);
	}
	IsAllocated = false;
	return(false);
}


/***********************************************************************************************
 * MixFileClass::Free -- Frees the allocated raw data block (not the index block).             *
 *                                                                                             *
 *    This routine will free the (presumably large) raw data block, but leave the index        *
 *    block intact. By using this in conjunction with the Cache() function, one can maintain   *
 *    tight control of memory usage. If the index block is desired to be freed, then the       *
 *    mixfile object must be deleted.                                                          *
 *                                                                                             *
 * INPUT:   none                                                                               *
 *                                                                                             *
 * OUTPUT:  none                                                                               *
 *                                                                                             *
 * WARNINGS:   none                                                                            *
 *                                                                                             *
 * HISTORY:                                                                                    *
 *   08/08/1994 JLB : Created.                                                                 *
 *=============================================================================================*/
template<class T>
void MixFileClass<T>::Free(void)
{
	if (Data != NULL && IsAllocated) {
		delete [] Data;
	}
	Data = NULL;
	IsAllocated = false;
}


int compfunc(void const * ptr1, void const * ptr2)
{
	if (*(int const *)ptr1 < *(int const *)ptr2) return(-1);
	if (*(int const *)ptr1 > *(int const *)ptr2) return(1);
	return(0);
}


/***********************************************************************************************
 * MixFileClass::Offset -- Determines the offset of the requested file from the mixfile system.*
 *                                                                                             *
 *    This routine will take the filename specified and search through the mixfile system      *
 *    looking for it. If the file was found, then the mixfile it was found in, the offset      *
 *    from the start of the mixfile, and the size of the embedded file will be returned.       *
 *    Using this method it is possible for the CCFileClass system to process it as a normal    *
 *    file.                                                                                    *
 *                                                                                             *
 * INPUT:   filename    -- The filename to search for.                                         *
 *                                                                                             *
 *          realptr     -- Stores a pointer to the start of the file in memory here. If the    *
 *                         file is not in memory, then NULL is stored here.                    *
 *                                                                                             *
 *          mixfile     -- The pointer to the corresponding mixfile is placed here. If no      *
 *                         mixfile was found that contains the file, then NULL is stored here. *
 *                                                                                             *
 *          offset      -- The starting offset from the beginning of the parent mixfile is     *
 *                         stored here.                                                        *
 *                                                                                             *
 *          size        -- The size of the embedded file is stored here.                       *
 *                                                                                             *
 * OUTPUT:  bool; Was the file found? The file may or may not be resident, but it does exist   *
 *                 and can be opened.                                                           *
 *                                                                                             *
 * WARNINGS:   none                                                                            *
 *                                                                                             *
 * HISTORY:                                                                                    *
 *   10/17/1994 JLB : Created.                                                                 *
 *=============================================================================================*/
template<class T>
bool MixFileClass<T>::Offset(char const * filename, void ** realptr, MixFileClass ** mixfile, long * offset, long * size) 
{
	MixFileClass<T> * ptr;

	if (filename == NULL) {
assert(filename != NULL);//BG
		return(false);
	}

	/*
	**	Create the key block that will be used to binary search for the file.
	*/
	// Can't call strupr on a const string. ST - 5/20/2019
	//long crc = Calculate_CRC(strupr((char *)filename), strlen(filename));
	char filename_upper[_MAX_PATH];
	strcpy(filename_upper, filename);
	strupr(filename_upper);
	int crc = Calculate_CRC(strupr(filename_upper), strlen(filename_upper));
	SubBlock key;
	key.CRC = crc;

	/*
	**	Sweep through all registered mixfiles, trying to find the file in question.
	*/
	ptr = List.First();
	while (ptr->Is_Valid()) {
		SubBlock * block;

		/*
		**	Binary search for the file in this mixfile. If it is found, then extract the
		**	appropriate information and store it in the locations provided and then return.
		*/
		block = (SubBlock *)bsearch(&key, ptr->HeaderBuffer, ptr->Count, sizeof(SubBlock), compfunc);
		if (block != NULL) {
			if (mixfile != NULL) *mixfile = ptr;
			if (size != NULL) *size = block->Size;
			if (realptr != NULL) *realptr = NULL;
			if (offset != NULL) *offset = block->Offset;
			if (realptr != NULL && ptr->Data != NULL) {
				*realptr = (char *)ptr->Data + block->Offset;
			}
			if (ptr->Data == NULL && offset != NULL) {
				*offset += ptr->DataStart;
			}
			return(true);
		}

		/*
		**	Advance to next mixfile.
		*/
		ptr = ptr->Next();
	}

	/*
	**	All the mixfiles have been examined but no match was found. Return with the non success flag.
	*/
assert(1);//BG
	return(false);
}



// ST - 12/18/2019 11:36AM
template<class T>
void MixFileClass<T>::Free_All(void)
{
	MixFileClass<T> * ptr = List.First();
	while (ptr->Is_Valid()) {
		delete ptr;
		ptr = List.First();
	}
}
