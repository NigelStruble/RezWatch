local ADDON, ns = ...
local L = ns.L

local _G = _G
local pairs, ipairs, next, type, tostring, tonumber, select = pairs, ipairs, next, type, tostring, tonumber, select
local wipe, tinsert, tremove, sort, concat = wipe, table.insert, table.remove, table.sort, table.concat
local format, strsplit = string.format, strsplit
local GetTime, UnitExists, UnitGUID, UnitName, UnitClass = GetTime, UnitExists, UnitGUID, UnitName, UnitClass
local UnitIsDeadOrGhost = UnitIsDeadOrGhost

local PREFIX = "RezWatch"
local ACCEPT_TIME = 60 -- how long a resurrection offer waits for its answer
local STOP_GRACE = 0.5 -- a finished cast may report its stop before its success
local UPDATE_INTERVAL = 0.2
local TEST_TIME = 15
-- Res spells take 10 seconds to cast, heals at most 3.5. A hidden cast this
-- short can't be an out-of-combat res, so its landing isn't kept (a heal's
-- would show nowhere anyway, but would hold a display layer for a minute).
local RES_MIN_CAST = 4
local HIDDEN_LIFETIME = 15 -- a hidden cast whose end was never seen (a res takes 10 s)

ns.DEFAULTS = {
	iconSize = 24,
	point = "CENTER", -- where the icon sits on the raid frame
	x = 0,
	y = 0,
	showNames = true, -- who is casting, under the icon
	showAccept = true, -- keep the icon while a landed res waits to be accepted
	warn = true, -- tell the player when their target already has a res coming
	sound = true,
	share = true, -- tell other RezWatch users who the player's res is aimed at
	debug = false, -- print what is seen of each res cast
}

-- Every rank of every resurrection cast on another player. Spells are also
-- matched by name, so a rank or variant missing here is still recognised.
ns.SPELLS = {
	2006, 2010, 10880, 10881, 20770, 25435, 48171, -- Resurrection
	7328, 10322, 10324, 20772, 20773, 48949, 48950, -- Redemption
	2008, 20609, 20610, 20776, 20777, 25590, 49277, -- Ancestral Spirit
	20484, 20739, 20742, 20747, 20748, 26994, 48477, -- Rebirth
	50769, -- Revive
	115178, -- Resuscitate
	361227, -- Return
	8342, 22999, -- Defibrillate (Goblin Jumper Cables)
}

-- [caster GUID] = { castGUID, target, exact, name, class, started, ends, stopped, warned }
ns.casts = {}
ns.offers = {} -- [target GUID] = { caster, name, class, expires }: landed, not yet accepted
ns.incoming = {} -- [GUID] = true while the game itself reports a res on the way

-- Other players' casts the game hides from addons (spell, target and timing
-- are secret values), and the ones of those that landed:
-- { caster, name, class, started, stopped, landed, expires, targets = { [dead GUID] = answer } }
-- An answer is the game's UnitIsSpellTarget, usually a secret boolean that the
-- display can show (SetAlphaFromBoolean) but RezWatch can't read.
ns.hidden = {} -- [caster GUID] = record, while casting
ns.hiddenOffers = {} -- records whose cast landed

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

-- The 12.x engine hides some values from addons ("secret" values: other
-- players' casts, any cast's target). They can't be compared, so Plain turns
-- them into nil and every check that uses one simply fails.
local issecretvalue = _G.issecretvalue
local function Plain(value)
	if value ~= nil and issecretvalue and issecretvalue(value) then
		return nil
	end
	return value
end
ns.Plain = Plain

function ns:Print(message, ...)
	if select("#", ...) > 0 then
		message = format(message, ...)
	end
	DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99RezWatch|r: " .. tostring(message))
end

-- Diagnostics, printed only while /rezwatch debug is on.
function ns.Debug(message, ...)
	if ns.db and ns.db.debug then
		ns:Print("|cff999999" .. format(message, ...) .. "|r")
	end
end

function ns.IsGroupToken(unit)
	if type(unit) ~= "string" then
		return false
	end
	return unit == "player" or unit:match("^party%d+$") ~= nil or unit:match("^raid%d+$") ~= nil
end

-- Calls func(unit) for every group member (just the player when solo) until it returns true.
local function ForEachGroupUnit(func)
	if IsInRaid() then
		for i = 1, GetNumGroupMembers() do
			local unit = "raid" .. i
			if UnitExists(unit) and func(unit) then
				return
			end
		end
	else
		if func("player") then
			return
		end
		for i = 1, GetNumSubgroupMembers() do
			local unit = "party" .. i
			if UnitExists(unit) and func(unit) then
				return
			end
		end
	end
end

local unitByGUID = {}

local function MapUnits()
	wipe(unitByGUID)
	ForEachGroupUnit(function(unit)
		local guid = Plain(UnitGUID(unit))
		if guid then
			unitByGUID[guid] = unit
		end
	end)
end

-- The group unit token of a GUID, or nil when that player is not in the group.
local function UnitByGUID(guid)
	if not guid then
		return nil
	end
	local unit = unitByGUID[guid]
	if unit and Plain(UnitGUID(unit)) == guid then
		return unit
	end
	MapUnits()
	return unitByGUID[guid]
end

local function NameOfGUID(guid)
	local unit = UnitByGUID(guid)
	return unit and Plain(UnitName(unit)) or "?"
end

local function ClassOf(unit)
	local _, class = UnitClass(unit)
	return Plain(class)
end

--------------------------------------------------------------------------------
-- Spells and targets
--------------------------------------------------------------------------------

local spellIds, spellNames = {}, {}

local function SpellName(id)
	if C_Spell and C_Spell.GetSpellName then
		return C_Spell.GetSpellName(id)
	elseif GetSpellInfo then
		return (GetSpellInfo(id))
	end
end

local function LoadSpells()
	for _, id in ipairs(ns.SPELLS) do
		spellIds[id] = true
		local name = SpellName(id)
		if name then
			spellNames[name] = true
		end
	end
end

function ns.IsResSpell(spellID)
	spellID = Plain(spellID)
	if not spellID then
		return false
	end
	if spellIds[spellID] then
		return true
	end
	local name = Plain(SpellName(spellID))
	return name ~= nil and spellNames[name] == true
end

local function GUIDOf(unit)
	return Plain(UnitGUID(unit))
end

-- How well text names the unit: 2 for the whole name ("First Last" on Forever,
-- where characters have surnames), 1 when only the first name matches, 0
-- otherwise. A "-Realm" ending is ignored.
local function NameScore(text, unit)
	local name, surname = UnitName(unit)
	name, surname = Plain(name), Plain(surname)
	if not name then
		return 0
	end
	text = text:gsub("%-.*$", "")
	local full = (surname and surname ~= "") and (name .. " " .. surname) or name
	if text == full then
		return 2
	elseif text:match("^%S+") == name then
		return 1
	end
	return 0
end

-- The group member text names best; with dead set, only dead members count.
local function MemberNamed(text, dead)
	local best, bestScore = nil, 0
	ForEachGroupUnit(function(unit)
		if not dead or UnitIsDeadOrGhost(unit) then
			local score = NameScore(text, unit)
			if score > bestScore then
				best, bestScore = unit, score
			end
		end
	end)
	return best
end

-- The group unit a token like "party1target" points at, or nil when that is
-- not a group member. Goes by GUID, or by UnitIsUnit if the GUID is hidden.
local function GroupUnitOf(token)
	if not UnitExists(token) then
		return nil
	end
	local guid = GUIDOf(token)
	if guid then
		return UnitByGUID(guid)
	end
	local found
	ForEachGroupUnit(function(unit)
		if Plain(UnitIsUnit(token, unit)) == true then
			found = unit
			return true
		end
	end)
	return found
end

-- The dead group member, when exactly one is dead.
local function OnlyDeadMember()
	local found, count = nil, 0
	ForEachGroupUnit(function(unit)
		if UnitIsDeadOrGhost(unit) then
			found, count = unit, count + 1
		end
	end)
	return count == 1 and found or nil
end

-- For a res cast whose spell RezWatch can read (the player's own, or another
-- player's where the game shows it): the GUID of the dead group member it is
-- aimed at, and how that was found. The game hides a cast's target from
-- addons (UnitSpellTargetName is always a secret value on the 12.x engine),
-- so this goes by what can be read: the name UNIT_SPELLCAST_SENT gave for the
-- player's own casts (hint), the caster's target, or the only dead group
-- member. Returns nil when it can't tell (several are dead and the caster
-- targets none of them) or when the target isn't in the group.
function ns.FindTarget(caster, hint)
	local text = Plain(hint)
	if not text or text == "" then
		text = UnitSpellTargetName and Plain(UnitSpellTargetName(caster))
	end
	if text and text ~= "" then
		local unit = MemberNamed(text, true)
		if unit then
			return GUIDOf(unit), "name"
		end
	end
	local target = caster .. "target"
	if UnitExists(target) and UnitIsDeadOrGhost(target) then
		local unit = GroupUnitOf(target)
		if unit then
			return GUIDOf(unit), "target"
		end
		return nil, "outside"
	end
	if text and text ~= "" then
		return nil, "outside" -- named someone who isn't a dead group member
	end
	local only = OnlyDeadMember()
	if only then
		return GUIDOf(only), "only"
	end
	return nil, "unknown"
end

-- Asks the game, for every dead group member, whether a hidden cast is aimed
-- at them (UnitIsSpellTarget), keeping the answers in record.targets. Only a
-- resurrection can be aimed at a dead player, so the display needs nothing
-- else. Returns true and the target's GUID (or nil) when every answer came
-- back plain; false when they are secret, as on Forever.
local function SampleTargets(record, caster)
	local targets, plain, found = record.targets, true, nil
	ForEachGroupUnit(function(unit)
		if UnitIsDeadOrGhost(unit) then
			local guid = GUIDOf(unit)
			if guid then
				local answer = UnitIsSpellTarget(caster, unit)
				targets[guid] = answer
				if issecretvalue and issecretvalue(answer) then
					plain = false
				elseif answer then
					found = guid
				end
			end
		end
	end)
	return plain, found
end

--------------------------------------------------------------------------------
-- Casts and offers
--------------------------------------------------------------------------------

-- exact: the target is known for sure (by name on the caster's own client, or
-- the game said so) rather than taken from the caster's target.
function ns.StartCast(casterGUID, castGUID, target, name, class, ends, exact)
	if target then
		ns.hidden[casterGUID] = nil -- known now, so no longer shown from the game's hidden answers
	end
	local cast = ns.casts[casterGUID]
	if cast and not cast.stopped and (not castGUID or not cast.castGUID or cast.castGUID == castGUID) then
		-- The same cast seen twice (unit tokens, or an event plus a RezWatch message).
		cast.castGUID = cast.castGUID or castGUID
		if target and (not cast.target or (exact and not cast.exact)) then
			cast.target, cast.exact = target, exact or nil
		end
	else
		local now = GetTime()
		ns.casts[casterGUID] = {
			castGUID = castGUID,
			target = target,
			exact = exact or nil,
			name = name or "?",
			class = class,
			started = now,
			ends = ends or (now + 10),
		}
	end
	ns.CheckOverlap()
	ns.Changed()
end

-- outcome: "done" (the res landed), "stop" (the cast bar ended, success may
-- still follow) or "fail".
function ns.StopCast(casterGUID, castGUID, outcome)
	local cast = ns.casts[casterGUID]
	if not cast or (castGUID and cast.castGUID and cast.castGUID ~= castGUID) then
		return
	end
	if outcome == "stop" then
		cast.stopped = cast.stopped or GetTime()
	else
		ns.casts[casterGUID] = nil
		if outcome == "done" and cast.target then
			ns.offers[cast.target] = {
				caster = casterGUID, name = cast.name, class = cast.class, expires = GetTime() + ACCEPT_TIME,
			}
		end
	end
	ns.Changed()
end

-- A dead player's RezWatch reports the offer it got (RESURRECT_REQUEST). That
-- is certain, so it replaces what RezWatch had from the same caster: an offer
-- it thought went to someone else, and the same res seen as a hidden cast.
function ns.Offered(target, inviter, seconds)
	local unit = inviter and inviter ~= "" and MemberNamed(inviter) or nil
	local caster = unit and GUIDOf(unit)
	if caster then
		ns.casts[caster] = nil
		ns.hidden[caster] = nil
		for guid, offer in pairs(ns.offers) do
			if offer.caster == caster and guid ~= target then
				ns.offers[guid] = nil
			end
		end
		for i = #ns.hiddenOffers, 1, -1 do
			if ns.hiddenOffers[i].caster == caster then
				tremove(ns.hiddenOffers, i) -- the same res, now known
			end
		end
	end
	ns.offers[target] = {
		caster = caster,
		name = unit and Plain(UnitName(unit)) or inviter or "?",
		class = unit and ClassOf(unit),
		expires = GetTime() + (seconds or ACCEPT_TIME),
	}
	ns.Changed()
end

-- The offer was declined or ran out.
function ns.OfferGone(target)
	if ns.offers[target] then
		ns.offers[target] = nil
		ns.Changed()
	end
end

-- Warns once per cast when the player's target already has a res coming that
-- RezWatch knows of. A res the game hides can't be known here; the frame's
-- red "2" shows it instead.
function ns.CheckOverlap()
	local mine = ns.playerGUID and ns.casts[ns.playerGUID]
	if not mine or mine.warned or not mine.target or mine.stopped then
		return
	end
	local others = {}
	for guid, cast in pairs(ns.casts) do
		if guid ~= ns.playerGUID and cast.target == mine.target and not cast.stopped then
			tinsert(others, cast.name)
		end
	end
	local offer = ns.offers[mine.target]
	if #others == 0 and not offer then
		return
	end
	mine.warned = true
	if not ns.db.warn then
		return
	end
	local unit = UnitByGUID(mine.target)
	local target = unit and Plain(UnitName(unit)) or "?"
	if #others > 0 then
		ns:Print(L["%s is also being resurrected by %s."], target, concat(others, ", "))
	else
		ns:Print(L["%s already has a resurrection from %s waiting to be accepted."], target, offer.name)
	end
	if ns.db.sound then
		PlaySound(SOUNDKIT and SOUNDKIT.RAID_WARNING or 8959)
	end
end

-- Drops what is over: stopped casts past the grace, casts long past their end,
-- offers that were accepted or expired, and players who left.
local function Expire(now)
	for guid, cast in pairs(ns.casts) do
		if (cast.stopped and now - cast.stopped > STOP_GRACE) or now > cast.ends + 2 or not UnitByGUID(guid) then
			ns.casts[guid] = nil
		end
	end
	for guid, offer in pairs(ns.offers) do
		local unit = UnitByGUID(guid)
		if now > offer.expires or not unit or not UnitIsDeadOrGhost(unit) then
			ns.offers[guid] = nil
		end
	end
	for guid in pairs(ns.incoming) do
		local unit = UnitByGUID(guid)
		if not unit or not Plain(UnitHasIncomingResurrection(unit)) then
			ns.incoming[guid] = nil
		end
	end
	for caster, record in pairs(ns.hidden) do
		if (record.stopped and now - record.stopped > STOP_GRACE) or now - record.started > HIDDEN_LIFETIME
			or not UnitByGUID(caster) then
			ns.hidden[caster] = nil
		end
	end
	for i = #ns.hiddenOffers, 1, -1 do
		if now > ns.hiddenOffers[i].expires then
			tremove(ns.hiddenOffers, i)
		end
	end
	ns.ForgetFinished(now)
end

local function ByStart(a, b)
	return a.started < b.started
end

-- What each dead group member's frames should show, by GUID:
-- { casters = { cast, ... }, offer = offer or nil, incoming = true or nil }
function ns.BuildStates()
	Expire(GetTime())
	ns.CheckOverlap() -- a res landing on the player's target mid-cast counts too
	local states = {}
	local function StateOf(guid)
		local state = states[guid]
		if not state then
			local unit = UnitByGUID(guid)
			if not unit or not UnitIsDeadOrGhost(unit) then
				return nil
			end
			state = { casters = {} }
			states[guid] = state
		end
		return state
	end
	for _, cast in pairs(ns.casts) do
		local state = cast.target and StateOf(cast.target)
		if state then
			tinsert(state.casters, cast)
		end
	end
	if ns.db.showAccept then
		for guid, offer in pairs(ns.offers) do
			local state = StateOf(guid)
			if state then
				state.offer = offer
			end
		end
	end
	for guid in pairs(ns.incoming) do
		local state = StateOf(guid)
		if state then
			state.incoming = true
		end
	end
	for _, state in pairs(states) do
		sort(state.casters, ByStart)
	end
	return states
end

-- The casts the game hides, and those that landed, oldest first, for the
-- display. A cast still going is asked again on each update, in case the game
-- had no answer yet when it started.
function ns.HiddenLayers()
	local layers = {}
	for caster, record in pairs(ns.hidden) do
		local unit = not record.stopped and UnitByGUID(caster)
		if unit then
			SampleTargets(record, unit)
		end
		layers[#layers + 1] = record
	end
	if ns.db.showAccept then
		for _, record in ipairs(ns.hiddenOffers) do
			layers[#layers + 1] = record
		end
	end
	sort(layers, ByStart)
	return layers
end

-- Fake states on every group member, to see where the icons sit.
function ns.TestStates()
	local states, i = {}, 0
	local me = { name = Plain(UnitName("player")) or "?", class = ClassOf("player") }
	local other = { name = L["Priest"], class = "PRIEST" }
	ForEachGroupUnit(function(unit)
		local guid = Plain(UnitGUID(unit))
		if guid then
			i = i + 1
			if i % 3 == 1 then
				states[guid] = { casters = { me } }
			elseif i % 3 == 2 then
				states[guid] = { casters = { me, other } }
			else
				states[guid] = { casters = {}, offer = other }
			end
		end
	end)
	return states
end

--------------------------------------------------------------------------------
-- Updates
--------------------------------------------------------------------------------

local driver = CreateFrame("Frame")
driver:Hide()

local function Active()
	return next(ns.casts) ~= nil or next(ns.offers) ~= nil or next(ns.incoming) ~= nil or ns.testUntil ~= nil
		or next(ns.hidden) ~= nil or #ns.hiddenOffers > 0
end

local unshown = {} -- [GUID] = true: already reported as having no frame

function ns.Refresh()
	if ns.testUntil and GetTime() > ns.testUntil then
		ns.testUntil = nil
	end
	local states = ns.testUntil and ns.TestStates() or ns.BuildStates()
	local painted = ns.Display.Update(states, not ns.testUntil and ns.HiddenLayers() or nil)
	if ns.db.debug and not ns.testUntil then
		for guid in pairs(states) do
			if not painted[guid] and not unshown[guid] then
				unshown[guid] = true
				ns.Debug(L["No raid frame RezWatch can find shows %s."], NameOfGUID(guid))
			end
		end
	end
	for guid in pairs(unshown) do
		if not states[guid] then
			unshown[guid] = nil
		end
	end
	if Active() then
		driver:Show()
	else
		driver:Hide()
	end
end

-- Something changed: repaint now, and keep repainting while anything is shown.
function ns.Changed()
	if ns.db then
		ns.Refresh()
	end
end

local elapsed = 0
driver:SetScript("OnUpdate", function(_, delta)
	elapsed = elapsed + delta
	if elapsed >= UPDATE_INTERVAL then
		elapsed = 0
		ns.Refresh()
	end
end)

function ns.StartTest()
	ns.testUntil = GetTime() + TEST_TIME
	ns.Display.Dirty()
	ns.Refresh()
	ns:Print(L["Showing test icons for %d seconds."], TEST_TIME)
end

--------------------------------------------------------------------------------
-- Sharing with other RezWatch users
--------------------------------------------------------------------------------

-- Messages are "<kind>,<sender GUID>,...":
--   S,<caster>,<cast GUID>,<target GUID>,<seconds left>   a res started
--   D,<caster>,<cast GUID>                                it landed
--   X,<caster>,<cast GUID>                                it was cancelled
--   O,<dead player>,<who resurrected them>,<seconds>      a res offer arrived
--   N,<dead player>                                       the offer was declined or ran out
-- The caster's client knows the name it cast on, and the dead player's client
-- knows its offer, so these tell everyone what the game hides from addons.

local function Channel()
	if LE_PARTY_CATEGORY_INSTANCE and IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then
		return "INSTANCE_CHAT"
	elseif IsInRaid() then
		return "RAID"
	elseif IsInGroup() then
		return "PARTY"
	end
end

function ns.Share(kind, ...)
	if not ns.db.share or not ns.playerGUID or not C_ChatInfo or not C_ChatInfo.SendAddonMessage then
		return
	end
	local channel = Channel()
	if not channel then
		return
	end
	local fields = { kind, ns.playerGUID }
	for i = 1, select("#", ...) do
		local value = select(i, ...)
		fields[#fields + 1] = value ~= nil and tostring(value) or ""
	end
	-- Addon messages can be blocked (in combat on the 12.x engine); the icons
	-- then fall back to what each client sees itself.
	pcall(C_ChatInfo.SendAddonMessage, PREFIX, concat(fields, ","), channel)
end

local function Field(value)
	if value ~= "" then
		return value
	end
end

function ns.Receive(message)
	local kind, from, a, b, c = strsplit(",", message)
	from, a, b, c = Field(from), Field(a), Field(b), Field(c)
	if not from or from == ns.playerGUID then
		return
	end
	local unit = UnitByGUID(from)
	if not unit then
		return
	end
	local name = Plain(UnitName(unit))
	if kind == "S" then
		if b then
			ns.Debug(L["%s's RezWatch: their res is on %s."], name or "?", NameOfGUID(b))
		end
		ns.StartCast(from, a, b, name, ClassOf(unit), GetTime() + (tonumber(c) or 10), b ~= nil)
	elseif kind == "D" then
		ns.StopCast(from, a, "done")
	elseif kind == "X" then
		ns.StopCast(from, a, "fail")
	elseif kind == "O" then
		ns.Debug(L["%s's RezWatch: they have a res from %s."], name or "?", a or "?")
		ns.Offered(from, a, tonumber(b))
	elseif kind == "N" then
		ns.OfferGone(from)
	end
end

--------------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------------

local sent -- { castGUID, name }: the target of the player's last res, from UNIT_SPELLCAST_SENT
local finished = {} -- [cast GUID] = time: casts already ended, as their events come once per unit token

-- How a cast's target was found, for /rezwatch debug.
local HOW = {
	name = L["named by the game"],
	target = L["the caster's target"],
	only = L["the only dead player"],
	outside = L["someone outside the group"],
	unknown = L["several are dead, none targeted"],
}

local function CastEnd(unit)
	local endMs = select(5, UnitCastingInfo(unit))
	endMs = Plain(endMs)
	return endMs and endMs / 1000 or nil
end

local function OnCastStart(unit, castGUID, spellID)
	castGUID = Plain(castGUID)
	local caster = GUIDOf(unit)
	if not caster then
		return
	end
	local hint = caster == ns.playerGUID and sent and sent.castGUID == castGUID and sent.name or nil
	local target, how = ns.FindTarget(unit, hint)
	local ends = CastEnd(unit)
	local name = Plain(UnitName(unit))
	local cast = ns.casts[caster]
	if not (cast and not cast.stopped and cast.castGUID == castGUID) then
		ns.Debug(L["%s casts %s on %s (%s)."], name or unit, Plain(SpellName(spellID)) or "?",
			target and NameOfGUID(target) or "?", HOW[how])
	end
	ns.StartCast(caster, castGUID, target, name, ClassOf(unit), ends, how == "name")
	if unit == "player" then
		-- Only a target found by name is worth sharing: the others are guesses
		-- every client can make itself.
		ns.Share("S", castGUID, how == "name" and target or nil, ends and format("%.1f", ends - GetTime()) or nil)
	end
end

local function AnyoneDead()
	local dead = false
	ForEachGroupUnit(function(unit)
		dead = UnitIsDeadOrGhost(unit)
		return dead
	end)
	return dead
end

-- Debug line for a hidden cast. The game lets its spell and target be shown,
-- though not read: printing them works (the line then can't be copied out of
-- chat), and a pcall keeps a refusal from stopping the cast being handled.
local function DebugHidden(unit, spellID, name)
	local shown = pcall(function()
		local spell = C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(spellID)
		local aim = UnitSpellTargetName and UnitSpellTargetName(unit)
		local who = type(aim) == "nil" and L["no one"] or tostring(aim) -- type() is safe on secrets
		ns.Debug(L["%s casts %s on %s."], name, tostring(spell), who)
	end)
	if not shown then
		ns.Debug(L["%s casts something the game hides from addons."], name)
	end
end

-- Another player's cast, which the game hides from addons. RezWatch can't
-- tell what it is, but asks the game whether it is aimed at each dead player
-- (SampleTargets): a heal can't be, so only a res ever shows.
local function OnHiddenCastStart(unit, spellID)
	local caster = GUIDOf(unit)
	if not caster or caster == ns.playerGUID or not UnitIsSpellTarget or not AnyoneDead() then
		return
	end
	local known = ns.casts[caster]
	if known and known.target then
		return -- the caster's RezWatch already said where it goes
	end
	local record = ns.hidden[caster]
	if record and not record.stopped then
		return -- the same cast, seen through another unit token
	end
	local name = Plain(UnitName(unit)) or unit
	record = { caster = caster, name = name, class = ClassOf(unit), started = GetTime(), targets = {} }
	local plain, target = SampleTargets(record, unit)
	if ns.db.debug then
		DebugHidden(unit, spellID, name)
	end
	if plain then
		-- The game answered plainly: aimed at a dead player, so a res on them.
		if target then
			ns.StartCast(caster, nil, target, name, record.class, nil, true)
		end
		return
	end
	ns.hidden[caster] = record
	ns.Changed()
end

-- A hidden cast ended. One that landed keeps the game's answers as an offer,
-- shown green until it is accepted (the player comes alive) or runs out.
local function OnHiddenCastEnd(caster, record, outcome)
	local now = GetTime()
	if outcome == "stop" then
		record.stopped = record.stopped or now
	else
		ns.hidden[caster] = nil
		if outcome == "done" and now - record.started >= RES_MIN_CAST then
			record.landed, record.expires = now, now + ACCEPT_TIME
			tinsert(ns.hiddenOffers, record)
		end
	end
	ns.Changed()
end

local function OnCastEnd(unit, castGUID, spellID, outcome)
	castGUID = Plain(castGUID)
	local caster = GUIDOf(unit)
	if not caster or (castGUID and finished[castGUID]) then
		return
	end
	local record = ns.hidden[caster]
	if record then
		OnHiddenCastEnd(caster, record, outcome)
		if not ns.casts[caster] then
			return
		end
	end
	if not ns.casts[caster] then
		-- Instant resurrections have no start; only a landed one matters.
		if outcome ~= "done" or not ns.IsResSpell(spellID) then
			return
		end
		OnCastStart(unit, castGUID, spellID)
	end
	if outcome ~= "stop" and castGUID then
		finished[castGUID] = GetTime()
	end
	ns.StopCast(caster, castGUID, outcome)
	if unit == "player" and outcome ~= "stop" then
		ns.Share(outcome == "done" and "D" or "X", castGUID)
	end
end

function ns.ForgetFinished(now)
	for castGUID, time in pairs(finished) do
		if now - time > 10 then
			finished[castGUID] = nil
		end
	end
end

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")

local handlers = {}

function handlers.ADDON_LOADED(name)
	if name ~= ADDON then
		return
	end
	events:UnregisterEvent("ADDON_LOADED")
	_G.RezWatchDB = _G.RezWatchDB or {}
	ns.db = _G.RezWatchDB
	for key, value in pairs(ns.DEFAULTS) do
		if ns.db[key] == nil then
			ns.db[key] = value
		end
	end
end

-- The player's own offer was declined or ran out (Blizzard's dialog calls these).
local function OwnOfferGone()
	if ns.playerGUID and ns.offers[ns.playerGUID] then
		ns.OfferGone(ns.playerGUID)
		ns.Share("N")
	end
end

function handlers.PLAYER_LOGIN()
	ns.playerGUID = UnitGUID("player")
	LoadSpells()
	if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
		C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
	end
	for _, event in ipairs({
		"PLAYER_ENTERING_WORLD", "GROUP_ROSTER_UPDATE", "CHAT_MSG_ADDON", "INCOMING_RESURRECT_CHANGED",
		"RESURRECT_REQUEST", "UNIT_SPELLCAST_SENT", "UNIT_SPELLCAST_START", "UNIT_SPELLCAST_STOP",
		"UNIT_SPELLCAST_FAILED", "UNIT_SPELLCAST_INTERRUPTED", "UNIT_SPELLCAST_SUCCEEDED",
	}) do
		pcall(events.RegisterEvent, events, event)
	end
	for _, name in ipairs({ "DeclineResurrect", "TimeoutResurrect" }) do
		if type(_G[name]) == "function" then
			hooksecurefunc(name, OwnOfferGone)
		end
	end
	MapUnits()
end

function handlers.PLAYER_ENTERING_WORLD()
	MapUnits()
	ns.Display.Dirty()
	ns.Changed()
end
handlers.GROUP_ROSTER_UPDATE = handlers.PLAYER_ENTERING_WORLD

function handlers.CHAT_MSG_ADDON(prefix, message)
	if prefix == PREFIX and type(message) == "string" then
		ns.Receive(message)
	end
end

function handlers.INCOMING_RESURRECT_CHANGED(unit)
	if not ns.IsGroupToken(unit) then
		return
	end
	local guid = GUIDOf(unit)
	if guid and Plain(UnitHasIncomingResurrection(unit)) then
		ns.incoming[guid] = true
	end
	ns.Changed()
end

-- A res landed on the player: tell the group, since only this client knows for sure.
function handlers.RESURRECT_REQUEST(inviter)
	if not ns.playerGUID or not UnitIsDeadOrGhost("player") then
		return
	end
	inviter = Plain(inviter)
	local seconds = ACCEPT_TIME + (GetCorpseRecoveryDelay and Plain(GetCorpseRecoveryDelay()) or 0)
	ns.Debug(L["You have a res from %s."], inviter or "?")
	ns.Offered(ns.playerGUID, inviter, seconds)
	ns.Share("O", inviter, format("%d", seconds))
end

function handlers.UNIT_SPELLCAST_SENT(unit, target, castGUID, spellID)
	if unit == "player" and ns.IsResSpell(spellID) then
		sent = { castGUID = Plain(castGUID), name = Plain(target) }
	end
end

function handlers.UNIT_SPELLCAST_START(unit, castGUID, spellID)
	if not ns.IsGroupToken(unit) then
		return
	end
	if Plain(spellID) == nil then
		OnHiddenCastStart(unit, spellID)
		return
	end
	if ns.IsResSpell(spellID) then
		OnCastStart(unit, castGUID, spellID)
	end
end

local OUTCOMES = {
	UNIT_SPELLCAST_STOP = "stop",
	UNIT_SPELLCAST_FAILED = "fail",
	UNIT_SPELLCAST_INTERRUPTED = "fail",
	UNIT_SPELLCAST_SUCCEEDED = "done",
}

for event, outcome in pairs(OUTCOMES) do
	handlers[event] = function(unit, castGUID, spellID)
		if ns.IsGroupToken(unit) then
			OnCastEnd(unit, castGUID, spellID, outcome)
		end
	end
end

events:SetScript("OnEvent", function(_, event, ...)
	handlers[event](...)
end)

--------------------------------------------------------------------------------
-- Slash command
--------------------------------------------------------------------------------

local POINTS = {
	TOPLEFT = true, TOP = true, TOPRIGHT = true, LEFT = true, CENTER = true, RIGHT = true,
	BOTTOMLEFT = true, BOTTOM = true, BOTTOMRIGHT = true,
}

local TOGGLES = {
	names = { "showNames", L["Caster names"] },
	accept = { "showAccept", L["Icon while a res waits to be accepted"] },
	warn = { "warn", L["Warning when your target already has a res coming"] },
	sound = { "sound", L["Sound with the warning"] },
	share = { "share", L["Sharing your res target with other RezWatch users"] },
	debug = { "debug", L["Printing what RezWatch sees of each res"] },
}
local TOGGLE_ORDER = { "names", "accept", "warn", "sound", "share", "debug" }

local function OnOff(value)
	return value and ("|cff40ff40" .. L["on"] .. "|r") or ("|cffff4040" .. L["off"] .. "|r")
end

local function Help()
	local db = ns.db
	ns:Print(L["Shows an icon on raid frames when a dead player is being resurrected. Commands:"])
	ns:Print("/rezwatch test - " .. L["show test icons on your group's frames"])
	ns:Print("/rezwatch size <8-64> - " .. L["icon size (now %d)"], db.iconSize)
	ns:Print("/rezwatch anchor <point> [x y] - " .. L["icon position on the frame (now %s %d %d)"],
		db.point, db.x, db.y)
	for _, key in ipairs(TOGGLE_ORDER) do
		local toggle = TOGGLES[key]
		ns:Print("/rezwatch %s - %s: %s", key, toggle[2], OnOff(db[toggle[1]]))
	end
	ns:Print("/rezwatch reset - " .. L["back to the default settings"])
end

local function Slash(message)
	local command, rest = (message or ""):match("^%s*(%S*)%s*(.-)%s*$")
	command = command:lower()
	local db = ns.db
	if command == "test" then
		ns.StartTest()
	elseif command == "size" then
		local size = tonumber(rest)
		if size and size >= 8 and size <= 64 then
			db.iconSize = size
			ns.StartTest()
		else
			ns:Print(L["The size must be a number from 8 to 64."])
		end
	elseif command == "anchor" then
		local point, x, y = rest:upper():match("^(%a+)%s*(%-?%d*)%s*(%-?%d*)$")
		if point and POINTS[point] then
			db.point, db.x, db.y = point, tonumber(x) or 0, tonumber(y) or 0
			ns.StartTest()
		else
			ns:Print(L["Points: TOPLEFT, TOP, TOPRIGHT, LEFT, CENTER, RIGHT, BOTTOMLEFT, BOTTOM, BOTTOMRIGHT."])
		end
	elseif TOGGLES[command] then
		local key, label = TOGGLES[command][1], TOGGLES[command][2]
		db[key] = not db[key]
		ns:Print("%s: %s", label, OnOff(db[key]))
		ns.Changed()
	elseif command == "reset" then
		wipe(db)
		for key, value in pairs(ns.DEFAULTS) do
			db[key] = value
		end
		ns:Print(L["Settings reset."])
		ns.Changed()
	else
		Help()
	end
end

_G.SLASH_REZWATCH1 = "/rezwatch"
_G.SLASH_REZWATCH2 = "/rezw"
_G.SlashCmdList.REZWATCH = Slash
