// Stub THIPX32.DLL — replaces the real IPX networking DLL with one that
// doesn't depend on 16-bit THIPX16.DLL thunking. Provides the same exports
// as the original but returns sensible default/error values.
//
// Build with:
//   i686-w64-mingw32-gcc -shared -o thipx32.dll stub.c thipx32.def
//
// The .def file provides correct export names (with _Name@N decoration
// matching what RA95.EXE's import table expects).

#include <windows.h>

// --- Exported functions (matching original thipx32.dll exports) ---

int __stdcall IPX_Broadcast_Packet95(void) { return 0; }
int __stdcall IPX_Change_Socket95(void) { return 0; }
int __stdcall IPX_Close_Socket95(void) { return 0; }
int __stdcall IPX_Enum_Setup95(void) { return 0; }
int __stdcall IPX_Get_Connection_Number95(void) { return 0; }
int __stdcall IPX_Get_Local_Target95(void) { return 0; }
int __stdcall IPX_Get_Outstanding_Buffer95(void) { return 0; }
int __stdcall IPX_Get_System_Address95(void) { return 0; }
int __stdcall IPX_Get_System_Clock95(void) { return 0; }
int __stdcall IPX_Get_System_Data(void) { return 0; }
int __stdcall IPX_Get_Version(void) { return 0x0100; }
int __stdcall IPX_Initialise(void) { return 0; }
int __stdcall IPX_Open_Socket95(void) { return 0; }
int __stdcall IPX_Packet_Exchange95(void) { return 0; }
int __stdcall IPX_Register_Logical_Host95(void) { return 0; }
int __stdcall IPX_Resume95(void) { return 0; }
int __stdcall IPX_Send_Packet95(void) { return 0; }
int __stdcall IPX_Shut_Down95(void) { return 0; }
int __stdcall IPX_Shutdown95(void) { return 0; }
int __stdcall IPX_Start_Listening95(void) { return 0; }
int __stdcall IPX_Suspend95(void) { return 0; }

// Thunk data - needs to be a real data structure that the thunking layer
// expects. For the stub, this is a minimal structure.
#pragma data_seg(".thunk")
unsigned char Thipx_ThunkData32[64] = { 0 };
#pragma data_seg()

// --- DllMain ---

BOOL WINAPI DllMain(HINSTANCE hinstDLL, DWORD fdwReason, LPVOID lpvReserved) {
    (void)hinstDLL;
    (void)fdwReason;
    (void)lpvReserved;
    return TRUE;
}
