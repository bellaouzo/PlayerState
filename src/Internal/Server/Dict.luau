--!strict

local Dict = {}

function Dict.SetInDict(replica: any, pathKeys: {string}, currentDict: {[any]: any}, key: string, value: any): boolean
	currentDict[key] = value

	local success = pcall(replica.Set, replica, pathKeys, currentDict)
	return success
end

function Dict.RemoveFromDict(replica: any, pathKeys: {string}, currentDict: {[any]: any}, key: string): boolean
	if typeof(currentDict) ~= "table" then
		return false
	end

	currentDict[key] = nil

	local success = pcall(replica.Set, replica, pathKeys, currentDict)
	return success
end

return Dict
