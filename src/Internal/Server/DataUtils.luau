--!strict

type Connection = {
	Disconnect: (self: Connection) -> (),
}

type ProfileSignal = {
	Connect: (self: ProfileSignal, listener: (...any) -> ()) -> Connection,
}

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

local function BuildKeepRootLookup(keepRoots: {string}?): {[string]: boolean}?
	if typeof(keepRoots) ~= "table" then
		return nil
	end

	local lookup: {[string]: boolean} = {}
	local hasAny = false
	for _, root in keepRoots do
		if typeof(root) ~= "string" or root == "" then
			continue
		end

		local dotIndex = string.find(root, ".", 1, true)
		local rootSegment = if dotIndex then string.sub(root, 1, dotIndex - 1) else root
		if rootSegment ~= "" then
			lookup[rootSegment] = true
			hasAny = true
		end
	end

	return if hasAny then lookup else nil
end

function DataUtils.CleanData(data: any, template: any, keepRoots: {string}?): ()
	local keepLookup = BuildKeepRootLookup(keepRoots)

	for key in data do
		if keepLookup and typeof(key) == "string" and keepLookup[key] then
			continue
		end

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

local function ShallowCopy(value: any): any
	if getmetatable(value) == nil then
		return table.clone(value)
	end

	local copy = {}
	for key, child in value do
		copy[key] = child
	end

	return copy
end

local function DeepClone(value: any): any
	if typeof(value) ~= "table" then
		return value
	end

	local clone = ShallowCopy(value)
	for key, child in clone do
		if typeof(child) == "table" then
			clone[key] = DeepClone(child)
		end
	end

	return clone
end

DataUtils.DeepClone = DeepClone

local PendingRuntimeCaptures: {[any]: {[string]: any}} = setmetatable({}, { __mode = "k" }) :: any
DataUtils.PendingRuntimeCaptures = PendingRuntimeCaptures

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

function DataUtils.IsArray(value: any): boolean
	if typeof(value) ~= "table" then
		return false
	end

	local length = #value
	if length == 0 then
		return false
	end

	local count = 0
	for key in value do
		if typeof(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > length then
			return false
		end
		count += 1
	end

	return count == length
end

type SkipNode = {[string]: SkipNode | boolean}

local function BuildSkipTree(roots: {string}): SkipNode?
	local tree: SkipNode = {}
	local hasAny = false

	for _, rootPath in roots do
		if typeof(rootPath) ~= "string" or rootPath == "" then
			continue
		end

		local pathKeys = GetPathKeys(rootPath)
		if #pathKeys == 0 then
			continue
		end

		local node: SkipNode = tree
		for i = 1, #pathKeys do
			local key = pathKeys[i]
			local existing = node[key]

			if existing == true then
				break
			end

			if i == #pathKeys then
				node[key] = true
				hasAny = true
			else
				if typeof(existing) ~= "table" then
					local child: SkipNode = {}
					node[key] = child
					existing = child
				end
				node = existing :: SkipNode
			end
		end
	end

	return if hasAny then tree else nil
end

local SkipTreeCache: {[{string}]: SkipNode | false} = setmetatable({}, { __mode = "k" }) :: any

local function GetSkipTree(roots: {string}): SkipNode?
	local cached = SkipTreeCache[roots]
	if cached ~= nil then
		return if cached == false then nil else cached
	end

	local tree = BuildSkipTree(roots)
	SkipTreeCache[roots] = if tree then tree else false

	return tree
end

local function CloneSkipping(value: any, node: SkipNode): any
	local clone = ShallowCopy(value)

	for key, child in clone do
		local skip = if typeof(key) == "string" then node[key] else nil

		if skip == true then
			clone[key] = nil
		elseif typeof(child) == "table" then
			if typeof(skip) == "table" then
				clone[key] = CloneSkipping(child, skip :: SkipNode)
			else
				clone[key] = DeepClone(child)
			end
		end
	end

	return clone
end

function DataUtils.CloneWithoutRoots(data: any, roots: {string}?): any
	if typeof(data) ~= "table" or typeof(roots) ~= "table" then
		return DeepClone(data)
	end

	local skipTree = GetSkipTree(roots)
	if not skipTree then
		return DeepClone(data)
	end

	return CloneSkipping(data, skipTree)
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

local function MergeRestoreRuntimeRoots(data: any, captured: {[string]: any}): ()
	if typeof(data) ~= "table" then
		return
	end

	for rootPath, capturedValue in captured do
		if typeof(rootPath) ~= "string" or rootPath == "" then
			continue
		end

		local pathKeys = GetPathKeys(rootPath)
		local existingValue = GetNestedPathValue(data, pathKeys)

		if existingValue == nil then
			SetNestedPathValue(data, pathKeys, capturedValue)
		elseif typeof(existingValue) == "table" and typeof(capturedValue) == "table" and existingValue ~= capturedValue then
			for key, child in capturedValue do
				if existingValue[key] == nil then
					existingValue[key] = child
				end
			end
		end
	end
end

function DataUtils.GetPendingRuntimeCapture(profile: any): {[string]: any}?
	return PendingRuntimeCaptures[profile]
end

function DataUtils.AttachRuntimeSaveProtection(profile: any, runtimeRoots: {string}?, onErrorSignal: any?): () -> {[string]: any}?
	local function GetPending(): {[string]: any}?
		return PendingRuntimeCaptures[profile]
	end

	if not profile then
		return GetPending
	end

	local pendingCapture: {[string]: any}? = nil
	local errorConnection: Connection? = nil

	local function RestorePending(): ()
		local captured = pendingCapture
		if captured == nil then
			return
		end

		pendingCapture = nil
		if PendingRuntimeCaptures[profile] == captured then
			PendingRuntimeCaptures[profile] = nil
		end
		MergeRestoreRuntimeRoots((profile :: any).Data, captured)
	end

	local function DisconnectError(): ()
		local connection = errorConnection
		errorConnection = nil
		if connection then
			pcall(function()
				connection:Disconnect()
			end)
		end
	end

	local onSave: ProfileSignal? = (profile :: any).OnSave
	if onSave and onSave.Connect then
		onSave:Connect(function()
			RestorePending()

			local data = (profile :: any).Data
			local captured = DataUtils.CaptureAndRemoveRuntimeRoots(data, runtimeRoots)
			pendingCapture = captured
			PendingRuntimeCaptures[profile] = captured
		end)
	end

	local onAfterSave: ProfileSignal? = (profile :: any).OnAfterSave
	if onAfterSave and onAfterSave.Connect then
		onAfterSave:Connect(function()
			RestorePending()
		end)
	end

	local errorSignal: ProfileSignal? = onErrorSignal
	if errorSignal and typeof(errorSignal) == "table" and errorSignal.Connect then
		local ok, connection = pcall(function()
			return errorSignal:Connect(function(_message: any, storeName: any, profileKey: any)
				local isActive = true
				local isActiveFn = (profile :: any).IsActive
				if typeof(isActiveFn) == "function" then
					local activeOk, activeResult = pcall(isActiveFn, profile)
					isActive = activeOk and activeResult == true
				end

				if not isActive then
					DisconnectError()
					return
				end

				if profileKey ~= (profile :: any).Key then
					return
				end

				local profileStore = (profile :: any).ProfileStore
				local expectedStoreName = if typeof(profileStore) == "table" then profileStore.Name else nil
				if typeof(storeName) == "string" and typeof(expectedStoreName) == "string" and storeName ~= expectedStoreName then
					return
				end

				RestorePending()
			end)
		end)

		if ok then
			errorConnection = connection
		end
	end

	local onSessionEnd: ProfileSignal? = (profile :: any).OnSessionEnd
	if errorConnection and onSessionEnd and onSessionEnd.Connect then
		local sessionEndConnection: Connection? = nil
		sessionEndConnection = onSessionEnd:Connect(function()
			DisconnectError()
			if sessionEndConnection then
				sessionEndConnection:Disconnect()
			end
		end)
	end

	return GetPending
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
