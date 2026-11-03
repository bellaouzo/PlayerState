--!strict

local Players = game:GetService("Players")
local DataStoreService = game:GetService("DataStoreService")

export type LeaderboardEntry = {
	userId: number,
	score: number,
	rank: number,
}

export type LeaderboardDebugCounts = {
	pending: number,
	lastWritten: number,
	warned: number,
}

export type LeaderboardModule = {
	InitializeLeaderboards: () -> (),
	IsStatTracked: (statName: string) -> boolean,
	UpdateAllLeaderboards: () -> (),
	GetLeaderboardInternal: (statName: string, limit: number) -> {LeaderboardEntry},
	UpdateReplicaLeaderboardScore: (replica: any, statName: string, score: number) -> (),
	SyncPlayerLeaderboardRanks: () -> (),
	SyncReplicaLeaderboardRanks: (player: Player, replica: any) -> (),
	StartPeriodicUpdates: () -> (),
	UpdatePlayerLeaderboard: (player: Player) -> (),
	CancelPeriodicUpdates: () -> (),
	EnqueueTrackedStatsFromReplica: (replica: any) -> (),
	FlushPendingWrites: (timeoutSeconds: number?) -> (),
	GetDebugCounts: () -> LeaderboardDebugCounts,
}

type PendingWrite = {
	statName: string,
	userId: number,
	store: any,
	userIdKey: string,
	value: number,
	attempts: number,
	nextAttemptAt: number,
}

type CachedLeaderboard = {
	data: {LeaderboardEntry},
	lastUpdate: number,
	limit: number,
	exhausted: boolean,
}

type LeaderboardFetch = {
	limit: number,
	done: boolean,
	result: {LeaderboardEntry},
	waiting: {thread},
}

local function CreateLeaderboardModule(
	config: any,
	validatePlayer: (player: Player) -> boolean,
	validateReplica: (replica: any?) -> boolean,
	getReplicas: () -> {[Player]: any},
	getNestedValue: (data: any, path: string) -> any,
	dataStoreService: any?
): LeaderboardModule
	local dataStores: any = if dataStoreService ~= nil then dataStoreService else DataStoreService
	local leaderboardStores: {[string]: any} = {}
	local leaderboardCache: {[string]: CachedLeaderboard} = {}
	local leaderboardFetches: {[string]: LeaderboardFetch} = {}
	local periodicUpdateThread: thread?
	local fullWriteUpdateThread: thread?
	local initialSyncThread: thread?
	local trackedStatSet: {[string]: boolean} = {}

	local WRITE_INTERVAL_SECONDS = 0.12
	local MAX_WRITE_ATTEMPTS = 5
	local BUDGET_RETRY_SECONDS = 1
	local WRITE_BUDGET_RESERVE = 2
	local FETCH_FAILURE_COOLDOWN_SECONDS = 10
	local FLUSH_MAX_PARALLEL = 8
	local FLUSH_DEFAULT_TIMEOUT_SECONDS = 20
	local FLUSH_POLL_SECONDS = 0.05
	local FLUSH_MAX_BACKOFF_SECONDS = 1
	local CACHE_SECONDS = 15
	local MAX_PAGE_SIZE = 100
	local INT64_MIN = -9223372036854775808
	local INT64_LIMIT = 9223372036854775808

	local lastWrittenScore: {[string]: number} = {}
	local pendingWrites: {[string]: PendingWrite} = {}
	local inFlightWrites: {[string]: PendingWrite} = {}
	local releaseAfterWrite: {[string]: number} = {}
	local fetchFailedAt: {[string]: number} = {}
	local writeKeysByUser: {[number]: {[string]: string}} = {}
	local userIdKeys: {[number]: string} = {}
	local warnedInvalidScore: {[string]: boolean} = {}
	local writeWorkerStarted = false
	local idleWorkerThread: thread? = nil
	local workerSleepToken: {}? = nil
	local lastWorkerWriteAt = -math.huge
	local activeFlushes = 0

	local function GetUserIdKey(userId: number): string
		local userIdKey = userIdKeys[userId]
		if userIdKey == nil then
			userIdKey = tostring(userId)
			userIdKeys[userId] = userIdKey
		end

		return userIdKey
	end

	local function GetWriteKey(statName: string, userId: number): string
		local userKeys = writeKeysByUser[userId]
		if userKeys == nil then
			userKeys = {}
			writeKeysByUser[userId] = userKeys
		end

		local key = userKeys[statName]
		if key == nil then
			key = statName .. "|" .. GetUserIdKey(userId)
			userKeys[statName] = key
		end

		return key
	end

	local function ForgetUserKeys(userId: number): ()
		writeKeysByUser[userId] = nil
		userIdKeys[userId] = nil
	end

	local function WarnOnce(key: string, message: string): ()
		if warnedInvalidScore[key] then
			return
		end

		warnedInvalidScore[key] = true
		warn(message)
	end

	local function ToStoreValue(statName: string, userId: number, value: number): number?
		if value == value and value ~= math.huge and value ~= -math.huge then
			local storeValue = if value % 1 == 0 then value else math.floor(value)
			if INT64_MIN <= storeValue and storeValue < INT64_LIMIT then
				return storeValue
			end
		end

		WarnOnce(
			GetWriteKey(statName, userId),
			`[PlayerState] Leaderboard "{statName}" value for user {userId} ({tostring(value)}) can't be stored in an OrderedDataStore (must be a whole number within about ±9.2e18). Skipping leaderboard write.`
		)

		return nil
	end

	local function TryReleaseKey(key: string): ()
		local userId = releaseAfterWrite[key]
		if userId == nil then
			return
		end
		if pendingWrites[key] ~= nil or inFlightWrites[key] ~= nil then
			return
		end

		releaseAfterWrite[key] = nil
		lastWrittenScore[key] = nil
		warnedInvalidScore[key] = nil
		ForgetUserKeys(userId)
	end

	local function MarkReleaseAfterWrite(key: string, userId: number): ()
		releaseAfterWrite[key] = userId
		TryReleaseKey(key)
	end

	local function WakeWriteWorker(): ()
		local thread = idleWorkerThread
		if thread == nil then
			return
		end

		idleWorkerThread = nil
		workerSleepToken = nil
		task.defer(thread)
	end

	local function SleepWriteWorker(timeoutSeconds: number?): ()
		local thread = coroutine.running()
		local token = {}
		idleWorkerThread = thread
		workerSleepToken = token

		if timeoutSeconds ~= nil then
			task.delay(timeoutSeconds, function()
				if idleWorkerThread == thread and workerSleepToken == token then
					idleWorkerThread = nil
					workerSleepToken = nil
					task.spawn(thread)
				end
			end)
		end

		coroutine.yield()
	end

	local function HasWriteBudget(): boolean
		local success, budget = pcall(function()
			return dataStores:GetRequestBudgetForRequestType(Enum.DataStoreRequestType.SetIncrementSortedAsync)
		end)

		if not success or typeof(budget) ~= "number" then
			return true
		end

		return budget > WRITE_BUDGET_RESERVE
	end

	local function HasReadBudget(): boolean
		local success, budget = pcall(function()
			return dataStores:GetRequestBudgetForRequestType(Enum.DataStoreRequestType.GetSortedAsync)
		end)

		if not success or typeof(budget) ~= "number" then
			return true
		end

		return budget > 0
	end

	local function PickReadyWrite(now: number): (string?, PendingWrite?, number?)
		local bestKey: string? = nil
		local bestEntry: PendingWrite? = nil
		local bestAt = math.huge
		local earliestWait: number? = nil

		for key, entry in pendingWrites do
			if inFlightWrites[key] ~= nil then
				continue
			end

			if entry.nextAttemptAt <= now then
				if entry.nextAttemptAt < bestAt or bestEntry == nil then
					bestKey = key
					bestEntry = entry
					bestAt = entry.nextAttemptAt
				end
			elseif earliestWait == nil or entry.nextAttemptAt < earliestWait then
				earliestWait = entry.nextAttemptAt
			end
		end

		return bestKey, bestEntry, earliestWait
	end

	local function BeginWrite(key: string, entry: PendingWrite): ()
		pendingWrites[key] = nil
		inFlightWrites[key] = entry
	end

	local function PerformWrite(key: string, entry: PendingWrite): ()
		local success, err = pcall(function()
			entry.store:SetAsync(entry.userIdKey, entry.value)
		end)

		inFlightWrites[key] = nil

		if success then
			lastWrittenScore[key] = entry.value
		else
			local message = tostring(err)

			if string.find(message, "ValueNotNumeric", 1, true) then
				WarnOnce(
					key,
					`[PlayerState] Leaderboard "{entry.statName}" value for user {entry.userId} ({tostring(entry.value)}) was rejected by the OrderedDataStore ({message}). Skipping leaderboard write.`
				)
			else
				entry.attempts += 1

				if entry.attempts >= MAX_WRITE_ATTEMPTS then
					warn(
						`[PlayerState] Leaderboard "{entry.statName}" write for user {entry.userId} failed {entry.attempts} times. Dropping it. Last error: {message}`
					)
				elseif pendingWrites[key] == nil then
					local backoff = 2 ^ entry.attempts
					if activeFlushes > 0 then
						backoff = math.min(backoff, FLUSH_MAX_BACKOFF_SECONDS)
					end

					entry.nextAttemptAt = os.clock() + backoff
					pendingWrites[key] = entry
				end
			end
		end

		TryReleaseKey(key)

		if next(pendingWrites) ~= nil then
			WakeWriteWorker()
		end
	end

	local function RunLeaderboardWriteWorker()
		while true do
			if next(pendingWrites) == nil then
				SleepWriteWorker(nil)
				continue
			end

			local sinceLastWrite = os.clock() - lastWorkerWriteAt
			if sinceLastWrite < WRITE_INTERVAL_SECONDS then
				task.wait(WRITE_INTERVAL_SECONDS - sinceLastWrite)
			end

			local key, entry, earliestWait = PickReadyWrite(os.clock())
			if key == nil or entry == nil then
				if earliestWait ~= nil then
					SleepWriteWorker(math.max(earliestWait - os.clock(), WRITE_INTERVAL_SECONDS))
				else
					SleepWriteWorker(nil)
				end
				continue
			end

			if not HasWriteBudget() then
				task.wait(BUDGET_RETRY_SECONDS)
				continue
			end

			lastWorkerWriteAt = os.clock()
			BeginWrite(key, entry)
			PerformWrite(key, entry)
		end
	end

	local function EnsureWriteWorker(): ()
		if not writeWorkerStarted then
			writeWorkerStarted = true

			task.spawn(RunLeaderboardWriteWorker)
		end
	end

	local function EnqueueLeaderboardWrite(statName: string, store: any, userId: number, value: number)
		local key = GetWriteKey(statName, userId)
		warnedInvalidScore[key] = nil

		local existing = pendingWrites[key]
		local inFlight = inFlightWrites[key]
		local baseline = if inFlight ~= nil then inFlight.value else lastWrittenScore[key]
		if existing == nil and baseline == value then
			return
		end

		if existing ~= nil then
			existing.store = store
			existing.value = value
			existing.attempts = 0
		else
			pendingWrites[key] = {
				statName = statName,
				userId = userId,
				store = store,
				userIdKey = GetUserIdKey(userId),
				value = value,
				attempts = 0,
				nextAttemptAt = os.clock(),
			}
		end

		EnsureWriteWorker()
		WakeWriteWorker()
	end

	local function QueueStatValue(statName: string, store: any, userId: number, value: number): ()
		local storeValue = ToStoreValue(statName, userId, value)
		if storeValue == nil then
			return
		end

		EnqueueLeaderboardWrite(statName, store, userId, storeValue)
	end

	local function FlushPendingWrites(timeoutSeconds: number?): ()
		local timeout = FLUSH_DEFAULT_TIMEOUT_SECONDS
		if typeof(timeoutSeconds) == "number" and timeoutSeconds == timeoutSeconds and timeoutSeconds >= 0 then
			timeout = timeoutSeconds
		end

		local deadline = os.clock() + timeout
		activeFlushes += 1

		local now = os.clock()
		for _, entry in pendingWrites do
			if entry.nextAttemptAt > now then
				entry.nextAttemptAt = now
			end
		end

		local activeWrites = 0
		while next(pendingWrites) ~= nil or next(inFlightWrites) ~= nil do
			if os.clock() >= deadline then
				break
			end

			while activeWrites < FLUSH_MAX_PARALLEL do
				local key, entry = PickReadyWrite(os.clock())
				if key == nil or entry == nil then
					break
				end
				if not HasWriteBudget() then
					break
				end

				local writeKey: string = key
				local writeEntry: PendingWrite = entry
				BeginWrite(writeKey, writeEntry)
				activeWrites += 1

				task.spawn(function()
					PerformWrite(writeKey, writeEntry)
					activeWrites -= 1
				end)
			end

			task.wait(FLUSH_POLL_SECONDS)
		end

		activeFlushes -= 1
	end

	local function CountKeys(map: {[string]: any}): number
		local count = 0
		for _ in map do
			count += 1
		end

		return count
	end

	local function GetDebugCounts(): LeaderboardDebugCounts
		local pending = CountKeys(pendingWrites)
		for key in inFlightWrites do
			if pendingWrites[key] == nil then
				pending += 1
			end
		end

		return {
			pending = pending,
			lastWritten = CountKeys(lastWrittenScore),
			warned = CountKeys(warnedInvalidScore),
		}
	end

	local function CopyLeaderboardEntries(entries: {LeaderboardEntry}, maxCount: number?): {LeaderboardEntry}
		local count = #entries
		if maxCount ~= nil and maxCount < count then
			count = maxCount
		end

		local copiedEntries: {LeaderboardEntry} = {}
		for i = 1, count do
			local entry = entries[i]
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

	local function SetRuntimeStatValue(replica: any, rootKey: string, statName: string, value: any): ()
		local root = (replica.Data :: any)[rootKey]
		if typeof(root) == "table" then
			pcall(replica.Set, replica, {rootKey, statName}, value)
		else
			pcall(replica.Set, replica, {rootKey}, {[statName] = value})
		end
	end

	local function InitializeLeaderboards()
		table.clear(trackedStatSet)

		if not config.Leaderboard.Enabled then
			return
		end

		for _, statName in (config.Leaderboard.TrackedStats) do
			trackedStatSet[statName] = true
			local storeName = config.Leaderboard.DataStoreName .. "_" .. statName:gsub("%.", "_")

			leaderboardStores[statName] = dataStores:GetOrderedDataStore(storeName)
		end

		EnsureWriteWorker()
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
					QueueStatValue(statName, store, player.UserId, value)
				end
			end
		end
	end

	local function FetchSortedEntries(store: any, wanted: number): ({LeaderboardEntry}, boolean, number)
		local pageSize = math.min(math.max(wanted, 1), MAX_PAGE_SIZE)
		local pages = store:GetSortedAsync(false, pageSize)

		local entries: {LeaderboardEntry} = {}
		local position = 0
		local exhausted = false

		while true do
			local page = pages:GetCurrentPage()
			if #page == 0 then
				exhausted = true
				break
			end

			for _, item in page do
				position += 1

				local userId = tonumber(item.key)
				if userId then
					entries[#entries + 1] = {
						userId = userId,
						score = item.value,
						rank = position,
					}
				end

				if position >= wanted then
					break
				end
			end

			if position >= wanted then
				break
			end
			if pages.IsFinished then
				exhausted = true
				break
			end

			local advanced = pcall(function()
				pages:AdvanceToNextPageAsync()
			end)
			if not advanced then
				break
			end
		end

		return entries, exhausted, math.min(position, wanted)
	end

	local function StartLeaderboardFetch(statName: string, store: any, wanted: number): LeaderboardFetch
		local fetch: LeaderboardFetch = {
			limit = wanted,
			done = false,
			result = {},
			waiting = {},
		}
		leaderboardFetches[statName] = fetch

		task.spawn(function()
			local fetchTime = os.time()
			local success, entries, exhausted, covered = pcall(FetchSortedEntries, store, wanted)

			if success then
				fetchFailedAt[statName] = nil
				leaderboardCache[statName] = {
					data = entries,
					lastUpdate = fetchTime,
					limit = covered,
					exhausted = exhausted,
				}
				fetch.result = entries
			else
				fetchFailedAt[statName] = os.clock()
				local cached = leaderboardCache[statName]
				fetch.result = if cached then cached.data else {}
			end

			fetch.done = true
			if leaderboardFetches[statName] == fetch then
				leaderboardFetches[statName] = nil
			end

			for _, thread in fetch.waiting do
				if coroutine.status(thread) == "suspended" then
					task.spawn(thread)
				end
			end
		end)

		return fetch
	end

	local function GetLeaderboardInternal(statName: string, limit: number): {LeaderboardEntry}
		limit = limit or 100

		local store = leaderboardStores[statName]
		if not store then
			return {}
		end

		local wanted = if typeof(limit) == "number" and limit == limit then math.floor(limit) else 100
		if wanted <= 0 then
			return {}
		end

		while true do
			local cached = leaderboardCache[statName]
			if cached
				and (os.time() - cached.lastUpdate) < CACHE_SECONDS
				and (cached.exhausted or cached.limit >= wanted)
			then
				return CopyLeaderboardEntries(cached.data, wanted)
			end

			local fetch: LeaderboardFetch
			local activeFetch = leaderboardFetches[statName]
			if activeFetch ~= nil then
				fetch = activeFetch
			else
				local failedAt = fetchFailedAt[statName]
				if failedAt ~= nil and os.clock() - failedAt < FETCH_FAILURE_COOLDOWN_SECONDS or not HasReadBudget() then
					return if cached then CopyLeaderboardEntries(cached.data, wanted) else {}
				end

				fetch = StartLeaderboardFetch(statName, store, wanted)
			end
			if not fetch.done then
				table.insert(fetch.waiting, coroutine.running())
				coroutine.yield()
			end

			if fetch.limit >= wanted then
				return CopyLeaderboardEntries(fetch.result, wanted)
			end
		end
	end

	local function UpdateReplicaLeaderboardScore(replica: any, statName: string, score: number): ()
		if not config.Leaderboard.Enabled or not IsStatTracked(statName) then return end
		if not validateReplica(replica) then return end

		local data = replica.Data :: any
		local currentRanks = data._LeaderboardRanks
		local currentStatRank = if typeof(currentRanks) == "table" then currentRanks[statName] else nil
		if typeof(currentStatRank) == "table" and currentStatRank.score == score then
			return
		end

		SetRuntimeStatValue(replica, "_LeaderboardRanks", statName, {
			rank = if typeof(currentStatRank) == "table" then currentStatRank.rank else nil,
			score = score,
		})

		local tags = replica.Tags
		local userId = if typeof(tags) == "table" then (tags :: any).UserId else nil
		if typeof(userId) ~= "number" then return end

		local store = leaderboardStores[statName]
		if not store then return end

		QueueStatValue(statName, store, userId, score)
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

	local function BuildPlayerRanks(leaderboardEntries: {LeaderboardEntry}): {[number]: {rank: number, score: number}}
		local playerRanks: {[number]: {rank: number, score: number}} = {}
		for _, entry in leaderboardEntries do
			playerRanks[entry.userId] = {
				rank = entry.rank,
				score = entry.score,
			}
		end

		return playerRanks
	end

	local function ApplyLeaderboardToReplica(
		replica: any,
		userId: number,
		statName: string,
		leaderboardEntries: {LeaderboardEntry},
		playerRanks: {[number]: {rank: number, score: number}}
	): ()
		local rankInfo = playerRanks[userId]
		local currentRanks = (replica.Data :: any)._LeaderboardRanks
		local currentLeaderboards = (replica.Data :: any)._Leaderboards
		local currentStatRank = if typeof(currentRanks) == "table" then currentRanks[statName] else nil
		local currentStatLeaderboard = if typeof(currentLeaderboards) == "table" then currentLeaderboards[statName] else nil

		if not AreLeaderboardEntriesEqual(currentStatLeaderboard, leaderboardEntries) then
			SetRuntimeStatValue(replica, "_Leaderboards", statName, CopyLeaderboardEntries(leaderboardEntries))
		end

		if rankInfo then
			if typeof(currentStatRank) ~= "table"
				or currentStatRank.rank ~= rankInfo.rank
				or currentStatRank.score ~= rankInfo.score
			then
				SetRuntimeStatValue(replica, "_LeaderboardRanks", statName, {
					rank = rankInfo.rank,
					score = rankInfo.score,
				})
			end
		else
			local value = getNestedValue(replica.Data, statName)
			if typeof(value) == "number" then
				if typeof(currentStatRank) ~= "table" or currentStatRank.score ~= value then
					SetRuntimeStatValue(replica, "_LeaderboardRanks", statName, {
						rank = nil,
						score = value,
					})
				end
			end
		end
	end

	local function SyncPlayerLeaderboardRanks(): ()
		if not config.Leaderboard.Enabled then return end

		local replicas = getReplicas()
		for _, statName in config.Leaderboard.TrackedStats do
			local leaderboardEntries = GetLeaderboardInternal(statName, 100)
			local playerRanks = BuildPlayerRanks(leaderboardEntries)

			for _, player in Players:GetPlayers() do
				if not validatePlayer(player) then
					continue
				end

				local replica = replicas[player]
				if not validateReplica(replica) then
					continue
				end

				ApplyLeaderboardToReplica(replica, player.UserId, statName, leaderboardEntries, playerRanks)
			end
		end
	end

	local function SyncReplicaLeaderboardRanks(player: Player, replica: any): ()
		if not config.Leaderboard.Enabled then return end

		for _, statName in config.Leaderboard.TrackedStats do
			local leaderboardEntries = GetLeaderboardInternal(statName, 100)

			if not validatePlayer(player) or not validateReplica(replica) or getReplicas()[player] ~= replica then
				return
			end

			ApplyLeaderboardToReplica(replica, player.UserId, statName, leaderboardEntries, BuildPlayerRanks(leaderboardEntries))
		end
	end

	local function CancelThread(thread: thread?): ()
		if thread ~= nil and coroutine.status(thread) == "suspended" then
			task.cancel(thread)
		end
	end

	local function StartPeriodicUpdates(): ()
		CancelThread(initialSyncThread)
		initialSyncThread = nil
		CancelThread(periodicUpdateThread)
		periodicUpdateThread = nil
		CancelThread(fullWriteUpdateThread)
		fullWriteUpdateThread = nil

		initialSyncThread = task.spawn(SyncPlayerLeaderboardRanks)

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
		if not config.Leaderboard.Enabled then return end

		local replica: any = nil
		if config.Leaderboard.UpdateOnPlayerLeave and validatePlayer(player) then
			local candidate = getReplicas()[player]
			if validateReplica(candidate) then
				replica = candidate
			end
		end

		local userId = player.UserId
		for _, statName in config.Leaderboard.TrackedStats do
			local store = leaderboardStores[statName]

			if replica ~= nil and store then
				local value = getNestedValue(replica.Data, statName)
				if typeof(value) == "number" then
					QueueStatValue(statName, store, userId, value)
				end
			end

			MarkReleaseAfterWrite(GetWriteKey(statName, userId), userId)
		end

		ForgetUserKeys(userId)
	end

	local function CancelPeriodicUpdates(): ()
		CancelThread(initialSyncThread)
		initialSyncThread = nil
		CancelThread(periodicUpdateThread)
		periodicUpdateThread = nil
		CancelThread(fullWriteUpdateThread)
		fullWriteUpdateThread = nil
	end

	return {
		InitializeLeaderboards = InitializeLeaderboards,
		IsStatTracked = IsStatTracked,
		UpdateAllLeaderboards = UpdateAllLeaderboards,
		GetLeaderboardInternal = GetLeaderboardInternal,
		UpdateReplicaLeaderboardScore = UpdateReplicaLeaderboardScore,
		SyncPlayerLeaderboardRanks = SyncPlayerLeaderboardRanks,
		SyncReplicaLeaderboardRanks = SyncReplicaLeaderboardRanks,
		StartPeriodicUpdates = StartPeriodicUpdates,
		UpdatePlayerLeaderboard = UpdatePlayerLeaderboard,
		CancelPeriodicUpdates = CancelPeriodicUpdates,
		EnqueueTrackedStatsFromReplica = EnqueueTrackedStatsFromReplica,
		FlushPendingWrites = FlushPendingWrites,
		GetDebugCounts = GetDebugCounts,
	}
end

return CreateLeaderboardModule
