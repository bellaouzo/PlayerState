return {
	-- Adds to default data. Examples:
	-- Points = 25 -- Adds "Points" to data and defaults to 25

	-- Adds "Coins" to data and defaults to 0
	Coins = 0,

	-- Example table for default data
	
	Inventory = {
		Pills = {}, -- [itemId] = {itemName = string, quantity = number}
		Elixirs = {}, -- [itemId] = {itemName = string, quantity = number}
	},

	
	--Cultivation = {
	--	Environment = "Normal",
	--},

	-- Non-persistent data. Does not save on leave.
	session = {
		isChopping = false,
		isSprinting = false,
	},

	-- Data that goes onto leaderstats/top right leaderboard display
	leaderstats = {
		["💰 Coins"] = "Coins",
	}
}