// TIM-151 network reconnect dialog stubs.
//
// NETDLG.CPP and NULLDLG.CPP contain the network/modem reconnect UI
// dialogs, but both files are wrapped in `#if (0)//PG` which disables
// the function bodies. QUEUE.CPP calls both symbols unconditionally
// at link time.  These NOP bodies satisfy the linker.
//
// Net_Reconnect_Dialog — declared in FUNCTION.H:815. NOP on Linux;
//   the network reconnect UI is not operational without a WIN32 build.
//
// Reconnect_Modem — declared in FUNCTION.H:824. Returns 0 (failure)
//   to match the null-modem absent path that callers already guard
//   with a failure branch.

void Net_Reconnect_Dialog(int /*reconn*/, int /*fresh*/,
                           int /*oldest_index*/, unsigned long /*timeval*/)
{
}

int Reconnect_Modem(void)
{
    return 0;
}
