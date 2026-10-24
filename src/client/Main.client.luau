--!strict
-- Client entry. The client renders and requests; it never decides pickups, damage, rescues, crafts or purchases.

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Net = require(Shared.Net)

local Controllers = script.Parent:WaitForChild("Controllers")
local UI = require(Controllers.UI)
local Settings = require(Controllers.Settings)
local Hud = require(Controllers.Hud)
local Input = require(Controllers.Input)
local Panels = require(Controllers.Panels)
local WorldRenderer = require(Controllers.WorldRenderer)
local Cues = require(Controllers.Cues)

local player = Players.LocalPlayer
local request = Net.event(Net.Names.Request)
local stateEvent = Net.event(Net.Names.State)

local function send(action: string, payload: any?)
	request:FireServer(action, payload or {})
end

local gui = Instance.new("ScreenGui")
gui.Name = "ExpeditionUI"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = false
gui.ScreenInsets = Enum.ScreenInsets.CoreUISafeInsets -- respect safe areas and system UI
-- ZIndex orders siblings only: an icon's shapes (Controllers/Icons) layer inside their button and never above a
-- screen, and a screen draws over the HUD (UI.panel).
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.Parent = player:WaitForChild("PlayerGui")
UI.attach(gui) -- the HUD layout (UIRules.hudLayout) every controller places its elements from

-- Feature modules (src/client/Features/*.luau) subscribe to State channels with ctx.on(channel, fn).
local listeners: { [string]: { (any) -> () } } = {}
local function on(channel: string, fn: (any) -> ())
	local list = listeners[channel]
	if not list then
		list = {}
		listeners[channel] = list
	end
	table.insert(list, fn)
end

local ctx = {
	send = send,
	on = on,
	gui = gui,
	settings = Settings,
	state = {} :: { [string]: any },
	hud = Hud,
	panels = Panels,
	world = WorldRenderer,
	cues = Cues,
}

Settings.init(ctx)
Hud.init(ctx)
Panels.init(ctx)
WorldRenderer.init(ctx)
Cues.init(ctx)
Input.init(ctx)

stateEvent.OnClientEvent:Connect(function(channel: string, data: any)
	ctx.state[channel] = data
	if channel == "vitals" then
		Hud.vitals(data)
		Cues.vitals(data)
	elseif channel == "inventory" then
		Hud.inventory(data)
		Panels.inventory(data)
	elseif channel == "notice" then
		Hud.notice(data.text, data.kind)
	elseif channel == "save" then
		Hud.save(data)
	elseif channel == "hold" then
		Hud.hold(data)
	elseif channel == "party" then
		Hud.party(data)
		Panels.party(data)
	elseif channel == "partyInvite" then
		Hud.invite(data)
	elseif channel == "roster" then
		Panels.roster(data)
	elseif channel == "ping" then
		WorldRenderer.ping(data)
	elseif channel == "nav" then
		WorldRenderer.nav(data)
		Panels.nav(data)
	elseif channel == "bags" then
		WorldRenderer.bags(data)
	elseif channel == "discovery" then
		Hud.discovery(data)
		Panels.discovery(data)
	elseif channel == "research" then
		Hud.notice(
			string.format(
				"Journal: %s — %s (%d/%d)%s",
				data.name,
				(string.gsub(data.stageName, "_", " ")),
				data.stage,
				data.stages,
				if data.nextHint then (". Next: " .. data.nextHint) else ""
			),
			"info"
		)
		Panels.research(data)
	elseif channel == "cue" then
		Cues.cue(data)
	elseif channel == "mission" then
		Hud.mission(data)
	elseif channel == "missionList" then
		Panels.missionList(data)
	elseif channel == "shelterPanel" then
		Panels.shelter(data)
	elseif channel == "shop" then
		Panels.shop(data)
	elseif channel == "onboarding" then
		Panels.onboarding(data)
	elseif channel == "story" then
		Hud.story(data)
		Panels.story(data)
	elseif channel == "debugPressure" then
		Hud.debugPressure(data)
	end
	local list = listeners[channel]
	if list then
		for _, fn in list do
			task.spawn(fn, data)
		end
	end
end)

-- Every ModuleScript in Features is required after the core controllers, in name order, and given ctx. This runs
-- after the State dispatcher is connected so a slow feature cannot delay join-time pushes; a feature that needs
-- data pushed before it started reads ctx.state[channel].
local Features = script.Parent:FindFirstChild("Features")
if Features then
	local mods = Features:GetChildren()
	table.sort(mods, function(a, b)
		return a.Name < b.Name
	end)
	for _, m in mods do
		if m:IsA("ModuleScript") then
			local ok, err = pcall(function()
				(require(m) :: any).init(ctx)
			end)
			if not ok then
				warn("[Features] " .. m.Name .. " failed to start: " .. tostring(err))
			end
		end
	end
end
