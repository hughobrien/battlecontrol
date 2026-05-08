// TIM-151 Stop_Execution stub.
//
// KEYFBUFF.ASM originally contained a `_Stop_Execution` routine that
// halted execution (x86 real-mode mechanism). KEY.CPP and KEYBOARD.CPP
// both declare it `extern "C"` and call it on a bad-state escape path
// that cannot fire under the current runnable subset. NOP body.

extern "C" void Stop_Execution(void)
{
}
