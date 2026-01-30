--!strict

export type PathCacheModule = {
	GetPathKeys: (path: string) -> {string},
	ClearCache: () -> (),
}

local function CreatePathCache(maxCacheSize: number): PathCacheModule
	local pathCache: {[string]: {string}} = {}
	local pathCacheSize: number = 0

	local function GetPathKeys(path: string): {string}
		local cached = pathCache[path]
		if cached then
			return cached
		end

		local keys = string.split(path, ".")
		pathCache[path] = keys
		pathCacheSize += 1

		if pathCacheSize > maxCacheSize then
			local clearCount = math.floor(maxCacheSize * 0.2)
			local cleared = 0

			for cachedPath in pathCache do
				pathCache[cachedPath] = nil
				cleared += 1
				if cleared >= clearCount then
					break
				end
			end

			pathCacheSize -= cleared
		end

		return keys
	end

	local function ClearCache(): ()
		table.clear(pathCache)
		pathCacheSize = 0
	end

	return {
		GetPathKeys = GetPathKeys,
		ClearCache = ClearCache,
	}
end

return CreatePathCache
