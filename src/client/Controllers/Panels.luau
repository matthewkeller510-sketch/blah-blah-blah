--!strict
-- Milestone 1 screens: menu, inventory, notebook (discoveries, research, placed markers), party, settings,
-- shelter (fortification, upgrades, crafting, escrow, class), mission browser, quartermaster.
-- Every list has an explicit empty state; actions show insufficient-resource text instead of failing silently.

local Players = game:GetService("Players")
local UI = require(script.Parent.UI)

local Panels = {}
local ctx: any
local C = UI.Colors
local current: string? = nil
local root: Frame? = nil
local cache: { [string]: any } = { discoveries = {}, research = {}, story = nil, onboarding = nil }

local CLASS_TEXT = {
	Explorer = "Lights last about 5% longer.",
	Medic = "Treats wounds about 5% faster.",
	Runner = "Recovers stamina about 5% faster.",
	Technician = "Repairs and crafts about 5% faster.",
}

local CHALK_PRESETS = { "arrow", "danger", "shelter", "exit", "water", "x", "route_a", "route_b", "route_c" }
local SIGN_PRESETS = { "to_shelter", "to_exit", "danger_ahead", "water_crossing", "dead_end", "rescue_here" }

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

local renderers: { [string]: () -> () } = {}

renderers.menu = function()
	local b = open("menu", "Expedition")
	for _, e in {
		{ "Inventory", "inventory" }, { "Field notebook", "notebook" }, { "Party", "party" }, { "Settings", "settings" },
	} do
		UI.button(b, e[1], function()
			Panels.toggle(e[2])
		end, { Size = UDim2.new(1, 0, 0, UI.TOUCH) })
	end
end

renderers.inventory = function()
	local b = open("inventory", "Inventory")
	local d = ctx.state.inventory
	if not d or #d.items == 0 then
		UI.label(b, "You are carrying nothing. Crates in the quarry and the quartermaster at the depot are sources of supplies.", 15, C.dim)
		return
	end
	UI.label(b, string.format("Coins: %d · Class: %s", d.coins, d.class), 15)
	UI.label(b, "Expedition items are lost to a bag if you die or log out before reaching a shelter. Protected items (navigation supplies) are always kept.", 13, C.dim)
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
		UI.label(row, string.format("%s ×%d %s", it.name, it.loadout + it.expedition, if #tags > 0 then ("· " .. table.concat(tags, " · ")) else ""), 15)
		if it.category == "light" then
			UI.button(row, "Equip", function()
				ctx.send("light.equip", { itemId = it.id })
			end, { Size = UDim2.new(0, 120, 0, 36) })
		elseif it.category == "medical" then
			UI.button(row, "Use on self", function()
				ctx.send("med.use", { itemId = it.id })
				close()
			end, { Size = UDim2.new(0, 140, 0, 36) })
			local party = ctx.state.party
			if party then
				for _, m in party.members do
					if m.userId ~= Players.LocalPlayer.UserId then
						UI.button(row, "Treat " .. m.name, function()
							ctx.send("med.use", { itemId = it.id, targetUserId = m.userId })
							close()
						end, { Size = UDim2.new(0, 180, 0, 36), BackgroundColor3 = C.teal })
					end
				end
			end
		elseif it.id == "nav.chalk" or it.id == "nav.sign" then
			local presets = if it.id == "nav.chalk" then CHALK_PRESETS else SIGN_PRESETS
			local key = if it.id == "nav.chalk" then "chalkPreset" else "signPreset"
			local holder = UI.frame(row, { Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1 })
			local g = Instance.new("UIGridLayout")
			g.CellSize = UDim2.fromOffset(110, 34)
			g.CellPadding = UDim2.fromOffset(4, 4)
			g.Parent = holder
			for _, p in presets do
				UI.button(holder, nice(p), function()
					ctx.state[key] = p
					ctx.hud.notice("Marker: " .. nice(p), "info")
				end, { BackgroundColor3 = if (ctx.state[key] or presets[1]) == p then C.amber else C.dim })
			end
		end
	end
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
	local n = 0
	for _, label in cache.discoveries do
		UI.label(b, "• " .. label, 14)
		n += 1
	end
	if n == 0 then
		UI.label(b, "Nothing recorded yet.", 14, C.dim)
	end
	UI.label(b, "Creature research", 17)
	local r = 0
	for _, e in cache.research do
		UI.label(b, string.format("• %s — %s (%d/%d)", e.name, nice(e.stageName), e.stage, e.stages), 14)
		if e.nextHint then
			UI.label(b, "    next: " .. e.nextHint, 13, C.dim)
		end
		r += 1
	end
	if r == 0 then
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
			UI.label(row, string.format("%s “%s” at (%d, %d)", rec.kind, nice(rec.content), math.floor(rec.position.X), math.floor(rec.position.Z)), 14)
			UI.button(row, if rec.allowPartyRecovery then "Party may pick up: ON" else "Party may pick up: OFF", function()
				ctx.send("nav.partyRecovery", { recordId = rec.recordId, allow = not rec.allowPartyRecovery })
			end, { Size = UDim2.new(0, 220, 0, 32), BackgroundColor3 = C.teal })
		end
	end
	if mine == 0 then
		UI.label(b, "None placed. Placed chalk, signs and rope stay until you pick them up.", 14, C.dim)
	end
end

renderers.party = function()
	local b = open("party", "Party")
	local party = ctx.state.party
	if party and #party.members > 0 then
		UI.label(b, "Current party (this session only)", 16, C.teal)
		for _, m in party.members do
			local row = UI.frame(b, { Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1 })
			UI.list(row, 2)
			UI.label(row, string.format("%s%s — %s", if m.leader then "★ " else "", m.name, m.condition), 15, C.teal)
			if party.isLeader and m.userId ~= Players.LocalPlayer.UserId then
				UI.button(row, "Remove", function()
					ctx.send("party.remove", { userId = m.userId })
				end, { Size = UDim2.new(0, 110, 0, 32), BackgroundColor3 = C.dim })
			end
		end
		UI.button(b, "Leave party", function()
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
			UI.button(b, "Invite " .. p.name, function()
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
		UI.button(b, string.format("%s: %s", label, if S.get(key) then "ON" else "OFF"), function()
			S.set(key, not S.get(key))
			renderers.settings()
		end, { BackgroundColor3 = C.dim })
	end
	local function stepper(key: string, label: string, step: number, lo: number, hi: number, fmt: string)
		local row = UI.frame(b, { Size = UDim2.new(1, 0, 0, 40), BackgroundTransparency = 1 })
		UI.list(row, 6, true)
		local t = UI.label(row, string.format("%s: " .. fmt, label, S.get(key)), 15)
		t.Size = UDim2.new(0.5, 0, 0, 40)
		t.AutomaticSize = Enum.AutomaticSize.None
		UI.button(row, "−", function()
			S.set(key, math.clamp(S.get(key) - step, lo, hi))
			renderers.settings()
		end, { Size = UDim2.fromOffset(UI.TOUCH, 40) })
		UI.button(row, "+", function()
			S.set(key, math.clamp(S.get(key) + step, lo, hi))
			renderers.settings()
		end, { Size = UDim2.fromOffset(UI.TOUCH, 40) })
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

function Panels.init(c)
	ctx = c
	ctx.settings.onChanged(function(k, v)
		if k == "textScale" then
			UI.TextScale = v
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

local function refreshIf(name: string)
	if current == name and renderers[name] then
		renderers[name]()
	end
end

function Panels.inventory(_d)
	refreshIf("inventory")
end
function Panels.party(_d)
	refreshIf("party")
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
	local b = open("onboarding", "Before you descend")
	UI.label(b, "You are joining the search for a survey team that vanished below the recorded quarries.", 15)
	UI.label(b, "• Light and medical supplies keep you alive. Running low makes things bolder.", 14, C.dim)
	UI.label(b, "• Loot you pick up is EXPEDITION loot until you reach a shelter. Die or log out first and it stays behind in a bag.", 14, C.dim)
	UI.label(b, "• Chalk, signs and rope are PROTECTED: you always keep unused ones.", 14, C.dim)
	UI.label(b, "• Run, hide in niches, or throw a stone to draw attention away. Not everything can be fought.", 14, C.dim)
	UI.label(b, "Choose a starting class. Every class can do everything; each starts with a small edge.", 15)
	for _, name in { "Explorer", "Medic", "Runner", "Technician" } do
		UI.button(b, name .. " — " .. CLASS_TEXT[name], function()
			ctx.send("onboard.choose", { className = name })
		end, { Size = UDim2.new(1, 0, 0, UI.TOUCH) })
	end
end

function Panels.missionList(list)
	local b = open("missions", "Missions")
	UI.label(b, "Estimated lengths and risk are rough. There is no GPS route — follow the clues.", 13, C.dim)
	for _, m in list do
		local row = UI.frame(b, { Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y })
		UI.corner(row)
		UI.pad(row, 6)
		UI.list(row, 4)
		UI.label(row, string.format("%s %s%s", m.id, m.name, if m.estimate then (" · " .. m.estimate .. " · risk " .. tostring(m.risk)) else ""), 15)
		if m.status ~= "SLICE" then
			UI.label(row, "Planned — not built in this milestone.", 13, C.dim)
		elseif m.available then
			UI.button(row, "Accept", function()
				ctx.send("mission.accept", { id = m.id })
				close()
			end, { Size = UDim2.new(0, 120, 0, 36) })
		elseif m.cooldown and m.cooldown > 0 then
			UI.label(row, string.format("Available again in %ds.", m.cooldown), 13, C.dim)
		else
			UI.label(row, "You already have an active mission.", 13, C.dim)
			UI.button(row, "Abandon current", function()
				ctx.send("mission.abandon")
				close()
			end, { Size = UDim2.new(0, 170, 0, 36), BackgroundColor3 = C.dim })
		end
	end
end

function Panels.shelter(d)
	if not d.open then
		if current == "shelter" then
			close()
		end
		return
	end
	local b = open("shelter", d.name)
	local fortText = {
		discovered = "DISCOVERED — entrances are vulnerable. Relatively safe, not completely.",
		patched = "PATCHED — some entrances protected.",
		secured = "SECURED — creatures cannot enter or harm anyone inside.",
	}
	UI.label(b, fortText[d.fortification] or d.fortification, 16, if d.fortification == "secured" then C.teal else C.warn)
	for _, e in d.entrances do
		UI.label(b, string.format("• %s: %s", nice(e.id), if e.protected then "protected" else "VULNERABLE"), 14)
	end
	UI.label(b, string.format("Passive recovery here stops at %d%% health. Medical supplies heal further.", math.floor(d.passiveCap * 100)), 13, C.dim)
	UI.label(b, "Improvements", 17)
	for _, u in d.upgrades do
		local row = UI.frame(b, { Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y })
		UI.corner(row)
		UI.pad(row, 6)
		UI.list(row, 3)
		UI.label(row, string.format("%s (%s) — stage %d/%d", nice(u.id), u.kind, u.stage, u.maxStage), 15)
		if u.cost then
			local parts = {}
			for id, n in u.cost do
				table.insert(parts, n .. "× " .. nice(string.match(id, "%.(.+)$") or id))
			end
			UI.label(row, "Needs: " .. table.concat(parts, ", "), 13, C.dim)
			UI.button(row, if u.affordable then "Build" else "Not enough materials", function()
				if u.affordable then
					ctx.send("shelter.upgrade", { upgradeId = u.id })
				end
			end, { Size = UDim2.new(0, 220, 0, 36), BackgroundColor3 = if u.affordable then C.amber else C.dim })
		else
			UI.label(row, "Complete.", 13, C.teal)
		end
	end
	UI.label(b, "Crafting", 17)
	for _, r in d.recipes do
		local row = UI.frame(b, { Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y })
		UI.pad(row, 6)
		UI.list(row, 3)
		local ins = {}
		for id, n in r.inputs do
			table.insert(ins, n .. "× " .. nice(string.match(id, "%.(.+)$") or id))
		end
		UI.label(row, string.format("%s ×%d ← %s%s", r.output, r.outputCount, table.concat(ins, ", "), if r.requiresWorkbench then " (workbench)" else ""), 14)
		UI.button(row, if r.canCraft then "Craft" else "Missing materials", function()
			if r.canCraft then
				ctx.send("shelter.craft", { recipeId = r.id })
			end
		end, { Size = UDim2.new(0, 200, 0, 34), BackgroundColor3 = if r.canCraft then C.amber else C.dim })
	end
	UI.label(b, "Recovery escrow", 17)
	local esc = {}
	for id, n in d.escrow do
		table.insert(esc, n .. "× " .. nice(string.match(id, "%.(.+)$") or id))
	end
	if #esc == 0 then
		UI.label(b, "Empty. Items a party member recovers from your bags arrive here.", 13, C.dim)
	else
		UI.label(b, table.concat(esc, ", "), 14)
		UI.button(b, "Collect escrow", function()
			ctx.send("shelter.escrow")
		end)
	end
	UI.label(b, string.format("Class: %s (coins %d)", d.class, d.coins), 17)
	UI.label(b, string.format("Classes give small (~5%%) head starts; everyone can do everything. Changing costs %d earned coins.", d.classCost), 13, C.dim)
	for _, cls in d.classes do
		if cls ~= d.class then
			UI.button(b, "Switch to " .. cls, function()
				ctx.send("shelter.class", { className = cls })
			end, { BackgroundColor3 = if d.coins >= d.classCost then C.amber else C.dim })
		end
	end
	UI.button(b, "Missions", function()
		ctx.send("mission.list")
	end, { BackgroundColor3 = C.teal })
	UI.button(b, "Leave shelter", function()
		ctx.send("shelter.exit")
		close()
	end, { BackgroundColor3 = C.dim })
end

function Panels.shop(d)
	local b = open("shop", "Quartermaster (placeholder)")
	UI.label(b, string.format("Coins: %d. Everything here can also be found in the tunnels.", d.coins), 14)
	UI.label(b, "Buy", 17)
	for _, e in d.buy do
		local full = e.have >= e.limit
		UI.button(b, string.format("%s — %d coins (have %d)", e.name, e.price, e.have), function()
			ctx.send("shop.buy", { itemId = e.itemId })
		end, { BackgroundColor3 = if d.coins >= e.price and not full then C.amber else C.dim })
	end
	UI.label(b, "Sell treasures", 17)
	if #d.sell == 0 then
		UI.label(b, "No sellable treasures. Unique story items are never sold here.", 13, C.dim)
	end
	for _, e in d.sell do
		UI.button(b, string.format("Sell %s for %d (have %d)", e.name, e.value, e.have), function()
			ctx.send("shop.sell", { itemId = e.itemId })
		end, { BackgroundColor3 = C.teal })
	end
	UI.label(b, "Store", 17)
	if not d.storeConfigured then
		UI.label(b, "No products are configured in this build. Purchases are never required to explore.", 13, C.dim)
	end
	for _, p in d.products do
		UI.button(b, string.format("%s — %s", p.name, if p.price then (p.price .. " Robux") else "price unavailable"), function()
			ctx.send("shop.product", { productId = p.productId })
		end, { BackgroundColor3 = C.dim })
	end
end

return Panels
