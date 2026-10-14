--!strict
-- Puzzle rules (section 12). Pure module: the server owns authoritative state; clients only see results.
-- P01 inscription alignment: rotate a plaque until its symbol matches the carving (authored targets, rotated per
--      server so the answer is read from the clue, not memorised).
-- P02 pump routing: valves set to one authored open/closed pattern per cycle; feedback is the count of correctly
--      set valves (gauge + sound), reset is immediate.
-- P03 fuse bridge (and the M04 private breaker, which reuses the same layouts): three labelled boxes, a plate that
--      names the dead line and labelled conduits to trace. Needs a repair tool roll (kept) and consumes one fuse kit
--      on the right box only; a wrong box costs time and returns the fuse, never health.
-- P04 weight and pulley: stones in the counterweight basket raise a grate; a latch or a held lever keeps it up; it
--      only ever drops when nobody is under it or behind it, and the inner lever always raises it.
-- P05 echo sequence: repeat an authored short/long pattern; the pattern is always shown as text and as a visual
--      rhythm (never audio-only).
-- W05 sluice gates: turn three wheels in an authored order supported by two clue plates; a wrong turn resets.
-- Occupancy boxes: every "never change state under a player" rule tests positions against these boxes.

local Puzzles = {}

export type V3 = { x: number, y: number, z: number }

local ROMAN = { "I", "II", "III", "IV", "V", "VI", "VII", "VIII", "IX", "X", "XI", "XII" }

-- Roman numeral for valve, wheel and line labels (falls back to digits beyond the table).
function Puzzles.roman(i: number): string
	return ROMAN[i] or tostring(i)
end

-- Gates -------------------------------------------------------------------------------------------
-- Every corridor gate id in WorldDefs.Corridors must be reported by PuzzleService.openGates (tested): an unknown gate
-- key fails closed in WorldDefs.hops, which would silently make a room unreachable for missions.
Puzzles.GATE_IDS = { "P01", "P02", "P04", "W05" }

-- Occupancy boxes -----------------------------------------------------------------------------------
export type Box = { min: V3, max: V3 }

-- Interior of a chamber (floor to ceiling) widened by margin on every horizontal side.
function Puzzles.chamberBox(c: { pos: V3, size: V3 }, margin: number): Box
	return {
		min = { x = c.pos.x - c.size.x / 2 - margin, y = c.pos.y - 3, z = c.pos.z - c.size.z / 2 - margin },
		max = { x = c.pos.x + c.size.x / 2 + margin, y = c.pos.y + c.size.y + 2, z = c.pos.z + c.size.z / 2 + margin },
	}
end

-- A straight same-height corridor between two axis-aligned chambers: the span between their interiors (so the wall
-- openings at both mouths are included), extended by `reach` into both chambers and widened by `margin`.
function Puzzles.corridorBox(
	a: { pos: V3, size: V3 },
	b: { pos: V3, size: V3 },
	width: number,
	height: number,
	margin: number,
	reach: number
): Box
	local y0 = math.min(a.pos.y, b.pos.y) - 3
	local y1 = math.max(a.pos.y, b.pos.y) + height + 2
	if a.pos.x == b.pos.x then
		local lo, hi = a, b
		if a.pos.z > b.pos.z then
			lo, hi = b, a
		end
		return {
			min = { x = a.pos.x - width / 2 - margin, y = y0, z = lo.pos.z + lo.size.z / 2 - reach },
			max = { x = a.pos.x + width / 2 + margin, y = y1, z = hi.pos.z - hi.size.z / 2 + reach },
		}
	end
	local lo, hi = a, b
	if a.pos.x > b.pos.x then
		lo, hi = b, a
	end
	return {
		min = { x = lo.pos.x + lo.size.x / 2 - reach, y = y0, z = a.pos.z - width / 2 - margin },
		max = { x = hi.pos.x - hi.size.x / 2 + reach, y = y1, z = a.pos.z + width / 2 + margin },
	}
end

function Puzzles.inBox(b: Box, x: number, y: number, z: number): boolean
	return x >= b.min.x and x <= b.max.x and y >= b.min.y and y <= b.max.y and z >= b.min.z and z <= b.max.z
end

function Puzzles.inAnyBox(boxes: { Box }, x: number, y: number, z: number): boolean
	for _, b in boxes do
		if Puzzles.inBox(b, x, y, z) then
			return true
		end
	end
	return false
end

-- P01 ---------------------------------------------------------------------------------------------
export type P01State = { orientation: number, target: number, solved: boolean, orientations: number }

function Puzzles.newP01(target: number, orientations: number): P01State
	assert(orientations >= 2, "P01 needs at least two orientations")
	assert(target >= 0 and target < orientations, "target out of range")
	-- never start already solved: half a turn away (two quarter turns with four orientations)
	local start = (target + math.max(1, orientations // 2)) % orientations
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

-- Symbol for an orientation: arrows for the authored four-way plaque, degrees for any other count.
function Puzzles.p01Label(orientation: number, orientations: number): string
	if orientations == #Puzzles.ARROWS then
		return Puzzles.ARROWS[orientation + 1]
	end
	return string.format("%d°", math.floor(orientation * 360 / orientations + 0.5))
end

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
	return { valves = table.create(#sol, false), solution = table.clone(sol), drained = false }
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
	s.valves = table.create(#s.solution, false)
	s.drained = false
end

-- Clue text for a solution: which pipes must carry water away (open) and which must stay shut.
function Puzzles.p02Clue(solution: { boolean }): string
	local parts = {}
	for i, open in solution do
		table.insert(parts, Puzzles.roman(i) .. (if open then " OUVERT" else " FERMÉ"))
	end
	return "VIDANGE DE LA CITERNE: " .. table.concat(parts, " · ")
end

-- P03 fuse bridge / M04 private breaker ----------------------------------------------------------------
-- A layout wires each labelled box to one numbered line. The plate names the dead line; the box feeding it is the
-- burnt one. Each box's conduit carries a stencilled tag at both ends (on the box and on the line terminal), so the
-- answer is traced from labels alone: plate -> dead line -> terminal tag -> box with that tag.
-- PROPOSED: lines are numbered (LINE 1-3) so they never read as box letters; four authored layouts, and in every one
-- the burnt box is not the "natural" guess (box A for line 1, B for 2, C for 3).
export type FuseLayout = {
	wiring: { [string]: number }, -- box label -> line number it feeds
	dead: number, -- the line the plate names as dead
	tags: { [string]: string }, -- box label -> conduit tag
}

Puzzles.FUSE_BOXES = { "A", "B", "C" }

Puzzles.P03_LAYOUTS = {
	{ wiring = { A = 2, B = 3, C = 1 }, dead = 2, tags = { A = "K7", B = "M2", C = "T4" } }, -- burnt A
	{ wiring = { A = 3, B = 1, C = 2 }, dead = 1, tags = { A = "R5", B = "D8", C = "V3" } }, -- burnt B
	{ wiring = { A = 1, B = 3, C = 2 }, dead = 3, tags = { A = "H6", B = "N1", C = "S9" } }, -- burnt B
	{ wiring = { A = 3, B = 2, C = 1 }, dead = 1, tags = { A = "P4", B = "L2", C = "G8" } }, -- burnt C
} :: { FuseLayout }

Puzzles.REPAIR_ROLL = "tool.repair_roll"
Puzzles.FUSE_KIT = "tool.fuse_kit"

-- The box whose line is the dead one.
function Puzzles.burntBox(layout: FuseLayout): string
	for _, b in Puzzles.FUSE_BOXES do
		if layout.wiring[b] == layout.dead then
			return b
		end
	end
	error("fuse layout has no box on the dead line")
end

-- The box that feeds a line, or nil.
function Puzzles.boxForLine(layout: FuseLayout, line: number): string?
	for _, b in Puzzles.FUSE_BOXES do
		if layout.wiring[b] == line then
			return b
		end
	end
	return nil
end

-- Structural check used by the tests and at server start: wiring is a one-to-one map of boxes to lines, the dead line
-- exists, tags are present and distinct.
function Puzzles.validLayout(layout: FuseLayout): (boolean, string?)
	local n = #Puzzles.FUSE_BOXES
	local seenLine: { [number]: boolean } = {}
	local seenTag: { [string]: boolean } = {}
	for _, b in Puzzles.FUSE_BOXES do
		local line = layout.wiring[b]
		if type(line) ~= "number" or line < 1 or line > n or line ~= math.floor(line) or seenLine[line] then
			return false, "box " .. b .. " has no unique line"
		end
		seenLine[line] = true
		local tag = layout.tags[b]
		if type(tag) ~= "string" or tag == "" or seenTag[tag] then
			return false, "box " .. b .. " has no unique conduit tag"
		end
		seenTag[tag] = true
	end
	if type(layout.dead) ~= "number" or not seenLine[layout.dead] then
		return false, "dead line is not wired"
	end
	return true, nil
end

export type P03State = { layout: number, powered: boolean, poweredAt: number }

function Puzzles.newP03(layoutIndex: number): P03State
	assert(Puzzles.P03_LAYOUTS[layoutIndex], "unknown P03 layout")
	return { layout = layoutIndex, powered = false, poweredAt = 0 }
end

-- Item ids still needed to work on a box: the repair roll (reusable, never consumed) and one fuse kit.
function Puzzles.fuseMissing(rolls: number, fuses: number): { string }
	local out = {}
	if rolls < 1 then
		table.insert(out, Puzzles.REPAIR_ROLL)
	end
	if fuses < 1 then
		table.insert(out, Puzzles.FUSE_KIT)
	end
	return out
end

-- A clear notice naming where the missing things are found organically (F19/F20): never a store prompt.
function Puzzles.fuseMissingText(missing: { string }): string
	local roll, fuse = false, false
	for _, id in missing do
		roll = roll or id == Puzzles.REPAIR_ROLL
		fuse = fuse or id == Puzzles.FUSE_KIT
	end
	local craft = " A shelter workbench can also make a fuse kit from fuse components."
	if roll and fuse then
		return "A repair tool roll and a fuse kit are needed. The Battery Store and the generator locker have held them."
			.. craft
	elseif roll then
		return "A repair tool roll is needed (it is not used up). The Battery Store and the generator locker have held them."
	elseif fuse then
		return "A fuse kit is needed. The generator locker has held them." .. craft
	end
	return ""
end

export type FuseOutcome = "powered" | "wrong" | "already" | "missing"
export type FuseResult = {
	outcome: FuseOutcome,
	missing: { string },
	fusesConsumed: number,
	rollsConsumed: number, -- always 0: the repair tool roll is a reusable tool
	delaySeconds: number, -- extra time a wrong box costs (the fuse is pulled back out and returned)
}

-- One fuse insertion at `box`, after the insert hold has completed.
function Puzzles.insertFuse(
	s: P03State,
	box: string,
	rolls: number,
	fuses: number,
	wrongSeconds: number,
	now: number
): FuseResult
	if s.powered then
		return { outcome = "already", missing = {}, fusesConsumed = 0, rollsConsumed = 0, delaySeconds = 0 }
	end
	local missing = Puzzles.fuseMissing(rolls, fuses)
	if #missing > 0 then
		return { outcome = "missing", missing = missing, fusesConsumed = 0, rollsConsumed = 0, delaySeconds = 0 }
	end
	if box ~= Puzzles.burntBox(Puzzles.P03_LAYOUTS[s.layout]) then
		return { outcome = "wrong", missing = {}, fusesConsumed = 0, rollsConsumed = 0, delaySeconds = wrongSeconds }
	end
	s.powered = true
	s.poweredAt = now
	return { outcome = "powered", missing = {}, fusesConsumed = 1, rollsConsumed = 0, delaySeconds = 0 }
end

-- Power trips only after its time is up and only when the generator room is empty.
function Puzzles.p03ShouldTrip(s: P03State, now: number, powerSeconds: number, occupied: boolean): boolean
	return s.powered and now - s.poweredAt >= powerSeconds and not occupied
end

function Puzzles.tripP03(s: P03State, nextLayout: number)
	assert(Puzzles.P03_LAYOUTS[nextLayout], "unknown P03 layout")
	s.powered = false
	s.poweredAt = 0
	s.layout = nextLayout
end

-- Picks a layout different from `current` (roll in 1..count-1), so every trip changes the answer.
function Puzzles.nextLayout(current: number, count: number, roll: number): number
	if count <= 1 then
		return current
	end
	local r = ((roll - 1) % (count - 1)) + 1
	return if r >= current then r + 1 else r
end

-- Plate / terminal / box texts. `lineWord` is "LINE" at the station and "CIRCUIT" on the private wiring card.
function Puzzles.fuseDeadText(layout: FuseLayout, lineWord: string): string
	return string.format("%s %d — NO CURRENT", lineWord, layout.dead)
end

function Puzzles.fuseTerminalText(layout: FuseLayout, line: number, lineWord: string): string
	local b = Puzzles.boxForLine(layout, line)
	return string.format("%s %d ◄ conduit %s", lineWord, line, if b then layout.tags[b] else "?")
end

function Puzzles.fuseBoxText(layout: FuseLayout, box: string, boxWord: string): string
	return string.format("%s %s\nconduit %s", boxWord, box, layout.tags[box] or "?")
end

-- The whole private wiring card (M04): dead circuit plus every terminal.
function Puzzles.fuseCardText(layout: FuseLayout, lineWord: string): string
	local lines = { "WIRING CARD", Puzzles.fuseDeadText(layout, lineWord) }
	for line = 1, #Puzzles.FUSE_BOXES do
		table.insert(lines, Puzzles.fuseTerminalText(layout, line, lineWord))
	end
	return table.concat(lines, "\n")
end

-- P04 weight and pulley ------------------------------------------------------------------------------------
-- PROPOSED: a full basket raises the grate, but the worn brake only holds it for `slipSeconds` on its own. Pulling the
-- latch holds it until someone releases the latch; releasing starts the drop timer (Config.Puzzles.pulleyDropSeconds).
-- A party can skip the stones: one member holds the lever while the others cross. Whatever the timers say, the grate
-- only drops when the occupancy check is clear, and a drop tips the stones back out of the basket.
export type P04State = {
	stones: number,
	required: number,
	raised: boolean,
	latched: boolean,
	holders: number, -- players currently holding the lever
	holdUntil: number, -- held up (without latch or lever) until this time
}

function Puzzles.newP04(required: number): P04State
	assert(required >= 1, "P04 needs at least one stone")
	return { stones = 0, required = required, raised = false, latched = false, holders = 0, holdUntil = 0 }
end

-- Loads one stone. Returns (stones, justRaised).
function Puzzles.loadStone(s: P04State, now: number, slipSeconds: number): (number, boolean)
	if s.stones >= s.required then
		return s.stones, false
	end
	s.stones += 1
	if s.stones >= s.required then
		s.holdUntil = math.max(s.holdUntil, now + slipSeconds)
		if not s.raised then
			s.raised = true
			return s.stones, true
		end
	end
	return s.stones, false
end

export type LatchResult = "latched" | "unlatched" | "not_raised"

function Puzzles.toggleLatch(s: P04State, now: number, dropSeconds: number): LatchResult
	if s.latched then
		s.latched = false
		s.holdUntil = math.max(s.holdUntil, now + dropSeconds) -- unlatching starts the drop timer
		return "unlatched"
	end
	if not s.raised then
		return "not_raised"
	end
	s.latched = true
	return "latched"
end

-- A player starts holding the lever. Returns true if this raised the grate.
function Puzzles.leverHold(s: P04State): boolean
	s.holders += 1
	if not s.raised then
		s.raised = true
		return true
	end
	return false
end

function Puzzles.leverRelease(s: P04State, now: number, slipSeconds: number)
	s.holders = math.max(0, s.holders - 1)
	if s.holders == 0 then
		s.holdUntil = math.max(s.holdUntil, now + slipSeconds)
	end
end

-- The lever inside the store always raises the grate (nobody can be shut in). Returns true if this raised it.
function Puzzles.innerLever(s: P04State, now: number, dropSeconds: number): boolean
	s.holdUntil = math.max(s.holdUntil, now + dropSeconds)
	if not s.raised then
		s.raised = true
		return true
	end
	return false
end

function Puzzles.p04ShouldDrop(s: P04State, now: number, occupied: boolean): boolean
	return s.raised and not s.latched and s.holders == 0 and now >= s.holdUntil and not occupied
end

function Puzzles.dropP04(s: P04State)
	s.raised = false
	s.latched = false
	s.stones = 0
	s.holdUntil = 0
end

-- P05 echo sequence ------------------------------------------------------------------------------------
Puzzles.ECHO_MAX = 8

-- A valid attempt is 1-8 symbols of S (short) and L (long), case-insensitive. Returns the upper-case form or nil.
function Puzzles.normalizeEcho(input: any): string?
	if type(input) ~= "string" or #input < 1 or #input > Puzzles.ECHO_MAX then
		return nil
	end
	local up = string.upper(input)
	if not string.match(up, "^[SL]+$") then
		return nil
	end
	return up
end

function Puzzles.echoMatches(pattern: string, input: any): boolean
	local n = Puzzles.normalizeEcho(input)
	return n ~= nil and n == pattern
end

-- Readable form of a pattern: S -> "•", L -> "—", separated by spaces ("SLSS" -> "• — • •").
function Puzzles.echoSymbols(pattern: string): string
	local out = {}
	for i = 1, #pattern do
		table.insert(out, if string.sub(pattern, i, i) == "L" then "—" else "•")
	end
	return table.concat(out, " ")
end

-- Rhythm timing shared by the radio lamp (server) and the PuzzleUI pulse (client). TUNE.
Puzzles.ECHO_SHORT_SECONDS = 0.25
Puzzles.ECHO_LONG_SECONDS = 0.75
Puzzles.ECHO_GAP_SECONDS = 0.35

function Puzzles.echoTimeline(pattern: string): { { on: number, off: number } }
	local out = {}
	for i = 1, #pattern do
		local long = string.sub(pattern, i, i) == "L"
		table.insert(out, {
			on = if long then Puzzles.ECHO_LONG_SECONDS else Puzzles.ECHO_SHORT_SECONDS,
			off = Puzzles.ECHO_GAP_SECONDS,
		})
	end
	return out
end

-- W05 sluice gates -----------------------------------------------------------------------------------
export type W05State = { order: { number }, progress: number, open: boolean, openedAt: number }

-- "231" -> { 2, 3, 1 } when it is a permutation of 1..n, else nil.
function Puzzles.parseOrder(text: string, n: number): { number }?
	if #text ~= n then
		return nil
	end
	local seen: { [number]: boolean } = {}
	local out = {}
	for i = 1, n do
		local d = tonumber(string.sub(text, i, i))
		if not d or d < 1 or d > n or seen[d] then
			return nil
		end
		seen[d] = true
		out[i] = d
	end
	return out
end

function Puzzles.newW05(orderText: string, wheels: number): W05State
	local order = Puzzles.parseOrder(orderText, wheels)
	assert(order, "bad W05 order " .. orderText)
	return { order = order, progress = 0, open = false, openedAt = 0 }
end

export type SluiceResult = "progress" | "open" | "reset" | "locked"

-- Turns wheel i. Returns (result, n) where n is how many wheels are set in order after this turn ("n of 3").
-- A wrong wheel resets the sequence to 0; it does not count as the first turn of a new attempt.
function Puzzles.turnWheel(s: W05State, wheel: number, now: number): (SluiceResult, number)
	if s.open then
		return "locked", #s.order
	end
	if s.order[s.progress + 1] == wheel then
		s.progress += 1
		if s.progress == #s.order then
			s.open = true
			s.openedAt = now
			return "open", s.progress
		end
		return "progress", s.progress
	end
	s.progress = 0
	return "reset", 0
end

function Puzzles.w05ShouldReflood(s: W05State, now: number, refloodSeconds: number, occupied: boolean): boolean
	return s.open and now - s.openedAt >= refloodSeconds and not occupied
end

function Puzzles.refloodW05(s: W05State)
	s.open = false
	s.progress = 0
	s.openedAt = 0
end

-- Clues: plate 1 says which of two wheels closes first ("before"); plate 2 fixes the third wheel's position
-- ("position"). Each alone leaves several orders open; together exactly one (tested for every authored order).
export type SluiceClue = { kind: string, a: number, b: number } -- before: a before b; position: wheel a at slot b

Puzzles.SLUICE_NAMES = { "upper", "middle", "lower" }

-- Which slot the position clue names, per authored order (PROPOSED; varied so plate 2 is not always "last").
Puzzles.W05_POSITION_SLOT = { ["123"] = 3, ["132"] = 1, ["213"] = 2, ["231"] = 3, ["312"] = 1, ["321"] = 2 }

function Puzzles.w05Clues(order: { number }, slot: number?): (SluiceClue, SluiceClue)
	assert(#order == 3, "sluice clues are authored for three wheels")
	local p = slot or #order
	local rest = {}
	for i, w in order do
		if i ~= p then
			table.insert(rest, w)
		end
	end
	return { kind = "before", a = rest[1], b = rest[2] }, { kind = "position", a = order[p], b = p }
end

-- Clues for an authored order string ("231").
function Puzzles.w05CluesFor(orderText: string): (SluiceClue, SluiceClue)
	local order = Puzzles.parseOrder(orderText, 3)
	assert(order, "bad W05 order " .. orderText)
	return Puzzles.w05Clues(order, Puzzles.W05_POSITION_SLOT[orderText])
end

function Puzzles.clueHolds(clue: SluiceClue, order: { number }): boolean
	if clue.kind == "position" then
		return order[clue.b] == clue.a
	end
	local ia, ib
	for i, w in order do
		if w == clue.a then
			ia = i
		elseif w == clue.b then
			ib = i
		end
	end
	return ia ~= nil and ib ~= nil and ia < ib
end

-- Every ordering of 1..n (n is small).
function Puzzles.permutations(n: number): { { number } }
	local out: { { number } } = {}
	local cur: { number } = {}
	local used: { [number]: boolean } = {}
	local function walk()
		if #cur == n then
			table.insert(out, table.clone(cur))
			return
		end
		for i = 1, n do
			if not used[i] then
				used[i] = true
				table.insert(cur, i)
				walk()
				table.remove(cur)
				used[i] = false
			end
		end
	end
	walk()
	return out
end

-- Orders of 1..n consistent with every clue.
function Puzzles.ordersMatching(clues: { SluiceClue }, n: number): { { number } }
	local out = {}
	for _, o in Puzzles.permutations(n) do
		local ok = true
		for _, c in clues do
			if not Puzzles.clueHolds(c, o) then
				ok = false
				break
			end
		end
		if ok then
			table.insert(out, o)
		end
	end
	return out
end

local SLOT_WORDS = { "first", "second", "last" }

function Puzzles.wheelName(i: number): string
	return Puzzles.SLUICE_NAMES[i] or ("wheel " .. tostring(i))
end

function Puzzles.clueText(clue: SluiceClue): string
	if clue.kind == "before" then
		return string.format(
			"The %s race (%s) closes before the %s race (%s).",
			Puzzles.wheelName(clue.a),
			Puzzles.roman(clue.a),
			Puzzles.wheelName(clue.b),
			Puzzles.roman(clue.b)
		)
	end
	return string.format(
		"The %s wheel (%s) turns %s.",
		Puzzles.wheelName(clue.a),
		Puzzles.roman(clue.a),
		SLOT_WORDS[clue.b] or ("in place " .. tostring(clue.b))
	)
end

return Puzzles
