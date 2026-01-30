--!strict

local Players = game:GetService("Players")

local OfflineData = {}

function OfflineData.GetOfflineData(
	userId: number,
	config: any,
	profileStore: any,
	getAllForPlayer: (player: Player) -> any?
): any?
	if not userId or userId == 0 then
		warn("[PlayerState] Invalid userId for GetOfflineData")
		return nil
	end

	for _, player in (Players:GetPlayers()) do
		if player.UserId == userId then
			return getAllForPlayer(player)
		end
	end

	local profileKey = config.Profile.Key .. "_" .. tostring(userId)
	local offlineProfile = profileStore:GetAsync(profileKey)

	if offlineProfile then
		return offlineProfile.Data
	end

	return nil
end

function OfflineData.SetOfflineData(
	userId: number,
	path: string,
	value: any,
	config: any,
	profileStore: any,
	setPathForPlayer: (player: Player, path: string, value: any) -> boolean,
	getPathKeys: (path: string) -> {string},
	cleanData: (data: any, template: any) -> ()
): boolean
	if not userId or userId == 0 then
		warn("[PlayerState] Invalid userId for SetOfflineData")
		return false
	end

	for _, player in Players:GetPlayers() do
		if player.UserId == userId then
			return setPathForPlayer(player, path, value)
		end
	end

	local profileKey = config.Profile.Key .. "_" .. tostring(userId)

	local offlineProfile = profileStore:GetAsync(profileKey)

	if offlineProfile and offlineProfile.Session then
		local success = profileStore:MessageAsync(profileKey, {
			Type = "SetData",
			Path = path,
			Value = value,
		})

		if success then
			print(`[PlayerState] Sent data change message to active profile for user {userId}`)
			return true
		else
			warn(`[PlayerState] Failed to send message to active profile for user {userId}`)
			return false
		end
	end

	local success, profile = pcall(function()
		return profileStore:StartSessionAsync(profileKey)
	end)

	if not success or not profile then
		warn(`[PlayerState] Failed to start profile session for offline user {userId}`)
		return false
	end

	profile:AddUserId(userId)
	profile:Reconcile()

	cleanData(profile.Data, config.Profile.Template)

	local success = pcall(function()
		if not string.find(path, ".", 1, true) then
			profile.Data[path] = value
		else
			local pathKeys = getPathKeys(path)
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

return OfflineData
