--!strict

export type LeaderboardInfo = {
	rank: number?,
	score: number?,
	statName: string,
}

export type LeaderboardEntry = {
	userId: number,
	score: number,
	rank: number,
}

local Leaderboard = {}

local function ToLeaderboardInfo(statName: string, statData: any): LeaderboardInfo?
	if typeof(statData) ~= "table" then
		return nil
	end

	return {
		rank = statData.rank,
		score = statData.score,
		statName = statName,
	}
end

function Leaderboard.GetLeaderboardInfo(replica: any?, statName: string): LeaderboardInfo?
	if not replica then
		print("[Leaderboard] GetLeaderboardInfo failed: No replica")
		return nil
	end

	local leaderboardRanks = (replica.Data :: any)._LeaderboardRanks
	if typeof(leaderboardRanks) ~= "table" then
		print("[Leaderboard] GetLeaderboardInfo failed: No leaderboard ranks")
		return nil
	end

	local statData = leaderboardRanks[statName]
	return ToLeaderboardInfo(statName, statData)
end

function Leaderboard.GetLeaderboard(replica: any?, statName: string, limit: number?): {LeaderboardEntry}
	if not replica then
		return {}
	end

	local leaderboards = (replica.Data :: any)._Leaderboards
	if typeof(leaderboards) ~= "table" then
		return {}
	end

	local statLeaderboard = leaderboards[statName]
	if typeof(statLeaderboard) ~= "table" then
		return {}
	end

	local entries: {LeaderboardEntry} = {}
	for _, entry in statLeaderboard do
		if typeof(entry) == "table" and typeof(entry.userId) == "number" and typeof(entry.score) == "number" and typeof(entry.rank) == "number" then
			entries[#entries + 1] = {
				userId = entry.userId,
				score = entry.score,
				rank = entry.rank,
			}
		end
	end

	local requestedLimit = if typeof(limit) == "number" and limit > 0 then math.floor(limit) else #entries
	local clampedLimit = math.min(requestedLimit, #entries)

	return table.move(entries, 1, clampedLimit, 1, {})
end

return Leaderboard