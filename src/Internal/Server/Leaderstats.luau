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

type DescendantMapping = {
	displayName: string,
	relativeKeys: {string},
}

local function UpdateLeaderstatValue(leaderstats: Instance, displayName: string, newValue: any): ()
	local valueObject = leaderstats:FindFirstChild(displayName)
	if not valueObject then
		return
	end

	if typeof(newValue) == "number" then
		local requiredType = GetAppropriateValueType(newValue)
		local currentType = valueObject.ClassName

		if currentType ~= requiredType then
			local siblings = leaderstats:GetChildren()
			local index = table.find(siblings, valueObject) or #siblings

			valueObject:Destroy()
			local newValueObject = Instance.new(requiredType)
			local newNumericValue = newValueObject :: any

			newNumericValue.Value = newValue
			newValueObject.Name = displayName
			newValueObject.Parent = leaderstats

			for i = index + 1, #siblings do
				local sibling = siblings[i]
				if sibling.Parent == leaderstats then
					sibling.Parent = nil
					sibling.Parent = leaderstats
				end
			end
		else
			local numericValue = valueObject :: any
			numericValue.Value = newValue
		end
	elseif valueObject:IsA("StringValue") then
		(valueObject :: StringValue).Value = tostring(newValue or "")
	end
end

local function GetRelativeValue(value: any, relativeKeys: {string}): any
	local current = value
	for i = 1, #relativeKeys do
		if typeof(current) ~= "table" then
			return nil
		end
		current = current[relativeKeys[i]]
	end

	return current
end

function Leaderstats.ResolveOrder(leaderstatsConfig: any, order: {string}?): {string}
	local ordered: {string} = {}
	if typeof(leaderstatsConfig) ~= "table" then
		return ordered
	end

	local added: {[string]: boolean} = {}

	if typeof(order) == "table" then
		for _, displayName in order do
			if typeof(displayName) == "string" and not added[displayName] and leaderstatsConfig[displayName] ~= nil then
				added[displayName] = true
				table.insert(ordered, displayName)
			end
		end
	end

	local remaining: {string} = {}
	for displayName in leaderstatsConfig do
		if typeof(displayName) == "string" and not added[displayName] then
			table.insert(remaining, displayName)
		end
	end
	table.sort(remaining)

	return table.move(remaining, 1, #remaining, #ordered + 1, ordered)
end

function Leaderstats.CreateLeaderstats(player: Player, profileData: any, getNestedValue: (data: any, path: string) -> any, order: {string}?): ()
	local leaderstatsConfig = profileData.leaderstats
	if not leaderstatsConfig then
		return
	end

	local leaderstats = Instance.new("Folder")
	leaderstats.Name = "leaderstats"
	leaderstats.Parent = player

	for _, displayName in Leaderstats.ResolveOrder(leaderstatsConfig, order) do
		local dataPath = leaderstatsConfig[displayName]
		local currentValue = getNestedValue(profileData, dataPath)

		if typeof(currentValue) == "number" then
			local valueType = GetAppropriateValueType(currentValue)
			local valueObject = Instance.new(valueType)
			local numericValue = valueObject :: any

			numericValue.Value = currentValue
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
			UpdateLeaderstatValue(leaderstats, displayName, newValue)

			break
		end
	end
end

function Leaderstats.SetupLeaderstatsSync(player: Player, replica: any, getProfile: (player: Player) -> any?, validateProfile: (profile: any?) -> boolean, getNestedValue: (data: any, path: string) -> any, order: {string}?): ()
	local profile = getProfile(player)
	if not profile or not validateProfile(profile) then
		return
	end

	local leaderstatsConfig = (replica.Data :: any).leaderstats
	if not leaderstatsConfig then return end

	Leaderstats.CreateLeaderstats(player, profile.Data, getNestedValue, order)

	local pathToDisplayNames: {[string]: {string}} = {}
	local prefixToDescendants: {[string]: {DescendantMapping}} = {}
	local rootKeys: {[string]: boolean} = {}

	if typeof(leaderstatsConfig) == "table" then
		for displayName, dataPath in leaderstatsConfig do
			if typeof(displayName) ~= "string" or typeof(dataPath) ~= "string" or dataPath == "" then
				continue
			end

			local displayNames = pathToDisplayNames[dataPath]
			if not displayNames then
				displayNames = {}
				pathToDisplayNames[dataPath] = displayNames
			end
			table.insert(displayNames, displayName)

			local segments: {string} = {}
			for segment in string.gmatch(dataPath, "[^%.]+") do
				table.insert(segments, segment)
			end

			local firstDot = string.find(dataPath, ".", 1, true)
			rootKeys[if firstDot then string.sub(dataPath, 1, firstDot - 1) else dataPath] = true
			if segments[1] then
				rootKeys[segments[1]] = true
			end

			local prefix = ""
			for depth = 1, #segments - 1 do
				prefix = if depth == 1 then segments[1] else prefix .. "." .. segments[depth]

				local descendants = prefixToDescendants[prefix]
				if not descendants then
					descendants = {}
					prefixToDescendants[prefix] = descendants
				end

				table.insert(descendants, {
					displayName = displayName,
					relativeKeys = table.move(segments, depth + 1, #segments, 1, {}),
				})
			end
		end
	end

	local function IsMappedRoot(firstKey: any): boolean
		if firstKey == nil then
			return false
		end

		local key = if typeof(firstKey) == "string" then firstKey else tostring(firstKey)
		return rootKeys[key] == true or string.find(key, ".", 1, true) ~= nil
	end

	local function ApplyForPath(pathString: string, value: any): ()
		local displayNames = pathToDisplayNames[pathString]
		local descendants = prefixToDescendants[pathString]
		if not displayNames and not descendants then
			return
		end

		local leaderstats = player:FindFirstChild("leaderstats")
		if not leaderstats then
			return
		end

		if displayNames then
			for _, displayName in displayNames do
				UpdateLeaderstatValue(leaderstats, displayName, value)
			end
		end

		if descendants then
			for _, descendant in descendants do
				UpdateLeaderstatValue(leaderstats, descendant.displayName, GetRelativeValue(value, descendant.relativeKeys))
			end
		end
	end

	local originalSet = replica.Set
	local originalSetValues = replica.SetValues

	replica.Set = function(self, path: {string}, value: any): boolean
		local success, err = pcall(originalSet, self, path, value)
		if not success then
			warn(`[PlayerState] Set operation failed for {player.Name}: {err}`)
			return success
		end

		local firstKey = path[1]
		if not IsMappedRoot(firstKey) then
			return success
		end

		if #path == 1 and typeof(firstKey) == "string" then
			ApplyForPath(firstKey, value)
		else
			ApplyForPath(table.concat(path, "."), value)
		end

		return success
	end

	replica.SetValues = function(self, path: {string}, values: {[string]: any}): boolean
		local success, err = pcall(originalSetValues, self, path, values)
		if not success then
			warn(`[PlayerState] SetValues operation failed for {player.Name}: {err}`)
			return success
		end

		if #path == 0 then
			for key, value in values do
				if IsMappedRoot(key) then
					ApplyForPath(if typeof(key) == "string" then key else tostring(key), value)
				end
			end
		elseif IsMappedRoot(path[1]) then
			local basePath = table.concat(path, ".")
			for key, value in values do
				ApplyForPath(basePath .. "." .. tostring(key), value)
			end
		end

		return success
	end
end

return Leaderstats