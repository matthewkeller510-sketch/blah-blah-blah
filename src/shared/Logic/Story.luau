--!strict
-- Story acts (section 05, PROPOSED story "The Last Survey"). Pure module: the current step is derived from facts
-- already in the player's profile, so story state can never fall out of sync with what the player actually did.
-- Each step carries a short subtitle-ready instruction and a journal entry (important instructions get both).
-- Act I "The Descent" (Milestone 2) is unchanged. Act II "Contradictory Records" (Milestone 3, docs/MILESTONE-3.md
-- 4.5) starts only after Act I is complete because acts are walked in order.
--
-- Stable step keys: every step id below ("A1.1".."A1.6", "A2.1".."A2.7") is a stable key. Field experience for a
-- story step uses the dedupe key "story:" .. stepId (Story.xpKey), shared with the player package's back-fill.

export type Facts = {
	discoveries: { [string]: boolean },
	claims: { [string]: boolean },
	storyStates: { [string]: string },
	shelterUpgrades: { [string]: { [string]: number } },
	-- Optional so older fixtures (Act I only) stay valid; read nil-safe.
	charactersMet: { [string]: string }?,
}

export type Step = {
	id: string,
	objective: string,
	journal: string,
	done: (Facts) -> boolean,
}

export type Act = { id: string, title: string, steps: { Step }, doneText: string }

export type JournalEntry = { id: string, text: string, done: boolean }

local Story = {}

local function stage(f: Facts, shelterId: string, upgradeId: string): number
	local s = f.shelterUpgrades[shelterId]
	return if s then (s[upgradeId] or 0) else 0
end

local function met(f: Facts, npcId: string): string?
	local m = f.charactersMet
	return if m then m[npcId] else nil
end

Story.ACT1 = {
	{
		id = "A1.1",
		objective = "Descend into the Old Quarry and find the survey board.",
		journal = 'Mara Voss: "A survey team went past the recorded quarries and never signed out. Start where they started — the board at Galerie 14."',
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

-- Act II "Contradictory Records". Every major revelation has a place, an item and a witness or recording.
Story.ACT2 = {
	{
		id = "A2.1",
		objective = "Show the old tag's story to Dr Luc Moreau in the depot courtyard.",
		journal = "Mara wants the tag explained by someone who reads old records for a living: Dr Luc Moreau, the historian.",
		done = function(f)
			return met(f, "N02") ~= nil
		end,
	},
	{
		id = "A2.2",
		objective = "Find Noah Perrin, the courier who saw the survey team, in the Silt Works and bring him to any shelter.",
		journal = "Noah Perrin saw Team Seven near the waterworks and never came back up. Treat him, then escort or carry him to safety.",
		done = function(f)
			return f.storyStates["act2.noah_rescued"] == "1"
		end,
	},
	{
		id = "A2.3",
		objective = "Recover the waterworks log from the drained cistern (route the pumps in the Old Pumps first).",
		journal = "Noah says Team Seven left the waterworks log in the cistern. The water has to be routed away before anyone can reach it.",
		done = function(f)
			return f.claims["R03.unique.waterworks_log"] == true
		end,
	},
	{
		id = "A2.4",
		objective = "Go down past the Sluice Channel to the Abandoned Survey Station and register its Service Office shelter.",
		journal = "The waterworks log ends with a station number. The survey station lies below the Sluice Channel; its service office can be held.",
		done = function(f)
			return f.discoveries["shelter:S04.service_office"] == true
		end,
	},
	{
		id = "A2.5",
		objective = "Restore the station power in the Generator Room, then lock the frequency on the Radio Room set.",
		journal = "The station radio still holds a frequency. It needs the generator running before the set will play anything.",
		done = function(f)
			return f.storyStates["act2.radio_heard"] == "1"
		end,
	},
	{
		id = "A2.6",
		objective = "Carry the waterworks log and the station tape to the Map Room table and compare them.",
		journal = "Elise Renaud's recording says both logs are right. The Map Room table is where the station's surveys were drawn.",
		done = function(f)
			return f.storyStates["act2.logs_compared"] == "1"
		end,
	},
	{
		id = "A2.7",
		objective = "Report what the logs show to Mara Voss at the depot.",
		journal = "Two careful records of the same rooms, decades apart. Mara needs to hear it from you.",
		done = function(f)
			return f.storyStates["act2.complete"] == "1"
		end,
	},
} :: { Step }

Story.ACTS = {
	{
		id = "A1",
		title = "Act I — The Descent",
		steps = Story.ACT1,
		doneText = "Act I complete.",
	},
	{
		id = "A2",
		title = "Act II — Contradictory Records",
		steps = Story.ACT2,
		doneText = "Act II complete. The network remains open — later acts are not built yet.",
	},
} :: { Act }

-- Every step id in story order (stable keys; see the header).
Story.STEP_IDS = {} :: { string }
for _, act in Story.ACTS do
	for _, step in act.steps do
		table.insert(Story.STEP_IDS, step.id)
	end
end

function Story.xpKey(stepId: string): string
	return "story:" .. stepId
end

-- Builds facts from a profile (any profile-shaped table).
function Story.factsOf(profile: any): Facts
	return {
		discoveries = profile.discoveries or {},
		claims = profile.claims or {},
		storyStates = profile.storyStates or {},
		shelterUpgrades = profile.shelterUpgrades or {},
		charactersMet = profile.charactersMet or {},
	}
end

-- Act I only (kept for Milestone 2 callers and tests): (index of the first unfinished step or nil, the step).
function Story.current(f: Facts): (number?, Step?)
	for i, step in Story.ACT1 do
		if not step.done(f) then
			return i, step
		end
	end
	return nil, nil
end

-- Walks the acts in order: returns (act, index, step) of the first unfinished step, or nil when every act is done.
-- A later act can never be current while an earlier act has an unfinished step.
function Story.locate(f: Facts): (Act?, number?, Step?)
	for _, act in Story.ACTS do
		for i, step in act.steps do
			if not step.done(f) then
				return act, i, step
			end
		end
	end
	return nil, nil, nil
end

-- The current step id, or "done" when every built act is complete.
function Story.currentId(f: Facts): string
	local _, _, step = Story.locate(f)
	return if step then step.id else "done"
end

-- True when step `stepId` comes strictly before the current step in story order (or everything is complete).
-- Facts can arrive out of order (shared discoveries, party rescues); this protects narrative order.
function Story.reached(f: Facts, stepId: string): boolean
	local cur = Story.currentId(f)
	if cur == "done" then
		return true
	end
	for _, id in Story.STEP_IDS do
		if id == cur then
			return false
		elseif id == stepId then
			return true
		end
	end
	return false
end

-- Steps completed in story order (everything before the current step). Used for story experience.
function Story.completedStepIds(f: Facts): { string }
	local out = {}
	local cur = Story.currentId(f)
	for _, id in Story.STEP_IDS do
		if id == cur then
			break
		end
		table.insert(out, id)
	end
	return out
end

local function actJournal(f: Facts, act: Act): { JournalEntry }
	local out = {}
	for _, step in act.steps do
		local done = step.done(f)
		table.insert(out, { id = step.id, text = step.journal, done = done })
		if not done then
			break
		end
	end
	return out
end

-- Act I journal (unchanged behaviour): every finished step plus the current one.
function Story.journal(f: Facts): { JournalEntry }
	return actJournal(f, Story.ACTS[1])
end

-- Journal for the whole story so far: earlier acts are summarised in one line each, then the current act's
-- finished steps plus the current one.
function Story.fullJournal(f: Facts): { JournalEntry }
	local out = {}
	local act = Story.locate(f)
	for _, a in Story.ACTS do
		if a == act then
			for _, e in actJournal(f, a) do
				table.insert(out, e)
			end
			break
		end
		table.insert(out, { id = a.id, text = a.title .. ": complete.", done = true })
	end
	return out
end

-- Persistent notes derived from facts (characters met, readables read, recordings heard, revelations).
-- `readables` maps a readable id (also its discovery id) to its journal text; `characterNotes` maps npc ids.
function Story.notes(
	f: Facts,
	readables: { [string]: any }, -- id -> { journal: string, ... } (StoryDefs.Readables)
	characterNotes: { [string]: string },
	recordings: { radio: string?, revelation: string? }
): { { id: string, text: string } }
	local out = {}
	for _, npcId in { "N01", "N02", "N03", "N04", "N05", "N06" } do
		local state = met(f, npcId)
		if state and characterNotes[npcId] then
			table.insert(out, { id = "met:" .. npcId, text = characterNotes[npcId] .. " (" .. state .. ")" })
		end
	end
	local ids = {}
	for id in readables do
		table.insert(ids, id)
	end
	table.sort(ids)
	for _, id in ids do
		if f.discoveries[id] then
			table.insert(out, { id = "read:" .. id, text = readables[id].journal })
		end
	end
	if recordings.radio and f.storyStates["act2.radio_heard"] == "1" then
		table.insert(out, { id = "rec:radio_log", text = recordings.radio })
	end
	if recordings.revelation and f.storyStates["act2.logs_compared"] == "1" then
		table.insert(out, { id = "rec:logs_compared", text = recordings.revelation })
	end
	return out
end

-- charactersMet only ever rises: encountered < rescued < understood (section 05). Returns true if it changed.
local MET_RANK = { encountered = 1, rescued = 2, understood = 3 }
function Story.raiseMet(map: { [string]: string }, npcId: string, state: string): boolean
	local newRank = MET_RANK[state]
	if not newRank then
		return false
	end
	local cur = map[npcId]
	if cur and (MET_RANK[cur] or 0) >= newRank then
		return false
	end
	map[npcId] = state
	return true
end

-- Act II step 6 rule. Returns "ok" (compare now), "done" (already compared: show the revelation again),
-- "too_early" (Act I unfinished), or "missing" with the display names of the missing records.
function Story.compareLogs(f: Facts, hasWaterworksLog: boolean, hasStationTape: boolean): (string, { string })
	if f.storyStates["act2.logs_compared"] == "1" then
		return "done", {}
	end
	local act = Story.locate(f)
	if not act or act.id ~= "A2" then
		return "too_early", {}
	end
	local missing = {}
	if not hasWaterworksLog then
		table.insert(missing, "the waterworks log (from the drained cistern)")
	end
	if not hasStationTape then
		table.insert(missing, "the station tape (from the Radio Room set, with the power on)")
	end
	if #missing > 0 then
		return "missing", missing
	end
	return "ok", {}
end

export type TalkResult = {
	line: string, -- line id in StoryDefs.Lines[npcId]
	met: string?, -- charactersMet state to raise to
	appendObjective: boolean?, -- the speaker restates the current objective
}

-- Chooses what a character says from story facts (PROPOSED dialogue logic). `visits` counts this session's talks
-- with the character so repeated visits can rotate optional hints. Returns nil when the character has nothing to
-- say to this player (e.g. Noah before he is rescued).
function Story.talk(npcId: string, f: Facts, visits: number): TalkResult?
	local cur = Story.currentId(f)
	local act1Done = f.storyStates["A1.complete"] == "1"
	if npcId == "N01" then
		-- Hand-ins (A1.6, A2.7) are handled by StoryService.atBoard before this is asked.
		if f.storyStates["act2.complete"] == "1" then
			return { line = "after_act2", met = "understood" }
		end
		if met(f, "N01") == nil then
			return { line = "greet", met = "encountered" }
		end
		return { line = "objective", appendObjective = true }
	elseif npcId == "N02" then
		if not act1Done then
			-- Moreau only engages once the player brings the Act I story (step A2.1's fact is set by this talk).
			return { line = "before_act2" }
		end
		if f.storyStates["act2.logs_compared"] == "1" then
			return { line = "act2_understood", met = "understood" }
		end
		if met(f, "N02") == nil then
			return { line = "act2_tag", met = "encountered" }
		end
		if cur == "A2.6" then
			return { line = "act2_compare" }
		end
		return { line = "act2_progress", appendObjective = true }
	elseif npcId == "N03" then
		if met(f, "N03") == nil or visits == 0 then
			return { line = "greet", met = "encountered" }
		end
		return { line = "again" }
	elseif npcId == "N04" then
		local understood = Story.reached(f, "A2.5")
		local result: TalkResult
		if cur == "A2.3" then
			result = { line = "pumps" }
		elseif cur == "A2.5" then
			result = { line = "power" }
		elseif
			f.discoveries["shelter:S04.service_office"] == true
			and stage(f, "S04.service_office", "station_power") < 1
		then
			result = { line = "breaker" }
		elseif visits % 2 == 0 then
			result = { line = "barricades" }
		else
			result = { line = "sluice" }
		end
		result.met = if understood then "understood" else "encountered"
		return result
	elseif npcId == "N06" then
		if f.storyStates["act2.noah_rescued"] ~= "1" then
			return nil
		end
		if cur == "A2.3" then
			return { line = "log_hint", met = "rescued" }
		end
		return { line = "after", met = "rescued" }
	end
	return nil
end

return Story
