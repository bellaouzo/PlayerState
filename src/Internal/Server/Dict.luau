--!strict

local Dict = {}

local function getParentAndDictSlot(replicaData: any, pathKeys: {string}): (any?, string?)
	if #pathKeys == 0 then
		return nil, nil
	end

	local current = replicaData
	for i = 1, #pathKeys - 1 do
		local k = pathKeys[i]
		if typeof(current) ~= "table" then
			return nil, nil
		end
		current = current[k]
		if typeof(current) ~= "table" then
			return nil, nil
		end
	end

	if typeof(current) ~= "table" then
		return nil, nil
	end

	return current, pathKeys[#pathKeys]
end

function Dict.SetInDict(replica: any, pathKeys: {string}, key: string, value: any): boolean
	local parent, slotKey = getParentAndDictSlot(replica.Data, pathKeys)
	if parent == nil or slotKey == nil then
		return false
	end

	local dict = parent[slotKey]

	if typeof(dict) == "table" then
		local fullPath = table.clone(pathKeys)
		table.insert(fullPath, key)

		local ok, res = pcall(replica.Set, replica, fullPath, value)
		return ok and res ~= false
	elseif dict == nil then
		local ok, res = pcall(replica.Set, replica, table.clone(pathKeys), { [key] = value })
		return ok and res ~= false
	end

	return false
end

function Dict.RemoveFromDict(replica: any, pathKeys: {string}, key: string): boolean
	local parent, slotKey = getParentAndDictSlot(replica.Data, pathKeys)
	if parent == nil or slotKey == nil then
		return false
	end

	local dict = parent[slotKey]
	if typeof(dict) ~= "table" then
		return false
	end

	local fullPath = table.clone(pathKeys)
	table.insert(fullPath, key)

	local ok, res = pcall(replica.Set, replica, fullPath, nil)
	return ok and res ~= false
end

return Dict
