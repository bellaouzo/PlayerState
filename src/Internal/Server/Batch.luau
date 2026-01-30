--!strict

export type BatchOperation = {
	path: string,
	value: any,
}

export type BatchModule = {
	ScheduleBatchOperation: (player: Player, operation: BatchOperation) -> (),
	ProcessBatchOperations: (player: Player) -> (),
	FlushBatch: (player: Player) -> (),
	ClearPlayerBatch: (player: Player) -> (),
}

local function CreateBatchModule(config: any, getPathKeys: (path: string) -> {string}, validateReplica: (replica: any?) -> boolean, getReplica: (player: Player) -> any?): BatchModule
	local batchOperations: {[Player]: {BatchOperation}} = {}
	local batchScheduled: {[Player]: thread?} = {}

	local function ProcessBatchOperations(player: Player): ()
		local playerBatch = batchOperations[player]
		if not playerBatch or #playerBatch == 0 then
			return
		end

		local replica = getReplica(player)
		if not validateReplica(replica) then
			warn(`[PlayerState] Cannot process batch operations - invalid replica for {player.Name}`)
			batchOperations[player] = nil
			batchScheduled[player] = nil
			return
		end

		local groupedOps: {[string]: {[string]: any}} = {}
		local singleOps: {{path: {string}, value: any}} = {}
		local rootLevelOps: {[string]: any} = {}

		for i = 1, #playerBatch do
			local operation = playerBatch[i]
			local pathKeys = getPathKeys(operation.path)

			if #pathKeys == 1 then
				rootLevelOps[pathKeys[1]] = operation.value
			elseif #pathKeys == 2 then
				local rootPath = pathKeys[1]
				if not groupedOps[rootPath] then
					groupedOps[rootPath] = {}
				end
				groupedOps[rootPath][pathKeys[2]] = operation.value
			else
				singleOps[#singleOps + 1] = {path = pathKeys, value = operation.value}
			end
		end

		replica:BeginBatch()

		if next(rootLevelOps) then
			local success = pcall(replica.SetValues, replica, {}, rootLevelOps)
			if not success then
				warn(`[PlayerState] Batch root SetValues failed for {player.Name}`)
			end
		end

		for rootPath, values in groupedOps do
			local success = pcall(replica.SetValues, replica, {rootPath}, values)
			if not success then
				warn(`[PlayerState] Batch grouped SetValues failed for {player.Name}`)
			end
		end

		for i = 1, #singleOps do
			local operation = singleOps[i]
			local success = pcall(replica.Set, replica, operation.path, operation.value)
			if not success then
				warn(`[PlayerState] Batch Set failed for {player.Name}`)
			end
		end

		replica:EndBatch()

		batchOperations[player] = nil
		batchScheduled[player] = nil
	end

	local function ScheduleBatchOperation(player: Player, operation: BatchOperation): ()
		local playerBatch = batchOperations[player]
		if not playerBatch then
			playerBatch = {}
			batchOperations[player] = playerBatch
		end

		playerBatch[#playerBatch + 1] = operation

		if #playerBatch >= config.BatchSize then
			local scheduledThread = batchScheduled[player]
			if scheduledThread then
				task.cancel(scheduledThread)
				batchScheduled[player] = nil
			end
			ProcessBatchOperations(player)
			return
		end

		if not batchScheduled[player] then
			batchScheduled[player] = task.delay(config.BatchDelay, function()
				ProcessBatchOperations(player)
			end)
		end
	end

	local function FlushBatch(player: Player): ()
		local scheduledThread = batchScheduled[player]
		if scheduledThread then
			task.cancel(scheduledThread)
			batchScheduled[player] = nil
		end

		ProcessBatchOperations(player)
	end

	local function ClearPlayerBatch(player: Player): ()
		if batchOperations[player] then
			ProcessBatchOperations(player)
			batchOperations[player] = nil
		end
		local scheduledThread = batchScheduled[player]
		if scheduledThread then
			task.cancel(scheduledThread)
			batchScheduled[player] = nil
		end
	end

	return {
		ScheduleBatchOperation = ScheduleBatchOperation,
		ProcessBatchOperations = ProcessBatchOperations,
		FlushBatch = FlushBatch,
		ClearPlayerBatch = ClearPlayerBatch,
	}
end

return CreateBatchModule
