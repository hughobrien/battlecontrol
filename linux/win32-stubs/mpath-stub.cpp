// TIM-151 MPath/LPC service stubs.
//
// MPMGRD.CPP uses two LPC (Local Procedure Call) service functions
// declared in the original WW MPath VxD headers (services.h, mplpc.h).
// On Linux there is no VxD layer; these NOP bodies satisfy the link-time
// references so we can continue advancing toward the run milestone.
//
// LPCGetMPAddr — returns the local MPath address. MPMGRD stores the
//   result in _myAddr (int). Return 0: no valid MPath address on Linux.
//
// GetGameDef — fills a TGAMEDEF with the current game definition.
//   Only numPlayers is accessed by MPMGRD::Find_Num_Connections; fill
//   the struct to zero so numPlayers==0, indicating no connected games.
//   MPMGRD.CPP wraps `#include "services.h"` inside `extern "C"`, so
//   GetGameDef has C linkage at call sites. Include services.h here
//   inside the same `extern "C"` block so both declaration and definition
//   agree on linkage; the body follows immediately inside the block.
//
// LPCGetMPAddr — `#include "mplpc.h"` is NOT inside extern "C" in
//   MPMGRD.CPP, so it gets C++ linkage and needs no extra annotation.

#include "mplpc.h"
#include <string.h>

int LPCGetMPAddr(void)
{
    return 0;
}

extern "C" {
#include "services.h"

void GetGameDef(TGAMEDEF *gd, int *sz)
{
    if (gd) memset(gd, 0, sizeof(*gd));
    if (sz) *sz = sizeof(TGAMEDEF);
}
}  // extern "C"
