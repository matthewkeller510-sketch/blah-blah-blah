--!strict
-- Story characters N01-N06 (section 05): greybox figures, subtitled dialogue and journal lines.
-- SCAFFOLD: the story, missions and NPCs package implements this service. The API names below are the contract.

local NpcService = {}
local _services: any

function NpcService.init(s)
	_services = s
end

function NpcService.start() end

-- Show a subtitled line from a character to one player and copy it to their journal.
function NpcService.say(_player: Player, _npcId: string, _lineId: string) end

return NpcService
