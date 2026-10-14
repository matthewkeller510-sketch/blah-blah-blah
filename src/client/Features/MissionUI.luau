--!strict
-- Mission-specific screens (section 06, 17). M03 Medical Delivery: an amount chooser listing the medical items the
-- player holds; each button sends `mission.deliver { itemId, count }` and the server validates holdings, range and
-- the mission before removing exactly that many. With nothing to give it explains where supplies have turned up.
-- It never opens a store and never mentions Robux (section 06: never demand a real-money purchase).
-- The chooser is player-initiated and closes itself when the player goes down or a threat cue arrives.
-- It is a standard UI.panel: Close sits in the header, always on screen and Modal (frees the first-person PC
-- cursor), and the options scroll when they do not fit (three item kinds on a phone).

local UI = require(script.Parent.Parent.Controllers.UI)
local UIRules = require(script.Parent.Parent.Controllers.UIRules)

local MissionUI = {}
local ctx: any
local C = UI.Colors
local root: Frame? = nil

local function close()
	if root then
		root:Destroy()
		root = nil
	end
end

local function openChooser(d: any)
	close()
	if type(d) ~= "table" then
		return
	end
	local panel, body = UI.panel(ctx.gui, if type(d.title) == "string" then d.title else "Medical Delivery", close)
	panel.Name = "MissionChooser"
	root = panel
	local options = if type(d.options) == "table" then d.options else {}
	if #options == 0 then
		UI.label(
			body,
			if type(d.nothing) == "string" then d.nothing else "You have nothing the worker can use.",
			15,
			C.dim
		)
	else
		UI.label(
			body,
			string.format(
				"The worker can use dressings, bandages or splints. You choose how many (up to %d): %d coins plus %d per item.",
				tonumber(d.max) or 3,
				tonumber(d.base) or 0,
				tonumber(d.perItem) or 0
			),
			14,
			C.dim
		)
		for _, o in options do
			if type(o) ~= "table" or type(o.itemId) ~= "string" then
				continue
			end
			UI.label(body, string.format("%s — you have %d", tostring(o.name), tonumber(o.have) or 0), 15)
			local row = UI.frame(body, { Size = UDim2.new(1, -8, 0, UI.TOUCH), BackgroundTransparency = 1 })
			UI.list(row, 6, true)
			for n = 1, tonumber(o.max) or 0 do
				local coins = (tonumber(d.base) or 0) + (tonumber(d.perItem) or 0) * n
				-- a third of the row each, wrapped, so "Give 3 (+40)" stays inside the button at large text sizes
				UI.button(row, string.format("Give %d (+%d)", n, coins), function()
					ctx.send("mission.deliver", { itemId = o.itemId, count = n })
					close()
				end, { Size = UDim2.new(1 / 3, -4, 0, UI.TOUCH), TextWrapped = true })
			end
		end
	end
end

function MissionUI.init(c: any)
	ctx = c
	ctx.on("missionDeliver", openChooser)
	ctx.on("cue", function(d: any)
		if type(d) == "table" and UIRules.THREAT_CUES[d.id] then
			close()
		end
	end)
	ctx.on("vitals", function(d: any)
		if type(d) == "table" and d.condition == "downed" then
			close()
		end
	end)
	ctx.on("mission", function(d: any)
		-- the delivery is done or the objective ended: nothing left to choose
		if type(d) == "table" and d.state ~= "deliver" then
			close()
		end
	end)
end

return MissionUI
