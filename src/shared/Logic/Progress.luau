--!strict
-- Discovery, unique claims and creature research (sections 10, 14; owner rules F12, F14).
-- Group discoveries are committed to each eligible online member's personal record. Item pickups are never
-- shared: each participant physically claims their own copy, and one player's claim does not consume another's.
-- Pure module.

export type Discoveries = { [string]: boolean } -- discoveryId -> true
export type Claims = { [string]: boolean } -- pickupId -> true (unique/once-per-player pickups)

local Progress = {}

-- Commits a discovery to every listed member. Returns the IDs (as strings) that newly gained it.
-- No proximity requirement: that would be a new design proposal (section 14).
function Progress.commitDiscovery(memberRecords: { [number]: Discoveries }, discoveryId: string): { number }
	local newly = {}
	for uid, rec in memberRecords do
		if not rec[discoveryId] then
			rec[discoveryId] = true
			table.insert(newly, uid)
		end
	end
	table.sort(newly)
	return newly
end

-- Per-player pickup claim. Returns true exactly once per player per pickup.
function Progress.claim(claims: Claims, pickupId: string): boolean
	if claims[pickupId] then
		return false
	end
	claims[pickupId] = true
	return true
end

-- Research stages (section 10): sighted -> cue identified -> behavior tested -> counter confirmed -> fully documented.
Progress.RESEARCH_STAGES = { "sighted", "cue_identified", "behavior_tested", "counter_confirmed", "documented" }

export type ResearchEntry = { stage: number, evidence: { [string]: boolean } }
export type Research = { [string]: ResearchEntry } -- creatureId -> entry

-- Each stage requires a specific piece of evidence; evidence can only advance one stage at a time so the
-- journal never becomes a free instant omniscient description.
function Progress.addEvidence(research: Research, creatureId: string, evidenceId: string, stageRequirements: { string }): number
	local e = research[creatureId]
	if not e then
		e = { stage = 0, evidence = {} }
		research[creatureId] = e
	end
	e.evidence[evidenceId] = true
	while e.stage < #stageRequirements and e.evidence[stageRequirements[e.stage + 1]] do
		e.stage += 1
	end
	return e.stage
end

function Progress.stageName(stage: number): string
	return if stage == 0 then "unknown" else Progress.RESEARCH_STAGES[stage]
end

return Progress
