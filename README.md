# BuildTimers

> **AI disclosure:** this mod was written with substantial AI assistance
> (Claude, Anthropic) - design, implementation, and debugging, working from
> the mod author's requirements and in-game testing/feedback across
> several iterations. Disclosed per the
> [FAF Vault meta requirements](https://wiki.faforever.com/en/Development/Vault/Rules).

A UI-only mod for [Forged Alliance Forever](https://faforever.com) (Supreme
Commander: Forged Alliance) that shows a lean countdown over a small set of
units whose build or missile charge is easy to lose track of.

| Unit | What the timer counts |
|---|---|
| Nuke silo (incl. Seraphim experimental nuke) | construction, then each missile build |
| Anti-nuke (SMD) silo | construction, then each missile build |
| T3 strategic missile submarine (UEF/Aeon/Cybran) | nuke build only - while a nuke is queued |
| Seraphim T3 battleship | nuke build only - while a nuke is queued |
| T3 artillery installation (stationary) | construction only |
| Experimental units | construction only |

Not tracked: mobile heavy artillery, missile cruisers, carriers, regular
battleships, tactical missile launchers, commanders. Tactical missile
builds on subs and the Seraphim battleship are ignored.

## What it shows

Stacked above/below the unit, in the game's own UI font:

```
          1:24           <- time remaining (under a minute: 45s)
          x3             <- missiles stored (nuke/anti-nuke units only)
       [ unit model ]    <- left clear, no overlay
           67%           <- percent complete
```

- The time and percent appear only while something is actually being
  built. The missile count stays visible on nuke/anti-nuke units.
- The time shows `??:??` when it can't be estimated: right after a build
  starts, while the game is paused, and when progress has stalled (no
  assist, no resources) - instead of a frozen old number.
- Labels appear automatically on your own units within a few seconds of
  being placed, including buildings still under construction (as long as
  something is building or assisting them) - no need to select or hover
  them. A foundation nobody is working on shows up once you hover or
  select it. Hovering or selecting an
  enemy/allied unit under vision shows its label too (handy for scouting).

## Install

Easiest: find **BuildTimers** in the FAF client's mod vault and install it.

Manual: drop the `FAF-BuildTimers` folder into the folder below. The mod
works under any folder name, but the client only finds the preview icon
if the folder keeps this name.

```
Documents\My Games\Gas Powered Games\Supreme Commander Forged Alliance\mods\
```

Then enable it from the FAF client's mod manager.

## Safe for ranked

This is a `ui_only` mod - it never touches simulation Lua, so it doesn't
unrank games.

## How it works, briefly

- Label positions follow the unit every frame; the text (time, percent,
  missile count) refreshes 4 times a second.
- Every 3 seconds a background scan picks up newly-placed units
  automatically via a UI-only "hidden select" trick (no sim-mod needed),
  plus whatever your engineers and factories are currently building.
- Performance: both the scan and the selection check first narrow the
  army down with one engine-side category filter, so per-unit Lua work
  only runs on the handful of units that can actually get a label.
- The remaining time is averaged over a short sliding window (2.5 s), so it
  stays smooth but still reacts when assist starts or stops.

See the comments at the top of `modules/main.lua` for the version history
and the reasoning behind each design decision.

## License

MIT - see [LICENSE](LICENSE).
