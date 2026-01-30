--!strict

export type ConnectionModule = {
	AddConnection: (connection: any) -> (),
	ScheduleCleanup: () -> (),
}

local function CreateConnectionModule(): ConnectionModule
	local activeConnections: {any} = {}
	local connectionCleanupScheduled = false

	local function ScheduleCleanup(): ()
		if connectionCleanupScheduled then
			return
		end

		connectionCleanupScheduled = true
		task.defer(function()
			connectionCleanupScheduled = false

			local validConnections = {}
			for _, connection in activeConnections do
				if typeof(connection) == "table" and connection.Disconnect then
					table.insert(validConnections, connection)
				end
			end

			activeConnections = validConnections
		end)
	end

	local function AddConnection(connection: any): ()
		table.insert(activeConnections, connection)
		ScheduleCleanup()
	end

	return {
		AddConnection = AddConnection,
		ScheduleCleanup = ScheduleCleanup,
	}
end

return CreateConnectionModule
