# BuildTimers

> **AI disclosure:** this mod was written with substantial AI assistance
> (Claude, Anthropic) - design, implementation, and debugging, working from
> the mod author's requirements and in-game testing/feedback across
> several iterations. Disclosed per the
> [FAF Vault meta requirements](https://wiki.faforever.com/en/Development/Vault/Rules).

A UI-only mod for [Forged Alliance Forever](https://faforever.com) (Supreme
Commander: Forged Alliance) that shows a lean countdown over units with a
reload/charge cycle that's otherwise easy to lose track of:

- Nuke silos
- Anti-nuke (SMD) silos
- Seraphim T3 Battleship (their stand-in for a strategic missile sub)
- T3 strategic missile submarines (UEF/Aeon/Cybran)
- T3 artillery
- Experimental units (construction time)

## What it shows

Stacked above/below the unit, in the game's own UI font:

```
        ETA 01:24        <- time remaining
          x3              <- missile count (nuke/anti-nuke/naval only)
       [ unit model ]      <- left clear, no overlay
           67%             <- percent complete
```

If the remaining time can't be estimated yet (e.g. right after a reload
cycle starts), the time label shows `??:??` instead of disappearing. The
label only appears while a unit actually has something in progress - for
the naval nuke launchers (Seraphim battleship, strategic missile subs)
that means only while a missile build has actually been ordered, since
those don't auto-reload like a ground silo.

Labels appear automatically on your own qualifying units within a few
seconds of being placed - no need to select or hover them. Hovering or
selecting an enemy/allied unit under vision still shows its label too
(handy for scouting), the same as it always did.

## Install

Drop the `FAF-BuildTimers` folder into:

```
Documents\My Games\Gas Powered Games\Supreme Commander Forged Alliance\mods\
```

Enable it from the FAF client's mod manager.

## Safe for ranked

This is a `ui_only` mod - it never touches simulation Lua, so it doesn't
unrank games.

## How it works, briefly

- A slow poll (4x/second) refreshes label text/position; a low-frequency
  background scan (every few seconds) picks up newly-placed qualifying
  units automatically via a UI-only "hidden select" trick (no sim-mod
  needed) - see the comments at the top of `modules/main.lua` for the
  version history and the reasoning behind each design decision.
- The remaining-time estimate uses a short sliding averaging window rather
  than a per-tick instantaneous rate or a whole-cycle average, to stay
  smooth without drifting when a build stalls and resumes.

## License

MIT - see [LICENSE](LICENSE).
