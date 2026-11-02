--!strict

local Players = game:GetService("Players")

local Registry = require(script.Parent.Registry)

local REMOTE_NAME = "GetOfflineData"
local RATE_LIMIT_CALLS = 10
local RATE_LIMIT_WINDOW_SECONDS = 10
local CACHE_SECONDS = 30
local CACHE_PRUNE_THRESHOLD = 200

local OfflineDataRemote = {}

function OfflineDataRemote.SetupServer(playerState: any): ()
	local DataUtils = require(script.Parent.Parent.Parent.Server.DataUtils) :: any
	local Config = require(script.Parent.Parent.Parent.Parent.PlayerStateConfig) :: any

	local serverConfig = Config.Server
	local hiddenRoots: {string} = {}
	local seenRoots: {[string]: boolean} = {}

	for _, roots in {
		DataUtils.ResolveServerOnlyRoots(serverConfig.ServerOnlyRoots),
		DataUtils.ResolveRuntimeNonPersistentRoots(serverConfig.RuntimeNonPersistentRoots),
	} do
		for _, root in roots do
			if not seenRoots[root] then
				seenRoots[root] = true
				table.insert(hiddenRoots, root)
			end
		end
	end

	local callWindows: {[Player]: {startedAt: number, count: number}} = {}
	local cachedResults: {[number]: {data: any, expiresAt: number}} = {}
	local cachedCount = 0

	local function isRateLimited(player: Player): boolean
		local now = os.clock()
		local window = callWindows[player]

		if not window or now - window.startedAt >= RATE_LIMIT_WINDOW_SECONDS then
			callWindows[player] = { startedAt = now, count = 1 }
			return false
		end

		if window.count >= RATE_LIMIT_CALLS then
			return true
		end

		window.count += 1
		return false
	end

	local function pruneCache(now: number): ()
		for userId, entry in cachedResults do
			if entry.expiresAt <= now then
				cachedResults[userId] = nil
				cachedCount -= 1
			end
		end
	end

	Players.PlayerRemoving:Connect(function(player: Player)
		callWindows[player] = nil
	end)

	Registry.BindRemoteFunction(REMOTE_NAME, function(player: Player, userId: unknown): any?
		if typeof(userId) ~= "number" then
			return nil
		end

		if isRateLimited(player) then
			return nil
		end

		local requestedUserId = userId :: number
		local isOnline = Players:GetPlayerByUserId(requestedUserId) ~= nil
		local now = os.clock()

		if not isOnline then
			local cached = cachedResults[requestedUserId]
			if cached and cached.expiresAt > now then
				return cached.data
			end
		end

		local data = playerState.GetOfflineData(requestedUserId)
		if typeof(data) ~= "table" then
			return data
		end

		local visibleData = DataUtils.CloneWithoutRoots(data, hiddenRoots)

		if not isOnline then
			if cachedResults[requestedUserId] == nil then
				cachedCount += 1
			end
			cachedResults[requestedUserId] = { data = visibleData, expiresAt = now + CACHE_SECONDS }

			if cachedCount > CACHE_PRUNE_THRESHOLD then
				pruneCache(now)
			end
		end

		return visibleData
	end)
end

function OfflineDataRemote.Invoke(userId: number): any?
	return Registry.InvokeRemoteFunction(REMOTE_NAME, userId)
end

return OfflineDataRemote
