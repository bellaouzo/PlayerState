--!strict

--[[
	PlayerStateClient - Server-side player data access

	Documentation: https://playerstate.netlify.app/api/server.html
--]]

-- Services
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local DataStoreService = game:GetService("DataStoreService")

-- Validation
local IS_SERVER = RunService:IsServer()
if not IS_SERVER then
	error("[PlayerStateServer] This module can only be used on the server")
end

-- Libraries  
local DefaultData = require(script.Parent.DefaultData)
local ProfileService = require(script.Parent.ProfileStore)
local ReplicaServer = require(script.Parent.Replica.ReplicaServer)
local Signal = require(script.Parent.Replica.Signal)
local Config = require(script.Parent.PlayerStateConfig)

-- Types
export type PlayerData = typeof(DefaultData)

export type ProfileStoreProfile = {
	Data: PlayerData,
	OnSessionEnd: RBXScriptSignal,
	AddUserId: (self: ProfileStoreProfile, userId: number) -> (),
	Reconcile: (self: ProfileStoreProfile) -> (),
	EndSession: (self: ProfileStoreProfile) -> (),
	IsActive: (self: ProfileStoreProfile) -> boolean,
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
	Increment: (player: Player, path: ValuePath, amount: number?) -> boolean,
	Decrement: (player: Player, path: ValuePath, amount: number?) -> boolean,
	FlushBatch: (player: Player) -> boolean,
	AddToArray: (player: Player, arrayPath: ArrayPath, item: any) -> boolean,
	RemoveFromArray: (player: Player, arrayPath: ArrayPath, index: number) -> boolean,
	UpdateArrayItem: (player: Player, arrayPath: ArrayPath, index: number, newItem: any) -> boolean,
	SetInDict: (player: Player, dictPath: DictPath, key: string | number, value: any) -> boolean,
	GetFromDict: (player: Player, dictPath: DictPath, key: string | number) -> any,
	RemoveFromDict: (player: Player, dictPath: DictPath, key: string | number) -> boolean,
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

	-- Events
	BeforeSave: BeforeSaveSignal,
	ProfileLoaded: ProfileLoadedSignal,
	ProfileUnloaded: ProfileUnloadedSignal,
}

-- Event types
export type Connection = {
	Disconnect: (self: Connection) -> ()
}
export type Signal = {
	Connect: (self: Signal, listener: (...any) -> ()) -> (Connection),
	GetListenerCount: (self: Signal) -> (number),
}
export type BeforeSaveSignal = {
	Connect: (self: BeforeSaveSignal, listener: (player: Player, data: PlayerData) -> ()) -> (Connection),
	GetListenerCount: (self: BeforeSaveSignal) -> (number),
}
export type ProfileLoadedSignal = {
	Connect: (self: ProfileLoadedSignal, listener: (player: Player, data: PlayerData) -> ()) -> (Connection),
	GetListenerCount: (self: ProfileLoadedSignal) -> (number),
}
export type ProfileUnloadedSignal = {
	Connect: (self: ProfileUnloadedSignal, listener: (player: Player, data: PlayerData) -> ()) -> (Connection),
	GetListenerCount: (self: ProfileUnloadedSignal) -> (number),
}

-- Configuration (now centralized in PlayerStateConfig)
local CONFIG = Config.Server

-- Validate configuration for performance constraints
if CONFIG.Leaderboard and CONFIG.Leaderboard.SyncInterval and CONFIG.Leaderboard.SyncInterval < 60 then
    warn("[PlayerState] SyncInterval should be >= 60 seconds for optimal performance. Setting to 60.")

    CONFIG.Leaderboard.SyncInterval = 60
end

-- IntValue limits 
local INT32_MAX = 2147483647
local INT32_MIN = -2147483648

-- States
local replicas: { [Player]: ReplicaInstance } = {}
local profiles: { [Player]: ProfileStoreProfile } = {}
local initInFlight: {[number]: boolean} = {}
local profileStore: ProfileStoreInstance

-- Events
local BeforeSave = Signal.New() :: BeforeSaveSignal
local ProfileLoaded = Signal.New() :: ProfileLoadedSignal
local ProfileUnloaded = Signal.New() :: ProfileUnloadedSignal

-- Performance
local pathCache: {[string]: {string}} = {}
local pathCacheSize: number = 0  -- Track cache size for O(1) lookup
local batchOperations: {[Player]: {BatchOperation}} = {}
local batchScheduled: {[Player]: thread?} = {}

-- Leaderboard
local leaderboardStores: {[string]: any} = {} -- {statName = OrderedDataStore, ...}
local leaderboardCache: {[string]: {data: {LeaderboardEntry}, lastUpdate: number}} = {} -- {statName = {data, lastUpdate}, ...}
local periodicUpdateThread: thread?

-- Replica setup
local PlayerDataToken = ReplicaServer.Token("PlayerData")

profileStore = ProfileService.New(
	CONFIG.DataStore.Name,
	CONFIG.Profile.Template
)

if CONFIG.DataStore.Scope == "Testing" then
	profileStore = profileStore.Mock
	print("[PlayerState] Testing Scope: Using ProfileStore with mock data")
end

-- ========== LEADERBOARD INITIALIZATION ==========
local function InitializeLeaderboards()
	if not CONFIG.Leaderboard.Enabled then return end

	for _, statName in (CONFIG.Leaderboard.TrackedStats) do
		local storeName = CONFIG.Leaderboard.DataStoreName .. "_" .. statName:gsub("%.", "_")
		leaderboardStores[statName] = DataStoreService:GetOrderedDataStore(storeName)
	end
end

InitializeLeaderboards()

-- ========== UTILITIES ==========
local function _GetAppropriateValueType(value: number): string
	if value % 1 ~= 0 then
		return "NumberValue"
	elseif value > INT32_MAX or value < INT32_MIN then
		return "NumberValue"
	else
		return "IntValue"
	end
end

local function GetPathKeys(path: string): {string}
	local cached = pathCache[path]
	if cached then
		return cached
	end

	local keys = string.split(path, ".")
	pathCache[path] = keys
	pathCacheSize += 1

	if pathCacheSize > CONFIG.MaxCacheSize then
		local clearCount = math.floor(CONFIG.MaxCacheSize * 0.2)
		local cleared = 0

		for cachedPath in pathCache do
			pathCache[cachedPath] = nil
			cleared += 1
			if cleared >= clearCount then
				break
			end
		end

		pathCacheSize -= cleared
	end

	return keys
end

local function _GetNestedValue(data: any, path: string): any
	local keys = GetPathKeys(path)
	local current = data


	for i = 1, #keys do
		local key = keys[i]
		if typeof(current) ~= "table" then
			return nil
		end
		current = current[key]
		if current == nil then
			return nil
		end
	end

	return current
end

local function _ValidatePlayer(player: Player): boolean
	return player and player.Parent == Players
end

local function _ValidateReplica(replica: ReplicaInstance?): boolean
	return replica ~= nil and replica:IsActive()
end

local function _ValidateProfile(profile: ProfileStoreProfile?): boolean
	return profile ~= nil and profile:IsActive()
end

-- ========== DATA UTILITIES ==========
local function _CleanData(data: any, template: any): ()
	if not CONFIG.CleanExtraFields then return end

	for key in data do
		if template[key] == nil then
			data[key] = nil
		elseif typeof(data[key]) == "table" and typeof(template[key]) == "table" then
			if next(template[key]) == nil then
				continue
			end

			_CleanData(data[key], template[key])
		end
	end
end

-- ========== BATCH PROCESSING ==========
local function _ProcessBatchOperations(player: Player): ()
	local playerBatch = batchOperations[player]
	if not playerBatch or #playerBatch == 0 then
		return
	end

	local replica = replicas[player]
	if not _ValidateReplica(replica) then
		warn(`[PlayerState] Cannot process batch operations - invalid replica for {player.Name}`)
		batchOperations[player] = nil
		batchScheduled[player] = nil
		return
	end

	local groupedOps: {[string]: {[string]: any}} = {}
	local singleOps: {{path: {string}, value: any}} = {}
	local rootLevelOps: {[string]: any} = {}

	for i = 1, #playerBatch do
		local operation = playerBatch[i]
		local pathKeys = GetPathKeys(operation.path)

		if #pathKeys == 1 then
			rootLevelOps[pathKeys[1]] = operation.value
		elseif #pathKeys == 2 then
			local rootPath = pathKeys[1]
			if not groupedOps[rootPath] then
				groupedOps[rootPath] = {}
			end
			groupedOps[rootPath][pathKeys[2]] = operation.value
		else
			singleOps[#singleOps + 1] = {path = pathKeys, value = operation.value}
		end
	end

	if next(rootLevelOps) then
		local success = pcall(replica.SetValues, replica, {}, rootLevelOps)
		if not success then
			warn(`[PlayerState] Batch root SetValues failed for {player.Name}`)
		end
	end

	for rootPath, values in groupedOps do
		local success = pcall(replica.SetValues, replica, {rootPath}, values)
		if not success then
			warn(`[PlayerState] Batch grouped SetValues failed for {player.Name}`)
		end
	end

	for i = 1, #singleOps do
		local operation = singleOps[i]
		local success = pcall(replica.Set, replica, operation.path, operation.value)
		if not success then
			warn(`[PlayerState] Batch Set failed for {player.Name}`)
		end
	end

	batchOperations[player] = nil
	batchScheduled[player] = nil
end

local function _ScheduleBatchOperation(player: Player, operation: BatchOperation): ()
	local playerBatch = batchOperations[player]
	if not playerBatch then
		playerBatch = {}
		batchOperations[player] = playerBatch
	end

	playerBatch[#playerBatch + 1] = operation

	if #playerBatch >= CONFIG.BatchSize then
		local scheduledThread = batchScheduled[player]
		if scheduledThread then
			task.cancel(scheduledThread)
			batchScheduled[player] = nil
		end
		_ProcessBatchOperations(player)
		return
	end

	if not batchScheduled[player] then
		batchScheduled[player] = task.delay(CONFIG.BatchDelay, function()
			_ProcessBatchOperations(player)
		end)
	end
end

-- ========== LEADERBOARD PERIODIC PROCESSING ==========
local function _UpdateAllLeaderboards(): ()
	if not CONFIG.Leaderboard.Enabled then return end

	for _, statName in CONFIG.Leaderboard.TrackedStats do
		local store = leaderboardStores[statName]
		if not store then continue end

		for _, player in Players:GetPlayers() do
			if not _ValidatePlayer(player) then continue end

			local replica = replicas[player]
			if not _ValidateReplica(replica) then continue end

			local value = _GetNestedValue(replica.Data, statName)
			if typeof(value) == "number" then
				task.spawn(function()
					pcall(function()
						store:SetAsync(tostring(player.UserId), value)
					end)
				end)
			end
		end
	end
end

local function _GetLeaderboardInternal(statName: string, limit: number): {LeaderboardEntry}
	local store = leaderboardStores[statName]
	if not store then
		return {}
	end

	local cached = leaderboardCache[statName]
	local currentTime = os.time()

	if cached and (currentTime - cached.lastUpdate) < 15 then
		return table.move(cached.data, 1, math.min(limit, #cached.data), 1, {})
	end

	local success, pages = pcall(function()
		return store:GetSortedAsync(false, math.max(limit, 100))
	end)

	if not success then
		if cached then
			return table.move(cached.data, 1, math.min(limit, #cached.data), 1, {})
		end
		return {}
	end

	local topPlayers: {LeaderboardEntry} = {}
	local data = pages:GetCurrentPage()

	for i, entry in data do
		local userId = tonumber(entry.key)
		if userId then
			table.insert(topPlayers, {
				userId = userId,
				score = entry.value,
				rank = i,
			})
		end
	end

	leaderboardCache[statName] = {
		data = topPlayers,
		lastUpdate = currentTime,
	}

	return table.move(topPlayers, 1, math.min(limit, #topPlayers), 1, {})
end

local function _SyncPlayerLeaderboardRanks(): ()
	if not CONFIG.Leaderboard.Enabled then return end

	for _, statName in CONFIG.Leaderboard.TrackedStats do
		local leaderboard = _GetLeaderboardInternal(statName, 100)

		local playerRanks: {[number]: {rank: number, score: number}} = {}
		for _, entry in leaderboard do
			playerRanks[entry.userId] = {
				rank = entry.rank,
				score = entry.score,
			}
		end

		for _, player in Players:GetPlayers() do
			if not _ValidatePlayer(player) then continue end

			local replica = replicas[player]
			if not _ValidateReplica(replica) then continue end

			local rankInfo = playerRanks[player.UserId]
			local currentRanks = replica.Data._LeaderboardRanks or {}
			local currentStatRank = currentRanks[statName]

			if rankInfo then
				if not currentStatRank or currentStatRank.rank ~= rankInfo.rank or currentStatRank.score ~= rankInfo.score then
					local newRanks = table.clone(currentRanks)
					newRanks[statName] = rankInfo

					pcall(replica.Set, replica, {"_LeaderboardRanks"}, newRanks)
				end
			else
				local value = _GetNestedValue(replica.Data, statName)
				if typeof(value) == "number" then
					if not currentStatRank or currentStatRank.score ~= value then
						local newRanks = table.clone(currentRanks)
						newRanks[statName] = {
							rank = nil,
							score = value,
						}

						pcall(replica.Set, replica, {"_LeaderboardRanks"}, newRanks)
					end
				end
			end
		end
	end
end

local function _StartPeriodicUpdates(): ()
	if periodicUpdateThread then
		task.cancel(periodicUpdateThread)
	end

	_UpdateAllLeaderboards()
	_SyncPlayerLeaderboardRanks()

	periodicUpdateThread = task.spawn(function()
		while true do
			task.wait(CONFIG.Leaderboard.SyncInterval)
			_UpdateAllLeaderboards()
			_SyncPlayerLeaderboardRanks()
		end
	end)
end

local function _UpdatePlayerLeaderboard(player: Player): ()
	if not CONFIG.Leaderboard.Enabled or not CONFIG.Leaderboard.UpdateOnPlayerLeave then return end
	if not _ValidatePlayer(player) then return end

	local replica = replicas[player]
	if not _ValidateReplica(replica) then return end

	for _, statName in CONFIG.Leaderboard.TrackedStats do
		local store = leaderboardStores[statName]
		if not store then continue end

		local value = _GetNestedValue(replica.Data, statName)
		if typeof(value) == "number" then
			task.spawn(function()
				pcall(function()
					store:SetAsync(tostring(player.UserId), value)
				end)
			end)
		end
	end
end

-- ========== LEADERSTATS UTILITIES ==========
local function _CreateLeaderstats(player: Player, leaderstatsConfig: {[string]: string}): ()
	local leaderstats = Instance.new("Folder")
	leaderstats.Name = "leaderstats"
	leaderstats.Parent = player

	for displayName, dataPath in leaderstatsConfig do
		local currentValue = _GetNestedValue(profiles[player].Data, dataPath)

		if typeof(currentValue) == "number" then
			local valueType = _GetAppropriateValueType(currentValue)
			local valueObject = Instance.new(valueType)

			valueObject.Value = currentValue
			valueObject.Name = displayName
			valueObject.Parent = leaderstats
		else
			local stringValue = Instance.new("StringValue")

			stringValue.Value = tostring(currentValue or "")
			stringValue.Name = displayName
			stringValue.Parent = leaderstats
		end
	end
end

local function _UpdateLeaderstatsForPath(player: Player, path: string, newValue: any): ()
	local leaderstats = player:FindFirstChild("leaderstats")
	if not leaderstats then return end

	local profile = profiles[player]
	if not _ValidateProfile(profile) then return end

	local leaderstatsConfig = (profile.Data :: any).leaderstats
	if not leaderstatsConfig then return end

	for displayName, configPath in leaderstatsConfig do
		if configPath == path then
			local valueObject = leaderstats:FindFirstChild(displayName)
			if valueObject then
				if typeof(newValue) == "number" then
					local requiredType = _GetAppropriateValueType(newValue)
					local currentType = valueObject.ClassName

					if currentType ~= requiredType then
						valueObject:Destroy()
						local newValueObject = Instance.new(requiredType)

						newValueObject.Value = newValue
						newValueObject.Name = displayName
						newValueObject.Parent = leaderstats
					else
						valueObject.Value = newValue
					end
				elseif valueObject:IsA("StringValue") then
					(valueObject :: StringValue).Value = tostring(newValue or "")
				end
			end

			break
		end
	end
end

local function _SetupLeaderstatsSync(player: Player, replica: ReplicaInstance): ()
	local leaderstatsConfig = (replica.Data :: any).leaderstats
	if not leaderstatsConfig then return end

	_CreateLeaderstats(player, leaderstatsConfig)

	local originalSet = replica.Set
	local originalSetValues = replica.SetValues

	replica.Set = function(self, path: {string}, value: any)
		local success = pcall(originalSet, self, path, value)
		if not success then
			warn(`[PlayerState] Set operation failed for {player.Name}`)
			return
		end

		local pathString = table.concat(path, ".")
		_UpdateLeaderstatsForPath(player, pathString, value)
	end

	replica.SetValues = function(self, path: {string}, values: {[string]: any})
		local success = pcall(originalSetValues, self, path, values)
		if not success then
			warn(`[PlayerState] SetValues operation failed for {player.Name}`)
			return
		end

		local basePath = table.concat(path, ".")
		for key, value in values do
			local fullPath = basePath == "" and key or basePath .. "." .. key
			_UpdateLeaderstatsForPath(player, fullPath, value)
		end
	end
end

-- ========== SERVER IMPLEMENTATION ==========
local PlayerState: PlayerStateServer = {} :: PlayerStateServer

local function _WaitForPlayerData(player: Player, maxWaitTime: number?): boolean
	maxWaitTime = maxWaitTime or CONFIG.DataWaitTimeout or 10
	local startTime = tick()

	while not PlayerState.IsPlayerDataReady(player) do
		if tick() - startTime > maxWaitTime then
			warn(`[PlayerState] Timeout waiting for {player.Name}'s data to load`)
			return false
		end
		task.wait(0.1)
	end

	return true
end

local function _GetPlayerProfile(player: Player): ProfileStoreProfile?
	if not _ValidatePlayer(player) then
		return nil
	end

	local profile = profiles[player]
	if not _ValidateProfile(profile) then
		warn(`[PlayerState] No valid profile found for {player.Name}`)
		return nil
	end

	return profile
end

local function _GetPlayerReplica(player: Player): ReplicaInstance?
	if not _ValidatePlayer(player) then
		local profile = profiles[player]
		if profile and _ValidateProfile(profile) then
			local replica = replicas[player]

			if _ValidateReplica(replica) then
				return replica
			end
		end

		return nil
	end

	if not _WaitForPlayerData(player) then
		return nil
	end

	local replica = replicas[player]
	if not _ValidateReplica(replica) then
		warn(`[PlayerState] No valid replica found for {player.Name}`)
		return nil
	end

	return replica
end

function PlayerState.Init(player: Player, existingData: PlayerData?): boolean
	if not _ValidatePlayer(player) then return false end
	
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

	local profileKey = CONFIG.Profile.Key .. "_" .. player.UserId

	local function attach(profile: ProfileStoreProfile)
		profiles[player] = profile

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
			conn = ReplicaServer.NewReadyPlayer:Connect(function(p)
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

		_SetupLeaderstatsSync(player, replica)

		if CONFIG.Leaderboard.Enabled then
			_StartPeriodicUpdates()
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
		
		_CleanData(prof.Data, CONFIG.Profile.Template)
		
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

	return (replica.Data :: any)[key]
end

function PlayerState.SetPath(player: Player, path: ValuePath, value: any): boolean
	local replica = _GetPlayerReplica(player)

	if not replica then
		return false
	end

	if path == "leaderstats" or string.sub(path, 1, 12) == "leaderstats." then
		warn(`[PlayerState] Cannot directly modify leaderstats path "{path}". Change the actual data source that the leaderstat references instead.`)
		return false
	end

	if not string.find(path, ".", 1, true) then
		local success = pcall(replica.Set, replica, {path}, value)
		if not success then
			warn(`[PlayerState] SetPath operation failed for {player.Name}`)
			return false
		end

		return true
	end

	local pathKeys = GetPathKeys(path)
	local success = pcall(replica.Set, replica, pathKeys, value)
	if not success then
		warn(`[PlayerState] SetPath operation failed for {player.Name}`)
		return false
	end

	return true
end

function PlayerState.GetPath(player: Player, path: ValuePath): any
	local replica = _GetPlayerReplica(player)
	if not replica then
		return nil
	end

	if not string.find(path, ".", 1, true) then
		return (replica.Data :: any)[path]
	end

	return _GetNestedValue(replica.Data, path)
end

function PlayerState.SetValues(player: Player, values: {[string]: any}): boolean
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

	return true
end

function PlayerState.BatchSetValues(player: Player, operations: {BatchOperation}): boolean
	if not _ValidatePlayer(player) then
		return false
	end

	for _, operation in operations do
		if operation.path == "leaderstats" or string.sub(operation.path, 1, 12) == "leaderstats." then
			warn(`[PlayerState] Cannot directly modify leaderstats path "{operation.path}" in BatchSetValues. Change the actual data source that the leaderstat references instead.`)
			return false
		end

		_ScheduleBatchOperation(player, operation)
	end

	return true
end

function PlayerState.FlushBatch(player: Player): boolean
	if not _ValidatePlayer(player) then
		return false
	end

	local scheduledThread = batchScheduled[player]
	if scheduledThread then
		task.cancel(scheduledThread)
		batchScheduled[player] = nil
	end

	_ProcessBatchOperations(player)
	return true
end

function PlayerState.AddToArray(player: Player, arrayPath: ArrayPath, item: any): boolean
	local replica = _GetPlayerReplica(player)

	if not replica then
		return false
	end

	local pathKeys = GetPathKeys(arrayPath)
	local success, result = pcall(replica.TableInsert, replica, pathKeys, item)
	if not success then
		warn(`[PlayerState] AddToArray operation failed for {player.Name}: {result}`)
		return false
	end

	return success
end

function PlayerState.RemoveFromArray(player: Player, arrayPath: ArrayPath, index: number): boolean
	local replica = _GetPlayerReplica(player)

	if not replica then
		return false
	end

	local pathKeys = GetPathKeys(arrayPath)
	local success, result = pcall(replica.TableRemove, replica, pathKeys, index)
	if not success then
		warn(`[PlayerState] RemoveFromArray operation failed for {player.Name}: {result}`)
		return false
	end

	return success
end

function PlayerState.UpdateArrayItem(player: Player, arrayPath: ArrayPath, index: number, newItem: any): boolean
	local replica = _GetPlayerReplica(player)

	if not replica then
		return false
	end

	local pathKeys = GetPathKeys(arrayPath)
	table.insert(pathKeys, index)

	local success = pcall(replica.Set, replica, pathKeys, newItem)
	if not success then
		warn(`[PlayerState] UpdateArrayItem operation failed for {player.Name}`)
		return false
	end

	return true
end

function PlayerState.SetInDict(player: Player, dictPath: DictPath, key: string | number, value: any): boolean
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

	currentDict[stringKey] = value

	local pathKeys = GetPathKeys(dictPath)
	local success = pcall(replica.Set, replica, pathKeys, currentDict)

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

	return currentDict[stringKey]
end

function PlayerState.RemoveFromDict(player: Player, dictPath: DictPath, key: string | number): boolean
	local replica = _GetPlayerReplica(player)

	if not replica then
		return false
	end

	local stringKey = if typeof(key) == "number" then tostring(key) else key

	local currentDict = PlayerState.GetPath(player, dictPath) or {}

	if typeof(currentDict) ~= "table" then
		warn(`[PlayerState] RemoveFromDict failed - path is not a dictionary for {player.Name}`)
		return false
	end

	currentDict[stringKey] = nil

	local pathKeys = GetPathKeys(dictPath)
	local success = pcall(replica.Set, replica, pathKeys, currentDict)

	if not success then
		warn(`[PlayerState] RemoveFromDict operation failed for {player.Name}`)
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
	if not _ValidatePlayer(player) then
		local profile = profiles[player]
		if profile and _ValidateProfile(profile) then
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
	return _ValidatePlayer(player) and _ValidateProfile(profiles[player]) and _ValidateReplica(replicas[player])
end

function PlayerState.ClearPathCache(): ()
	table.clear(pathCache)
	pathCacheSize = 0
end

function PlayerState.GetOfflineData(userId: number): PlayerData?
	if not userId or userId < 1 then
		warn("[PlayerState] Invalid userId for GetOfflineData")
		return nil
	end

	for _, player in (Players:GetPlayers()) do
		if player.UserId == userId then
			return PlayerState.GetAll(player)
		end
	end

	local profileKey = CONFIG.Profile.Key .. "_" .. tostring(userId)
	local offlineProfile = profileStore:GetAsync(profileKey)

	if offlineProfile then
		return offlineProfile.Data
	end

	return nil
end

function PlayerState.SetOfflineData(userId: number, path: string, value: any): boolean
	if not userId or userId < 1 then
		warn("[PlayerState] Invalid userId for SetOfflineData")
		return false
	end

	for _, player in Players do
		if player.UserId == userId then
			return PlayerState.SetPath(player, path, value)
		end
	end

	local profileKey = CONFIG.Profile.Key .. "_" .. tostring(userId)

	local success, profile = pcall(function()
		return profileStore:StartSessionAsync(profileKey)
	end)

	if not success or not profile then
		warn(`[PlayerState] Failed to start profile session for offline user {userId}`)
		return false
	end

	profile:AddUserId(userId)
	profile:Reconcile()

	_CleanData(profile.Data, CONFIG.Profile.Template)

	local success = pcall(function()
		if not string.find(path, ".", 1, true) then
			profile.Data[path] = value
		else
			local pathKeys = GetPathKeys(path)
			local current = profile.Data

			for i = 1, #pathKeys - 1 do
				local key = pathKeys[i]

				if not current[key] then
					current[key] = {}
				end

				current = current[key]
			end

			current[pathKeys[#pathKeys]] = value
		end
	end)

	if not success then
		warn(`[PlayerState] Failed to set offline data for user {userId} at path {path}`)
		profile:EndSession()
		return false
	end

	profile:Save()
	profile:EndSession()

	print(`[PlayerState] Successfully set offline data for user {userId}: {path} = {value}`)
	return true
end

function PlayerState.WipePlayerData(player: Player): boolean
	if not _ValidatePlayer(player) then
		warn("[PlayerState] Cannot wipe data - invalid player")
		return false
	end

	local profile = profiles[player]
	if not _ValidateProfile(profile) then
		warn(`[PlayerState] No valid profile found for {player.Name}`)
		return false
	end

	local success = pcall(function()
		table.clear(profile.Data)
		for key, value in CONFIG.Profile.Template do
			profile.Data[key] = value
		end
	end)

	if not success then
		warn(`[PlayerState] Failed to wipe data for {player.Name}`)
		return false
	end

	local replica = replicas[player]
	if _ValidateReplica(replica) then
		pcall(replica.SetValues, replica, {}, profile.Data)
	end

	print(`[PlayerState] Successfully wiped data for {player.Name}`)
	
	if player:IsDescendantOf(Players) then
		player:Kick("Your data has been reset. Please rejoin to continue.")
	end
	
	return true
end

function PlayerState.WipeOfflinePlayerData(userId: number): boolean
	if not userId or userId < 1 then
		warn("[PlayerState] Invalid userId for WipeOfflinePlayerData")
		return false
	end

	for _, player in (Players:GetPlayers()) do
		if player.UserId == userId then
			return PlayerState.WipePlayerData(player)
		end
	end

	local profileKey = CONFIG.Profile.Key .. "_" .. tostring(userId)

	local success, profile = pcall(function()
		return profileStore:StartSessionAsync(profileKey)
	end)

	if not success or not profile then
		warn(`[PlayerState] Failed to start profile session for offline userId {userId}`)
		return false
	end

	profile:AddUserId(userId)
	profile:Reconcile()

	_CleanData(profile.Data, CONFIG.Profile.Template)

	local success = pcall(function()
		for key, value in CONFIG.Profile.Template do
			profile.Data[key] = value
		end
	end)

	if not success then
		warn(`[PlayerState] Failed to wipe offline data for userId {userId}`)
		profile:EndSession()
		return false
	end

	profile:Save()
	profile:EndSession()

	print(`[PlayerState] Successfully wiped offline data for userId {userId}`)
	return true
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

-- ========== LEADERBOARD VALIDATION ==========
local function IsStatTracked(statName: string): boolean
	if not CONFIG.Leaderboard or not CONFIG.Leaderboard.TrackedStats then
		return false
	end

	for _, trackedStat in CONFIG.Leaderboard.TrackedStats do
		if trackedStat == statName then
			return true
		end
	end
	return false
end

function PlayerState.UpdateLeaderboard(player: Player, statName: string, score: number): boolean
	if not CONFIG.Leaderboard or not CONFIG.Leaderboard.Enabled then
		warn("[PlayerState] Leaderboard functionality is disabled")
		return false
	end

	if not IsStatTracked(statName) then
		warn(`[PlayerState] Stat "{statName}" is not configured as a tracked leaderboard stat. Add it to CONFIG.Leaderboard.TrackedStats`)
		return false
	end

	if not _ValidatePlayer(player) then
		return false
	end

	local store = leaderboardStores[statName]
	if not store then
		warn(`[PlayerState] No leaderboard store found for stat: {statName}`)
		return false
	end

	local success = pcall(function()
		store:SetAsync(tostring(player.UserId), score)
	end)

	if not success then
		warn(`[PlayerState] Failed to update leaderboard for {player.Name} on stat {statName}`)
		return false
	end

	if leaderboardCache[statName] then
		leaderboardCache[statName] = nil
	end

	return true
end


function PlayerState.GetLeaderboard(statName: string, limit: number): {LeaderboardEntry}
	if not CONFIG.Leaderboard or not CONFIG.Leaderboard.Enabled then
		return {}
	end

	if not IsStatTracked(statName) then
		warn(`[PlayerState] Stat "{statName}" is not configured as a tracked leaderboard stat. Add it to CONFIG.Leaderboard.TrackedStats`)
		return {}
	end

	local store = leaderboardStores[statName]
	if not store then
		warn(`[PlayerState] No leaderboard store found for stat: {statName} in PlayerStateConfig (Server.Leaderboard)`)
		return {}
	end

	local cached = leaderboardCache[statName]
	local currentTime = os.time()

	if cached and (currentTime - cached.lastUpdate) < 15 then
		return table.move(cached.data, 1, math.min(limit, #cached.data), 1, {})
	end

	local success, pages = pcall(function()
		return store:GetSortedAsync(false, math.max(limit, 100))
	end)

	if not success then
		if cached then
			return table.move(cached.data, 1, math.min(limit, #cached.data), 1, {})
		end
		return {}
	end

	local topPlayers = {}
	local data = pages:GetCurrentPage()

	for i, entry in (data) do
		local userId = tonumber(entry.key)
		if userId then
			table.insert(topPlayers, {
				userId = userId,
				score = entry.value,
				rank = i
			})
		end
	end

	leaderboardCache[statName] = {
		data = topPlayers,
		lastUpdate = currentTime
	}

	return table.move(topPlayers, 1, math.min(limit, #topPlayers), 1, {})
end

function PlayerState.GetPlayerRank(player: Player, statName: string): number?
	if not CONFIG.Leaderboard or not CONFIG.Leaderboard.Enabled then
		return nil
	end

	if not IsStatTracked(statName) then
		warn(`[PlayerState] Stat "{statName}" is not configured as a tracked leaderboard stat. Add it to CONFIG.Leaderboard.TrackedStats`)
		return nil
	end

	if not _ValidatePlayer(player) then
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

	if batchOperations[player] then
		_ProcessBatchOperations(player)
		batchOperations[player] = nil
	end
	local scheduledThread = batchScheduled[player]
	if scheduledThread then
		task.cancel(scheduledThread)
		batchScheduled[player] = nil
	end

	_UpdatePlayerLeaderboard(player)

	if profiles[player] then
		profiles[player]:EndSession()
		profiles[player] = nil
	end

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

	for player in batchOperations do
		_ProcessBatchOperations(player)
	end

	if periodicUpdateThread then
		task.cancel(periodicUpdateThread)
	end

	_UpdateAllLeaderboards()

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