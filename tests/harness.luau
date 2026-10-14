--!strict
-- Shared test harness. Specs receive this table: T.test(name, fn), T.eq(a, b, msg?), T.near(a, b, eps, msg?).

local T = { passed = 0, failed = 0 }

function T.test(name: string, fn: () -> ())
	local ok, err = pcall(fn)
	if ok then
		T.passed += 1
		print("  ok   " .. name)
	else
		T.failed += 1
		print("  FAIL " .. name .. "\n       " .. tostring(err))
	end
end

function T.eq(a: any, b: any, msg: string?)
	if a ~= b then
		error(string.format("%s: expected %s, got %s", msg or "eq", tostring(b), tostring(a)), 2)
	end
end

function T.near(a: number, b: number, eps: number, msg: string?)
	if math.abs(a - b) > eps then
		error(string.format("%s: expected ~%s, got %s", msg or "near", tostring(b), tostring(a)), 2)
	end
end

return T
