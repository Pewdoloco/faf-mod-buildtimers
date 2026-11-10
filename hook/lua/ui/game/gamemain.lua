-- Non-destructive hook: wraps the vanilla CreateUI instead of replacing the file.
-- This file only exists so the mod has an entry point; all real logic lives in modules/main.lua.
local originalCreateUI = CreateUI

-- The folder name depends on how the mod was installed (copied by hand,
-- downloaded from the vault, ...), so look it up instead of hardcoding it.
-- Matched by name + author rather than uid, since the uid changes with
-- every released version. import() lowercases paths itself, so the
-- folder's casing doesn't matter.
local function FindBuildTimersLocation()
    for _, mod in __active_mods or {} do
        if mod.name == 'BuildTimers' and mod.author == 'BagFromWalmart' and mod.location then
            return mod.location
        end
    end
    return '/mods/faf-buildtimers'
end

CreateUI = function(isReplay)
    originalCreateUI(isReplay)

    local ok, err = pcall(function()
        import(FindBuildTimersLocation() .. '/modules/main.lua').Init()
    end)
    if not ok then
        WARN('BuildTimers: failed to initialize - ' .. tostring(err))
    end
end
