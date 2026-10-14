--!strict
-- Remote names and helpers. The server creates the remotes; clients wait for them.
-- Clients only ever send REQUESTS. The server validates range, target state, permissions, inventory,
-- cooldown and region before changing anything (section 19).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Net = {}

Net.Names = {
	Request = "Request", -- client -> server: (action: string, payload: table)
	State = "State", -- server -> client: (channel: string, data: table)
}

local folder: Folder? = nil

local function getFolder(): Folder
	local existing = folder
	if existing then
		return existing
	end
	local result: Folder
	if RunService:IsServer() then
		local f = ReplicatedStorage:FindFirstChild("Remotes") :: Folder?
		if f then
			result = f
		else
			local nf = Instance.new("Folder")
			nf.Name = "Remotes"
			nf.Parent = ReplicatedStorage
			result = nf
		end
	else
		result = ReplicatedStorage:WaitForChild("Remotes") :: Folder
	end
	folder = result
	return result
end

function Net.event(name: string): RemoteEvent
	local f = getFolder()
	local e = f:FindFirstChild(name) :: RemoteEvent?
	if e then
		return e
	end
	if RunService:IsServer() then
		local ne = Instance.new("RemoteEvent")
		ne.Name = name
		ne.Parent = f
		return ne
	end
	return f:WaitForChild(name) :: RemoteEvent
end

return Net
