# SCR Autopilot 

An enhanced build of [PlaceReporter99's SCR Autopilot](https://github.com/PlaceReporter99/SCR-Autopilot)
for [Stepford County Railway](https://www.roblox.com/games/696347899/Stepford-County-Railway), rebuilt to survive an
unattended multi-hour shift.

The original reads the DriveGui and drives the train with `VirtualInputManager` key presses. This
build keeps that engine intact and adds ten self-contained blocks on top of it: anti-idle, a
dynamic braking point, a terminal buffer approach, platform alignment, automatic Next Leg, and the
watchdogs that keep a run alive at 4am.

> **Status: it works, and it is not finished.** It will drive a route unattended for hours. It will
> also occasionally stop a few studs short of where SCR wants and need a nudge. Everything known to
> be wrong is in [Known issues](#known-issues) — nothing is hidden.

---

## Requirements

- Stepford County Railway on Roblox
- A Lua executor. Developed and tested against **Opiumware on macOS**; anything with
  `VirtualInputManager`, `getgenv()` and `game:HttpGet` should work
- Nothing else. The script fetches the original's `RouteBuffers` table at runtime and needs no
  other dependency

## Quick start

1. Launch SCR and spawn in as a driver.
2. Execute [`scr_autopilot_overnight.lua`](scr_autopilot_overnight.lua) **once**.
3. Watch the Roblox developer console (**F9**) for the arming lines — `[brake] armed`,
   `[buffer] armed`, `[platform] armed` and so on. They appear over about 45 seconds as each block
   finds what it needs.

Do not stack instances. One execution per session; if something has gone wrong, exit Roblox
completely and start again.

---

## What each block does

| Block | What it is for |
|---|---|
| `antiafk` | `Player.Idled` plus a 600 s backup timer, nudging with `VirtualUser:ClickButton2()`. Never touches W/S/T/Q, so it cannot fight the driving. |
| `fixes` | Runaway-creep guard and a 1 s dedupe on repeated identical speed commands. |
| `braking` | The dynamic braking point. `SAFESTOPDISTANCE` is a fixed distance regardless of speed, which is nowhere near enough room on a 125 line — this puts a real curve ceiling on commanded speed. |
| `stophold` | Eases into a platform: 5 mph for 2 s before 0. Stands down at termini. |
| `whitelight` | Depot and shunt position lights. SCR swaps the aspect column out but leaves the old transparencies alone, so the original keeps reading a red that is not on screen and pins the train at 0. |
| `platform` | The alignment reflex. When SCR asks for the train to move further forward, rolls at 5 mph and stops the instant the doors actually open. |
| `longevity` | Print throttle, position-based stuck detection, defibrillator, and DriveGui rebuild detection with rebind. |
| `nextleg` | Clicks Next Leg on the Summary screen and waits for the distance label to become non-zero before kicking the driving loop. |
| `bufferstop` | The terminal approach. Reads the real distance to the buffer and steps down a fixed speed ladder, learning each platform's accepted stop point. |
| `bridge` | Mirrors every `_G.SCRxxx` control into `getgenv()`, because some executors do not share `_G` between executions. |

---

## How the train stops

Three numbers and one reflex. If a stop goes wrong it is one of these, and they are worth knowing
before you touch anything else.

**Stations.** `SAFESTOPDISTANCE = 0.2` and `SAFESTOPSPEED = 30` in the original section: line speed
until a fifth of a mile out, then 30, then the stop at the counter's zero. `braking` is what makes
that possible on a fast line — 0.2 miles is not enough room to lose 95 mph, so it starts the
deceleration much further out. Its `TARGET_SPEED` must stay equal to `SAFESTOPSPEED`.

**Not fully in the platform.** `platform` rolls forward at 5 mph and stops when the doors open.
Acceptance means the doors are *actually* open — loading, close the doors, ready to depart. The
banner reads "Unlock doors to begin loading passengers" at every stand, aligned or not, so it is
not evidence of anything.

**Termini.** `bufferstop` owns these completely, on its own ladder:

```
700 studs out   35 mph          90 studs   10 mph
500             30              45          7
350             25              18          5
240             20               0          3
150             15          arrived         0
```

A table rather than a formula, deliberately: a formula has to be trusted, a table can be read and
argued with. It **ignores the line speed limit** — this is the run into the last station and the
platform is the end of the line. What keeps that honest is a floor test (hard floor plus the
stopping distance of the speed actually being made) that **latches** once it fires, and contact
detection: a train told to move that does not move is a train against a buffer.

---

## Controls

Type these into your executor while the script is running. From a second tab use `getgenv().`
instead of `_G.` — that is what the bridge block is for.

```lua
_G.SCRBuffer.status()     -- approaches, learned stop points, last driver message
_G.SCRBuffer.probe()      -- studs to the last buffer, right now
_G.SCRBuffer.learned()    -- the per-platform stop points
_G.SCRBuffer.set{ aim = 45, floor = 10, cap = 35, crawl = 3, closerFloor = 25 }
_G.SCRBuffer.forget()     -- drop everything learned

_G.SCRBrake.status()      -- closing speed, ceiling, brake rate, lateness
_G.SCRBrake.set{ target = 30, rate = 2.0, early = 0.75, lateAfter = 60 }

_G.SCRPlatform.status()   -- arrivals, rolls, alignment
_G.SCRPlatform.align()    -- run the forward roll by hand, now
_G.SCRPlatform.probe()    -- car-stop boards in range and how they parsed

_G.SCRWhite.probe()       -- signal panel dump
_G.SCRWhite.go()          -- manual shunt release. Ignores signals — it will drive past a red

_G.SCRLong.status()       -- uptime, defibs, rebinds
_G.SCRLong.defib()        -- force one now
_G.SCRFix.status()        -- what the guards have caught
_G.AutoNextLeg.status()
_G.AntiAFK.status()
```

Every block also has `.enable()` and `.disable()`, and disabling one returns that behaviour to the
original.

---

## Building from source

The published script is **one concatenated file**, built from 11 sources in this exact order:

```bash
cat antiafk.lua fixes.lua braking.lua stophold.lua whitelight.lua \
    platform.lua longevity.lua nextleg.lua bufferstop.lua bridge.lua og_patched.lua \
    > scr_autopilot_overnight.lua
```

Order matters for readability only — install order is enforced at runtime by what each block waits
for, not by position in the file. Every block is wrapped in `do ... end` and exports nothing but its
own `_G.SCRxxx` table.

Then check it:

```bash
python3 luacheck.py  <files...>   # block balance: function/if/do/repeat vs end/until
python3 luascope.py  <files...>   # forward references and bracket balance
```

`luascope.py` catches a call to a name that is not declared as a `local function` until further
down the same scope. That compiles as a global lookup, resolves to `nil`, and throws at runtime.
It is not a hypothetical: `platform.lua` called a helper ninety lines above its declaration, so
every forward roll threw inside its `pcall` and the block had never once aligned a train.

There is no Lua interpreter in the loop, which is why both checkers are Python.

### Repository layout

```
scr_autopilot_overnight.lua   the build — this is what you execute
og_patched.lua                the original, with seven documented edits
antiafk.lua … bridge.lua      the add-on blocks, in build order
luacheck.py  luascope.py      the two static checks
HANDOFF.md                    full design notes, every bug and why it happened
```

`HANDOFF.md` is the real documentation. If you are going to change anything, read it first — it
records the failures that produced each of these rules, and most of them cost a night's testing.

---

## Gotchas that cost real time

- **`print` goes to Roblox's F9 developer console, not your executor's output tab.** Several
  diagnostic runs were wasted before this was worked out.
- **`_G` is not `getgenv()`.** `_G` is Roblox's shared table; executor globals like `writefile` live
  in `getgenv()`. Some executors also isolate `_G` per execution, which is what `bridge.lua` works
  around.
- **Never call the original's `target()` from a control loop.** It blocks until the notch arrives
  and abandons its ramp whenever anything else fires the speed event. A cut-off call cannot be
  cancelled from outside. Blocks needing precise control drive W and S directly against the
  `TargetIndicator` rotation, `mph = (rot + 31) / 1.2`.
- **Only ever reduce a commanded speed.** No add-on should have a path that makes the train faster
  than the original asked for.
- `%d` with a nil or non-integer float throws in Luau. Use `%.0f` for anything computed.

### Running it overnight on macOS

```bash
caffeinate -dimsu
```

Leave that window open. Three things it will not save you from: closing the lid still sleeps a
MacBook, battery power overrides most of it, and a locked screen takes focus away from Roblox so
the key presses stop landing. Set Lock Screen → screen saver and display off to Never.

---

## Known issues

1. **Car-stop marker semantics are known but unused.** From SCR's driver training: stop at the
   marker matching your coach count, numbered markers beat `S`, round up if there is no exact
   match, `S` only when nothing numbered fits; black is universal and colours are
   operator-specific. `HST` and `Class 80x` boards are other stock's. A block that drove to them
   existed and was deleted for being over-engineered — it stopped the train confidently in places
   nobody had asked for. If it comes back it should be twenty lines that adjust where the 5 mph
   roll stops, not a second driving system. `_G.SCRPlatform.markers(true)` still exists and stays
   off.
2. **The braking block has never been verified in game.** Its maths and hazards were checked by
   hand. Watch for `[brake] armed` in F9.
3. **The number under the train icon is not the car count.** It read 9, 2, 8, 14, 19 and 54 across
   screenshots of a three-car train. It is the power/brake notch.
4. Stops can still land short at platforms the buffer block has not learned yet. The first arrival
   teaches it; `_G.SCRBuffer.learned()` shows what it knows.

Issues and PRs welcome — a screenshot of the HUD plus the relevant `.status()` output is worth far
more than a description.

---

## Credits and licence

The autopilot engine is **[PlaceReporter99](https://github.com/PlaceReporter99)'s**
([SCR-Autopilot](https://github.com/PlaceReporter99/SCR-Autopilot)). All the hard work of reading
the DriveGui and driving the train is theirs. This repository is a derivative that keeps that engine
essentially intact and adds unattended-running behaviour around it.

**Seven edits** were made to the original, documented in full in `HANDOFF.md`: the station approach
constants, a rebindable HUD, a rebindable clock handler, an inverted loop condition that caused a
re-entrancy bug, a leaked event connection, a lowercase `cs:fire` that meant a whole handler had
never run, and a single-flight guard on that handler.

The original is licensed **AGPL-3.0**, so this is too — see [LICENSE](LICENSE). If you fork it,
those terms come with it, including the requirement to state your changes and to offer source to
anyone who uses it over a network.

### A note on using it

Automating gameplay with an executor is against Roblox's Terms of Use, and accounts do get banned
for it. That is your call to make, with your account.
