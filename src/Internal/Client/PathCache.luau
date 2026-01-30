--!strict

export type PathCacheModule = {
	GetPathKeys: (path: string) -> {string},
	ClearCache: () -> (),
}

local function CreatePathCache(maxPathCacheSize: number): PathCacheModule
	local pathCache: {[string]: {string}} = {}

	local function GetPathKeys(path: string): {string}
		local cached = pathCache[path]
		if cached then
			return cached
		end

		local keys = string.split(path, ".")
		pathCache[path] = keys

		local cacheSize = 0
		for _ in pathCache do
			cacheSize += 1
		end

		if cacheSize > maxPathCacheSize then
			local keysToRemove = {}
			local count = 0
			for cachedPath in pathCache do
				table.insert(keysToRemove, cachedPath)
				count += 1
				if count > 100 then
					break
				end
			end

			for _, keyToRemove in keysToRemove do
				pathCache[keyToRemove] = nil
			end
		end

		return keys
	end

	local function ClearCache(): ()
		table.clear(pathCache)
	end

	return {
		GetPathKeys = GetPathKeys,
		ClearCache = ClearCache,
	}
end

return CreatePathCache
