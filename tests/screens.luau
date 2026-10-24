--!strict
-- Screens the layout specs check (shared by tests/specs/fix_client.luau and tests/specs/hud_layout.luau). Each has
-- the safe-area gui size the ExpeditionUI gets (CoreUISafeInsets: top bar 36 or 58 px, iOS home indicator 21 px,
-- notch sides 47 px) and the full viewport the default touch controls may use.

export type Screen = { name: string, w: number, h: number, vw: number, vh: number }

local Screens = {}

Screens.PHONES_390 = {
	{ name = "iPhone 14, new top bar, home bar, notch", w = 750, h = 390 - 58 - 21, vw = 844, vh = 390 },
	{ name = "iPhone 14, old top bar, home bar, notch", w = 750, h = 390 - 36 - 21, vw = 844, vh = 390 },
	{ name = "390 tall, new top bar only", w = 844, h = 390 - 58, vw = 844, vh = 390 },
	{ name = "390 tall, old top bar only", w = 844, h = 390 - 36, vw = 844, vh = 390 },
} :: { Screen }

Screens.OTHER_PHONES = {
	{ name = "iPhone SE 667 x 375", w = 667, h = 375 - 58, vw = 667, vh = 375 },
	{ name = "Android 800 x 360", w = 800, h = 360 - 58, vw = 800, vh = 360 },
	{ name = "Pro Max 932 x 430", w = 932 - 2 * 59, h = 430 - 58 - 21, vw = 932, vh = 430 },
	{ name = "small 568 x 320", w = 568, h = 320 - 58, vw = 568, vh = 320 },
} :: { Screen }

Screens.TABLETS = {
	{ name = "iPad 1024 x 768", w = 1024, h = 768 - 58 - 20, vw = 1024, vh = 768 },
	{ name = "iPad Air 1180 x 820", w = 1180, h = 820 - 58 - 20, vw = 1180, vh = 820 },
	{ name = "iPad Pro 1366 x 1024", w = 1366, h = 1024 - 58 - 20, vw = 1366, vh = 1024 },
} :: { Screen }

Screens.DESKTOPS = {
	{ name = "1080p", w = 1920, h = 1080 - 58, vw = 1920, vh = 1080 },
	{ name = "1366 x 768", w = 1366, h = 768 - 58, vw = 1366, vh = 768 },
} :: { Screen }

function Screens.all(...: { Screen }): { Screen }
	local out = {}
	for _, list in { ... } do
		for _, s in list do
			table.insert(out, s)
		end
	end
	return out
end

return Screens
