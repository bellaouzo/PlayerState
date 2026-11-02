--!strict

local Players = game:GetService("Players")
local DataUtils = require(script.Parent.DataUtils)
local Utils = require(script.Parent.Parent.Shared.Utils)

local DataWipe = {}

local OFFLINE_SESSION_DEADLINE = 5

local function StartOfflineSession(profileStore: any, profileKey: string): (boolean, any)
	local deadline = os.clock() + OFFLINE_SESSION_DEADLINE

	return pcall(function()
		return profileStore:StartSessionAsync(profileKey, {
			Cancel = function(): boolean
				return os.clock() >= deadline
			end,
		})
	end)
end

local function SendWipeMessage(profileStore: any, profileKey: string): boolean
	local ok, sent = pcall(function()
		return profileStore:MessageAsync(profileKey, {
			Type = "WipeData",
		})
	end)

	return ok and sent == true
end

function DataWipe.WipePlayerData(
	player: Player,
	config: any,
	getProfile: (player: Player) -> any?,
	getReplica: (player: Player) -> any?,
	validatePlayer: (player: Player) -> boolean,
	validateProfile: (profile: any?) -> boolean,
	validateReplica: (replica: any?) -> boolean
): boolean
	if not validatePlayer(player) then
		warn("[PlayerState] Cannot wipe data - invalid player")
		return false
	end

	local profile = getProfile(player)
	if not validateProfile(profile) then
		warn(`[PlayerState] No valid profile found for {player.Name}`)
		return false
	end

	local success = pcall(function()
		table.clear(profile.Data)
		for key, value in config.Profile.Template do
			profile.Data[key] = if typeof(value) == "table" then Utils.DeepClone(value) else value
		end
	end)

	if not success then
		warn(`[PlayerState] Failed to wipe data for {player.Name}`)
		return false
	end

	local replica = getReplica(player)
	if validateReplica(replica) then
		local serverOnlyRoots = DataUtils.ResolveServerOnlyRoots(config.ServerOnlyRoots)
		local replicatedData = DataUtils.CloneWithoutRoots(profile.Data, serverOnlyRoots)

		pcall(replica.SetValues, replica, {}, replicatedData)
	end

	print(`[PlayerState] Successfully wiped data for {player.Name}`)

	if player:IsDescendantOf(Players) then
		player:Kick("Your data has been reset. Please rejoin to continue.")
	end

	return true
end

function DataWipe.WipeOfflinePlayerData(
	userId: number,
	config: any,
	profileStore: any,
	wipePlayerData: (player: Player) -> boolean,
	cleanData: (data: any, template: any) -> ()
): boolean
	if not userId or userId == 0 then
		warn("[PlayerState] Invalid userId for WipeOfflinePlayerData")
		return false
	end

	for _, player in Players:GetPlayers() do
		if player.UserId == userId then
			return wipePlayerData(player)
		end
	end

	local profileKey = config.Profile.Key .. "_" .. tostring(userId)

	local offlineProfile = profileStore:GetAsync(profileKey)

	if offlineProfile and offlineProfile.Session then
		local success = profileStore:MessageAsync(profileKey, {
			Type = "WipeData",
		})

		if success then
			print(`[PlayerState] Sent wipe data message to active profile for user {userId}`)
			return true
		else
			warn(`[PlayerState] Failed to send wipe message to active profile for user {userId}`)
			return false
		end
	end

	local success, profile = StartOfflineSession(profileStore, profileKey)

	if not success or not profile then
		if SendWipeMessage(profileStore, profileKey) then
			print(`[PlayerState] Profile for userId {userId} was busy; sent wipe data message instead`)
			return true
		end

		warn(`[PlayerState] Failed to start profile session for offline userId {userId}`)
		return false
	end

	profile:AddUserId(userId)
	profile:Reconcile()

	cleanData(profile.Data, config.Profile.Template)

	local wipeSuccess = pcall(function()
		for key, value in config.Profile.Template do
			profile.Data[key] = if typeof(value) == "table" then Utils.DeepClone(value) else value
		end
	end)

	if not wipeSuccess then
		warn(`[PlayerState] Failed to wipe offline data for userId {userId}`)
		profile:EndSession()
		return false
	end

	local runtimeRoots = DataUtils.ResolveRuntimeNonPersistentRoots(config.RuntimeNonPersistentRoots)
	DataUtils.RemoveRuntimeRoots(profile.Data, runtimeRoots)
	profile:EndSession()

	print(`[PlayerState] Successfully wiped offline data for userId {userId}`)
	return true
end

return DataWipe
