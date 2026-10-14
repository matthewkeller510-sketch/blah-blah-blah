--!strict
-- Act I "The Descent" (section 05). Story progress is derived from profile facts (Logic/Story.luau), pushed to
-- the HUD as the current objective and to the notebook as journal entries with subtitle-ready text.
-- Completed story objectives are permanent (section 06): repeatable missions never reset them.

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Story = require(Shared.Logic.Story)
local Inventory = require(Shared.Logic.Inventory)

local StoryService = {}
local services: any
local lastStep: { [Player]: string } = {}

local ACT1_REWARD_COINS = 60

local function facts(profile: any): Story.Facts
	return {
		discoveries = profile.discoveries,
		claims = profile.claims,
		storyStates = profile.storyStates,
		shelterUpgrades = profile.shelterUpgrades,
	}
end

-- Sends the story state. The poll passes onlyIfChanged so unchanged state is not re-sent every few seconds.
function StoryService.push(player: Player, onlyIfChanged: boolean?)
	local s = services.PlayerService.get(player)
	if not s then
		return
	end
	local f = facts(s.profile)
	local index, step = Story.current(f)
	local id = if step then step.id else "A1.done"
	if onlyIfChanged and lastStep[player] == id then
		return
	end
	services.PlayerService.send(player, "story", {
		act = "Act I — The Descent",
		stepIndex = index,
		steps = #Story.ACT1,
		objective = if step then step.objective else "Act I complete. The network remains open — later acts are not built yet.",
		journal = Story.journal(f),
		complete = step == nil,
	})
	if lastStep[player] and lastStep[player] ~= id then
		services.PlayerService.notify(player, "Journal updated: " .. (if step then step.objective else "Act I complete."), "info")
	end
	lastStep[player] = id
end

-- Returning the tag to Mara Voss's board completes Act I (the tag is a keepsake and is not consumed).
function StoryService.atBoard(player: Player): boolean
	local s = services.PlayerService.get(player)
	if not s then
		return false
	end
	local _, step = Story.current(facts(s.profile))
	if not step or step.id ~= "A1.6" then
		return false
	end
	if Inventory.count(s.profile.inventory, "treasure.old_expedition_tag") < 1 then
		services.PlayerService.notify(player, "Mara Voss: \"You found the tag? Then bring it here — it should be with you.\"", "info")
		return false
	end
	s.profile.storyStates["A1.complete"] = "1"
	s.profile.coins += ACT1_REWARD_COINS
	services.SaveService.markDirty(player)
	task.spawn(services.SaveService.commit, player)
	services.PlayerService.notify(player,
		"Mara Voss: \"Team Seven's number. On a tag older than my grandmother. Whatever they measured down there, it measured them back.\" (+"
			.. ACT1_REWARD_COINS .. " coins)", "info")
	services.PlayerService.pushInventory(player)
	StoryService.push(player)
	return true
end

function StoryService.init(s)
	services = s
	game:GetService("Players").PlayerRemoving:Connect(function(p)
		lastStep[p] = nil
	end)
end

function StoryService.start()
	-- Facts change from many systems (discoveries, rescues, upgrades, claims); a light poll keeps them in sync.
	task.spawn(function()
		while true do
			task.wait(3)
			for p in services.PlayerService.all() do
				StoryService.push(p, true)
			end
		end
	end)
end

return StoryService
