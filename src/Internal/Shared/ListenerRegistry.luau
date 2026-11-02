--!strict

export type Connection = {
	Connected: boolean,
	Disconnect: (self: Connection) -> (),
}

export type Callback = (newValue: any, oldValue: any, info: any) -> ()

export type Options = {
	getPathKeys: (path: string) -> {string},
	readValue: (pathKeys: {string}, pathOrKey: string) -> any,
	onChange: ((action: string, path: {any}) -> ())?,
}

export type Registry = {
	Bind: (self: Registry, replica: any) -> (),
	Unbind: (self: Registry) -> (),
	Connect: (self: Registry, pathOrKey: string, callback: Callback) -> Connection,
	Clear: (self: Registry) -> (),
	GetListenerCount: (self: Registry) -> number,
}

type Listener = {
	pathOrKey: string,
	pathKeys: {string},
	bucketKey: string?,
	callback: Callback,
	connection: Connection,
}

local ROOT_PATH = "."

local function SegmentMatches(segment: any, key: string): boolean
	return segment == key or tostring(segment) == key
end

local function LookupKey(container: {[any]: any}, key: string): any
	local value = container[key]
	if value == nil then
		local numericKey = tonumber(key)
		if numericKey ~= nil then
			value = container[numericKey]
		end
	end
	return value
end

local function WalkFrom(value: any, pathKeys: {string}, startIndex: number): any
	local current = value
	for index = startIndex, #pathKeys do
		if typeof(current) ~= "table" then
			return nil
		end
		current = LookupKey(current, pathKeys[index])
	end
	return current
end

local function FireWithRead(
	callback: Callback,
	readValue: (pathKeys: {string}, pathOrKey: string) -> any,
	pathKeys: {string},
	pathOrKey: string,
	oldValue: any,
	info: any
): ()
	callback(readValue(pathKeys, pathOrKey), oldValue, info)
end

local function FireRoot(listener: Listener, action: string, path: {any}, param1: any, param2: any): ()
	local callback = listener.callback

	if action == "Set" then
		task.spawn(callback, param1, param2, {action = action, path = path})
	elseif action == "SetValues" then
		task.spawn(callback, param1, nil, {action = action, path = path})
	elseif action == "TableInsert" then
		task.spawn(callback, param1, nil, {action = action, path = path, index = param2})
	elseif action == "TableRemove" then
		task.spawn(callback, nil, param1, {action = action, path = path, index = param2})
	end
end

local function FirePath(
	listener: Listener,
	readValue: (pathKeys: {string}, pathOrKey: string) -> any,
	action: string,
	path: {any},
	param1: any,
	param2: any
): ()
	local pathKeys = listener.pathKeys
	local keyCount = #pathKeys
	local pathLength = #path
	local sharedLength = if pathLength < keyCount then pathLength else keyCount

	for index = 1, sharedLength do
		if not SegmentMatches(path[index], pathKeys[index]) then
			return
		end
	end

	local callback = listener.callback

	if pathLength < keyCount then
		if action == "Set" then
			local oldChild = WalkFrom(param2, pathKeys, pathLength + 1)
			local newChild = WalkFrom(param1, pathKeys, pathLength + 1)
			if newChild ~= oldChild then
				task.spawn(FireWithRead, callback, readValue, pathKeys, listener.pathOrKey, oldChild, {action = "Set", path = path})
			end
		elseif action == "SetValues" then
			if typeof(param1) == "table" and LookupKey(param1, pathKeys[pathLength + 1]) ~= nil then
				task.spawn(FireWithRead, callback, readValue, pathKeys, listener.pathOrKey, nil, {action = "SetValues", path = path})
			end
		end
		return
	end

	local isExactMatch = pathLength == keyCount

	if action == "Set" then
		if isExactMatch then
			task.spawn(callback, param1, param2, table.clone(pathKeys))
		else
			task.spawn(FireWithRead, callback, readValue, pathKeys, listener.pathOrKey, nil, {action = action, path = path})
		end
	elseif action == "SetValues" then
		if isExactMatch then
			task.spawn(callback, param1, nil, {action = action, path = path})
		else
			task.spawn(FireWithRead, callback, readValue, pathKeys, listener.pathOrKey, nil, {action = action, path = path})
		end
	elseif action == "TableInsert" then
		task.spawn(callback, param1, nil, {action = action, path = path, index = param2})
	elseif action == "TableRemove" then
		task.spawn(callback, nil, param1, {action = action, path = path, index = param2})
	end
end

local ListenerRegistry = {}

function ListenerRegistry.new(options: Options): Registry
	local getPathKeys = options.getPathKeys
	local readValue = options.readValue
	local onChange = options.onChange

	local rootListeners: {Listener} = {}
	local buckets: {[string]: {Listener}} = {}
	local listenerCount = 0
	local replicaConnection: any = nil
	local boundReplica: any = nil
	local Dispatch: (action: string, path: {any}, param1: any, param2: any) -> ()

	local function ReleaseConnection(): ()
		local connection = replicaConnection
		replicaConnection = nil
		if connection ~= nil then
			connection:Disconnect()
		end
	end

	local function SyncConnection(): ()
		local wanted = boundReplica ~= nil and (listenerCount > 0 or onChange ~= nil)
		if wanted and replicaConnection == nil then
			replicaConnection = boundReplica:OnChange(Dispatch)
		elseif not wanted and replicaConnection ~= nil then
			ReleaseConnection()
		end
	end

	local function RemoveListener(listener: Listener): ()
		local list: {Listener}?
		local bucketKey = listener.bucketKey
		if bucketKey == nil then
			list = rootListeners
		else
			list = buckets[bucketKey]
		end

		if list == nil then
			return
		end

		local index = table.find(list, listener)
		if index == nil then
			return
		end

		table.remove(list, index)
		listenerCount -= 1

		if bucketKey ~= nil and #list == 0 then
			buckets[bucketKey] = nil
		end

		SyncConnection()
	end

	local function DispatchBucket(bucket: {Listener}?, action: string, path: {any}, param1: any, param2: any): ()
		if bucket == nil or #bucket == 0 then
			return
		end

		for _, listener in table.clone(bucket) do
			if listener.connection.Connected then
				FirePath(listener, readValue, action, path, param1, param2)
			end
		end
	end

	Dispatch = function(action: string, path: {any}, param1: any, param2: any): ()
		if onChange ~= nil then
			onChange(action, path)
		end

		if listenerCount == 0 then
			return
		end

		if #rootListeners > 0 then
			for _, listener in table.clone(rootListeners) do
				if listener.connection.Connected then
					FireRoot(listener, action, path, param1, param2)
				end
			end
		end

		if #path >= 1 then
			DispatchBucket(buckets[tostring(path[1])], action, path, param1, param2)
		elseif action == "SetValues" and typeof(param1) == "table" then
			local visited: {[string]: boolean} = {}
			for key in param1 do
				local bucketKey = tostring(key)
				if not visited[bucketKey] then
					visited[bucketKey] = true
					DispatchBucket(buckets[bucketKey], action, path, param1, param2)
				end
			end
		end
	end

	local registry = {} :: Registry

	function registry.Unbind(_self: Registry): ()
		boundReplica = nil
		ReleaseConnection()
	end

	function registry.Bind(_self: Registry, replica: any): ()
		ReleaseConnection()
		boundReplica = replica
		SyncConnection()
	end

	function registry.Connect(_self: Registry, pathOrKey: string, callback: Callback): Connection
		local isRoot = pathOrKey == ROOT_PATH
		local pathKeys: {string} = if isRoot then {} else table.clone(getPathKeys(pathOrKey))
		local bucketKey: string? = if isRoot then nil else pathKeys[1] or ""

		local listener: Listener
		local connection: Connection

		connection = {
			Connected = true,
			Disconnect = function(_connectionSelf: Connection): ()
				if not connection.Connected then
					return
				end
				connection.Connected = false
				RemoveListener(listener)
			end,
		}

		listener = {
			pathOrKey = pathOrKey,
			pathKeys = pathKeys,
			bucketKey = bucketKey,
			callback = callback,
			connection = connection,
		}

		if bucketKey == nil then
			table.insert(rootListeners, listener)
		else
			local bucket = buckets[bucketKey]
			if bucket == nil then
				bucket = {}
				buckets[bucketKey] = bucket
			end
			table.insert(bucket :: {Listener}, listener)
		end

		listenerCount += 1
		SyncConnection()

		return connection
	end

	function registry.Clear(self: Registry): ()
		for _, listener in rootListeners do
			listener.connection.Connected = false
		end
		for _, bucket in buckets do
			for _, listener in bucket do
				listener.connection.Connected = false
			end
		end

		table.clear(rootListeners)
		table.clear(buckets)
		listenerCount = 0

		self:Unbind()
	end

	function registry.GetListenerCount(_self: Registry): number
		return listenerCount
	end

	return registry
end

return ListenerRegistry
