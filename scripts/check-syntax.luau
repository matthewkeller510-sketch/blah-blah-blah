-- Compiles every .luau file under src/ to catch syntax errors outside Studio. Run: lune run scripts/check-syntax
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")

local failures = 0
local count = 0
local function walk(dir: string)
	for _, name in fs.readDir(dir) do
		local path = dir .. "/" .. name
		if fs.isDir(path) then
			walk(path)
		elseif string.sub(name, -5) == ".luau" then
			count += 1
			local ok, err = pcall(luau.compile, fs.readFile(path))
			if not ok then
				failures += 1
				print("SYNTAX " .. path .. ": " .. tostring(err))
			end
		end
	end
end
walk("src")
walk("tests")
print(string.format("%d files compiled, %d failed", count, failures))
if failures > 0 then
	process.exit(1)
end
