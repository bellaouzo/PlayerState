--[[
	PlayerStateConfig - Configuration settings for PlayerState system
	
	Documentation: https://playerstate.netlify.app/setup.html#playerstateconfig-module
--]]

-- Libraries
local DefaultData = require(script.Parent.DefaultData)

local Config = {
	Server = {
		Profile = {
			-- Unique key for ProfileStore data identification
			Key = "PlayerData",
			
			-- Data template/structure (automatically pulled from DefaultData)
			Template = DefaultData,
		},
		
		DataStore = {
			-- DataStore name (change for different versions/environments)
			Name = "PlayerData_0.01",

			-- Scope: "Production" for live data, "Testing" for mock data that won't save
			Scope = "Production",
		},

		-- Check documentation migration instructions for info
		LegacyDataStore = {
			enabled = false,
			store = "OldStore",
			strategy = "Auto", -- Auto | Overwrite | KeepNew | Manual | ContinuousOverwrite
			keys = {
				"{UserId}",
				"PlayerData_{UserId}",
			},
			advanced = {
				scope = nil,
				marker = {
					path = "_Migration.LegacyDataStoreV1",
					writeOnNoData = true,
				},
				payload = {
					mode = "auto", -- auto | profileStore
				},
				manual = {
					transform = nil, -- function(legacyData, template, player) -> table
				},
				fetch = {
					custom = nil, -- function(keyCandidates, userId, player) -> payload, keyUsed
				},
			},
		},

		-- Allows you to load another user's data profile in Studio for debugging purposes
		ViewedUser = {
			-- Studio-only debug profile override:
			-- 0 = disabled, any other value loads that user's profile key in Studio
			ViewedUserId = 0,

			-- If true, blocks all data mutation APIs while viewing another user's data
			ReadOnly = true,
		},

		-- If it will remove fields not in template during data reconciliation
		CleanExtraFields = false,

		-- If enabled, Get/GetPath/GetFromDict will return deep copies of tables instead of references
		-- This can be resource heavy so I would not recommend enabling it unless you really need it
		AutoCloneTables = false,

		-- How long to wait for player data to load before timing out (in seconds)
		DataWaitTimeout = 10,

		RuntimeNonPersistentRoots = {
			"session",
			"_LeaderboardRanks",
			"_Leaderboards",
			"_Leaderboard",
		},

		-- Batch processing settings
		BatchDelay = 0.03,      -- Seconds to wait before processing batch (lower = faster, higher = more efficient)
		BatchSize = 20,         -- Auto-flush batch when this many operations are queued
		MaxCacheSize = 1000,    -- Maximum number of cached path keys

		Leaderboard = {
			Enabled = true,

			-- DataStore name for leaderboards
			DataStoreName = "PlayerState_Leaderboards",

			-- Which data fields should have leaderboards (auto-updated when values change)
			TrackedStats = {
				"Coins",
				-- Add stat names here to create leaderboards
				-- Examples: "coins", "level", "score", "Inventory.Pills"
			},

			-- How often to refresh each player's rank and top-100 list from DataStores (seconds, min 60)
			SyncInterval = 60,
			-- Full leaderboard write sweep (seconds): every online player × tracked stats. 0 = off; min 60 when enabled. Join, stat changes, leave, and shutdown still update scores.
			FullLeaderboardWriteInterval = 600,
			UpdateOnPlayerLeave = true,
		},
	},
	
	Client = {
		-- How long to cache values (in seconds)
		CacheDuration = 0.1,
		
		-- How often to clean up expired cache entries (in seconds)  
		CacheCleanupInterval = 30,
		
		-- Maximum number of cached values before cleanup
		MaxCacheSize = 1000,
		
		-- Maximum number of cached path strings before cleanup
		MaxPathCacheSize = 1000,

		-- If enabled, Get/GetPath/GetFromDict will return deep copies of tables instead of references
		AutoCloneTables = false,
	},
}

return Config 