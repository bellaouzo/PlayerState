--!strict

local Utils = {}

local function DeepCloneTable(value: any): any
	if getmetatable(value) ~= nil then
		local copy = {}
		for key, entry in value do
			copy[key] = if type(entry) == "table" then DeepCloneTable(entry) else entry
		end
		return copy
	end

	local copy = table.clone(value)
	for key, entry in copy do
		if type(entry) == "table" then
			copy[key] = DeepCloneTable(entry)
		end
	end
	return copy
end

function Utils.DeepClone(value: any): any
	return DeepCloneTable(value)
end

return Utils
