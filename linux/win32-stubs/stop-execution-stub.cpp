// TIM-151 Stop_Execution stub.
//
// KEYFBUFF.ASM originally contained a `_Stop_Execution` routine that
// halted execution (x86 real-mode mechanism). KEY.CPP and KEYBOARD.CPP
// both declare it `extern "C"` and call it on a bad-state escape path
// that cannot fire under the current runnable subset. NOP body.

extern "C" void Stop_Execution(void)
{
}

// TIM-159 pass-48A: DLL_Startup stub for Linux.
//
// On Linux, STARTUP.CPP exports main() (not DLL_Startup) because the
// _MSC_VER guard now controls the function name.  DLLInterface.cpp and
// DLLInterfaceEditor.cpp retain extern+call sites for DLL_Startup; those
// DLL entry points are never invoked in the standalone Linux binary, but
// the symbol must be present at link time.  NOP body that returns 0.
int DLL_Startup(const char*)
{
    return 0;
}
