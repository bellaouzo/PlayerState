--!strict

local Validation = {}

function Validation.ValidateReplica(replica: any?): boolean
	return replica ~= nil and replica:IsActive()
end

function Validation.WaitForData(
	dataReady: () -> boolean,
	validateReplica: (replica: any?) -> boolean,
	getReplica: () -> any?,
	readyEvent: BindableEvent?
): boolean
	if dataReady() and validateReplica(getReplica()) then
		return true
	end

	if readyEvent ~= nil then
		readyEvent.Event:Wait()
		if dataReady() and validateReplica(getReplica()) then
			return true
		end
	end

	while not (dataReady() and validateReplica(getReplica())) do
		task.wait(0.05)
	end

	return true
end

return Validation
