--!strict

local RunService = game:GetService("RunService")
local RemoteRegistry = require(script.Parent.RemoteRegistry)

local REMOTE_NAME = "GetOfflineData"

local cachedRemote: RemoteFunction?

local function _EnsureRemote(): RemoteFunction
	if cachedRemote then
		return cachedRemote
	end

	local resolvedRemote = RemoteRegistry.GetRemoteFunction(REMOTE_NAME)
	cachedRemote = resolvedRemote
	
	return resolvedRemote
end

local OfflineDataRemote = {}

function OfflineDataRemote.SetupServer(onInvoke: (Player, number) -> any?): ()
	if not RunService:IsServer() then
		return
	end

	local rf = _EnsureRemote()
	rf.OnServerInvoke = function(player: Player, userId: unknown): any?
		if typeof(userId) ~= "number" then
			return nil
		end

		return onInvoke(player, userId :: number)
	end
end

function OfflineDataRemote.Invoke(userId: number): any?
	return _EnsureRemote():InvokeServer(userId)
end

return OfflineDataRemote
