--!strict

export type CacheModule = {
	GetFromValueCache: (key: string) -> any?,
	SetInValueCache: (key: string, value: any) -> (),
	GetFromNestedCache: (path: string) -> any?,
	SetInNestedCache: (path: string, value: any) -> (),
	ClearAllCaches: () -> (),
	CleanupCache: () -> (),
}

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

	return {
		GetFromValueCache = GetFromValueCache,
		SetInValueCache = SetInValueCache,
		GetFromNestedCache = GetFromNestedCache,
		SetInNestedCache = SetInNestedCache,
		ClearAllCaches = ClearAllCaches,
		CleanupCache = CleanupCache,
	}
end

return CreateCacheModule
