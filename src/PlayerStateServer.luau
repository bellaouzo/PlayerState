--!strict

--[[
	PlayerStateServer - Server-side player data access

	Documentation: https://playerstate.netlify.app/api/server/
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
local ListenerRegistry = require(script.Parent.Internal.Shared.ListenerRegistry)
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
local LegacyMigration = require(script.Parent.Internal.Server.LegacyMigration)
local DebugState = require(script.Parent.Internal.Server.DebugState)
local DataTypes = require(script.Parent.Internal.Shared.DataTypes)

export type PlayerData = typeof(DefaultData)
export type SharedSessionData = {[string]: any}

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
export type DataKey = DataTypes.DataKey
export type DataPath = DataTypes.DataPath
export type NumberPath = DataTypes.NumberPath
export type TablePath = DataTypes.TablePath
export type SharedKey = DataTypes.SharedKey
export type SharedPath = DataTypes.SharedPath
export type ChangeInfo = {
	action: "Set" | "SetValues" | "TableInsert" | "TableRemove",
	path: {any},
	index: number?,
}
export type ChangeCallback = (newValue: any, oldValue: any, info: ChangeInfo | {any}?) -> ()

export type BatchOperation = {
	path: DataPath,
	value: any,
}

export type BatchUpdateOperation = {
	path: NumberPath,
	operation: "Increment" | "Decrement",
	amount: number?,
}

export type LeaderboardEntry = {
	userId: number,
	score: number,
	rank: number,
}

export type MigrationResultInfo = LegacyMigration.MigrationResult

export type PlayerStateServer = {
	SaveData: (player: Player) -> boolean,
	Init: (player: Player, existingData: PlayerData?) -> boolean,
	Set: (player: Player, key: DataKey, value: any) -> boolean,
	Get: (player: Player, key: DataKey) -> any,
	SetPath: (player: Player, path: DataPath, value: any) -> boolean,
	GetPath: (player: Player, path: DataPath) -> any,
	OnChanged: (player: Player, pathOrKey: DataPath, callback: ChangeCallback) -> Connection?,
	SetValues: (player: Player, values: {[string]: any}) -> boolean,
	BatchSetValues: (player: Player, operations: {BatchOperation}) -> boolean,
	BatchUpdateValues: (player: Player, operations: {BatchUpdateOperation}) -> boolean,
	Increment: (player: Player, path: NumberPath, amount: number?) -> boolean,
	Decrement: (player: Player, path: NumberPath, amount: number?) -> boolean,
	FlushBatch: (player: Player) -> boolean,
	AddToArray: (player: Player, arrayPath: TablePath, item: any) -> boolean,
	RemoveFromArray: (player: Player, arrayPath: TablePath, index: number) -> boolean,
	UpdateArrayItem: (player: Player, arrayPath: TablePath, index: number, newItem: any) -> boolean,
	SetInDict: (player: Player, dictPath: TablePath, key: string | number, value: any) -> boolean,
	GetFromDict: (player: Player, dictPath: TablePath, key: string | number) -> any,
	RemoveFromDict: (player: Player, dictPath: TablePath, key: string | number) -> boolean,
	Clone: (value: any, deep: boolean?) -> any,
	GetReplica: (player: Player) -> ReplicaInstance?,
	GetProfile: (player: Player) -> ProfileStoreProfile?,
	GetAll: (player: Player) -> PlayerData?,
	GetOfflineData: (userId: number) -> PlayerData?,
	IsPlayerDataReady: (player: Player) -> boolean,
	ClearPathCache: () -> (),
	UpdateLeaderboard: (player: Player, statName: NumberPath, score: number) -> boolean,
	GetLeaderboard: (statName: NumberPath, topCount: number) -> {LeaderboardEntry},
	GetPlayerRank: (player: Player, statName: NumberPath) -> number?,
	SetOfflineData: (userId: number, path: DataPath, value: any) -> boolean,
	WipePlayerData: (player: Player) -> boolean,
	WipeOfflinePlayerData: (userId: number) -> boolean,
	SetShared: (key: SharedKey, value: any) -> boolean,
	GetShared: (key: SharedKey) -> any,
	SetSharedPath: (path: SharedPath, value: any) -> boolean,
	GetSharedPath: (path: SharedPath) -> any,
	SetSharedValues: (values: {[string]: any}) -> boolean,
	OnSharedChanged: (pathOrKey: SharedPath, callback: ChangeCallback) -> Connection?,
	GetSharedReplica: () -> ReplicaInstance?,
	GetSharedAll: () -> SharedSessionData?,
	IsSharedReady: () -> boolean,

	BeforeSave: BeforeSaveSignal,
	BeforeRelease: BeforeReleaseSignal,
	ProfileLoaded: ProfileLoadedSignal,
	ProfileUnloaded: ProfileUnloadedSignal,
	MigrationResult: MigrationResultSignal,
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
export type BeforeReleaseSignal = {
	Connect: (self: BeforeReleaseSignal, listener: (player: Player, data: PlayerData) -> ()) -> (Connection),
	Fire: (self: BeforeReleaseSignal, player: Player, data: PlayerData) -> (),
	GetListenerCount: (self: BeforeReleaseSignal) -> (number),
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
export type MigrationResultSignal = {
	Connect: (self: MigrationResultSignal, listener: (player: Player, result: MigrationResultInfo, data: PlayerData) -> ()) -> (Connection),
	Fire: (self: MigrationResultSignal, player: Player, result: MigrationResultInfo, data: PlayerData) -> (),
	GetListenerCount: (self: MigrationResultSignal) -> (number),
}

local CONFIG = Config.Server
local AUTO_CLONE_TABLES = CONFIG.AutoCloneTables
local RUNTIME_NON_PERSISTENT_ROOTS = DataUtils.ResolveRuntimeNonPersistentRoots(CONFIG.RuntimeNonPersistentRoots)
local SERVER_ONLY_ROOTS = DataUtils.ResolveServerOnlyRoots(CONFIG.ServerOnlyRoots)
local SERVER_ONLY_ROOT_LOOKUP: {[string]: boolean} = {}

for _, root in SERVER_ONLY_ROOTS do
	SERVER_ONLY_ROOT_LOOKUP[root] = true
end

local HAS_SERVER_ONLY = next(SERVER_ONLY_ROOT_LOOKUP) ~= nil
local SKIP_UNCHANGED_WRITES = CONFIG.SkipUnchangedWrites == true
local RUNTIME_ROOT_LOOKUP: {[string]: boolean} = {}

for _, root in RUNTIME_NON_PERSISTENT_ROOTS do
	if not string.find(root, ".", 1, true) then
		RUNTIME_ROOT_LOOKUP[root] = true
	end
end

local savesInFlight: {[any]: {[string]: any}} = DataUtils.PendingRuntimeCaptures

if CONFIG.Leaderboard and CONFIG.Leaderboard.SyncInterval and CONFIG.Leaderboard.SyncInterval < 60 then
	warn("[PlayerState] SyncInterval should be >= 60 seconds for optimal performance. Setting to 60.")

	CONFIG.Leaderboard.SyncInterval = 60
end

if CONFIG.Leaderboard then
	local lb = CONFIG.Leaderboard :: any
	if lb.FullLeaderboardWriteInterval == nil and type(lb.ReconcileInterval) == "number" then
		lb.FullLeaderboardWriteInterval = lb.ReconcileInterval
	end
	if type(lb.FullLeaderboardWriteInterval) == "number" and lb.FullLeaderboardWriteInterval > 0 and lb.FullLeaderboardWriteInterval < 60 then
		warn("[PlayerState] FullLeaderboardWriteInterval should be >= 60 seconds when enabled. Setting to 60.")
		lb.FullLeaderboardWriteInterval = 60
	end
end

local replicas: { [Player]: ReplicaInstance } = {}
local profiles: { [Player]: ProfileStoreProfile } = {}
local loadedProfileUserIds: {[Player]: number} = {}
local mutationBlockedByPlayer: {[Player]: boolean} = {}
local initInFlight: {[Player]: boolean} = {}
local releasingPlayers: {[Player]: boolean} = {}
local pendingReadyConnections: {[Player]: any} = {}
local reopenAttempts: {[Player]: number} = {}
local releasedPlayers: {[Player]: boolean} = {}
local endedProfiles: {[any]: boolean} = setmetatable({}, { __mode = "k" }) :: any
local playerRegistries: {[Player]: any} = {}
local dataWaiters: {[Player]: {[any]: boolean}} = {}
local loadedProfiles: {[any]: boolean} = setmetatable({}, { __mode = "k" }) :: any
local sharedRegistry: any = nil
local profileStore: ProfileStoreInstance
local leaderboardPeriodicStarted = false
local isShuttingDown = false

local MAX_REOPEN_ATTEMPTS = 3
local START_SESSION_TIMEOUT = 120
local RELEASE_FLAG_LIFETIME = 10

local BeforeSave = Signal.New() :: BeforeSaveSignal
local BeforeRelease = Signal.New() :: BeforeReleaseSignal
local ProfileLoaded = Signal.New() :: ProfileLoadedSignal
local ProfileUnloaded = Signal.New() :: ProfileUnloadedSignal
local MigrationResult = Signal.New() :: MigrationResultSignal

local PathCacheModule = CreatePathCache(CONFIG.MaxCacheSize)
local GetPathKeys = PathCacheModule.GetPathKeys

local function _FireReleaseHooks(player: Player, data: PlayerData)
	if releasedPlayers[player] then
		return
	end

	releasedPlayers[player] = true
	BeforeRelease:Fire(player, data)
	BeforeSave:Fire(player, data)
end

local function _EndProfileSession(profile: ProfileStoreProfile): ()
	if endedProfiles[profile] then
		return
	end

	endedProfiles[profile] = true
	profile:EndSession()
end

local function _DataForRoot(profile: ProfileStoreProfile, root: string): any
	local capture = savesInFlight[profile]
	if capture ~= nil and RUNTIME_ROOT_LOOKUP[root] == true then
		return capture
	end

	return profile.Data
end

local function _IsLeaderstatsPath(path: string): boolean
	return string.byte(path, 1) == 108 and (path == "leaderstats" or string.sub(path, 1, 12) == "leaderstats.")
end

local function _IsUnchangedPrimitive(current: any, value: any): boolean
	return current == value and typeof(value) ~= "table" and value == value
end

local function GetNestedValue(data: any, path: string): any
	local keys = GetPathKeys(path)
	return DataUtils.GetNestedValue(data, keys)
end

local function IsServerOnlyPath(path: string): boolean
	if not HAS_SERVER_ONLY or typeof(path) ~= "string" or path == "" then
		return false
	end

	local dotIndex = string.find(path, ".", 1, true)
	local root = if dotIndex then string.sub(path, 1, dotIndex - 1) else path

	return SERVER_ONLY_ROOT_LOOKUP[root] == true
end

local function IsServerOnlyRoot(root: string): boolean
	return SERVER_ONLY_ROOT_LOOKUP[root] == true
end

local function CloneForReplica(value: any): any
	if typeof(value) == "table" then
		return Utils.DeepClone(value)
	end

	return value
end

local function _ReplicaWrite(method: any, replica: any, ...: any): boolean
	local ok, result = pcall(method, replica, ...)
	return ok and result ~= false
end

local function _IsShuttingDown(): boolean
	return isShuttingDown or (ProfileService :: any).IsClosing == true
end

local function _ResolveCleanKeepRoots(): {string}
	local keepRoots: {string} = { "_Migration" }
	local seen: {[string]: boolean} = { _Migration = true }

	local function addRoot(path: any)
		if typeof(path) ~= "string" or path == "" then
			return
		end
		local dotIndex = string.find(path, ".", 1, true)
		local root = if dotIndex then string.sub(path, 1, dotIndex - 1) else path
		if not seen[root] then
			seen[root] = true
			table.insert(keepRoots, root)
		end
	end

	local legacyConfig = CONFIG.LegacyDataStore
	if typeof(legacyConfig) == "table" then
		local advanced = (legacyConfig :: any).advanced
		local marker = if typeof(advanced) == "table" then advanced.marker else nil
		if typeof(marker) == "table" then
			addRoot(marker.path)
		end
	end

	for _, root in RUNTIME_NON_PERSISTENT_ROOTS do
		addRoot(root)
	end

	return keepRoots
end

local CLEAN_KEEP_ROOTS = _ResolveCleanKeepRoots()

local LeaderboardModule = CreateLeaderboardModule(
	CONFIG,
	Validation.ValidatePlayer,
	Validation.ValidateReplica,
	function()
		return replicas
	end,
	GetNestedValue
)

local BatchModule = CreateBatchModule(
	CONFIG,
	GetPathKeys,
	Validation.ValidateReplica,
	function(player: Player)
		return replicas[player]
	end,
	function(player: Player, operations: {BatchOperation})
		if not CONFIG.Leaderboard or not CONFIG.Leaderboard.Enabled then
			return
		end

		local replica = replicas[player]
		if not replica then
			return
		end

		for _, op in operations do
			if LeaderboardModule.IsStatTracked(op.path) and typeof(op.value) == "number" then
				LeaderboardModule.UpdateReplicaLeaderboardScore(replica, op.path, op.value :: number)
			end
		end
	end
)

local PlayerDataToken = ReplicaServer.Token("PlayerData") :: any
local SharedSessionToken = ReplicaServer.Token("SharedSession") :: any

local sharedSessionTemplate = if typeof(CONFIG.SharedSession) == "table" then CONFIG.SharedSession else {}

local sharedReplica = ReplicaServer.New({
	Token = SharedSessionToken,
	Data = Utils.DeepClone(sharedSessionTemplate),
	Tags = { Name = "SharedSession" },
})
sharedReplica:Replicate()

profileStore = ProfileService.New(
	CONFIG.DataStore.Name,
	CONFIG.Profile.Template :: any
)

if CONFIG.DataStore.Scope == "Testing" then
	profileStore = profileStore.Mock
	print("[PlayerState] Testing Scope: Using ProfileStore with mock data")
end

LeaderboardModule.InitializeLeaderboards()

local PlayerState: PlayerStateServer = {} :: PlayerStateServer

local REMOTES_MODULES_FOLDER = script.Parent.Internal.Shared.Remotes
local REMOTE_REGISTRY_MODULE_NAME = "Registry"

local function _CollectRemoteModules(): {ModuleScript}
	local remoteModuleScripts: {ModuleScript} = {}

	for _, child in REMOTES_MODULES_FOLDER:GetChildren() do
		if child:IsA("ModuleScript") and child.Name ~= REMOTE_REGISTRY_MODULE_NAME then
			table.insert(remoteModuleScripts, child)
		end
	end

	table.sort(remoteModuleScripts, function(a: ModuleScript, b: ModuleScript): boolean
		return a.Name < b.Name
	end)

	return remoteModuleScripts
end

type RemoteModule = {
	SetupServer: ((playerState: PlayerStateServer) -> ())?,
}

local function _SetupRemoteModules(playerState: PlayerStateServer): ()
	for _, moduleScript in _CollectRemoteModules() do
		local remoteModule: RemoteModule? = require(moduleScript) :: any
		if typeof(remoteModule) == "table" then
			local setupServer = remoteModule.SetupServer
			if typeof(setupServer) == "function" then
				setupServer(playerState)
			end
		end
	end
end

local function _SetupRuntimeSaveProtection(profile: ProfileStoreProfile): ()
	DataUtils.AttachRuntimeSaveProtection(profile, RUNTIME_NON_PERSISTENT_ROOTS, (ProfileService :: any).OnError)
end

local function _WakeDataWaiters(player: Player): ()
	local waiters = dataWaiters[player]
	if not waiters then
		return
	end

	dataWaiters[player] = nil
	for waiter in waiters do
		if not waiter.done then
			waiter.done = true
			task.spawn(waiter.thread)
		end
	end
end

local function _WaitForPlayerData(player: Player, maxWaitTime: number?): boolean
	if PlayerState.IsPlayerDataReady(player) then
		return true
	end

	local waitTime: number = maxWaitTime or CONFIG.DataWaitTimeout or 10
	local deadline = os.clock() + waitTime

	while not PlayerState.IsPlayerDataReady(player) do
		if player.Parent ~= Players then
			return false
		end

		local remaining = deadline - os.clock()
		if remaining <= 0 then
			warn(`[PlayerState] Timeout waiting for {player.Name}'s data to load`)
			return false
		end

		local waiters = dataWaiters[player]
		if not waiters then
			waiters = {}
			dataWaiters[player] = waiters
		end

		local waiter = { thread = coroutine.running(), done = false }
		waiters[waiter] = true

		task.delay(remaining, function()
			if waiter.done then
				return
			end
			waiter.done = true
			waiters[waiter] = nil
			if dataWaiters[player] == waiters and next(waiters) == nil then
				dataWaiters[player] = nil
			end
			task.spawn(waiter.thread)
		end)

		coroutine.yield()
	end

	return true
end

local function _GetPlayerProfile(player: Player): ProfileStoreProfile?
	if not Validation.ValidatePlayer(player) then
		return nil
	end

	local profile = profiles[player]
	if Validation.ValidateProfile(profile) then
		return profile
	end

	if not _WaitForPlayerData(player) then
		return nil
	end

	profile = profiles[player]
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

local function _ResolveEffectiveProfileUserId(player: Player, viewedUserId: number): number
	if viewedUserId == 0 then
		return player.UserId
	end

	if not RunService:IsStudio() then
		warn("[PlayerState] CONFIG.ViewedUser.ViewedUserId is Studio-only. Falling back to player's own profile.")
		return player.UserId
	end

	return viewedUserId
end

local function _CanMutatePlayerData(player: Player): boolean
	if mutationBlockedByPlayer[player] ~= true then
		return true
	end

	warn(`[PlayerState] Blocked write for {player.Name} while viewing user {loadedProfileUserIds[player]} (ReadOnly mode).`)
	return false
end

local function _GetWritableReplica(player: Player): ReplicaInstance?
	if not _CanMutatePlayerData(player) then
		return nil
	end

	return _GetPlayerReplica(player)
end

local function _GetWritableState(player: Player): (ProfileStoreProfile?, ReplicaInstance?)
	if not Validation.ValidatePlayer(player) then
		return nil, nil
	end

	if not _CanMutatePlayerData(player) then
		return nil, nil
	end

	local profile = profiles[player]
	local replica = replicas[player]
	if Validation.ValidateProfile(profile) and Validation.ValidateReplica(replica) then
		return profile, replica
	end

	if not _WaitForPlayerData(player) then
		return nil, nil
	end

	profile = profiles[player]
	replica = replicas[player]

	if Validation.ValidateProfile(profile) and Validation.ValidateReplica(replica) then
		return profile, replica
	end

	warn(`[PlayerState] No valid profile or replica found for {player.Name}`)
	return nil, nil
end

local function _ValidateSharedPathOrKey(pathOrKey: string, apiName: string): boolean
	if type(pathOrKey) ~= "string" then
		warn(`[PlayerState] {apiName} pathOrKey must be a string`)
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

	if initInFlight[player] then
		warn(`[PlayerState] Init already running for {player.Name}`)
		return false
	end

	initInFlight[player] = true

	local viewedUserId, viewedReadOnly = _ResolveViewedUserSettings()
	local effectiveProfileUserId = _ResolveEffectiveProfileUserId(player, viewedUserId)
	local profileKey = CONFIG.Profile.Key .. "_" .. effectiveProfileUserId
	local isViewingAnotherUser = effectiveProfileUserId ~= player.UserId
	local isMutationBlocked = isViewingAnotherUser and viewedReadOnly

	if isViewingAnotherUser then
		local viewedModeLabel = if viewedReadOnly then "read-only" else "writable"
		local viewedUserDisplay = tostring(effectiveProfileUserId)
		local ok, viewedUsername = pcall(Players.GetNameFromUserIdAsync, Players, effectiveProfileUserId :: any)
		if ok and type(viewedUsername) == "string" then
			viewedUserDisplay = `{viewedUsername} ({effectiveProfileUserId})`
		end

		print(`[PlayerState] {player.Name} is loading viewed profile {viewedUserDisplay} ({viewedModeLabel}).`)
	end

	local function isLoadCancelled(): boolean
		return _IsShuttingDown() or releasingPlayers[player] == true or player.Parent ~= Players
	end

	local function attach(profile: ProfileStoreProfile)
		profiles[player] = profile
		loadedProfileUserIds[player] = effectiveProfileUserId
		mutationBlockedByPlayer[player] = isMutationBlocked

		_SetupRuntimeSaveProtection(profile)

		if replicas[player] then
			pcall(replicas[player].Destroy, replicas[player])
		end
		local replica = ReplicaServer.New({
			Token = PlayerDataToken,
			Data = DataUtils.CloneWithoutRoots(profile.Data, SERVER_ONLY_ROOTS),
			Tags = { UserId = player.UserId, PlayerName = player.Name },
		})
		replicas[player] = replica

		if CONFIG.Leaderboard.Enabled then
			LeaderboardModule.EnqueueTrackedStatsFromReplica(replica)
		end

		local previousReadyConnection = pendingReadyConnections[player]
		if previousReadyConnection then
			pendingReadyConnections[player] = nil
			previousReadyConnection:Disconnect()
		end

		if ReplicaServer.ReadyPlayers[player] then
			replica:Subscribe(player)
		else
			local conn: typeof(ReplicaServer.NewReadyPlayer:Connect(function(_: Player) end))
			conn = ReplicaServer.NewReadyPlayer:Connect(function(p: Player)
				if p ~= player then
					return
				end

				conn:Disconnect()
				if pendingReadyConnections[player] == conn then
					pendingReadyConnections[player] = nil
				end

				if replica:IsActive() then
					replica:Subscribe(player)
				end
			end)
			pendingReadyConnections[player] = conn
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
			GetNestedValue,
			CONFIG.LeaderstatsOrder
		)

		if CONFIG.Leaderboard.Enabled then
			if not leaderboardPeriodicStarted then
				leaderboardPeriodicStarted = true
				LeaderboardModule.StartPeriodicUpdates()
			else
				task.spawn(LeaderboardModule.SyncReplicaLeaderboardRanks, player, replica)
			end
		end

		local registry = playerRegistries[player]
		if registry then
			registry:Bind(replica)
		end

		loadedProfiles[profile] = true
		ProfileLoaded:Fire(player, profile.Data)

		_WakeDataWaiters(player)
	end

	local function openSession(): ProfileStoreProfile?
		local sessionStart = os.clock()
		local ok, profOrErr = pcall(function()
			return profileStore:StartSessionAsync(profileKey, {
				Cancel = function(): boolean
					return isLoadCancelled() or os.clock() - sessionStart >= START_SESSION_TIMEOUT
				end,
			})
		end)

		if not ok or not profOrErr then
			if not isLoadCancelled() then
				warn(`[PlayerState] StartSession failed for {player.Name}: {profOrErr}`)
			end
			return nil
		end

		local prof: ProfileStoreProfile = profOrErr
		local migrationResult: MigrationResultInfo

		local setupOk, setupErr = pcall(function()
			prof:AddUserId(player.UserId)
			prof:Reconcile()

			if CONFIG.CleanExtraFields then
				DataUtils.CleanData(prof.Data, CONFIG.Profile.Template, CLEAN_KEEP_ROOTS)
			end

			migrationResult = LegacyMigration.TryMigrateProfile(
				prof.Data,
				CONFIG.Profile.Template,
				effectiveProfileUserId,
				player,
				CONFIG.LegacyDataStore,
				RUNTIME_NON_PERSISTENT_ROOTS
			)

			if migrationResult.applied and CONFIG.CleanExtraFields then
				DataUtils.CleanData(prof.Data, CONFIG.Profile.Template, CLEAN_KEEP_ROOTS)
			end

			DataUtils.RemoveRuntimeRoots(prof.Data, RUNTIME_NON_PERSISTENT_ROOTS)
			DataUtils.ApplyRuntimeRootDefaults(prof.Data, CONFIG.Profile.Template, RUNTIME_NON_PERSISTENT_ROOTS)
		end)

		if not setupOk then
			warn(`[PlayerState] Profile setup failed for {player.Name}: {setupErr}`)
			pcall(prof.EndSession, prof)
			return nil
		end

		MigrationResult:Fire(player, migrationResult, prof.Data)

		return prof
	end

	local bindProfileHooks: (profile: ProfileStoreProfile) -> ()

	local function bindMessageHandler(profile: ProfileStoreProfile)
		profile:MessageHandler(function(message, processed)
			if profiles[player] ~= profile or not profile:IsActive() then
				return
			end

			if mutationBlockedByPlayer[player] == true then
				return
			end

			if typeof(message) ~= "table" then
				return
			end

			if message.Type == "SetData" then
				if not PlayerState.SetPath(player, message.Path, message.Value) then
					warn(`[PlayerState] Offline SetData message for "{message.Path}" could not be applied for {player.Name}`)
				end
				processed()
			elseif message.Type == "WipeData" then
				local template: {[string]: unknown} = CONFIG.Profile.Template :: any
				local data = profile.Data :: any
				local markerState = DataWipe.CaptureMigrationMarker(data, CONFIG)

				for key in data do
					if template[key] == nil and markerState.roots[key] == nil and replicas[player] then
						data[key] = nil
						local replica = replicas[player]
						if replica and (replica.Data :: any)[key] ~= nil then
							_ReplicaWrite(replica.Set, replica, { key }, nil)
						end
					end
				end

				for key, value in template do
					if key ~= "leaderstats" then
						PlayerState.Set(player, key :: string, CloneForReplica(value))
					end
				end
				DataWipe.RestoreMigrationMarker(profile.Data, markerState)
				processed()
			end
		end)
	end

	bindProfileHooks = function(profile: ProfileStoreProfile)
		profile.OnSessionEnd:Connect(function()
			if loadedProfiles[profile] then
				loadedProfiles[profile] = nil
				ProfileUnloaded:Fire(player, profile.Data)
			end

			if _IsShuttingDown() or releasingPlayers[player] or profiles[player] ~= profile then
				return
			end

			task.delay(2, function()
				if _IsShuttingDown() or releasingPlayers[player] or not player:IsDescendantOf(Players) then
					return
				end

				if profiles[player] ~= profile then
					return
				end

				local attempts = (reopenAttempts[player] or 0) + 1
				reopenAttempts[player] = attempts
				if attempts > MAX_REOPEN_ATTEMPTS then
					player:Kick("Profile session ended - rejoin to continue playing")
					return
				end

				local newProfile = openSession()

				if newProfile then
					if _IsShuttingDown() or releasingPlayers[player] or not player:IsDescendantOf(Players) then
						pcall(newProfile.EndSession, newProfile)
						return
					end

					bindProfileHooks(newProfile)
					attach(newProfile)
					bindMessageHandler(newProfile)
				elseif player:IsDescendantOf(Players) and not _IsShuttingDown() then
					player:Kick("Profile session ended - rejoin to continue playing")
				end
			end)
		end)
	end

	local profile = openSession()
	if not profile then
		initInFlight[player] = nil
		if player:IsDescendantOf(Players) and not _IsShuttingDown() then
			player:Kick("Failed to load data - please rejoin")
		end

		return false
	end

	bindProfileHooks(profile)

	if player:IsDescendantOf(Players) and not releasingPlayers[player] then
		attach(profile)
		bindMessageHandler(profile)
	else
		profile:EndSession()
		initInFlight[player] = nil

		return false
	end

	initInFlight[player] = nil
	return true
end


local function _FlushPendingBatch(player: Player): ()
	if BatchModule.HasPendingBatch(player) then
		BatchModule.FlushBatch(player)
	end
end

local function _ReplicaParentExists(replica: ReplicaInstance, pathKeys: {string}): boolean
	local node: any = replica.Data
	for i = 1, #pathKeys - 1 do
		node = node[pathKeys[i]]
		if typeof(node) ~= "table" then
			return false
		end
	end

	return true
end

local function _GetPlayerRegistry(player: Player, replica: ReplicaInstance): any
	local registry = playerRegistries[player]
	if registry then
		return registry
	end

	registry = ListenerRegistry.new({
		getPathKeys = GetPathKeys,
		readValue = function(pathKeys: {string}, pathOrKey: string): any
			if #pathKeys > 0 and Validation.ValidatePlayer(player) then
				local profile = profiles[player]
				if Validation.ValidateProfile(profile) then
					local data: any = (profile :: ProfileStoreProfile).Data
					local capture = savesInFlight[profile]
					if capture ~= nil and RUNTIME_ROOT_LOOKUP[pathKeys[1]] == true then
						data = capture
					end

					local result = DataUtils.GetNestedValue(data, pathKeys)
					if AUTO_CLONE_TABLES and typeof(result) == "table" then
						return Utils.DeepClone(result)
					end

					return result
				end
			end

			return PlayerState.GetPath(player, pathOrKey)
		end,
	})
	playerRegistries[player] = registry
	registry:Bind(replica)

	return registry
end

local function _GetSharedRegistry(): any
	if sharedRegistry then
		return sharedRegistry
	end

	sharedRegistry = ListenerRegistry.new({
		getPathKeys = GetPathKeys,
		readValue = function(_pathKeys: {string}, pathOrKey: string): any
			return PlayerState.GetSharedPath(pathOrKey)
		end,
	})
	sharedRegistry:Bind(sharedReplica)

	return sharedRegistry
end

local function _SetPathKeysInternal(player: Player, profile: ProfileStoreProfile, replica: ReplicaInstance, path: ValuePath, pathKeys: {string}, value: any): boolean
	if _IsLeaderstatsPath(path) then
		warn(`[PlayerState] Cannot directly modify leaderstats path "{path}". Change the actual data source that the leaderstat references instead.`)
		return false
	end

	local keyCount = #pathKeys
	local root = pathKeys[1]

	if HAS_SERVER_ONLY and SERVER_ONLY_ROOT_LOOKUP[root] == true then
		DataUtils.SetNestedValue(profile.Data, pathKeys, value)
		return true
	end

	local shouldSyncLeaderboard = typeof(value) == "number" and LeaderboardModule.IsStatTracked(path)

	local data: any = profile.Data
	local capture = savesInFlight[profile]
	if capture ~= nil and RUNTIME_ROOT_LOOKUP[root] == true then
		data = capture
	end

	if keyCount == 1 then
		if SKIP_UNCHANGED_WRITES and _IsUnchangedPrimitive(data[root], value) then
			return true
		end

		_FlushPendingBatch(player)

		local previousValue = data[root]
		data[root] = value

		if not _ReplicaWrite(replica.Set, replica, {root}, CloneForReplica(value)) then
			data[root] = previousValue
			warn(`[PlayerState] SetPath operation failed for {player.Name}`)
			return false
		end

		if shouldSyncLeaderboard then
			LeaderboardModule.UpdateReplicaLeaderboardScore(replica, path, value :: number)
		end

		return true
	end

	if SKIP_UNCHANGED_WRITES and _IsUnchangedPrimitive(DataUtils.GetNestedValue(data, pathKeys), value) then
		return true
	end

	_FlushPendingBatch(player)

	local node: any = replica.Data
	local missingIndex: number? = nil

	for i = 1, keyCount - 1 do
		local child = node[pathKeys[i]]
		if child == nil then
			missingIndex = i
			break
		end
		if typeof(child) ~= "table" then
			warn(`[PlayerState] SetPath operation failed for {player.Name}`)
			return false
		end
		node = child
	end

	local lastKey = pathKeys[keyCount]
	local profileNode: any = data
	local profileMissingIndex: number? = nil
	for i = 1, keyCount - 1 do
		local child = profileNode[pathKeys[i]]
		if typeof(child) ~= "table" then
			profileMissingIndex = i
			break
		end
		profileNode = child
	end

	local previousValue: any = nil
	local previousBranch: any = nil
	if profileMissingIndex then
		previousBranch = profileNode[pathKeys[profileMissingIndex]]
		local createdNode: any = profileNode
		for i = profileMissingIndex, keyCount - 1 do
			local created = {}
			createdNode[pathKeys[i]] = created
			createdNode = created
		end
		createdNode[lastKey] = value
	else
		previousValue = profileNode[lastKey]
		profileNode[lastKey] = value
	end

	local replicated
	if missingIndex then
		local subtree = CloneForReplica(value)
		for i = keyCount, missingIndex + 1, -1 do
			subtree = { [pathKeys[i]] = subtree }
		end

		replicated = _ReplicaWrite(replica.Set, replica, table.move(pathKeys, 1, missingIndex, 1, {}), subtree)
	else
		replicated = _ReplicaWrite(replica.Set, replica, table.clone(pathKeys), CloneForReplica(value))
	end

	if not replicated then
		if profileMissingIndex then
			profileNode[pathKeys[profileMissingIndex]] = previousBranch
		else
			profileNode[lastKey] = previousValue
		end
		warn(`[PlayerState] SetPath operation failed for {player.Name}`)
		return false
	end

	if shouldSyncLeaderboard then
		LeaderboardModule.UpdateReplicaLeaderboardScore(replica, path, value :: number)
	end

	return true
end

local function _SetPathInternal(player: Player, profile: ProfileStoreProfile, replica: ReplicaInstance, path: ValuePath, value: any): boolean
	return _SetPathKeysInternal(player, profile, replica, path, GetPathKeys(path), value)
end

function PlayerState.Set(player: Player, key: string, value: any): boolean
	local profile, replica = _GetWritableState(player)
	if not profile or not replica then
		return false
	end

	if string.find(key, ".", 1, true) then
		warn(`[PlayerState] Detected path syntax in Set() call. Use SetPath() instead for nested paths like "{key}"`)
		return false
	end

	if _IsLeaderstatsPath(key) then
		warn(`[PlayerState] Cannot directly modify leaderstats. Change the actual data source that the leaderstat references instead.`)
		return false
	end

	local data = profile.Data :: any

	if IsServerOnlyRoot(key) then
		data[key] = value
		return true
	end

	local capture = savesInFlight[profile]
	if capture ~= nil and RUNTIME_ROOT_LOOKUP[key] == true then
		data = capture
	end

	if SKIP_UNCHANGED_WRITES and _IsUnchangedPrimitive(data[key], value) then
		return true
	end

	_FlushPendingBatch(player)

	local previousValue = data[key]
	data[key] = value

	if not _ReplicaWrite(replica.Set, replica, {key}, CloneForReplica(value)) then
		data[key] = previousValue
		warn(`[PlayerState] Set operation failed for {player.Name}`)
		return false
	end

	if typeof(value) == "number" and LeaderboardModule.IsStatTracked(key) then
		LeaderboardModule.UpdateReplicaLeaderboardScore(replica, key, value :: number)
	end

	return true
end

function PlayerState.Get(player: Player, key: string): any
	if not player or player.Parent ~= Players then
		return nil
	end

	local profile = _GetPlayerProfile(player)
	if not profile then
		return nil
	end

	local data: any = profile.Data
	local capture = savesInFlight[profile]
	if capture ~= nil and RUNTIME_ROOT_LOOKUP[key] == true then
		data = capture
	end

	local value = data[key]

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
	local profile, replica = _GetWritableState(player)
	if not profile or not replica then
		return false
	end

	return _SetPathInternal(player, profile, replica, path, value)
end

function PlayerState.GetPath(player: Player, path: ValuePath): any
	local profile = _GetPlayerProfile(player)
	if not profile then
		return nil
	end

	local result
	local dotIndex = string.find(path, ".", 1, true)
	local data: any = profile.Data
	local capture = savesInFlight[profile]
	if capture ~= nil and RUNTIME_ROOT_LOOKUP[if dotIndex then string.sub(path, 1, dotIndex - 1) else path] == true then
		data = capture
	end

	if not dotIndex then
		result = data[path]
	else
		result = GetNestedValue(data, path)
	end

	if AUTO_CLONE_TABLES and typeof(result) == "table" then
		return Utils.DeepClone(result)
	end

	return result
end

function PlayerState.OnChanged(player: Player, pathOrKey: string, callback: ChangeCallback): Connection?
	if not Validation.ValidatePlayer(player) then
		return nil
	end

	if type(pathOrKey) ~= "string" then
		warn("[PlayerState] OnChanged pathOrKey must be a string")
		return nil
	end

	if type(callback) ~= "function" then
		warn("[PlayerState] OnChanged callback must be a function")
		return nil
	end

	local replica = _GetPlayerReplica(player)
	if not replica then
		return nil
	end

	return _GetPlayerRegistry(player, replica):Connect(pathOrKey, callback)
end

function PlayerState.SetShared(key: string, value: any): boolean
	if not _ValidateSharedPathOrKey(key, "SetShared") then
		return false
	end

	if string.find(key, ".", 1, true) then
		warn(`[PlayerState] Detected path syntax in SetShared() call. Use SetSharedPath() instead for nested paths like "{key}"`)
		return false
	end

	if not _ReplicaWrite(sharedReplica.Set, sharedReplica, {key}, CloneForReplica(value)) then
		warn("[PlayerState] SetShared operation failed")
		return false
	end

	return true
end

function PlayerState.GetShared(key: string): any
	if not _ValidateSharedPathOrKey(key, "GetShared") then
		return nil
	end

	if string.find(key, ".", 1, true) then
		warn(`[PlayerState] Detected path syntax in GetShared() call. Use GetSharedPath() instead for nested paths like "{key}"`)
		return nil
	end

	local value = (sharedReplica.Data :: any)[key]

	if AUTO_CLONE_TABLES and typeof(value) == "table" then
		return Utils.DeepClone(value)
	end

	return value
end

function PlayerState.SetSharedPath(path: ValuePath, value: any): boolean
	if not _ValidateSharedPathOrKey(path, "SetSharedPath") then
		return false
	end

	local pathKeys = if string.find(path, ".", 1, true) then table.clone(GetPathKeys(path)) else {path}
	if not _ReplicaWrite(sharedReplica.Set, sharedReplica, pathKeys, CloneForReplica(value)) then
		warn("[PlayerState] SetSharedPath operation failed")
		return false
	end

	return true
end

function PlayerState.GetSharedPath(path: ValuePath): any
	if not _ValidateSharedPathOrKey(path, "GetSharedPath") then
		return nil
	end

	local result
	if not string.find(path, ".", 1, true) then
		result = (sharedReplica.Data :: any)[path]
	else
		result = GetNestedValue(sharedReplica.Data, path)
	end

	if AUTO_CLONE_TABLES and typeof(result) == "table" then
		return Utils.DeepClone(result)
	end

	return result
end

function PlayerState.SetSharedValues(values: {[string]: any}): boolean
	if typeof(values) ~= "table" then
		warn("[PlayerState] SetSharedValues values must be a table")
		return false
	end

	local replicatedValues: {[string]: any} = {}
	for key, value in values do
		replicatedValues[key] = CloneForReplica(value)
	end

	if not _ReplicaWrite(sharedReplica.SetValues, sharedReplica, {}, replicatedValues) then
		warn("[PlayerState] SetSharedValues operation failed")
		return false
	end

	return true
end

function PlayerState.OnSharedChanged(pathOrKey: string, callback: ChangeCallback): Connection?
	if not _ValidateSharedPathOrKey(pathOrKey, "OnSharedChanged") then
		return nil
	end

	if type(callback) ~= "function" then
		warn("[PlayerState] OnSharedChanged callback must be a function")
		return nil
	end

	return _GetSharedRegistry():Connect(pathOrKey, callback)
end

function PlayerState.SetValues(player: Player, values: {[string]: any}): boolean
	local profile, replica = _GetWritableState(player)
	if not profile or not replica then
		return false
	end

	local replicatedValues: {[string]: any} = {}

	for key, _ in values do
		if _IsLeaderstatsPath(key) then
			warn(`[PlayerState] Cannot directly modify leaderstats key "{key}" in SetValues. Change the actual data source that the leaderstat references instead.`)
			return false
		end
	end

	local data = profile.Data :: any
	local capture = savesInFlight[profile]
	local previousValues: {[string]: any} = {}

	for key, value in values do
		local target = if capture ~= nil and RUNTIME_ROOT_LOOKUP[key] == true then capture else data
		previousValues[key] = target[key]
		target[key] = value

		if not IsServerOnlyRoot(key) then
			replicatedValues[key] = CloneForReplica(value)
		end
	end

	if not next(replicatedValues) then
		return true
	end

	_FlushPendingBatch(player)

	if not _ReplicaWrite(replica.SetValues, replica, {}, replicatedValues) then
		for key in replicatedValues do
			local target = if capture ~= nil and RUNTIME_ROOT_LOOKUP[key] == true then capture else data
			target[key] = previousValues[key]
		end
		warn(`[PlayerState] SetValues operation failed for {player.Name}`)
		return false
	end

	for key, value in replicatedValues do
		if typeof(value) == "number" and LeaderboardModule.IsStatTracked(key) then
			LeaderboardModule.UpdateReplicaLeaderboardScore(replica, key, value :: number)
		end
	end

	return true
end

local function _BatchSetValuesInternal(player: Player, profile: ProfileStoreProfile, operations: {BatchOperation}): boolean
	for _, operation in operations do
		if _IsLeaderstatsPath(operation.path) then
			warn(`[PlayerState] Cannot directly modify leaderstats path "{operation.path}" in BatchSetValues. Change the actual data source that the leaderstat references instead.`)
			return false
		end
	end

	for _, operation in operations do
		local pathKeys = GetPathKeys(operation.path)
		DataUtils.SetNestedValue(_DataForRoot(profile, pathKeys[1]), pathKeys, operation.value)

		if not IsServerOnlyPath(operation.path) then
			BatchModule.ScheduleBatchOperation(player, {
				path = operation.path,
				value = CloneForReplica(operation.value),
			})
		end
	end

	return true
end

function PlayerState.BatchSetValues(player: Player, operations: {BatchOperation}): boolean
	if not Validation.ValidatePlayer(player) then
		return false
	end

	local profile, replica = _GetWritableState(player)
	if not profile or not replica then
		return false
	end

	return _BatchSetValuesInternal(player, profile, operations)
end

function PlayerState.BatchUpdateValues(player: Player, operations: {BatchUpdateOperation}): boolean
	if not Validation.ValidatePlayer(player) then
		return false
	end

	local profile, replica = _GetWritableState(player)
	if not profile or not replica then
		return false
	end

	local batchOperations: {BatchOperation} = {}
	local pendingValues: {[string]: number} = {}

	for _, op in operations do
		local currentValue: any = pendingValues[op.path]
		if currentValue == nil then
			local opKeys = GetPathKeys(op.path)
			currentValue = DataUtils.GetNestedValue(_DataForRoot(profile, opKeys[1]), opKeys)
		end

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

		pendingValues[op.path] = newValue
		table.insert(batchOperations, {
			path = op.path,
			value = newValue,
		})
	end

	local success = _BatchSetValuesInternal(player, profile, batchOperations)

	BatchModule.FlushBatch(player)

	return success
end

function PlayerState.FlushBatch(player: Player): boolean
	if not Validation.ValidatePlayer(player) then
		return false
	end

	if not _GetWritableReplica(player) then
		return false
	end

	BatchModule.FlushBatch(player)
	return true
end

function PlayerState.AddToArray(player: Player, arrayPath: ArrayPath, item: any): boolean
	local profile, replica = _GetWritableState(player)
	if not profile or not replica then
		return false
	end

	local pathKeys = GetPathKeys(arrayPath)
	local array = DataUtils.GetNestedValue(_DataForRoot(profile, pathKeys[1]), pathKeys)
	if typeof(array) ~= "table" then
		warn(`[PlayerState] AddToArray path "{arrayPath}" is not an array for {player.Name}`)
		return false
	end

	if IsServerOnlyPath(arrayPath) then
		table.insert(array, item)
		return true
	end

	_FlushPendingBatch(player)

	table.insert(array, item)

	local success, result = ArrayOps.AddToArray(replica, pathKeys, CloneForReplica(item))
	if not success then
		table.remove(array)
		warn(`[PlayerState] AddToArray operation failed for {player.Name}: {result}`)
		return false
	end

	return success
end

function PlayerState.RemoveFromArray(player: Player, arrayPath: ArrayPath, index: number): boolean
	local profile, replica = _GetWritableState(player)
	if not profile or not replica then
		return false
	end

	local pathKeys = GetPathKeys(arrayPath)
	local array = DataUtils.GetNestedValue(_DataForRoot(profile, pathKeys[1]), pathKeys)
	if typeof(array) ~= "table" then
		warn(`[PlayerState] RemoveFromArray path "{arrayPath}" is not an array for {player.Name}`)
		return false
	end

	if IsServerOnlyPath(arrayPath) then
		table.remove(array, index)
		return true
	end

	_FlushPendingBatch(player)

	local previousLength = #array
	local removedLocally, removedValue = pcall(table.remove, array, index)
	if not removedLocally then
		warn(`[PlayerState] RemoveFromArray operation failed for {player.Name}: {removedValue}`)
		return false
	end

	local success, result = ArrayOps.RemoveFromArray(replica, pathKeys, index)
	if not success then
		if #array < previousLength then
			table.insert(array, index, removedValue)
		end
		warn(`[PlayerState] RemoveFromArray operation failed for {player.Name}: {result}`)
		return false
	end

	return success
end

function PlayerState.UpdateArrayItem(player: Player, arrayPath: ArrayPath, index: number, newItem: any): boolean
	local profile, replica = _GetWritableState(player)
	if not profile or not replica then
		return false
	end

	local pathKeys = GetPathKeys(arrayPath)
	local array = DataUtils.GetNestedValue(_DataForRoot(profile, pathKeys[1]), pathKeys)
	if typeof(array) ~= "table" then
		warn(`[PlayerState] UpdateArrayItem path "{arrayPath}" is not an array for {player.Name}`)
		return false
	end

	if IsServerOnlyPath(arrayPath) then
		array[index] = newItem
		return true
	end

	_FlushPendingBatch(player)

	local previousItem = array[index]
	array[index] = newItem

	local success = ArrayOps.UpdateArrayItem(replica, pathKeys, index, CloneForReplica(newItem))
	if not success then
		array[index] = previousItem
		warn(`[PlayerState] UpdateArrayItem operation failed for {player.Name}`)
		return false
	end

	return true
end

function PlayerState.SetInDict(player: Player, dictPath: DictPath, key: string | number, value: any): boolean
	local profile, replica = _GetWritableState(player)
	if not profile or not replica then
		return false
	end

	local stringKey = if typeof(key) == "number" then tostring(key) else key
	local pathKeys = GetPathKeys(dictPath)
	local prior = DataUtils.GetNestedValue(_DataForRoot(profile, pathKeys[1]), pathKeys)

	if prior ~= nil and typeof(prior) ~= "table" then
		warn(`[PlayerState] SetInDict path "{dictPath}" is not a dictionary for {player.Name}`)
		return false
	end

	if IsServerOnlyPath(dictPath) then
		if prior == nil then
			DataUtils.SetNestedValue(profile.Data, pathKeys, {[stringKey] = value})
			warn(`[PlayerState] Created new dictionary at path "{dictPath}" for {player.Name}`)
		else
			prior[stringKey] = value
		end

		return true
	end

	if not _ReplicaParentExists(replica, pathKeys) then
		warn(`[PlayerState] SetInDict operation failed for {player.Name}`)
		return false
	end

	if SKIP_UNCHANGED_WRITES and prior ~= nil and _IsUnchangedPrimitive(prior[stringKey], value) then
		return true
	end

	_FlushPendingBatch(player)

	local previousEntry = if prior ~= nil then prior[stringKey] else nil
	if prior == nil then
		DataUtils.SetNestedValue(_DataForRoot(profile, pathKeys[1]), pathKeys, {[stringKey] = value})
	else
		prior[stringKey] = value
	end

	local success = DictOps.SetInDict(replica, pathKeys, stringKey, CloneForReplica(value))

	if not success then
		if prior == nil then
			DataUtils.SetNestedValue(_DataForRoot(profile, pathKeys[1]), pathKeys, nil)
		else
			prior[stringKey] = previousEntry
		end
		warn(`[PlayerState] SetInDict operation failed for {player.Name}`)
		return false
	end

	if prior == nil then
		warn(`[PlayerState] Created new dictionary at path "{dictPath}" for {player.Name}`)
	end

	return true
end

function PlayerState.GetFromDict(player: Player, dictPath: DictPath, key: string | number): any
	local profile = _GetPlayerProfile(player)
	if not profile then
		return nil
	end

	local stringKey = if typeof(key) == "number" then tostring(key) else key

	local currentDict
	local dotIndex = string.find(dictPath, ".", 1, true)
	local data: any = profile.Data
	local capture = savesInFlight[profile]
	if capture ~= nil and RUNTIME_ROOT_LOOKUP[if dotIndex then string.sub(dictPath, 1, dotIndex - 1) else dictPath] == true then
		data = capture
	end

	if not dotIndex then
		currentDict = data[dictPath]
	else
		currentDict = GetNestedValue(data, dictPath)
	end

	if typeof(currentDict) ~= "table" then
		return nil
	end

	local result = currentDict[stringKey]
	if result == nil and typeof(key) == "number" then
		result = currentDict[key]
	end

	if AUTO_CLONE_TABLES and typeof(result) == "table" then
		return Utils.DeepClone(result)
	end

	return result
end

function PlayerState.RemoveFromDict(player: Player, dictPath: DictPath, key: string | number): boolean
	local profile, replica = _GetWritableState(player)
	if not profile or not replica then
		return false
	end

	local stringKey = if typeof(key) == "number" then tostring(key) else key
	local pathKeys = GetPathKeys(dictPath)
	local dict = DataUtils.GetNestedValue(_DataForRoot(profile, pathKeys[1]), pathKeys)

	if typeof(dict) ~= "table" then
		warn(`[PlayerState] RemoveFromDict failed - path is not a dictionary for {player.Name}`)
		return false
	end

	if IsServerOnlyPath(dictPath) then
		dict[stringKey] = nil
		return true
	end

	_FlushPendingBatch(player)

	local previousEntry = dict[stringKey]
	dict[stringKey] = nil

	local success = DictOps.RemoveFromDict(replica, pathKeys, stringKey)

	if not success then
		dict[stringKey] = previousEntry
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

	local profile = _GetPlayerProfile(player)
	if not profile then
		return nil
	end

	return profile.Data
end

function PlayerState.GetSharedReplica(): ReplicaInstance?
	if not Validation.ValidateReplica(sharedReplica) then
		return nil
	end

	return sharedReplica
end

function PlayerState.GetSharedAll(): SharedSessionData?
	if not Validation.ValidateReplica(sharedReplica) then
		return nil
	end

	return sharedReplica.Data
end

function PlayerState.IsSharedReady(): boolean
	return Validation.ValidateReplica(sharedReplica)
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
	if DataUtils.IsPathInRuntimeRoots(path, RUNTIME_NON_PERSISTENT_ROOTS) then
		warn(`[PlayerState] Cannot set offline value for runtime-only path "{path}"`)
		return false
	end

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
				DataUtils.CleanData(data, template, CLEAN_KEEP_ROOTS)
			end
		end
	)
end

function PlayerState.WipePlayerData(player: Player): boolean
	if not _GetWritableReplica(player) then
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
				DataUtils.CleanData(data, template, CLEAN_KEEP_ROOTS)
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
		warn("[PlayerState] Invalid player for Increment")
		return false
	end

	local profile, replica = _GetWritableState(player)
	if not profile or not replica then
		return false
	end

	local pathKeys = GetPathKeys(path)
	local currentValue = DataUtils.GetNestedValue(_DataForRoot(profile, pathKeys[1]), pathKeys)
	if typeof(currentValue) ~= "number" then
		warn(`[PlayerState] Cannot increment non-numeric value at path: {path}`)
		return false
	end

	local incrementAmount = if amount ~= nil then amount else 1
	local newValue = currentValue + incrementAmount

	return _SetPathKeysInternal(player, profile, replica, path, pathKeys, newValue)
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

	return PlayerState.SetPath(player, statName, score)
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
	releasingPlayers[player] = true

	local readyConnection = pendingReadyConnections[player]
	if readyConnection then
		pendingReadyConnections[player] = nil
		readyConnection:Disconnect()
	end

	if profiles[player] then
		_FireReleaseHooks(player, profiles[player].Data)
	end

	BatchModule.ClearPlayerBatch(player)

	LeaderboardModule.UpdatePlayerLeaderboard(player)

	if profiles[player] then
		_EndProfileSession(profiles[player])
		profiles[player] = nil
	end
	loadedProfileUserIds[player] = nil
	mutationBlockedByPlayer[player] = nil
	reopenAttempts[player] = nil

	if replicas[player] then
		replicas[player]:Destroy()
		replicas[player] = nil
	end

	local registry = playerRegistries[player]
	if registry then
		playerRegistries[player] = nil
		registry:Clear()
	end

	_WakeDataWaiters(player)

	releasedPlayers[player] = nil

	task.delay(RELEASE_FLAG_LIFETIME, function()
		releasingPlayers[player] = nil
		initInFlight[player] = nil
	end)
end)

game:BindToClose(function()
	isShuttingDown = true

	for player, profile in profiles do
		if profile then
			_FireReleaseHooks(player, profile.Data)
		end
	end

	for player in profiles do
		BatchModule.ProcessBatchOperations(player)
	end

	LeaderboardModule.CancelPeriodicUpdates()

	LeaderboardModule.UpdateAllLeaderboards()

	for _, profile in profiles do
		if profile then
			_EndProfileSession(profile)
		end
	end

	LeaderboardModule.FlushPendingWrites(20)
end)

DebugState.GetServerCounts = function(): {[string]: number}
	local function count(map: {[any]: any}): number
		local total = 0
		for _ in map do
			total += 1
		end
		return total
	end

	local leaderboardCounts = LeaderboardModule.GetDebugCounts()

	return {
		replicas = count(replicas),
		profiles = count(profiles),
		loadedProfileUserIds = count(loadedProfileUserIds),
		mutationBlockedByPlayer = count(mutationBlockedByPlayer),
		initInFlight = count(initInFlight),
		releasingPlayers = count(releasingPlayers),
		pendingReadyConnections = count(pendingReadyConnections),
		reopenAttempts = count(reopenAttempts),
		playerRegistries = count(playerRegistries),
		dataWaiters = count(dataWaiters),
		newReadyPlayerListeners = (ReplicaServer.NewReadyPlayer :: any):GetListenerCount(),
		leaderboardPending = leaderboardCounts.pending,
		leaderboardLastWritten = leaderboardCounts.lastWritten,
		leaderboardWarned = leaderboardCounts.warned,
	}
end

PlayerState.BeforeSave = BeforeSave
PlayerState.BeforeRelease = BeforeRelease
PlayerState.ProfileLoaded = ProfileLoaded
PlayerState.ProfileUnloaded = ProfileUnloaded
PlayerState.MigrationResult = MigrationResult

_SetupRemoteModules(PlayerState)

return PlayerState
