# PlayerState

A modern player data management system for Roblox games featuring ProfileService integration, replica-based state replication, automatic leaderboards, and batched updates.

📖 **[Full Documentation](https://playerstate.netlify.app)** - Complete API reference, guides, and examples

## Features

- ✅ **ProfileService Integration** - Secure data persistence with session locking
- ✅ **Real-time Replication** - Automatic client data sync with change tracking
- ✅ **Built-in Leaderboards** - Automatic stat tracking and rankings
- ✅ **Batched Updates** - Efficient DataStore writes
- ✅ **Path-Based Access** - Access nested data with dot notation
- ✅ **Type-Safe API** - Full Luau type coverage
- ✅ **Performance Optimized** - Intelligent caching and rate limiting

## Installation

### Option 1: Download Model (.rbxm)

**Recommended for beginners** - Download the latest `.rbxm` file from [Releases](https://github.com/bellaouzo/PlayerState/releases/) and drag it into your ReplicatedStorage.

### Option 2: Manual Installation

1. Clone or download this repository
   git clone https://github.com/bellaouzo/PlayerState.git
2. Open your Roblox game in Studio
3. In ReplicatedStorage, make sure the folder is named `PlayerState`
4. The require path will be: `game.ReplicatedStorage.PlayerState.PlayerStateServer`

### Option 3: GitHub Cloning Plugin

Use the [GitHub Cloning Plugin](https://devforum.roblox.com/t/github-cloning-plugin/31267) to clone directly into Roblox Studio.

## Quick Start

### 1. Configure Your Data Structure

Edit `DefaultData.luau` to define your player data:

```lua
return {
    Coins = 0,
    Level = 1,

    Inventory = {
        Weapons = {},
        Items = {}
    },

    leaderstats = {
        ["💰 Coins"] = "Coins",
        ["⭐ Level"] = "Level"
    }
}
```

### 2. Configure Settings

Edit `PlayerStateConfig.luau` for your game settings:

```lua
local Config = {
    Server = {
        DataStore = {
            Name = "PlayerData_v1",
            Scope = "Production"
        },

        Leaderboard = {
            Enabled = true,
            TrackedStats = {"Coins", "Level"}
        }
    }
}

return Config
```

### 3. Initialize on Server

```lua
local Players = game:GetService("Players")
local PlayerState = require(ReplicatedStorage.PlayerState.PlayerStateServer)

Players.PlayerAdded:Connect(function(player)
    local success = PlayerState.Init(player)

    if success then
        print(`[PlayerState] Loaded data for {player.Name}`)
    end
end)

Players.PlayerRemoving:Connect(function(player)
    PlayerState.SaveData(player)
end)
```

### 4. Use on Client

```lua
local PlayerState = require(ReplicatedStorage.PlayerState.PlayerStateClient)

-- Wait for data to load
PlayerState.IsReady() -- Check if ready

-- Listen for changes
PlayerState.OnChanged("Coins", function(newValue, oldValue)
    print(`Coins: {oldValue} → {newValue}`)
end)
```

## API Reference

### Server API

#### Basic Operations

```lua
-- Set a value
PlayerState.Set(player, "Coins", 100)

-- Get a value
local coins = PlayerState.Get(player, "Coins")

-- Access nested data with dot notation
PlayerState.SetPath(player, "Inventory.Weapons[1].Durability", 95)
local durability = PlayerState.GetPath(player, "Inventory.Weapons[1].Durability")
```

#### Increment/Decrement

```lua
-- Increment by 1
PlayerState.Increment(player, "Coins")

-- Increment by custom amount
PlayerState.Increment(player, "Level", 5)

-- Decrement
PlayerState.Decrement(player, "Coins", 10)
```

#### Arrays

```lua
-- Add item to array
PlayerState.AddToArray(player, "Inventory.Weapons", {
    Id = "sword_001",
    Name = "Iron Sword",
    Damage = 10
})

-- Update array item
PlayerState.UpdateArrayItem(player, "Inventory.Weapons", 1, {
    Id = "sword_001",
    Name = "Iron Sword",
    Damage = 15
})

-- Remove from array
PlayerState.RemoveFromArray(player, "Inventory.Weapons", 1)
```

#### Dictionaries

```lua
-- Set dictionary value
PlayerState.SetInDict(player, "Inventory.Items", "health_potion", 5)

-- Get dictionary value
local quantity = PlayerState.GetFromDict(player, "Inventory.Items", "health_potion")

-- Remove from dictionary
PlayerState.RemoveFromDict(player, "Inventory.Items", "health_potion")
```

#### Batch Operations

```lua
-- Update multiple values at once
PlayerState.BatchSetValues(player, {
    {path = "Coins", value = 200},
    {path = "Level", value = 5},
    {path = "Experience", value = 1000}
})

-- Manually flush batch (normally auto-flushes)
PlayerState.FlushBatch(player)
```

#### Leaderboards

```lua
-- Get top players
local topPlayers = PlayerState.GetLeaderboard("Coins", 10)
-- Returns: {{userId = 123, score = 5000, rank = 1}, ...}

-- Get player's rank
local rank = PlayerState.GetPlayerRank(player, "Coins")
```

#### Events

```lua
-- Before data is saved
PlayerState.BeforeSave:Connect(function(player, data)
    -- Validate or modify data before saving
end)

-- When player data loads
PlayerState.ProfileLoaded:Connect(function(player, data)
    print("Data loaded for", player.Name)
end)

-- When player leaves
PlayerState.ProfileUnloaded:Connect(function(player, data)
    print("Data saved for", player.Name)
end)
```

#### Utilities

```lua
-- Get all player data
local allData = PlayerState.GetAll(player)

-- Check if data is ready
if PlayerState.IsPlayerDataReady(player) then
    -- Safe to use data
end

-- Save data manually
PlayerState.SaveData(player)

-- Admin: Wipe player data
PlayerState.WipePlayerData(player)
```

### Client API

#### Reading Data

```lua
-- Get value
local coins = PlayerState.Get("Coins")

-- Get nested value
local durability = PlayerState.GetPath("Inventory.Weapons[1].Durability")

-- Get dictionary value
local quantity = PlayerState.GetFromDict("Inventory.Items", "health_potion")

-- Get all data
local allData = PlayerState.GetAll()
```

#### Listening for Changes

```lua
-- Listen to any path
PlayerState.OnChanged("Coins", function(newValue, oldValue)
    print(`Coins changed: {oldValue} → {newValue}`)
end)

PlayerState.OnChanged("Inventory.Weapons", function(newValue, oldValue)
    print("Weapons updated!")
end)
```

#### Utilities

```lua
-- Check if data is ready
if PlayerState.IsReady() then
    -- Data loaded
end

-- Clear cache (advanced)
PlayerState.ClearCache()

-- Get underlying Replica (advanced)
local replica = PlayerState.GetReplica()
```

## Attribution

This library uses the following third-party dependencies (included):

- **ProfileStore** by MAD STUDIO (loleris) - DataStore session management
- **Replica** by MAD STUDIO (loleris) - State replication system
- **Maid, Signal, Remote, RateLimit** by MAD STUDIO - Supporting utilities

See individual file headers for full attribution details.

## License

MIT License - See LICENSE file for details

## Support

- 💬 [DevForum Post](https://devforum.roblox.com/t/your-post-link)
- 🐛 [Report Issues](https://github.com/YOURUSERNAME/PlayerState/issues)
