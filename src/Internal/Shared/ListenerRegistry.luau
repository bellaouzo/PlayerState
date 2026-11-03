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
	bucket: Bucket,
	slot: number,
	callback: Callback,
	connection: Connection,
}

type Bucket = {
	key: string?,
	listeners: {Listener | false},
	size: number,
	live: number,
	dirty: boolean,
}

local ROOT_PATH = "."

local freeRunnerThread: thread? = nil

local function AcquireRunnerThreadAndCall(fn: (...any) -> (), ...: any): ()
	local acquiredRunnerThread = freeRunnerThread
	freeRunnerThread = nil
	fn(...)
	freeRunnerThread = acquiredRunnerThread
end

local function RunInFreeThread(...: any): ()
	AcquireRunnerThreadAndCall(...)
	while true do
		AcquireRunnerThreadAndCall(coroutine.yield())
	end
end

local function Spawn(fn: (...any) -> (), ...: any): ()
	if freeRunnerThread == nil then
		freeRunnerThread = coroutine.create(RunInFreeThread)
	end
	task.spawn(freeRunnerThread :: thread, fn, ...)
end

local function NewBucket(key: string?): Bucket
	return {
		key = key,
		listeners = {},
		size = 0,
		live = 0,
		dirty = false,
	}
end

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
		Spawn(callback, param1, param2, {action = action, path = table.clone(path)})
	elseif action == "SetValues" then
		Spawn(callback, param1, nil, {action = action, path = table.clone(path)})
	elseif action == "TableInsert" then
		Spawn(callback, param1, nil, {action = action, path = table.clone(path), index = param2})
	elseif action == "TableRemove" then
		Spawn(callback, nil, param1, {action = action, path = table.clone(path), index = param2})
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
				Spawn(FireWithRead, callback, readValue, pathKeys, listener.pathOrKey, oldChild, {action = "Set", path = table.clone(path)})
			end
		elseif action == "SetValues" then
			if typeof(param1) == "table" and LookupKey(param1, pathKeys[pathLength + 1]) ~= nil then
				Spawn(FireWithRead, callback, readValue, pathKeys, listener.pathOrKey, nil, {action = "SetValues", path = table.clone(path)})
			end
		end
		return
	end

	local isExactMatch = pathLength == keyCount

	if action == "Set" then
		if isExactMatch then
			Spawn(callback, param1, param2, table.clone(pathKeys))
		else
			Spawn(FireWithRead, callback, readValue, pathKeys, listener.pathOrKey, nil, {action = action, path = table.clone(path)})
		end
	elseif action == "SetValues" then
		if isExactMatch then
			Spawn(callback, param1, nil, {action = action, path = table.clone(path)})
		else
			Spawn(FireWithRead, callback, readValue, pathKeys, listener.pathOrKey, nil, {action = action, path = table.clone(path)})
		end
	elseif action == "TableInsert" then
		Spawn(callback, param1, nil, {action = action, path = table.clone(path), index = param2})
	elseif action == "TableRemove" then
		Spawn(callback, nil, param1, {action = action, path = table.clone(path), index = param2})
	end
end

local ListenerRegistry = {}

function ListenerRegistry.new(options: Options): Registry
	local getPathKeys = options.getPathKeys
	local readValue = options.readValue
	local onChange = options.onChange

	local rootBucket: Bucket = NewBucket(nil)
	local buckets: {[string]: Bucket} = {}
	local dirtyBuckets: {Bucket} = {}
	local dispatchDepth = 0
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

	local function CompactBucket(bucket: Bucket): ()
		local listeners = bucket.listeners
		local size = bucket.size

		if bucket.live == 0 then
			table.clear(listeners)
			bucket.size = 0
			local key = bucket.key
			if key ~= nil and buckets[key] == bucket then
				buckets[key] = nil
			end
			return
		end

		if size < bucket.live * 2 then
			return
		end

		local writeIndex = 0
		for readIndex = 1, size do
			local listener = listeners[readIndex]
			if listener then
				writeIndex += 1
				listeners[writeIndex] = listener
				listener.slot = writeIndex
			end
		end
		for index = writeIndex + 1, size do
			listeners[index] = nil
		end
		bucket.size = writeIndex
	end

	local function RemoveListener(listener: Listener): ()
		local bucket = listener.bucket
		local listeners = bucket.listeners
		local slot = listener.slot

		if listeners[slot] ~= listener then
			return
		end

		listeners[slot] = false
		bucket.live -= 1
		listenerCount -= 1

		if dispatchDepth > 0 then
			if not bucket.dirty then
				bucket.dirty = true
				table.insert(dirtyBuckets, bucket)
			end
		else
			CompactBucket(bucket)
		end

		SyncConnection()
	end

	local function FlushDirtyBuckets(): ()
		for _, bucket in dirtyBuckets do
			bucket.dirty = false
			CompactBucket(bucket)
		end
		table.clear(dirtyBuckets)
	end

	local function DispatchBucket(bucket: Bucket?, action: string, path: {any}, param1: any, param2: any): ()
		if bucket == nil or bucket.live == 0 then
			return
		end

		local listeners = bucket.listeners
		for index = 1, bucket.size do
			local listener = listeners[index]
			if listener and listener.connection.Connected then
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

		dispatchDepth += 1

		local roots = rootBucket
		if roots.live > 0 then
			local listeners = roots.listeners
			for index = 1, roots.size do
				local listener = listeners[index]
				if listener and listener.connection.Connected then
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

		dispatchDepth -= 1

		if dispatchDepth == 0 and #dirtyBuckets > 0 then
			FlushDirtyBuckets()
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

		local bucket: Bucket
		if isRoot then
			bucket = rootBucket
		else
			local bucketKey = pathKeys[1] or ""
			local existing = buckets[bucketKey]
			if existing then
				bucket = existing
			else
				bucket = NewBucket(bucketKey)
				buckets[bucketKey] = bucket
			end
		end

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

		local slot = bucket.size + 1

		listener = {
			pathOrKey = pathOrKey,
			pathKeys = pathKeys,
			bucket = bucket,
			slot = slot,
			callback = callback,
			connection = connection,
		}

		bucket.listeners[slot] = listener
		bucket.size = slot
		bucket.live += 1

		listenerCount += 1
		SyncConnection()

		return connection
	end

	function registry.Clear(self: Registry): ()
		local oldBuckets: {Bucket} = {rootBucket}
		for _, bucket in buckets do
			table.insert(oldBuckets, bucket)
		end

		for _, bucket in oldBuckets do
			local listeners = bucket.listeners
			for index = 1, bucket.size do
				local listener = listeners[index]
				if listener then
					listener.connection.Connected = false
				end
			end
		end

		rootBucket = NewBucket(nil)
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
