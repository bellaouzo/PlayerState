--!strict

local Leaderstats = {}

local INT32_MAX = 2147483647
local INT32_MIN = -2147483648

local function GetAppropriateValueType(value: number): string
	if value % 1 ~= 0 then
		return "NumberValue"
	elseif value > INT32_MAX or value < INT32_MIN then
		return "NumberValue"
	else
		return "IntValue"
	end
end

function Leaderstats.CreateLeaderstats(player: Player, profileData: any, getNestedValue: (data: any, path: string) -> any): ()
	local leaderstatsConfig = profileData.leaderstats
	if not leaderstatsConfig then
		return
	end

	local leaderstats = Instance.new("Folder")
	leaderstats.Name = "leaderstats"
	leaderstats.Parent = player

	for displayName, dataPath in leaderstatsConfig do
		local currentValue = getNestedValue(profileData, dataPath)

		if typeof(currentValue) == "number" then
			local valueType = GetAppropriateValueType(currentValue)
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

function Leaderstats.UpdateLeaderstatsForPath(player: Player, profileData: any, path: string, newValue: any, validateProfile: (profile: any?) -> boolean): ()
	local leaderstats = player:FindFirstChild("leaderstats")
	if not leaderstats then return end

	local leaderstatsConfig = profileData.leaderstats
	if not leaderstatsConfig then return end

	for displayName, configPath in leaderstatsConfig do
		if configPath == path then
			local valueObject = leaderstats:FindFirstChild(displayName)
			if valueObject then
				if typeof(newValue) == "number" then
					local requiredType = GetAppropriateValueType(newValue)
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

function Leaderstats.SetupLeaderstatsSync(player: Player, replica: any, getProfile: (player: Player) -> any?, validateProfile: (profile: any?) -> boolean, getNestedValue: (data: any, path: string) -> any): ()
	local profile = getProfile(player)
	if not profile or not validateProfile(profile) then
		return
	end

	local leaderstatsConfig = (replica.Data :: any).leaderstats
	if not leaderstatsConfig then return end

	Leaderstats.CreateLeaderstats(player, profile.Data, getNestedValue)

	local originalSet = replica.Set
	local originalSetValues = replica.SetValues

	replica.Set = function(self, path: {string}, value: any)
		local success, err = pcall(originalSet, self, path, value)
		if not success then
			warn(`[PlayerState] Set operation failed for {player.Name}: {err}`)
			return success
		end

		local pathString = table.concat(path, ".")
		Leaderstats.UpdateLeaderstatsForPath(player, profile.Data, pathString, value, validateProfile)
		return success
	end

	replica.SetValues = function(self, path: {string}, values: {[string]: any})
		local success, err = pcall(originalSetValues, self, path, values)
		if not success then
			warn(`[PlayerState] SetValues operation failed for {player.Name}: {err}`)
			return success
		end

		local basePath = table.concat(path, ".")
		for key, value in values do
			local fullPath = basePath == "" and key or basePath .. "." .. key
			Leaderstats.UpdateLeaderstatsForPath(player, profile.Data, fullPath, value, validateProfile)
		end
		return success
	end
end

return Leaderstats
