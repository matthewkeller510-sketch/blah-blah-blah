--!strict
-- Review fixes, batch 1 (client UX and accessibility). Pure arithmetic only (src/client/Controllers/UIRules): the
-- default jump button, the modal panel, dialogue paging and the P05 radio lamp rhythm, for 390-px-tall landscape
-- phones, smaller phones and tablets. The HUD layout that replaced the touch grid (D108) is checked in
-- tests/specs/hud_layout.luau. It does not
-- prove how Roblox lays out, draws or routes input to these screens; see docs/TEST-PLAN.md (T21) for device rows.

local UIRules = require("../../src/client/Controllers/UIRules")
local Puzzles = require("../../src/shared/Logic/Puzzles")
local CueDefs = require("../../src/shared/Data/CueDefs")
local StoryDefs = require("../../src/shared/Data/StoryDefs")

local Screens = require("../screens")

type Screen = Screens.Screen
type Rect = { x0: number, y0: number, x1: number, y1: number }

local function rect(x: number, y: number, w: number, h: number): Rect
	return { x0 = x, y0 = y, x1 = x + w, y1 = y + h }
end

local PHONES_390, OTHER_PHONES, TABLETS = Screens.PHONES_390, Screens.OTHER_PHONES, Screens.TABLETS
local all = Screens.all

-- The HUD layout on a touch screen with the four standard consumables (UI.BAR_SLOTS = 7).
local function touchLayout(s: Screen): UIRules.HudLayout
	return UIRules.hudLayout(s.w, s.h, s.vw, s.vh, true, 4, 7)
end

-- A rough GothamMedium wrap: about 0.6 em per character, words kept whole. Height = lines x text size.
local function wrapHeight(text: string, width: number, size: number): number
	local perLine = math.max(1, math.floor(width / (0.6 * size)))
	local lines, cur = 1, 0
	for _, word in string.split(text, " ") do
		local len = utf8.len(word) or #word
		if cur == 0 then
			cur = len
		elseif cur + 1 + len <= perLine then
			cur += 1 + len
		else
			lines += 1
			cur = len
		end
		if len > perLine then
			lines += math.ceil(len / perLine) - 1
			cur = len % perLine
		end
	end
	return lines * size
end

local function longestDialogueLine(): string
	local best = ""
	local function walk(t: any)
		for k, v in t do
			if type(v) == "table" then
				walk(v)
			elseif type(v) == "string" and type(k) == "number" and #v > #best then
				best = v
			end
		end
	end
	walk(StoryDefs.Lines)
	return best
end

return function(T)
	local test, eq = T.test, T.eq

	-- Threat cues ---------------------------------------------------------------------------------------
	test("every screen-closing threat cue is a defined, essential cue", function()
		local n = 0
		for id in UIRules.THREAT_CUES do
			n += 1
			local def = CueDefs[id]
			assert(def ~= nil, "unknown cue " .. id)
			assert(def.essential, id .. " should be essential")
		end
		eq(n, 5, "chase approach cues")
		for _, id in { "scrabbler_windup", "knocker_knock", "wader_drag", "thief_strike" } do
			assert(UIRules.isThreatCue({ id = id }), id .. " closes screens")
		end
		-- the Lantern Thief's rattle closes screens only when it starts an approach, not while it merely stalks
		assert(UIRules.isThreatCue({ id = "thief_rattle", extra = { warn = true } }), "engagement rattle")
		assert(not UIRules.isThreatCue({ id = "thief_rattle" }), "stalking rattle")
		assert(not UIRules.isThreatCue({ id = "miner_rhythm" }), "harmless cue")
		assert(not UIRules.isThreatCue(nil), "no payload")
	end)

	-- The default jump button (findings 19, 20) -------------------------------------------------------------
	test("390-px-tall phones get the small jump button, tablets the big one", function()
		for _, s in all(PHONES_390, OTHER_PHONES) do
			assert(not UIRules.isBigJump(s.w, s.h, s.vw, s.vh), s.name .. ": small jump button")
		end
		for _, s in TABLETS do
			assert(UIRules.isBigJump(s.w, s.h, s.vw, s.vh), s.name .. ": big jump button")
			assert(UIRules.isSurelyBigJump(s.w, s.h, s.vw, s.vh), s.name .. ": surely big")
		end
	end)

	test("the jump size test is conservative when the safe area and the viewport disagree", function()
		-- safe area under 500 px tall but a 540 px viewport: the touch GUI may see the big button
		assert(UIRules.isBigJump(900, 462, 960, 540), "big when the viewport says so")
		assert(not UIRules.isBigJump(750, 311, 844, 390), "small phone stays small")
	end)

	-- HUD strips (findings 20, 21, 23) now follow UIRules.hudLayout's bands: tests/specs/hud_layout.luau.

	-- Modal panel (findings 18, 22, 24) ------------------------------------------------------------------
	test("a panel's Close is a full touch target, fully on screen, with room for its body on phones", function()
		for _, s in all(PHONES_390, OTHER_PHONES, TABLETS) do
			local px, py, pw, ph = UIRules.panelRect(s.w, s.h)
			local close = rect(
				px + pw - UIRules.PANEL_PAD - UIRules.PANEL_CLOSE_W,
				py + UIRules.PANEL_PAD,
				UIRules.PANEL_CLOSE_W,
				UIRules.TOUCH
			)
			assert(
				close.y0 >= 0 and close.y1 <= s.h and close.x0 >= 0 and close.x1 <= s.w,
				s.name .. ": Close on screen"
			)
			assert(UIRules.TOUCH >= UIRules.MIN_TOUCH, "Close height")
			local bodyH = ph - 2 * UIRules.PANEL_PAD - UIRules.PANEL_BODY_TOP
			assert(bodyH >= 2 * UIRules.TOUCH, s.name .. ": body shows at least two rows, " .. bodyH)
			-- M03: three Give buttons share a row (row inset 8 for the scroll bar, list gap 6)
			local give = (pw - 2 * UIRules.PANEL_PAD - 8 - 2 * 6) / 3
			assert(give >= UIRules.MIN_TOUCH, s.name .. ": Give button width " .. give)
		end
	end)

	test("the panel title ends before Close", function()
		local _, _, pw = UIRules.panelRect(750, 311)
		local inner = pw - 2 * UIRules.PANEL_PAD
		local titleW = inner - (UIRules.PANEL_CLOSE_W + 8)
		assert(titleW + 8 + UIRules.PANEL_CLOSE_W <= inner, "title and Close side by side")
		-- the 32 px title at text size 1.6 fits the 52 px header row on one line
		assert(math.floor(20 * 1.6) <= UIRules.TOUCH, "title height")
	end)

	-- Dialogue (findings 21, 22) -------------------------------------------------------------------------
	test("the dialogue strip with three 52 px buttons fits above the action row on phones", function()
		eq(UIRules.DIALOGUE_BUTTONS, 3 * UIRules.TOUCH + 2 * 8, "button column")
		for _, s in all(PHONES_390, OTHER_PHONES, TABLETS) do
			local maxH = UIRules.dialogueMaxHeight(s.h)
			assert(maxH >= UIRules.DIALOGUE_BUTTONS + 2 * UIRules.DIALOGUE_PAD, s.name .. ": room for the buttons")
			assert(s.h - touchLayout(s).lowBottom - maxH >= 0, s.name .. ": strip top on screen")
		end
		eq(UIRules.dialogueMaxHeight(311), 188, "phone: the button column decides")
		eq(UIRules.dialogueMaxHeight(690), 414, "tablet: 60% of the height")
	end)

	local function pagesFor(s: Screen, textScale: number, l: UIRules.HudLayout): ({ string }, number, number, number)
		local size = math.floor(18 * textScale)
		local nameH = math.ceil(14 * textScale) + 2
		local bw = UIRules.bandWidth(s.w, l.lowBand, 0.56, 620)
		local textW = bw - 2 * UIRules.DIALOGUE_PAD - 116
		local cap = UIRules.dialogueLineCap(s.h, nameH)
		local text = longestDialogueLine()
		local pages = UIRules.paginate(text, function(candidate: string): boolean
			return wrapHeight(candidate, textW, size) <= cap
		end)
		return pages, textW, size, cap
	end

	test("the longest dialogue line at text size 1.6 on phones is paged, every page fits on screen", function()
		local text = longestDialogueLine()
		assert(#text > 120, "longest line found")
		for _, s in all(PHONES_390, OTHER_PHONES) do
			local l = touchLayout(s)
			for _, scale in { 1, 1.2, 1.4, 1.6 } do
				local pages, textW, size, cap = pagesFor(s, scale, l)
				eq(table.concat(pages, " "), text, s.name .. ": nothing lost")
				for _, p in pages do
					local h = wrapHeight(p, textW, size)
					assert(h <= cap, string.format("%s at %.1f: page height %d over %d", s.name, scale, h, cap))
					local nameH = math.ceil(14 * scale) + 2
					local panelH = math.max(UIRules.DIALOGUE_BUTTONS, nameH + 2 + h) + 2 * UIRules.DIALOGUE_PAD
					assert(s.h - l.lowBottom - panelH >= 0, s.name .. ": strip stays on screen")
				end
				if scale == 1.6 then
					assert(#pages >= 2, s.name .. ": the long line needs pages at 1.6")
				end
			end
		end
	end)

	test("on a desktop screen the longest line needs no paging", function()
		local desktop = Screens.DESKTOPS[1]
		local pages = pagesFor(desktop, 1, UIRules.hudLayout(desktop.w, desktop.h, desktop.vw, desktop.vh, false, 4, 7))
		eq(#pages, 1, "one page")
	end)

	test("paginate keeps words whole and handles edge cases", function()
		local function maxChars(n: number): (string) -> boolean
			return function(candidate: string): boolean
				return #candidate <= n
			end
		end
		local p = UIRules.paginate("aa bb cc dd", maxChars(5))
		eq(#p, 2, "two pages")
		eq(p[1], "aa bb")
		eq(p[2], "cc dd")
		local single = UIRules.paginate("short line", maxChars(100))
		eq(#single, 1)
		eq(single[1], "short line")
		local long = UIRules.paginate("tiny enormousword tiny", maxChars(6))
		eq(#long, 3, "an oversized word gets its own page")
		eq(long[2], "enormousword")
		local empty = UIRules.paginate("", maxChars(5))
		eq(#empty, 1)
		eq(empty[1], "")
	end)

	-- P05 radio lamp (finding 26) ------------------------------------------------------------------------
	test("the radio lamp loop follows the echo timeline plus a 2.5 s rest", function()
		local tl = Puzzles.echoTimeline("SLSS")
		local level = function(t: number): number
			return UIRules.echoLampLevel(tl, 2.5, t, false)
		end
		-- S 0..0.25, gap ..0.6, L 0.6..1.35, gap ..1.7, S 1.7..1.95, gap ..2.3, S 2.3..2.55, gap ..2.9, rest ..5.4
		eq(level(0.1), 1, "first short on")
		eq(level(0.3), 0, "gap")
		eq(level(0.7), 1, "long on")
		eq(level(1.3), 1, "long still on")
		eq(level(1.4), 0, "gap after long")
		eq(level(1.8), 1, "third")
		eq(level(2.4), 1, "fourth")
		eq(level(2.6), 0, "gap")
		eq(level(3.0), 0, "rest")
		eq(level(5.3), 0, "rest end")
		eq(level(5.4 + 0.1), 1, "repeats")
		eq(level(-5.4 + 0.1), 1, "a client clock just behind the epoch is still in phase")
		eq(level(5.4 * 1000 + 0.7), 1, "long after the epoch")
	end)

	test("with Reduce flashes the lamp swells gently and never snaps to full", function()
		local tl = Puzzles.echoTimeline("SL")
		local peak = 0
		for i = 0, 400 do
			local t = i * 0.01
			local v = UIRules.echoLampLevel(tl, 2.5, t, true)
			assert(v >= 0 and v <= UIRules.REDUCED_PEAK + 1e-9, "bounded at " .. t)
			peak = math.max(peak, v)
		end
		T.near(peak, UIRules.REDUCED_PEAK, 0.01, "reaches the gentle peak")
		eq(UIRules.echoLampLevel(tl, 2.5, 0, true), 0, "starts dark: no step")
		T.near(UIRules.echoLampLevel(tl, 2.5, 0.125, true), UIRules.REDUCED_PEAK, 1e-9, "short peaks mid-step")
		-- the long element swells for 0.75 s: still lit at 0.6 s into it, where a short one is long dark
		assert(UIRules.echoLampLevel(tl, 2.5, 0.6 + 0.6, true) > 0.2, "long swell lasts")
		eq(UIRules.echoLampLevel(tl, 2.5, 0.3, true), 0, "gap after the short")
	end)

	test("an empty or broken lamp pattern stays dark", function()
		eq(UIRules.echoLampLevel({}, 2.5, 1, false), 0, "empty timeline")
		eq(UIRules.echoLampLevel({}, 0, 1, false), 0, "zero cycle")
		eq(UIRules.echoLampLevel(Puzzles.echoTimeline("S"), 2.5, 0 / 0, false), 0, "NaN time")
	end)
end
