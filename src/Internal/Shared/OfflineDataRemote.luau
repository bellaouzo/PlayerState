--!strict

local RunService = game:GetService("RunService")

local PLAYER_STATE_ROOT = script.Parent.Parent.Parent
local REMOTES_FOLDER_NAME = "Remotes"
local REMOTE_NAME = "GetOfflineData"

local cachedRemote: RemoteFunction?

local function _ResolveRemotesFolder(): Folder
	local folder = PLAYER_STATE_ROOT:FindFirstChild(REMOTES_FOLDER_NAME)
	if folder and folder:IsA("Folder") then
		return folder
	end

	if RunService:IsServer() then
		error(
			`[PlayerState] Expected Folder "{REMOTES_FOLDER_NAME}" under PlayerState with RemoteFunction "{REMOTE_NAME}" inside`
		)
	end

	local waited = PLAYER_STATE_ROOT:WaitForChild(REMOTES_FOLDER_NAME, 30)
	if not waited or not waited:IsA("Folder") then
		error(`[PlayerState] Folder "{REMOTES_FOLDER_NAME}" under PlayerState was not found`)
	end

	return waited
end

local function _EnsureRemote(): RemoteFunction
	if cachedRemote then
		return cachedRemote
	end

	local remotes = _ResolveRemotesFolder()
	local existing = remotes:FindFirstChild(REMOTE_NAME)
	if existing and existing:IsA("RemoteFunction") then
		local found = existing :: RemoteFunction
		cachedRemote = found
		return found
	end

	if RunService:IsServer() then
		error(
			`[PlayerState] Expected RemoteFunction "{REMOTE_NAME}" inside PlayerState.{REMOTES_FOLDER_NAME}`
		)
	end

	local waited = remotes:WaitForChild(REMOTE_NAME, 30)
	if not waited or not waited:IsA("RemoteFunction") then
		error(`[PlayerState] RemoteFunction "{REMOTE_NAME}" under PlayerState.{REMOTES_FOLDER_NAME} was not found`)
	end

	cachedRemote = waited
	return waited
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
