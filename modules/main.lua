-- BuildTimers: lean countdown labels for a small, fixed set of units:
--   * nuke silo (incl. Seraphim battleship, which fills that role for
--     Seraphim instead of a T3 strategic missile sub): reload time + count
--   * anti-nuke (SMD) silo: reload time + missile count
--   * T3 strategic missile submarine (UEF/Aeon/Cybran): reload time + count
--   * T3 artillery: reload/build time only (no missile count)
--   * experimental units (any faction): construction time only
--
-- v0.7: found in game logs - after a pause/resume (and possibly other
-- WorldView-recreating events), the engine can destroy a tracker's controls
-- without telling this mod. Every further Left/Top/SetText/etc. call on
-- one then throws "Game object has been destroyed", uncaught, on every
-- rendered frame from then on - hundreds of stack traces per game and a
-- permanently frozen label for that tracker. See InvalidateControls,
-- UpdateFramePosition and the pcall-wrapped SetText calls in UpdateVisuals:
-- any such failure now nulls the tracker's controls out so the next poll
-- tick's EnsureControls rebuilds them from scratch instead of continuing
-- to hammer the dead ones.
--
-- v0.6: fixed a false positive where every T3 battleship (not just
-- Seraphim's nuclear one) showed a bogus reload timer - see IsNukeOrAntiNuke
-- for the root cause and the fix (require the SILO category alongside
-- ANTIMISSILE). Naval nuke units only start reporting progress once the
-- player manually orders a missile build (there's no automatic reload like
-- the ground silo), so the label already only appears while that's active
-- - no separate code needed for "only while the charge button is pressed".
--
-- v0.5: dropped the v0.4 radial dial - it looked good on one unit but
-- turned into unreadable clutter with several qualifying units clustered
-- together, and its custom font/color didn't match the game's own look.
-- Replaced with a stacked text layout (top to bottom: time, missile count,
-- the unit itself left clear, percent complete) using UIUtil.CreateText/
-- bodyFont - same helper other installed mods use to match native UI text -
-- instead of a hand-picked font/color/icon badge. The background box
-- behind the text is gone too. If the ETA can't be computed for a tick
-- (fraction is known but the rate isn't yet - e.g. right after a window
-- re-anchor) the time label shows "??:??" instead of vanishing; only a nil
-- fraction (not currently building at all) hides the label.
--
-- v0.3: an earlier, broader version tracked any hovered/selected unit and
-- recomputed the timer/text every rendered frame, which caused noticeable
-- in-game lag. This version deliberately trades timer precision for
-- performance:
--   * label CONTENT (timer value, percent, missile count) refreshes on a
--     slow poll (POLL_INTERVAL), not per rendered frame
--   * screen POSITION still updates every frame (via OnFrame) - it has to,
--     since it depends on the camera, not just the unit - but that callback
--     only does cheap position math, no text/texture work
--   * only the four category/tag combinations above are tracked at all,
--     checked once when a tracker would be created, so nothing is spent on
--     units outside that list
--
-- v0.4:
--   * ETA is now a rate averaged since the start of the current build/
--     reload cycle (see UpdateEta) instead of a per-tick instantaneous
--     rate with exponential smoothing - the old approach amplified any
--     small noise in the engine's fraction reading into a visibly jittery
--     countdown even under steady mass/energy income.
--   * "Sticky" tracking (select/hover a unit once, keep tracking it after)
--     is kept for scouting enemy/allied silos under vision, but is no
--     longer the only way a tracker gets created: a low-frequency
--     (DISCOVERY_INTERVAL) hidden full-selection scan of the local
--     player's own army (see DiscoverNewUnits) picks up newly-placed
--     qualifying units automatically, without needing a click/hover.
--     This does NOT require a sim-mod - contrary to this file's earlier
--     assumption, UI-only mods can already do this (see UMT and
--     SupremeEconomy in this same mods folder, both installed alongside
--     this one, for the same technique).

local WorldView = import('/lua/ui/game/worldview.lua')
local GameMain = import('/lua/ui/game/gamemain.lua')
local CommandMode = import('/lua/ui/game/commandmode.lua')
local UIUtil = import('/lua/ui/uiutil.lua')

local POLL_INTERVAL = 0.25         -- single update rate for position/text/badge/ETA
local DISCOVERY_INTERVAL = 3       -- seconds between hidden full-army scans for new units
local TEXT_SIZE = 12               -- bumped from 10 - UIUtil.bodyFont looked pixelated that small
local LINE_GAP = 2                 -- pixels between the stacked time/missile lines
local TIME_ABOVE_OFFSET = 24       -- pixels between the unit and the bottom of the stacked lines above it
local PERCENT_BELOW_OFFSET = 20    -- pixels between the unit and the percent label below it

-- Screen-space no-render zone so badges/timers don't paint over the
-- minimap. There's no way to query the minimap's live position/size (it's
-- an internal local to minimap.lua, and the player can drag it anywhere),
-- so this is a fixed box padded a bit beyond the default top-left minimap
-- size/position. Adjust these four numbers if your minimap lives elsewhere
-- or this over/under-shoots.
local MINIMAP_EXCLUSION = { left = 0, top = 0, right = 250, bottom = 380 }

local function InMinimapZone(x, y)
    return x >= MINIMAP_EXCLUSION.left and x <= MINIMAP_EXCLUSION.right
        and y >= MINIMAP_EXCLUSION.top and y <= MINIMAP_EXCLUSION.bottom
end

local trackers = {}                -- [entityId] = tracker table, see NewTracker()
local initialized = false
local DEBUG = false

local function GetView()
    return WorldView.viewLeft
end

local function InCategory(unit, categoryName)
    local ok, result = pcall(EntityCategoryContains, categories[categoryName], unit)
    if ok then return result end
    return false
end

local function IsCommanderUnit(unit)
    return InCategory(unit, 'COMMAND') or InCategory(unit, 'SUBCOMMANDER')
end

-- ACUs/SACUs have an innate tactical-missile ability that reports through
-- the same GetMissileInfo() fields as a real anti-nuke silo - excluding
-- commanders keeps this to the actual silo structure.
--
-- 'ANTIMISSILE' alone is NOT enough to mean "anti-nuke silo": every T3
-- battleship in the game (regular, non-nuclear ones included) also carries
-- 'ANTIMISSILE' for its built-in point-defense flak, which reload-cycles
-- constantly - that's what was showing a bogus timer on plain battleships.
-- Verified against FAF's own unit blueprints (github.com/FAForever/fa,
-- units/UAS0302 "Omen Class" battleship and units/UAS0303 "Keefer Class"
-- carrier both list ANTIMISSILE with no SILO tag) vs. actual silo-capable
-- units (units/UES0304 T3 strategic missile sub, units/XSS0302 "Hauthuum"
-- Seraphim battleship - the Seraphim's stand-in for a strategic sub) which
-- both list SILO. 'NUKE' itself isn't overloaded that way (only real
-- nuke-capable units carry it), so it's left as a standalone match - this
-- only tightens the ANTIMISSILE side, which is where the false positive
-- came from.
local function IsNukeOrAntiNuke(unit)
    if IsCommanderUnit(unit) then return false end
    if InCategory(unit, 'NUKE') then return true end
    return InCategory(unit, 'ANTIMISSILE') and InCategory(unit, 'SILO')
end

local function IsTech3Artillery(unit)
    return InCategory(unit, 'ARTILLERY') and InCategory(unit, 'TECH3')
end

-- The only unit types this mod tracks at all - checked once up front so
-- nothing is spent on units outside this fixed list.
local function IsTrackedUnit(unit)
    if IsCommanderUnit(unit) then return false end
    return IsNukeOrAntiNuke(unit) or InCategory(unit, 'EXPERIMENTAL') or IsTech3Artillery(unit)
end

local function SafeCall(unit, methodName)
    local method = unit[methodName]
    if not method then return nil end
    local ok, result = pcall(method, unit)
    if ok then return result end
    return nil
end

-- Same call the native tooltip uses for missile counts.
local function GetMissileInfo(unit)
    local ok, info = pcall(unit.GetMissileInfo, unit)
    if ok then return info end
    return nil
end

local function FormatTime(seconds)
    if not seconds or seconds ~= seconds or seconds < 0 then return nil end
    seconds = math.floor(seconds + 0.5)
    local m = math.floor(seconds / 60)
    local s = seconds - m * 60  -- Lua 5.0 (this engine) has no % operator
    if m > 0 then
        return string.format('%d:%02d', m, s)
    end
    return string.format('%ds', s)
end

local function NewTracker(unit)
    return {
        unit = unit,
        fraction = nil,            -- latest 0..1 progress reading
        cycleStartFraction = nil,  -- fraction at the start of the current cycle
        cycleStartTime = nil,      -- GetNow() at the start of the current cycle
        eta = nil,                 -- seconds remaining, derived from the cycle-average rate
        missileInfo = nil,
        isNukeSilo = false,     -- true nuke/anti-nuke silo (missile-count label eligible)
        control = nil,          -- time label, above the unit
        missileControl = nil,   -- missile-count label, between the time label and the unit
        hasMissileLabel = false,
        percentControl = nil,   -- percent-complete label, below the unit
    }
end

-- Construction/repair progress first; falls back to GetWorkProgress for
-- nuke/anti-nuke silos, since GetFractionComplete stays pinned at 1 once
-- the structure itself is built while GetWorkProgress tracks the reload
-- on at least some silo types.
local function DetectFraction(unit, isNukeSilo)
    local fraction = SafeCall(unit, 'GetFractionComplete')
    if (fraction == nil or fraction >= 1 or fraction <= 0) and isNukeSilo then
        local wp = SafeCall(unit, 'GetWorkProgress')
        if wp ~= nil and wp > 0 and wp < 1 then
            fraction = wp
        end
    end
    if fraction ~= nil and fraction < 1 and fraction > 0 then
        return fraction
    end
    return nil
end

-- Plain text ("x3") instead of an icon badge - at the small sizes this mod
-- runs at, the icon badge didn't read well and was dropped.
local function FormatMissileLabel(missileInfo, isNukeSilo)
    if not missileInfo or not isNukeSilo then return nil end
    local count
    if missileInfo.nukeSiloMaxStorageCount and missileInfo.nukeSiloMaxStorageCount > 0 then
        count = missileInfo.nukeSiloStorageCount or 0
    elseif missileInfo.tacticalSiloMaxStorageCount and missileInfo.tacticalSiloMaxStorageCount > 0 then
        count = missileInfo.tacticalSiloStorageCount or 0
    else
        return nil
    end
    if count < 0 then count = 0 end
    return 'x' .. count
end

-- GameTick() advances with simulation time (10 ticks/second), not wall-clock
-- time, so it stays in lockstep with the fraction readings even across
-- pauses or a hitching poll loop - using real wall-clock time here would let
-- the two drift apart and reintroduce jitter.
local function GetNow()
    return GameTick() / 10
end

local ANCHOR_WINDOW = 2.5   -- seconds; re-anchor the averaging window this often

-- ETA is a rate averaged over a short sliding window (ANCHOR_WINDOW), not a
-- per-tick instantaneous rate and NOT a whole-cycle average.
--   * per-tick delta amplifies any small noise/quantization in the engine's
--     fraction reading into a visibly jittery countdown even when mass/
--     energy income is perfectly steady;
--   * BUT averaging over the *entire* cycle-so-far (an earlier version of
--     this function) has its own bug: one slow/stalled stretch early in a
--     multi-minute reload permanently drags the average down, so the
--     displayed ETA keeps climbing for the rest of the cycle even once
--     resources/assist are fine again - it never "forgets" that early
--     stall. Periodically sliding the window forward bounds how long a
--     past stall can skew the estimate, while still smoothing several poll
--     ticks' worth of noise within each window.
local function UpdateEta(tracker)
    local fraction = tracker.fraction
    if fraction == nil then
        tracker.cycleStartFraction = nil
        tracker.cycleStartTime = nil
        tracker.eta = nil
        return
    end

    local now = GetNow()

    -- Real cycle reset: first sample, or fraction dropped back down (a new
    -- build/reload cycle started). The old eta no longer applies at all.
    if tracker.cycleStartFraction == nil or fraction < tracker.cycleStartFraction then
        tracker.cycleStartFraction = fraction
        tracker.cycleStartTime = now
        tracker.eta = nil
        return
    end

    local elapsed = now - tracker.cycleStartTime

    -- Slide the window forward. Keep showing the last computed eta this
    -- tick rather than blanking it - only an actual cycle reset (above)
    -- should do that.
    if elapsed >= ANCHOR_WINDOW then
        tracker.cycleStartFraction = fraction
        tracker.cycleStartTime = now
        return
    end

    local gained = fraction - tracker.cycleStartFraction
    if elapsed > 0 and gained > 0 and fraction < 1 then
        tracker.eta = (1 - fraction) * (elapsed / gained)
    end
end

-- nil only when nothing is being built/reloaded right now (fraction is
-- nil) - hides the label entirely. Whenever fraction IS valid but the ETA
-- itself isn't known yet (e.g. right after UpdateEta re-anchors its
-- window), show a placeholder instead of letting the label disappear and
-- reappear.
local function FormatLabel(tracker)
    if tracker.fraction == nil then return nil end
    return FormatTime(tracker.eta) or '??:??'
end

local function FormatPercentLabel(tracker)
    if tracker.fraction == nil then return nil end
    local pct = math.floor(tracker.fraction * 100 + 0.5)
    if pct < 0 then pct = 0 end
    if pct > 99 then pct = 99 end
    return pct .. '%'
end

-- Forgets a tracker's controls (without touching the underlying dead
-- engine objects, which may themselves throw on further use) so the next
-- EnsureControls call rebuilds fresh ones. See the big comment above
-- AttachFrameTracking for why this exists.
local function InvalidateControls(tracker)
    tracker.control = nil
    tracker.missileControl = nil
    tracker.percentControl = nil
end

local function DestroyTracker(entityId)
    local tracker = trackers[entityId]
    if tracker then
        -- pcall-wrapped like everything else touching these controls: one
        -- may already be a dead engine object (see UpdateFramePosition's
        -- comment) that hasn't been caught/nulled out yet.
        if tracker.control then pcall(tracker.control.Destroy, tracker.control) end
        if tracker.missileControl then pcall(tracker.missileControl.Destroy, tracker.missileControl) end
        if tracker.percentControl then pcall(tracker.percentControl.Destroy, tracker.percentControl) end
    end
    trackers[entityId] = nil
end

-- Position tracking (camera projection) runs every rendered frame via
-- OnFrame - it has to, since the on-screen position depends on the camera,
-- which can change every frame (zoom/pan) independently of our slow poll.
-- It's kept deliberately cheap: no closures allocated per call (methods are
-- passed to pcall directly), no string/texture work, just a handful of
-- Set() calls. Content (text/badge/visibility-by-data) is still only
-- refreshed once per poll tick in UpdateVisuals below.
--
-- Layout, top to bottom: time label, missile-count label (nuke/anti-nuke
-- only), the unit model itself (left clear, no overlay), percent label.
--
-- Split out from the OnFrame closure below so it can be called through
-- pcall - the engine can destroy a WorldView's controls out from under a
-- mod (observed in logs: happens around pause/resume) without telling it,
-- and calling Left/Top/SetAlpha/etc. on a dead control throws "Game object
-- has been destroyed". Uncaught, that happens on literally every rendered
-- frame from then on (OnFrame keeps firing on the dead control) - hundreds
-- of stack traces a game, real CPU cost, and this tracker's label frozen/
-- stuck forever since the exception aborted before updating anything.
local function UpdateFramePosition(tracker, text, missileText, percentText, view)
    local unit = tracker.unit
    local ok, pos = pcall(unit.GetPosition, unit)
    local screenPos = ok and pos and view:Project(pos)
    if not screenPos or InMinimapZone(screenPos.x, screenPos.y) then
        text:SetAlpha(0)
        if missileText then missileText:SetAlpha(0) end
        if percentText then percentText:SetAlpha(0) end
        return
    end

    -- Stack missile-count directly above the unit, then time above that.
    -- Only reserves vertical space when there's actually a missile
    -- count to show (nuke/anti-nuke) - otherwise the time label sits
    -- right at the usual offset instead of leaving a blank gap above
    -- T3 artillery/experimentals.
    local aboveBottom = screenPos.y - TIME_ABOVE_OFFSET

    if missileText then
        if tracker.hasMissileLabel then
            missileText:SetAlpha(1)
            missileText.Left:Set(screenPos.x - missileText.Width() / 2)
            missileText.Top:Set(aboveBottom - missileText.Height())
            aboveBottom = missileText.Top() - LINE_GAP
        else
            missileText:SetAlpha(0)
        end
    end

    text:SetAlpha(1)
    text.Left:Set(screenPos.x - text.Width() / 2)
    text.Top:Set(aboveBottom - text.Height())

    if percentText then
        percentText:SetAlpha(1)
        percentText.Left:Set(screenPos.x - percentText.Width() / 2)
        percentText.Top:Set(screenPos.y + PERCENT_BELOW_OFFSET)
    end
end

local function AttachFrameTracking(tracker, view)
    local text = tracker.control
    local missileText = tracker.missileControl
    local percentText = tracker.percentControl

    text:SetNeedsFrameUpdate(true)
    text.OnFrame = function(self, delta)
        local ok = pcall(UpdateFramePosition, tracker, text, missileText, percentText, view)
        if not ok then
            -- Best-effort: stop this dead control from getting an OnFrame
            -- call (and paying the error-construction cost) every future
            -- frame. Wrapped in pcall too - it may already be too far gone
            -- to even accept this call.
            pcall(self.SetNeedsFrameUpdate, self, false)
            InvalidateControls(tracker)
        end
    end
end

local function EnsureControls(tracker)
    if tracker.control then return true end
    local view = GetView()
    if not view then return false end

    -- UIUtil.CreateText/bodyFont matches the font+style the game's own UI
    -- panels use, instead of a hand-picked font/color - same helper other
    -- installed mods (Advanced Selection Info, UMT, ...) use for the same
    -- reason.
    local textOk, text = pcall(UIUtil.CreateText, view, '', TEXT_SIZE, UIUtil.bodyFont)
    if not textOk then return false end
    pcall(text.SetDropShadow, text, true)
    pcall(text.DisableHitTest, text)

    local missileOk, missileText = pcall(UIUtil.CreateText, view, '', TEXT_SIZE, UIUtil.bodyFont)
    if missileOk then
        pcall(missileText.SetDropShadow, missileText, true)
        pcall(missileText.DisableHitTest, missileText)
    else
        missileText = nil
    end

    local percentOk, percentText = pcall(UIUtil.CreateText, view, '', TEXT_SIZE, UIUtil.bodyFont)
    if percentOk then
        pcall(percentText.SetDropShadow, percentText, true)
        pcall(percentText.DisableHitTest, percentText)
    else
        percentText = nil
    end

    tracker.control = text
    tracker.missileControl = missileText
    tracker.percentControl = percentText
    AttachFrameTracking(tracker, view)
    return true
end

-- Refreshes text/badge content once per poll tick. Screen position is
-- handled separately, every frame, by the OnFrame callback set up in
-- AttachFrameTracking above.
--
-- Each SetText is pcall-wrapped and bails out on the first failure: a
-- control can go stale between EnsureControls (which only checks if
-- tracker.control is non-nil, not whether the engine object behind it is
-- still alive) and here - see the comment above UpdateFramePosition. If
-- that happens, invalidate everything and let the next poll tick's
-- EnsureControls rebuild from scratch instead of leaving a half-updated,
-- now-orphaned set of controls around.
local function UpdateVisuals(tracker)
    if not EnsureControls(tracker) then return end

    local ok = pcall(tracker.control.SetText, tracker.control, FormatLabel(tracker) or '')
    if not ok then
        InvalidateControls(tracker)
        return
    end

    if tracker.percentControl then
        ok = pcall(tracker.percentControl.SetText, tracker.percentControl, FormatPercentLabel(tracker) or '')
        if not ok then
            InvalidateControls(tracker)
            return
        end
    end

    if tracker.missileControl then
        local missileLabel = FormatMissileLabel(tracker.missileInfo, tracker.isNukeSilo)
        tracker.hasMissileLabel = missileLabel ~= nil
        ok = pcall(tracker.missileControl.SetText, tracker.missileControl, missileLabel or '')
        if not ok then
            InvalidateControls(tracker)
            return
        end
    end
end

local function RefreshTracker(tracker)
    local unit = tracker.unit
    local missileInfo = GetMissileInfo(unit)
    tracker.missileInfo = missileInfo
    tracker.isNukeSilo = IsNukeOrAntiNuke(unit)
    tracker.fraction = DetectFraction(unit, tracker.isNukeSilo)
    UpdateEta(tracker)
    UpdateVisuals(tracker)
end

-- Briefly select every friendly unit to read them off GetSelectedUnits(),
-- then restore the player's real selection and command mode. This is a
-- UI-only trick (no sim-mod involved) - the same technique is already used
-- by other installed mods (UMT's HiddenSelect, SupremeEconomy's Reset) to
-- enumerate the local player's whole army.
local function HiddenSelect(callback)
    local ok = pcall(function()
        CommandMode.CacheAndClearCommandMode()
        GameMain.SetIgnoreSelection(true)
        local oldSelection = GetSelectedUnits()
        UISelectionByCategory('ALLUNITS', false, false, false, false)
        callback()
        SelectUnits(oldSelection)
        GameMain.SetIgnoreSelection(false)
        CommandMode.RestoreCommandMode(true)
    end)
    if not ok then
        -- Don't leave selection hidden / command mode cached if something
        -- above threw partway through.
        pcall(GameMain.SetIgnoreSelection, false)
        pcall(CommandMode.RestoreCommandMode, true)
    end
end

-- Runs on a slow, fixed interval (DISCOVERY_INTERVAL) - this is what lets a
-- nuke/anti-nuke/experimental/T3-arty foundation show its timer the moment
-- it's placed, without the player ever selecting or hovering it. Only seeds
-- the shared `trackers` table for anything not already tracked; the
-- existing "sticky" loop in PollSelection then keeps refreshing/rendering
-- and eventually cleans it up, same as a hover-discovered tracker.
local function DiscoverNewUnits()
    HiddenSelect(function()
        for _, unit in GetSelectedUnits() or {} do
            if IsTrackedUnit(unit) then
                local ok, entityId = pcall(unit.GetEntityId, unit)
                if ok and entityId and not trackers[entityId] then
                    local tracker = NewTracker(unit)
                    trackers[entityId] = tracker
                    RefreshTracker(tracker)
                end
            end
        end
    end)
end

local function PollSelection()
    local seen = {}

    local selected = GetSelectedUnits()
    if selected then
        for _, unit in selected do
            if IsTrackedUnit(unit) then
                local ok, entityId = pcall(unit.GetEntityId, unit)
                if ok and entityId then
                    seen[entityId] = true
                    local tracker = trackers[entityId]
                    if not tracker then
                        tracker = NewTracker(unit)
                        trackers[entityId] = tracker
                    end
                    RefreshTracker(tracker)
                end
            end
        end
    end

    -- Whatever's currently under the mouse cursor, native-tooltip style.
    local hoverOk, hoverInfo = pcall(GetRolloverInfo)
    if hoverOk and hoverInfo and hoverInfo.entityId then
        local entityId = hoverInfo.entityId
        local tracker = trackers[entityId]
        if not tracker then
            local unitOk, unit = pcall(GetUnitById, entityId)
            if unitOk and unit and IsTrackedUnit(unit) then
                tracker = NewTracker(unit)
                trackers[entityId] = tracker
            end
        end
        if tracker then
            seen[entityId] = true
            RefreshTracker(tracker)
        end
    end

    -- Sticky: keep tracking (and showing) anything already tracked as long
    -- as it still exists, even after you stop selecting/hovering it.
    for entityId, tracker in trackers do
        if not seen[entityId] then
            local aliveOk, unit = pcall(GetUnitById, entityId)
            if aliveOk and unit then
                seen[entityId] = true
                RefreshTracker(tracker)
            end
        end
    end

    for entityId, _ in trackers do
        if not seen[entityId] then
            DestroyTracker(entityId)
        end
    end
end

function Init()
    if initialized then return end
    initialized = true

    ForkThread(function()
        while true do
            local ok, err = pcall(PollSelection)
            if DEBUG and not ok then
                WARN('BuildTimers: poll error - ' .. tostring(err))
            end
            WaitSeconds(POLL_INTERVAL)
        end
    end)

    ForkThread(function()
        while true do
            local ok, err = pcall(DiscoverNewUnits)
            if DEBUG and not ok then
                WARN('BuildTimers: discovery error - ' .. tostring(err))
            end
            WaitSeconds(DISCOVERY_INTERVAL)
        end
    end)
end
