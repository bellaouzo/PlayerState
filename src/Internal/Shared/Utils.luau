--!strict

local Utils = {}

function Utils.DeepClone(value: any): any
	local copy = {}

	for key, entry in value do
		copy[key] = if typeof(entry) == "table" then Utils.DeepClone(entry) else entry
	end

	return copy
end

return Utils
