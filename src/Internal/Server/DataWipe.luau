--!strict

local Players = game:GetService("Players")

local DataWipe = {}

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
			profile.Data[key] = value
		end
	end)

	if not success then
		warn(`[PlayerState] Failed to wipe data for {player.Name}`)
		return false
	end

	local replica = getReplica(player)
	if validateReplica(replica) then
		pcall(replica.SetValues, replica, {}, profile.Data)
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

	local success, profile = pcall(function()
		return profileStore:StartSessionAsync(profileKey)
	end)

	if not success or not profile then
		warn(`[PlayerState] Failed to start profile session for offline userId {userId}`)
		return false
	end

	profile:AddUserId(userId)
	profile:Reconcile()

	cleanData(profile.Data, config.Profile.Template)

	local success = pcall(function()
		for key, value in config.Profile.Template do
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

return DataWipe
