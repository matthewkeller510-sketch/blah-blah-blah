--!strict
-- Persistent profiles (section 20). Uses DataStore UpdateAsync with a session lock so two concurrent sessions
-- cannot overwrite each other (T20). Retries with exponential backoff. Save status is reported to the player and
-- a success is only shown after the durable write returns.
-- UNTESTED IN STUDIO as of this commit: requires a published place with API access enabled.

local DataStoreService = game:GetService("DataStoreService")
local RunService = game:GetService("RunService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Data.Config)
local Profile = require(Shared.Logic.Profile)
local WorldDefs = require(Shared.Data.WorldDefs)

local STORE_NAME = "CatacombsProfiles_v1"
local SaveService = {}

type Entry = {
	profile: Profile.Profile,
	loaded: boolean,
	dirty: boolean,
	saving: boolean,
	lastStatus: string,
	released: boolean,
}

local entries: { [Player]: Entry } = {}
local store: DataStore? = nil
local available = true
local services: any

local function lockId(): string
	return game.JobId ~= "" and game.JobId or ("studio-" .. tostring(os.clock()))
end
local LOCK = lockId()

local function withRetry<T>(fn: () -> T): (boolean, T | string)
	local delay = Config.Save.retryBaseSeconds
	local lastErr: any = nil
	for _ = 1, Config.Save.maxRetries do
		local ok, res = pcall(fn)
		if ok then
			return true, res
		end
		lastErr = res
		task.wait(delay)
		delay *= 2
	end
	return false, tostring(lastErr)
end

local function setStatus(player: Player, status: string, detail: string?)
	local e = entries[player]
	if e then
		e.lastStatus = status
	end
	if services and services.PlayerService then
		services.PlayerService.pushSaveStatus(player, status, detail)
	end
end

function SaveService.init(s)
	services = s
	local ok, res = pcall(function()
		return DataStoreService:GetDataStore(STORE_NAME)
	end)
	if ok then
		store = res
	else
		available = false
		warn("[SaveService] DataStore unavailable; progress will NOT persist this session:", res)
	end
end

function SaveService.isAvailable(): boolean
	return available
end

-- Loads and session-locks a profile. Returns (profile?, err?). A live lock held by another server makes the
-- load wait and retry; a stale lock (older than sessionLockStaleSeconds) is taken over.
function SaveService.load(player: Player): (Profile.Profile?, string?)
	local key = "u_" .. player.UserId
	local result: any = nil
	local err: string? = nil
	if available and store then
		for attempt = 1, 6 do
			local blocked = false
			local ok, res = withRetry(function()
				return (store :: DataStore):UpdateAsync(key, function(old)
					blocked = false -- UpdateAsync may call the transform more than once
					old = old or { data = nil, lock = nil }
					local lock = old.lock
					if lock and lock.id ~= LOCK and (os.time() - (lock.time or 0)) < Config.Save.sessionLockStaleSeconds then
						blocked = true
						return nil -- abort write, keep the other session's data
					end
					old.lock = { id = LOCK, time = os.time() }
					return old
				end)
			end)
			if not ok then
				err = "load_failed"
				break
			end
			if not blocked then
				result = res and res.data
				err = nil
				break
			end
			err = "session_locked"
			task.wait(attempt * 2)
		end
	else
		err = nil -- offline mode: fresh in-memory profile, clearly flagged
	end
	if err then
		return nil, err
	end
	local prof, perr = Profile.reconcile(result, player.UserId, Config.DefaultClass, WorldDefs.DepotPseudoShelterId)
	if not prof then
		return nil, perr
	end
	entries[player] = { profile = prof, loaded = true, dirty = false, saving = false, lastStatus = "loaded", released = false }
	setStatus(player, if available then "loaded" else "offline", if available then nil else "Saving unavailable in this session")
	return prof, nil
end

function SaveService.get(player: Player): Profile.Profile?
	local e = entries[player]
	return e and e.profile
end

function SaveService.markDirty(player: Player)
	local e = entries[player]
	if e then
		e.dirty = true
	end
end

-- Durable commit. Returns true only after the DataStore write succeeds (section 20: do not acknowledge a
-- purchase or show a successful bank/save before the durable operation succeeds).
function SaveService.commit(player: Player, release: boolean?): boolean
	local e = entries[player]
	if not e then
		return false
	end
	if not available or not store then
		setStatus(player, "offline", "Saving unavailable in this session")
		return false
	end
	while e.saving do
		task.wait(0.1)
	end
	-- A commit queued behind release() must not write (it would re-lock a departed player's profile).
	if e.released or entries[player] ~= e then
		return false
	end
	if release then
		e.released = true
	end
	e.saving = true
	setStatus(player, "saving")
	local lostLock = false
	local ok = withRetry(function()
		return (store :: DataStore):UpdateAsync("u_" .. player.UserId, function(old)
			old = old or {}
			if old.lock and old.lock.id ~= LOCK then
				lostLock = true
				return nil
			end
			old.data = e.profile
			old.lock = if release then nil else { id = LOCK, time = os.time() }
			return old
		end)
	end)
	e.saving = false
	if ok and not lostLock then
		e.dirty = false
		setStatus(player, "saved")
		return true
	end
	setStatus(player, "failed", if lostLock then "Another session owns this profile" else "Save failed; will retry")
	return false
end

function SaveService.release(player: Player)
	SaveService.commit(player, true)
	entries[player] = nil
end

-- True while a profile entry exists (used to wait for in-flight departures on shutdown).
function SaveService.hasPending(): boolean
	return next(entries) ~= nil
end

function SaveService.start()
	task.spawn(function()
		while true do
			task.wait(Config.Save.autosaveSeconds)
			for player, e in entries do
				-- Commit even when clean so the session lock's timestamp never looks stale to other servers.
				if player.Parent and not e.released then
					task.spawn(SaveService.commit, player)
				end
			end
		end
	end)
	game:BindToClose(function()
		-- PlayerService handles logout bags on PlayerRemoving; this flushes anything left.
		if RunService:IsStudio() and not available then
			return
		end
		for player in entries do
			task.spawn(function()
				if services.PlayerService then
					services.PlayerService.handleDeparture(player)
				end
			end)
		end
		-- Wait on the real state: departures already started by PlayerRemoving are still in flight.
		local t = os.clock()
		while next(entries) ~= nil and os.clock() - t < 25 do
			task.wait(0.2)
		end
	end)
end

return SaveService
