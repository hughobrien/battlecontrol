---
name: redalert-modding
description: Use when modifying Red Alert game data — editing RULES.INI to change unit/structure/weapon stats, creating or patching scenario INI files, extracting or rebuilding MIX archives, editing conquer.eng strings, adding custom units/structures, or creating maps. Covers the original RA95 data formats, the battlecontrol project's tooling for working with them, and references to the ra.afraid.org modding archive.
version: 0.1.0
---

# Red Alert Modding Skill

> Reference for modding Red Alert (RA95) data files. Applies to both the original
> Win32 binary (under Wine) and the battlecontrol Linux/WASM port (which reads the
> same formats). Distilled from http://ra.afraid.org/ and the battlecontrol source.

---

## Phase 0 — Understand the data loading chain

RA95 loads data in this priority order (highest wins):

1. **Disk files** in the RA directory (e.g., `RULES.INI` on disk beats built-in defaults)
2. **MIX archives** in the RA directory — named embedded files shadow disk files
3. **Built-in defaults** compiled into `RA95.EXE`

To inspect game data, use the project's MIX extractor:

```bash
python3 scripts/extract_mix.py --list <path>/MAIN.MIX
python3 scripts/extract_mix.py --extract RULES.INI <path>/MAIN.MIX > rules_default.ini
python3 scripts/extract_mix.py --extract-all-known <path>/MAIN.MIX --out-dir ./extracted/
```

Key MIX files in the loading order (`Init_Secondary_Mixfiles()` in `REDALERT/INIT.CPP`):

| MIX file | Contents |
|----------|----------|
| `MAIN.MIX` | Scenario INIs, terrain, maps, local mix list |
| `CONQUER.MIX` | Language strings (`CONQUER.ENG`), EVA speech |
| `GENERAL.MIX` | General game assets (never cached) |
| `MOVIES1.MIX` / `MOVIES2.MIX` | VQA cinematics |
| `SCORES.MIX` | Music/scores |
| `SPEECH.MIX` | Speech audio |
| `SOUNDS.MIX` | Sound effects |
| `RUSSIAN.MIX` / `ALLIES.MIX` | Side-specific audio |
| `HIRES.MIX` / `LORES.MIX` | High/low resolution art |
| `LOCAL.MIX` / `REDALERT.MIX` | Localization, misc assets |
| `EXPAND.MIX` | Expansion data (Aftermath) |

---

## Phase 1 — Choose your modding target

| I want to… | Go to |
|------------|-------|
| Change unit/structure/weapon stats globally | §1 — RULES.INI |
| Change Aftermath-only stats | §2 — AFTRMATH.INI |
| Edit in-game text strings (unit names, briefings) | §3 — CONQUER.ENG |
| Create or edit a single-player mission | §4 — Scenario INI |
| Add a new unit or structure (swap graphics) | §5 — Custom Units/Structures |
| Change multiplayer settings | §6 — MPLAYER.INI / Scenario Lists |
| Extract or repack MIX archives | §7 — MIX Tools |
| Test my mod under the native/WASM port | §8 — Testing Mods |
| Find editors, guides, and community mods | §9 — Utilities & Documentation |

---

## §1 — RULES.INI

RULES.INI is an optional text file in the RA directory. If present, it overrides
built-in values. RA reads it once at startup.

### Loading code (for reference)

```cpp
// REDALERT/INIT.CPP:352-357
CCFileClass rulesFile("RULES.INI");
if (RuleINI.Load(rulesFile, false)) {
    Rule.Process(RuleINI);
}
```

### Key sections

| Section | Contents | Key parameters |
|---------|----------|----------------|
| `[General]` | Global gameplay multipliers | `CrateRadius`, `FirepowerMultiplier`, `ArmorMultiplier`, `SpeedMultiplier`, `BuildSpeed` |
| `[Audio]` | Sound/music settings | |
| `[AI]` | Computer AI parameters | `BuildSpeed`, `AttackDelay`, `PowerPlantsPerAction` |
| `[Powerups]` | Crate contents | |
| `[Land_Types]` | Terrain movement costs | |
| `[IQ]` | IQ level capabilities | |
| `[Themes]` | Music track definitions | |
| `[Objects]` | Object count limits | |
| `[Difficulty]` | Per-difficulty multipliers | `Easy`, `Medium`, `Hard` |
| `[Recharge]` | Superweapon recharge rates | |
| `[Units]` | Vehicle stats | `Cost`, `Speed`, `Armor`, `Health`, `Sight`, `Weapon`, `ROT`, `Crewed`, `Image`, `Prerequisite` |
| `[Infantry]` | Infantry stats | `Cost`, `Speed`, `Armor`, `Health`, `Sight`, `Weapon`, `Image` |
| `[Structures]` | Building stats | `Cost`, `Power`, `Armor`, `Health`, `Weapon`, `Sight`, `PowerOutput`, `Capturable`, `Repairable` |
| `[Weapons]` | Weapon definitions | `Damage`, `Range`, `ROF`, `Burst`, `Projectile`, `Warhead`, `Speed`, `Report` |
| `[Projectiles]` | Projectile types | `Speed`, `ROT`, `Arming`, `Image`, `AA`, `AG`, `Inaccurate`, `High` |
| `[Warheads]` | Damage modifiers per armor | `Verses` (comma-separated), `Conventional`, `Wall`, `Wood`, `Stone` |
| `[Animations]` | Visual effects | `Damage`, `LoopCount`, `Rate` |
| `[Veteran]` | Veteran/elite bonuses | `Firepower`, `Armor`, `Speed`, `ROF` |
| `[AllyUnits]` | Allied-specific unit overrides | Same keys as `[Units]` |
| `[SovietUnits]` | Soviet-specific unit overrides | Same keys as `[Units]` |
| `[AllyInfantry]` | Allied-specific infantry overrides | Same keys as `[Infantry]` |
| `[SovietInfantry]` | Soviet-specific infantry overrides | Same keys as `[Infantry]` |
| `[AllyVessels]` | Allied-specific naval overrides | |
| `[SovietVessels]` | Soviet-specific naval overrides | |

### Modding recipes (common changes)

| Change | INI entry |
|--------|-----------|
| Free units | `Cost=0` (in `[Units]`, `[Infantry]`, or `[Structures]`) |
| Instant build | `BuildSpeed=0` or `BuildTime=0` (per-unit) or `BuildSpeed=100` in `[General]` |
| Double damage globally | `FirepowerMultiplier=2.0` in `[General]` |
| Halve armor globally | `ArmorMultiplier=0.5` in `[General]` |
| Super-fast units | `Speed=999` (in `[Units]` or `[Infantry]`) |
| Infinite sight range | `Sight=999` |
| Remove prerequisite | `Prerequisite=none` |
| Mammoth Tank shoots Tesla | Replace weapon in `[Units]` → `MAMM` → `Weapon= TeslaZap` |
| Make any unit buildable | `Buildable=yes` |
| Change weapon damage | In `[Weapons]`, set `Damage=` higher/lower |
| Enable hidden units | Set `Buildable=yes` and remove `RequiredHouses=` / `ForbiddenHouses=` |

### Multiplayer note

All human players must have an identical `RULES.INI` for multiplayer to work.
The host's `RuleINI.Get_Unique_ID()` is sent to clients to verify matching files
(`REDALERT/WOL_GSUP.CPP:2346`).

### Download the base file

- Annotated original: http://ra.afraid.org/download.php/ini/rules.zip (17 KB)
- Expert (no comments): http://ra.afraid.org/download.php/ini/rules-e.zip (6 KB)

---

## §2 — AFTRMATH.INI

Aftermath expansion override. Loaded after RULES.INI if Aftermath is installed.
Provides multiplayer stats for the 7 new Aftermath units.

### Loading code

```cpp
// REDALERT/INIT.CPP:358-367
if (Is_Aftermath_Installed()) {
    CCFileClass aftermathFile("AFTRMATH.INI");
    if (AftermathINI.Load(aftermathFile, false)) {
        Rule.Process(AftermathINI);
    }
}
```

### Download

- http://ra.afraid.org/download.php/ini/aftrmath.zip (2 KB)

### Units added by Aftermath

| Unit/Structure | Internal name | Side |
|----------------|---------------|------|
| Demolition Truck | `TRUK` | Both |
| Mechanic | `MECH` | Allies |
| Tesla Tank | `TTNK` | Soviet |
| MAD Tank | `QTNK` | Soviet |
| Shock Trooper | `SHOK` | Soviet |
| Phase Transport | `PTRS` | Allies |
| Helicarrier (hidden) | — | Soviet |

The Helicarrier is hidden in Aftermath but can be enabled via `AFTRMATH.INI`.

---

## §3 — CONQUER.ENG (Game Strings)

CONQUER.ENG contains all in-game text: unit names, button labels, EVA announcements,
briefing text, etc. It's stored in `CONQUER.MIX` by default, but a standalone file
in the RA directory takes priority.

### Loading code

```cpp
// REDALERT/INIT.CPP:3636-3647
RawFileClass strings("CONQUER.ENG");
if (strings.Is_Available()) {
    SystemStrings = new char[strings.Size()];
    strings.Read((void*)SystemStrings, strings.Size());
} else {
    SystemStrings = (char const *)MFCD::Retrieve(Language_Name("CONQUER"));
}
```

**Aftermath v2.00 note:** The startup code explicitly deletes `conquer.eng` from disk
if found, since Aftermath's MIX files provide the string overrides.

### Editing tools

- **C&C Names File Editor v1.03** — http://ra.afraid.org/download.php/utilities/RA_names_editor.zip (DOS)
- **Ingame Strings Editor** — http://ra.afraid.org/download.php/utilities/ingstr12.exe (Windows)

Both edit the `conquer.eng` format. The Names File Editor handles stable renaming
without causing game instability.

### String format

Strings are stored as null-terminated C strings, one after another. Labels reference
them by index. Editing with a hex editor is possible but error-prone; prefer the
tools above.

---

## §4 — Scenario INI Files

Each single-player mission is defined by a `.INI` file embedded in `MAIN.MIX`.
Scenario INIs override game rules for that specific mission.

### Naming convention

```
SC{player}{scenario}{difficulty}{variant}.INI
```

| Position | Meaning | Values |
|----------|---------|--------|
| 0-1 | Prefix | `SC` (always) |
| 2 | Side | `G` = Allies/Greece, `U` = USSR/Soviet, `M` = Multiplayer, `A` = Ant missions |
| 3-4 | Number | `01`–`99` (or alphanumeric for Aftermath scenarios) |
| 5 | Difficulty | `E` = Easy, `M` = Medium, `D` = Difficult |
| 6 | Variant | `A`, `B`, `C`, `D`, or `L` for campaign branches |

**Examples:**
- `SCG01EA.INI` — Allied Mission 1 Easy
- `SCU01EA.INI` — Soviet Mission 1 Easy
- `SCG05EB.INI` — Allied Mission 5 Easy variant B
- `SCM008EA.INI` — Multiplayer map 8

### Sections

| Section | Purpose | Key fields |
|---------|---------|------------|
| `[Basic]` | Core metadata | `Name`, `Player`, `Intro`, `Brief`, `Win`, `Lose`, `Action`, `Theme`, `Percent`, `CarryOverMoney`, `EndOfGame`, `SkipScore`, `SkipMapSelect`, `CivEvac`, `OneTimeOnly`, `TruckCrate`, `NoSpyPlane`, `NewINIFormat` |
| `[Briefing]` | Briefing text | Multi-line text block |
| `[General]` | Rules override | Same keys as RULES.INI `[General]` |
| `[Recharge]` | Superweapon recharge | |
| `[AI]` | AI settings | `BuildSpeed`, team compositions |
| `[Powerups]` | Crate settings | |
| `[IQ]` | IQ levels | |
| `[Objects]` | Object limits | |
| `[Difficulty]` | Difficulty multipliers | |
| `[Map]` | Map layout | Cell-by-cell terrain data |
| `[Houses]` | Per-house config | `Money`, `Units`, `Buildings`, `Edge`, `Ally`, `Player`, `Color`, `IQ`, `TechLevel` |
| `[TeamTypes]` | AI team definitions | `Name`, `Veteran`, `Reinforce`, `Prebuild`, `Recruiter`, `IsBaseDefense`, `IsSuicide`, `Max`, `TechLevel`, `Class`, `Group`, `Units`, `Waypoints` |
| `[TriggerTypes]` | Event/action triggers | `Name`, `Event`, `Action`, `Team` |
| `[Terrain]` | Terrain objects | Trees, rocks, etc. |
| `[Units]` | Vehicle placements | `Owner`, `Health`, `Direction`, `Mission`, `Location` |
| `[Aircraft]` | Aircraft placements | |
| `[Vessels]` | Naval placements | |
| `[Infantry]` | Infantry placements | |
| `[Buildings]` | Building placements | |
| `[Base]` | AI base building plans | Building type + count for computer players |
| `[Overlay]` | Tiberium/ore placement | |
| `[Smudge]` | Crater/scorch marks | |
| `[Waypoints]` | Path/route waypoints | |
| `[CellTriggers]` | Cell-based triggers | |

### Extracting and patching scenarios

Use the project's scenario patching tool:

```bash
# Extract a scenario from MAIN.MIX
python3 scripts/extract_mix.py --extract SCG02EA.INI /path/to/MAIN.MIX

# Apply patches (if ra-scenario-patch.py supports your format)
python3 scripts/ra/ra-scenario-patch.py --ini SCG02EA.INI --patch my-changes.ini
```

### Campaign downloads

Custom campaigns and missions from ra.afraid.org:
- http://ra.afraid.org/html/downloads/missions.html (9 pages of user missions)
- http://ra.afraid.org/html/downloads/campaigns.html (full campaigns)

---

## §5 — Custom Units and Structures

"New" units in RA95 are actually existing units with swapped graphics and
overridden characteristics via `RULES.INI`. They typically include:

1. A `RULES.INI` snippet with the unit's new stats
2. A `.MIX` file with new art (the `Image=` tag points to the internal name in the MIX)
3. New icon art (usually `.SHP` or `.PCX` in `HIRES.MIX` / `LORES.MIX`)

### Installation

```
Unzip into RA directory → RULES.INI + MIX files override the originals
```

### Where to find user-made units

- http://ra.afraid.org/html/downloads/units.html (6 pages, 10s of units)
- http://ra.afraid.org/html/downloads/structures.html (new buildings)
- http://ra.afraid.org/html/downloads/mods.html (4 pages of total conversions)

### Notable mods

| Mod | Size | Description |
|-----|------|-------------|
| Aftermath Wars v3.0b | 3.4 MB | New units: Laser Trooper, Cyborg, Hover Carryall |
| Armageddon v4 | 5.9 MB | Total conversion: Scrin invasion, TS/RA2 graphics |
| BadRA v4.99 | 3.4 MB | 40+ new units, Plasma Tech, Tesla Drone |
| CnC in RA v2.10 | 402 KB | C&C units in RA (Chemical Soldier, Orca, Stealth Tank) |
| Desert Storm | 2.0 MB | Gulf War total conversion |

---

## §6 — MPLAYER.INI and Scenario Lists

### MPLAYER.INI

Controls Aftermath multiplayer settings:

| Key | Effect |
|-----|--------|
| `Credits` | Starting money |
| `Bases` | Whether players start with MCVs |
| `Units` | Starting units |
| `Crates` | Crate availability |
| `OreRegeneration` | Ore respawn rate |
| `TechLevel` | Maximum tech level available |

Download: http://ra.afraid.org/download.php/ini/mplayer.zip (0.3 KB)

### Scenario packet files

Human-readable maps for each add-on:

| File | Content |
|------|---------|
| `MISSIONS.PKT` | All scenarios |
| `CSTRIKE.PKT` | Counterstrike scenarios |
| `AFTMATH.PKT` | Aftermath scenarios |

These are read by `REDALERT/SESSION.CPP` to build the scenario selection menus.

---

## §7 — MIX Tools

### Project tool: extract_mix.py

`scripts/extract_mix.py` is a standalone Python MIX extractor that handles both
classic and extended (digest/encrypted-flag) formats.

```bash
# List contents
python3 scripts/extract_mix.py --list <path>/MAIN.MIX

# Extract specific file
python3 scripts/extract_mix.py --extract RULES.INI <path>/MAIN.MIX > rules.ini

# Extract all known RA filenames
python3 scripts/extract_mix.py --extract-all-known <path>/MAIN.MIX --out-dir ./mix_extracted/
```

### MIX header format

```
struct FileHeader {           // packed (6 bytes on disk)
    short count;              // number of embedded files
    int   size;               // total data size after header
};

struct SubBlock {
    int CRC;                  // Westwood CRC32 of uppercased filename
    int Offset;               // offset from end of header
    int Size;                 // file size
};
```

> **LP64 note:** On GCC, `FileHeader` must be `__attribute__((packed))` to avoid
> padding `short` + `int` to 8 bytes instead of 6 (`REDALERT/MIXFILE.H`, TIM-173).

### CRC algorithm

```python
def ww_crc32(name):
    crc = 0
    for ch in name.upper().encode('ascii'):
        crc = ((crc << 1) | (crc >> 31)) + ch
    return crc & 0xFFFFFFFF
```

### Obtaining MIX files

MIX files are part of the original game data and must be provided by the user
(from their CnC Remastered Collection Steam install, original CD, or the
freeware download at http://ra.afraid.org/html/ra/download.html).

---

## §8 — Testing Mods

### Under Wine

```bash
# Place mod files in the Wine RA directory
cp RULES.INI "$WINEPREFIX/drive_c/Westwood/RedAlert/"
cp mymod.mix "$WINEPREFIX/drive_c/Westwood/RedAlert/"

# Run the game
wine RA95.EXE
```

### Under the native Linux port

```bash
# Set RA_BASEDIR to point at your game data
export RA_BASEDIR=/path/to/ra-data/

# Add mod files on top (they shadow MIX contents)
cp RULES.INI "$RA_BASEDIR/"

# Build and run
build_native(target: "ra")
./build/ra/ra
```

### Under WASM

Mod files can be injected via MEMFS in the preloader. See
`wasm/preloader.js` for the autostart/scenario flag mechanism.

### Autostart + Scenario override

For testing a specific mission with a mod:

```bash
# Native: use RA_AUTOSTART
RA_AUTOSTART=1 RA_AUTOSTART_SCENARIO=SCU01EA.INI ./build/ra/ra

# WASM: add URL params
# http://localhost:8000/ra.html?autostart=1&scenario=SCU01EA
```

---

## §9 — Utilities & Documentation

### Essential editors

| Tool | Purpose | OS | URL |
|------|---------|----|-----|
| R.A.C.K. Editor v1.0 Beta 4 | Scenario editor (most popular) | Windows | http://ra.afraid.org/download.php/utilities/rack10b4.zip |
| R.A.R.E. v1.0 | Rules.ini editor | Windows | http://ra.afraid.org/download.php/utilities/rarev1_0.exe |
| Red Alchemist Pro 4.0 | Best free RULES.INI editor (reg: `Name=Freebie, Pass=332297218`) | Windows | http://ra.afraid.org/download.php/utilities/alchemist.exe |
| Red Maximus Editor | Comprehensive RULES.INI editor | Windows | http://ra.afraid.org/download.php/utilities/rm10rl2.zip |
| RedEdit 98 | All-in-one RA editor | Windows | http://ra.afraid.org/download.php/utilities/re98.exe |
| RA Scenario Editor v1.25 | Best mission editor, supports CS + Aftermath | Windows | http://ra.afraid.org/download.php/utilities/raed125.zip |
| Quick-n-Dirty Scenario Editor | DOS scenario editor | DOS | http://ra.afraid.org/download.php/utilities/qnd.zip |
| RA Build v4.0 | Place buildings/units/infantry on maps, create missions | Windows | http://ra.afraid.org/download.php/utilities/rabuild4.zip |
| Red Alert Terrain Editor | Official Westwood map editor | Windows | http://ra.afraid.org/download.php/utilities/ra_ted.zip |
| Mission Annotater v1.3 | Decompiles scenario INI → annotated `.ANN` file | DOS | http://ra.afraid.org/download.php/utilities/rama.zip |
| C&C Names File Editor v1.03 | conquer.eng editor | DOS | http://ra.afraid.org/download.php/utilities/RA_names_editor.zip |
| Ingame Strings Editor | conquer.eng + rules.ini | Windows | http://ra.afraid.org/download.php/utilities/ingstr12.exe |
| RULES.INI Extractor | Extract built-in defaults from RA95.EXE | Windows | http://ra.afraid.org/download.php/utilities/rulesextractor.zip |
| Unit Creator | Create new units with graphics (needs RAL library) | Windows | http://ra.afraid.org/download.php/utilities/unit_creator.exe |
| DirectDraw Compatibility Tool | Fix color palette on modern Windows | Windows | http://ra.afraid.org/download.php/utilities/DD_Compatibility_Tool.zip |

### MIX tools

| Tool | Purpose | OS | URL |
|------|---------|----|-----|
| XCC Utilities | Premier MIX editor suite: Mixer, MIX Editor, AV Player, TMP Editor | Windows | http://ra.afraid.org/download.php/utilities/XCC_Utilities.zip |
| RA-MIXer v5.1 OR3 | MIX viewer/creator, play CS+AM without CD, create MIX files | DOS | http://ra.afraid.org/download.php/utilities/ramix513.zip |
| VQA-AVI2 v1.35 | VQA ↔ AVI converter, AUD extraction, MIX → ZIP | Windows | http://ra.afraid.org/download.php/utilities/vqa-avi2.zip |
| Red Horizon Utilities v0.30 | Java converter for SHP, PAL, VQA, and Dune 2 formats | Windows/Java7 | http://ra.afraid.org/download.php/utilities/RedHorizon_Utilities_030.zip |
| Red Alert Sound Ripper | Extract sounds from MIX files | DOS | http://ra.afraid.org/download.php/utilities/ra_rip.zip |

### Palettes and media

| Tool | Purpose | OS | URL |
|------|---------|----|-----|
| Red Alert Pallets | Complete palette format reference (Raw, NeoPaint, PSP) | n/a | http://ra.afraid.org/download.php/utilities/rapal.zip |
| Purple Pallets | Palette conversion tool (prevent invisibility errors) | Windows | http://ra.afraid.org/download.php/utilities/purp_pal.zip |
| RA Cameo Creator | Template for unit icon cameos | Windows | http://ra.afraid.org/download.php/utilities/ra1cameoeditor.zip |
| C&C Animation | Play VQA videos, screenshot frames | DOS | http://ra.afraid.org/download.php/utilities/cc_anim.zip |
| Red Alert Movie Player v1.1 | Watch all RA movies, take screenshots | DOS | http://ra.afraid.org/download.php/utilities/ramp.zip |

### Network / misc

| Tool | Purpose | OS | URL |
|------|---------|----|-----|
| Westwood Chat Server Emulator | Java-based WWChat server for online play | Cross-platform/Java5 | http://ra.afraid.org/download.php/utilities/java_ra1_server.zip |
| RA Setup Manager v0.98 | Install helper for Windows XP | Windows | http://ra.afraid.org/download.php/utilities/red-alert_manager_0.98.exe |
| Map QuickViewer | View Westwood maps | Windows | http://ra.afraid.org/download.php/utilities/quickview.zip |

### Key documentation downloads

| Document | Content | URL |
|----------|---------|-----|
| `rainfo.zip` | INI file reference for missions/maps | http://ra.afraid.org/download.php/docs/rainfo.zip |
| `racg110.zip` | Single-player mission creation guide | http://ra.afraid.org/download.php/docs/racg110.zip |
| `raspmct.zip` | Step-by-step mission creation tutorial | http://ra.afraid.org/download.php/docs/raspmct.zip |
| `mm_guid.zip` | MegaMap (126×126) creation guide | http://ra.afraid.org/download.php/docs/mm_guid.zip |
| `uc_guide.zip` | Unit creation guide | http://ra.afraid.org/download.php/docs/uc_guide.zip |
| `ra_manual.zip` | Original Red Alert handbook scan (3.1 MB) | http://ra.afraid.org/download.php/docs/ra_manual.zip |
| `am_manual.zip` | Aftermath manual scan (624 KB) | http://ra.afraid.org/download.php/docs/am_manual.zip |
| `rabugs.zip` | Known bugs and cheats list | http://ra.afraid.org/download.php/docs/rabugs.zip |
| `rafaq19.zip` | Official Westwood FAQ | http://ra.afraid.org/download.php/docs/rafaq19.zip |
| `rakey_remap.zip` | Keyboard remapping guide | http://ra.afraid.org/download.php/docs/rakey_remap.zip |
| `raug_v5.zip` | Ultimate Guide v5 — unit creation, strategies, codes (324 KB) | http://ra.afraid.org/download.php/docs/raug_v5.zip |
| `terrain.zip` | Official Terrain Editor FAQ | http://ra.afraid.org/download.php/docs/terrain.zip |

### INI downloads

| File | Purpose | URL |
|------|---------|-----|
| `rules.zip` | Original annotated RULES.INI | http://ra.afraid.org/download.php/ini/rules.zip |
| `rules-e.zip` | Expert RULES.INI (no comments) | http://ra.afraid.org/download.php/ini/rules-e.zip |
| `aftrmath.zip` | Default Aftermath.ini | http://ra.afraid.org/download.php/ini/aftrmath.zip |
| `mplayer.zip` | Default MPLAYER.INI | http://ra.afraid.org/download.php/ini/mplayer.zip |
| `tutorial.zip` | TUTORIAL.INI (text triggers) | http://ra.afraid.org/download.php/ini/tutorial.zip |
| `mission1.zip` | MISSION.INI (briefing text) | http://ra.afraid.org/download.php/ini/mission1.zip |
| `mission2.zip` | MISSIONS.PKT (scenario names) | http://ra.afraid.org/download.php/ini/mission2.zip |
| `csrules.zip` | Counterstrike units in normal RA (user mod) | http://ra.afraid.org/download.php/ini/contrib/csrules.zip |
| `moreunit.zip` | Aftermath hidden unit unlocker | http://ra.afraid.org/download.php/ini/contrib/moreunit.zip |

---

## Reference

- ra.afraid.org mods: http://ra.afraid.org/html/downloads/mods.html
- ra.afraid.org units: http://ra.afraid.org/html/downloads/units.html
- ra.afraid.org structures: http://ra.afraid.org/html/downloads/structures.html
- ra.afraid.org INI files: http://ra.afraid.org/html/downloads/ini.html
- ra.afraid.org missions: http://ra.afraid.org/html/downloads/missions.html
- ra.afraid.org documentation: http://ra.afraid.org/html/downloads/docs.html
- ra.afraid.org utilities: http://ra.afraid.org/html/downloads/utilities.html
- Westwood archive (original docs): http://ra.afraid.org/ww_archive/games/redalert/redalert.html

### Project source references

| File | What it tells you |
|------|-------------------|
| `REDALERT/INIT.CPP` | RULES.INI/AFTRMATH.INI loading, MIX sequence, command line parsing |
| `REDALERT/SCENARIO.CPP` | Scenario INI reading, naming convention, section parsing |
| `REDALERT/RULES.CPP` / `RULES.H` | `Rule` class — how all INI sections deserialize |
| `REDALERT/MIXFILE.H` / `MIXFILE.CPP` | MIX file format, cache, retrieval |
| `REDALERT/CCFILE.H` | CCFileClass — MIX-aware file I/O |
| `scripts/extract_mix.py` | Python MIX extractor |
| `scripts/ra/ra-scenario-patch.py` | Scenario patching tool |
| `skills/ra-archive/SKILL.md` | Related: RA versions, trainers, fixes |

### Related skills

- `skills/wine-testing/SKILL.md` — Testing mods under Wine
- `skills/native-build/SKILL.md` — Testing mods with native Linux build
- `skills/ra-archive/SKILL.md` — RA version identification, patches, no-CD fixes
