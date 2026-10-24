--!strict
-- Pure layout and timing arithmetic for the client UI. No Roblox APIs, so tests/specs/fix_client.luau and
-- tests/specs/hud_layout.luau can check it for 390-px-tall landscape phones, smaller phones and tablets. Sizes are
-- logical pixels of the ExpeditionUI ScreenGui (the safe area). None of this proves how Roblox lays out or draws the screens; that needs Studio and real devices (T21).

local UIRules = {}

UIRules.TOUCH = 52 -- the kit's touch target (UI.TOUCH)
UIRules.MIN_TOUCH = 48 -- section 17 minimum; a touch target is never smaller
UIRules.EDGE = 12 -- screen margin for HUD elements

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
-- or only the safe area, so take the larger of the two shorter sides: a wrong "big" only lifts the HUD above the
-- jump button higher and ends the action row further left.
function UIRules.isBigJump(guiW: number, guiH: number, viewW: number, viewH: number): boolean
	return math.max(math.min(guiW, guiH), math.min(viewW, viewH)) > 500
end

-- True only when both readings agree that the button is big. Anything placed below the jump button needs this: if
-- the button were in fact small, it would sit lower and could cover it.
function UIRules.isSurelyBigJump(guiW: number, guiH: number, viewW: number, viewH: number): boolean
	return math.min(math.min(guiW, guiH), math.min(viewW, viewH)) > 500
end

-- HUD layout (D108, owner request): a slim health readout top left; consumables as an icon column on the left;
-- the battery gauge bottom right; on touch screens a row of action slots along the very bottom (ending just left of
-- the jump button) and very small Crouch and Light buttons on the right. Everything here is in gui pixels.
UIRules.TOP = 8 -- top margin
UIRules.VITALS_W = 140 -- health, stamina and one status line, top left
UIRules.VITALS_H = 64
UIRules.PARTY_W = 140 -- party list, top right (up to four members and an invitation line)
UIRules.PARTY_H = 80
UIRules.SLOT_MAX = 52 -- consumable and action slots: 52 px, shrinking on short screens to no less than 40
UIRules.SLOT_MIN = 40
UIRules.SLOT_GAP = 6
UIRules.COLUMN_ROWS = 4 -- consumables per column; a fifth and sixth (sign, rope) start a second column
UIRules.BAR_BOTTOM = 6 -- gap between the action row and the bottom edge
UIRules.BAR_JUMP_GAP = 10 -- gap between the action row and the jump button
UIRules.SMALL_HIT = 40 -- Crouch and Light: a 30 px button inside a 40 px touch area (owner request: very small)
UIRules.SMALL_ICON = 30
UIRules.SMALL_GAP = 6
UIRules.BATTERY_W = 120
UIRules.BATTERY_H = 24
UIRules.LOW_GAP = 8 -- captions and the dialogue strip sit this far above the action row
UIRules.OBJECTIVE_H = 20 -- the one-line objective, top centre

export type Rect = { x: number, y: number, w: number, h: number }
export type Band = { x0: number, x1: number }

export type HudLayout = {
	touch: boolean,
	vitals: Rect,
	party: Rect,
	column: Rect, -- consumable slots, filled top to bottom, then a second column
	columnCell: number,
	columnRows: number,
	bar: Rect?, -- touch only: the action slots
	barCell: number,
	small: Rect?, -- touch only: Crouch and Light side by side
	battery: Rect,
	jump: Rect?, -- touch only: where the default jump button is assumed to be
	topBand: Band, -- objective, notices and popups, between the vitals and the party list
	noticeTop: number, -- top of the notices (below the one-line objective) and of popups
	lowBand: Band, -- captions and the dialogue strip, between the side columns, above the action row
	lowBottom: number, -- offset of the low band's bottom from the gui's bottom edge
}

local function rect(x: number, y: number, w: number, h: number): Rect
	return { x = x, y = y, w = w, h = h }
end

local function fit(avail: number, n: number): number
	return math.clamp(math.floor((avail - UIRules.SLOT_GAP * (n - 1)) / n), UIRules.SLOT_MIN, UIRules.SLOT_MAX)
end

-- `consumables` is the number of consumable slots shown (at least one); `barSlots` the number of touch actions.
function UIRules.hudLayout(
	guiW: number,
	guiH: number,
	viewW: number,
	viewH: number,
	touch: boolean,
	consumables: number,
	barSlots: number
): HudLayout
	local edge, gap = UIRules.EDGE, UIRules.SLOT_GAP
	local vitals = rect(edge, UIRules.TOP, UIRules.VITALS_W, UIRules.VITALS_H)
	local party = rect(guiW - edge - UIRules.PARTY_W, UIRules.TOP, UIRules.PARTY_W, UIRules.PARTY_H)

	-- Consumable column: below the vitals, centred in the height left, never past the bottom margin.
	local n = math.max(1, consumables)
	local rows = math.min(n, UIRules.COLUMN_ROWS)
	local cols = math.ceil(n / rows)
	local top = vitals.y + vitals.h + 8
	local avail = guiH - 8 - top
	local cell = fit(avail, rows)
	local colH = rows * cell + gap * (rows - 1)
	local column = rect(edge, top + math.max(0, math.floor((avail - colH) / 2)), cols * cell + gap * (cols - 1), colH)
	local columnRight = column.x + column.w

	local bar: Rect? = nil
	local barCell = 0
	local small: Rect? = nil
	local jump: Rect? = nil
	local battery: Rect
	local smallW = 2 * UIRules.SMALL_HIT + UIRules.SMALL_GAP
	local rightNeed = edge + UIRules.BATTERY_W + 8
	local lowBottom = 40
	if touch then
		local size, right, jumpTop = UIRules.jumpButton(UIRules.isBigJump(guiW, guiH, viewW, viewH))
		jump = rect(guiW - right, guiH - jumpTop, size, size)
		-- Action row: right-aligned just left of the jump button, at the very bottom.
		local barRight = guiW - right - UIRules.BAR_JUMP_GAP
		barCell = fit(barRight - (columnRight + 8), barSlots)
		local barW = barSlots * barCell + gap * (barSlots - 1)
		bar = rect(barRight - barW, guiH - UIRules.BAR_BOTTOM - barCell, barW, barCell)
		-- Battery: in the corner below the jump button when there is surely room (tablets), else just above it (phones).
		if UIRules.isSurelyBigJump(guiW, guiH, viewW, viewH) and jumpTop - size >= UIRules.BATTERY_H + 16 then
			battery = rect(
				guiW - edge - UIRules.BATTERY_W,
				guiH - edge - UIRules.BATTERY_H,
				UIRules.BATTERY_W,
				UIRules.BATTERY_H
			)
			small = rect(guiW - edge - smallW, guiH - jumpTop - 8 - UIRules.SMALL_HIT, smallW, UIRules.SMALL_HIT)
		else
			battery = rect(
				guiW - edge - UIRules.BATTERY_W,
				guiH - jumpTop - 8 - UIRules.BATTERY_H,
				UIRules.BATTERY_W,
				UIRules.BATTERY_H
			)
			small =
				rect(guiW - edge - smallW, battery.y - UIRules.SMALL_GAP - UIRules.SMALL_HIT, smallW, UIRules.SMALL_HIT)
		end
		rightNeed = math.max(rightNeed, right + 8, edge + smallW + 8)
		lowBottom = UIRules.BAR_BOTTOM + barCell + UIRules.LOW_GAP
	else
		battery =
			rect(guiW - edge - UIRules.BATTERY_W, guiH - edge - UIRules.BATTERY_H, UIRules.BATTERY_W, UIRules.BATTERY_H)
	end
	-- Centred strips use symmetric bands, so they stay centred on the screen.
	local topMargin = edge + math.max(UIRules.VITALS_W, UIRules.PARTY_W) + 16
	local lowMargin = math.max(columnRight + 8, rightNeed)
	return {
		touch = touch,
		vitals = vitals,
		party = party,
		column = column,
		columnCell = cell,
		columnRows = rows,
		bar = bar,
		barCell = barCell,
		small = small,
		battery = battery,
		jump = jump,
		topBand = { x0 = topMargin, x1 = guiW - topMargin },
		noticeTop = UIRules.TOP + UIRules.OBJECTIVE_H + 4,
		lowBand = { x0 = lowMargin, x1 = guiW - lowMargin },
		lowBottom = lowBottom,
	}
end

-- Width of a centred strip in a band: `frac` of the gui width, at most maxW, never wider than the band.
function UIRules.bandWidth(guiW: number, band: Band, frac: number, maxW: number): number
	return math.max(0, math.min(guiW * frac, maxW, band.x1 - band.x0))
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

-- The panel's rectangle when its bottom may not pass `bottomLimit` (the top of the touch action row less LOW_GAP):
-- centred as usual when it fits; otherwise it ends at the limit and keeps its top at TOP, shrinking if it must.
function UIRules.panelRectAbove(guiW: number, guiH: number, bottomLimit: number): (number, number, number, number)
	local x, y, w, h = UIRules.panelRect(guiW, guiH)
	if y + h <= bottomLimit then
		return x, y, w, h
	end
	local nh = math.min(h, bottomLimit - UIRules.TOP)
	return x, bottomLimit - nh, w, nh
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
