// Toolchain smoke test for the CnC RedAlert Linux port.
//
// Prints compile-time facts about the host C++ toolchain so we can confirm
// (a) C++17 is actually selected, and (b) the LP64 / sizeof-long landmine
// flagged by the porting brief (TIM-2) is real and consistent on this host.

#include <cstddef>
#include <cstdint>
#include <iostream>

int main() {
    std::cout << "CnC RedAlert Linux toolchain smoke test\n";
    std::cout << "  __cplusplus       : " << __cplusplus << "\n";
#if defined(__clang__)
    std::cout << "  compiler          : clang " << __clang_major__ << "." << __clang_minor__ << "." << __clang_patchlevel__ << "\n";
#elif defined(__GNUC__)
    std::cout << "  compiler          : gcc " << __GNUC__ << "." << __GNUC_MINOR__ << "." << __GNUC_PATCHLEVEL__ << "\n";
#else
    std::cout << "  compiler          : unknown\n";
#endif
    std::cout << "  sizeof(void*)     : " << sizeof(void*) << "\n";
    std::cout << "  sizeof(long)      : " << sizeof(long) << "\n";  // NOLINT: intentional LP64 demo
    std::cout << "  sizeof(long long) : " << sizeof(long long) << "\n";
    std::cout << "  sizeof(int)       : " << sizeof(int) << "\n";

    // Sanity: the upstream Win32 source assumes DWORD == 32 bits regardless of
    // sizeof(long). On LP64 Linux, sizeof(long) == 8, which is exactly why a
    // compat shim is needed before the port can compile.
    static_assert(sizeof(std::uint32_t) == 4, "uint32_t must be 32 bits");
    static_assert(sizeof(std::uint64_t) == 8, "uint64_t must be 64 bits");

    std::cout << "Toolchain OK.\n";
    return 0;
}
