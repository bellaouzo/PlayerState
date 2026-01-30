--!strict

local Players = game:GetService("Players")
local DataStoreService = game:GetService("DataStoreService")

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

	local function InitializeLeaderboards()
		if not config.Leaderboard.Enabled then return end

		for _, statName in (config.Leaderboard.TrackedStats) do
			local storeName = config.Leaderboard.DataStoreName .. "_" .. statName:gsub("%.", "_")
			leaderboardStores[statName] = DataStoreService:GetOrderedDataStore(storeName)
		end
	end

	local function IsStatTracked(statName: string): boolean
		if not config.Leaderboard or not config.Leaderboard.Enabled then
			return false
		end

		for _, trackedStat in config.Leaderboard.TrackedStats do
			if trackedStat == statName then
				return true
			end
		end

		return false
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
					task.spawn(function()
						pcall(function()
							store:SetAsync(tostring(player.UserId), value)
						end)
					end)
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
	end

	local function SetupLeaderboardRankSaveProtection(profile: any): ()
		if not config.Leaderboard.Enabled then return end

		local savedLeaderboardRanks: any = nil

		local function restoreSavedLeaderboardRanks()
			if savedLeaderboardRanks == nil then
				return
			end

			local data = profile.Data :: any
			if data._LeaderboardRanks == nil then
				data._LeaderboardRanks = savedLeaderboardRanks
			end

			savedLeaderboardRanks = nil
		end

		local onSave = (profile :: any).OnSave
		if onSave and onSave.Connect then
			onSave:Connect(function()
				local data = profile.Data :: any
				savedLeaderboardRanks = data._LeaderboardRanks

				if savedLeaderboardRanks ~= nil then
					data._LeaderboardRanks = nil
				end
			end)
		end

		local onAfterSave = (profile :: any).OnAfterSave
		if onAfterSave and onAfterSave.Connect then
			onAfterSave:Connect(restoreSavedLeaderboardRanks)
		end

		profile.OnSessionEnd:Connect(restoreSavedLeaderboardRanks)
	end

	local function SyncPlayerLeaderboardRanks(): ()
		if not config.Leaderboard.Enabled then return end

		local replicas = getReplicas()
		for _, statName in config.Leaderboard.TrackedStats do
			local leaderboard = GetLeaderboardInternal(statName, 100)

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
				if typeof(currentRanks) ~= "table" then
					currentRanks = {}
				end
				local currentStatRank = currentRanks[statName]

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

		task.spawn(function()
			UpdateAllLeaderboards()
			SyncPlayerLeaderboardRanks()
		end)

		periodicUpdateThread = task.spawn(function()
			while true do
				task.wait(config.Leaderboard.SyncInterval)
				UpdateAllLeaderboards()
				SyncPlayerLeaderboardRanks()
			end
		end)
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
				task.spawn(function()
					pcall(function()
						store:SetAsync(tostring(player.UserId), value)
					end)
				end)
			end
		end
	end

	local function CancelPeriodicUpdates(): ()
		if periodicUpdateThread then
			task.cancel(periodicUpdateThread)
			periodicUpdateThread = nil
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
	}
end

return CreateLeaderboardModule
