--!strict

local DataStoreService = game:GetService("DataStoreService")

local DataUtils = require(script.Parent.DataUtils)

local LegacyMigration = {}

export type MigrationResult = {
	applied: boolean,
	legacyFound: boolean,
	markerWritten: boolean,
	keyUsed: string?,
	strategy: string,
	markerPath: string,
	continuous: boolean,
	reason: string,
}

local function DeepClone(value: any): any
	if typeof(value) ~= "table" then
		return value
	end

	local cloned = {}
	for key, child in value do
		cloned[key] = DeepClone(child)
	end

	return cloned
end

local function DeepEqual(a: any, b: any): boolean
	if a == b then
		return true
	end

	if typeof(a) ~= "table" or typeof(b) ~= "table" then
		return false
	end

	for key, value in a do
		if not DeepEqual(value, b[key]) then
			return false
		end
	end

	for key, value in b do
		if not DeepEqual(a[key], value) then
			return false
		end
	end

	return true
end

local function ParsePath(path: string): {string}
	local keys = {}
	for segment in string.gmatch(path, "[^%.]+") do
		table.insert(keys, segment)
	end

	return keys
end

local function GetPath(data: any, path: string): any
	if typeof(data) ~= "table" then
		return nil
	end

	local keys = ParsePath(path)
	if #keys == 0 then
		return nil
	end

	return DataUtils.GetNestedValue(data, keys)
end

local function SetPath(data: any, path: string, value: any): boolean
	if typeof(data) ~= "table" then
		return false
	end

	local keys = ParsePath(path)
	if #keys == 0 then
		return false
	end

	local current = data
	for i = 1, #keys - 1 do
		local key = keys[i]
		if typeof(current[key]) ~= "table" then
			current[key] = {}
		end
		current = current[key]
	end

	current[keys[#keys]] = value

	return true
end

local function GetConfigValue(config: any, key: string, defaultValue: any): any
	if typeof(config) ~= "table" then
		return defaultValue
	end

	if config[key] ~= nil then
		return config[key]
	end

	return defaultValue
end

local function NormalizeStrategy(value: any): string
	if typeof(value) ~= "string" then
		return "Auto"
	end

	local normalized = string.lower(value)
	if normalized == "auto" then
		return "Auto"
	elseif normalized == "overwrite" then
		return "Overwrite"
	elseif normalized == "keepnew" then
		return "KeepNew"
	elseif normalized == "manual" then
		return "Manual"
	elseif normalized == "continuousoverwrite" then
		return "ContinuousOverwrite"
	end

	return value
end

local function NormalizeLegacyConfig(legacyConfig: any): any
	if typeof(legacyConfig) ~= "table" then
		return nil
	end

	local advanced = if typeof(legacyConfig.advanced) == "table" then legacyConfig.advanced else {}
	local advancedMarker = if typeof(advanced.marker) == "table" then advanced.marker else {}
	local advancedPayload = if typeof(advanced.payload) == "table" then advanced.payload else {}
	local advancedManual = if typeof(advanced.manual) == "table" then advanced.manual else {}
	local advancedFetch = if typeof(advanced.fetch) == "table" then advanced.fetch else {}

	local normalized = {}

	normalized.Enabled = GetConfigValue(legacyConfig, "enabled", false)
	normalized.DataStoreName = GetConfigValue(legacyConfig, "store", "")
	normalized.Scope = GetConfigValue(legacyConfig, "scope", nil)
	normalized.MergeStrategy = NormalizeStrategy(GetConfigValue(legacyConfig, "strategy", "Auto"))
	normalized.KeyCandidates = GetConfigValue(legacyConfig, "keys", {"{UserId}"})
	normalized.ProfileStorePayload = false
	normalized.Transform = nil
	normalized.MigrationMarkerPath = "_Migration.LegacyDataStoreV1"
	normalized.WriteMarkerOnNoLegacyData = true
	normalized.FetchLegacyData = nil

	local payloadMode = if typeof(advancedPayload.mode) == "string" then string.lower(advancedPayload.mode) else nil
	if payloadMode == "profilestore" then
		normalized.ProfileStorePayload = true
	elseif payloadMode == "auto" then
		normalized.ProfileStorePayload = false
	end

	if advancedMarker.path ~= nil then
		normalized.MigrationMarkerPath = advancedMarker.path
	end
	if advancedMarker.writeOnNoData ~= nil then
		normalized.WriteMarkerOnNoLegacyData = advancedMarker.writeOnNoData
	end
	if advancedManual.transform ~= nil then
		normalized.Transform = advancedManual.transform
	end
	if advancedFetch.custom ~= nil then
		normalized.FetchLegacyData = advancedFetch.custom
	end

	return normalized
end

local function ResolveCandidateKeys(userId: number, candidates: {string}?): {string}
	local resolved = {}
	local seen: {[string]: boolean} = {}
	local userIdString = tostring(userId)

	local patterns: {string}
	if typeof(candidates) == "table" and #candidates > 0 then
		patterns = candidates
	else
		patterns = {"{UserId}"}
	end

	for _, candidate in patterns do
		if typeof(candidate) ~= "string" or candidate == "" then
			continue
		end

		local key = candidate:gsub("{UserId}", userIdString)
		if key ~= "" and not seen[key] then
			table.insert(resolved, key)
			seen[key] = true
		end
	end

	return resolved
end

local function ExtractLegacyPayload(payload: any, treatAsProfileStore: boolean): any
	if typeof(payload) ~= "table" then
		return nil
	end

	if treatAsProfileStore then
		if typeof(payload.Data) == "table" then
			return payload.Data
		end
		return nil
	end

	if typeof(payload.Data) == "table" then
		return payload.Data
	end

	return payload
end

local function MergeOverwrite(currentData: any, legacyData: any): any
	if typeof(legacyData) ~= "table" then
		return currentData
	end

	for key, legacyValue in legacyData do
		if typeof(legacyValue) == "table" and typeof(currentData[key]) == "table" then
			MergeOverwrite(currentData[key], legacyValue)
		else
			currentData[key] = DeepClone(legacyValue)
		end
	end

	return currentData
end

local function MergeKeepNew(currentData: any, _legacyData: any): any
	return currentData
end

local function MergeAuto(currentData: any, templateData: any, legacyData: any): any
	if typeof(legacyData) ~= "table" then
		return currentData
	end

	for key, legacyValue in legacyData do
		local currentValue = currentData[key]
		local templateValue = if typeof(templateData) == "table" then templateData[key] else nil

		if typeof(legacyValue) == "table" and typeof(currentValue) == "table" then
			MergeAuto(currentValue, templateValue, legacyValue)
		elseif currentValue == nil or DeepEqual(currentValue, templateValue) then
			currentData[key] = DeepClone(legacyValue)
		end
	end

	return currentData
end

local function GetLegacyStore(legacyConfig: any): any?
	local storeName = legacyConfig and legacyConfig.DataStoreName
	if typeof(storeName) ~= "string" or storeName == "" then
		return nil
	end

	local scope = legacyConfig.Scope
	if scope ~= nil and typeof(scope) ~= "string" then
		scope = nil
	end

	local success, store = pcall(function()
		if scope ~= nil and scope ~= "" then
			return DataStoreService:GetDataStore(storeName, scope)
		end

		return DataStoreService:GetDataStore(storeName)
	end)

	if not success then
		warn(`[PlayerState] Failed to initialize legacy DataStore "{storeName}"`)
		
		return nil
	end

	return store
end

local function FetchLegacyData(store: any, keyCandidates: {string}): (any?, string?)
	for _, key in keyCandidates do
		local success, data = pcall(function()
			return store:GetAsync(key)
		end)

		if success and data ~= nil then
			return data, key
		end
	end

	return nil, nil
end

function LegacyMigration.TryMigrateProfile(
	profileData: any,
	template: any,
	userId: number,
	player: Player?,
	legacyConfig: any,
	runtimeRoots: {string}
): MigrationResult
	local result: MigrationResult = {
		applied = false,
		legacyFound = false,
		markerWritten = false,
		keyUsed = nil,
		strategy = "Auto",
		markerPath = "_Migration.LegacyDataStoreV1",
		continuous = false,
		reason = "disabled",
	}

	if typeof(profileData) ~= "table" or typeof(template) ~= "table" then
		return result
	end

	local normalizedConfig = NormalizeLegacyConfig(legacyConfig)
	if typeof(normalizedConfig) ~= "table" or not normalizedConfig.Enabled then
		return result
	end

	local rawStrategy = NormalizeStrategy(normalizedConfig.MergeStrategy)

	local continuousOverwrite = rawStrategy == "ContinuousOverwrite"
	result.continuous = continuousOverwrite

	local markerPath = normalizedConfig.MigrationMarkerPath
	if typeof(markerPath) ~= "string" or markerPath == "" then
		markerPath = "_Migration.LegacyDataStoreV1"
	end
	result.markerPath = markerPath
	result.strategy = if continuousOverwrite then "Overwrite" else rawStrategy

	if not continuousOverwrite and GetPath(profileData, markerPath) == true then
		result.reason = "already_marked"
		return result
	end

	local keyCandidates = ResolveCandidateKeys(userId, normalizedConfig.KeyCandidates)
	local customFetcher = normalizedConfig.FetchLegacyData
	local legacyPayload
	local keyUsed

	if typeof(customFetcher) == "function" then
		local ok, payloadResult, keyResult = pcall(customFetcher, keyCandidates, userId, player)
		if ok then
			legacyPayload = payloadResult
			keyUsed = keyResult
		else
			warn("[PlayerState] LegacyDataStore.FetchLegacyData failed")
			result.reason = "fetch_failed"
		end
	else
		local store = GetLegacyStore(normalizedConfig)
		if not store then
			result.reason = "store_unavailable"
			return result
		end
		legacyPayload, keyUsed = FetchLegacyData(store, keyCandidates)
	end

	result.keyUsed = keyUsed
	result.legacyFound = legacyPayload ~= nil

	local writeMarkerOnNoData = normalizedConfig.WriteMarkerOnNoLegacyData
	if typeof(writeMarkerOnNoData) ~= "boolean" then
		writeMarkerOnNoData = true
	end

	if legacyPayload == nil then
		if writeMarkerOnNoData and not continuousOverwrite then
			SetPath(profileData, markerPath, true)
			result.markerWritten = true
		end
		if result.reason ~= "fetch_failed" then
			result.reason = "no_legacy_data"
		end
		return result
	end

	local treatAsProfileStore = normalizedConfig.ProfileStorePayload == true
	local legacyData = ExtractLegacyPayload(legacyPayload, treatAsProfileStore)
	if typeof(legacyData) ~= "table" then
		if writeMarkerOnNoData and not continuousOverwrite then
			SetPath(profileData, markerPath, true)
			result.markerWritten = true
		end
		result.reason = "invalid_payload"
		return result
	end

	legacyData = DeepClone(legacyData)
	DataUtils.RemoveRuntimeRoots(legacyData, runtimeRoots)

	local strategy = if continuousOverwrite then "Overwrite" else rawStrategy

	if strategy == "Overwrite" then
		MergeOverwrite(profileData, legacyData)
		result.reason = "applied"
	elseif strategy == "KeepNew" then
		MergeKeepNew(profileData, legacyData)
		result.reason = "applied"
	elseif strategy == "Manual" then
		local transform = normalizedConfig.Transform
		if typeof(transform) ~= "function" then
			warn("[PlayerState] LegacyDataStore.MergeStrategy is Manual, but Transform is missing")
			result.reason = "manual_transform_missing"
		else
			local success, transformed = pcall(transform, legacyData, template, player)
			if success and typeof(transformed) == "table" then
				DataUtils.RemoveRuntimeRoots(transformed, runtimeRoots)
				MergeOverwrite(profileData, transformed)
				result.reason = "applied"
			elseif not success then
				warn("[PlayerState] Legacy data transform failed")
				result.reason = "manual_transform_failed"
			end
		end
	else
		MergeAuto(profileData, template, legacyData)
		result.reason = "applied"
	end

	if not continuousOverwrite then
		SetPath(profileData, markerPath, true)
		result.markerWritten = true
	end

	result.applied = true
	if result.reason == "disabled" or result.reason == "no_legacy_data" or result.reason == "already_marked" then
		result.reason = "applied"
	end

	return result
end

return LegacyMigration
