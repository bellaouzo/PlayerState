--!strict

--[[
	PlayerStateClient - Client-side player data access
	
	Documentation: https://playerstate.netlify.app/api/client.html
--]]

local RunService = game:GetService("RunService")

local dataReadyEvent = Instance.new("BindableEvent")

local IS_CLIENT = RunService:IsClient()
if not IS_CLIENT then
	error("[PlayerStateClient] This module can only be used on the client")
end

local DefaultData = require(script.Parent.DefaultData)
local ReplicaClient = require(script.Parent.Replica.ReplicaClient)
local Config = require(script.Parent.PlayerStateConfig)

local Utils = require(script.Parent.Internal.Shared.Utils)
local CreatePathCache = require(script.Parent.Internal.Client.PathCache)
local CreateCacheModule = require(script.Parent.Internal.Client.Cache)
local Validation = require(script.Parent.Internal.Client.Validation)
local Leaderboard = require(script.Parent.Internal.Client.Leaderboard)
local CreateConnectionModule = require(script.Parent.Internal.Client.Connection)
local OfflineDataRemote = require(script.Parent.Internal.Shared.Remotes.GetOfflineDataRemote)

export type PlayerData = typeof(DefaultData)
export type ReplicaInstance = ReplicaClient.Replica
export type ValuePath = string
export type LeaderboardInfo = {
	rank: number?,
	score: number?,
	statName: string,
}
export type LeaderboardEntry = {
	userId: number,
	score: number,
	rank: number,
}
export type ChangeInfo = {
	action: "Set" | "SetValues" | "TableInsert" | "TableRemove",
	path: {string},
	index: number?,
}

export type PlayerStateClient = {
	Get: (key: string) -> any,
	GetPath: (path: ValuePath) -> any,
	GetFromDict: (dictPath: ValuePath, key: string | number) -> any,
	Clone: (value: any, deep: boolean?) -> any,
	OnChanged: (pathOrKey: string, callback: (newValue: any, oldValue: any, info: ChangeInfo | {string}?) -> ()) -> ReplicaClient.Connection?,
	GetReplica: () -> ReplicaInstance?,
	GetAll: () -> PlayerData?,
	GetOfflineData: (userId: number) -> PlayerData?,
	IsReady: () -> boolean,
	ClearCache: () -> (),
	GetLeaderboardInfo: (statName: string) -> LeaderboardInfo?,
	GetLeaderboard: (statName: string, limit: number?) -> {LeaderboardEntry},
}

local localReplica: ReplicaInstance?
local dataReady: boolean = false

local PathCacheModule = CreatePathCache(Config.Client.MaxPathCacheSize)
local CacheModule = CreateCacheModule(Config.Client.CacheDuration, Config.Client.CacheCleanupInterval)
local ConnectionModule = CreateConnectionModule()
local AUTO_CLONE_TABLES = Config.Client.AutoCloneTables

ReplicaClient.OnNew("PlayerData", function(replica)
	localReplica = replica
	dataReady = true

	CacheModule.ClearAllCaches()

	dataReadyEvent:Fire()

	print("[PlayerState] Client data is ready")
end)
ReplicaClient.RequestData()

local function GetNestedValue(data: any, path: string): any
	local cached = CacheModule.GetFromNestedCache(path)
	if cached ~= nil then
		return cached
	end

	local keys = PathCacheModule.GetPathKeys(path)
	local current = data

	for _, key in keys do
		if typeof(current) ~= "table" or current[key] == nil then
			CacheModule.SetInNestedCache(path, nil)
			return nil
		end
		current = current[key]
	end

	CacheModule.SetInNestedCache(path, current)

	return current
end

local function WaitForData(): boolean
	return Validation.WaitForData(
		function()
			return dataReady
		end,
		Validation.ValidateReplica,
		function()
			return localReplica
		end,
		dataReadyEvent
	)
end

local PlayerState: PlayerStateClient = {} :: PlayerStateClient

function PlayerState.Get(key: string): any
	if not WaitForData() then
		return nil
	end

	if not Validation.ValidateReplica(localReplica) then
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

	local cachedValue = CacheModule.GetFromValueCache(key)
	if cachedValue ~= nil then
		if AUTO_CLONE_TABLES and typeof(cachedValue) == "table" then
			return Utils.DeepClone(cachedValue)
		end
		return cachedValue
	end

	local value = (localReplica :: ReplicaInstance).Data[key]

	if AUTO_CLONE_TABLES and typeof(value) == "table" then
		value = Utils.DeepClone(value)
	end

	CacheModule.SetInValueCache(key, value)

	CacheModule.CleanupCache()

	return value
end

function PlayerState.Clone(value: any, deep: boolean?): any
	if typeof(value) ~= "table" then
		return value
	end

	if deep then
		return Utils.DeepClone(value)
	end

	return table.clone(value)
end

function PlayerState.GetPath(path: ValuePath): any	
	if not WaitForData() then
		return nil
	end

	if not Validation.ValidateReplica(localReplica) then
		return nil
	end

	if typeof(path) == "Instance" and path:IsA("Player") then
		warn(`[PlayerState] Player object detected as first parameter in GetPath(). Client-side GetPath() only takes a path string. Use server-side PlayerState.GetPath(player, path) instead.`)
		return nil
	end

	local replicaData = (localReplica :: ReplicaInstance).Data

	local result
	if not string.find(path, ".", 1, true) then
		result = replicaData[path]
	else
		result = GetNestedValue(replicaData, path)
	end

	CacheModule.CleanupCache()

	if AUTO_CLONE_TABLES and typeof(result) == "table" then
		return Utils.DeepClone(result)
	end

	return result
end

function PlayerState.GetFromDict(dictPath: ValuePath, key: string | number): any	
	if not WaitForData() then
		return nil
	end

	if not Validation.ValidateReplica(localReplica) then
		return nil
	end

	if typeof(dictPath) == "Instance" and dictPath:IsA("Player") then
		warn(`[PlayerState] Player object detected as first parameter in GetFromDict(). Client-side GetFromDict() only takes a dictPath string. Use server-side PlayerState.GetFromDict(player, dictPath, key) instead.`)
		return nil
	end

	local stringKey = if typeof(key) == "number" then tostring(key) else key

	local replicaData = (localReplica :: ReplicaInstance).Data
	local dictKeys = PathCacheModule.GetPathKeys(dictPath)
	local current: any = replicaData

	for _, segment in dictKeys do
		if typeof(current) ~= "table" then
			CacheModule.CleanupCache()
			return nil
		end
		current = current[segment]
		if current == nil then
			CacheModule.CleanupCache()
			return nil
		end
	end

	if typeof(current) ~= "table" then
		CacheModule.CleanupCache()
		return nil
	end

	local result = current[stringKey]

	CacheModule.CleanupCache()

	if AUTO_CLONE_TABLES and typeof(result) == "table" then
		return Utils.DeepClone(result)
	end

	return result
end

function PlayerState.OnChanged(pathOrKey: string, callback: (newValue: any, oldValue: any, fullPath: {string}?) -> ()): ReplicaClient.Connection?
	local function createConnection(replica: ReplicaInstance): ReplicaClient.Connection?
		if not Validation.ValidateReplica(replica) then
			return nil
		end

		local connection: ReplicaClient.Connection?

		if pathOrKey == "." then
			connection = replica:OnChange(function(action, path, param1, param2)
				CacheModule.ClearAllCaches()

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
			local pathKeys = PathCacheModule.GetPathKeys(pathOrKey)

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
					CacheModule.InvalidateForMutationPath(path)

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
			ConnectionModule.AddConnection(connection)
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

		ConnectionModule.AddConnection(newReplicaConnection)

		return connection
	end
end

function PlayerState.GetReplica(): ReplicaInstance?
	if not Validation.ValidateReplica(localReplica) then
		return nil
	end

	return localReplica
end

function PlayerState.GetAll(): PlayerData?
	if not WaitForData() then
		return nil
	end

	if not Validation.ValidateReplica(localReplica) then
		return nil
	end

	return (localReplica :: ReplicaInstance).Data
end

function PlayerState.GetOfflineData(userId: number): PlayerData?
	if not userId or userId == 0 then
		warn("[PlayerState] Invalid userId for GetOfflineData")
		return nil
	end

	local ok, result = pcall(function()
		return OfflineDataRemote.Invoke(userId)
	end)

	if not ok then
		warn(`[PlayerState] GetOfflineData Invoke failed: {result}`)
		return nil
	end

	return result :: PlayerData?
end

function PlayerState.IsReady(): boolean
	return dataReady and Validation.ValidateReplica(localReplica)
end

function PlayerState.ClearCache(): ()
	PathCacheModule.ClearCache()
	CacheModule.ClearAllCaches()
end

function PlayerState.GetLeaderboardInfo(statName: string): LeaderboardInfo?
	if not WaitForData() then
		print("[PlayerState] GetLeaderboardInfo failed: No data")
		return nil
	end

	if not Validation.ValidateReplica(localReplica) then
		print("[PlayerState] GetLeaderboardInfo failed: No replica")
		return nil
	end

	return Leaderboard.GetLeaderboardInfo(localReplica, statName)
end

function PlayerState.GetLeaderboard(statName: string, limit: number?): {LeaderboardEntry}
	if not WaitForData() then
		return {}
	end

	if not Validation.ValidateReplica(localReplica) then
		return {}
	end

	return Leaderboard.GetLeaderboard(localReplica, statName, limit)
end

return PlayerState
