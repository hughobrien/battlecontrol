// Layout probe for LP64 struct audit: TechnoTypeClass (TIM-212) + DisplayClass/MapClass (TIM-236)
//
// Must be compiled via function.h (same entry-point as DISPLAY.CPP) to get all class
// definitions in the right include order.  Link with --unresolved-symbols=ignore-all
// since we never call any virtual methods (sizeof/offsetof are compile-time constants).
//
// Compile with: g++ -std=c++17 -I build/include-shim/redalert -I build/include-shim/win32lib
//   -I REDALERT -I REDALERT/WIN32LIB -I linux/win32-stubs
//   -include linux/win32-stubs/msvc-compat.h -w scripts/probe-layout.cpp
//   -o /tmp/probe-layout -Wl,--unresolved-symbols=ignore-all
//   && /tmp/probe-layout

#include <cstdio>
#include <cstddef>
#include "function.h"  // resolves via -I to build/include-shim/redalert/function.h

int main() {
    // -----------------------------------------------------------------------
    // Fundamental LP64 type sizes
    // -----------------------------------------------------------------------
    printf("=== Fundamental LP64 type sizes ===\n");
    printf("  sizeof(long)                            = %zu  (MSVC 32-bit: 4)\n", sizeof(long));
    printf("  sizeof(void*)                           = %zu  (MSVC 32-bit: 4)\n", sizeof(void*));
    printf("  sizeof(unsigned)                        = %zu  (both: 4)\n", sizeof(unsigned));
    printf("  sizeof(COORDINATE)                      = %zu  (MSVC 32-bit: 4)  [unsigned long]\n",
           sizeof(COORDINATE));
    printf("  sizeof(COORD_COMPOSITE)                 = %zu  (MSVC 32-bit: 4)  [union with COORDINATE]\n",
           sizeof(COORD_COMPOSITE));
    printf("  sizeof(LEPTON)                          = %zu  (both: 2)  [unsigned short]\n", sizeof(LEPTON));
    printf("  sizeof(CELL)                            = %zu  (both: 2)  [signed short]\n", sizeof(CELL));

    // -----------------------------------------------------------------------
    // Timer classes (unsigned long hazard — used in CrateClass)
    // -----------------------------------------------------------------------
    printf("\n=== Timer classes (LP64 unsigned long hazard) ===\n");
    printf("  sizeof(FrameTimerClass)                 = %zu  (MSVC 32-bit: 1 empty class)\n",
           sizeof(FrameTimerClass));
    printf("  sizeof(BasicTimerClass<FrameTimerClass>)= %zu  (MSVC 32-bit:  8 [1+pad3+ulong4])\n",
           sizeof(BasicTimerClass<FrameTimerClass>));
    printf("  sizeof(CDTimerClass<FrameTimerClass>)   = %zu  (MSVC 32-bit: 16 [base8+ulong4+bool1+pad3])\n",
           sizeof(CDTimerClass<FrameTimerClass>));
    printf("  sizeof(CrateClass)                      = %zu  (MSVC 32-bit: 20 [timer16+CELL2+pad2])\n",
           sizeof(CrateClass));
    printf("  256*sizeof(CrateClass)                  = %zu  (MSVC 32-bit: 5120)\n",
           256 * sizeof(CrateClass));

    // -----------------------------------------------------------------------
    // VectorClass<CellClass> — embedded as Array member in MapClass
    // -----------------------------------------------------------------------
    printf("\n=== VectorClass<CellClass> (has own vptr + T* pointer) ===\n");
    printf("  sizeof(VectorClass<CellClass>)          = %zu  (MSVC 32-bit: 16 [vptr4+ptr4+uint4+bitfield4])\n",
           sizeof(VectorClass<CellClass>));

    // -----------------------------------------------------------------------
    // GScreenClass (root of display hierarchy)
    // -----------------------------------------------------------------------
    printf("\n=== GScreenClass ===\n");
    printf("  sizeof(GScreenClass)                    = %zu  (MSVC 32-bit: 1032 [vptr4+bitfields4+pad1024])\n",
           sizeof(GScreenClass));

    // -----------------------------------------------------------------------
    // MapClass
    // -----------------------------------------------------------------------
    printf("\n=== MapClass ===\n");
    printf("  sizeof(MapClass)                        = %zu\n", sizeof(MapClass));
    printf("  offsetof(MapClass, MapCellX)            = %zu (0x%zx)  (MSVC 32-bit: 1032)\n",
           offsetof(MapClass, MapCellX), offsetof(MapClass, MapCellX));
    printf("  offsetof(MapClass, MapCellY)            = %zu (0x%zx)  (MSVC 32-bit: 1036)\n",
           offsetof(MapClass, MapCellY), offsetof(MapClass, MapCellY));
    printf("  offsetof(MapClass, MapCellWidth)        = %zu (0x%zx)  (MSVC 32-bit: 1040)\n",
           offsetof(MapClass, MapCellWidth), offsetof(MapClass, MapCellWidth));
    printf("  offsetof(MapClass, MapCellHeight)       = %zu (0x%zx)  (MSVC 32-bit: 1044)\n",
           offsetof(MapClass, MapCellHeight), offsetof(MapClass, MapCellHeight));
    printf("  offsetof(MapClass, TotalValue)          = %zu (0x%zx)  (MSVC 32-bit: 1048) [long!]\n",
           offsetof(MapClass, TotalValue), offsetof(MapClass, TotalValue));
    // Array, XSize, Crates are protected — not accessible with offsetof without derived class

    // -----------------------------------------------------------------------
    // DisplayClass
    // -----------------------------------------------------------------------
    printf("\n=== DisplayClass ===\n");
    printf("  sizeof(DisplayClass)                    = %zu\n", sizeof(DisplayClass));
    printf("  offsetof(DisplayClass, TacticalCoord)   = %zu (0x%zx)  [COORDINATE=unsigned long, MSVC: 4 bytes]\n",
           offsetof(DisplayClass, TacticalCoord), offsetof(DisplayClass, TacticalCoord));
    printf("  offsetof(DisplayClass, TacLeptonWidth)  = %zu (0x%zx)  [LEPTON=unsigned short]\n",
           offsetof(DisplayClass, TacLeptonWidth), offsetof(DisplayClass, TacLeptonWidth));
    printf("  offsetof(DisplayClass, TacLeptonHeight) = %zu (0x%zx)\n",
           offsetof(DisplayClass, TacLeptonHeight), offsetof(DisplayClass, TacLeptonHeight));
    printf("  offsetof(DisplayClass, ZoneCell)        = %zu (0x%zx)  [CELL=signed short]\n",
           offsetof(DisplayClass, ZoneCell), offsetof(DisplayClass, ZoneCell));
    printf("  offsetof(DisplayClass, ZoneOffset)      = %zu (0x%zx)\n",
           offsetof(DisplayClass, ZoneOffset), offsetof(DisplayClass, ZoneOffset));
    printf("  offsetof(DisplayClass, CursorSize)      = %zu (0x%zx)  [short const*, MSVC: 4 bytes]\n",
           offsetof(DisplayClass, CursorSize), offsetof(DisplayClass, CursorSize));
    printf("  offsetof(DisplayClass, CursorShapeSave) = %zu (0x%zx)  [short[256]=512 bytes]\n",
           offsetof(DisplayClass, CursorShapeSave), offsetof(DisplayClass, CursorShapeSave));
    printf("  offsetof(DisplayClass, ProximityCheck)  = %zu (0x%zx)  [bool]\n",
           offsetof(DisplayClass, ProximityCheck), offsetof(DisplayClass, ProximityCheck));
    printf("  offsetof(DisplayClass, PendingObjectPtr)= %zu (0x%zx)  [ObjectClass*, MSVC: 4 bytes]\n",
           offsetof(DisplayClass, PendingObjectPtr), offsetof(DisplayClass, PendingObjectPtr));
    printf("  offsetof(DisplayClass, PendingObject)   = %zu (0x%zx)  [ObjectTypeClass const*, MSVC: 4 bytes]\n",
           offsetof(DisplayClass, PendingObject), offsetof(DisplayClass, PendingObject));
    printf("  offsetof(DisplayClass, PendingHouse)    = %zu (0x%zx)\n",
           offsetof(DisplayClass, PendingHouse), offsetof(DisplayClass, PendingHouse));
    printf("  offsetof(DisplayClass, TacPixelX)       = %zu (0x%zx)\n",
           offsetof(DisplayClass, TacPixelX), offsetof(DisplayClass, TacPixelX));
    printf("  offsetof(DisplayClass, TacPixelY)       = %zu (0x%zx)\n",
           offsetof(DisplayClass, TacPixelY), offsetof(DisplayClass, TacPixelY));
    printf("  offsetof(DisplayClass,DesiredTacticalCoord)=%zu (0x%zx)  [COORDINATE=unsigned long, MSVC: 4 bytes]\n",
           offsetof(DisplayClass, DesiredTacticalCoord), offsetof(DisplayClass, DesiredTacticalCoord));

    // -----------------------------------------------------------------------
    // TechnoTypeClass (from TIM-212 — regression check)
    // -----------------------------------------------------------------------
    printf("\n=== TechnoTypeClass (regression) ===\n");
    printf("  sizeof(AbstractTypeClass)               = %zu\n", sizeof(AbstractTypeClass));
    printf("  sizeof(TechnoTypeClass)                 = %zu\n", sizeof(TechnoTypeClass));
    printf("  offsetof(TechnoTypeClass, Remap)        = %zu (0x%zx)\n",
           offsetof(TechnoTypeClass, Remap), offsetof(TechnoTypeClass, Remap));
    printf("  offsetof(TechnoTypeClass, Points)       = %zu (0x%zx)\n",
           offsetof(TechnoTypeClass, Points), offsetof(TechnoTypeClass, Points));
    printf("  sizeof(BuildingTypeClass)               = %zu\n", sizeof(BuildingTypeClass));

    return 0;
}
