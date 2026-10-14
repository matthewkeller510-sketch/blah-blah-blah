--!strict
-- Unit tests for the Roblox-independent logic modules. Run from the repository root with: lune run tests/run
-- Every file in tests/specs is a spec module returning function(T) (see tests/harness.luau). Specs run in file-name
-- order. These tests exercise pure rules only. They do NOT prove the Roblox services, replication, DataStores,
-- streaming or device performance work; those require Studio and published-test-place evidence (section 23).

local fs = require("@lune/fs")
local T = require("./harness")

local names = {}
for _, name in fs.readDir("tests/specs") do
	if string.sub(name, -5) == ".luau" then
		table.insert(names, string.sub(name, 1, -6))
	end
end
table.sort(names)

for _, name in names do
	print("\n== " .. name)
	local spec = (require :: any)("./specs/" .. name)
	spec(T)
end

print(string.format("\n%d passed, %d failed", T.passed, T.failed))
if T.failed > 0 then
	error("tests failed")
end
