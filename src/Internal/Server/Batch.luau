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
	HasPendingBatch: (player: Player) -> boolean,
}

local function CreateBatchModule(
	config: any,
	getPathKeys: (path: string) -> {string},
	validateReplica: (replica: any?) -> boolean,
	getReplica: (player: Player) -> any?,
	onBatchCommitted: ((Player, {BatchOperation}) -> ())?
): BatchModule
	local batchOperations: {[Player]: {BatchOperation}} = {}
	local batchScheduled: {[Player]: thread?} = {}

	local function ProcessBatchOperations(player: Player): ()
		local playerBatch = batchOperations[player]
		if not playerBatch or #playerBatch == 0 then
			return
		end

		local replica = getReplica(player)
		if not replica or not validateReplica(replica) then
			warn(`[PlayerState] Cannot process batch operations - invalid replica for {player.Name}`)
			batchOperations[player] = nil
			batchScheduled[player] = nil
			
			return
		end

		batchOperations[player] = nil
		batchScheduled[player] = nil

		local operationCount = #playerBatch
		local pathKeysList: {{string}} = table.create(operationCount)
		local pathStrings: {string} = table.create(operationCount)
		local lastIndexByPath: {[string]: number} = {}

		for i = 1, operationCount do
			local pathKeys = getPathKeys(playerBatch[i].path)
			local pathString = table.concat(pathKeys, ".")
			pathKeysList[i] = pathKeys
			pathStrings[i] = pathString
			lastIndexByPath[pathString] = i
		end

		local hasPrefixConflict = false
		for i = 1, operationCount do
			local pathKeys = pathKeysList[i]
			if #pathKeys < 2 then
				continue
			end

			local prefix = pathKeys[1]
			for depth = 1, #pathKeys - 1 do
				if depth > 1 then
					prefix = prefix .. "." .. pathKeys[depth]
				end

				if lastIndexByPath[prefix] ~= nil then
					hasPrefixConflict = true
					break
				end
			end

			if hasPrefixConflict then
				break
			end
		end

		local function ApplySet(pathKeys: {string}, value: any): ()
			local setPath = pathKeys
			local setValue = value
			local node = replica.Data

			for depth = 1, #pathKeys - 1 do
				local child = if typeof(node) == "table" then node[pathKeys[depth]] else nil
				if child == nil then
					if value == nil then
						return
					end

					local subtree = value
					for index = #pathKeys, depth + 1, -1 do
						subtree = {[pathKeys[index]] = subtree}
					end
					setPath = table.move(pathKeys, 1, depth, 1, {})
					setValue = subtree
					break
				end
				node = child
			end

			local ok, res = pcall(replica.Set, replica, setPath, setValue)
			if not (ok and res ~= false) then
				warn(`[PlayerState] Batch Set failed for {player.Name}`)
			end
		end

		local function ApplySetValues(pathKeys: {string}, values: {[string]: any}, label: string): ()
			if next(values) == nil then
				return
			end

			if #pathKeys == 1 and (replica.Data :: any)[pathKeys[1]] == nil then
				local ok, res = pcall(replica.Set, replica, pathKeys, values)
				if not (ok and res ~= false) then
					warn(`[PlayerState] Batch {label} SetValues failed for {player.Name}`)
				end
				return
			end

			local ok, res = pcall(replica.SetValues, replica, pathKeys, values)
			if not (ok and res ~= false) then
				warn(`[PlayerState] Batch {label} SetValues failed for {player.Name}`)
			end
		end

		replica:BeginBatch()

		if hasPrefixConflict then
			for i = 1, operationCount do
				ApplySet(pathKeysList[i], playerBatch[i].value)
			end
		else
			local groupedOps: {[string]: {[string]: any}} = {}
			local groupedOrder: {string} = {}
			local singleOps: {{path: {string}, value: any}} = {}
			local rootLevelOps: {[string]: any} = {}

			for i = 1, operationCount do
				if lastIndexByPath[pathStrings[i]] ~= i then
					continue
				end

				local pathKeys = pathKeysList[i]
				local value = playerBatch[i].value

				if value == nil or #pathKeys == 0 or #pathKeys > 2 then
					singleOps[#singleOps + 1] = {path = pathKeys, value = value}
				elseif #pathKeys == 1 then
					rootLevelOps[pathKeys[1]] = value
				else
					local rootPath = pathKeys[1]
					local group = groupedOps[rootPath]
					if not group then
						group = {}
						groupedOps[rootPath] = group
						groupedOrder[#groupedOrder + 1] = rootPath
					end
					group[pathKeys[2]] = value
				end
			end

			ApplySetValues({}, rootLevelOps, "root")

			for _, rootPath in groupedOrder do
				ApplySetValues({rootPath}, groupedOps[rootPath], "grouped")
			end

			for i = 1, #singleOps do
				local operation = singleOps[i]
				ApplySet(operation.path, operation.value)
			end
		end

		replica:EndBatch()

		if onBatchCommitted then
			local committedOps = table.create(operationCount)
			table.move(playerBatch, 1, operationCount, 1, committedOps)
			onBatchCommitted(player, committedOps)
		end
	end

	local function HasPendingBatch(player: Player): boolean
		local playerBatch = batchOperations[player]
		return playerBatch ~= nil and #playerBatch > 0
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
		HasPendingBatch = HasPendingBatch,
	}
end

return CreateBatchModule
