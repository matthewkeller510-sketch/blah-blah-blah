--!strict
-- Act I "The Descent" (section 05, PROPOSED story). Pure module: the current step is derived from facts already
-- in the player's profile, so story state can never fall out of sync with what the player actually did.
-- Each step carries a short subtitle-ready instruction and a journal entry (important instructions get both).

export type Facts = {
	discoveries: { [string]: boolean },
	claims: { [string]: boolean },
	storyStates: { [string]: string },
	shelterUpgrades: { [string]: { [string]: number } },
}

export type Step = {
	id: string,
	objective: string,
	journal: string,
	done: (Facts) -> boolean,
}

local Story = {}

local function stage(f: Facts, shelterId: string, upgradeId: string): number
	local s = f.shelterUpgrades[shelterId]
	return if s then (s[upgradeId] or 0) else 0
end

Story.ACT1 = {
	{
		id = "A1.1",
		objective = "Descend into the Old Quarry and find the survey board.",
		journal = "Mara Voss: \"A survey team went past the recorded quarries and never signed out. Start where they started — the board at Galerie 14.\"",
		done = function(f)
			return f.discoveries["R01.survey_board"] == true
		end,
	},
	{
		id = "A1.2",
		objective = "Bring a lost worker back to a shelter (Nearby Rescue).",
		journal = "Workers keep wandering off the marked routes since the team vanished. Every one brought back is a witness.",
		done = function(f)
			return (tonumber(f.storyStates["M01.completions"]) or 0) >= 1
		end,
	},
	{
		id = "A1.3",
		objective = "Restore the Worker's Alcove: repair its gate at least once.",
		journal = "A shelter you can trust is the difference between pressing on and turning back.",
		done = function(f)
			return stage(f, "S01.worker_alcove", "gate_repair") >= 1
		end,
	},
	{
		id = "A1.4",
		objective = "Follow the old survey marks down into the Ossuary Galleries.",
		journal = "The survey numbers continue past the rubble, down toward the bone walls. Nobody has recorded that route.",
		done = function(f)
			return f.discoveries["R02.bone_gate"] == true
		end,
	},
	{
		id = "A1.5",
		objective = "Open the sealed chapel in the Hall of Plaques and recover the expedition tag.",
		journal = "One plaque in the hall has been turned. The carving beside the door shows how it should sit.",
		done = function(f)
			return f.claims["R02.unique.old_tag"] == true
		end,
	},
	{
		id = "A1.6",
		objective = "Return the old expedition tag to Mara Voss's board at the depot.",
		journal = "The tag is stamped with the missing team's number — but the metal is decades old. It cannot be theirs. It is.",
		done = function(f)
			return f.storyStates["A1.complete"] == "1"
		end,
	},
} :: { Step }

-- Returns (index of the first unfinished step or nil when the act is complete, the step).
function Story.current(f: Facts): (number?, Step?)
	for i, step in Story.ACT1 do
		if not step.done(f) then
			return i, step
		end
	end
	return nil, nil
end

-- Journal entries the player has unlocked: every finished step plus the current one.
function Story.journal(f: Facts): { { id: string, text: string, done: boolean } }
	local out = {}
	for _, step in Story.ACT1 do
		local done = step.done(f)
		table.insert(out, { id = step.id, text = step.journal, done = done })
		if not done then
			break
		end
	end
	return out
end

return Story
