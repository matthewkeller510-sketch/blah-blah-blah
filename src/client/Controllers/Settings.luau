--!strict
-- Accessibility and comfort settings (section 17). Stored per device for Milestone 1 (not in the profile).

local Settings = {
	values = {
		reduceFlashes = false,
		reduceCameraMotion = true,
		subtitles = true,
		textScale = 1,
		sensitivity = 1,
		fieldOfView = 75,
		sprintToggle = false, -- hold vs toggle alternative
		crosshair = true,
		lowLightBoost = 0, -- 0..1 extra close-range legibility; calibration never removes tension entirely
		showPressureDebug = false,
	},
	listeners = {} :: { (string, any) -> () },
}

function Settings.init(_ctx) end

function Settings.get(k: string): any
	return Settings.values[k]
end

function Settings.set(k: string, v: any)
	Settings.values[k] = v
	for _, f in Settings.listeners do
		f(k, v)
	end
end

function Settings.onChanged(f: (string, any) -> ())
	table.insert(Settings.listeners, f)
end

return Settings
