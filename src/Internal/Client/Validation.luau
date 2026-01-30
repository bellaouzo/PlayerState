--!strict

local Validation = {}

function Validation.ValidateReplica(replica: any?): boolean
	return replica ~= nil and replica:IsActive()
end

function Validation.WaitForData(dataReady: () -> boolean, validateReplica: (replica: any?) -> boolean, getReplica: () -> any?): boolean
	while not (dataReady() and validateReplica(getReplica())) do
		task.wait(0.1)
	end

	return true
end

return Validation
