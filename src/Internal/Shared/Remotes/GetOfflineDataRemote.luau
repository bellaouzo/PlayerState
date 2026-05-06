--!strict

local Registry = require(script.Parent.Registry)

local REMOTE_NAME = "GetOfflineData"

local OfflineDataRemote = {}

function OfflineDataRemote.SetupServer(playerState: any): ()
	Registry.BindRemoteFunction(REMOTE_NAME, function(player: Player, userId: unknown): any?
		if typeof(userId) ~= "number" then
			return nil
		end

		return playerState.GetOfflineData(userId :: number)
	end)
end

function OfflineDataRemote.Invoke(userId: number): any?
	return Registry.InvokeRemoteFunction(REMOTE_NAME, userId)
end

return OfflineDataRemote
