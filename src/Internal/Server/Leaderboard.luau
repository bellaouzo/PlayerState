--!strict

local Players = game:GetService("Players")
local DataStoreService = game:GetService("DataStoreService")
local DataUtils = require(script.Parent.DataUtils)

export type LeaderboardEntry = {
	userId: number,
	score: number,
	rank: number,
}

export type LeaderboardModule = {
	InitializeLeaderboards: () -> (),
	IsStatTracked: (statName: string) -> boolean,
	UpdateAllLeaderboards: () -> (),
	GetLeaderboardInternal: (statName: string, limit: number) -> {LeaderboardEntry},
	UpdateReplicaLeaderboardScore: (replica: any, statName: string, score: number) -> (),
	SetupLeaderboardRankSaveProtection: (profile: any) -> (),
	SyncPlayerLeaderboardRanks: () -> (),
	StartPeriodicUpdates: () -> (),
	UpdatePlayerLeaderboard: (player: Player) -> (),
	CancelPeriodicUpdates: () -> (),
	EnqueueTrackedStatsFromReplica: (replica: any) -> (),
}

local function CreateLeaderboardModule(
	config: any,
	validatePlayer: (player: Player) -> boolean,
	validateReplica: (replica: any?) -> boolean,
	getReplicas: () -> {[Player]: any},
	getNestedValue: (data: any, path: string) -> any
): LeaderboardModule
	local leaderboardStores: {[string]: any} = {}
	local leaderboardCache: {[string]: {data: {LeaderboardEntry}, lastUpdate: number}} = {}
	local periodicUpdateThread: thread?
	local fullWriteUpdateThread: thread?
	local trackedStatSet: {[string]: boolean} = {}

	local WRITE_INTERVAL_SECONDS = 0.12
	local lastWrittenScore: {[string]: number} = {}
	local pendingWrites: {[string]: {store: any, userIdKey: string, value: number}} = {}
	local writeWorkerStarted = false

	local function RunLeaderboardWriteWorker()
		while true do
			task.wait(WRITE_INTERVAL_SECONDS)
			local key, entry = next(pendingWrites)

			if key and entry then
				pendingWrites[key] = nil

				local success = pcall(function()
					entry.store:SetAsync(entry.userIdKey, entry.value)
				end)

				if success then
					lastWrittenScore[key] = entry.value
				else
					pendingWrites[key] = entry
				end
			end
		end
	end

	local function EnqueueLeaderboardWrite(statName: string, store: any, userId: number, value: number)
		local key = statName .. "|" .. tostring(userId)
		if pendingWrites[key] == nil and lastWrittenScore[key] == value then
			return
		end

		pendingWrites[key] = {
			store = store,
			userIdKey = tostring(userId),
			value = value,
		}

		if not writeWorkerStarted then
			writeWorkerStarted = true
			task.spawn(RunLeaderboardWriteWorker)
		end
	end

	local function CopyLeaderboardEntries(entries: {LeaderboardEntry}): {LeaderboardEntry}
		local copiedEntries: {LeaderboardEntry} = {}
		for i, entry in entries do
			copiedEntries[i] = {
				userId = entry.userId,
				score = entry.score,
				rank = entry.rank,
			}
		end

		return copiedEntries
	end

	local function AreLeaderboardEntriesEqual(a: any, b: {LeaderboardEntry}): boolean
		if typeof(a) ~= "table" or #a ~= #b then
			return false
		end

		for i, entry in b do
			local currentEntry = a[i]
			if typeof(currentEntry) ~= "table"
				or currentEntry.userId ~= entry.userId
				or currentEntry.score ~= entry.score
				or currentEntry.rank ~= entry.rank
			then
				return false
			end
		end

		return true
	end

	local function InitializeLeaderboards()
		table.clear(trackedStatSet)

		if not config.Leaderboard.Enabled then
			return
		end

		for _, statName in (config.Leaderboard.TrackedStats) do
			trackedStatSet[statName] = true
			local storeName = config.Leaderboard.DataStoreName .. "_" .. statName:gsub("%.", "_")

			leaderboardStores[statName] = DataStoreService:GetOrderedDataStore(storeName)
		end

		if not writeWorkerStarted then
			writeWorkerStarted = true

			task.spawn(RunLeaderboardWriteWorker)
		end
	end

	local function IsStatTracked(statName: string): boolean
		if not config.Leaderboard or not config.Leaderboard.Enabled then
			return false
		end

		return trackedStatSet[statName] == true
	end

	local function UpdateAllLeaderboards(): ()
		if not config.Leaderboard.Enabled then return end

		local replicas = getReplicas()
		for _, statName in config.Leaderboard.TrackedStats do
			local store = leaderboardStores[statName]
			if not store then continue end

			for _, player in Players:GetPlayers() do
				if not validatePlayer(player) then continue end

				local replica = replicas[player]
				if not validateReplica(replica) then continue end

				local value = getNestedValue(replica.Data, statName)
				if typeof(value) == "number" then
					local storeValue = (value % 1 == 0) and value or math.floor(value)

					EnqueueLeaderboardWrite(statName, store, player.UserId, storeValue)
				end
			end
		end
	end

	local function GetLeaderboardInternal(statName: string, limit: number): {LeaderboardEntry}
		limit = limit or 100

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
				topPlayers[#topPlayers + 1] = {
					userId = userId,
					score = entry.value,
					rank = i,
				}
			end
		end

		leaderboardCache[statName] = {
			data = topPlayers,
			lastUpdate = currentTime,
		}

		return table.move(topPlayers, 1, math.min(limit, #topPlayers), 1, {})
	end

	local function UpdateReplicaLeaderboardScore(replica: any, statName: string, score: number): ()
		if not config.Leaderboard.Enabled or not IsStatTracked(statName) then return end
		if not validateReplica(replica) then return end

		local data = replica.Data :: any
		local currentRanks = data._LeaderboardRanks
		if typeof(currentRanks) ~= "table" then
			currentRanks = {}
		end

		local currentStatRank = currentRanks[statName]
		if typeof(currentStatRank) == "table" and currentStatRank.score == score then
			return
		end

		local newRanks = table.clone(currentRanks :: any)
		newRanks[statName] = {
			rank = if typeof(currentStatRank) == "table" then currentStatRank.rank else nil,
			score = score,
		}

		pcall(replica.Set, replica, {"_LeaderboardRanks"}, newRanks)

		local tags = replica.Tags
		local userId = if typeof(tags) == "table" then (tags :: any).UserId else nil
		if typeof(userId) ~= "number" then return end

		local store = leaderboardStores[statName]
		if not store then return end

		local storeValue = (score % 1 == 0) and score or math.floor(score)

		EnqueueLeaderboardWrite(statName, store, userId, storeValue)
	end

	local function EnqueueTrackedStatsFromReplica(replica: any): ()
		if not config.Leaderboard.Enabled then return end
		if not validateReplica(replica) then return end

		local tags = replica.Tags
		local userId = if typeof(tags) == "table" then (tags :: any).UserId else nil
		if typeof(userId) ~= "number" then return end

		for _, statName in config.Leaderboard.TrackedStats do
			local store = leaderboardStores[statName]
			if not store then continue end

			local value = getNestedValue(replica.Data, statName)
			if typeof(value) == "number" then
				UpdateReplicaLeaderboardScore(replica, statName, value)
			end
		end
	end

	local function SetupLeaderboardRankSaveProtection(profile: any): ()
		if not config.Leaderboard.Enabled then return end

		local runtimeRoots = {"_LeaderboardRanks", "_Leaderboards", "_Leaderboard"}
		DataUtils.AttachRuntimeSaveProtection(profile, runtimeRoots)
	end

	local function SyncPlayerLeaderboardRanks(): ()
		if not config.Leaderboard.Enabled then return end

		local replicas = getReplicas()
		for _, statName in config.Leaderboard.TrackedStats do
			local leaderboard = GetLeaderboardInternal(statName, 100)
			local leaderboardEntries = CopyLeaderboardEntries(leaderboard)

			local playerRanks: {[number]: {rank: number, score: number}} = {}
			for _, entry in leaderboard do
				playerRanks[entry.userId] = {
					rank = entry.rank,
					score = entry.score,
				}
			end

			for _, player in Players:GetPlayers() do
				if not validatePlayer(player) then
					continue
				end

				local replica = replicas[player]
				if not validateReplica(replica) then
					continue
				end

				local rankInfo = playerRanks[player.UserId]
				local currentRanks = (replica.Data :: any)._LeaderboardRanks
				local currentLeaderboards = (replica.Data :: any)._Leaderboards
				if typeof(currentRanks) ~= "table" then
					currentRanks = {}
				end
				if typeof(currentLeaderboards) ~= "table" then
					currentLeaderboards = {}
				end

				local currentStatRank = currentRanks[statName]
				local currentStatLeaderboard = currentLeaderboards[statName]

				if not AreLeaderboardEntriesEqual(currentStatLeaderboard, leaderboardEntries) then
					local newLeaderboards = table.clone(currentLeaderboards)
					newLeaderboards[statName] = CopyLeaderboardEntries(leaderboardEntries)

					pcall(replica.Set, replica, {"_Leaderboards"}, newLeaderboards)
				end

				if rankInfo then
					if typeof(currentStatRank) ~= "table"
						or currentStatRank.rank ~= rankInfo.rank
						or currentStatRank.score ~= rankInfo.score
					then
						local newRanks = table.clone(currentRanks)
						newRanks[statName] = rankInfo

						pcall(replica.Set, replica, {"_LeaderboardRanks"}, newRanks)
					end
				else
					local value = getNestedValue(replica.Data, statName)
					if typeof(value) == "number" then
						if typeof(currentStatRank) ~= "table" or currentStatRank.score ~= value then
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

	local function StartPeriodicUpdates(): ()
		if periodicUpdateThread then
			task.cancel(periodicUpdateThread)

			periodicUpdateThread = nil
		end
		if fullWriteUpdateThread then
			task.cancel(fullWriteUpdateThread)

			fullWriteUpdateThread = nil
		end

		task.spawn(function()
			SyncPlayerLeaderboardRanks()
		end)

		periodicUpdateThread = task.spawn(function()
			while true do
				task.wait(config.Leaderboard.SyncInterval)

				SyncPlayerLeaderboardRanks()
			end
		end)

		local lb = config.Leaderboard :: any
		local fullWriteSec = lb.FullLeaderboardWriteInterval
		if fullWriteSec == nil and type(lb.ReconcileInterval) == "number" then
			fullWriteSec = lb.ReconcileInterval
		end
		if fullWriteSec == nil then
			fullWriteSec = 600
		end
		if type(fullWriteSec) == "number" and fullWriteSec > 0 then
			fullWriteUpdateThread = task.spawn(function()
				while true do
					task.wait(fullWriteSec)

					UpdateAllLeaderboards()
				end
			end)
		end
	end

	local function UpdatePlayerLeaderboard(player: Player): ()
		if not config.Leaderboard.Enabled or not config.Leaderboard.UpdateOnPlayerLeave then return end
		if not validatePlayer(player) then return end

		local replicas = getReplicas()
		local replica = replicas[player]
		if not validateReplica(replica) then return end

		for _, statName in config.Leaderboard.TrackedStats do
			local store = leaderboardStores[statName]
			if not store then continue end

			local value = getNestedValue(replica.Data, statName)
			if typeof(value) == "number" then
				local storeValue = (value % 1 == 0) and value or math.floor(value)

				EnqueueLeaderboardWrite(statName, store, player.UserId, storeValue)
			end
		end
	end

	local function CancelPeriodicUpdates(): ()
		if periodicUpdateThread then
			task.cancel(periodicUpdateThread)
			
			periodicUpdateThread = nil
		end
		if fullWriteUpdateThread then
			task.cancel(fullWriteUpdateThread)

			fullWriteUpdateThread = nil
		end
	end

	return {
		InitializeLeaderboards = InitializeLeaderboards,
		IsStatTracked = IsStatTracked,
		UpdateAllLeaderboards = UpdateAllLeaderboards,
		GetLeaderboardInternal = GetLeaderboardInternal,
		UpdateReplicaLeaderboardScore = UpdateReplicaLeaderboardScore,
		SetupLeaderboardRankSaveProtection = SetupLeaderboardRankSaveProtection,
		SyncPlayerLeaderboardRanks = SyncPlayerLeaderboardRanks,
		StartPeriodicUpdates = StartPeriodicUpdates,
		UpdatePlayerLeaderboard = UpdatePlayerLeaderboard,
		CancelPeriodicUpdates = CancelPeriodicUpdates,
		EnqueueTrackedStatsFromReplica = EnqueueTrackedStatsFromReplica,
	}
end

return CreateLeaderboardModule
