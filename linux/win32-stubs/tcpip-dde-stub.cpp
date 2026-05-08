// TIM-154 NOP stubs for TcpipManagerClass (Winsock) and DDEServerClass (DDEServer).
//
// TCPIP.CPP and CCDDE.CPP each open with `#ifdef WIN32` before any includes,
// so the entire body is compiled away: WIN32 is only defined after wwstd.h is
// pulled in via function.h, but that include lives INSIDE the #ifdef WIN32
// block, so the guard fires with WIN32 undefined and the whole TU is empty.
//
// Callers (INIT.CPP, CONQUER.CPP, IPXMGR.CPP, IPXCONN.CPP, EVENT.CPP,
// STARTUP.CPP) DO compile because they include function.h first, which brings
// in wwstd.h → WIN32=1 before they reach their own #ifdef WIN32 guards.
//
// Fix: define WIN32 here so tcpip.h and ccdde.h expose their class shapes,
// then provide NOP bodies for every symbol the linker demands.
//
// Required Windows types (SOCKET, WSADATA, IN_ADDR, MAXGETHOSTSTRUCT, HSZ,
// HCONV, HDDEDATA, LPBYTE, DWORD, …) arrive via the force-included chain:
//   -include msvc-compat.h → windows.h → winsock.h / ddeml.h
//
// When a real network / DDE replacement lands, remove this file.

#ifndef WIN32
#define WIN32 1
#endif

#include "tcpip.h"  // TcpipManagerClass (guarded on WIN32)
#include "ccdde.h"  // DDEServerClass    (guarded on WIN32; pulls in dde.h)

// ---- Global definitions --------------------------------------------------

TcpipManagerClass Winsock;
DDEServerClass    DDEServer;

// ---- TcpipManagerClass NOP bodies ----------------------------------------

TcpipManagerClass::TcpipManagerClass(void) {}
TcpipManagerClass::~TcpipManagerClass(void) {}

BOOL TcpipManagerClass::Init(void)                              { return FALSE; }
void TcpipManagerClass::Start_Server(void)                      {}
void TcpipManagerClass::Start_Client(void)                      {}
void TcpipManagerClass::Close(void)                             {}
int  TcpipManagerClass::Read(void * /*buf*/, int /*len*/)       { return 0; }
void TcpipManagerClass::Write(void * /*buf*/, int /*len*/)      {}
void TcpipManagerClass::Set_Host_Address(char * /*addr*/)       {}

// ---- DDEServerClass NOP bodies -------------------------------------------

DDEServerClass::DDEServerClass(void)
    : MPlayerGameInfo(nullptr),
      MPlayerGameInfoLength(0),
      IsEnabled(FALSE),
      LastHeartbeat(0)
{}

DDEServerClass::~DDEServerClass(void) {}

char * DDEServerClass::Get_MPlayer_Game_Info(void)              { return nullptr; }
void   DDEServerClass::Delete_MPlayer_Game_Info(void)           {}
void   DDEServerClass::Enable(void)                             {}
void   DDEServerClass::Disable(void)                            {}
int    DDEServerClass::Time_Since_Heartbeat(void)               { return 0; }
