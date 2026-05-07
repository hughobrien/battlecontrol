// TIM-146 oleaut32 thin stubs.
//
// Replaces the Windows OLE Automation runtime calls used by the level
// editor exports in REDALERT/DLLInterfaceEditor.cpp. The real OLE
// Automation surface is irrelevant to the in-game flow; these NOP
// bodies exist solely to close the link-time gap so the rest of the
// engine can run. SafeArrayCreate returns NULL, the access pair returns
// E_NOTIMPL — the editor wraps every call in `if (SUCCEEDED(...))` so
// the early-return path is harmless.

#include "windows.h"
#include "msvc-compat.h"

#ifndef E_NOTIMPL
#define E_NOTIMPL ((HRESULT)0x80004001L)
#endif

extern "C" {

SAFEARRAY* SafeArrayCreate(VARTYPE /*vt*/, unsigned int /*cDims*/, SAFEARRAYBOUND* /*rgsabound*/)
{
    return 0;
}

HRESULT SafeArrayAccessData(SAFEARRAY* /*psa*/, void** ppvData)
{
    if (ppvData) *ppvData = 0;
    return E_NOTIMPL;
}

HRESULT SafeArrayUnaccessData(SAFEARRAY* /*psa*/)
{
    return E_NOTIMPL;
}

}
