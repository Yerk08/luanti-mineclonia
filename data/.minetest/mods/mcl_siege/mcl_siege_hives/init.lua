local path = core.get_modpath(core.get_current_modname())
local hive = dofile(path .. "/hive.lua")
dofile(path .. "/queens.lua")(hive)
