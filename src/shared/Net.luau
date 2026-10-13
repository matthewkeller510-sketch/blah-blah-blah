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

local folder: Folder

local function getFolder(): Folder
	if folder then
		return folder
	end
	if RunService:IsServer() then
		local f = ReplicatedStorage:FindFirstChild("Remotes") :: Folder?
		if not f then
			local nf = Instance.new("Folder")
			nf.Name = "Remotes"
			nf.Parent = ReplicatedStorage
			f = nf
		end
		folder = f :: Folder
	else
		folder = ReplicatedStorage:WaitForChild("Remotes") :: Folder
	end
	return folder
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
