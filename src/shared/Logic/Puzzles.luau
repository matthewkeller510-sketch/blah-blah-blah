--!strict
-- Puzzle rules (section 12). Pure module: the server owns authoritative state; clients only see results.
-- P01 inscription alignment: rotate a plaque until its symbol matches the carving (authored targets, rotated per
--      server so the answer is read from the clue, not memorised).
-- P02 pump routing: three valves, one authored open/closed pattern per cycle; feedback is the count of correctly
--      set valves (gauge + sound), reset is immediate.

local Puzzles = {}

-- P01 ---------------------------------------------------------------------------------------------
export type P01State = { orientation: number, target: number, solved: boolean, orientations: number }

function Puzzles.newP01(target: number, orientations: number): P01State
	assert(target >= 0 and target < orientations, "target out of range")
	-- never start already solved
	local start = (target + 2) % orientations
	return { orientation = start, target = target, solved = false, orientations = orientations }
end

-- Rotates one step clockwise. Returns true if this rotation solved it. A solved plaque stays solved.
function Puzzles.rotateP01(s: P01State): boolean
	if s.solved then
		return false
	end
	s.orientation = (s.orientation + 1) % s.orientations
	if s.orientation == s.target then
		s.solved = true
		return true
	end
	return false
end

Puzzles.ARROWS = { "↑", "→", "↓", "←" }

-- P02 ---------------------------------------------------------------------------------------------
export type P02State = { valves: { boolean }, solution: { boolean }, drained: boolean }

-- Authored solutions (never all-closed, which is the reset state, and never all-open).
Puzzles.P02_SOLUTIONS = {
	{ true, false, true },
	{ false, true, true },
	{ true, true, false },
}

function Puzzles.newP02(solutionIndex: number): P02State
	local sol = Puzzles.P02_SOLUTIONS[solutionIndex]
	assert(sol, "unknown P02 solution")
	return { valves = { false, false, false }, solution = table.clone(sol), drained = false }
end

function Puzzles.correctCount(s: P02State): number
	local n = 0
	for i, v in s.valves do
		if v == s.solution[i] then
			n += 1
		end
	end
	return n
end

-- Toggles valve i. Returns (correctCount, justDrained).
function Puzzles.toggleValve(s: P02State, i: number): (number, boolean)
	assert(i >= 1 and i <= #s.valves, "bad valve")
	if s.drained then
		return #s.valves, false -- valves are locked open/closed while drained; reset or reflood first
	end
	s.valves[i] = not s.valves[i]
	local n = Puzzles.correctCount(s)
	if n == #s.valves then
		s.drained = true
		return n, true
	end
	return n, false
end

function Puzzles.resetP02(s: P02State)
	s.valves = { false, false, false }
	s.drained = false
end

-- Clue text for a solution: which pipes must carry water away (open) and which must stay shut.
function Puzzles.p02Clue(solution: { boolean }): string
	local parts = {}
	local numerals = { "I", "II", "III" }
	for i, open in solution do
		table.insert(parts, numerals[i] .. (if open then " OUVERT" else " FERMÉ"))
	end
	return "VIDANGE DE LA CITERNE: " .. table.concat(parts, " · ")
end

return Puzzles
