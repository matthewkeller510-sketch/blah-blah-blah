--!strict
-- Variable pockets (section 04, owner rule F08; docs/MILESTONE-3.md section 3).
-- SCAFFOLD: the world-and-pockets package implements this service. The API names below are the contract.

local PocketService = {}
local _services: any

function PocketService.init(s)
	_services = s
end

function PocketService.start() end

-- Current version id of a pocket on this server (e.g. "direct").
function PocketService.versionOf(_pocketId: string): string?
	return nil
end

-- The pocket whose bounds contain a world position, or nil.
function PocketService.pocketAt(_position: Vector3): string?
	return nil
end

-- Subscribe to version changes: fn(pocketId, oldVersion, newVersion).
function PocketService.onChanged(_fn: (string, string, string) -> ()) end

return PocketService
