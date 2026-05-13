--!strict

local DataUtils = {}

local INT32_MAX = 2147483647
local INT32_MIN = -2147483648
local DEFAULT_RUNTIME_NON_PERSISTENT_ROOTS = {
	"session",
	"_LeaderboardRanks",
	"_Leaderboards",
	"_Leaderboard",
}
local DEFAULT_SERVER_ONLY_ROOTS = {
	"Server",
}

function DataUtils.GetAppropriateValueType(value: number): string
	if value % 1 ~= 0 then
		return "NumberValue"
	elseif value > INT32_MAX or value < INT32_MIN then
		return "NumberValue"
	else
		return "IntValue"
	end
end

function DataUtils.GetNestedValue(data: any, pathKeys: {string}): any
	local current = data

	for i = 1, #pathKeys do
		local key = pathKeys[i]
		if typeof(current) ~= "table" then
			return nil
		end
		current = current[key]
		if current == nil then
			return nil
		end
	end

	return current
end

function DataUtils.CleanData(data: any, template: any): ()
	for key in data do
		if template[key] == nil then
			data[key] = nil
		elseif typeof(data[key]) == "table" and typeof(template[key]) == "table" then
			if next(template[key]) == nil then
				continue
			end

			DataUtils.CleanData(data[key], template[key])
		end
	end
end

local function GetPathKeys(path: string): {string}
	local keys: {string} = {}
	for segment in string.gmatch(path, "[^%.]+") do
		table.insert(keys, segment)
	end

	return keys
end

local function GetNestedPathValue(data: any, pathKeys: {string}): any
	local current = data

	for i = 1, #pathKeys do
		if typeof(current) ~= "table" then
			return nil
		end

		current = current[pathKeys[i]]
		if current == nil then
			return nil
		end
	end

	return current
end

local function SetNestedPathValue(data: any, pathKeys: {string}, value: any): boolean
	if typeof(data) ~= "table" or #pathKeys == 0 then
		return false
	end

	local current = data
	for i = 1, #pathKeys - 1 do
		local key = pathKeys[i]
		if typeof(current[key]) ~= "table" then
			current[key] = {}
		end

		current = current[key]
	end

	current[pathKeys[#pathKeys]] = value

	return true
end

function DataUtils.SetNestedValue(data: any, pathKeys: {string}, value: any): boolean
	return SetNestedPathValue(data, pathKeys, value)
end

local function DeepClone(value: any): any
	if typeof(value) ~= "table" then
		return value
	end

	local clone = {}
	for key, child in value do
		clone[key] = DeepClone(child)
	end

	return clone
end

function DataUtils.IsPathInRuntimeRoots(path: string, runtimeRoots: {string}?): boolean
	if typeof(path) ~= "string" or path == "" then
		return false
	end

	if typeof(runtimeRoots) ~= "table" then
		return false
	end

	for _, root in runtimeRoots do
		if typeof(root) == "string" and root ~= "" then
			if path == root then
				return true
			end

			if string.sub(path, 1, #root + 1) == root .. "." then
				return true
			end
		end
	end

	return false
end

function DataUtils.ResolveRuntimeNonPersistentRoots(runtimeRoots: {string}?): {string}
	local resolved: {string} = {}
	local seen: {[string]: boolean} = {}

	if typeof(runtimeRoots) == "table" then
		for _, root in runtimeRoots do
			if typeof(root) == "string" and root ~= "" and not seen[root] then
				table.insert(resolved, root)
				seen[root] = true
			end
		end
	end

	for _, root in DEFAULT_RUNTIME_NON_PERSISTENT_ROOTS do
		if not seen[root] then
			table.insert(resolved, root)
			seen[root] = true
		end
	end

	return resolved
end

function DataUtils.ResolveServerOnlyRoots(serverOnlyRoots: {string}?): {string}
	local resolved: {string} = {}
	local seen: {[string]: boolean} = {}

	if typeof(serverOnlyRoots) == "table" then
		for _, root in serverOnlyRoots do
			if typeof(root) == "string" and root ~= "" and not seen[root] then
				table.insert(resolved, root)
				seen[root] = true
			end
		end
	end

	for _, root in DEFAULT_SERVER_ONLY_ROOTS do
		if not seen[root] then
			table.insert(resolved, root)
			seen[root] = true
		end
	end

	return resolved
end

function DataUtils.IsPathInServerOnlyRoots(path: string, serverOnlyRoots: {string}?): boolean
	return DataUtils.IsPathInRuntimeRoots(path, serverOnlyRoots)
end

function DataUtils.CloneWithoutRoots(data: any, roots: {string}?): any
	local clone = DeepClone(data)
	DataUtils.RemoveRuntimeRoots(clone, roots)

	return clone
end

function DataUtils.RemoveRuntimeRoots(data: any, runtimeRoots: {string}?): boolean
	if typeof(data) ~= "table" or typeof(runtimeRoots) ~= "table" then
		return false
	end

	local removed = false
	for _, rootPath in runtimeRoots do
		if typeof(rootPath) ~= "string" or rootPath == "" then
			continue
		end

		local pathKeys = GetPathKeys(rootPath)
		if #pathKeys == 1 then
			local key = pathKeys[1]
			if data[key] ~= nil then
				data[key] = nil
				removed = true
			end
		else
			local parentPath = table.move(pathKeys, 1, #pathKeys - 1, 1, {})
			local parent = GetNestedPathValue(data, parentPath)
			local key = pathKeys[#pathKeys]

			if typeof(parent) == "table" and parent[key] ~= nil then
				parent[key] = nil
				removed = true
			end
		end
	end

	return removed
end

function DataUtils.CaptureAndRemoveRuntimeRoots(data: any, runtimeRoots: {string}?): {[string]: any}
	local captured: {[string]: any} = {}
	if typeof(data) ~= "table" or typeof(runtimeRoots) ~= "table" then
		return captured
	end

	for _, rootPath in runtimeRoots do
		if typeof(rootPath) ~= "string" or rootPath == "" then
			continue
		end

		local pathKeys = GetPathKeys(rootPath)
		local currentValue = GetNestedPathValue(data, pathKeys)
		if currentValue == nil then
			continue
		end

		captured[rootPath] = currentValue
		DataUtils.RemoveRuntimeRoots(data, {rootPath})
	end

	return captured
end

function DataUtils.RestoreRuntimeRoots(data: any, captured: {[string]: any}?): ()
	if typeof(data) ~= "table" or typeof(captured) ~= "table" then
		return
	end

	for rootPath, value in captured do
		if typeof(rootPath) ~= "string" or rootPath == "" then
			continue
		end
		
		local pathKeys = GetPathKeys(rootPath)
		SetNestedPathValue(data, pathKeys, value)
	end
end

function DataUtils.AttachRuntimeSaveProtection(profile: any, runtimeRoots: {string}?): ()
	local capturedRuntimeData: {[string]: any}? = nil

	local onSave = profile and (profile :: any).OnSave
	if onSave and onSave.Connect then
		onSave:Connect(function()
			local data = (profile :: any).Data
			capturedRuntimeData = DataUtils.CaptureAndRemoveRuntimeRoots(data, runtimeRoots)
		end)
	end

	local onAfterSave = profile and (profile :: any).OnAfterSave
	if onAfterSave and onAfterSave.Connect then
		onAfterSave:Connect(function()
			local data = (profile :: any).Data
			DataUtils.RestoreRuntimeRoots(data, capturedRuntimeData)
			capturedRuntimeData = nil
		end)
	end
end

function DataUtils.ApplyRuntimeRootDefaults(data: any, template: any, runtimeRoots: {string}?): ()
	if typeof(data) ~= "table" or typeof(template) ~= "table" or typeof(runtimeRoots) ~= "table" then
		return
	end

	for _, rootPath in runtimeRoots do
		if typeof(rootPath) ~= "string" or rootPath == "" then
			continue
		end

		local pathKeys = GetPathKeys(rootPath)
		local templateValue = GetNestedPathValue(template, pathKeys)
		if templateValue ~= nil then
			SetNestedPathValue(data, pathKeys, DeepClone(templateValue))
		end
	end
end

function DataUtils.RemoveRuntimeLeaderboardData(data: any): boolean
	return DataUtils.RemoveRuntimeRoots(data, {
		"_LeaderboardRanks",
		"_Leaderboards",
		"_Leaderboard",
	})
end

return DataUtils
