--!strict

export type LeaderboardInfo = {
	rank: number?,
	score: number?,
	statName: string,
}

local Leaderboard = {}

function Leaderboard.GetLeaderboardInfo(replica: any?, statName: string): LeaderboardInfo?
	if not replica then
		return nil
	end

	local leaderboardRanks = (replica.Data :: any)._LeaderboardRanks
	if typeof(leaderboardRanks) ~= "table" then
		return nil
	end

	local statData = leaderboardRanks[statName]
	if typeof(statData) ~= "table" then
		return nil
	end

	return {
		rank = statData.rank,
		score = statData.score,
		statName = statName,
	}
end

return Leaderboard
