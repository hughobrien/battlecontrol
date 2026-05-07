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

// TIM-20: SmartPtr<> was historically defined inline in JSHELL.H. Headers
// that name SmartPtr<T> as a member (notably OBJECT.H) had to rely on the
// includer pre-pulling JSHELL.H -- and JSHELL.H itself drags in the entire
// keyboard / library shim chain. Splitting the template into its own
// header (mirroring the FTIMER.H extraction from TIM-17) lets dependent
// headers parse standalone without inheriting JSHELL.H's full transitive
// closure. JSHELL.H now re-exports it via #include for back-compat.

#ifndef SMARTPTR_H
#define SMARTPTR_H

#include <assert.h>

// Forward declaration: SmartPtr's NoInitClass constructor only needs the
// type to exist (passed by const ref, body empty), so a forward decl
// keeps this header free of FTIMER.H's transitive closure for consumers
// that don't otherwise need it.
class NoInitClass;

template<class T>
class SmartPtr
{
	public:
		SmartPtr(NoInitClass const &) {}
		SmartPtr(T * realptr = 0) : Pointer(realptr) {}
		SmartPtr(SmartPtr const & rvalue) : Pointer(rvalue.Pointer) {}
		~SmartPtr(void) {Pointer = 0;}

		operator T * (void) const {return(Pointer);}

		operator long (void) const {return((long)Pointer);}

		SmartPtr<T> operator ++ (int) {assert(Pointer != 0);SmartPtr<T> temp = *this;++Pointer;return(temp);}
		SmartPtr<T> & operator ++ (void) {assert(Pointer != 0);++Pointer;return(*this);}
		SmartPtr<T> operator -- (int) {assert(Pointer != 0);SmartPtr<T> temp = *this;--Pointer;return(temp);}
		SmartPtr<T> & operator -- (void) {assert(Pointer != 0);--Pointer;return(*this);}

		SmartPtr & operator = (SmartPtr const & rvalue) {Pointer = rvalue.Pointer;return(*this);}
		T * operator -> (void) const {assert(Pointer != 0);return(Pointer);}
		T & operator * (void) const {assert(Pointer != 0);return(*Pointer);}

	private:
		T * Pointer;
};

#endif
