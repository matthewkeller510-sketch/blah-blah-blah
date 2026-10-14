--!strict
-- Pure layout and timing arithmetic for the client UI. No Roblox APIs, so tests/specs/fix_client.luau can check it
-- for a 390-px-tall landscape phone and a tablet. Sizes are logical pixels of the ExpeditionUI ScreenGui (the safe
-- area). None of this proves how Roblox lays out or draws the screens; that needs Studio and real devices (T21).

local UIRules = {}

UIRules.TOUCH = 52 -- the kit's touch target (UI.TOUCH)
UIRules.MIN_TOUCH = 48 -- section 17 minimum; a touch target is never smaller
UIRules.EDGE = 12 -- screen margin for HUD elements kept clear of the touch grid

-- Approach cues of damaging creatures. Interactive screens step aside for them (and for going down), so nothing the
-- player opened covers the screen during a chase.
UIRules.THREAT_CUES = {
	scrabbler_windup = true,
	knocker_knock = true,
	wader_drag = true,
	wader_strike = true,
	thief_strike = true,
} :: { [string]: boolean }

-- True for a cue that starts a chase. The Lantern Thief rattles every few seconds while it only stalks; only the
-- rattle that starts its approach (extra.warn) counts, so screens are not closed over and over during a stalk.
function UIRules.isThreatCue(d: any): boolean
	if type(d) ~= "table" then
		return false
	end
	if d.id == "thief_rattle" then
		return type(d.extra) == "table" and d.extra.warn == true
	end
	return UIRules.THREAT_CUES[d.id] == true
end

-- Roblox's default touch jump button (PlayerModule TouchJump): a 70 px button at UDim2.new(1, -95, 1, -90) when the
-- screen's shorter side is at most 500 px, otherwise a 120 px button at UDim2.new(1, -170, 1, -210).
-- Returns the button's size and its offsets from the right and bottom edges to its left and top edges.
function UIRules.jumpButton(big: boolean): (number, number, number)
	if big then
		return 120, 170, 210
	end
	return 70, 95, 90
end

-- The jump button is big when the touch GUI's shorter side exceeds 500 px. The touch GUI may span the whole viewport
-- or only the safe area, so take the larger of the two shorter sides: a wrong "big" only lifts the grid higher.
function UIRules.isBigJump(guiW: number, guiH: number, viewW: number, viewH: number): boolean
	return math.max(math.min(guiW, guiH), math.min(viewW, viewH)) > 500
end

-- Touch action grid (D79, revised): 5 columns x 3 rows (13 buttons) filled from the bottom-right corner, sitting
-- just above the jump button. Cells shrink from 52 px only when the screen is too short, never below 48 px.
UIRules.GRID_COLS = 5
UIRules.GRID_ROWS = 3
UIRules.GRID_GAP = 8
UIRules.GRID_RIGHT = 16 -- gap to the right edge
UIRules.GRID_ABOVE_JUMP = 10 -- gap above the jump button's top edge (PROPOSED)
UIRules.GRID_TOP = 8 -- room kept above the top row

export type TouchGrid = {
	cell: number,
	gap: number,
	width: number,
	height: number,
	right: number, -- offset of the grid's right edge from the gui's right edge
	bottom: number, -- offset of the grid's bottom edge from the gui's bottom edge
	reserve: number, -- width at the right edge that other HUD elements keep clear of (grid + gap)
}

function UIRules.touchGrid(guiW: number, guiH: number, viewW: number, viewH: number): TouchGrid
	local _, _, jumpTop = UIRules.jumpButton(UIRules.isBigJump(guiW, guiH, viewW, viewH))
	local cols, rows, gap = UIRules.GRID_COLS, UIRules.GRID_ROWS, UIRules.GRID_GAP
	local bottom = jumpTop + UIRules.GRID_ABOVE_JUMP
	local avail = guiH - bottom - UIRules.GRID_TOP
	local cell = math.clamp(math.floor((avail - gap * (rows - 1)) / rows), UIRules.MIN_TOUCH, UIRules.TOUCH)
	local width = cols * cell + gap * (cols - 1)
	return {
		cell = cell,
		gap = gap,
		width = width,
		height = rows * cell + gap * (rows - 1),
		right = UIRules.GRID_RIGHT,
		bottom = bottom,
		reserve = UIRules.GRID_RIGHT + width + 8,
	}
end

-- UI.panel (every modal screen): 90% x 82% of the gui, at most 560 x 640, centred, 12 px padding. The header row is
-- one touch target tall (Close, 72 px wide) and the scrolling body starts 8 px below it.
UIRules.PANEL_SCALE_W = 0.9
UIRules.PANEL_SCALE_H = 0.82
UIRules.PANEL_MAX_W = 560
UIRules.PANEL_MAX_H = 640
UIRules.PANEL_PAD = 12
UIRules.PANEL_CLOSE_W = 72
UIRules.PANEL_BODY_TOP = UIRules.TOUCH + 8

-- The panel's rectangle: left x, top y, width, height.
function UIRules.panelRect(guiW: number, guiH: number): (number, number, number, number)
	local w = math.min(guiW * UIRules.PANEL_SCALE_W, UIRules.PANEL_MAX_W)
	local h = math.min(guiH * UIRules.PANEL_SCALE_H, UIRules.PANEL_MAX_H)
	return (guiW - w) / 2, (guiH - h) / 2, w, h
end

-- Horizontal placement of a centred element that wants `frac` of the gui width (at most maxW): with nothing reserved
-- it is centred on the screen; otherwise it is centred in [margin, guiW - reserve] and narrowed to fit there.
-- Returns its left x and its width.
function UIRules.band(guiW: number, reserve: number, frac: number, maxW: number, margin: number): (number, number)
	local right = guiW - math.max(reserve, margin)
	local w = math.min(guiW * frac, maxW, math.max(0, right - margin))
	local centre = if reserve > 0 then (margin + right) / 2 else guiW / 2
	return centre - w / 2, w
end

-- Dialogue strip: its button column (Next, Close, Auto at 52 px with 8 px gaps) sets the minimum height; a line
-- longer than the space left in 60% of the screen height (PROPOSED / TUNE) is split into pages, never clipped.
UIRules.DIALOGUE_BUTTONS = 3 * 52 + 2 * 8
UIRules.DIALOGUE_PAD = 8
UIRules.DIALOGUE_SHARE = 0.6

function UIRules.dialogueMaxHeight(guiH: number): number
	return math.max(UIRules.DIALOGUE_BUTTONS + 2 * UIRules.DIALOGUE_PAD, math.floor(guiH * UIRules.DIALOGUE_SHARE))
end

-- Height available to one page of a line under the speaker's name (nameH, plus the 2 px list gap).
function UIRules.dialogueLineCap(guiH: number, nameH: number): number
	return math.max(40, UIRules.dialogueMaxHeight(guiH) - 2 * UIRules.DIALOGUE_PAD - nameH - 2)
end

-- Splits text into pages at spaces so that `fits(page)` holds for each page. A single word that does not fit gets a
-- page of its own (it is never cut). Joining the pages with single spaces gives single-spaced text back.
function UIRules.paginate(text: string, fits: (string) -> boolean): { string }
	local pages: { string } = {}
	local cur = ""
	for _, word in string.split(text, " ") do
		local candidate = if cur == "" then word else cur .. " " .. word
		if cur ~= "" and not fits(candidate) then
			table.insert(pages, cur)
			cur = word
		else
			cur = candidate
		end
	end
	if cur ~= "" or #pages == 0 then
		table.insert(pages, cur)
	end
	return pages
end

-- P05 radio lamp: brightness 0..1 at `elapsed` seconds after the pattern's epoch. The loop is the echo timeline's
-- on/off steps followed by `rest` seconds dark (the rhythm the server lamp used). Hard on/off normally; with Reduce
-- flashes each "on" becomes one smooth rise and fall to at most REDUCED_PEAK, so short and long stay readable as
-- the length of the swell without a hard flash.
UIRules.REDUCED_PEAK = 0.6

function UIRules.echoLampLevel(
	timeline: { { on: number, off: number } },
	rest: number,
	elapsed: number,
	reduce: boolean
): number
	local cycle = rest
	for _, step in timeline do
		cycle += step.on + step.off
	end
	if cycle <= 0 or elapsed ~= elapsed then
		return 0
	end
	local t = elapsed % cycle
	for _, step in timeline do
		if t < step.on then
			return if reduce then UIRules.REDUCED_PEAK * math.sin(math.pi * t / step.on) else 1
		end
		t -= step.on
		if t < step.off then
			return 0
		end
		t -= step.off
	end
	return 0
end

return UIRules
