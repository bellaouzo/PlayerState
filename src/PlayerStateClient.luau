--!strict

--[[
	PlayerStateClient - Client-side player data access
	
	Documentation: https://playerstate.netlify.app/api/client.html
--]]

-- Services
local RunService = game:GetService("RunService")

-- Validation
local IS_CLIENT = RunService:IsClient()
if not IS_CLIENT then
	error("[PlayerStateClient] This module can only be used on the client")
end

-- Libraries
local DefaultData = require(script.Parent.DefaultData)
local ReplicaClient = require(script.Parent.Replica.ReplicaClient)
local Config = require(script.Parent.PlayerStateConfig)

-- Types
export type PlayerData = typeof(DefaultData)
export type ReplicaInstance = ReplicaClient.Replica
export type ValuePath = string
export type ChangeInfo = {
	action: "Set" | "SetValues" | "TableInsert" | "TableRemove",
	path: {string},
	index: number?,
}

export type LeaderboardInfo = {
	rank: number?,
	score: number?,
	statName: string,
}

export type PlayerStateClient = {
	Get: (key: string) -> any,
	GetPath: (path: ValuePath) -> any,
	GetFromDict: (dictPath: ValuePath, key: string | number) -> any,
	OnChanged: (pathOrKey: string, callback: (newValue: any, oldValue: any, info: ChangeInfo | {string}?) -> ()) -> ReplicaClient.Connection?,
	GetReplica: () -> ReplicaInstance?,
	GetAll: () -> PlayerData?,
	IsReady: () -> boolean,
	ClearCache: () -> (),
	GetLeaderboardInfo: (statName: string) -> LeaderboardInfo?,
}

-- States
local localReplica: ReplicaInstance?
local dataReady: boolean = false

-- Caching (configuration from PlayerStateConfig)
local pathCache: {[string]: {string}} = {}
local valueCache: {[string]: {value: any, timestamp: number}} = {}
local nestedValueCache: {[string]: {value: any, timestamp: number}} = {}
local CACHE_DURATION = Config.Client.CacheDuration
local lastCacheCleanup = 0
local CACHE_CLEANUP_INTERVAL = Config.Client.CacheCleanupInterval

-- Connection management
local activeConnections: {ReplicaClient.Connection} = {}
local connectionCleanupScheduled = false

-- Replica setup
ReplicaClient.OnNew("PlayerData", function(replica)
	localReplica = replica
	dataReady = true

	table.clear(valueCache)
	table.clear(nestedValueCache)

	print("[PlayerState] Client data is ready")
end)
ReplicaClient.RequestData()

-- ========== UTILITIES ==========
local function _GetPathKeys(path: string): {string}
	local cached = pathCache[path]
	if cached then
		return cached
	end

	local keys = string.split(path, ".")
	pathCache[path] = keys

	local cacheSize = 0
	for _ in pathCache do
		cacheSize += 1
	end

	if cacheSize > Config.Client.MaxPathCacheSize then
		local keysToRemove = {}
		local count = 0
		for cachedPath in pathCache do
			table.insert(keysToRemove, cachedPath)
			count += 1
			if count > 100 then
				break
			end
		end

		for _, keyToRemove in keysToRemove do
			pathCache[keyToRemove] = nil
		end
	end

	return keys
end

local function _GetNestedValue(data: any, path: string): any
	local currentTime = tick()
	local cached = nestedValueCache[path]
	if cached and currentTime - cached.timestamp < CACHE_DURATION then
		return cached.value
	end

	local keys = _GetPathKeys(path)
	local current = data

	for _, key in keys do
		if typeof(current) ~= "table" or current[key] == nil then
			nestedValueCache[path] = {value = nil, timestamp = currentTime}
			return nil
		end
		current = current[key]
	end

	nestedValueCache[path] = {value = current, timestamp = currentTime}

	return current
end

local function _CleanupCache(): ()
	local currentTime = tick()

	if currentTime - lastCacheCleanup < CACHE_CLEANUP_INTERVAL then
		return
	end

	lastCacheCleanup = currentTime

	local keysToRemove = {}

	for key, cached in valueCache do
		if currentTime - cached.timestamp > CACHE_DURATION * 10 then
			table.insert(keysToRemove, key)
		end
	end

	for _, key in keysToRemove do
		valueCache[key] = nil
	end

	table.clear(keysToRemove)

	for key, cached in nestedValueCache do
		if currentTime - cached.timestamp > CACHE_DURATION * 10 then
			table.insert(keysToRemove, key)
		end
	end

	for _, key in keysToRemove do
		nestedValueCache[key] = nil
	end
end

local function _ValidateReplica(replica: ReplicaInstance?): boolean
	return replica ~= nil and replica:IsActive()
end

local function _WaitForData(): boolean
	while not (dataReady and _ValidateReplica(localReplica)) do
		task.wait(0.1)
	end

	return true
end

local function _ScheduleConnectionCleanup(): ()
	if connectionCleanupScheduled then
		return
	end

	connectionCleanupScheduled = true
	task.defer(function()
		connectionCleanupScheduled = false

		local validConnections = {}
		for _, connection in activeConnections do
			if typeof(connection) == "table" and connection.Disconnect then
				table.insert(validConnections, connection)
			end
		end

		activeConnections = validConnections
	end)
end

-- ========== CLIENT IMPLEMENTATION ==========
local PlayerState: PlayerStateClient = {} :: PlayerStateClient

function PlayerState.Get(key: string): any
	if not _WaitForData() then
		return nil
	end

	if not _ValidateReplica(localReplica) then
		return nil
	end

	if typeof(key) == "Instance" and key:IsA("Player") then
		warn(`[PlayerState] Player object detected as first parameter in Get(). Client-side Get() only takes a key string.`)
		return nil
	end
	if string.find(key, "%.") then
		warn(`[PlayerState] Detected path syntax in Get() call. Use GetPath() instead for nested paths like "{key}"`)
		return false
	end
	
	local currentTime = tick()
	local cached = valueCache[key]
	if cached and currentTime - cached.timestamp < CACHE_DURATION then
		return cached.value
	end

	local value = (localReplica :: ReplicaInstance).Data[key]

	valueCache[key] = {value = value, timestamp = currentTime}

	_CleanupCache()

	return value
end

function PlayerState.GetPath(path: ValuePath): any	
	if not _WaitForData() then
		return nil
	end

	if not _ValidateReplica(localReplica) then
		return nil
	end

	if typeof(path) == "Instance" and path:IsA("Player") then
		warn(`[PlayerState] Player object detected as first parameter in GetPath(). Client-side GetPath() only takes a path string. Use server-side PlayerState.GetPath(player, path) instead.`)
		return nil
	end

	local replicaData = (localReplica :: ReplicaInstance).Data

	if not string.find(path, ".", 1, true) then
		return replicaData[path]
	end

	local result = _GetNestedValue(replicaData, path)

	_CleanupCache()

	return result
end

function PlayerState.GetFromDict(dictPath: ValuePath, key: string | number): any	
	if not _WaitForData() then
		return nil
	end

	if not _ValidateReplica(localReplica) then
		return nil
	end

	if typeof(dictPath) == "Instance" and dictPath:IsA("Player") then
		warn(`[PlayerState] Player object detected as first parameter in GetFromDict(). Client-side GetFromDict() only takes a dictPath string. Use server-side PlayerState.GetFromDict(player, dictPath, key) instead.`)
		return nil
	end

	local stringKey = if typeof(key) == "number" then tostring(key) else key
	local currentDict = PlayerState.GetPath(dictPath) or {}

	_CleanupCache()

	return currentDict[stringKey]
end

function PlayerState.OnChanged(pathOrKey: string, callback: (newValue: any, oldValue: any, fullPath: {string}?) -> ()): ReplicaClient.Connection?
	local function createConnection(replica: ReplicaInstance): ReplicaClient.Connection?
		if not _ValidateReplica(replica) then
			return nil
		end

		local connection: ReplicaClient.Connection?

		if pathOrKey == "." then
			connection = replica:OnChange(function(action, path, param1, param2)
				table.clear(valueCache)
				table.clear(nestedValueCache)

				if action == "Set" then
					local newValue, oldValue = param1, param2
					callback(newValue, oldValue, {action = action, path = path})
				elseif action == "SetValues" then
					local values = param1
					callback(values, nil, {action = action, path = path})
				elseif action == "TableInsert" then
					local value, index = param1, param2
					callback(value, nil, {action = action, path = path, index = index})
				elseif action == "TableRemove" then
					local removedValue, index = param1, param2
					callback(nil, removedValue, {action = action, path = path, index = index})
				end
			end)
		else
			local pathKeys = _GetPathKeys(pathOrKey)

			connection = replica:OnChange(function(action, path, param1, param2)
				local isExactMatch = #path == #pathKeys
				local isSubPath = #path > #pathKeys
				local pathMatches = false

				if isExactMatch or isSubPath then
					pathMatches = true

					for i = 1, #pathKeys do
						if path[i] ~= pathKeys[i] then
							pathMatches = false
							break
						end
					end
				end

				if pathMatches then
					table.clear(valueCache)
					table.clear(nestedValueCache)

					if action == "Set" then
						if isExactMatch then
							local newValue, oldValue = param1, param2

							callback(newValue, oldValue, pathKeys)
						else
							local currentValue = PlayerState.GetPath(pathOrKey)

							callback(currentValue, nil, {action = action, path = path})
						end
					elseif action == "SetValues" then
						if isExactMatch then
							local values = param1

							callback(values, nil, {action = action, path = path})
						else
							local currentValue = PlayerState.GetPath(pathOrKey)

							callback(currentValue, nil, {action = action, path = path})
						end
					elseif action == "TableInsert" then
						local value, index = param1, param2

						callback(value, nil, {action = action, path = path, index = index})
					elseif action == "TableRemove" then
						local removedValue, index = param1, param2

						callback(nil, removedValue, {action = action, path = path, index = index})
					end
				end
			end)
		end

		if connection then
			table.insert(activeConnections, connection)
			_ScheduleConnectionCleanup()
		end

		return connection
	end

	if localReplica then
		return createConnection(localReplica)
	else
		local connection: ReplicaClient.Connection?

		local newReplicaConnection = ReplicaClient.OnNew("PlayerData", function(replica)
			connection = createConnection(replica)
		end)

		table.insert(activeConnections, newReplicaConnection)
		_ScheduleConnectionCleanup()

		return connection
	end
end

function PlayerState.GetReplica(): ReplicaInstance?
	if not _ValidateReplica(localReplica) then
		return nil
	end

	return localReplica
end

function PlayerState.GetAll(): PlayerData?
	if not _WaitForData() then
		return nil
	end

	if not _ValidateReplica(localReplica) then
		return nil
	end

	return (localReplica :: ReplicaInstance).Data
end

function PlayerState.IsReady(): boolean
	return dataReady and _ValidateReplica(localReplica)
end

function PlayerState.ClearCache(): ()
	table.clear(pathCache)
	table.clear(valueCache)
	table.clear(nestedValueCache)
end

function PlayerState.GetLeaderboardInfo(statName: string): LeaderboardInfo?
	if not _WaitForData() then
		return nil
	end

	if not _ValidateReplica(localReplica) then
		return nil
	end

	local replica = localReplica :: ReplicaInstance
	local leaderboardRanks = replica.Data._LeaderboardRanks

	if not leaderboardRanks then
		return nil
	end

	local statData = leaderboardRanks[statName]

	if not statData then
		return nil
	end

	return {
		rank = statData.rank,
		score = statData.score,
		statName = statName,
	}
end

return PlayerState 