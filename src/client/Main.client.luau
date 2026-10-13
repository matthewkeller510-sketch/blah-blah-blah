--!strict
-- Client entry. The client renders and requests; it never decides pickups, damage, rescues, crafts or purchases.

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Net = require(Shared.Net)

local Controllers = script.Parent:WaitForChild("Controllers")
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
gui.Parent = player:WaitForChild("PlayerGui")

local ctx = {
	send = send,
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
		Hud.notice(string.format("Journal: %s — %s (%d/%d)", data.name, string.gsub(data.stageName, "_", " "), data.stage, data.stages), "info")
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
	elseif channel == "debugPressure" then
		Hud.debugPressure(data)
	end
end)
