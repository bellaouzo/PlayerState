--!strict

local Players = game:GetService("Players")

local Validation = {}

function Validation.ValidatePlayer(player: Player): boolean
	return player and player.Parent == Players
end

function Validation.ValidateReplica(replica: any?): boolean
	return replica ~= nil and replica:IsActive()
end

function Validation.ValidateProfile(profile: any?): boolean
	return profile ~= nil and profile:IsActive()
end

return Validation
