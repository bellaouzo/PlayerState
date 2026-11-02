--!strict

export type DebugState = {
	GetServerCounts: (() -> {[string]: number})?,
}

local DebugState: DebugState = {
	GetServerCounts = nil,
}

return DebugState
