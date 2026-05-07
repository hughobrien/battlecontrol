# TIM-147 pass-43N link-side recovery measurement

Bonus measurement on top of pass-43N (compile floor 301/0/301).
Quantifies the link-time payoff from the 180 newly-defined symbols
across the four whole-body-elided TUs (CCDDE +19, STATS +34,
INTERNET +62, TCPIP +65) once cluster A1+A2+A3 graduates them.

## Method

1. Take the pass-43L baseline `.o` set (300 OK TUs, all built without -DWIN32).
2. Substitute the WIN32-enabled CCDDE.o, STATS.o, INTERNET.o, TCPIP.o.
3. Re-link with `g++ -no-pie -fuse-ld=bfd
   -Wl,--allow-multiple-definition -Wl,--warn-unresolved-symbols`.
4. Diff the unresolved-reference set against pass-43L (184) and 43M (158).

## Result

| Metric                           | 43L | 43M (CCDDE+STATS) | 43N (+INTERNET+TCPIP) |
|----------------------------------|----:|------------------:|----------------------:|
| undefined-reference sites        | 184 | 158               | 104          |
| unique unresolved symbols        |  57 |  53               | 34    |

## Files

- `link-warnonly.log` — re-link diagnostic.
- `objects.list` — the 300 .o paths with the four substituted targets.
- `undef-symbols.txt` — remaining unique unresolved symbols.
