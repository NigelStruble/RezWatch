local _, ns = ...

-- Every string in the addon is written in English and looked up through L, so
-- a missing translation simply falls back to the English text. To translate,
-- add a block for the locale and assign only the strings that should change:
--
--   if GetLocale() == "deDE" then
--       L["Rezzed"] = "Wiederbelebt"
--   end
--
-- Spell names never need translating: they are read from the game client.

local L = setmetatable({}, {
	__index = function(_, key)
		return key
	end,
})

ns.L = L
