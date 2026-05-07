# Win32 / DOS / project stub headers

These headers exist purely to let the preprocessor find names like
`<windows.h>`, `<objbase.h>`, `<dos.h>` so that `cc1plus` advances past
include resolution and into real C++ parse errors. They are loaded only
when nothing earlier in the include path provides the name.

Rules:

- **Declarations only.** No implementations. No type definitions unless
  required to satisfy a parser (e.g. forward `struct`s referenced by
  pointer in upstream headers). The point is to expose the next layer
  of errors, not to silently make broken code "compile".
- **No system header pollution.** Stubs must not include `<sys/...>` or
  glibc internals that could change behaviour for downstream code.
- **Empty is best.** If a file just needs to exist, leave it empty.

Replacing these with real ports happens later — search for `TIM-` ticket
references in commits / issues for the roadmap.
