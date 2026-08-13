-- Non-destructive hook: wraps the vanilla CreateUI instead of replacing the file.
-- This file only exists so the mod has an entry point; all real logic lives in modules/main.lua.
local originalCreateUI = CreateUI

CreateUI = function(isReplay)
    originalCreateUI(isReplay)

    -- The engine mounts a mod's folder as /mods/<foldername, lowercased>/
    -- regardless of the on-disk casing, so this path must stay lowercase.
    local ok, err = pcall(function()
        import('/mods/faf-buildtimers/modules/main.lua').Init()
    end)
    if not ok then
        WARN('BuildTimers: failed to initialize - ' .. tostring(err))
    end
end
