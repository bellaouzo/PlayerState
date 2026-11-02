--!strict

local Array = {}

function Array.AddToArray(replica: any, pathKeys: {string}, item: any): (boolean, string?)
	local success, result = pcall(replica.TableInsert, replica, pathKeys, item)
	if not success then
		return false, result
	end

	return success, nil
end

function Array.RemoveFromArray(replica: any, pathKeys: {string}, index: number): (boolean, string?)
	local success, result = pcall(replica.TableRemove, replica, pathKeys, index)
	if not success then
		return false, result
	end

	return success, nil
end

function Array.UpdateArrayItem(replica: any, pathKeys: {string}, index: number, newItem: any): boolean
	local fullPath: {string | number} = table.clone(pathKeys)
	table.insert(fullPath, index)

	local ok, res = pcall(replica.Set, replica, fullPath :: any, newItem)
	return ok and res ~= false
end

return Array
