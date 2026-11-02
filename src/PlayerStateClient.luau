--!strict

--[[
	PlayerStateClient - Client-side player data access
	
	Documentation: https://playerstate.netlify.app/api/client/
--]]

local RunService = game:GetService("RunService")

local dataReadyEvent = Instance.new("BindableEvent")
local sharedReadyEvent = Instance.new("BindableEvent")

local IS_CLIENT = RunService:IsClient()
if not IS_CLIENT then
	error("[PlayerStateClient] This module can only be used on the client")
end

local DefaultData = require(script.Parent.DefaultData)
local ReplicaClient = require(script.Parent.Replica.ReplicaClient)
local Config = require(script.Parent.PlayerStateConfig)

local Utils = require(script.Parent.Internal.Shared.Utils)
local CreatePathCache = require(script.Parent.Internal.Shared.PathCache)
local ListenerRegistry = require(script.Parent.Internal.Shared.ListenerRegistry)
local CreateCacheModule = require(script.Parent.Internal.Client.Cache)
local Validation = require(script.Parent.Internal.Client.Validation)
local Leaderboard = require(script.Parent.Internal.Client.Leaderboard)
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
	GetShared: (key: string) -> any,
	GetSharedPath: (path: ValuePath) -> any,
	OnSharedChanged: (pathOrKey: string, callback: (newValue: any, oldValue: any, info: ChangeInfo | {string}?) -> ()) -> ReplicaClient.Connection?,
	GetSharedReplica: () -> ReplicaInstance?,
	GetSharedAll: () -> {[string]: any}?,
	IsSharedReady: () -> boolean,
	ClearCache: () -> (),
	GetLeaderboardInfo: (statName: string) -> LeaderboardInfo?,
	GetLeaderboard: (statName: string, limit: number?) -> {LeaderboardEntry},
}

local localReplica: ReplicaInstance?
local sharedReplica: ReplicaInstance?
local dataReady: boolean = false
local sharedReady: boolean = false

local PathCacheModule = CreatePathCache(Config.Client.MaxPathCacheSize)
local CacheModule = CreateCacheModule(Config.Client.CacheDuration, Config.Client.CacheCleanupInterval)
local SharedCacheModule = CreateCacheModule(Config.Client.CacheDuration, Config.Client.CacheCleanupInterval)
local AUTO_CLONE_TABLES = Config.Client.AutoCloneTables

local PlayerState: PlayerStateClient = {} :: PlayerStateClient

local PlayerDataListeners = ListenerRegistry.new({
	getPathKeys = PathCacheModule.GetPathKeys,
	readValue = function(_pathKeys: {string}, pathOrKey: string): any
		return PlayerState.GetPath(pathOrKey)
	end,
	onChange = function(_action: string, path: {any}): ()
		CacheModule.InvalidateForMutationPath(path)
	end,
})

local SharedListeners = ListenerRegistry.new({
	getPathKeys = PathCacheModule.GetPathKeys,
	readValue = function(_pathKeys: {string}, pathOrKey: string): any
		return PlayerState.GetSharedPath(pathOrKey)
	end,
	onChange = function(_action: string, path: {any}): ()
		SharedCacheModule.InvalidateForMutationPath(path)
	end,
})

ReplicaClient.OnNew("PlayerData", function(replica)
	localReplica = replica
	dataReady = true

	CacheModule.ClearAllCaches()
	PlayerDataListeners:Bind(replica)

	dataReadyEvent:Fire()

	print("[PlayerState] Client data is ready")
end)

ReplicaClient.OnNew("SharedSession", function(replica)
	sharedReplica = replica
	sharedReady = true

	SharedCacheModule.ClearAllCaches()
	SharedListeners:Bind(replica)

	sharedReadyEvent:Fire()

	print("[PlayerState] Shared session is ready")
end)
ReplicaClient.RequestData()

local function LookupKey(container: {[any]: any}, key: string): any
	local value = container[key]
	if value == nil then
		local numericKey = tonumber(key)
		if numericKey ~= nil then
			value = container[numericKey]
		end
	end
	return value
end

local function ReadNestedValue(data: any, keys: {string}): any
	local current = data

	for _, key in keys do
		if typeof(current) ~= "table" then
			return nil
		end
		current = LookupKey(current, key)
		if current == nil then
			return nil
		end
	end

	return current
end

local function GetNestedValue(data: any, path: string): any
	local cached = CacheModule.GetFromNestedCache(path)
	if cached ~= nil then
		return cached
	end

	local result = ReadNestedValue(data, PathCacheModule.GetPathKeys(path))

	if result ~= nil then
		CacheModule.SetInNestedCache(path, result)
	end

	return result
end

local function GetSharedNestedValue(data: any, path: string): any
	local cached = SharedCacheModule.GetFromNestedCache(path)
	if cached ~= nil then
		return cached
	end

	local result = ReadNestedValue(data, PathCacheModule.GetPathKeys(path))

	if result ~= nil then
		SharedCacheModule.SetInNestedCache(path, result)
	end

	return result
end

local function IsDataReadyFlag(): boolean
	return dataReady
end

local function GetLocalReplicaRef(): ReplicaInstance?
	return localReplica
end

local function IsSharedReadyFlag(): boolean
	return sharedReady
end

local function GetSharedReplicaRef(): ReplicaInstance?
	return sharedReplica
end

local function WaitForData(): boolean
	local replica = localReplica
	if dataReady and replica and replica:IsActive() then
		return true
	end

	return Validation.WaitForData(IsDataReadyFlag, Validation.ValidateReplica, GetLocalReplicaRef, dataReadyEvent)
end

local function WaitForSharedData(): boolean
	local replica = sharedReplica
	if sharedReady and replica and replica:IsActive() then
		return true
	end

	return Validation.WaitForData(IsSharedReadyFlag, Validation.ValidateReplica, GetSharedReplicaRef, sharedReadyEvent)
end

local function ValidateSharedPathOrKey(pathOrKey: string, apiName: string): boolean
	if type(pathOrKey) ~= "string" then
		warn(`[PlayerState] {apiName} pathOrKey must be a string`)
		return false
	end

	return true
end

local function CloneIfTable(value: any): any
	if AUTO_CLONE_TABLES and typeof(value) == "table" then
		return Utils.DeepClone(value)
	end
	return value
end

function PlayerState.Get(key: string): any
	if not WaitForData() then
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
		return CloneIfTable(cachedValue)
	end

	local value = (localReplica :: ReplicaInstance).Data[key]

	if value ~= nil then
		CacheModule.SetInValueCache(key, value)
	end

	CacheModule.CleanupCache()

	return CloneIfTable(value)
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

	return CloneIfTable(result)
end

function PlayerState.GetFromDict(dictPath: ValuePath, key: string | number): any
	if not WaitForData() then
		return nil
	end

	if typeof(dictPath) == "Instance" and dictPath:IsA("Player") then
		warn(`[PlayerState] Player object detected as first parameter in GetFromDict(). Client-side GetFromDict() only takes a dictPath string. Use server-side PlayerState.GetFromDict(player, dictPath, key) instead.`)
		return nil
	end

	local stringKey = if typeof(key) == "number" then tostring(key) else key

	local replicaData = (localReplica :: ReplicaInstance).Data
	local current = ReadNestedValue(replicaData, PathCacheModule.GetPathKeys(dictPath))

	CacheModule.CleanupCache()

	if typeof(current) ~= "table" then
		return nil
	end

	local result = LookupKey(current, stringKey)

	return CloneIfTable(result)
end

function PlayerState.GetShared(key: string): any
	if not WaitForSharedData() then
		return nil
	end

	if not ValidateSharedPathOrKey(key, "GetShared") then
		return nil
	end

	if string.find(key, "%.") then
		warn(`[PlayerState] Detected path syntax in GetShared() call. Use GetSharedPath() instead for nested paths like "{key}"`)
		return nil
	end

	local cachedValue = SharedCacheModule.GetFromValueCache(key)
	if cachedValue ~= nil then
		return CloneIfTable(cachedValue)
	end

	local value = (sharedReplica :: ReplicaInstance).Data[key]

	if value ~= nil then
		SharedCacheModule.SetInValueCache(key, value)
	end

	SharedCacheModule.CleanupCache()

	return CloneIfTable(value)
end

function PlayerState.GetSharedPath(path: ValuePath): any
	if not WaitForSharedData() then
		return nil
	end

	if not ValidateSharedPathOrKey(path, "GetSharedPath") then
		return nil
	end

	local replicaData = (sharedReplica :: ReplicaInstance).Data

	local result
	if not string.find(path, ".", 1, true) then
		result = replicaData[path]
	else
		result = GetSharedNestedValue(replicaData, path)
	end

	SharedCacheModule.CleanupCache()

	return CloneIfTable(result)
end

function PlayerState.OnChanged(pathOrKey: string, callback: (newValue: any, oldValue: any, fullPath: {string}?) -> ()): ReplicaClient.Connection?
	if not ValidateSharedPathOrKey(pathOrKey, "OnChanged") then
		return nil
	end

	if type(callback) ~= "function" then
		warn("[PlayerState] OnChanged callback must be a function")
		return nil
	end

	return PlayerDataListeners:Connect(pathOrKey, callback)
end

function PlayerState.GetReplica(): ReplicaInstance?
	if not Validation.ValidateReplica(localReplica) then
		return nil
	end

	return localReplica
end

function PlayerState.OnSharedChanged(pathOrKey: string, callback: (newValue: any, oldValue: any, fullPath: {string}?) -> ()): ReplicaClient.Connection?
	if not ValidateSharedPathOrKey(pathOrKey, "OnSharedChanged") then
		return nil
	end

	if type(callback) ~= "function" then
		warn("[PlayerState] OnSharedChanged callback must be a function")
		return nil
	end

	return SharedListeners:Connect(pathOrKey, callback)
end

function PlayerState.GetAll(): PlayerData?
	if not WaitForData() then
		return nil
	end

	return (localReplica :: ReplicaInstance).Data
end

function PlayerState.GetSharedReplica(): ReplicaInstance?
	if not Validation.ValidateReplica(sharedReplica) then
		return nil
	end

	return sharedReplica
end

function PlayerState.GetSharedAll(): {[string]: any}?
	if not WaitForSharedData() then
		return nil
	end

	return (sharedReplica :: ReplicaInstance).Data
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

function PlayerState.IsSharedReady(): boolean
	return sharedReady and Validation.ValidateReplica(sharedReplica)
end

function PlayerState.ClearCache(): ()
	PathCacheModule.ClearCache()
	CacheModule.ClearAllCaches()
	SharedCacheModule.ClearAllCaches()
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
