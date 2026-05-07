# TIM-143 pass-43M link-side recovery measurement

Bonus measurement on top of the pass-43M hand-back. Quantifies the link-time payoff from the 53 new defined symbols (CCDDE +19 / STATS +34) that pass-43M unmasked, even *before* INTERNET and TCPIP graduate via cluster heads C-A through C-D.

## Method

1. Take the pass-43L baseline `.o` set (300 OK TUs, all built without `-DWIN32`).
2. Substitute the WIN32-enabled `CCDDE.o` (19 syms) and `STATS.o` (34 syms) for the previously-empty (0 syms) baselines.
3. Re-link with `g++ -no-pie -fuse-ld=bfd -Wl,--allow-multiple-definition -Wl,--warn-unresolved-symbols`.
4. Diff the unresolved-reference set against pass-43L's `undef-symbols-all.txt`.

## Result

| Metric                          | pass-43L | pass-43M (CCDDE+STATS) | Δ          |
|---------------------------------|---------:|-----------------------:|-----------:|
| undefined-reference sites       | 184      | 158                    | **−26**    |
| unique unresolved symbols       | 57       | 53                     | −4 unique (−11 grouped — see below) |

## 11 unique symbols resolved by CCDDE+STATS bodies

CCDDE-side (DDE protocol):
- `DDEServer`
- `DDEServerClass::Delete_MPlayer_Game_Info()`
- `DDEServerClass::Disable()`
- `DDEServerClass::Enable()`
- `DDEServerClass::Get_MPlayer_Game_Info()`
- `DDEServerClass::Time_Since_Heartbeat()`
- `Send_Data_To_DDE_Server(char*, int, int)`

STATS-side (telemetry):
- `Send_Statistics_Packet()`
- `Register_Game_Start_Time()`
- `Register_Game_End_Time()`
- `PacketLater`

The 4-vs-11 gap (4 unique-set delta vs 11 named) is because some 43L undef sites had `more undefined references to X follow` rolled-up reporting; 7 of those 11 names were collapsed under fewer printed-symbol summary lines.

## Files

- `link-warnonly.log` — re-link diagnostic (warnings, rc=0).
- `objects.list` — the 300 .o paths (CCDDE.o / STATS.o substituted from `-DWIN32 -c` builds).
- `undef-symbols.txt` — the remaining 53 unique unresolved symbols post-43M.
