--!strict
-- Screens: menu, inventory, character (field experience), notebook (discoveries, research, placed markers),
-- party, settings, shelter (fortification, upgrades, crafting, escrow, class), mission browser, quartermaster.
-- Every list has an explicit empty state; actions show insufficient-resource text instead of failing silently.
-- One modal at a time. Panels pushed by the server never replace the class briefing, and the shelter panel
-- (pushed to every occupant after any upgrade) never replaces another open screen: it waits in the menu.
-- Any screen but the briefing steps aside when a dangerous creature's approach cue arrives or the player goes down.
-- Pending party invitations are answered on the Party screen.

local Players = game:GetService("Players")
local UI = require(script.Parent.UI)
local UIRules = require(script.Parent.UIRules)

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local ItemDefs = require(Shared:WaitForChild("Data"):WaitForChild("ItemDefs"))
local Commerce = require(Shared:WaitForChild("Logic"):WaitForChild("Commerce"))

local Panels = {}
local ctx: any
local C = UI.Colors
local current: string? = nil
local root: Frame? = nil
local cache: { [string]: any } = { discoveries = {}, research = {}, story = nil, onboarding = nil, shelter = nil }
local partySignature = ""
local extraMenu: { { label: string, name: string } } = {}
local wasDowned = false

local BTN = 48 -- minimum touch target height for panel buttons (section 17: 48-56 px)

local CLASS_TEXT = {
	Explorer = "Lights last about 5% longer.",
	Medic = "Treats wounds about 5% faster.",
	Runner = "Recovers stamina about 5% faster.",
	Technician = "Repairs and crafts about 5% faster.",
}

local CHALK_PRESETS = { "arrow", "danger", "shelter", "exit", "water", "x", "route_a", "route_b", "route_c" }
local SIGN_PRESETS = { "to_shelter", "to_exit", "danger_ahead", "water_crossing", "dead_end", "rescue_here" }

-- Short item descriptions for the inventory (fictional and game-oriented; no real medical instruction).
-- ItemDefs may later carry its own `description`, which then wins.
local DESCRIPTIONS: { [string]: string } = {
	["light.pocket_torch"] = "A short, narrow beam. Easy on the cell.",
	["light.expedition_flashlight"] = "A long, bright beam that drains the cell faster.",
	["light.compact_headlamp"] = "A wide beam that frees your hands; modest reach.",
	["light.shielded_lantern"] = "Lights all around you, for everyone nearby, but shows creatures where you are. Close the shutters (V) for a dim, quiet glow.",
	["power.cell"] = "Swap it in (R) to refill your light.",
	["med.cloth_dressing"] = "Heals a little. Does not fix an injury.",
	["med.bandage"] = "Heals well and removes an injury.",
	["med.splint"] = "Heals a little and removes an injury, so sprint and stamina recover.",
	["tool.stun_device"] = "Repels creatures that can be stunned. Limited charges.",
	["tool.iron_bar"] = "Hurts only vulnerable creatures.",
	["tool.flare"] = "Place it ahead (N): a red light for everyone that burns for a while. Some creatures turn toward it.",
	["tool.repair_roll"] = "Tools for fuse and breaker work. Never used up.",
	["tool.fuse_kit"] = "Replaces a burnt fuse in a junction box. Used up when fitted.",
	["mat.fuse_component"] = "Two, with a fastener, make a fuse kit.",
	["mat.battery_housing"] = "With a fastener, becomes a replaceable cell.",
	["mat.fabric"] = "For dressings and splints.",
	["mat.fastener"] = "Holds repairs and crafted items together.",
	["mat.plank"] = "For barricades, workbenches and splints.",
	["mat.bracket"] = "For barricades and doors.",
	["mat.chalk_fragment"] = "Three make a usable chalk stick.",
	["nav.chalk"] = "Draws a marker only you and your party see. Kept when you die.",
	["nav.sign"] = "A labelled route sign. Kept when you die.",
	["nav.rope"] = "A continuous guide line. Kept when you die.",
	["evidence.waterworks_log"] = "A record from the waterworks. Story item: kept when you die.",
	["evidence.station_tape"] = "A recording from the survey station. Story item: kept when you die.",
	["treasure.old_expedition_tag"] = "Story item: kept when you die.",
}

local function itemName(id: string): string
	local d = ItemDefs.get(id)
	return if d then d.displayName else (string.gsub(string.match(id, "%.(.+)$") or id, "_", " "))
end

local function describe(id: string): string?
	local d = ItemDefs.get(id)
	local own = d and (d :: any).description
	if type(own) == "string" then
		return own
	end
	if DESCRIPTIONS[id] then
		return DESCRIPTIONS[id]
	end
	if d and d.category == "treasure" then
		return "Sell it at the depot for coins."
	end
	return nil
end

local function countsText(map: { [string]: number }): string
	local parts = {}
	for id, n in map do
		table.insert(parts, n .. "× " .. itemName(id))
	end
	table.sort(parts)
	return table.concat(parts, ", ")
end

local function close()
	if root then
		root:Destroy()
		root = nil
	end
	current = nil
end

local function open(name: string, title: string): ScrollingFrame
	close()
	current = name
	local r, body = UI.panel(ctx.gui, title, close)
	root = r
	return body
end

local function nice(id: string): string
	return (string.gsub(id, "_", " "))
end

-- A panel button at least BTN tall unless a size is given.
local function button(parent: Instance, text: string, onClick: () -> (), props: { [string]: any }?): TextButton
	local p: { [string]: any } = props or {}
	if p.Size == nil then
		p.Size = UDim2.new(1, 0, 0, BTN)
	end
	return UI.button(parent, text, onClick, p)
end

local renderers: { [string]: () -> () } = {}

local function inShelter(): boolean
	local v = ctx.state.vitals
	return v ~= nil and v.inShelter ~= nil
end

renderers.menu = function()
	local b = open("menu", "Expedition")
	local entries = {
		{ "Inventory", "inventory" },
		{ "Character", "character" },
		{ "Field notebook", "notebook" },
		{ "Party", "party" },
		{ "Settings", "settings" },
	}
	for _, e in extraMenu do
		table.insert(entries, { e.label, e.name })
	end
	for _, e in entries do
		button(b, e[1], function()
			Panels.toggle(e[2])
		end, { Size = UDim2.new(1, 0, 0, UI.TOUCH) })
	end
	if inShelter() then
		button(b, "Shelter", function()
			if cache.shelter then
				Panels.shelter(cache.shelter, true)
			else
				close()
			end
			ctx.send("shelter.panel")
		end, { Size = UDim2.new(1, 0, 0, UI.TOUCH), BackgroundColor3 = C.teal })
	end
end

renderers.inventory = function()
	local b = open("inventory", "Inventory")
	local d = ctx.state.inventory
	if not d or #d.items == 0 then
		UI.label(
			b,
			"You are carrying nothing. Crates in the quarry and the quartermaster at the depot are sources of supplies.",
			15,
			C.dim
		)
		return
	end
	UI.label(b, string.format("Coins: %d · Class: %s", d.coins, d.class), 15)
	UI.label(
		b,
		"Expedition items are lost to a bag if you die or log out before reaching a shelter. Protected items (navigation supplies) are always kept.",
		13,
		C.dim
	)
	local v = ctx.state.vitals
	for _, it in d.items do
		local row = UI.frame(b, { Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y })
		UI.corner(row)
		UI.pad(row, 6)
		UI.list(row, 4)
		local tags = {}
		if it.protected then
			table.insert(tags, "PROTECTED")
		end
		if it.expedition > 0 then
			table.insert(tags, it.expedition .. " unbanked")
		end
		local equipped = it.category == "light" and v ~= nil and v.lightName == it.name
		if equipped then
			table.insert(tags, "EQUIPPED")
		end
		UI.label(
			row,
			string.format(
				"%s ×%d %s",
				it.name,
				it.loadout + it.expedition,
				if #tags > 0 then ("· " .. table.concat(tags, " · ")) else ""
			),
			15
		)
		local text = describe(it.id)
		if text then
			UI.label(row, text, 13, C.dim)
		end
		if it.category == "light" then
			if not equipped then
				button(row, "Equip", function()
					ctx.send("light.equip", { itemId = it.id })
				end, { Size = UDim2.new(0, 140, 0, BTN) })
			elseif v and v.isLantern then
				button(row, if v.shielded then "Open the shutters" else "Close the shutters", function()
					ctx.send("light.shield")
				end, { Size = UDim2.new(0, 200, 0, BTN) })
			end
		elseif it.category == "medical" then
			button(row, "Use on self", function()
				ctx.send("med.use", { itemId = it.id })
				close()
			end, { Size = UDim2.new(0, 160, 0, BTN) })
			local party = ctx.state.party
			if party then
				for _, m in party.members do
					if m.userId ~= Players.LocalPlayer.UserId then
						button(row, "Treat " .. m.name, function()
							ctx.send("med.use", { itemId = it.id, targetUserId = m.userId })
							close()
						end, { Size = UDim2.new(0, 200, 0, BTN), BackgroundColor3 = C.teal })
					end
				end
			end
		elseif it.id == "tool.flare" then
			button(row, "Light a flare ahead", function()
				ctx.send("flare.place")
				close()
			end, { Size = UDim2.new(0, 200, 0, BTN) })
		elseif it.id == "nav.chalk" or it.id == "nav.sign" then
			local presets: { string } = if it.id == "nav.chalk" then CHALK_PRESETS else SIGN_PRESETS
			local key = if it.id == "nav.chalk" then "chalkPreset" else "signPreset"
			local holder = UI.frame(
				row,
				{ Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1 }
			)
			local g = Instance.new("UIGridLayout")
			g.CellSize = UDim2.fromOffset(120, BTN)
			g.CellPadding = UDim2.fromOffset(4, 4)
			g.Parent = holder
			local presetButtons: { [string]: TextButton } = {}
			-- The chosen preset carries a tick and an outline as well as the amber fill (never colour alone).
			local function recolor()
				local cur = ctx.state[key] or presets[1]
				for p, pb in presetButtons do
					local sel = cur == p
					pb.BackgroundColor3 = if sel then C.amber else C.dim
					pb.Text = (if sel then "✓ " else "") .. nice(p)
					local stroke = pb:FindFirstChildOfClass("UIStroke")
					if sel and not stroke then
						local s = Instance.new("UIStroke")
						s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
						s.Color = C.bone
						s.Thickness = 2
						s.Parent = pb
					elseif not sel and stroke then
						stroke:Destroy()
					end
				end
			end
			for _, p in presets do
				presetButtons[p] = UI.button(holder, nice(p), function()
					ctx.state[key] = p
					recolor() -- the highlight follows the choice at once
					ctx.hud.notice("Marker: " .. nice(p), "info")
				end, { TextWrapped = true })
			end
			recolor()
		end
	end
end

-- Character: field experience (F24, D37). Gains shrink with each rank; equipment stays the larger advantage.
renderers.character = function()
	local b = open("character", "Character")
	local inv = ctx.state.inventory
	if inv then
		UI.label(b, string.format("Class: %s", inv.class), 17)
		if CLASS_TEXT[inv.class] then
			UI.label(b, CLASS_TEXT[inv.class], 13, C.dim)
		end
	end
	UI.label(b, "Field experience", 17)
	local p = ctx.state.progression
	if not p then
		UI.label(b, "No field experience recorded yet.", 14, C.dim)
	else
		UI.label(b, string.format("Rank %d · %d experience", p.rank, p.xp), 15)
		UI.label(
			b,
			string.format("Next rank at %d (%d to go).", p.nextRankXp, math.max(0, p.nextRankXp - p.xp)),
			14,
			C.dim
		)
		UI.label(
			b,
			string.format(
				"Max stamina +%d (never more than +%d) · Max health +%d (never more than +%d)",
				p.staminaBonus,
				p.staminaCap or 15,
				p.healthBonus,
				p.healthCap or 15
			),
			14
		)
	end
	UI.label(
		b,
		"Experience comes from discovering places and shelters, creature research, story steps, rescues and missions — each counts once.",
		13,
		C.dim
	)
	UI.label(
		b,
		"Each rank adds less than the one before. Equipment and what you know remain your largest advantage; creatures never grow stronger with your rank.",
		13,
		C.dim
	)
	UI.label(b, "Automatic recovery still stops at half of your (raised) maximum health.", 13, C.dim)
end

renderers.notebook = function()
	local b = open("notebook", "Field notebook")
	local story = cache.story
	if story then
		UI.label(b, story.act, 17)
		for _, e in story.journal do
			UI.label(b, (if e.done then "✓ " else "• ") .. e.text, 14, if e.done then C.dim else C.bone)
		end
		if not story.complete then
			UI.label(b, "Now: " .. story.objective, 14, C.amber)
		end
	end
	UI.label(b, "Discovered places", 17)
	local labels = {}
	for _, label in cache.discoveries do
		table.insert(labels, label)
	end
	table.sort(labels)
	for _, label in labels do
		UI.label(b, "• " .. label, 14)
	end
	if #labels == 0 then
		UI.label(b, "Nothing recorded yet.", 14, C.dim)
	end
	UI.label(b, "Creature research", 17)
	local entries = {}
	for _, e in cache.research do
		table.insert(entries, e)
	end
	table.sort(entries, function(x, y)
		return tostring(x.name) < tostring(y.name)
	end)
	for _, e in entries do
		UI.label(b, string.format("• %s — %s (%d/%d)", e.name, nice(e.stageName), e.stage, e.stages), 14)
		if e.nextHint then
			UI.label(b, "    next: " .. e.nextHint, 13, C.dim)
		end
	end
	if #entries == 0 then
		UI.label(b, "No observations yet. Entries record evidence, not certainty.", 14, C.dim)
	end
	UI.label(b, "Your placed markers", 17)
	local nav = ctx.state.nav or {}
	local mine = 0
	for _, rec in nav do
		if rec.isOwn then
			mine += 1
			local row = UI.frame(b, { Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y })
			UI.pad(row, 4)
			UI.list(row, 2)
			UI.label(
				row,
				string.format(
					"%s “%s” at (%d, %d)%s",
					rec.kind,
					nice(rec.content),
					math.floor(rec.position.X),
					math.floor(rec.position.Z),
					-- a record a variable pocket moved to its survey anchor (docs/MILESTONE-3.md section 3, rule 5)
					if rec.migratedFrom then " (moved: the passage changed)" else ""
				),
				14
			)
			button(row, if rec.allowPartyRecovery then "Party may pick up: ON" else "Party may pick up: OFF", function()
				ctx.send("nav.partyRecovery", { recordId = rec.recordId, allow = not rec.allowPartyRecovery })
			end, { Size = UDim2.new(0, 240, 0, BTN), BackgroundColor3 = C.teal })
		end
	end
	if mine == 0 then
		UI.label(b, "None placed. Placed chalk, signs and rope stay until you pick them up.", 14, C.dim)
	end
end

renderers.party = function()
	local b = open("party", "Party")
	-- A pending invitation is answered here (the HUD only names it).
	local invite = ctx.hud.pendingInvite()
	if invite then
		UI.label(b, invite.fromName .. " invites you to explore together.", 16, C.teal)
		button(b, "Accept invitation", function()
			ctx.hud.answerInvite(true)
		end, { BackgroundColor3 = C.teal })
		button(b, "Decline invitation", function()
			ctx.hud.answerInvite(false)
		end, { BackgroundColor3 = C.dim })
	end
	local party = ctx.state.party
	if party and #party.members > 0 then
		UI.label(b, "Current party (this session only)", 16, C.teal)
		for _, m in party.members do
			local row = UI.frame(
				b,
				{ Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1 }
			)
			UI.list(row, 2)
			UI.label(
				row,
				string.format("%s%s — %s", if m.leader then "★ " else "", m.name, m.condition),
				15,
				C.teal
			)
			if party.isLeader and m.userId ~= Players.LocalPlayer.UserId then
				button(row, "Remove", function()
					ctx.send("party.remove", { userId = m.userId })
				end, { Size = UDim2.new(0, 120, 0, BTN), BackgroundColor3 = C.dim })
			end
		end
		button(b, "Leave party", function()
			ctx.send("party.leave")
			close()
		end, { BackgroundColor3 = C.dim })
	else
		UI.label(b, "You are exploring solo. Parties are optional and last only for this session.", 15, C.dim)
	end
	UI.label(b, "Invite someone on this server", 16)
	local roster = ctx.state.roster or {}
	local any = false
	for _, p in roster do
		if p.userId ~= Players.LocalPlayer.UserId then
			any = true
			button(b, "Invite " .. p.name, function()
				ctx.send("party.invite", { userId = p.userId })
			end, { BackgroundColor3 = C.teal })
		end
	end
	if not any then
		UI.label(b, "Nobody else is here right now.", 14, C.dim)
	end
end

renderers.settings = function()
	local b = open("settings", "Settings")
	local S = ctx.settings
	local function toggle(key: string, label: string)
		button(b, string.format("%s: %s", label, if S.get(key) then "ON" else "OFF"), function()
			S.set(key, not S.get(key))
			renderers.settings()
		end, { BackgroundColor3 = C.dim })
	end
	local function stepper(key: string, label: string, step: number, lo: number, hi: number, fmt: string)
		local row = UI.frame(b, { Size = UDim2.new(1, 0, 0, BTN), BackgroundTransparency = 1 })
		UI.list(row, 6, true)
		local t = UI.label(row, string.format("%s: " .. fmt, label, S.get(key)), 15)
		t.Size = UDim2.new(0.5, 0, 0, BTN)
		t.AutomaticSize = Enum.AutomaticSize.None
		UI.button(row, "−", function()
			S.set(key, math.clamp(S.get(key) - step, lo, hi))
			renderers.settings()
		end, { Size = UDim2.fromOffset(UI.TOUCH, BTN) })
		UI.button(row, "+", function()
			S.set(key, math.clamp(S.get(key) + step, lo, hi))
			renderers.settings()
		end, { Size = UDim2.fromOffset(UI.TOUCH, BTN) })
	end
	toggle("subtitles", "Subtitles for speech and creature cues")
	toggle("reduceFlashes", "Reduce flashes and flicker")
	toggle("reduceCameraMotion", "Reduce camera motion")
	toggle("sprintToggle", "Sprint toggles (instead of hold)")
	toggle("crosshair", "Center marker")
	toggle("showPressureDebug", "Developer: show director pressure")
	stepper("textScale", "Text size", 0.1, 0.8, 1.6, "%.1f×")
	stepper("sensitivity", "Look sensitivity", 0.1, 0.2, 3, "%.1f")
	stepper("fieldOfView", "Field of view", 5, 60, 100, "%d")
	stepper("lowLightBoost", "Low-light calibration", 0.1, 0, 1, "%.1f")
	UI.label(b, "Text size applies to newly opened screens.", 12, C.dim)
end

local function refreshIf(name: string)
	if current == name and renderers[name] then
		renderers[name]()
	end
end

function Panels.init(c)
	ctx = c
	ctx.settings.onChanged(function(k, v)
		if k == "textScale" then
			UI.TextScale = v
		end
	end)
	-- Join-time notebook snapshot (the server sends discoveries and research once; live pushes add to it).
	ctx.on("notebook", function(d: any)
		if type(d) ~= "table" then
			return
		end
		for _, e in d.discoveries or {} do
			cache.discoveries[e.id] = e.label
		end
		for _, e in d.research or {} do
			cache.research[e.id] = e
		end
		refreshIf("notebook")
	end)
	ctx.on("progression", function()
		refreshIf("character")
	end)
	ctx.on("vitals", function(d: any)
		-- leaving the shelter forgets its panel snapshot (the menu entry disappears with it)
		if type(d) == "table" and d.inShelter == nil then
			cache.shelter = nil
		end
		-- going down closes the open screen so the DOWN text and the world stay visible (not the first-join briefing);
		-- only on the change, so a screen can still be opened while waiting for help
		local downed = type(d) == "table" and d.condition == "downed"
		if downed and not wasDowned and current ~= nil and current ~= "onboarding" then
			close()
		end
		wasDowned = downed
	end)
	-- A screen never covers the view during a chase: a dangerous creature's approach cue closes it (PROPOSED).
	ctx.on("cue", function(d: any)
		if UIRules.isThreatCue(d) and current ~= nil and current ~= "onboarding" then
			close()
		end
	end)
end

function Panels.toggle(name: string)
	if current == name then
		close()
		return
	end
	local r = renderers[name]
	if r then
		r()
	end
end

-- Small public API so client Features share the single modal instead of stacking their own.
function Panels.register(name: string, render: () -> ())
	renderers[name] = render
end
function Panels.open(name: string, title: string): ScrollingFrame
	return open(name, title)
end
function Panels.close()
	close()
end
function Panels.current(): string?
	return current
end
function Panels.refreshIf(name: string)
	refreshIf(name)
end
function Panels.addMenuEntry(label: string, name: string)
	table.insert(extraMenu, { label = label, name = name })
end

function Panels.inventory(_d)
	refreshIf("inventory")
end
-- The party payload arrives every second; rebuild only when something visible changed.
function Panels.party(d)
	local parts = { tostring(d and d.isLeader) }
	local members: { any } = (d and d.members) or {}
	for _, m in members do
		table.insert(
			parts,
			string.format("%s:%s:%s:%s", tostring(m.userId), tostring(m.condition), tostring(m.leader), m.name)
		)
	end
	local sig = table.concat(parts, "|")
	if sig ~= partySignature then
		partySignature = sig
		refreshIf("party")
	end
end
function Panels.roster(_d)
	-- roster updates often; only refresh if the party screen is open and idle
end
function Panels.nav(_d)
	refreshIf("notebook")
end
function Panels.discovery(d)
	cache.discoveries[d.id] = d.label
	refreshIf("notebook")
end
function Panels.research(d)
	cache.research[d.id] = d
	refreshIf("notebook")
end

function Panels.story(d)
	cache.story = d
	refreshIf("notebook")
end

-- First join: choose a starting class (free once; later changes cost earned coins at a shelter).
function Panels.onboarding(d)
	if d.done then
		if current == "onboarding" then
			close()
		end
		return
	end
	cache.onboarding = d
	local b = open("onboarding", "Before you descend")
	UI.label(b, "You are joining the search for a survey team that vanished below the recorded quarries.", 15)
	UI.label(b, "• Light and medical supplies keep you alive. Running low makes things bolder.", 14, C.dim)
	UI.label(
		b,
		"• Loot you pick up is EXPEDITION loot until you reach a shelter. Die or log out first and it stays behind in a bag.",
		14,
		C.dim
	)
	UI.label(b, "• Chalk, signs and rope are PROTECTED: you always keep unused ones.", 14, C.dim)
	UI.label(
		b,
		"• Run, hide in niches, or throw a stone to draw attention away. Not everything can be fought.",
		14,
		C.dim
	)
	UI.label(b, "Choose a starting class. Every class can do everything; each starts with a small edge.", 15)
	local names = {}
	if type(d.classes) == "table" then
		for name in d.classes do
			if type(name) == "string" then
				table.insert(names, name)
			end
		end
	end
	if #names == 0 then
		names = { "Explorer", "Medic", "Runner", "Technician" }
	end
	table.sort(names)
	for _, name in names do
		button(b, name .. " — " .. (CLASS_TEXT[name] or "A small head start."), function()
			ctx.send("onboard.choose", { className = name })
		end, { Size = UDim2.new(1, 0, 0, UI.TOUCH) })
	end
end

-- Server-pushed screens the player asked for (board, shop) may replace another screen, never the briefing.
local function mayOpenRequested(): boolean
	return current ~= "onboarding"
end

function Panels.missionList(list)
	if not mayOpenRequested() then
		return
	end
	local b = open("missions", "Missions")
	UI.label(b, "Estimated lengths and risk are rough. There is no GPS route — follow the clues.", 13, C.dim)
	-- A built mission that is neither available nor cooling down (and gives no reason of its own) is blocked by
	-- the active mission: say so once, with one Abandon button, instead of on every row.
	local function blockedByActive(m: any): boolean
		return m.status == "SLICE"
			and not m.available
			and not (m.cooldown and m.cooldown > 0)
			and type(m.reason) ~= "string"
	end
	local active = false
	for _, m in list do
		if blockedByActive(m) then
			active = true
		end
	end
	if active then
		UI.label(b, "You already have an active mission.", 14, C.warn)
		button(b, "Abandon current mission", function()
			ctx.send("mission.abandon")
			close()
		end, { Size = UDim2.new(0, 240, 0, BTN), BackgroundColor3 = C.dim })
	end
	for _, m in list do
		local row = UI.frame(b, { Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y })
		UI.corner(row)
		UI.pad(row, 6)
		UI.list(row, 4)
		UI.label(
			row,
			string.format(
				"%s %s%s",
				m.id,
				m.name,
				if m.estimate then (" · " .. m.estimate .. " · risk " .. tostring(m.risk)) else ""
			),
			15
		)
		if m.status ~= "SLICE" then
			UI.label(row, "Planned — not built in this milestone.", 13, C.dim)
		elseif m.available and type(m.locked) == "string" then
			-- the server explains why accepting would be refused right now (it refuses with the same words)
			UI.label(row, m.locked, 13, C.dim)
		elseif m.available then
			button(row, "Accept", function()
				ctx.send("mission.accept", { id = m.id })
				close()
			end, { Size = UDim2.new(0, 140, 0, BTN) })
		elseif m.cooldown and m.cooldown > 0 then
			UI.label(row, string.format("Available again in %ds.", m.cooldown), 13, C.dim)
		elseif type(m.reason) == "string" then
			UI.label(row, m.reason, 13, C.dim)
		else
			UI.label(row, "Unavailable while another mission is active.", 13, C.dim)
		end
	end
end

-- Why a recipe cannot be crafted, in words (the server decides; this only explains the preview).
local function craftBlocker(r: any): string
	if r.missing and next(r.missing) ~= nil then
		return "Missing " .. countsText(r.missing)
	end
	local recipe = Commerce.recipe(r.id)
	local inv = ctx.state.inventory
	if recipe and inv then
		local def = ItemDefs.get(recipe.output)
		local have = 0
		for _, it in inv.items do
			if it.id == recipe.output then
				have = it.loadout + it.expedition
			end
		end
		if def and have + recipe.outputCount > def.stackLimit then
			return "No room to carry more " .. def.displayName
		end
	end
	return if r.requiresWorkbench then "Needs a workbench here" else "Cannot craft that here"
end

local function renderShelter(d: any)
	local b = open("shelter", d.name)
	local fortText = {
		discovered = "DISCOVERED — entrances are vulnerable. Relatively safe, not completely.",
		patched = "PATCHED — some entrances protected.",
		secured = "SECURED — creatures cannot enter or harm anyone inside.",
	}
	UI.label(
		b,
		fortText[d.fortification] or d.fortification,
		16,
		if d.fortification == "secured" then C.teal else C.warn
	)
	for _, e in d.entrances do
		UI.label(b, string.format("• %s: %s", nice(e.id), if e.protected then "protected" else "VULNERABLE"), 14)
	end
	UI.label(
		b,
		string.format(
			"Passive recovery here stops at %d%% health. Medical supplies heal further.",
			math.floor(d.passiveCap * 100)
		),
		13,
		C.dim
	)
	UI.label(b, "Improvements", 17)
	for _, u in d.upgrades do
		local row = UI.frame(b, { Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y })
		UI.corner(row)
		UI.pad(row, 6)
		UI.list(row, 3)
		UI.label(row, string.format("%s (%s) — stage %d/%d", nice(u.id), u.kind, u.stage, u.maxStage), 15)
		if u.cost and u.locked then
			-- grant-only improvements (e.g. station power: repair the breaker cabinet instead)
			UI.label(row, "Needs: " .. countsText(u.cost), 13, C.dim)
			UI.label(row, tostring(u.lockReason or "Cannot be built from this panel."), 13, C.warn)
		elseif u.cost then
			UI.label(row, "Needs: " .. countsText(u.cost), 13, C.dim)
			button(row, if u.affordable then "Build" else "Not enough materials", function()
				if u.affordable then
					ctx.send("shelter.upgrade", { upgradeId = u.id })
				end
			end, { Size = UDim2.new(0, 240, 0, BTN), BackgroundColor3 = if u.affordable then C.amber else C.dim })
		else
			UI.label(row, "Complete.", 13, C.teal)
		end
	end
	UI.label(b, "Crafting", 17)
	if #d.recipes == 0 then
		UI.label(b, "No recipes known.", 13, C.dim)
	end
	for _, r in d.recipes do
		local row = UI.frame(b, { Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y })
		UI.pad(row, 6)
		UI.list(row, 3)
		-- Preview: exactly what is used and what is made (the craft is all-or-nothing on the server).
		UI.label(
			row,
			string.format(
				"%s ×%d ← %s%s",
				r.output,
				r.outputCount,
				countsText(r.inputs),
				if r.requiresWorkbench then " (workbench)" else ""
			),
			14
		)
		if not r.canCraft then
			UI.label(row, craftBlocker(r), 13, C.warn)
		end
		button(row, if r.canCraft then "Craft" else "Cannot craft yet", function()
			if r.canCraft then
				ctx.send("shelter.craft", { recipeId = r.id })
			end
		end, { Size = UDim2.new(0, 220, 0, BTN), BackgroundColor3 = if r.canCraft then C.amber else C.dim })
	end
	UI.label(b, "Recovery escrow", 17)
	if next(d.escrow) == nil then
		UI.label(b, "Empty. Items a party member recovers from your bags arrive here.", 13, C.dim)
	else
		UI.label(b, countsText(d.escrow), 14)
		button(b, "Collect escrow", function()
			ctx.send("shelter.escrow")
		end)
	end
	UI.label(b, string.format("Class: %s (coins %d)", d.class, d.coins), 17)
	UI.label(
		b,
		string.format(
			"Classes give small (~5%%) head starts; everyone can do everything. Changing costs %d earned coins.",
			d.classCost
		),
		13,
		C.dim
	)
	for _, cls in d.classes do
		if cls ~= d.class then
			button(b, "Switch to " .. cls, function()
				ctx.send("shelter.class", { className = cls })
			end, { BackgroundColor3 = if d.coins >= d.classCost then C.amber else C.dim })
		end
	end
	button(b, "Missions", function()
		ctx.send("mission.list")
	end, { BackgroundColor3 = C.teal })
	button(b, "Leave shelter", function()
		ctx.send("shelter.exit")
		close()
	end, { BackgroundColor3 = C.dim })
end

-- The shelter panel is pushed on entry and to every occupant after any upgrade or craft. It refreshes when it
-- is already open or nothing is open; otherwise it waits in the menu ("Shelter") instead of replacing the
-- screen someone is using. `requested` is the menu entry reopening it.
function Panels.shelter(d: any, requested: boolean?)
	if not d.open then
		cache.shelter = nil
		if current == "shelter" then
			close()
		end
		return
	end
	cache.shelter = d
	if current == "onboarding" then
		return
	end
	if requested or current == "shelter" or (current == nil and not d.quiet) then
		renderShelter(d)
	end
end

function Panels.shop(d: any)
	if not mayOpenRequested() then
		return
	end
	local b = open("shop", if type(d.vendor) == "string" then d.vendor .. " — quartermaster" else "Quartermaster")
	UI.label(b, string.format("Coins: %d. Everything here can also be found in the tunnels.", d.coins), 14)
	UI.label(b, "Buy", 17)
	for _, e in d.buy do
		local full = e.have >= e.limit
		button(b, string.format("%s — %d coins (have %d)", e.name, e.price, e.have), function()
			ctx.send("shop.buy", { itemId = e.itemId })
		end, { BackgroundColor3 = if d.coins >= e.price and not full then C.amber else C.dim })
	end
	UI.label(b, "Sell treasures", 17)
	if #d.sell == 0 then
		UI.label(b, "No sellable treasures. Unique story items are never sold here.", 13, C.dim)
	end
	for _, e in d.sell do
		button(b, string.format("Sell %s for %d (have %d)", e.name, e.value, e.have), function()
			ctx.send("shop.sell", { itemId = e.itemId })
		end, { BackgroundColor3 = C.teal })
	end
	UI.label(b, "Store", 17)
	if not d.storeConfigured then
		UI.label(b, "No products are configured in this build. Purchases are never required to explore.", 13, C.dim)
	end
	for _, p in d.products do
		button(
			b,
			string.format("%s — %s", p.name, if p.price then (p.price .. " Robux") else "price unavailable"),
			function()
				ctx.send("shop.product", { productId = p.productId })
			end,
			{ BackgroundColor3 = C.dim }
		)
	end
end

return Panels
