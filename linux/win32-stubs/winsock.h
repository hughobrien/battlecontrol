/* TIM-51 stub: Winsock 1.0 type taxonomy.
 *
 * Mirror of TIM-9 / TIM-46 minimum-viable type-taxonomy approach for the
 * Winsock1 surface. The pass-25 first-error histogram surfaced two new
 * top buckets — tcpip.h:96 (7 TUs) and WSProto.h:101 (4 TUs) — both
 * collapsing to the same root cause: `SOCKET` (and the rest of the
 * Winsock1 typedefs that tcpip.h's TcpipManagerClass member layout
 * requires) is not visible on Linux. Upstream's Win32 build relied on a
 * /FI force-include or precompiled-header path that pulled `<winsock.h>`
 * before tcpip.h; neither tcpip.h nor function.h pull it directly, and
 * REDALERT/WIN32LIB does not pull it either.
 *
 * Smallest shape that lets cc1plus parse the TcpipManagerClass /
 * WinsockInterfaceClass member declarations referenced in pass-25:
 *   tcpip.h:96, 105, 144-146  : SOCKET
 *   tcpip.h:130               : struct in_addr  (field Addr)
 *   tcpip.h:143               : WSADATA          (field WinsockInfo)
 *   tcpip.h:147, 164          : IN_ADDR
 *   tcpip.h:149               : MAXGETHOSTSTRUCT (array size)
 *   WSProto.h:101, 113        : SOCKET
 *
 * Rules (linux/win32-stubs/README.md, TIM-9 line):
 *   - Declarations only, no implementations.
 *   - Smallest shape that lets the parser reach the next layer.
 *   - Layout matches the real Winsock1 ABI where engine code does
 *     byte-level reasoning (in_addr is a 4-byte union/struct keyed off
 *     s_addr). We are NOT linking against winsock; nothing here ever
 *     executes.
 */
#ifndef LINUX_STUBS_WINSOCK_H_INCLUDED
#define LINUX_STUBS_WINSOCK_H_INCLUDED

#ifdef __cplusplus
#include <cstdint>
#else
#include <stdint.h>
#endif

/* SOCKET on Win32 is a UINT_PTR (pointer-sized unsigned). REDALERT
 * stores it in class members and compares against INVALID_SOCKET; an
 * opaque pointer-sized integer is enough for parse. */
typedef unsigned long      SOCKET;

#ifndef INVALID_SOCKET
#define INVALID_SOCKET     ((SOCKET)(~0))
#endif
#ifndef SOCKET_ERROR
#define SOCKET_ERROR       (-1)
#endif

/* in_addr — single 32-bit IPv4 address. Real Winsock layers an anon
 * union over four byte fields; engine code in tcpip.h only takes its
 * address and writes s_addr, so the struct shape is what matters. */
struct in_addr {
    union {
        struct { unsigned char s_b1, s_b2, s_b3, s_b4; } S_un_b;
        struct { unsigned short s_w1, s_w2; }            S_un_w;
        uint32_t                                          S_addr;
    } S_un;
#ifndef s_addr
#define s_addr S_un.S_addr
#endif
};
typedef struct in_addr     IN_ADDR;
typedef struct in_addr*    LPIN_ADDR;

/* WSADATA — winsock startup info block. Engine never reads its fields
 * after WSAStartup; opaque-with-realistic-size is enough. Field shape
 * mirrors WSADATA so any sizeof / memset on it parses cleanly. */
#define WSADESCRIPTION_LEN 256
#define WSASYS_STATUS_LEN  128
typedef struct WSAData {
    unsigned short wVersion;
    unsigned short wHighVersion;
    char           szDescription[WSADESCRIPTION_LEN + 1];
    char           szSystemStatus[WSASYS_STATUS_LEN + 1];
    unsigned short iMaxSockets;
    unsigned short iMaxUdpDg;
    char*          lpVendorInfo;
} WSADATA;
typedef WSADATA*           LPWSADATA;

/* MAXGETHOSTSTRUCT — size of the per-socket async-resolution buffer
 * that gethostbyname/gethostbyaddr write into. Real Winsock1 fixes
 * this at 1024. tcpip.h:149 uses it as a char[] dimension. */
#ifndef MAXGETHOSTSTRUCT
#define MAXGETHOSTSTRUCT   1024
#endif

#endif /* LINUX_STUBS_WINSOCK_H_INCLUDED */
