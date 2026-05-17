# TIM-724 — Acceptance evidence

After [TIM-763](/TIM/issues/TIM-763) (PR #152, the 1-byte `je → jmp` patch at
`0x41128a` that skips the NULL preview-frame copy), `scripts/wine-gdi-m1.sh`
now drives `C&C95.EXE` from boot through the side-select dialog into the
live GDI Mission 1 map.

## Acceptance criteria — all met

| # | Criterion                                                  | Status | Evidence |
|---|------------------------------------------------------------|--------|----------|
| 1 | `wine-gdi-m1.sh` navigates main menu → GDI Mission 1 start | ✅ | side-select → click GDI → strategic map → mission start, captured in `e2e/tim724/gdi-m1/` |
| 2 | Frame 500 shows non-black terrain (GDI mission terrain)    | ✅ | `docs/tim724/td-gameplay-frame500.png` — green GDI terrain, units, sidebar UI |
| 3 | Script exits cleanly with return code 0                    | ✅ | `bash scripts/wine-gdi-m1.sh` → `EXIT 0` |
| 4 | ≥3 gameplay screenshots in `e2e/report/data/` or `docs/tim-NNN/` | ✅ | `td-gameplay-frame100.png` / `…-frame250.png` / `…-frame500.png` in `docs/tim724/` |

## Run summary

Single `bash scripts/wine-gdi-m1.sh` invocation from the repo root,
`Wine 10.0`, `cnc-ddraw` (windowed, GDI renderer), `Xvfb :92 1024x768x24`,
`openbox`. Eight screenshots captured progressing through:

- `t05-initial`  — side-select menu (`110 590 B / 4 600 colours`)
- `t10-pre-side` — same menu, post-dismiss (`110 103 B / 4 604 colours`)
- `t15-post-gdi-click` — click registered, still side-select (`111 701 B / 4 771 colours`)
- `t25-briefing-advance` — transition / strategic map (`24 102 B / 1 547 colours`)
- `t35-post-map`  — mission load (`24 577 B / 1 573 colours`)
- `t45-frame100`  — early gameplay (`25 725 B / 1 668 colours`)
- `t60-frame250`  — mid gameplay (`32 403 B / 1 860 colours`)
- `t90-frame500`  — gameplay frame 500 (`32 583 B / 1 868 colours`)

`wine.log` is empty — no faults; TD still alive at script exit.

## Patch chain (final SHA after this work)

```
td-focus-skip      → 53d1670fc412…
td-game-in-focus   → 460bf72d1844…
td-vqa-skip        → 5f0f37829a7d…
td-activateapp     → 46a6d902963e…
td-ddmode          → 46dc1eb4a811…
td-setcoop-hwnd    → 19ab8620eadf…
td-ioport          → 42664f2aa13f…
td-side-preview-skip → 700e61a8fba5… (TIM-763)
```

## Related work

- [TIM-708](/TIM/issues/TIM-708) — RA Wine OG Allied L1 gameplay (mirror)
- [TIM-711](/TIM/issues/TIM-711) — `scripts/wine-td.sh` boot-to-menu baseline
- [TIM-743](/TIM/issues/TIM-743) — TD-specific binary patches (focus / game-in-focus / vqa-skip / activateapp)
- [TIM-747](/TIM/issues/TIM-747) — `td-ddmode` + `td-setcoop-hwnd` + `td-ioport` (side-select renders)
- [TIM-763](/TIM/issues/TIM-763) — `td-side-preview-skip` (this issue's blocker fix)
