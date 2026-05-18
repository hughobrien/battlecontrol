---
name: ra-archive
description: Reference skill for Red Alert versions, patches, trainers, saved games, known bugs, and compatibility fixes. Use when setting up or instrumenting the Win32 RA95.EXE under Wine — identifying which version is installed, applying no-CD or compatibility patches, finding trainers for automation, loading pre-made saved games, or diagnosing crashes and rendering issues on modern systems.
version: 0.1.0
---

# RA Archive Reference

> Distilled from http://ra.afraid.org/ — the largest Red Alert fan site (2000–2020).
> Covers versions v1.04 through v3.03, official/unofficial patches, trainers, saved
> games, known bugs, and modding utilities relevant to Wine automation.

---

## Phase 0 — Check installed RA version

The version is displayed at the bottom of the main menu screen after the game loads.

RA95.EXE's embedded version string can also be checked:

```bash
# Show PE version info
wine --version  # requires wine
strings RA95.EXE | grep -i "version\|1.04\|1.07\|1.08\|2.00\|3.03"
```

| Version | Identity | EXE name | Notes |
|---------|----------|----------|-------|
| v1.04 | Original CD release | `RA95.EXE` | DOS + Win95 versions exist |
| v1.06 | Rumored, never confirmed | — | May not exist |
| v1.07 | Counterstrike add-on CD | `RA95.EXE` | Comes on Counterstrike CD |
| v1.08 | Free official patch | `RA95.EXE` | Applies to v1.04 or v1.07 |
| v2.00 | Aftermath add-on CD | `RA95.EXE` | Adds mega maps + new units |
| v3.00 Beta | Westwood beta testers only | — | Superseded by v3.03 |
| v3.03 | Final beta patch | `RA95.EXE` | 4-player internet, integrated Westwood Chat |

> **Wine target version:** The battlecontrol project targets **v2.00 (Aftermath)** for
> parity testing. v3.03 is available if TCP/IP LAN is needed.

---

## §1 — Official Patches

Patches hosted at ra.afraid.org (extract with PeaZip or similar):

| Patch | File | Size | Applies to | Effect |
|-------|------|------|------------|--------|
| v1.07 (Counterstrike) | `cspatch.zip` | 1157 KB | v1.04 | Graphics fixes, new missions, Giant Ant missions |
| v1.08 | `ra108usp.exe` | 1157 KB | v1.04/v1.07 | Free substitute for CS; adds Name tags, more tutorial.ini messages |
| v3.03 | `ra303eng.zip` | 2294 KB | v1.04+ | 4-player internet, integrated chat, ranking, improved explosions/audio |

Base URLs (construct as needed):
- `http://ra.afraid.org/download.php/patches/cspatch.zip`
- `http://ra.afraid.org/download.php/patches/ra108usp.exe`
- `http://ra.afraid.org/download.php/patches/ra303eng.zip`

---

## §2 — Unofficial Patches / Fixes

### §2.1 — No-CD Patches

Required for running RA under Wine without physical CD. Select by version:

| Version | File | Notes |
|---------|------|-------|
| v1.04 | `ra95nocd_104.zip` | Original RA |
| v1.07 (CS) | `ra95nocd_107cs.zip` | Counterstrike |
| v1.08 | `ra95nocd_108.zip` | — |
| v2.00 (AM) | `ra95nocd_200am.zip` or `ra95am_nocd.zip` (16-bit R.I.S.C.) | Aftermath |
| v3.03 | `ra95nocd_303.zip` | 4-player internet |

Base URL: `http://ra.afraid.org/download.php/fixes/ra95nocd_*.zip`

### §2.2 — Multi-core / Hyper-threading Affinity Fix

RA95 crashes on multi-core CPUs (title screen or during gameplay). Fix:

```
Download: http://ra.afraid.org/download.php/fixes/hotfix/ra95_affinityfix.zip
```

Extract into RA directory. Start with `ra95.bat` instead of `ra95.exe`.
The `.bat` sets processor affinity to a single core.

### §2.3 — Windows Vista/7 Color Fix

Color palette corruption on Aero/WDDM. Two approaches:

1. **DirectDraw Compatibility Tool** (recommended):
   http://ra.afraid.org/download.php/utilities/DD_Compatibility_Tool.zip
   Point at RA95.EXE, click apply. Works on 32/64-bit, all versions.

2. **Registry fix**: http://ra.afraid.org/download.php/fixes/hotfix/ra95_colorfix.zip

### §2.4 — TCP/IP LAN Patch (v3.03 only)

Replaces IPX with UDP for LAN play on modern Windows (also relevant for Wine):

```
Download: http://ra.afraid.org/download.php/fixes/hotfix/ra303_tcpip_lan.zip
```

Requires v3.03 patch installed first.

### §2.5 — Mega Map Patches

Pre-v2.00 versions need a patch to support 126×126 maps:

| Version | File |
|---------|------|
| v1.04 | `ra95mmfix_104.zip` |
| v1.07 (CS) | `ra95mmfix_107.zip` |
| v1.08 | `ra95mmfix_108.zip` |

v2.00 (Aftermath) has built-in mega map support.

---

## §3 — Trainers

Useful for automation (injecting money, instant build, etc.). All single-player only.

| Trainer | Version | File | Size | Notes |
|---------|---------|------|------|-------|
| DOS Trainer | DOS (all) | `ra-trn2.zip` | 19 KB | Building speed, credits |
| RA Money Patch | All (incl. AM) | `ramoney.zip` | 11 KB | Gives 12000 credits in any mission/skirmish |
| Final RA Trainer | v1.04 | `ratrn2.zip` | 163 KB | Win95 only |
| Super RA Trainer | v1.04/1.08PE/2.00 | `ratrn.zip` | 25 KB | Best all-round trainer |
| Counterstrike Trainer | v1.07 | `cstrn.zip` | 268 KB | Alt-tab style trainer |
| Aftermath Trainer | v2.00 | `amtrn.zip` | 27 KB | |
| RA Trainer +8 | v2.00 | `ra1trainer_117.zip` | 231 KB | Money, max power, instant build, full map reveal, instant special weapons, inf health/ammo |
| RA 3.03 Trainer +2 | v3.03 | `ra303trn.exe` | 409 KB | Archive password: `ra4ever`. False-positive malware detection (CheatEngine-based) |

Base URL: `http://ra.afraid.org/download.php/trainers/<file>`

> **Most useful for Wine automation:** RA Money Patch (`ramoney.zip`) for
> consistent starting credits, Super RA Trainer (`ratrn.zip`) for multi-version
> support, and RA Trainer +8 (`ra1trainer_117.zip`) for instant build + reveal.

---

## §4 — Saved Games

Saved games are stored as `Savegame.000`, `Savegame.001`, etc. in the RA directory.

Pre-made saved games exist for **all 14 Allied and 14 Soviet missions** across
three version families:

| Family | Allied prefix | Soviet prefix | Notes |
|--------|--------------|---------------|-------|
| DOS | `dosalyXX.zip` | `dossovXX.zip` | Mission 2–14 (mission 1 starts automatically) |
| Windows (1.04/1.08) | `allwinXX.zip` | `sovwinXX.zip` | |
| v3.03 | `303allXX.zip` | `303sovXX.zip` | Also includes Giant Ants missions 1–4 (`303ants1-4.zip`) |

`XX` = 02 through 14 (mission number).

Base URL: `http://ra.afraid.org/download.php/savedgames/<file>`

Custom saved games collection (v2.00 only):
`ftp://ra.afraid.org/pub/redalert/savedgames/custom`

---

## §5 — Known Bugs & Quirks

### Gameplay bugs

| Bug | Description | Relevance to automation |
|-----|-------------|------------------------|
| England/France stat bug | England has −10% armor (not +10%); France has −10% RoF | Affects skirmish benchmarks |
| Stuck infantry on walls | Selling structures can strand infantry on unwalkable terrain | May cause unit count mismatch |
| Walk on water | Infantry can walk on water via timed LST move-away | Obscure edge case |
| Free money on reload | Saving and reloading a mission respawns ore | Useful for marathon benchmarks |
| Tesla tank in skirmish | Start "Legacy of Tesla", abort, then skirmish has Tesla tanks | Automation trick |
| Secret ant missions | Hold Shift + right-click speaker icon on main menu (Counterstrike CD) | Easter egg, not useful |
| End credits | Click Westwood logo top-left | Visual landmark for screenshots |
| Mine detection via structure outline | Building outline turns red over mines | Debug aid |
| No-CD with v2.00 | Both `ra95nocd_200am.zip` (modern) and `ra95am_nocd.zip` (16-bit R.I.S.C.) exist | Choose modern version |

### Known crash triggers

1. **Multi-core CPU** → Title screen/gameplay crash. Fix: affinity fix (§2.2).
2. **Color corruption on Aero** → Blotchy palette. Fix: DD Compatibility Tool (§2.3).
3. **nVidia GPU freezes** → Reported intermittent freezes on nVidia hardware.
   Integrated Intel GPU works fine (but slower).
4. **16-bit thunking (THIPX16.DLL)** → Immediate exit on wow64. Fix: TCP/IP LAN patch
   (§2.4) or use a 32-bit Wine prefix.

### Multiplayer facts

| Feature | Details |
|---------|---------|
| Max players | 8 via IPX; 2 via modem/null-modem/internet (v1.04–2.00) |
| 4-player internet | v3.03 patch only |
| DOS ↔ Win95 compatible | Modem, IPX, null-modem all work cross-platform |
| Internet requires patch | Westwood Chat auto-update needed on connect |
| AI in skirmish | Up to 7 AI opponents, builds bases |

---

## §6 — Utilities

### Editors

| Tool | Description | OS |
|------|-------------|----|
| R.A.C.K. Editor v1.0 Beta 4 | Most popular RA editor. Set PC date to 1996 for Beta 3. Beta 4 is freeware + XP-compatible. | Windows |
| R.A.R.E. v1.0 | Red Alert Rules Editor — edit game characteristics via rules.ini | Windows |
| Quick-n-Dirty Scenario Editor | DOS scenario (not map) editor | DOS |
| C&C Names File Editor v1.03 | Edit `conquer.eng` for stable renaming | DOS |
| Ingame Strings Editor | Edit `conquer.eng` + `rules.ini` | Windows |

### Viewers / Converters

| Tool | Description | OS |
|------|-------------|----|
| C&C Animation | Play any VQA video outside the game; screenshot each frame | DOS |
| Map QuickViewer | View official Westwood maps | Windows |
| Map Viewer | View single/multiplayer maps | DOS |
| AUD Player v1.1 | Play RA/C&C audio files (requires RA-MIXer 5.x) | DOS |
| Original CnC Music in RA | Import C&C music into RA | DOS |
| Purple Pallets | Palette conversion utility | Windows |

### Documentation

| Document | Description |
|----------|-------------|
| `rainfo.zip` | INI file reference for mission/map creation |
| `racg110.zip` | Single-player mission creation guide |
| `raspmct.zip` | Step-by-step mission creation tutorial |
| `mm_guid.zip` | MegaMap (126×126) creation guide |
| `rabugs.zip` | Known bugs and cheats list |
| `rafaq19.zip` | Official Westwood FAQ |
| `rakey_remap.zip` | Keyboard remapping guide |
| `dossound.zip` | DOS sound configuration guide |
| `amm_guid.zip` | Aftermath missions guide |
| `antsguid.zip` | Secret ant missions guide |

---

## §7 — Screenshot Diagnostics (Wine)

When capturing RA under Wine, these image signatures help classify what's on screen
(from `skills/wine-testing/SKILL.md`):

| Size | Contents | Diagnosis |
|------|----------|-----------|
| 176 B (1-bit black) | wined3d no3d mode — NULL draw_texture | §2.6 |
| ~3.5 KB RGB, small gray area | cnc-ddraw loaded, game stuck on error dialog | §2.6 |
| ~5 KB RGB, gray dialog | "Insert CD" or blocking dialog | §2.6 |
| ~7 KB paletted, navy blue | Game close — CD label comparison failing | §2.6 |
| **47–88 KB paletted, 117–177 colors** | **Real game content — rendering correctly!** | §2.6 |

---

## §8 — Keyboard Reference (SendInput Automation)

Complete keyboard shortcuts for RA95. Critical for `ra-sendinput.exe` automation
under Wine — these are the keys DInput polls for.

### Unit commands (always active)

| Key | Action | Notes for automation |
|-----|--------|---------------------|
| `F9`–`F12` | Jump to bookmark location | Pre-save with Ctrl+F9–F12 |
| `Ctrl`+`F9`–`F12` | Save bookmark | 4 locations |
| `Ctrl`+`1`–`4` | Save selected units as team | Teams 1–4 |
| `1`–`4` | Select team | Re-centers view with Shift |
| `F` | Toggle formation | Units maintain relative positions |
| `G` | Guard mode | Aggressive auto-engage |
| `Ctrl`+`LMB` | Force fire | Attacks ground/square even without enemy |
| `Alt`+`LMB` | Force move / crush infantry | Tanks run over infantry |
| `X` | Scatter | Random dodge, 1 use per press |
| `S` | Stop | Stop all action |
| `Ctrl`+`Alt`+`LMB` | Escort / follow unit | Click target to tail |
| `Home` | Center view on selected unit | — |
| `H` | Jump to Construction Yard | Base return |
| `E` | Select everything visible | All units on screen |
| `N` | Cycle next unit | — |
| `Q` | Waypoints | Stack move orders (partially implemented) |

### Multiplayer only

| Key | Action |
|-----|--------|
| `A` | Ally with selected player's unit |
| `F1`–`F7` | Send message to player 1–7 |
| `F8` | Send message to all |
| `Esc` | Abort message entry |

### Mouse

| Action | Meaning |
|--------|---------|
| LMB drag | Band-box selection |
| LMB click (with Ctrl) | Force fire |
| LMB click (with Alt) | Force move / crush |
| LMB click (with Ctrl+Alt) | Escort / follow |

---

## §9 — RULES.INI Reference

`RULES.INI` is an optional text file placed in the RA directory that overrides
built-in game parameters. RA reads it once at startup. If absent, defaults are
used.

### How it works

- Place `RULES.INI` in the RA directory (same dir as `RA95.EXE`)
- Edit with any text editor (Wordpad, notepad, vim via Wine)
- Lines starting with `;` are comments
- Section headers in `[square brackets]`
- Each key = value pair overrides one parameter
- Backup as `RULES.ORG` to keep a known-good copy

### Where to get the base file

Download from: http://ra.afraid.org/html/downloads/ini.html
(A current RULES.INI with all default values.)

### Key sections

```
[General]       Global multipliers: CrateRadius, Speed, Power, etc.
[Audio]         Sound effects, music volume
[Units]         Unit stats: cost, speed, armor, weapon, sight range
[Infantry]      Infantry stats: cost, speed, health, weapon
[Structures]    Structure stats: cost, power, armor, build time
[Weapons]       Weapon definitions: damage, range, ROF, projectile
[Projectiles]   Projectile types: speed, image, arcing
[Animations]    Animation definitions: damage, loop count
[Veteran]       Veteran status bonuses: firepower, armor, speed
[AllyUnits]     Allied-specific unit overrides
[SovietUnits]   Soviet-specific unit overrides
[AllyInfantry]  Allied-specific infantry overrides
[SovietInfantry] Soviet-specific infantry overrides
```

### Automation uses

| Change | Effect | Section |
|--------|--------|---------|
| `CrateRadius=1.0` | Crate pick-up radius smaller | `[General]` |
| `FirepowerMultiplier=2.0` | Double all unit damage | `[General]` |
| `ArmorMultiplier=0.5` | Halve all armor | `[General]` |
| Cost=0 or BuildTime=0 | Free/instant units (per unit) | `[Units]`, `[Infantry]`, `[Structures]` |
| Speed=999 | Super-fast units | `[Units]`, `[Infantry]` |

> **No-CD caveat:** Some no-CD patches incorporate their own checks via the
> executable. RULES.INI changes are orthogonal — they work regardless of CD
> status.

### Multiplayer note

All human players in a multiplayer game must have an identical `RULES.INI` for
it to work. Mismatches cause errors at game start.

---

## Reference

- ra.afraid.org home: http://ra.afraid.org/
- Versions page: http://ra.afraid.org/html/ra/versions.html
- Official patches: http://ra.afraid.org/html/downloads/patches.html
- Unofficial patches/fixes: http://ra.afraid.org/html/downloads/fixes.html
- Trainers: http://ra.afraid.org/html/downloads/trainers.html
- Saved games: http://ra.afraid.org/html/downloads/savedgames.html
- Utilities: http://ra.afraid.org/html/downloads/utilities.html
- Documentation: http://ra.afraid.org/html/downloads/docs.html
- Cheats/bugs: http://ra.afraid.org/html/extra/cheats.html
- Linux/Wine guide: http://ra.afraid.org/html/extra/linuxra.html
- FAQ: http://ra.afraid.org/html/extra/faq.html
- Hotkeys: http://ra.afraid.org/html/ra/hotkeys.html
- RULES.INI info: http://ra.afraid.org/html/ra/rules_ini.html
- INI downloads: http://ra.afraid.org/html/downloads/ini.html
- Westwood archive mirror: http://ra.afraid.org/ww_archive/games/redalert/redalert.html
- Related skill: `skills/wine-testing/SKILL.md` (Wine capture/diagnostics)
- Related skill: `skills/parity-comparison/SKILL.md` (SSIM comparison)
