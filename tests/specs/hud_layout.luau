--!strict
-- HUD layout and icons (D108-D110, owner request): no status panel; consumables as an icon column on the left; the
-- battery gauge bottom right; a touch action row along the very bottom ending just left of the jump button; very
-- small Crouch and Light buttons on the right. Pure arithmetic over UIRules.hudLayout and the IconDefs data: it does
-- not prove how Roblox draws or routes input to these frames (T21 needs devices).

local UIRules = require("../../src/client/Controllers/UIRules")
local IconDefs = require("../../src/client/Controllers/IconDefs")
local ItemDefs = require("../../src/shared/Data/ItemDefs")
local Screens = require("../screens")

type Screen = Screens.Screen
type Rect = UIRules.Rect

local BAR_SLOTS = 7 -- UI.BAR_SLOTS: Menu, Ping, Help, Shield, Throw, Use, Sprint

local function overlaps(a: Rect, b: Rect): boolean
	return a.x < b.x + b.w and b.x < a.x + a.w and a.y < b.y + b.h and b.y < a.y + a.h
end

local function onScreen(r: Rect, s: Screen): boolean
	return r.x >= 0 and r.y >= 0 and r.x + r.w <= s.w and r.y + r.h <= s.h
end

local function rect(x: number, y: number, w: number, h: number): Rect
	return { x = x, y = y, w = w, h = h }
end

local function layout(s: Screen, touch: boolean, consumables: number?): UIRules.HudLayout
	return UIRules.hudLayout(s.w, s.h, s.vw, s.vh, touch, consumables or 4, BAR_SLOTS)
end

-- Named rectangles of a layout that must never overlap one another.
local function parts(l: UIRules.HudLayout): { { name: string, r: Rect } }
	local out = {
		{ name = "vitals", r = l.vitals },
		{ name = "party", r = l.party },
		{ name = "column", r = l.column },
		{ name = "battery", r = l.battery },
	}
	for _, p in { { "bar", l.bar }, { "small", l.small }, { "jump", l.jump } } do
		local r = p[2] :: Rect?
		if r then
			table.insert(out, { name = p[1] :: string, r = r })
		end
	end
	return out
end

local TOUCH_SCREENS = Screens.all(Screens.PHONES_390, Screens.OTHER_PHONES, Screens.TABLETS)

return function(T)
	local test, eq = T.test, T.eq

	-- Layout -----------------------------------------------------------------------------------------------
	test("no HUD element overlaps another or leaves the screen, on phones and tablets", function()
		for _, s in TOUCH_SCREENS do
			for _, n in { 4, 5, 6 } do
				local l = layout(s, true, n)
				local ps = parts(l)
				for i, a in ps do
					local label = string.format("%s (%d consumables) %s", s.name, n, a.name)
					if a.name ~= "jump" then
						assert(onScreen(a.r, s), label .. " is on screen")
					end
					for j = i + 1, #ps do
						local b = ps[j]
						assert(not overlaps(a.r, b.r), label .. " overlaps " .. b.name)
					end
				end
			end
		end
	end)

	test("on a desktop there is no action row or small buttons; the battery is in the corner", function()
		for _, s in Screens.DESKTOPS do
			local l = layout(s, false)
			assert(l.bar == nil and l.small == nil and l.jump == nil, s.name)
			eq(l.battery.x + l.battery.w, s.w - UIRules.EDGE, s.name .. ": right edge")
			eq(l.battery.y + l.battery.h, s.h - UIRules.EDGE, s.name .. ": bottom edge")
			local ps = parts(l)
			for i, a in ps do
				assert(onScreen(a.r, s), s.name .. " " .. a.name)
				for j = i + 1, #ps do
					assert(not overlaps(a.r, ps[j].r), s.name .. " " .. a.name .. " / " .. ps[j].name)
				end
			end
		end
	end)

	test("consumables stack on the left, top to bottom, at full touch size on 390-px phones", function()
		for _, s in Screens.PHONES_390 do
			local l = layout(s, true, 4)
			eq(l.column.x, UIRules.EDGE, s.name .. ": left edge")
			eq(l.columnRows, 4, s.name .. ": one column of four")
			eq(l.column.w, l.columnCell, s.name .. ": a single column")
			assert(l.columnCell >= UIRules.MIN_TOUCH, s.name .. ": cell " .. l.columnCell)
			assert(l.column.y >= l.vitals.y + l.vitals.h, s.name .. ": below the health readout")
			-- a sign and a rope start a second column beside the first
			local six = layout(s, true, 6)
			eq(six.columnRows, 4, s.name)
			eq(six.column.w, 2 * six.columnCell + UIRules.SLOT_GAP, s.name .. ": two columns")
		end
		for _, s in Screens.all(Screens.OTHER_PHONES, Screens.TABLETS) do
			local l = layout(s, true, 6)
			assert(l.columnCell >= UIRules.SLOT_MIN, s.name .. ": column cell " .. l.columnCell)
		end
	end)

	test("the action row runs along the very bottom and ends just left of the jump button", function()
		for _, s in TOUCH_SCREENS do
			for _, n in { 4, 6 } do
				local l = layout(s, true, n)
				local bar, jump = l.bar :: Rect, l.jump :: Rect
				local label = s.name .. " (" .. n .. ")"
				eq(bar.y + bar.h, s.h - UIRules.BAR_BOTTOM, label .. ": at the very bottom")
				eq(jump.x - (bar.x + bar.w), UIRules.BAR_JUMP_GAP, label .. ": next to the jump button")
				eq(bar.w, BAR_SLOTS * l.barCell + (BAR_SLOTS - 1) * UIRules.SLOT_GAP, label .. ": all slots")
				assert(l.barCell >= UIRules.SLOT_MIN, label .. ": slot " .. l.barCell)
				assert(bar.x >= l.column.x + l.column.w + 8, label .. ": clear of the consumable column")
			end
		end
		for _, s in Screens.PHONES_390 do
			eq(layout(s, true).barCell, UIRules.SLOT_MAX, s.name .. ": 52 px slots")
		end
	end)

	test("Crouch and Light are very small and sit on the right, above the jump button", function()
		-- owner request (D108): below the section 17 minimum on purpose, with a touch area larger than the drawing
		assert(UIRules.SMALL_ICON < UIRules.MIN_TOUCH, "very small")
		assert(UIRules.SMALL_HIT > UIRules.SMALL_ICON, "a touch area larger than the drawn button")
		for _, s in TOUCH_SCREENS do
			local l = layout(s, true)
			local small, jump = l.small :: Rect, l.jump :: Rect
			eq(small.x + small.w, s.w - UIRules.EDGE, s.name .. ": right edge")
			eq(small.w, 2 * UIRules.SMALL_HIT + UIRules.SMALL_GAP, s.name .. ": two buttons")
			assert(small.y + small.h <= jump.y, s.name .. ": above the jump button")
			assert(small.x > s.w / 2, s.name .. ": right side")
		end
	end)

	test("the battery sits bottom right: above the jump button on phones, in the corner below it on tablets", function()
		for _, s in Screens.all(Screens.PHONES_390, Screens.OTHER_PHONES) do
			local l = layout(s, true)
			local b, jump = l.battery, l.jump :: Rect
			eq(b.x + b.w, s.w - UIRules.EDGE, s.name .. ": right edge")
			eq(jump.y - (b.y + b.h), 8, s.name .. ": just above the jump button")
			assert(b.y > s.h / 2, s.name .. ": lower half")
		end
		for _, s in Screens.TABLETS do
			local l = layout(s, true)
			local b = l.battery
			eq(b.x + b.w, s.w - UIRules.EDGE, s.name .. ": right edge")
			eq(b.y + b.h, s.h - UIRules.EDGE, s.name .. ": bottom corner")
		end
	end)

	test("when the jump size is uncertain nothing is placed where a small button could be", function()
		-- safe area under 500 px tall, viewport over 500: the button may be either size
		local s: Screen = { name = "uncertain", w = 900, h = 462, vw = 960, vh = 540 }
		assert(UIRules.isBigJump(s.w, s.h, s.vw, s.vh), "assumed big for the row")
		assert(not UIRules.isSurelyBigJump(s.w, s.h, s.vw, s.vh), "but not surely")
		local l = layout(s, true)
		for _, big in { true, false } do
			local size, right, top = UIRules.jumpButton(big)
			local real = rect(s.w - right, s.h - top, size, size)
			for _, p in parts(l) do
				if p.name ~= "jump" then
					assert(
						not overlaps(p.r, real),
						p.name .. " clear of a " .. (if big then "big" else "small") .. " button"
					)
				end
			end
		end
	end)

	test("the top band (objective, notices, popups) lies between the health readout and the party list", function()
		local cases: { { s: Screen, touch: boolean } } = {}
		for _, s in TOUCH_SCREENS do
			table.insert(cases, { s = s, touch = true })
		end
		for _, s in Screens.DESKTOPS do
			table.insert(cases, { s = s, touch = false })
		end
		for _, case in cases do
			local s = case.s
			local l = layout(s, case.touch)
			local b = l.topBand
			assert(b.x0 >= l.vitals.x + l.vitals.w + 16, s.name .. ": right of the vitals")
			assert(b.x1 <= l.party.x - 16, s.name .. ": left of the party list")
			eq(b.x0 + b.x1, s.w, s.name .. ": centred")
			local w = UIRules.bandWidth(s.w, b, 0.8, 420)
			assert(w >= 220, s.name .. ": a popup is still readable, width " .. w)
			-- three notices of two lines (14 px text, 4 px padding, 4 px gaps) stay above every bottom control
			local notices = rect(s.w / 2 - w / 2, l.noticeTop, w, 3 * (2 * 14 + 8) + 2 * 4)
			for _, p in parts(l) do
				assert(not overlaps(notices, p.r), s.name .. ": notices clear of " .. p.name)
			end
			assert(l.noticeTop >= UIRules.TOP + UIRules.OBJECTIVE_H, s.name .. ": below the objective")
		end
	end)

	test("captions and the dialogue strip stay between the side controls and above the action row", function()
		for _, s in TOUCH_SCREENS do
			for _, n in { 4, 6 } do
				local l = layout(s, true, n)
				local b = l.lowBand
				local label = s.name .. " (" .. n .. ")"
				eq(b.x0 + b.x1, s.w, label .. ": centred")
				-- a full-height strip in the band, ending at the band's bottom, touches no control
				local strip = rect(b.x0, 0, b.x1 - b.x0, s.h - l.lowBottom)
				for _, p in parts(l) do
					if p.name ~= "vitals" and p.name ~= "party" then
						assert(not overlaps(strip, p.r), label .. ": clear of " .. p.name)
					end
				end
				local bar = l.bar :: Rect
				eq(s.h - l.lowBottom, bar.y - UIRules.LOW_GAP, label .. ": just above the action row")
				-- five caption lines stay clear of the health readout and the party list
				local captions = rect(b.x0, s.h - l.lowBottom - 5 * 20, b.x1 - b.x0, 5 * 20)
				assert(not overlaps(captions, l.vitals), label .. ": captions clear of the vitals")
				assert(not overlaps(captions, l.party), label .. ": captions clear of the party list")
				assert(UIRules.bandWidth(s.w, b, 0.6, math.huge) >= 200, label .. ": captions readable")
			end
		end
	end)

	test("with no touch controls the strips stay centred at their usual width", function()
		local s = Screens.DESKTOPS[1]
		local l = layout(s, false)
		eq(UIRules.bandWidth(s.w, l.lowBand, 0.6, math.huge), s.w * 0.6, "captions")
		eq(UIRules.bandWidth(s.w, l.lowBand, 0.56, 620), 620, "dialogue capped")
		eq(UIRules.bandWidth(s.w, l.topBand, 0.5, 460), 460, "objective capped")
	end)

	-- Icons ------------------------------------------------------------------------------------------------
	local USED = {
		"med",
		"cell",
		"flare",
		"chalk",
		"sign",
		"rope",
		"bar",
		"stun",
		"stone",
		"lantern",
		"lantern_shut",
		"help",
		"ping",
		"menu",
		"sprint",
		"crouch",
		"crouch_on",
		"light",
		"light_off",
		"heart",
		"missing",
	}

	test("every icon the HUD draws exists, stays inside its square and uses defined colours", function()
		for _, name in USED do
			local shapes = IconDefs.ICONS[name]
			assert(shapes ~= nil and #shapes > 0, "icon " .. name)
		end
		for name, shapes in IconDefs.ICONS do
			for i, sh in shapes do
				local label = string.format("%s shape %d", name, i)
				assert(IconDefs.COLORS[sh.c] ~= nil, label .. ": colour " .. sh.c)
				assert(sh.w > 0 and sh.h > 0, label .. ": size")
				assert((sh.a or 0) >= 0 and (sh.a or 0) < 1, label .. ": visible")
				assert((sh.rad or 0) >= 0 and (sh.rad or 0) <= 0.5, label .. ": corner")
				if sh.k == "ring" then
					assert(sh.t ~= nil and sh.t > 0, label .. ": ring thickness")
				end
				for _, p in IconDefs.corners(sh) do
					assert(p[1] >= -1e-6 and p[1] <= 1 + 1e-6, label .. ": x " .. p[1])
					assert(p[2] >= -1e-6 and p[2] <= 1 + 1e-6, label .. ": y " .. p[2])
				end
			end
		end
	end)

	test("each consumable has its own picture, and every state has its own shape, not only a colour", function()
		local function key(name: string): string
			local parts = {}
			for _, sh in IconDefs.ICONS[name] do
				table.insert(parts, string.format("%s%.2f%.2f%.2f%.2f%d", sh.k, sh.x, sh.y, sh.w, sh.h, sh.r or 0))
			end
			return table.concat(parts, "|")
		end
		local seen: { [string]: string } = {}
		for _, name in { "med", "cell", "flare", "chalk", "sign", "rope" } do
			local k = key(name)
			assert(seen[k] == nil, name .. " looks like " .. tostring(seen[k]))
			seen[k] = name
		end
		for _, pair in { { "crouch", "crouch_on" }, { "light", "light_off" }, { "lantern", "lantern_shut" } } do
			assert(key(pair[1]) ~= key(pair[2]), pair[1] .. " and " .. pair[2] .. " differ in shape")
		end
	end)

	test("every carried consumable item maps to an icon", function()
		for _, id in { "med.cloth_dressing", "med.bandage", "med.splint", "power.cell", "tool.flare", "nav.chalk" } do
			assert(ItemDefs.get(id) ~= nil, "item " .. id)
			local icon = IconDefs.forItem(id)
			assert(icon ~= nil and IconDefs.ICONS[icon] ~= nil, id .. " has an icon")
		end
		for _, id in { "nav.sign", "nav.rope", "tool.iron_bar", "tool.stun_device", "light.shielded_lantern" } do
			assert(ItemDefs.get(id) ~= nil, "item " .. id)
			assert(IconDefs.forItem(id) ~= nil, id .. " has an icon")
		end
	end)

	test("a rotated shape's corners follow the screen's clockwise rotation", function()
		-- a vertical bar turned 90 degrees clockwise lies flat
		local c = IconDefs.corners({ k = "rect", x = 0.5, y = 0.5, w = 0.2, h = 0.6, c = "bone", r = 90 })
		local minX, maxX = math.huge, -math.huge
		for _, p in c do
			minX, maxX = math.min(minX, p[1]), math.max(maxX, p[1])
		end
		T.near(maxX - minX, 0.6, 1e-9, "now 0.6 wide")
		-- a ring's outline counts toward its extent
		local r = IconDefs.corners({ k = "ring", x = 0.5, y = 0.5, w = 0.6, h = 0.6, c = "bone", t = 0.1 })
		T.near(r[1][1], 0.1, 1e-9, "outline grows the ring")
	end)
end
