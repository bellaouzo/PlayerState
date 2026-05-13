--!strict

local RunService = game:GetService("RunService")

local PLAYER_STATE_ROOT = script.Parent.Parent.Parent
local REMOTES_FOLDER_NAME = "Remotes"
local WAIT_TIMEOUT_SECONDS = 30

local cachedRemotes: {[string]: Instance} = {}

local function _EnsureRemotesFolderServer(): Folder
	local existingFolder = PLAYER_STATE_ROOT:FindFirstChild(REMOTES_FOLDER_NAME)
	if existingFolder then
		if not existingFolder:IsA("Folder") then
			error(`[PlayerState] "{REMOTES_FOLDER_NAME}" under PlayerState must be a Folder`)
		end

		return existingFolder
	end

	local createdFolder = Instance.new("Folder")
	createdFolder.Name = REMOTES_FOLDER_NAME
	createdFolder.Parent = PLAYER_STATE_ROOT

	return createdFolder
end

local function _ResolveRemotesFolderClient(): Folder
	local existingFolder = PLAYER_STATE_ROOT:FindFirstChild(REMOTES_FOLDER_NAME)
	if existingFolder then
		if not existingFolder:IsA("Folder") then
			error(`[PlayerState] "{REMOTES_FOLDER_NAME}" under PlayerState must be a Folder`)
		end

		return existingFolder
	end

	local waitedFolder = PLAYER_STATE_ROOT:WaitForChild(REMOTES_FOLDER_NAME, WAIT_TIMEOUT_SECONDS)
	if not waitedFolder or not waitedFolder:IsA("Folder") then
		error(`[PlayerState] Folder "{REMOTES_FOLDER_NAME}" under PlayerState was not found`)
	end

	return waitedFolder
end

local function _ResolveRemotesFolder(): Folder
	if RunService:IsServer() then
		return _EnsureRemotesFolderServer()
	end

	return _ResolveRemotesFolderClient()
end

local function _EnsureRemoteFunctionServer(remotesFolder: Folder, remoteName: string): RemoteFunction
	local existingRemote = remotesFolder:FindFirstChild(remoteName)
	if existingRemote then
		if not existingRemote:IsA("RemoteFunction") then
			error(`[PlayerState] "{remoteName}" under PlayerState.{REMOTES_FOLDER_NAME} must be a RemoteFunction`)
		end

		return existingRemote
	end

	local createdRemote = Instance.new("RemoteFunction")
	createdRemote.Name = remoteName
	createdRemote.Parent = remotesFolder

	return createdRemote
end

local function _ResolveRemoteFunctionClient(remotesFolder: Folder, remoteName: string): RemoteFunction
	local existingRemote = remotesFolder:FindFirstChild(remoteName)
	if existingRemote then
		if not existingRemote:IsA("RemoteFunction") then
			error(`[PlayerState] "{remoteName}" under PlayerState.{REMOTES_FOLDER_NAME} must be a RemoteFunction`)
		end

		return existingRemote
	end

	local waitedRemote = remotesFolder:WaitForChild(remoteName, WAIT_TIMEOUT_SECONDS)
	if not waitedRemote or not waitedRemote:IsA("RemoteFunction") then
		error(`[PlayerState] RemoteFunction "{remoteName}" under PlayerState.{REMOTES_FOLDER_NAME} was not found`)
	end

	return waitedRemote
end

local RemoteRegistry = {}

function RemoteRegistry.GetRemoteFunction(remoteName: string): RemoteFunction
	local cached = cachedRemotes[remoteName]
	if cached then
		if cached:IsA("RemoteFunction") then
			return cached
		end

		cachedRemotes[remoteName] = nil
	end

	local remotesFolder = _ResolveRemotesFolder()
	local resolved: RemoteFunction

	if RunService:IsServer() then
		resolved = _EnsureRemoteFunctionServer(remotesFolder, remoteName)
	else
		resolved = _ResolveRemoteFunctionClient(remotesFolder, remoteName)
	end

	cachedRemotes[remoteName] = resolved
	return resolved
end

return RemoteRegistry
