--!strict
-- Temporary session parties (section 14; owner rules F12, F13, F15). Party IDs live only on this server and are
-- never used as persistent ownership. Invite/accept/decline/leave/remove are explicit. Invitations arrive as a
-- small non-blocking notice, never a modal over gameplay.

local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Data.Config)
local Shelters = require(Shared.Logic.Shelters)

local PartyService = {}
local services: any

type Party = { id: string, leader: Player, members: { Player } }

local parties: { [string]: Party } = {}
local partyOf: { [Player]: string } = {}
local invites: { [Player]: { [number]: number } } = {} -- invitee -> inviterUserId -> expiry

local INVITE_SECONDS = 60

function PartyService.partyIdOf(player: Player): string?
	return partyOf[player]
end

function PartyService.memberIds(player: Player): { number }?
	local pid = partyOf[player]
	local p = pid and parties[pid]
	if not p then
		return nil
	end
	local ids = {}
	for _, m in p.members do
		table.insert(ids, m.UserId)
	end
	return ids
end

function PartyService.memberIdsByParty(pid: string): { number }?
	local p = parties[pid]
	if not p then
		return nil
	end
	local ids = {}
	for _, m in p.members do
		table.insert(ids, m.UserId)
	end
	return ids
end

function PartyService.members(player: Player): { Player }
	local pid = partyOf[player]
	local p = pid and parties[pid]
	return if p then table.clone(p.members) else { player }
end

function PartyService.sameParty(a: Player, b: Player): boolean
	return partyOf[a] ~= nil and partyOf[a] == partyOf[b]
end

local function pushParty(p: Party?)
	if not p then
		return
	end
	local list = {}
	for _, m in p.members do
		local s = services.PlayerService.get(m)
		table.insert(list, {
			userId = m.UserId,
			name = m.DisplayName,
			leader = m == p.leader,
			condition = s and s.vitals.condition or "?",
			healthFraction = s and (s.vitals.health / s.vitals.max) or 0,
			stabilized = s and s.vitals.stabilized or false,
		})
	end
	for _, m in p.members do
		services.PlayerService.send(m, "party", { members = list, isLeader = m == p.leader })
	end
end

local function afterChange(touched: { Player })
	services.NavigationService.refreshAll()
	services.RecoveryService.pushAll()
	services.ShelterService.onPartyChanged()
	-- Carrying requires current party membership; detach safely if broken (section 07).
	for _, pl in touched do
		local s = services.PlayerService.get(pl)
		if s and s.carrying and s.carrying.kind == "player" and not PartyService.sameParty(pl, s.carrying.target) then
			services.PlayerService.dropCarry(pl)
		end
		if s and s.carriedBy and not PartyService.sameParty(pl, s.carriedBy) then
			services.PlayerService.dropCarry(s.carriedBy)
		end
		if not partyOf[pl] then
			services.PlayerService.send(pl, "party", { members = {}, isLeader = false })
		end
	end
end

-- Union/max of permanent upgrades across members, persisted to each (F13). Idempotent on repeated joins.
function PartyService.propagateUpgrades(player: Player)
	local members = PartyService.members(player)
	local maps = {}
	for _, m in members do
		local s = services.PlayerService.get(m)
		if s then
			table.insert(maps, s.profile.shelterUpgrades)
		end
	end
	local shared = Shelters.union(maps)
	for _, m in members do
		local s = services.PlayerService.get(m)
		if s and Shelters.inherit(s.profile.shelterUpgrades, shared) > 0 then
			services.SaveService.markDirty(m)
			services.PlayerService.notify(m, "You inherited your party's shelter improvements permanently.", "info")
		end
	end
end

function PartyService.invite(from: Player, toUserId: number)
	local to = Players:GetPlayerByUserId(toUserId)
	if not to or to == from then
		return
	end
	if PartyService.sameParty(from, to) then
		return
	end
	local pid = partyOf[from]
	if pid and #parties[pid].members >= Config.Server.maxPartySize then
		services.PlayerService.notify(from, "Your party is full.", "warn")
		return
	end
	invites[to] = invites[to] or {}
	invites[to][from.UserId] = os.clock() + INVITE_SECONDS
	services.PlayerService.send(
		to,
		"partyInvite",
		{ fromUserId = from.UserId, fromName = from.DisplayName, seconds = INVITE_SECONDS }
	)
	services.PlayerService.notify(from, "Invitation sent to " .. to.DisplayName .. ".", "info")
end

function PartyService.decline(player: Player, fromUserId: number)
	if invites[player] then
		invites[player][fromUserId] = nil
	end
	local from = Players:GetPlayerByUserId(fromUserId)
	if from then
		services.PlayerService.notify(from, player.DisplayName .. " declined.", "info")
	end
end

local function removeFrom(player: Player)
	local pid = partyOf[player]
	if not pid then
		return
	end
	local p = parties[pid]
	partyOf[player] = nil
	local i = table.find(p.members, player)
	if i then
		table.remove(p.members, i)
	end
	if #p.members <= 1 then
		for _, m in p.members do
			partyOf[m] = nil
			services.PlayerService.notify(m, "Your party has dissolved.", "info")
		end
		parties[pid] = nil
		afterChange({ player, table.unpack(p.members) })
		return
	end
	if p.leader == player then
		p.leader = p.members[1]
	end
	pushParty(p)
	afterChange({ player, table.unpack(p.members) })
end

function PartyService.accept(player: Player, fromUserId: number)
	local exp = invites[player] and invites[player][fromUserId]
	if not exp or exp < os.clock() then
		services.PlayerService.notify(player, "That invitation has expired.", "warn")
		return
	end
	invites[player][fromUserId] = nil
	local from = Players:GetPlayerByUserId(fromUserId)
	if not from then
		return
	end
	if partyOf[player] then
		removeFrom(player)
	end
	local pid = partyOf[from]
	local p: Party
	if pid then
		p = parties[pid]
		if #p.members >= Config.Server.maxPartySize then
			services.PlayerService.notify(player, "That party is full.", "warn")
			return
		end
	else
		local newId = HttpService:GenerateGUID(false)
		pid = newId
		p = { id = newId, leader = from, members = { from } }
		parties[newId] = p
		partyOf[from] = newId
	end
	table.insert(p.members, player)
	partyOf[player] = pid
	PartyService.propagateUpgrades(player)
	pushParty(p)
	afterChange(p.members)
end

function PartyService.leave(player: Player)
	removeFrom(player)
end

function PartyService.remove(leader: Player, userId: number)
	local pid = partyOf[leader]
	local p = pid and parties[pid]
	if not p or p.leader ~= leader then
		return
	end
	local target = Players:GetPlayerByUserId(userId)
	if target and partyOf[target] == pid then
		services.PlayerService.notify(target, "You were removed from the party.", "info")
		removeFrom(target)
	end
end

-- Verified party ping: system-authored, so mimics cannot forge it (section 10, C10 counterplay).
function PartyService.ping(player: Player)
	local pos = services.PlayerService.position(player)
	if not pos then
		return
	end
	for _, m in PartyService.members(player) do
		services.PlayerService.send(m, "ping", { userId = player.UserId, name = player.DisplayName, position = pos })
	end
end

function PartyService.onPlayerLeft(player: Player)
	invites[player] = nil
	removeFrom(player)
end

function PartyService.init(s)
	services = s
end

function PartyService.start()
	task.spawn(function()
		while true do
			task.wait(1)
			for _, p in parties do
				pushParty(p)
			end
		end
	end)
	-- Roster for the invite list (names only; no stranger interaction beyond invites).
	task.spawn(function()
		while true do
			task.wait(3)
			local roster = {}
			for _, pl in Players:GetPlayers() do
				table.insert(roster, { userId = pl.UserId, name = pl.DisplayName })
			end
			for _, pl in Players:GetPlayers() do
				services.PlayerService.send(pl, "roster", roster)
			end
		end
	end)
end

return PartyService
