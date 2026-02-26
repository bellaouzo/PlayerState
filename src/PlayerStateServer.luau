--!strict

--[[
	PlayerStateClient - Server-side player data access

	Documentation: https://playerstate.netlify.app/api/server.html
--]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local IS_SERVER = RunService:IsServer()
if not IS_SERVER then
	error("[PlayerStateServer] This module can only be used on the server")
end

local DefaultData = require(script.Parent.DefaultData)
local ProfileService = require(script.Parent.ProfileStore)
local ReplicaServer = require(script.Parent.Replica.ReplicaServer)
local Signal = require(script.Parent.Replica.Signal)
local Config = require(script.Parent.PlayerStateConfig)

local CreatePathCache = require(script.Parent.Internal.Shared.PathCache)
local Utils = require(script.Parent.Internal.Shared.Utils)
local Validation = require(script.Parent.Internal.Server.Validation)
local DataUtils = require(script.Parent.Internal.Server.DataUtils)
local ArrayOps = require(script.Parent.Internal.Server.Array)
local DictOps = require(script.Parent.Internal.Server.Dict)
local CreateBatchModule = require(script.Parent.Internal.Server.Batch)
local Leaderstats = require(script.Parent.Internal.Server.Leaderstats)
local CreateLeaderboardModule = require(script.Parent.Internal.Server.Leaderboard)
local OfflineData = require(script.Parent.Internal.Server.OfflineData)
local DataWipe = require(script.Parent.Internal.Server.DataWipe)

export type PlayerData = typeof(DefaultData)

export type ProfileStoreProfile = {
	Data: PlayerData,
	OnSessionEnd: RBXScriptSignal,
	AddUserId: (self: ProfileStoreProfile, userId: number) -> (),
	Reconcile: (self: ProfileStoreProfile) -> (),
	EndSession: (self: ProfileStoreProfile) -> (),
	IsActive: (self: ProfileStoreProfile) -> boolean,
	MessageHandler: (self: ProfileStoreProfile, fn: (message: any, processed: () -> ()) -> ()) -> (),
}

export type ProfileStoreInstance = any

export type ReplicaInstance = ReplicaServer.Replica

export type ArrayPath = string
export type DictPath = string  
export type ValuePath = string

export type BatchOperation = {
	path: ValuePath,
	value: any,
}

export type BatchUpdateOperation = {
	path: ValuePath,
	operation: "Increment" | "Decrement",
	amount: number?,
}

export type LeaderboardEntry = {
	userId: number,
	score: number,
	rank: number,
}

export type PlayerStateServer = {
	SaveData: (player: Player) -> boolean,
	Init: (player: Player, existingData: PlayerData?) -> boolean,
	Set: (player: Player, key: string, value: any) -> boolean,
	Get: (player: Player, key: string) -> any,
	SetPath: (player: Player, path: ValuePath, value: any) -> boolean,
	GetPath: (player: Player, path: ValuePath) -> any,
	SetValues: (player: Player, values: {[string]: any}) -> boolean,
	BatchSetValues: (player: Player, operations: {BatchOperation}) -> boolean,
	BatchUpdateValues: (player: Player, operations: {BatchUpdateOperation}) -> boolean,
	Increment: (player: Player, path: ValuePath, amount: number?) -> boolean,
	Decrement: (player: Player, path: ValuePath, amount: number?) -> boolean,
	FlushBatch: (player: Player) -> boolean,
	AddToArray: (player: Player, arrayPath: ArrayPath, item: any) -> boolean,
	RemoveFromArray: (player: Player, arrayPath: ArrayPath, index: number) -> boolean,
	UpdateArrayItem: (player: Player, arrayPath: ArrayPath, index: number, newItem: any) -> boolean,
	SetInDict: (player: Player, dictPath: DictPath, key: string | number, value: any) -> boolean,
	GetFromDict: (player: Player, dictPath: DictPath, key: string | number) -> any,
	RemoveFromDict: (player: Player, dictPath: DictPath, key: string | number) -> boolean,
	Clone: (value: any, deep: boolean?) -> any,
	GetReplica: (player: Player) -> ReplicaInstance?,
	GetProfile: (player: Player) -> ProfileStoreProfile?,
	GetAll: (player: Player) -> PlayerData?,
	GetOfflineData: (userId: number) -> PlayerData?,
	IsPlayerDataReady: (player: Player) -> boolean,
	ClearPathCache: () -> (),
	UpdateLeaderboard: (player: Player, statName: string, score: number) -> boolean,
	GetLeaderboard: (statName: string, topCount: number) -> {LeaderboardEntry},
	GetPlayerRank: (player: Player, statName: string) -> number?,
	SetOfflineData: (userId: number, path: string, value: any) -> boolean,
	WipePlayerData: (player: Player) -> boolean,
	WipeOfflinePlayerData: (userId: number) -> boolean,

	BeforeSave: BeforeSaveSignal,
	ProfileLoaded: ProfileLoadedSignal,
	ProfileUnloaded: ProfileUnloadedSignal,
}

export type Connection = {
	Disconnect: (self: Connection) -> ()
}
export type Signal = {
	Connect: (self: Signal, listener: (...any) -> ()) -> (Connection),
	Fire: (self: Signal, ...any) -> (),
	GetListenerCount: (self: Signal) -> (number),
}
export type BeforeSaveSignal = {
	Connect: (self: BeforeSaveSignal, listener: (player: Player, data: PlayerData) -> ()) -> (Connection),
	Fire: (self: BeforeSaveSignal, player: Player, data: PlayerData) -> (),
	GetListenerCount: (self: BeforeSaveSignal) -> (number),
}
export type ProfileLoadedSignal = {
	Connect: (self: ProfileLoadedSignal, listener: (player: Player, data: PlayerData) -> ()) -> (Connection),
	Fire: (self: ProfileLoadedSignal, player: Player, data: PlayerData) -> (),
	GetListenerCount: (self: ProfileLoadedSignal) -> (number),
}
export type ProfileUnloadedSignal = {
	Connect: (self: ProfileUnloadedSignal, listener: (player: Player, data: PlayerData) -> ()) -> (Connection),
	Fire: (self: ProfileUnloadedSignal, player: Player, data: PlayerData) -> (),
	GetListenerCount: (self: ProfileUnloadedSignal) -> (number),
}

local CONFIG = Config.Server
local AUTO_CLONE_TABLES = CONFIG.AutoCloneTables

if CONFIG.Leaderboard and CONFIG.Leaderboard.SyncInterval and CONFIG.Leaderboard.SyncInterval < 60 then
	warn("[PlayerState] SyncInterval should be >= 60 seconds for optimal performance. Setting to 60.")

	CONFIG.Leaderboard.SyncInterval = 60
end

local replicas: { [Player]: ReplicaInstance } = {}
local profiles: { [Player]: ProfileStoreProfile } = {}
local loadedProfileUserIds: {[Player]: number} = {}
local initInFlight: {[number]: boolean} = {}
local profileStore: ProfileStoreInstance

local BeforeSave = Signal.New() :: BeforeSaveSignal
local ProfileLoaded = Signal.New() :: ProfileLoadedSignal
local ProfileUnloaded = Signal.New() :: ProfileUnloadedSignal

local PathCacheModule = CreatePathCache(CONFIG.MaxCacheSize)
local GetPathKeys = PathCacheModule.GetPathKeys

local function GetNestedValue(data: any, path: string): any
	local keys = GetPathKeys(path)
	return DataUtils.GetNestedValue(data, keys)
end

local BatchModule = CreateBatchModule(
	CONFIG,
	GetPathKeys,
	Validation.ValidateReplica,
	function(player: Player)
		return replicas[player]
	end
)

local LeaderboardModule = CreateLeaderboardModule(
	CONFIG,
	Validation.ValidatePlayer,
	Validation.ValidateReplica,
	function()
		return replicas
	end,
	GetNestedValue
)

local PlayerDataToken = ReplicaServer.Token("PlayerData")

profileStore = ProfileService.New(
	CONFIG.DataStore.Name,
	CONFIG.Profile.Template
)

if CONFIG.DataStore.Scope == "Testing" then
	profileStore = profileStore.Mock
	print("[PlayerState] Testing Scope: Using ProfileStore with mock data")
end

LeaderboardModule.InitializeLeaderboards()

local PlayerState: PlayerStateServer = {} :: PlayerStateServer

local function _WaitForPlayerData(player: Player, maxWaitTime: number?): boolean
	local waitTime: number = maxWaitTime or CONFIG.DataWaitTimeout or 10
	local startTime = tick()

	while not PlayerState.IsPlayerDataReady(player) do
		if tick() - startTime > waitTime then
			warn(`[PlayerState] Timeout waiting for {player.Name}'s data to load`)
			return false
		end
		task.wait(0.1)
	end

	return true
end

local function _GetPlayerProfile(player: Player): ProfileStoreProfile?
	if not Validation.ValidatePlayer(player) then
		return nil
	end

	local profile = profiles[player]
	if not Validation.ValidateProfile(profile) then
		warn(`[PlayerState] No valid profile found for {player.Name}`)
		return nil
	end

	return profile
end

local function _GetPlayerReplica(player: Player): ReplicaInstance?
	if not Validation.ValidatePlayer(player) then
		local profile = profiles[player]
		if profile and Validation.ValidateProfile(profile) then
			local replica = replicas[player]

			if Validation.ValidateReplica(replica) then
				return replica
			end
		end

		return nil
	end

	if not _WaitForPlayerData(player) then
		return nil
	end

	local replica = replicas[player]
	if not Validation.ValidateReplica(replica) then
		warn(`[PlayerState] No valid replica found for {player.Name}`)
		return nil
	end

	return replica
end

local function _ResolveViewedUserSettings(): (number, boolean)
	local viewedConfig = CONFIG.ViewedUser
	if typeof(viewedConfig) ~= "table" then
		return 0, true
	end

	local viewedUserId = viewedConfig.ViewedUserId
	if typeof(viewedUserId) ~= "number" then
		if viewedUserId ~= nil then
			warn("[PlayerState] CONFIG.ViewedUser.ViewedUserId must be a number. Falling back to 0.")
		end

		viewedUserId = 0
	end

	viewedUserId = math.floor(viewedUserId)
	if viewedUserId < 0 then
		warn("[PlayerState] CONFIG.ViewedUser.ViewedUserId cannot be negative. Falling back to 0.")

		viewedUserId = 0
	end

	local readOnly = viewedConfig.ReadOnly
	if typeof(readOnly) ~= "boolean" then
		if readOnly ~= nil then
			warn("[PlayerState] CONFIG.ViewedUser.ReadOnly must be a boolean. Falling back to true.")
		end

		readOnly = true
	end

	return viewedUserId, readOnly
end

local function _ResolveEffectiveProfileUserId(player: Player): number
	local viewedUserId = _ResolveViewedUserSettings()

	if viewedUserId == 0 then
		return player.UserId
	end

	if not RunService:IsStudio() then
		warn("[PlayerState] CONFIG.ViewedUser.ViewedUserId is Studio-only. Falling back to player's own profile.")
		return player.UserId
	end

	return viewedUserId
end

local function _IsViewingAnotherUser(player: Player): boolean
	local loadedProfileUserId = loadedProfileUserIds[player]

	return loadedProfileUserId ~= nil and loadedProfileUserId ~= player.UserId
end

local function _CanMutatePlayerData(player: Player): boolean
	if not _IsViewingAnotherUser(player) then
		return true
	end

	local _, readOnly = _ResolveViewedUserSettings()
	if readOnly then
		warn(`[PlayerState] Blocked write for {player.Name} while viewing user {loadedProfileUserIds[player]} (ReadOnly mode).`)
		return false
	end

	return true
end

function PlayerState.Init(player: Player, existingData: PlayerData?): boolean
	if not Validation.ValidatePlayer(player) then return false end

	if profiles[player] or replicas[player] then
		warn(`[PlayerState] {player.Name} already initialized`)
		return false
	end

	if existingData then
		error("[PlayerState] existingData is not supported")
	end

	local initInFlight: {[number]: boolean} = initInFlight or {}
	if initInFlight[player.UserId] then
		warn(`[PlayerState] Init already running for {player.Name}`)
		return false
	end

	initInFlight[player.UserId] = true

	local effectiveProfileUserId = _ResolveEffectiveProfileUserId(player)
	local profileKey = CONFIG.Profile.Key .. "_" .. effectiveProfileUserId
	local _, viewedReadOnly = _ResolveViewedUserSettings()

	if effectiveProfileUserId ~= player.UserId then
		local viewedModeLabel = if viewedReadOnly then "read-only" else "writable"
		
		print(`[PlayerState] {player.Name} is loading viewed profile {effectiveProfileUserId} ({viewedModeLabel}).`)
	end

	local function attach(profile: ProfileStoreProfile)
		profiles[player] = profile
		loadedProfileUserIds[player] = effectiveProfileUserId

		LeaderboardModule.SetupLeaderboardRankSaveProtection(profile)

		if replicas[player] then
			pcall(replicas[player].Destroy, replicas[player])
		end
		local replica = ReplicaServer.New({
			Token = PlayerDataToken,
			Data = profile.Data,
			Tags = { UserId = player.UserId, PlayerName = player.Name },
		})
		replicas[player] = replica

		if ReplicaServer.ReadyPlayers[player] then
			replica:Subscribe(player)
		else
			local conn
			conn = ReplicaServer.NewReadyPlayer:Connect(function(p: Player)
				if p == player then
					replica:Subscribe(player)
					conn:Disconnect()
				end
			end)
		end

		local ls = player:FindFirstChild("leaderstats")
		if ls then
			pcall(function()
				ls:Destroy()
			end)
		end

		Leaderstats.SetupLeaderstatsSync(
			player,
			replica,
			function(p: Player)
				return profiles[p]
			end,
			Validation.ValidateProfile,
			GetNestedValue
		)

		if CONFIG.Leaderboard.Enabled then
			LeaderboardModule.StartPeriodicUpdates()
		end

		ProfileLoaded:Fire(player, profile.Data)
	end

	local function openSession(): ProfileStoreProfile?
		local ok, profOrErr = pcall(function()
			return profileStore:StartSessionAsync(profileKey)
		end)

		if not ok or not profOrErr then
			warn(`[PlayerState] StartSession failed for {player.Name}: {profOrErr}`)
			return nil
		end

		local prof: ProfileStoreProfile = profOrErr
		prof:AddUserId(player.UserId)
		prof:Reconcile()

		if CONFIG.CleanExtraFields then
			DataUtils.CleanData(prof.Data, CONFIG.Profile.Template)
		end

		return prof
	end

	local profile = openSession()
	if not profile then
		initInFlight[player.UserId] = nil
		player:Kick("Failed to load data - please rejoin")

		return false
	end

	profile.OnSessionEnd:Connect(function()
		ProfileUnloaded:Fire(player, profile.Data)

		task.delay(2, function()
			if not player:IsDescendantOf(Players) then return end
			local newProfile = openSession()

			if newProfile then
				attach(newProfile)
			elseif player:IsDescendantOf(Players) then
				player:Kick("Profile session ended - rejoin to continue playing")
			end
		end)
	end)

	profile:MessageHandler(function(message, processed)
		if message.Type == "SetData" then
			PlayerState.SetPath(player, message.Path, message.Value)
			processed()
		elseif message.Type == "WipeData" then
			for key, value in CONFIG.Profile.Template do
				PlayerState.Set(player, key :: string, value)
			end
			processed()
		end
	end)

	if player:IsDescendantOf(Players) then
		attach(profile)
	else
		profile:EndSession()
		initInFlight[player.UserId] = nil

		return false
	end

	initInFlight[player.UserId] = nil
	return true
end


function PlayerState.Set(player: Player, key: string, value: any): boolean
	if not _CanMutatePlayerData(player) then
		return false
	end

	local replica = _GetPlayerReplica(player)

	if not replica then
		return false
	end

	if string.find(key, "%.") then
		warn(`[PlayerState] Detected path syntax in Set() call. Use SetPath() instead for nested paths like "{key}"`)
		return false
	end

	if key == "leaderstats" or string.sub(key, 1, 12) == "leaderstats." then
		warn(`[PlayerState] Cannot directly modify leaderstats. Change the actual data source that the leaderstat references instead.`)
		return false
	end

	local success = pcall(replica.Set, replica, {key}, value)
	if not success then
		warn(`[PlayerState] Set operation failed for {player.Name}`)
		return false
	end

	if LeaderboardModule.IsStatTracked(key) and typeof(value) == "number" then
		LeaderboardModule.UpdateReplicaLeaderboardScore(replica, key, value :: number)
	end

	return true
end

function PlayerState.Get(player: Player, key: string): any
	if not player or player.Parent ~= Players then
		return nil
	end

	local replica = _GetPlayerReplica(player)
	if not replica then
		return nil
	end

	local value = (replica.Data :: any)[key]

	if AUTO_CLONE_TABLES and typeof(value) == "table" then
		return Utils.DeepClone(value)
	end

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

function PlayerState.SetPath(player: Player, path: ValuePath, value: any): boolean
	if not _CanMutatePlayerData(player) then
		return false
	end

	local replica = _GetPlayerReplica(player)

	if not replica then
		return false
	end

	if path == "leaderstats" or string.sub(path, 1, 12) == "leaderstats." then
		warn(`[PlayerState] Cannot directly modify leaderstats path "{path}". Change the actual data source that the leaderstat references instead.`)
		return false
	end

	local shouldSyncLeaderboard = LeaderboardModule.IsStatTracked(path) and typeof(value) == "number"

	if not string.find(path, ".", 1, true) then
		local success = pcall(replica.Set, replica, {path}, value)
		if not success then
			warn(`[PlayerState] SetPath operation failed for {player.Name}`)
			return false
		end

		if shouldSyncLeaderboard then
			LeaderboardModule.UpdateReplicaLeaderboardScore(replica, path, value :: number)
		end

		return true
	end

	local pathKeys = GetPathKeys(path)
	local success = pcall(replica.Set, replica, pathKeys, value)
	if not success then
		warn(`[PlayerState] SetPath operation failed for {player.Name}`)
		return false
	end

	if shouldSyncLeaderboard then
		LeaderboardModule.UpdateReplicaLeaderboardScore(replica, path, value :: number)
	end

	return true
end

function PlayerState.GetPath(player: Player, path: ValuePath): any
	local replica = _GetPlayerReplica(player)
	if not replica then
		return nil
	end

	local result
	if not string.find(path, ".", 1, true) then
		result = (replica.Data :: any)[path]
	else
		result = GetNestedValue(replica.Data, path)
	end

	if AUTO_CLONE_TABLES and typeof(result) == "table" then
		return Utils.DeepClone(result)
	end

	return result
end

function PlayerState.SetValues(player: Player, values: {[string]: any}): boolean
	if not _CanMutatePlayerData(player) then
		return false
	end

	local replica = _GetPlayerReplica(player)

	if not replica then
		return false
	end

	for key, _ in values do
		if key == "leaderstats" or string.sub(key, 1, 12) == "leaderstats." then
			warn(`[PlayerState] Cannot directly modify leaderstats key "{key}" in SetValues. Change the actual data source that the leaderstat references instead.`)
			return false
		end
	end

	local success = pcall(replica.SetValues, replica, {}, values)
	if not success then
		warn(`[PlayerState] SetValues operation failed for {player.Name}`)
		return false
	end

	for key, value in values do
		if LeaderboardModule.IsStatTracked(key) and typeof(value) == "number" then
			LeaderboardModule.UpdateReplicaLeaderboardScore(replica, key, value :: number)
		end
	end

	return true
end

function PlayerState.BatchSetValues(player: Player, operations: {BatchOperation}): boolean
	if not Validation.ValidatePlayer(player) then
		return false
	end

	if not _CanMutatePlayerData(player) then
		return false
	end

	for _, operation in operations do
		if operation.path == "leaderstats" or string.sub(operation.path, 1, 12) == "leaderstats." then
			warn(`[PlayerState] Cannot directly modify leaderstats path "{operation.path}" in BatchSetValues. Change the actual data source that the leaderstat references instead.`)
			return false
		end

		BatchModule.ScheduleBatchOperation(player, operation)
	end

	return true
end

function PlayerState.BatchUpdateValues(player: Player, operations: {BatchUpdateOperation}): boolean
	if not Validation.ValidatePlayer(player) then
		return false
	end

	if not _CanMutatePlayerData(player) then
		return false
	end

	local replica = _GetPlayerReplica(player)
	if not replica then
		return false
	end

	local batchOperations: {BatchOperation} = {}

	for _, op in operations do
		local currentValue = PlayerState.GetPath(player, op.path)

		if typeof(currentValue) ~= "number" then
			warn(`[PlayerState] Cannot {op.operation} non-numeric value at path: {op.path}`)
			return false
		end

		local amount = if op.amount ~= nil then op.amount else 1
		local newValue: number

		if op.operation == "Increment" then
			newValue = currentValue + amount
		elseif op.operation == "Decrement" then
			newValue = currentValue - amount
		else
			warn(`[PlayerState] Invalid operation type: {op.operation}`)
			return false
		end

		table.insert(batchOperations, {
			path = op.path,
			value = newValue,
		})
	end

	local success = PlayerState.BatchSetValues(player, batchOperations)

	BatchModule.FlushBatch(player)

	return success
end

function PlayerState.FlushBatch(player: Player): boolean
	if not Validation.ValidatePlayer(player) then
		return false
	end

	if not _CanMutatePlayerData(player) then
		return false
	end

	BatchModule.FlushBatch(player)
	return true
end

function PlayerState.AddToArray(player: Player, arrayPath: ArrayPath, item: any): boolean
	if not _CanMutatePlayerData(player) then
		return false
	end

	local replica = _GetPlayerReplica(player)

	if not replica then
		return false
	end

	local pathKeys = GetPathKeys(arrayPath)
	local success, result = ArrayOps.AddToArray(replica, pathKeys, item)
	if not success then
		warn(`[PlayerState] AddToArray operation failed for {player.Name}: {result}`)
		return false
	end

	return success
end

function PlayerState.RemoveFromArray(player: Player, arrayPath: ArrayPath, index: number): boolean
	if not _CanMutatePlayerData(player) then
		return false
	end

	local replica = _GetPlayerReplica(player)

	if not replica then
		return false
	end

	local pathKeys = GetPathKeys(arrayPath)
	local success, result = ArrayOps.RemoveFromArray(replica, pathKeys, index)
	if not success then
		warn(`[PlayerState] RemoveFromArray operation failed for {player.Name}: {result}`)
		return false
	end

	return success
end

function PlayerState.UpdateArrayItem(player: Player, arrayPath: ArrayPath, index: number, newItem: any): boolean
	if not _CanMutatePlayerData(player) then
		return false
	end

	local replica = _GetPlayerReplica(player)

	if not replica then
		return false
	end

	local pathKeys = GetPathKeys(arrayPath)
	local success = ArrayOps.UpdateArrayItem(replica, pathKeys, index, newItem)
	if not success then
		warn(`[PlayerState] UpdateArrayItem operation failed for {player.Name}`)
		return false
	end

	return true
end

function PlayerState.SetInDict(player: Player, dictPath: DictPath, key: string | number, value: any): boolean
	if not _CanMutatePlayerData(player) then
		return false
	end

	local replica = _GetPlayerReplica(player)

	if not replica then
		return false
	end

	local stringKey = if typeof(key) == "number" then tostring(key) else key
	local currentDict = PlayerState.GetPath(player, dictPath)

	if not currentDict or typeof(currentDict) ~= "table" then
		warn(`[PlayerState] Created new dictionary at path "{dictPath}" for {player.Name}`)
		currentDict = {}
	end

	local pathKeys = GetPathKeys(dictPath)
	local success = DictOps.SetInDict(replica, pathKeys, currentDict, stringKey, value)

	if not success then
		warn(`[PlayerState] SetInDict operation failed for {player.Name}`)
		return false
	end

	return true
end

function PlayerState.GetFromDict(player: Player, dictPath: DictPath, key: string | number): any
	local replica = _GetPlayerReplica(player)

	if not replica then
		return nil
	end

	local stringKey = if typeof(key) == "number" then tostring(key) else key

	local currentDict = PlayerState.GetPath(player, dictPath) or {}

	local result = currentDict[stringKey]

	if AUTO_CLONE_TABLES and typeof(result) == "table" then
		return Utils.DeepClone(result)
	end

	return result
end

function PlayerState.RemoveFromDict(player: Player, dictPath: DictPath, key: string | number): boolean
	if not _CanMutatePlayerData(player) then
		return false
	end

	local replica = _GetPlayerReplica(player)

	if not replica then
		return false
	end

	local stringKey = if typeof(key) == "number" then tostring(key) else key

	local currentDict = PlayerState.GetPath(player, dictPath) or {}

	local pathKeys = GetPathKeys(dictPath)
	local success = DictOps.RemoveFromDict(replica, pathKeys, currentDict, stringKey)

	if not success then
		warn(`[PlayerState] RemoveFromDict failed - path is not a dictionary for {player.Name}`)
		return false
	end

	return true
end

function PlayerState.GetReplica(player: Player): ReplicaInstance?
	return _GetPlayerReplica(player)
end

function PlayerState.GetProfile(player: Player): ProfileStoreProfile?
	return _GetPlayerProfile(player)
end

function PlayerState.GetAll(player: Player): PlayerData?
	if not Validation.ValidatePlayer(player) then
		local profile = profiles[player]
		if profile and Validation.ValidateProfile(profile) then
			return profile.Data
		end
		return nil
	end

	local replica = _GetPlayerReplica(player)
	if not replica then
		return nil
	end

	return replica.Data
end

function PlayerState.IsPlayerDataReady(player: Player): boolean
	return Validation.ValidatePlayer(player) and Validation.ValidateProfile(profiles[player]) and Validation.ValidateReplica(replicas[player])
end

function PlayerState.ClearPathCache(): ()
	PathCacheModule.ClearCache()
end

function PlayerState.GetOfflineData(userId: number): PlayerData?
	return OfflineData.GetOfflineData(
		userId,
		CONFIG,
		profileStore,
		function(player: Player)
			return PlayerState.GetAll(player)
		end
	)
end

function PlayerState.SetOfflineData(userId: number, path: string, value: any): boolean
	return OfflineData.SetOfflineData(
		userId,
		path,
		value,
		CONFIG,
		profileStore,
		function(player: Player, p: string, v: any)
			return PlayerState.SetPath(player, p, v)
		end,
		GetPathKeys,
		function(data: any, template: any)
			if CONFIG.CleanExtraFields then
				DataUtils.CleanData(data, template)
			end
		end
	)
end

function PlayerState.WipePlayerData(player: Player): boolean
	if not _CanMutatePlayerData(player) then
		return false
	end

	return DataWipe.WipePlayerData(
		player,
		CONFIG,
		function(p: Player)
			return profiles[p]
		end,
		function(p: Player)
			return replicas[p]
		end,
		Validation.ValidatePlayer,
		Validation.ValidateProfile,
		Validation.ValidateReplica
	)
end

function PlayerState.WipeOfflinePlayerData(userId: number): boolean
	return DataWipe.WipeOfflinePlayerData(
		userId,
		CONFIG,
		profileStore,
		PlayerState.WipePlayerData,
		function(data: any, template: any)
			if CONFIG.CleanExtraFields then
				DataUtils.CleanData(data, template)
			end
		end
	)
end

function PlayerState.SaveData(player: Player): boolean
	local profile = _GetPlayerProfile(player)
	if not profile then
		return false
	end

	BeforeSave:Fire(player, profile.Data)

	return profile:IsActive()
end

function PlayerState.Increment(player: Player, path: ValuePath, amount: number?): boolean
	if not player then
		print("[PlayerState] Invalid player for Increment")
		return false
	end

	if not _CanMutatePlayerData(player) then
		return false
	end

	local currentValue = PlayerState.GetPath(player, path)
	if typeof(currentValue) ~= "number" then
		warn(`[PlayerState] Cannot increment non-numeric value at path: {path}`)
		return false
	end

	local incrementAmount = if amount ~= nil then amount else 1
	local newValue = currentValue + incrementAmount

	return PlayerState.SetPath(player, path, newValue)
end

function PlayerState.Decrement(player: Player, path: ValuePath, amount: number?): boolean
	local decrementAmount = if amount ~= nil then amount else 1

	return PlayerState.Increment(player, path, -decrementAmount)
end

function PlayerState.UpdateLeaderboard(player: Player, statName: string, score: number): boolean
	if not CONFIG.Leaderboard or not CONFIG.Leaderboard.Enabled then
		warn("[PlayerState] Leaderboard functionality is disabled")
		return false
	end

	if not LeaderboardModule.IsStatTracked(statName) then
		warn(`[PlayerState] Stat "{statName}" is not configured as a tracked leaderboard stat. Add it to CONFIG.Leaderboard.TrackedStats`)
		return false
	end

	if not Validation.ValidatePlayer(player) then
		return false
	end

	local store = LeaderboardModule.GetLeaderboardInternal
	if not store then
		warn(`[PlayerState] No leaderboard store found for stat: {statName}`)
		return false
	end

	return true
end


function PlayerState.GetLeaderboard(statName: string, limit: number): {LeaderboardEntry}
	if not CONFIG.Leaderboard or not CONFIG.Leaderboard.Enabled then
		return {}
	end

	if not LeaderboardModule.IsStatTracked(statName) then
		warn(`[PlayerState] Stat "{statName}" is not configured as a tracked leaderboard stat. Add it to CONFIG.Leaderboard.TrackedStats`)
		return {}
	end

	return LeaderboardModule.GetLeaderboardInternal(statName, limit)
end

function PlayerState.GetPlayerRank(player: Player, statName: string): number?
	if not CONFIG.Leaderboard or not CONFIG.Leaderboard.Enabled then
		return nil
	end

	if not LeaderboardModule.IsStatTracked(statName) then
		warn(`[PlayerState] Stat "{statName}" is not configured as a tracked leaderboard stat. Add it to CONFIG.Leaderboard.TrackedStats`)
		return nil
	end

	if not Validation.ValidatePlayer(player) then
		return nil
	end

	local leaderboard = PlayerState.GetLeaderboard(statName, 100)

	for _, entry in (leaderboard) do
		if entry.userId == player.UserId then
			return entry.rank
		end
	end

	return nil
end

Players.PlayerRemoving:Connect(function(player)
	if profiles[player] then
		BeforeSave:Fire(player, profiles[player].Data)
	end

	BatchModule.ClearPlayerBatch(player)

	LeaderboardModule.UpdatePlayerLeaderboard(player)

	if profiles[player] then
		profiles[player]:EndSession()
		profiles[player] = nil
	end
	loadedProfileUserIds[player] = nil

	if replicas[player] then
		replicas[player]:Destroy()
		replicas[player] = nil
	end
end)

game:BindToClose(function()
	for player, profile in profiles do
		if profile then
			BeforeSave:Fire(player, profile.Data)
		end
	end

	for player in profiles do
		BatchModule.ProcessBatchOperations(player)
	end

	LeaderboardModule.CancelPeriodicUpdates()

	LeaderboardModule.UpdateAllLeaderboards()

	for _, profile in profiles do
		if profile then
			profile:EndSession()
		end
	end
end)

PlayerState.BeforeSave = BeforeSave
PlayerState.ProfileLoaded = ProfileLoaded
PlayerState.ProfileUnloaded = ProfileUnloaded

return PlayerState
