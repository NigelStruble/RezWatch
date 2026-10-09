-- Runs RezWatch against the mock client in tests/mock_wow.lua.
-- Usage, from the repository root:  lua5.1 tests/run_tests.lua

package.path = "tests/?.lua;" .. package.path
local Mock = require("mock_wow")

local ADDON_DIR = "RezWatch"
local passed, failed = 0, 0
local current

local function check(condition, message, ...)
	if condition then
		passed = passed + 1
	else
		failed = failed + 1
		print(("    FAIL [%s] " .. message):format(current, ...))
	end
	return condition
end

local function equal(actual, expected, what)
	return check(actual == expected, "%s: expected %s, got %s", what, tostring(expected), tostring(actual))
end

local function test(name, func)
	current = name
	local before = failed
	local ok, err = xpcall(func, debug.traceback)
	if not ok then
		failed = failed + 1
		print("    ERROR " .. tostring(err))
	end
	print(((ok and failed == before) and "ok     " or "FAILED ") .. name)
end

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

-- Forever characters have surnames: UnitName returns both.
local PARTY = {
	{ name = "Vedek", surname = "Md", class = "PRIEST" },
	{ name = "Armor", surname = "Gurd", class = "PALADIN" },
	{ name = "Tank", surname = "Smith", class = "WARRIOR", dead = true },
	{ name = "Mage", surname = "Jones", class = "MAGE", dead = true },
	{ name = "Shammy", surname = "Oak", class = "SHAMAN" },
}

-- Starts a client with the given members (copied) and loads the addon.
local function Start(members, raid, savedVariables)
	local env, state = Mock.New()
	for i, member in ipairs(members or PARTY) do
		local copy = {}
		for k, v in pairs(member) do copy[k] = v end
		state.members[i] = copy
	end
	state.raid = raid or false
	env.RezWatchDB = savedVariables
	local ns = Mock.Load(env, ADDON_DIR)
	state.Fire("ADDON_LOADED", "RezWatch")
	state.Fire("PLAYER_LOGIN")
	state.MakeButtons()
	state.Fire("PLAYER_ENTERING_WORLD")
	return env, state, ns
end

-- What the event payloads look like to the addon: like Forever's client, the
-- game hides other players' casts (secret values) but not the player's own.
local function Hider(state, i, hidden)
	if hidden == nil then
		hidden = i ~= 1
	end
	return function(value)
		if hidden then return state.Secret(value) end
		return value
	end, hidden
end

local castCount = 0

-- Member i starts a cast aimed at j (a member's index, "stranger", or nil).
-- By default the caster targets j first; with options.click the cast goes
-- through a click-cast or mouseover, so the caster's target stays as it was.
-- options.sent is the target name the player's own UNIT_SPELLCAST_SENT gives
-- (default "First Last"); options.hidden = false shows another player's cast
-- as an older client would.
local function Cast(state, i, j, options)
	options = options or {}
	castCount = castCount + 1
	local castGUID = "Cast-3-" .. castCount
	local spellID = options.spellID or 2006
	local target = type(j) == "number" and state.members[j]
	if j and not options.click then
		state.members[i].target = j
	end
	local R, hidden = Hider(state, i, options.hidden)
	state.casting[i] = {
		castGUID = castGUID, spellID = spellID, target = j, hidden = hidden,
		endMs = (state.time + (options.seconds or 10)) * 1000,
	}
	if i == 1 then
		local sent = options.sent or (target and (target.name .. " " .. target.surname)) or ""
		state.Fire("UNIT_SPELLCAST_SENT", "player", R(sent), R(castGUID), R(spellID))
	end
	if options.late then
		state.casting[i].target = nil -- the game doesn't know the target yet at the start
	end
	for _, unit in ipairs(options.tokens or { state.Token(i) }) do
		state.Fire("UNIT_SPELLCAST_START", unit, R(castGUID), R(spellID), nil)
	end
	state.casting[i].target = j
	return castGUID
end

local function Finish(state, i, castGUID, outcome, tokens)
	local cast = state.casting[i] or {}
	local spellID = cast.spellID or 2006
	local R = Hider(state, i, cast.hidden)
	state.casting[i] = nil
	for _, unit in ipairs(tokens or { state.Token(i) }) do
		if outcome == "done" then
			state.Fire("UNIT_SPELLCAST_SUCCEEDED", unit, R(castGUID), R(spellID))
			state.Fire("UNIT_SPELLCAST_STOP", unit, R(castGUID), R(spellID))
		elseif outcome == "interrupt" then
			state.Fire("UNIT_SPELLCAST_INTERRUPTED", unit, R(castGUID), R(spellID))
			state.Fire("UNIT_SPELLCAST_STOP", unit, R(castGUID), R(spellID))
		else -- moved or cancelled
			state.Fire("UNIT_SPELLCAST_STOP", unit, R(castGUID), R(spellID))
		end
	end
end

-- What member i's raid frame really shows (see state.Seen in the mock).
local function Shows(state, i)
	return state.Seen(i).icons > 0
end

local function HasText(state, i, text)
	for _, shown in ipairs(state.Seen(i).texts) do
		if shown == text then
			return true
		end
	end
	return false
end

local function Texts(state, i)
	return table.concat(state.Seen(i).texts, " | ")
end

local function Plain(text)
	return text and (text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))
end

local function Printed(state, text)
	for _, line in ipairs(state.printed) do
		if Plain(line):find(text, 1, true) then
			return true
		end
	end
	return false
end

local function CountPrinted(state, text)
	local count = 0
	for _, line in ipairs(state.printed) do
		if Plain(line):find(text, 1, true) then
			count = count + 1
		end
	end
	return count
end

local function Sent(state, kind)
	local found = {}
	for _, message in ipairs(state.sent) do
		if message.message:sub(1, #kind + 1) == kind .. "," then
			found[#found + 1] = message.message
		end
	end
	return found
end

local function Message(state, text)
	state.Fire("CHAT_MSG_ADDON", "RezWatch", text, "PARTY", "Someone")
end

--------------------------------------------------------------------------------
-- Other players' casts, which the game hides from addons
--------------------------------------------------------------------------------

test("loads with defaults and registers its prefix", function()
	local env, state, ns = Start()
	equal(env.RezWatchDB.iconSize, 24, "icon size")
	equal(env.RezWatchDB.debug, false, "debug off")
	equal(ns.playerGUID, "Player-1-1", "player GUID")
	check(env.SlashCmdList.REZWATCH ~= nil, "slash command")
	check(not Shows(state, 3), "no icon at rest")
end)

test("a hidden res shows only on the player it is aimed at", function()
	local env, state = Start(nil, false, { debug = true })
	Cast(state, 2, 3, { spellID = 7328 })
	check(Shows(state, 3), "icon on the dead tank")
	check(HasText(state, 3, "Armor"), "caster name: " .. Texts(state, 3))
	check(not Shows(state, 4), "no icon on the other dead player")
	check(not Shows(state, 2), "no icon on the caster")
	check(not HasText(state, 3, "2"), "no count for a single res")
	check(Printed(state, "Armor casts <secret> on <secret>."), "debug shows the spell and target as the game does")
	equal(#state.printed, 1, "one debug line")
end)

test("a heal on himself shows nothing; his res then shows (in-game report)", function()
	local members = {
		{ name = "Vedex", surname = "Vicious", class = "MAGE", dead = true },
		{ name = "Skynado", surname = "Airwalker", class = "SHAMAN" },
	}
	local env, state = Start(members)
	local heal = Cast(state, 2, 2, { click = true, spellID = 939 }) -- Healing Wave on himself
	check(not Shows(state, 1), "no icon for the heal")
	state.Advance(2.5)
	Finish(state, 2, heal, "done")
	state.Advance(1)
	check(not Shows(state, 1), "no icon after the heal lands")
	Cast(state, 2, 1, { spellID = 20609 }) -- Ancestral Spirit on the dead player
	check(Shows(state, 1), "icon for the res")
	check(HasText(state, 1, "Skynado"), "caster: " .. Texts(state, 1))
end)

test("an answer the game doesn't have yet at the start shows on the next update", function()
	local env, state = Start()
	Cast(state, 2, 3, { late = true })
	check(not Shows(state, 3), "nothing yet")
	state.Advance(0.3)
	check(Shows(state, 3), "icon once the game answers")
end)

test("click-cast with several dead: the icon goes on the right one", function()
	local env, state = Start()
	Cast(state, 2, 4, { click = true })
	check(Shows(state, 4), "icon on the mage it is aimed at")
	check(not Shows(state, 3), "none on the tank")
end)

test("any class's cast aimed at a dead player is a res (Goblin Jumper Cables)", function()
	local members = {
		{ name = "Vedek", surname = "Md", class = "PRIEST" },
		{ name = "Frosty", surname = "Ice", class = "MAGE" },
		{ name = "Tank", surname = "Smith", class = "WARRIOR", dead = true },
	}
	local env, state = Start(members)
	Cast(state, 2, 3, { spellID = 8342 })
	check(Shows(state, 3), "icon")
end)

test("in combat a heal shows nothing and a battle res does", function()
	local members = {
		{ name = "Vedek", surname = "Md", class = "PRIEST" },
		{ name = "Druid", surname = "Oak", class = "DRUID", combat = true },
		{ name = "Tank", surname = "Smith", class = "WARRIOR", dead = true },
	}
	local env, state = Start(members)
	local heal = Cast(state, 2, 2, { click = true })
	check(not Shows(state, 3), "no icon for the heal")
	Finish(state, 2, heal, "done")
	Cast(state, 2, 3, { click = true, spellID = 20484 })
	check(Shows(state, 3), "a battle res shows")
end)

test("hidden casts while nobody is dead are ignored quietly", function()
	local members = {
		{ name = "Vedek", surname = "Md", class = "PRIEST" },
		{ name = "Armor", surname = "Gurd", class = "PALADIN" },
	}
	local env, state = Start(members, false, { debug = true })
	Cast(state, 2, 1)
	equal(#state.printed, 0, "no debug line")
end)

test("a cast at a dead player outside the group shows nothing", function()
	local members = {
		{ name = "Vedek", surname = "Md", class = "PRIEST" },
		{ name = "Armor", surname = "Gurd", class = "PALADIN" },
		{ name = "Tank", surname = "Smith", class = "WARRIOR", dead = true },
	}
	local env, state = Start(members)
	Cast(state, 2, "stranger")
	check(not Shows(state, 3), "nothing on the group")
end)

test("when the game answers plainly, RezWatch knows the target", function()
	local env, state, ns = Start()
	state.plainSpellTarget = true
	Cast(state, 2, 3)
	check(Shows(state, 3), "icon")
	check(ns.casts["Player-1-2"] and ns.casts["Player-1-2"].target == "Player-1-3", "known as an exact cast")
	Cast(state, 5, 5, { click = true })
	check(ns.casts["Player-1-5"] == nil, "a heal is not a res")
	check(not Shows(state, 4), "nothing for it")
end)

test("a cast the game shows (older clients) is read exactly", function()
	local env, state = Start(nil, false, { debug = true })
	Cast(state, 2, 3, { hidden = false, spellID = 7328 })
	check(Shows(state, 3), "icon")
	check(Printed(state, "Armor casts Redemption on Tank (the caster's target)."), "read as a res")
end)

test("debug output that can't show the hidden spell doesn't break detection", function()
	local env, state = Start(nil, false, { debug = true })
	env.C_Spell.GetSpellName = function() error("attempt to use a secret value") end
	Cast(state, 2, 3)
	check(Shows(state, 3), "icon still shown")
	check(Printed(state, "Armor casts something the game hides from addons."), "plain debug line instead")
end)

test("debug: one line per cast, nothing when it is off", function()
	local env, state = Start(nil, false, { debug = true })
	local cast = Cast(state, 2, 3)
	Finish(state, 2, cast, "interrupt")
	Cast(state, 5, 4)
	equal(#state.printed, 2, "two casts, two lines")
	local env2, state2 = Start()
	Cast(state2, 2, 3)
	Cast(state2, 1, 4)
	equal(#state2.printed, 0, "nothing without debug")
end)

--------------------------------------------------------------------------------
-- The player's own casts
--------------------------------------------------------------------------------

test("own cast: the name the game gives (First Last) beats the target", function()
	local env, state = Start()
	state.members[1].target = 4 -- the player has the mage targeted but clicks the tank's frame
	Cast(state, 1, 3, { click = true })
	check(Shows(state, 3), "icon on the tank")
	check(not Shows(state, 4), "not on the targeted mage")
	local starts = Sent(state, "S")
	equal(#starts, 1, "one start message")
	check(starts[1] and starts[1]:find(",Player-1-3,", 1, true) ~= nil, "message names the tank: " .. tostring(starts[1]))
end)

test("own cast: every form of the name is understood", function()
	for _, sent in ipairs({ "Tank", "Tank Smith", "Tank-Realm", "Tank Smith-Realm" }) do
		local env, state = Start()
		Cast(state, 1, 3, { click = true, sent = sent })
		check(Shows(state, 3), "icon for %q", sent)
	end
end)

test("own cast: the surname picks between players with one first name", function()
	local members = {
		{ name = "Vedek", surname = "Md", class = "PRIEST" },
		{ name = "Sam", surname = "One", class = "WARRIOR", dead = true },
		{ name = "Sam", surname = "Two", class = "MAGE", dead = true },
	}
	local env, state = Start(members)
	Cast(state, 1, 3, { click = true, sent = "Sam Two" })
	check(Shows(state, 3) and not Shows(state, 2), "icon on Sam Two only")
end)

test("own cast on someone outside the group: no icon", function()
	local members = {
		{ name = "Vedek", surname = "Md", class = "PRIEST" },
		{ name = "Tank", surname = "Smith", class = "WARRIOR", dead = true },
	}
	local env, state = Start(members)
	Cast(state, 1, nil, { click = true, sent = "Stranger Danger" })
	check(not Shows(state, 2), "the only dead group member isn't assumed")
end)

test("own cast: spell ranks unknown to the list match by name", function()
	local env, state = Start()
	Cast(state, 1, 4, { spellID = 99999 })
	check(Shows(state, 4), "icon for an unlisted Resurrection rank")
end)

test("own cast: other spells are ignored", function()
	local env, state = Start()
	Cast(state, 1, 3, { spellID = 133 })
	check(not Shows(state, 3), "no icon for Fireball")
end)

--------------------------------------------------------------------------------
-- Cast lifecycle
--------------------------------------------------------------------------------

test("two ressers on one player: both names and a red 2", function()
	local env, state = Start()
	Cast(state, 2, 3, { spellID = 7328 })
	state.Advance(0.5)
	Cast(state, 5, 3, { spellID = 2008 })
	check(Shows(state, 3), "icon")
	check(HasText(state, 3, "Armor, Shammy"), "both names: " .. Texts(state, 3))
	check(HasText(state, 3, "2"), "red count")
end)

test("two ressers on different players: no 2", function()
	local env, state = Start()
	Cast(state, 2, 3)
	Cast(state, 5, 4)
	check(HasText(state, 3, "Armor") and not HasText(state, 3, "2"), "tank: " .. Texts(state, 3))
	check(HasText(state, 4, "Shammy") and not HasText(state, 4, "2"), "mage: " .. Texts(state, 4))
end)

test("a cancelled cast removes the icon", function()
	local env, state = Start()
	local cast = Cast(state, 2, 3)
	Finish(state, 2, cast, "stop")
	state.Advance(1)
	check(not Shows(state, 3), "icon gone after the cast stopped")
end)

test("an interrupted cast removes the icon at once", function()
	local env, state = Start()
	local cast = Cast(state, 2, 3)
	Finish(state, 2, cast, "interrupt")
	check(not Shows(state, 3), "icon gone")
end)

test("a landed res stays green until accepted", function()
	local env, state = Start()
	local cast = Cast(state, 2, 3)
	state.Advance(10)
	Finish(state, 2, cast, "done")
	state.Advance(1)
	check(Shows(state, 3), "icon kept while the offer waits")
	check(state.Seen(3).green, "green")
	check(HasText(state, 3, "Rezzed"), "text: " .. Texts(state, 3))
	check(not Shows(state, 4), "not on the other dead player")
	state.members[3].dead = false
	state.Advance(0.3)
	check(not Shows(state, 3), "icon gone once alive")
end)

test("a landing shorter than a res keeps nothing", function()
	local env, state = Start()
	local cast = Cast(state, 2, 3, { spellID = 20484 })
	state.Advance(2)
	Finish(state, 2, cast, "done")
	state.Advance(1)
	check(not Shows(state, 3), "no green after a 2 second cast")
end)

test("SUCCEEDED after STOP still counts as landed", function()
	local env, state = Start()
	Cast(state, 2, 3)
	state.Advance(10)
	state.casting[2] = nil
	local secret = state.SECRET
	state.Fire("UNIT_SPELLCAST_STOP", "party1", secret, secret)
	state.Advance(0.1)
	state.Fire("UNIT_SPELLCAST_SUCCEEDED", "party1", secret, secret)
	state.Advance(1)
	check(HasText(state, 3, "Rezzed"), "offer recorded: " .. Texts(state, 3))
end)

test("an unaccepted offer expires after a minute", function()
	local env, state = Start()
	local cast = Cast(state, 2, 3)
	state.Advance(10)
	Finish(state, 2, cast, "done")
	state.Advance(59)
	check(Shows(state, 3), "still shown at 59 s")
	state.Advance(2)
	check(not Shows(state, 3), "gone after 60 s")
end)

test("accept option off: icon gone when the cast lands", function()
	local env, state = Start(nil, false, { showAccept = false })
	local cast = Cast(state, 2, 3)
	state.Advance(10)
	Finish(state, 2, cast, "done")
	state.Advance(1)
	check(not Shows(state, 3), "no icon")
end)

test("a landed res and a new res on the same player: red 2", function()
	local env, state = Start()
	local first = Cast(state, 2, 3)
	state.Advance(10)
	Finish(state, 2, first, "done")
	Cast(state, 5, 3)
	check(HasText(state, 3, "2"), "red count: " .. Texts(state, 3))
end)

test("instant resurrections leave an offer (when the game shows the cast)", function()
	local env, state = Start()
	state.members[2].target = 3
	state.Fire("UNIT_SPELLCAST_SUCCEEDED", "party1", "Cast-3-instant", 2006)
	state.Advance(0.6)
	check(HasText(state, 3, "Rezzed"), "offer shown: " .. Texts(state, 3))
end)

test("a hidden cast vanishes if its end is never seen", function()
	local env, state = Start()
	Cast(state, 2, 3)
	state.Advance(14)
	check(Shows(state, 3), "still there at 14 s")
	state.Advance(2)
	check(not Shows(state, 3), "dropped after 15 s")
end)

test("a caster leaving the group drops the cast", function()
	local env, state = Start()
	Cast(state, 5, 3)
	table.remove(state.members, 5)
	state.Fire("GROUP_ROSTER_UPDATE")
	state.Advance(0.3)
	check(not Shows(state, 3), "dropped")
end)

test("works in a raid with raid unit tokens", function()
	local env, state = Start(nil, true)
	Cast(state, 5, 4, { spellID = 20484 })
	check(Shows(state, 4), "icon on raid4")
	check(HasText(state, 4, "Shammy"), "caster: " .. Texts(state, 4))
end)

test("in a raid the player's events come twice: one message, one offer", function()
	local env, state = Start(nil, true, { debug = true })
	local tokens = { "player", "raid1" }
	local cast = Cast(state, 1, 3, { click = true, tokens = tokens })
	Finish(state, 1, cast, "done", tokens)
	state.Advance(1)
	equal(#Sent(state, "S"), 1, "start messages")
	equal(#Sent(state, "D"), 1, "done messages")
	check(HasText(state, 3, "Rezzed"), "offer: " .. Texts(state, 3))
	equal(CountPrinted(state, "casts Resurrection"), 1, "one debug line")
end)

--------------------------------------------------------------------------------
-- Warnings and doubles
--------------------------------------------------------------------------------

test("own cast warns when a RezWatch user already casts on the target", function()
	local env, state = Start()
	Message(state, "S,Player-1-2,Cast-3-x,Player-1-3,8.0")
	local cast = Cast(state, 1, 3)
	check(Printed(state, "Tank is also being resurrected by Armor"), "warning printed")
	equal(state.sounds, 1, "sound played")
	Finish(state, 1, cast, "done")
	equal(#Sent(state, "D"), 1, "done message")
end)

test("own cast on a player someone else is ressing (hidden): red 2 on the frame", function()
	local env, state = Start()
	Cast(state, 2, 3)
	Cast(state, 1, 3)
	check(HasText(state, 3, "Vedek"), "own name: " .. Texts(state, 3))
	check(not HasText(state, 3, "Armor"), "the hidden name gives way")
	check(HasText(state, 3, "2"), "red count")
end)

test("warns when the target already has an offer waiting", function()
	local env, state = Start()
	Message(state, "O,Player-1-3,Armor Gurd,60")
	Cast(state, 1, 3)
	check(Printed(state, "waiting to be accepted"), "warning printed")
end)

test("no warning when ressing someone nobody else is on", function()
	local env, state = Start()
	Cast(state, 2, 3)
	Cast(state, 1, 4)
	equal(#state.printed, 0, "nothing printed")
end)

--------------------------------------------------------------------------------
-- Messages between RezWatch users
--------------------------------------------------------------------------------

test("a caster's message shows their target", function()
	local env, state = Start()
	Message(state, "S,Player-1-2,Cast-3-x,Player-1-4,8.0")
	check(Shows(state, 4), "icon from the message")
	check(HasText(state, 4, "Armor"), "caster from the message")
	Message(state, "X,Player-1-2,Cast-3-x")
	check(not Shows(state, 4), "cancel message clears it")
end)

test("a caster's message takes over from the hidden cast (no false 2)", function()
	local env, state = Start()
	Cast(state, 2, 3)
	Message(state, "S,Player-1-2,Cast-3-x,Player-1-3,9.0")
	check(Shows(state, 3), "icon")
	check(HasText(state, 3, "Armor"), "name")
	check(not HasText(state, 3, "2"), "one res, not two: " .. Texts(state, 3))
end)

test("a message without a target keeps the hidden cast showing", function()
	local env, state = Start()
	local cast = Cast(state, 2, 3)
	Message(state, "S,Player-1-2," .. cast .. ",,9.0")
	check(Shows(state, 3), "still on the tank")
	Finish(state, 2, cast, "interrupt")
	check(not Shows(state, 3), "and gone when it ends")
end)

test("a dead player's offer message turns their frame green", function()
	local env, state = Start()
	Message(state, "O,Player-1-3,Armor Gurd,60")
	check(Shows(state, 3), "icon")
	check(HasText(state, 3, "Rezzed"), "text")
	Message(state, "N,Player-1-3")
	check(not Shows(state, 3), "declined: gone")
end)

test("an offer message takes over from the same res seen hidden (no false 2)", function()
	local env, state = Start()
	local cast = Cast(state, 2, 3)
	state.Advance(10)
	Finish(state, 2, cast, "done")
	Message(state, "O,Player-1-3,Armor Gurd,60")
	check(HasText(state, 3, "Rezzed"), "green")
	check(not HasText(state, 3, "2"), "one offer, not two: " .. Texts(state, 3))
end)

test("an offer message moves a wrongly guessed offer (visible casts)", function()
	local env, state = Start()
	state.members[2].target = 4
	local cast = Cast(state, 2, 3, { click = true, hidden = false })
	state.Advance(10)
	Finish(state, 2, cast, "done")
	check(Shows(state, 4), "guessed offer on the mage")
	Message(state, "O,Player-1-3,Armor,60")
	check(Shows(state, 3), "offer on the tank")
	check(not Shows(state, 4), "guess dropped")
end)

test("when the player gets a res, the group hears it; declining clears it", function()
	local env, state = Start()
	state.members[1].dead = true
	state.Fire("RESURRECT_REQUEST", "Armor Gurd")
	local offers = Sent(state, "O")
	equal(#offers, 1, "offer message")
	equal(offers[1], "O,Player-1-1,Armor Gurd,60", "message")
	check(HasText(state, 1, "Rezzed"), "own frame shows it")
	env.DeclineResurrect()
	equal(state.declined, 1, "the game's decline still ran")
	equal(#Sent(state, "N"), 1, "decline message")
	check(not Shows(state, 1), "own frame cleared")
end)

test("own messages and strangers are ignored", function()
	local env, state = Start()
	Message(state, "S,Player-1-1,c,Player-1-3,8")
	Message(state, "S,Player-9-9,c,Player-1-3,8")
	Message(state, "O,Player-9-9,Armor,60")
	Message(state, "garbage")
	check(not Shows(state, 3), "no icon")
end)

test("the game's own incoming-res flag shows an icon too", function()
	local env, state = Start()
	state.incoming[4] = true
	state.Fire("INCOMING_RESURRECT_CHANGED", "party3")
	check(Shows(state, 4), "icon")
	equal(#state.Seen(4).texts, 0, "no names")
	state.incoming[4] = nil
	state.Advance(0.3)
	check(not Shows(state, 4), "gone when the flag drops")
end)

--------------------------------------------------------------------------------
-- Display and settings
--------------------------------------------------------------------------------

test("test mode paints every frame, then clears", function()
	local env, state = Start()
	env.SlashCmdList.REZWATCH("test")
	for i = 1, #state.members do
		check(Shows(state, i), "test icon on member %d", i)
	end
	check(HasText(state, 2, "2"), "second frame shows two ressers")
	state.Advance(16)
	for i = 1, #state.members do
		check(not Shows(state, i), "cleared on member %d", i)
	end
end)

test("slash settings: size, anchor, toggles, reset", function()
	local env, state = Start()
	local slash = env.SlashCmdList.REZWATCH
	slash("size 30")
	equal(env.RezWatchDB.iconSize, 30, "size")
	slash("size 300")
	equal(env.RezWatchDB.iconSize, 30, "bad size refused")
	slash("anchor topleft 2 -3")
	equal(env.RezWatchDB.point, "TOPLEFT", "point")
	equal(env.RezWatchDB.x, 2, "x")
	equal(env.RezWatchDB.y, -3, "y")
	slash("anchor nowhere")
	equal(env.RezWatchDB.point, "TOPLEFT", "bad point refused")
	slash("names")
	equal(env.RezWatchDB.showNames, false, "names off")
	equal(#state.Seen(1).texts, 0, "names hidden")
	slash("debug")
	equal(env.RezWatchDB.debug, true, "debug on")
	slash("reset")
	equal(env.RezWatchDB.iconSize, 24, "reset size")
	equal(env.RezWatchDB.showNames, true, "reset names")
	equal(env.RezWatchDB.debug, false, "reset debug")
	slash("")
	check(Printed(state, "/rezwatch debug"), "help lists debug")
end)

test("names off hides the names of hidden casts too", function()
	local env, state = Start(nil, false, { showNames = false })
	Cast(state, 2, 3)
	Cast(state, 5, 3)
	check(Shows(state, 3), "icon")
	check(not HasText(state, 3, "Armor") and not HasText(state, 3, "Armor, Shammy"), "no names: " .. Texts(state, 3))
	check(HasText(state, 3, "2"), "the count stays")
end)

test("icon fits small frames", function()
	local env, state = Start()
	state.buttons[3]:SetSize(60, 18)
	Cast(state, 1, 3)
	equal(state.Overlay(3).icon.width, 16, "icon shrinks to the frame")
end)

test("hidden frames get no icon; debug says so once", function()
	local env, state = Start(nil, false, { debug = true })
	state.buttons[3]:Hide()
	Cast(state, 1, 3)
	state.Advance(1)
	check(not Shows(state, 3), "no icon on a hidden frame")
	equal(CountPrinted(state, "No raid frame RezWatch can find shows Tank"), 1, "reported once")
end)

print(("\n%d passed, %d failed"):format(passed, failed))
if failed > 0 then
	os.exit(1)
end
