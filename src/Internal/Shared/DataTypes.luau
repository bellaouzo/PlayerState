--!nocheck
--!nolint UnknownGlobal

local DefaultData = require(script.Parent.Parent.Parent.DefaultData)
local Config = require(script.Parent.Parent.Parent.PlayerStateConfig)

type PlayerData = typeof(DefaultData)
type SharedData = typeof(Config.Server.SharedSession)

type function DataPaths(root, mode, skip)
	local wanted = mode:value()
	local skipped = {}

	local function addSkip(option)
		if option:is("singleton") then
			local name = option:value()
			if type(name) == "string" then
				skipped[name] = true
			end
		end
	end

	if skip:is("union") then
		for _, option in skip:components() do
			addSkip(option)
		end
	else
		addSkip(skip)
	end

	local results = {}

	local function walk(node, prefix, depth)
		if not node:is("table") then
			return
		end

		for key, access in node:properties() do
			if key:is("singleton") then
				local name = key:value()
				if type(name) == "string" and not (depth == 0 and skipped[name]) then
					local path = if prefix == "" then name else prefix .. "." .. name
					local value = access.read or access.write
					if value then
						local matches = wanted == "key"
							or wanted == "path"
							or (wanted == "number" and value:is("number"))
							or (wanted == "table" and value:is("table"))
						if matches then
							table.insert(results, types.singleton(path))
						end
						if wanted ~= "key" and depth < 6 then
							walk(value, path, depth + 1)
						end
					end
				end
			end
		end
	end

	walk(root, "", 0)

	if #results == 0 then
		return types.string
	elseif #results == 1 then
		return results[1]
	end

	return types.unionof(table.unpack(results))
end

type Loose<T> = T | string

type ServerSkip = "leaderstats"
type ClientSkip = "leaderstats" | "Server"

export type DataKey = Loose<DataPaths<PlayerData, "key", ServerSkip>>
export type DataPath = Loose<DataPaths<PlayerData, "path", ServerSkip>>
export type NumberPath = Loose<DataPaths<PlayerData, "number", ServerSkip>>
export type TablePath = Loose<DataPaths<PlayerData, "table", ServerSkip>>

export type ClientDataKey = Loose<DataPaths<PlayerData, "key", ClientSkip>>
export type ClientDataPath = Loose<DataPaths<PlayerData, "path", ClientSkip>>
export type ClientTablePath = Loose<DataPaths<PlayerData, "table", ClientSkip>>
export type ClientNumberPath = Loose<DataPaths<PlayerData, "number", ClientSkip>>

export type SharedKey = Loose<DataPaths<SharedData, "key", nil>>
export type SharedPath = Loose<DataPaths<SharedData, "path", nil>>

return {}
