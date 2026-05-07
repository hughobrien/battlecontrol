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

/* TIM-53: byte-order helpers and WSACleanup. FIELD.CPP:141/146 calls
 * htons / htonl on engine values to byte-flip serialization payloads
 * for cross-arch save files; UTRACKER.CPP:202 calls htonl; WSPROTO.CPP
 * :137 calls WSACleanup() under a tear-down path. We can NOT pull
 * <arpa/inet.h> here -- it redefines `struct in_addr` and would clash
 * with the opaque stub above. Compute byte-swaps inline using the
 * GCC/Clang builtins so semantics are exact on every endianness, and
 * provide a no-op WSACleanup since we are not actually managing a
 * Winsock instance. */
static inline unsigned short __wwlib_htons(unsigned short v)
{
#if defined(__BYTE_ORDER__) && __BYTE_ORDER__ == __ORDER_BIG_ENDIAN__
    return v;
#else
    return __builtin_bswap16(v);
#endif
}
static inline unsigned int __wwlib_htonl(unsigned int v)
{
#if defined(__BYTE_ORDER__) && __BYTE_ORDER__ == __ORDER_BIG_ENDIAN__
    return v;
#else
    return __builtin_bswap32(v);
#endif
}

#ifndef htons
#define htons(v) __wwlib_htons((unsigned short)(v))
#endif
#ifndef htonl
#define htonl(v) __wwlib_htonl((unsigned int)(v))
#endif
/* Network-to-host inverses are identical to host-to-network on every
 * supported endianness, so reuse the same builtin-driven path. */
#ifndef ntohs
#define ntohs(v) __wwlib_htons((unsigned short)(v))
#endif
#ifndef ntohl
#define ntohl(v) __wwlib_htonl((unsigned int)(v))
#endif

#ifdef __cplusplus
static inline int WSACleanup(void) { return 0; }
#else
static inline int WSACleanup(void) { return 0; }
#endif

/* TIM-55: closesocket -- WSPROTO.CPP:161 tear-down call after a SOCKET
 * is no longer needed. We never actually open a socket on Linux through
 * the stub, so the no-op return preserves parser semantics without
 * requiring real fd lifetime management. */
#ifdef __cplusplus
static inline int closesocket(SOCKET) { return 0; }
#else
static inline int closesocket(SOCKET s) { (void)s; return 0; }
#endif

/* TIM-55: LINGER -- Win32 socket-option payload for SO_LINGER. WSPUDP.CPP
 * :145 declares one on the stack and passes &ling to setsockopt. Layout
 * matches the real winsock1 ABI (two u_short halves: enable flag, then
 * timeout in seconds). Engine code only writes/reads the fields by name;
 * setsockopt is itself a stub (sockets are dormant on Linux for now). */
#ifndef _WINSOCK1_LINGER_DEFINED
#define _WINSOCK1_LINGER_DEFINED
typedef struct linger {
    unsigned short l_onoff;
    unsigned short l_linger;
} LINGER, *PLINGER, *LPLINGER;
#endif

/* TIM-56: sockaddr_in -- IPv4 socket-address record. Real winsock1
 * <winsock.h> shape: sin_family / sin_port / sin_addr / sin_zero[8].
 * WSPUDP.CPP:146 declares `struct sockaddr_in addr;` then writes
 * sin_family/sin_port/sin_addr.s_addr at lines 166-168 and reads
 * sin_addr.s_addr at line 356/366. Layout matches the SDK so engine
 * memcpy/memcmp through these fields stays well-defined. We do NOT
 * pull <netinet/in.h> here -- it would clash with the in_addr struct
 * defined above and trigger the same cascade trap as TIM-53's
 * <arpa/inet.h> attempt. */
#ifndef _WINSOCK1_SOCKADDR_IN_DEFINED
#define _WINSOCK1_SOCKADDR_IN_DEFINED
struct sockaddr_in {
    short          sin_family;
    unsigned short sin_port;
    struct in_addr sin_addr;
    char           sin_zero[8];
};
typedef struct sockaddr_in  SOCKADDR_IN;
typedef struct sockaddr_in* PSOCKADDR_IN;
typedef struct sockaddr_in* LPSOCKADDR_IN;
#endif

/* TIM-56: socket-type macros. WSPUDP.CPP / WSPIPX.CPP pass SOCK_DGRAM
 * to socket() for UDP / IPX datagram sockets. SOCK_STREAM is included
 * for completeness so any TCP fallback path in mplpc / mplib / wol
 * also parses. Standard Berkeley/Winsock1 values. */
#ifndef SOCK_STREAM
#define SOCK_STREAM 1
#endif
#ifndef SOCK_DGRAM
#define SOCK_DGRAM  2
#endif
#ifndef SOCK_RAW
#define SOCK_RAW    3
#endif

/* TIM-56: address-family macros. WSPUDP.CPP:166/400 sets
 * addr.sin_family = AF_INET; WSPIPX.CPP:107 uses AF_IPX; mplib/wol
 * sources reference AF_NS as a deprecated alias. Standard Winsock1
 * values from <winsock.h>: AF_INET=2, AF_IPX=6, AF_NS=6. */
#ifndef AF_UNSPEC
#define AF_UNSPEC 0
#endif
#ifndef AF_INET
#define AF_INET   2
#endif
#ifndef AF_IPX
#define AF_IPX    6
#endif
#ifndef AF_NS
#define AF_NS     6
#endif

/* TIM-56: WSAAsyncSelect event-type macros. WSPROTO.CPP:187 passes
 * `FD_READ | FD_WRITE` as the lEvent bitmask. Standard Winsock1
 * values from <winsock.h>; the engine never receives a real event,
 * so the macros only need to be the right bit constants for the
 * `if (events & FD_READ) ...` style checks elsewhere to fold. */
#ifndef FD_READ
#define FD_READ     0x01
#endif
#ifndef FD_WRITE
#define FD_WRITE    0x02
#endif
#ifndef FD_OOB
#define FD_OOB      0x04
#endif
#ifndef FD_ACCEPT
#define FD_ACCEPT   0x08
#endif
#ifndef FD_CONNECT
#define FD_CONNECT  0x10
#endif
#ifndef FD_CLOSE
#define FD_CLOSE    0x20
#endif

/* TIM-63: INADDR_ANY -- wildcard IPv4 bind address. WSPUDP.CPP:168 sets
 * `addr.sin_addr.s_addr = htonl(INADDR_ANY)` to bind on all local
 * interfaces. Standard <winsock.h> value (0u). The htonl wrapper above
 * folds the constant to 0 on every endianness; engine code never
 * numerically compares against INADDR_ANY, so the value is opaque. */
#ifndef INADDR_ANY
#define INADDR_ANY  ((unsigned long)0x00000000)
#endif

/* TIM-63: SOL_SOCKET + SO_* socket-option-name macros. WSPUDP.CPP:219
 * (SO_LINGER), WSPIPX.CPP:237 (SO_BROADCAST), WSPROTO.CPP:536/538
 * (SO_ERROR), 569 (SO_RCVBUF), 580 (SO_SNDBUF) all pass these through
 * setsockopt/getsockopt. The setsockopt/getsockopt function shims land
 * in the pass-33 function-shim bundle; this pass pre-positions the
 * option-name singletons that those calls reference. Standard SDK
 * values from <winsock.h>; engine code never branches on the numbers,
 * so the literals only need to parse. */
#ifndef SOL_SOCKET
#define SOL_SOCKET   0xffff
#endif
#ifndef SO_BROADCAST
#define SO_BROADCAST 0x0020
#endif
#ifndef SO_LINGER
#define SO_LINGER    0x0080
#endif
#ifndef SO_SNDBUF
#define SO_SNDBUF    0x1001
#endif
#ifndef SO_RCVBUF
#define SO_RCVBUF    0x1002
#endif
#ifndef SO_ERROR
#define SO_ERROR     0x1007
#endif

/* TIM-63: IPX_PTYPE / IPX_FILTERPTYPE -- IPX-protocol-level option-name
 * macros. WSPIPX.CPP:247 sets the outgoing IPX packet type via
 * setsockopt(NSPROTO_IPX, IPX_PTYPE, ...), and 258 installs the
 * inbound filter via setsockopt(NSPROTO_IPX, IPX_FILTERPTYPE, ...).
 * Standard <wsnwlink.h> values from the Microsoft IPX/SPX header.
 * The setsockopt() function shim itself lands in pass-33; this pass
 * pre-positions the option-name singletons. */
#ifndef IPX_PTYPE
#define IPX_PTYPE       0x4000
#endif
#ifndef IPX_FILTERPTYPE
#define IPX_FILTERPTYPE 0x4001
#endif

/* TIM-59: struct sockaddr forward + LPSOCKADDR. WSPUDP.CPP / WSPIPX.CPP
 * cast `(LPSOCKADDR)&addr` (where addr is `struct sockaddr_in`) when
 * passing to bind/sendto/recvfrom. We forward-declare the generic
 * sockaddr as opaque rather than pulling <sys/socket.h> -- doing so
 * would clash with the in_addr layout above and trigger the same
 * cascade trap as the <arpa/inet.h> attempt in TIM-53. The C-style
 * pointer casts at the call sites coerce sockaddr_in* through this
 * forward decl without needing field access. */
#ifndef _WINSOCK1_SOCKADDR_FWD_DEFINED
#define _WINSOCK1_SOCKADDR_FWD_DEFINED
struct sockaddr;
typedef struct sockaddr  SOCKADDR;
typedef struct sockaddr* PSOCKADDR;
typedef struct sockaddr* LPSOCKADDR;
#endif

/* TIM-59: NSPROTO_IPX -- Win32 Winsock IPX protocol selector. WSPIPX
 * .CPP:98 calls `socket(AF_IPX, SOCK_DGRAM, NSPROTO_IPX)` to open an
 * IPX datagram socket. Standard <wsnetbs.h>/<wsnwlink.h> value (1000)
 * from the Microsoft NSP catalogue. The IPX path is dormant under the
 * stub (socket() itself returns INVALID_SOCKET below); the constant
 * just lets the call site parse. */
#ifndef NSPROTO_IPX
#define NSPROTO_IPX 1000
#endif

/* TIM-59: socket / bind / sendto / recvfrom -- core Winsock1 BSD-shape
 * I/O surface. WSPUDP.CPP:158/170/341/410 (UDP path) and WSPIPX.CPP
 * :98/216/335/424 (IPX path) drive the engine's network transport. We
 * are NOT wiring real Linux sockets here -- the stub returns
 * INVALID_SOCKET on socket() so the engine's caller-side check
 * (`if (Socket == INVALID_SOCKET) return false;`) bails out and the
 * subsequent bind/sendto/recvfrom calls parse but never run.
 *
 * Real Win32 signatures from <winsock.h>:
 *   SOCKET socket(int af, int type, int protocol);
 *   int    bind(SOCKET, const struct sockaddr*, int);
 *   int    sendto(SOCKET, const char*, int, int, const struct sockaddr*, int);
 *   int    recvfrom(SOCKET, char*, int, int, struct sockaddr*, int*);
 * Linux <sys/socket.h> uses ssize_t / socklen_t in places; we keep the
 * Win32 signatures verbatim because that is what the engine call sites
 * are typed against. */
static inline SOCKET socket(int, int, int) { return INVALID_SOCKET; }
static inline int    bind(SOCKET, const struct sockaddr*, int) { return SOCKET_ERROR; }
static inline int    sendto(SOCKET, const char*, int, int, const struct sockaddr*, int) { return SOCKET_ERROR; }
static inline int    recvfrom(SOCKET, char*, int, int, struct sockaddr*, int*) { return SOCKET_ERROR; }

/* TIM-59: WSAAsyncSelect / WSACancelAsyncRequest -- Win32 async I/O
 * notification surface (Winsock1). WSPROTO.CPP:187 enables FD_READ |
 * FD_WRITE notifications via WSAAsyncSelect; lines 190/215 cancel
 * outstanding async-DNS requests on tear-down. The async-event pump
 * is dormant on Linux (no Win32 message loop); a later port routes
 * these via select()/poll(). Stubs return SOCKET_ERROR so any caller
 * that branches on success treats them as a no-op failure. */
static inline int WSAAsyncSelect(SOCKET, HWND, unsigned int, long) { return SOCKET_ERROR; }
static inline int WSACancelAsyncRequest(HANDLE) { return SOCKET_ERROR; }

/* TIM-77: pass-41 Winsock cluster shim drain. Pre-survey first-error
 * histogram on WSPIPX/WSPUDP/WSPROTO surfaced WSAStartup, gethostname,
 * getsockopt as immediate first-errors plus an obvious cascade of
 * setsockopt / WSAGetLastError / gethostbyname+hostent / WSAEWOULDBLOCK
 * / WSAGETSELECT* unpack helpers behind them. Same trivially-additive
 * shape as TIM-67 / TIM-71 / TIM-74 / TIM-75 -- inline returns / no-op
 * bodies and macro constants. WSPROTO and WSPUDP cascade past the
 * winsock cluster into Win32 SendMessage (windows.h scope, intentionally
 * out of TIM-77 scope -- next dispatch). */

/* WSAStartup -- WSPROTO.CPP:318 entry-point bring-up. Engine memsets
 * its own caller-allocated WSADATA buffer and then compares wVersion
 * against a baked-in expected version; the stub returns 0 (success)
 * and the wVersion comparison flow is dormant since sockets never
 * actually open (socket() returns INVALID_SOCKET above). */
static inline int WSAStartup(WORD, LPWSADATA) { return 0; }

/* gethostname -- WSPUDP.CPP:180 local-host name lookup. Real winsock1
 * fills the buffer with the host's name; the stub writes an empty
 * string so the immediate WWDebugString(hostname) call at WSPUDP.CPP
 * :181 prints a defined-but-empty value. */
static inline int gethostname(char* name, int)
{ if (name) name[0] = '\0'; return 0; }

/* hostent -- minimum-viable Win32 SDK winsock.h shape. WSPUDP.CPP:197
 * reads h_addr_list (cast through unsigned long**); the SDK form has
 * h_addr_list as char** and engine code casts. Layout matches winsock.h
 * so any future code that touches h_name / h_addrtype parses cleanly.
 * We do NOT pull <netdb.h> -- it would clash with struct in_addr above. */
#ifndef _WINSOCK1_HOSTENT_DEFINED
#define _WINSOCK1_HOSTENT_DEFINED
struct hostent {
    char*  h_name;
    char** h_aliases;
    short  h_addrtype;
    short  h_length;
    char** h_addr_list;
};
typedef struct hostent  HOSTENT;
typedef struct hostent* PHOSTENT;
typedef struct hostent* LPHOSTENT;
#endif

/* gethostbyname -- WSPUDP.CPP:182 follow-up to gethostname. Returns
 * NULL; the next-line dereference at WSPUDP.CPP:197 would NULL-trap
 * on a real run, but the parent Open_Socket path is gated on the
 * earlier socket() call returning INVALID_SOCKET so the dereference
 * is unreachable under the dormant-socket stub semantics. */
static inline struct hostent* gethostbyname(const char*)
{ return (struct hostent*)0; }

/* getsockopt / setsockopt -- WSPIPX/WSPUDP/WSPROTO socket-option I/O.
 * Engine code guards each call with `if (... == SOCKET_ERROR)` so a 0
 * return reads as success and the caller proceeds. Real linux
 * <sys/socket.h> uses socklen_t for the length pointer; we keep the
 * Win32 winsock.h signatures verbatim so call sites parse against the
 * engine's typed expectations. */
static inline int getsockopt(SOCKET, int, int, char*, int*) { return 0; }
static inline int setsockopt(SOCKET, int, int, const char*, int) { return 0; }

/* WSAGetLastError -- WSPIPX.CPP:337/427, WSPUDP.CPP:413, WSPROTO.CPP
 * :321 error-code retrieval after a failed sock op. Stub returns 0
 * (no error). The engine compares the value against WSAEWOULDBLOCK
 * to distinguish "would block" from real errors; with a 0 return,
 * the comparison reads as "real error" and the caller exits the
 * read loop -- consistent with the dormant-socket semantics. */
static inline int WSAGetLastError(void) { return 0; }

/* WSAEWOULDBLOCK -- Win32 SDK <winsock.h> error-code constant for
 * "operation would block on a non-blocking socket". WSPIPX.CPP:337
 * and WSPUDP.CPP:413 compare WSAGetLastError() against it to decide
 * whether to break the read loop. Standard SDK value: 10035. */
#ifndef WSAEWOULDBLOCK
#define WSAEWOULDBLOCK 10035
#endif

/* WSAGETSELECTEVENT / WSAGETSELECTERROR -- Win32 SDK <winsock.h>
 * macros that unpack WM_NETSOCK_EVENT message lParam payloads. WSPIPX
 * .CPP:316/325 and WSPUDP.CPP:322/331 use them to extract event-type
 * / error-code from the lParam halves. Standard SDK form is LOWORD/
 * HIWORD. LOWORD/HIWORD live in windows.h, which is force-included
 * via msvc-compat.h before this header in the include chain, so they
 * are visible here. */
#ifndef WSAGETSELECTEVENT
#define WSAGETSELECTEVENT(lParam) LOWORD(lParam)
#endif
#ifndef WSAGETSELECTERROR
#define WSAGETSELECTERROR(lParam) HIWORD(lParam)
#endif

#endif /* LINUX_STUBS_WINSOCK_H_INCLUDED */
