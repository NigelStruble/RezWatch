local _, ns = ...
local L = ns.L

local pairs, ipairs, next, min, max, format = pairs, ipairs, next, math.min, math.max, string.format
local wipe, concat = wipe, table.concat
local GetTime, UnitGUID, UnitIsDeadOrGhost = GetTime, UnitGUID, UnitIsDeadOrGhost

local Display = {}
ns.Display = Display

local SCAN_INTERVAL = 5 -- how often new raid frames are looked for while icons show
local REZ_ATLAS = "RaidFrame-Icon-Rez"
local MAX_PAIRED = 6 -- hidden casts checked two by two for a double res (15 pairs)
local NONE = {}

local buttons = {} -- every frame found that shows a group member
local overlays = {} -- [button] = overlay frame
local scanned, dirty = 0, true

--------------------------------------------------------------------------------
-- Finding raid frames
--------------------------------------------------------------------------------

-- Any frame whose "unit" attribute is a group member (the secure unit buttons
-- of EllesmereUI, Blizzard's raid frames, ElvUI and the like) gets the icon,
-- so no raid frame addon needs its own support.
local function Scan()
	wipe(buttons)
	local frame = EnumerateFrames()
	while frame do
		if not (frame.IsForbidden and frame:IsForbidden()) and frame.GetAttribute
			and ns.IsGroupToken(frame:GetAttribute("unit")) then
			buttons[#buttons + 1] = frame
		end
		frame = EnumerateFrames(frame)
	end
	scanned, dirty = GetTime(), false
end

function Display.Dirty()
	dirty = true
end

--------------------------------------------------------------------------------
-- Overlays
--------------------------------------------------------------------------------

-- An overlay sits on a raid frame and holds:
--   icon, count, text   what RezWatch knows (own casts, RezWatch messages, offers)
--   layers[k]           one per cast the game hides (or its landed offer): made
--                       visible by the game's own answer to "is it aimed at this
--                       player?", which RezWatch can show but not read
--   pairs[p]            two of those answers nested, so it shows only when both
--                       are true: a red "2" and both names, over the single ones

local function NewText(parent, layer)
	local font, size = GameFontHighlightSmall:GetFont()
	local text = parent:CreateFontString(nil, layer or "OVERLAY", "GameFontHighlightSmall")
	text:SetFont(font, size, "OUTLINE")
	text:SetWordWrap(false)
	return text
end

local function NewCount(parent, icon)
	local font, size = GameFontHighlightSmall:GetFont()
	local count = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	count:SetFont(font, size + 2, "OUTLINE")
	count:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", 3, -2)
	count:SetTextColor(1, 0.25, 0.25)
	return count
end

local function Overlay(button)
	local overlay = overlays[button]
	if overlay then
		return overlay
	end
	overlay = CreateFrame("Frame", nil, button)
	overlay:SetAllPoints(button)

	local icon = overlay:CreateTexture(nil, "OVERLAY")
	icon:SetAtlas(REZ_ATLAS)
	overlay.icon = icon
	overlay.count = NewCount(overlay, icon)
	overlay.text = NewText(overlay)
	overlay.layers, overlay.pairs = {}, {}

	overlays[button] = overlay
	return overlay
end

local function Colored(name, class)
	local color = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
	if not color then
		return name
	end
	return format("|cff%02x%02x%02x%s|r", color.r * 255, color.g * 255, color.b * 255, name)
end

local function Label(record)
	if record.landed then
		return "|cff40ff40" .. L["Rezzed"] .. "|r"
	end
	return Colored(record.name, record.class)
end

-- Names go below the icon, or above it when the icon sits at the bottom.
local function PlaceText(text, overlay)
	text:ClearAllPoints()
	if ns.db.point:find("BOTTOM") then
		text:SetPoint("BOTTOM", overlay.icon, "TOP", 0, 1)
	else
		text:SetPoint("TOP", overlay.icon, "BOTTOM", 0, -1)
	end
	text:SetWidth(overlay.textWidth)
end

local function Layout(overlay, button)
	local db = ns.db
	overlay:SetFrameLevel(button:GetFrameLevel() + 20)

	local size = db.iconSize
	local height = ns.Plain(button:GetHeight())
	if height and height > 4 then
		size = min(size, height - 2)
	end
	local icon = overlay.icon
	icon:SetSize(size, size)
	icon:ClearAllPoints()
	icon:SetPoint(db.point, overlay, db.point, db.x, db.y)

	overlay.textWidth = max((ns.Plain(button:GetWidth()) or 60) - 2, 20)
	PlaceText(overlay.text, overlay)
end

-- What RezWatch knows about this player; state is nil when it knows nothing.
local function Paint(overlay, state)
	local icon, count, text = overlay.icon, overlay.count, overlay.text
	if not state then
		icon:Hide()
		count:Hide()
		text:Hide()
		return
	end
	local casters = state.casters

	-- More than one res on the same player: a red count.
	local total = #casters + (state.offer and 1 or 0)
	if total > 1 then
		count:SetText(total)
		count:Show()
	else
		count:Hide()
	end

	if #casters > 0 then
		-- A res is being cast: plain icon, casters' names.
		icon:SetVertexColor(1, 1, 1)
		local names = {}
		for i, cast in ipairs(casters) do
			names[i] = Colored(cast.name, cast.class)
		end
		text:SetText(concat(names, ", "))
	elseif state.offer then
		-- The res landed and waits for the dead player to accept: green icon.
		icon:SetVertexColor(0.45, 1, 0.45)
		text:SetText("|cff40ff40" .. L["Rezzed"] .. "|r")
	else
		-- The game reports a res on the way, without saying who casts it.
		icon:SetVertexColor(1, 1, 1)
		text:SetText("")
	end
	icon:Show()
	text:SetShown(ns.db.showNames)
end

local function Layer(overlay, k)
	local layer = overlay.layers[k]
	if not layer then
		layer = CreateFrame("Frame", nil, overlay)
		layer:SetAllPoints(overlay)
		layer.icon = layer:CreateTexture(nil, "OVERLAY")
		layer.icon:SetAtlas(REZ_ATLAS)
		layer.icon:SetAllPoints(overlay.icon)
		layer.text = NewText(layer)
		layer.count = NewCount(layer, overlay.icon)
		layer.count:SetText("2")
		overlay.layers[k] = layer
	end
	return layer
end

local function Pair(overlay, p)
	local pair = overlay.pairs[p]
	if not pair then
		pair = CreateFrame("Frame", nil, overlay)
		pair:SetAllPoints(overlay)
		local inner = CreateFrame("Frame", nil, pair)
		inner:SetAllPoints(pair)
		inner.count = NewCount(inner, overlay.icon)
		inner.count:SetText("2")
		inner.text = NewText(inner)
		-- A backdrop hides the two single names drawn on top of each other.
		inner.back = inner:CreateTexture(nil, "BACKGROUND")
		inner.back:SetColorTexture(0, 0, 0, 0.85)
		inner.back:SetPoint("TOPLEFT", inner.text, "TOPLEFT", -1, 1)
		inner.back:SetPoint("BOTTOMRIGHT", inner.text, "BOTTOMRIGHT", 1, -1)
		pair.inner = inner
		overlay.pairs[p] = pair
	end
	return pair
end

-- The casts the game hides, on a dead player's frame. Each record's targets
-- hold the game's answer for this player, usually a secret boolean: alpha 1
-- when the cast is aimed here, 0 when not. A heal can't be aimed at a dead
-- player, so only resurrections ever show.
local function PaintLayers(overlay, guid, records, state)
	local known = state and (#state.casters + (state.offer and 1 or 0)) or 0
	local names = ns.db.showNames and known == 0 -- RezWatch's own names win the line
	local level = overlay:GetFrameLevel()

	local n = #records
	for k = 1, n do
		local layer, record = Layer(overlay, k), records[k]
		local answer = record.targets[guid]
		if answer == nil then
			layer:Hide()
		else
			layer:SetFrameLevel(level + 1)
			layer:SetAlphaFromBoolean(answer, 1, 0)
			layer.icon:SetVertexColor(record.landed and 0.45 or 1, 1, record.landed and 0.45 or 1)
			layer.text:SetText(Label(record))
			PlaceText(layer.text, overlay)
			layer.text:SetShown(names)
			layer.count:SetShown(known == 1)
			layer:Show()
		end
	end
	for k = n + 1, #overlay.layers do
		overlay.layers[k]:Hide()
	end

	local p, m = 0, min(n, MAX_PAIRED)
	for i = 1, m - 1 do
		for j = i + 1, m do
			local a, b = records[i].targets[guid], records[j].targets[guid]
			if a ~= nil and b ~= nil then
				p = p + 1
				local pair = Pair(overlay, p)
				pair:SetFrameLevel(level + 10)
				pair.inner:SetFrameLevel(level + 11)
				pair:SetAlphaFromBoolean(a, 1, 0)
				pair.inner:SetAlphaFromBoolean(b, 1, 0)
				local inner = pair.inner
				inner.text:SetText(Label(records[i]) .. ", " .. Label(records[j]))
				PlaceText(inner.text, overlay)
				inner.text:SetShown(names)
				inner.back:SetShown(names)
				pair:Show()
			end
		end
	end
	for q = p + 1, #overlay.pairs do
		overlay.pairs[q]:Hide()
	end
end

-- states: by GUID, what RezWatch knows (ns.BuildStates or ns.TestStates).
-- hidden: the casts the game hides and their landed offers (ns.HiddenLayers),
-- shown on every dead player's frame, each made visible only where it is aimed.
-- Returns the GUIDs of known states that got an icon on at least one frame.
function Display.Update(states, hidden)
	hidden = hidden or NONE
	local shown, painted = {}, {}
	if next(states) or #hidden > 0 then
		if dirty or GetTime() - scanned > SCAN_INTERVAL then
			Scan()
		end
		for _, button in ipairs(buttons) do
			if button:IsVisible() then
				local unit = button:GetAttribute("unit")
				local guid = ns.IsGroupToken(unit) and ns.Plain(UnitGUID(unit))
				local state = guid and states[guid]
				local dead = guid and #hidden > 0 and UnitIsDeadOrGhost(unit)
				if state or dead then
					local overlay = Overlay(button)
					Layout(overlay, button)
					Paint(overlay, state)
					PaintLayers(overlay, guid, dead and hidden or NONE, state)
					overlay:Show()
					shown[overlay] = true
					if state then
						painted[guid] = true
					end
				end
			end
		end
	end
	for _, overlay in pairs(overlays) do
		if not shown[overlay] and overlay:IsShown() then
			overlay:Hide()
		end
	end
	return painted
end
