-- A small mock of the World of Warcraft API, enough to load RezWatch and drive
-- it from tests. Widgets only have the methods the real client has (for the
-- parts the addon uses), so a misspelled or missing method fails the same way
-- it would in game: "attempt to call method 'X' (a nil value)".

local Mock = {}

local POINTS = {
	TOPLEFT = true, TOP = true, TOPRIGHT = true, LEFT = true, CENTER = true, RIGHT = true,
	BOTTOMLEFT = true, BOTTOM = true, BOTTOMRIGHT = true,
}

-- Secret values: the 12.x client hides some values from addons. Here a secret
-- is a table only issecretvalue recognises; it keeps the real value so the
-- mock's own widgets (SetAlphaFromBoolean) can act on it like the game does.
local SecretMeta = { __tostring = function() return "<secret>" end }
local function Secret(value)
	return setmetatable({ value = value }, SecretMeta)
end
local function IsSecret(value)
	return getmetatable(value) == SecretMeta
end
Mock.Secret = Secret

--------------------------------------------------------------------------------
-- Widgets
--------------------------------------------------------------------------------

local function Methods(...)
	local methods = {}
	for i = 1, select("#", ...) do
		for name, func in pairs((select(i, ...))) do
			methods[name] = func
		end
	end
	return { __index = methods }
end

local Region = {
	Show = function(self) self.shown = true end,
	Hide = function(self) self.shown = false end,
	IsShown = function(self) return self.shown end,
	IsVisible = function(self)
		if not self.shown then return false end
		return self.parent == nil or self.parent:IsVisible()
	end,
	SetPoint = function(self, point, relativeTo, relativePoint, x, y)
		assert(POINTS[point], "bad point " .. tostring(point))
		self.points = self.points or {}
		self.points[#self.points + 1] = { point, relativeTo, relativePoint, x, y }
	end,
	ClearAllPoints = function(self) self.points = {} end,
	SetAllPoints = function(self, target) self.points = { { "ALL", target } } end,
	SetSize = function(self, w, h) self.width, self.height = w, h end,
	SetWidth = function(self, w) assert(type(w) == "number") self.width = w end,
	SetHeight = function(self, h) self.height = h end,
	GetWidth = function(self) return self.width or 0 end,
	GetHeight = function(self) return self.height or 0 end,
	SetAlpha = function(self, a) self.alpha = a end,
	-- Like the game: accepts a secret boolean and acts on its real value.
	SetAlphaFromBoolean = function(self, value, alphaIfTrue, alphaIfFalse)
		if IsSecret(value) then value = value.value end
		assert(type(value) == "boolean", "SetAlphaFromBoolean needs a boolean")
		self.alpha = value and (alphaIfTrue or 1) or (alphaIfFalse or 0)
	end,
	SetShown = function(self, shown) self.shown = shown and true or false end,
	GetParent = function(self) return self.parent end,
}

local Texture = {
	SetAtlas = function(self, atlas) self.atlas = atlas end,
	SetTexture = function(self, texture) self.texture = texture end,
	SetVertexColor = function(self, r, g, b) self.color = { r, g, b } end,
	SetColorTexture = function(self, r, g, b, a) self.colorTexture = { r, g, b, a } end,
	SetDesaturated = function(self, value) self.desaturated = value end,
}

local FontString = {
	SetFont = function(self, font, size, flags)
		assert(type(size) == "number", "font size")
		self.font, self.fontSize, self.flags = font, size, flags
		return true
	end,
	GetFont = function(self) return self.font or "Fonts\\FRIZQT__.TTF", self.fontSize or 10, self.flags end,
	SetText = function(self, text) self.text = text ~= nil and tostring(text) or nil end,
	GetText = function(self) return self.text end,
	SetTextColor = function(self, r, g, b) self.textColor = { r, g, b } end,
	SetWordWrap = function(self, value) self.wordWrap = value end,
	SetJustifyH = function(self, value) self.justifyH = value end,
}

local Frame = {
	RegisterEvent = function(self, event)
		self.events[event] = true
		self.env.__registry[self] = true
	end,
	UnregisterEvent = function(self, event) self.events[event] = nil end,
	IsEventRegistered = function(self, event) return self.events[event] == true end,
	SetScript = function(self, script, func) self.scripts[script] = func end,
	GetScript = function(self, script) return self.scripts[script] end,
	SetFrameLevel = function(self, level) self.level = level end,
	GetFrameLevel = function(self) return self.level or 1 end,
	GetAttribute = function(self, key) return self.attributes[key] end,
	SetAttribute = function(self, key, value) self.attributes[key] = value end,
	IsForbidden = function() return false end,
	CreateTexture = function(self)
		local texture = setmetatable({ shown = true, parent = self }, Methods(Region, Texture))
		self.regions[#self.regions + 1] = texture
		return texture
	end,
	CreateFontString = function(self)
		local text = setmetatable({ shown = true, parent = self }, Methods(Region, FontString))
		self.regions[#self.regions + 1] = text
		return text
	end,
}

--------------------------------------------------------------------------------
-- Client
--------------------------------------------------------------------------------

-- members: list of { name, surname, class, dead, target (index or nil) }; the
-- first is the player.
function Mock.New(options)
	options = options or {}
	local env = setmetatable({}, { __index = _G })
	env._G = env
	local state = {
		time = 1000,
		members = {},
		raid = false,
		sent = {}, -- addon messages
		printed = {},
		sounds = 0,
		casting = {}, -- [guid] = { endMs, targetName, targetClass }
		secret = false, -- hide spell targets, like 12.x in combat
		incoming = {},
	}
	env.__registry = {}
	local frames = {}

	env.CreateFrame = function(kind, name, parent)
		local frame = setmetatable({
			env = env, kind = kind, name = name, parent = parent, shown = true,
			events = {}, scripts = {}, attributes = {}, regions = {}, children = {},
		}, Methods(Region, Frame))
		frames[#frames + 1] = frame
		if parent then parent.children[#parent.children + 1] = frame end
		if name then env[name] = frame end
		return frame
	end
	env.EnumerateFrames = function(current)
		if not current then return frames[1] end
		for i, frame in ipairs(frames) do
			if frame == current then return frames[i + 1] end
		end
	end

	env.GameFontHighlightSmall = env.CreateFrame("Frame")
	env.GameFontHighlightSmall.GetFont = function() return "Fonts\\FRIZQT__.TTF", 10, "" end
	env.RAID_CLASS_COLORS = {
		PRIEST = { r = 1, g = 1, b = 1 }, PALADIN = { r = 0.96, g = 0.55, b = 0.73 },
		SHAMAN = { r = 0, g = 0.44, b = 0.87 }, DRUID = { r = 1, g = 0.49, b = 0.04 },
		WARRIOR = { r = 0.78, g = 0.61, b = 0.43 }, MAGE = { r = 0.25, g = 0.78, b = 0.92 },
	}
	env.DEFAULT_CHAT_FRAME = { AddMessage = function(_, text) state.printed[#state.printed + 1] = text end }
	env.SlashCmdList = {}
	env.SOUNDKIT = { RAID_WARNING = 8959 }
	env.PlaySound = function() state.sounds = state.sounds + 1 end
	env.GetTime = function() return state.time end
	env.wipe = function(t) for k in pairs(t) do t[k] = nil end return t end
	env.strsplit = function(sep, text)
		local parts, start = {}, 1
		while true do
			local i = text:find(sep, start, true)
			if not i then parts[#parts + 1] = text:sub(start) break end
			parts[#parts + 1] = text:sub(start, i - 1)
			start = i + 1
		end
		return unpack(parts)
	end
	env.LE_PARTY_CATEGORY_INSTANCE = 2
	env.LE_PARTY_CATEGORY_HOME = 1


	env.issecretvalue = IsSecret
	-- Like Forever's client: other players' casts are hidden from addons (the
	-- player's own are not). cast.hidden decides it per cast.
	local function Hide(cast, value)
		if cast.hidden and value ~= nil then return Secret(value) end
		return value
	end

	-- Units. Members are indexed 1..n (the player first); a member's target is
	-- another member's index or "stranger" (a dead player outside the group).
	local STRANGER = { name = "Stranger", surname = "Danger", class = "MAGE", dead = true }
	local function Token(i)
		if state.raid then return "raid" .. i end
		return i == 1 and "player" or ("party" .. (i - 1))
	end
	local function Member(unit)
		if unit == "player" then return state.members[1], 1 end
		local base = unit:match("^(.-)target$")
		if base and base ~= "" then
			local member = Member(base)
			local target = member and member.target
			if target == "stranger" then return STRANGER, "stranger" end
			if target then return state.members[target], target end
			return nil
		end
		local n = unit:match("^party(%d+)$")
		if n and not state.raid then
			local i = tonumber(n) + 1
			if state.members[i] then return state.members[i], i end
			return nil
		end
		n = unit:match("^raid(%d+)$")
		if n and state.raid then
			local i = tonumber(n)
			if state.members[i] then return state.members[i], i end
		end
	end
	state.Token = Token

	env.IsInRaid = function() return state.raid end
	env.IsInGroup = function(category)
		if category == env.LE_PARTY_CATEGORY_INSTANCE then return false end
		return #state.members > 1
	end
	env.GetNumGroupMembers = function() return #state.members > 1 and #state.members or 0 end
	env.GetNumSubgroupMembers = function() return state.raid and 0 or (#state.members - 1) end
	env.UnitExists = function(unit) return Member(unit) ~= nil end
	env.UnitGUID = function(unit)
		local m, i = Member(unit)
		return m and ("Player-1-" .. i) or nil
	end
	env.UnitName = function(unit)
		local m = Member(unit)
		if not m then return nil end
		return m.name, m.surname -- Forever: the second value is the surname
	end
	env.UnitClass = function(unit)
		local m = Member(unit)
		if not m then return nil end
		return m.class, m.class
	end
	env.UnitIsDeadOrGhost = function(unit)
		local m = Member(unit)
		return m and m.dead or false
	end
	env.UnitIsUnit = function(a, b)
		local _, i = Member(a)
		local _, j = Member(b)
		return i ~= nil and i == j
	end
	env.UnitInParty = function(unit)
		local _, i = Member(unit)
		return type(i) == "number"
	end
	env.UnitInRaid = function(unit)
		local _, i = Member(unit)
		return state.raid and type(i) == "number" and i or nil
	end
	env.UnitHasIncomingResurrection = function(unit)
		local _, i = Member(unit)
		return i and state.incoming[i] or false
	end
	env.UnitAffectingCombat = function(unit)
		local m = Member(unit)
		return m and m.combat or false
	end
	env.UnitCastingInfo = function(unit)
		local _, i = Member(unit)
		local cast = i and state.casting[i]
		if not cast then return nil end
		return Hide(cast, "Resurrection"), Hide(cast, "Resurrection"), Hide(cast, 135955),
			Hide(cast, (state.time - 1) * 1000), Hide(cast, cast.endMs), false, Hide(cast, cast.castGUID), false,
			Hide(cast, cast.spellID)
	end
	-- Like the real client: a cast's target is always a secret value to addons.
	-- cast.target is the index of the member it is aimed at.
	env.UnitSpellTargetName = function(unit)
		local _, i = Member(unit)
		local cast = i and state.casting[i]
		local target = cast and cast.target and state.members[cast.target]
		return target and Secret(target.name .. " " .. target.surname) or nil
	end
	env.UnitSpellTargetClass = function(unit)
		local _, i = Member(unit)
		local cast = i and state.casting[i]
		local target = cast and cast.target and state.members[cast.target]
		return target and Secret(target.class) or nil
	end
	-- Whether unit's cast is aimed at target: a secret boolean, unless
	-- state.plainSpellTarget lets the game answer plainly.
	env.UnitIsSpellTarget = function(unit, target)
		local _, i = Member(unit)
		local _, j = Member(target)
		local cast = i and state.casting[i]
		local answer = cast ~= nil and cast.target ~= nil and cast.target == j
		if state.plainSpellTarget then return answer end
		return Secret(answer)
	end

	-- Resurrection offers
	env.GetCorpseRecoveryDelay = function() return 0 end
	env.AcceptResurrect = function() state.accepted = (state.accepted or 0) + 1 end
	env.DeclineResurrect = function() state.declined = (state.declined or 0) + 1 end
	env.TimeoutResurrect = function() end
	env.hooksecurefunc = function(name, hook)
		local original = env[name]
		env[name] = function(...)
			original(...)
			hook(...)
		end
	end

	-- Spells
	local SPELL_NAMES = { [2006] = "Resurrection", [2010] = "Resurrection", [7328] = "Redemption", [20484] = "Rebirth",
		[2008] = "Ancestral Spirit", [20609] = "Ancestral Spirit", [8342] = "Defibrillate", [133] = "Fireball",
		[939] = "Healing Wave", [99999] = "Resurrection" }
	env.C_Spell = {
		GetSpellName = function(id)
			if IsSecret(id) then return Secret(SPELL_NAMES[id.value]) end -- a hidden spell gives a hidden name
			return SPELL_NAMES[id]
		end,
	}
	env.C_ChatInfo = {
		RegisterAddonMessagePrefix = function() return true end,
		SendAddonMessage = function(prefix, message, channel)
			state.sent[#state.sent + 1] = { prefix = prefix, message = message, channel = channel }
		end,
	}


	function state.Fire(event, ...)
		for frame in pairs(env.__registry) do
			if frame.events[event] and frame.scripts.OnEvent then
				frame.scripts.OnEvent(frame, event, ...)
			end
		end
	end

	function state.Advance(seconds)
		local step = 0.1
		local left = seconds
		while left > 1e-9 do
			local dt = math.min(step, left)
			state.time = state.time + dt
			left = left - dt
			for _, frame in ipairs(frames) do
				if frame.scripts.OnUpdate and frame:IsVisible() then
					frame.scripts.OnUpdate(frame, dt)
				end
			end
		end
	end

	-- A raid frame button for every member, like a SecureGroupHeader's children.
	function state.MakeButtons()
		state.buttons = {}
		for i = 1, #state.members do
			local button = env.CreateFrame("Button", nil, nil)
			button:SetAttribute("unit", Token(i))
			button:SetSize(80, 40)
			state.buttons[i] = button
		end
	end

	-- The overlay RezWatch put on member i's button, when shown.
	function state.Overlay(i)
		local button = state.buttons[i]
		for _, frame in ipairs(frames) do
			if frame.parent == button and frame.icon and frame:IsShown() then
				return frame
			end
		end
	end

	-- What member i's raid frame really shows: res icons and texts that are
	-- shown and not faded out (alpha 0) anywhere up to the button.
	-- Returns { icons = n, green = bool, texts = { plain texts } }.
	function state.Seen(i)
		local button = state.buttons[i]
		local seen = { icons = 0, green = false, texts = {} }
		local function Visible(region)
			local r = region
			while r ~= button do
				if not r.shown or (r.alpha or 1) <= 0 then return false end
				r = r.parent
			end
			return button:IsVisible()
		end
		local function Walk(frame)
			for _, region in ipairs(frame.regions) do
				if Visible(region) then
					if region.atlas == "RaidFrame-Icon-Rez" then
						seen.icons = seen.icons + 1
						if region.color and region.color[1] < 1 then seen.green = true end
					elseif region.text and region.text ~= "" then
						seen.texts[#seen.texts + 1] = region.text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
					end
				end
			end
			for _, child in ipairs(frame.children) do Walk(child) end
		end
		Walk(button)
		return seen
	end

	state.SECRET = Secret("hidden")
	state.Secret = Secret
	return env, state
end

-- Loads the addon's files (in .toc order) into env.
function Mock.Load(env, dir)
	local ns = {}
	local toc = assert(io.open(dir .. "/RezWatch.toc")):read("*a")
	for file in toc:gmatch("[^\r\n]+") do
		if not file:match("^#") and file:match("%.lua$") then
			local chunk = assert(loadfile(dir .. "/" .. file))
			setfenv(chunk, env)
			chunk("RezWatch", ns)
		end
	end
	return ns
end

return Mock
