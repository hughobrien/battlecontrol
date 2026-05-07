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

/* $Header:   F:\projects\c&c0\vcs\code\turret.cpv   3.1   13 Mar 1996 09:49:34   JOE_BOSTIC  $ */
/***********************************************************************************************
 ***             C O N F I D E N T I A L  ---  W E S T W O O D   S T U D I O S               ***
 ***********************************************************************************************
 *                                                                                             *
 *                 Project Name : Command & Conquer                                            *
 *                                                                                             *
 *                    File Name : TURRET.CPP                                                   *
 *                                                                                             *
 *                   Programmer : Joe L. Bostic                                                *
 *                                                                                             *
 *                   Start Date : April 25, 1994                                               *
 *                                                                                             *
 *                  Last Update : August 13, 1995 [JLB]                                        *
 *                                                                                             *
 *---------------------------------------------------------------------------------------------*
 * Functions:                                                                                  *
 *   TurretClass::AI -- Handles the reloading of the turret weapon.                            *
 *   TurretClass::Can_Fire -- Determines if turret can fire upon target.                       *
 *   TurretClass::Debug_Dump -- Debug printing of turret values.                               *
 *   TurretClass::Fire_At -- Try to fire upon the target specified.                            *
 *   TurretClass::Fire_Coord -- Determines the coorindate that projectile would appear.        *
 *   TurretClass::Fire_Direction -- Determines the directinon of firing.                       *
 *   TurretClass::Ok_To_Move -- Queries whether the vehicle can move.                          *
 *   TurretClass::TurretClass -- Normal constructor for the turret class.                      *
 *   TurretClass::TurretClass -- The default constructor for turret class objects.             *
 *   TurretClass::Unlimbo -- Unlimboes turret object.                                          *
 *   TurretClass::~TurretClass -- Default destructor for turret class objects.                 *
 * - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - */

#include	"function.h"
#include	"turret.h"


/***********************************************************************************************
 * TurretClass::~TurretClass -- Default destructor for turret class objects.                   *
 *                                                                                             *
 *    This is the default destructor for turret class objects. It does nothing.                *
 *                                                                                             *
 * INPUT:   none                                                                               *
 *                                                                                             *
 * OUTPUT:  none                                                                               *
 *                                                                                             *
 * WARNINGS:   none                                                                            *
 *                                                                                             *
 * HISTORY:                                                                                    *
 *   08/13/1995 JLB : Created.                                                                 *
 *=============================================================================================*/
TurretClass::~TurretClass(void)
{
}


// TIM-146: anchor the TurretClass vtable. Itanium ABI emits the vtable
// in the TU defining the first non-inline non-pure virtual ("key
// function"). For TurretClass that's Code_Pointers — declared in
// TURRET.H but never previously defined, leaving the vtable absent
// and triggering "undefined reference to vtable for TurretClass" at
// link time. Empty bodies match the inline pattern from BASE.H and
// suffice because TurretClass is dead code in RA (no `new TurretClass`
// anywhere; see TIM-68 note on the ctors below).
void TurretClass::Code_Pointers(void)
{
}

void TurretClass::Decode_Pointers(void)
{
}


/***********************************************************************************************
 * TurretClass::TurretClass -- The default constructor for turret class objects.               *
 *                                                                                             *
 *    This is the default constructor for turret class objects. It does nothing.               *
 *                                                                                             *
 * INPUT:   none                                                                               *
 *                                                                                             *
 * OUTPUT:  none                                                                               *
 *                                                                                             *
 * WARNINGS:   none                                                                            *
 *                                                                                             *
 * HISTORY:                                                                                    *
 *   08/13/1995 JLB : Created.                                                                 *
 *=============================================================================================*/
// TIM-68: DriveClass has no default ctor (only NoInit/3-arg/copy).
// Delegate to the NoInit form so this empty default constructor parses.
// Matches the established sibling pattern in UnitClass::UnitClass(NoInit&).
TurretClass::TurretClass(void) : DriveClass(NoInitClass())
{
}


/***********************************************************************************************
 * TurretClass::TurretClass -- Normal constructor for the turret class.                        *
 *                                                                                             *
 *    This is the normal constructor for the turret class. It merely sets the turret up to     *
 *    face north.                                                                              *
 *                                                                                             *
 * INPUT:   classid  -- The type id for this particular unit.                                  *
 *                                                                                             *
 *          house    -- The house that this unit will belong to.                               *
 *                                                                                             *
 * OUTPUT:  none                                                                               *
 *                                                                                             *
 * WARNINGS:   none                                                                            *
 *                                                                                             *
 * HISTORY:                                                                                    *
 *   02/02/1995 JLB : Created.                                                                 *
 *=============================================================================================*/
// TIM-68: same DriveClass overload mismatch as the default ctor above.
// DriveClass needs (RTTIType, int, HousesType) -- (UnitType, HousesType)
// no longer matches. TurretClass is dead code in RA (no `new TurretClass`
// anywhere; only referenced by TURRET.{H,CPP}), so the minimal fix is
// to delegate to the NoInit form.
TurretClass::TurretClass(UnitType /*classid*/, HousesType /*house*/) :
	DriveClass(NoInitClass())
{
}



