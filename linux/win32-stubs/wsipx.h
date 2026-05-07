/* TIM-55 stub: wsipx.h -- minimum-viable Win32 IPX socket-address.
 *
 * Pre-TIM-55 this was an empty placeholder so #include resolves. Pass-28
 * (TIM-53) fragmentations surfaced WSPIPX as a long-tail TU: WSProto.h
 * gates were cleared but build/include-shim/redalert/wspipx.h:61 still
 * fails on `SOCKADDR_IPX has not been declared` because REDALERT/WSPIPX.H
 * pulls <wsipx.h> directly and the SDK header is what normally defines
 * the IPX address taxonomy.
 *
 * Same TIM-9 / TIM-46 / TIM-51 pattern: smallest opaque shape that lets
 * cc1plus advance past parse, no implementation. Layout matches the
 * Win32 SDK so any byte-level engine code (memcpy / memset on the
 * sa_netnum / sa_nodenum arrays in WSPIPX.CPP:142-144, 188-190) stays
 * sound.
 *
 * Engine field usage confirmed in WSPIPX.CPP:
 *   :108  Addr.sa_family = AF_IPX;
 *   :142  memcpy(addr->sa_netnum,  IpxData.netnum,  sizeof(addr->sa_netnum));
 *   :144  memcpy(addr->sa_nodenum, IpxData.nodenum, sizeof(addr->sa_nodenum));
 *   :188  memset(addr.sa_netnum,  0,  sizeof(addr.sa_netnum));
 *   :189  memset(addr.sa_nodenum, -1, sizeof(addr.sa_nodenum));
 *   :190  addr.sa_socket = htons(socketnum);
 */
#ifndef LINUX_STUBS_WSIPX_H_INCLUDED
#define LINUX_STUBS_WSIPX_H_INCLUDED

/* Pull SOCKET / htons from the winsock1 type taxonomy. winsock.h is
 * already force-included via msvc-compat.h -> windows.h, but pull it
 * here too so a direct `#include <wsipx.h>` works in isolation. The
 * header is fully guarded so re-inclusion is free. */
#include "winsock.h"

#ifndef AF_IPX
#define AF_IPX 6
#endif

/* sockaddr_ipx -- per Win32 SDK <wsipx.h>:
 *   short          sa_family;     // AF_IPX
 *   char           sa_netnum[4];
 *   char           sa_nodenum[6];
 *   unsigned short sa_socket;     // network byte order
 *
 * Total size 14 bytes (no padding before sa_socket). Engine code in
 * WSPIPX.CPP relies on the four-byte / six-byte memcpy widths and on
 * sa_socket being the trailing u16. */
#ifndef _WSIPX_SOCKADDR_DEFINED
#define _WSIPX_SOCKADDR_DEFINED
typedef struct sockaddr_ipx {
    short          sa_family;
    char           sa_netnum[4];
    char           sa_nodenum[6];
    unsigned short sa_socket;
} SOCKADDR_IPX, *PSOCKADDR_IPX, *LPSOCKADDR_IPX;
#endif

#endif /* LINUX_STUBS_WSIPX_H_INCLUDED */
