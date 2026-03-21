--!strict

export type CacheModule = {
	GetFromValueCache: (key: string) -> any?,
	SetInValueCache: (key: string, value: any) -> (),
	GetFromNestedCache: (path: string) -> any?,
	SetInNestedCache: (path: string, value: any) -> (),
	ClearAllCaches: () -> (),
	CleanupCache: () -> (),
	InvalidateForMutationPath: (path: {any}) -> (),
}

local function pathsOverlap(mutDot: string, cachedPath: string): boolean
	if mutDot == cachedPath then
		return true
	end

	local mutLen = #mutDot
	local cachedLen = #cachedPath

	if cachedLen > mutLen and string.sub(cachedPath, 1, mutLen + 1) == mutDot .. "." then
		return true
	end

	if mutLen > cachedLen and string.sub(mutDot, 1, cachedLen + 1) == cachedPath .. "." then
		return true
	end

	return false
end

local function CreateCacheModule(cacheDuration: number, cacheCleanupInterval: number): CacheModule
	local valueCache: {[string]: {value: any, timestamp: number}} = {}
	local nestedValueCache: {[string]: {value: any, timestamp: number}} = {}
	local lastCacheCleanup = 0

	local function GetFromValueCache(key: string): any?
		local currentTime = tick()
		local cached = valueCache[key]
		if cached and currentTime - cached.timestamp < cacheDuration then
			return cached.value
		end
		return nil
	end

	local function SetInValueCache(key: string, value: any): ()
		local currentTime = tick()
		valueCache[key] = {value = value, timestamp = currentTime}
	end

	local function GetFromNestedCache(path: string): any?
		local currentTime = tick()
		local cached = nestedValueCache[path]
		if cached and currentTime - cached.timestamp < cacheDuration then
			return cached.value
		end
		return nil
	end

	local function SetInNestedCache(path: string, value: any): ()
		local currentTime = tick()
		nestedValueCache[path] = {value = value, timestamp = currentTime}
	end

	local function ClearAllCaches(): ()
		table.clear(valueCache)
		table.clear(nestedValueCache)
	end

	local function CleanupCache(): ()
		local currentTime = tick()

		if currentTime - lastCacheCleanup < cacheCleanupInterval then
			return
		end

		lastCacheCleanup = currentTime

		local keysToRemove = {}

		for key, cached in valueCache do
			if currentTime - cached.timestamp > cacheDuration * 10 then
				table.insert(keysToRemove, key)
			end
		end

		for _, key in keysToRemove do
			valueCache[key] = nil
		end

		table.clear(keysToRemove)

		for key, cached in nestedValueCache do
			if currentTime - cached.timestamp > cacheDuration * 10 then
				table.insert(keysToRemove, key)
			end
		end

		for _, key in keysToRemove do
			nestedValueCache[key] = nil
		end
	end

	local function InvalidateForMutationPath(path: {any}): ()
		if #path == 0 then
			ClearAllCaches()
			return
		end

		local top = path[1]
		valueCache[tostring(top)] = nil

		local mutParts: {string} = table.create(#path)
		for i = 1, #path do
			mutParts[i] = tostring(path[i])
		end
		local mutDot = table.concat(mutParts, ".")

		local toRemove: {string} = {}
		for cachedPath in nestedValueCache do
			if pathsOverlap(mutDot, cachedPath) then
				table.insert(toRemove, cachedPath)
			end
		end

		for _, cachedPath in toRemove do
			nestedValueCache[cachedPath] = nil
		end
	end

	return {
		GetFromValueCache = GetFromValueCache,
		SetInValueCache = SetInValueCache,
		GetFromNestedCache = GetFromNestedCache,
		SetInNestedCache = SetInNestedCache,
		ClearAllCaches = ClearAllCaches,
		CleanupCache = CleanupCache,
		InvalidateForMutationPath = InvalidateForMutationPath,
	}
end

return CreateCacheModule
