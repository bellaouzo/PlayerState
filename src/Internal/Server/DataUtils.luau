--!strict

local DataUtils = {}

local INT32_MAX = 2147483647
local INT32_MIN = -2147483648

function DataUtils.GetAppropriateValueType(value: number): string
	if value % 1 ~= 0 then
		return "NumberValue"
	elseif value > INT32_MAX or value < INT32_MIN then
		return "NumberValue"
	else
		return "IntValue"
	end
end

function DataUtils.GetNestedValue(data: any, pathKeys: {string}): any
	local current = data

	for i = 1, #pathKeys do
		local key = pathKeys[i]
		if typeof(current) ~= "table" then
			return nil
		end
		current = current[key]
		if current == nil then
			return nil
		end
	end

	return current
end

function DataUtils.CleanData(data: any, template: any): ()
	for key in data do
		if template[key] == nil then
			data[key] = nil
		elseif typeof(data[key]) == "table" and typeof(template[key]) == "table" then
			if next(template[key]) == nil then
				continue
			end

			DataUtils.CleanData(data[key], template[key])
		end
	end
end

function DataUtils.RemoveRuntimeLeaderboardData(data: any): boolean
	if typeof(data) ~= "table" then
		return false
	end

	local removed = false

	if data._LeaderboardRanks ~= nil then
		data._LeaderboardRanks = nil
		removed = true
	end

	if data._Leaderboards ~= nil then
		data._Leaderboards = nil
		removed = true
	end

	if data._Leaderboard ~= nil then
		data._Leaderboard = nil
		removed = true
	end

	return removed
end

return DataUtils
