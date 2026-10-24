--!strict
-- Procedural HUD icons (D109). No image assets are bound yet (every iconRef in ItemDefs is a PLACEHOLDER), so the
-- consumables and actions are drawn from a few flat shapes that Controllers/Icons turns into frames. Pure data, no
-- Roblox APIs: tests/specs/hud_layout.luau checks every shape stays inside its square and every colour exists.
-- Replace with uploaded art when it exists.
--
-- A shape is centred at (x, y) with size (w, h), all as fractions of the icon's square; r is a clockwise rotation in
-- degrees; rad rounds the corners (a fraction of the shorter side, 0.5 = circle or capsule); a is transparency.
-- A "ring" is an outline only, `t` thick (a fraction of the icon size), drawn outside its edges.

local IconDefs = {}

export type Shape = {
	k: "rect" | "ring",
	x: number,
	y: number,
	w: number,
	h: number,
	c: string,
	r: number?,
	rad: number?,
	a: number?,
	t: number?,
}

IconDefs.COLORS = {
	bone = { 232, 226, 210 },
	white = { 244, 240, 232 },
	dim = { 120, 116, 108 },
	dark = { 44, 42, 40 },
	red = { 178, 52, 44 },
	steel = { 156, 162, 170 },
	steelDark = { 98, 102, 110 },
	amber = { 201, 150, 70 },
	yellow = { 236, 204, 96 },
	flame = { 240, 132, 48 },
	wood = { 116, 80, 48 },
	woodLight = { 164, 118, 72 },
	rope = { 190, 152, 98 },
	teal = { 96, 150, 148 },
	glass = { 226, 204, 140 },
	stone = { 132, 128, 122 },
} :: { [string]: { number } }

local function rect(x: number, y: number, w: number, h: number, c: string, extra: { [string]: number }?): Shape
	local s: Shape = { k = "rect", x = x, y = y, w = w, h = h, c = c }
	if extra then
		s.r, s.rad, s.a = extra.r, extra.rad, extra.a
	end
	return s
end

local function ring(x: number, y: number, w: number, h: number, t: number, c: string, rad: number, a: number?): Shape
	return { k = "ring", x = x, y = y, w = w, h = h, t = t, c = c, rad = rad, a = a }
end

-- A ">" chevron centred on (cx, cy) or, with `down`, a "v".
local function chevron(cx: number, cy: number, c: string, down: boolean?): { Shape }
	if down then
		return {
			rect(cx - 0.12, cy, 0.32, 0.1, c, { r = 45, rad = 0.5 }),
			rect(cx + 0.12, cy, 0.32, 0.1, c, { r = -45, rad = 0.5 }),
		}
	end
	return {
		rect(cx, cy - 0.12, 0.32, 0.1, c, { r = 45, rad = 0.5 }),
		rect(cx, cy + 0.12, 0.32, 0.1, c, { r = -45, rad = 0.5 }),
	}
end

local function concat(...: { Shape }): { Shape }
	local out = {}
	for _, list in { ... } do
		for _, s in list do
			table.insert(out, s)
		end
	end
	return out
end

local LANTERN_FRAME = {
	ring(0.5, 0.12, 0.22, 0.12, 0.05, "steel", 0.5),
	rect(0.5, 0.26, 0.54, 0.1, "steelDark", { rad = 0.3 }),
	rect(0.5, 0.86, 0.58, 0.1, "steelDark", { rad = 0.3 }),
}

IconDefs.ICONS = {
	-- Consumables (the left column).
	med = { -- first-aid pouch: any dressing, bandage or splint
		ring(0.5, 0.24, 0.3, 0.16, 0.06, "steel", 0.4),
		rect(0.5, 0.58, 0.82, 0.58, "white", { rad = 0.18 }),
		rect(0.5, 0.58, 0.38, 0.13, "red"),
		rect(0.5, 0.58, 0.13, 0.38, "red"),
	},
	cell = { -- replaceable battery cell
		rect(0.5, 0.13, 0.18, 0.1, "steel", { rad = 0.2 }),
		rect(0.5, 0.56, 0.42, 0.76, "steelDark", { rad = 0.16 }),
		rect(0.5, 0.67, 0.42, 0.28, "amber", { rad = 0.1 }),
		rect(0.5, 0.36, 0.18, 0.05, "white"),
		rect(0.5, 0.36, 0.05, 0.18, "white"),
	},
	flare = { -- red stick with a burning tip
		rect(0.42, 0.6, 0.17, 0.62, "red", { r = 40, rad = 0.25 }),
		rect(0.27, 0.78, 0.18, 0.14, "dark", { r = 40, rad = 0.2 }),
		rect(0.69, 0.28, 0.34, 0.34, "flame", { rad = 0.5, a = 0.1 }),
		rect(0.7, 0.27, 0.17, 0.17, "yellow", { rad = 0.5 }),
	},
	chalk = { -- chalk stick above a drawn arrow
		rect(0.5, 0.82, 0.64, 0.07, "bone", { rad = 0.5, a = 0.15 }),
		rect(0.75, 0.77, 0.18, 0.07, "bone", { r = 35, rad = 0.5, a = 0.15 }),
		rect(0.75, 0.87, 0.18, 0.07, "bone", { r = -35, rad = 0.5, a = 0.15 }),
		rect(0.46, 0.4, 0.18, 0.52, "white", { r = 45, rad = 0.2 }),
	},
	sign = { -- wooden arrow sign on a post (C03 silhouette, not a plaque)
		rect(0.42, 0.66, 0.1, 0.62, "wood"),
		rect(0.42, 0.34, 0.5, 0.24, "woodLight", { rad = 0.08 }),
		rect(0.66, 0.34, 0.24, 0.24, "woodLight", { r = 45 }),
		rect(0.42, 0.34, 0.3, 0.05, "dark", { a = 0.35 }),
	},
	rope = { -- coiled rope with a loose end
		ring(0.5, 0.46, 0.66, 0.66, 0.09, "rope", 0.5),
		ring(0.5, 0.46, 0.38, 0.38, 0.09, "rope", 0.5),
		rect(0.74, 0.82, 0.09, 0.3, "rope", { r = -35, rad = 0.5 }),
	},

	-- Actions (the touch action row).
	bar = { -- short iron bar
		rect(0.48, 0.52, 0.13, 0.84, "steel", { r = 45, rad = 0.3 }),
		rect(0.84, 0.27, 0.13, 0.2, "steel", { r = -40, rad = 0.3 }),
	},
	stun = { -- stun device
		rect(0.4, 0.12, 0.06, 0.14, "steel"),
		rect(0.6, 0.12, 0.06, 0.14, "steel"),
		rect(0.5, 0.57, 0.46, 0.7, "steelDark", { rad = 0.14 }),
		rect(0.46, 0.47, 0.1, 0.26, "yellow", { r = 25 }),
		rect(0.5, 0.57, 0.2, 0.07, "yellow"),
		rect(0.54, 0.67, 0.1, 0.26, "yellow", { r = 25 }),
	},
	stone = { -- thrown stone
		rect(0.56, 0.58, 0.6, 0.46, "stone", { r = -12, rad = 0.5 }),
		rect(0.5, 0.5, 0.2, 0.1, "bone", { r = -12, rad = 0.5, a = 0.55 }),
		rect(0.15, 0.44, 0.16, 0.05, "bone", { rad = 0.5, a = 0.4 }),
		rect(0.13, 0.58, 0.2, 0.05, "bone", { rad = 0.5, a = 0.4 }),
		rect(0.16, 0.72, 0.14, 0.05, "bone", { rad = 0.5, a = 0.4 }),
	},
	lantern = concat(LANTERN_FRAME, { -- shielded lantern, shutters open
		rect(0.5, 0.56, 0.42, 0.48, "glass", { rad = 0.1, a = 0.15 }),
		rect(0.5, 0.58, 0.12, 0.22, "flame", { rad = 0.5 }),
		rect(0.28, 0.56, 0.05, 0.5, "steelDark"),
		rect(0.72, 0.56, 0.05, 0.5, "steelDark"),
	}),
	lantern_shut = concat(LANTERN_FRAME, { -- shutters closed: a thin slit of light
		rect(0.5, 0.56, 0.48, 0.5, "steelDark", { rad = 0.1 }),
		rect(0.5, 0.45, 0.48, 0.03, "dark"),
		rect(0.5, 0.67, 0.48, 0.03, "dark"),
		rect(0.5, 0.56, 0.4, 0.04, "flame", { a = 0.2 }),
	}),
	help = { -- a person and a plus: stabilize or carry a teammate
		rect(0.4, 0.26, 0.2, 0.2, "bone", { rad = 0.5 }),
		rect(0.4, 0.62, 0.36, 0.42, "bone", { rad = 0.35 }),
		rect(0.76, 0.32, 0.3, 0.1, "teal"),
		rect(0.76, 0.32, 0.1, 0.3, "teal"),
	},
	ping = { -- verified party ping
		ring(0.5, 0.5, 0.68, 0.68, 0.06, "teal", 0.5, 0.45),
		ring(0.5, 0.5, 0.4, 0.4, 0.07, "teal", 0.5, 0.15),
		rect(0.5, 0.5, 0.16, 0.16, "teal", { rad = 0.5 }),
	},
	menu = {
		rect(0.5, 0.3, 0.6, 0.1, "bone", { rad = 0.5 }),
		rect(0.5, 0.5, 0.6, 0.1, "bone", { rad = 0.5 }),
		rect(0.5, 0.7, 0.6, 0.1, "bone", { rad = 0.5 }),
	},
	sprint = concat(chevron(0.4, 0.5, "bone"), chevron(0.64, 0.5, "bone")),

	-- The very small Crouch and Light buttons. Each state has its own shape, not only its own colour.
	crouch = concat(chevron(0.5, 0.4, "bone", true), { rect(0.5, 0.78, 0.62, 0.09, "bone", { rad = 0.5 }) }),
	crouch_on = concat(chevron(0.5, 0.56, "dark", true), { rect(0.5, 0.8, 0.62, 0.09, "dark", { rad = 0.5 }) }),
	light = { -- bulb with rays: light on
		rect(0.5, 0.44, 0.42, 0.42, "yellow", { rad = 0.5 }),
		rect(0.5, 0.74, 0.2, 0.16, "steel", { rad = 0.2 }),
		rect(0.5, 0.1, 0.06, 0.12, "yellow", { rad = 0.5 }),
		rect(0.2, 0.2, 0.06, 0.12, "yellow", { r = -45, rad = 0.5 }),
		rect(0.8, 0.2, 0.06, 0.12, "yellow", { r = 45, rad = 0.5 }),
		rect(0.1, 0.46, 0.12, 0.06, "yellow", { rad = 0.5 }),
		rect(0.9, 0.46, 0.12, 0.06, "yellow", { rad = 0.5 }),
	},
	light_off = { -- hollow bulb, no rays: light off
		ring(0.5, 0.44, 0.36, 0.36, 0.06, "dim", 0.5),
		rect(0.5, 0.74, 0.2, 0.16, "dim", { rad = 0.2 }),
	},

	-- HUD readouts.
	heart = {
		rect(0.35, 0.38, 0.42, 0.42, "red", { rad = 0.5 }),
		rect(0.65, 0.38, 0.42, 0.42, "red", { rad = 0.5 }),
		rect(0.5, 0.53, 0.42, 0.42, "red", { r = 45, rad = 0.08 }),
	},
	missing = {
		ring(0.5, 0.5, 0.6, 0.6, 0.06, "dim", 0.1),
	},
} :: { [string]: { Shape } }

-- Icon for an inventory item id (medical items share the pouch).
local ITEM_ICONS: { [string]: string } = {
	["med.cloth_dressing"] = "med",
	["med.bandage"] = "med",
	["med.splint"] = "med",
	["power.cell"] = "cell",
	["tool.flare"] = "flare",
	["nav.chalk"] = "chalk",
	["nav.sign"] = "sign",
	["nav.rope"] = "rope",
	["tool.iron_bar"] = "bar",
	["tool.stun_device"] = "stun",
	["light.shielded_lantern"] = "lantern",
}

function IconDefs.forItem(itemId: string): string?
	return ITEM_ICONS[itemId]
end

-- The four corners of a shape (after rotation), in icon fractions. A ring's corners include its outline.
function IconDefs.corners(s: Shape): { { number } }
	local grow = if s.k == "ring" then (s.t or 0) else 0
	local hw, hh = s.w / 2 + grow, s.h / 2 + grow
	local a = math.rad(s.r or 0)
	local cos, sin = math.cos(a), math.sin(a)
	local out = {}
	for _, p in { { -hw, -hh }, { hw, -hh }, { hw, hh }, { -hw, hh } } do
		-- clockwise on screen (y grows downward)
		table.insert(out, { s.x + p[1] * cos - p[2] * sin, s.y + p[1] * sin + p[2] * cos })
	end
	return out
end

return IconDefs
