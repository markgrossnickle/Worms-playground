--!strict
-- SpatialIndex — coarse 2D grid (XZ plane) for fast neighbor lookups.
--
-- Built each tick from cached worm head + segment positions. Used by
-- WormService and BotService to replace O(N²·S) collision checks with
-- O(N·k) cell-neighbor lookups (k ≈ entities in 9 neighbor cells).
--
-- Why not Roblox's built-in OverlapParams / GetPartsInBox?
--   1. Those query Workspace, which means walking the whole scene graph
--      and crossing the Lua↔C++ boundary for every Part.
--   2. We already have the data we need cached in plain Lua tables
--      (`wormData.HeadPosition`, `wormData.SegmentPositions[i]`). A pure-
--      Lua grid built from those tables avoids Roblox's overhead entirely.
--   3. We need to attach metadata per entry (owner name, team index,
--      "is head?") for quick filtering before distance check. Cheap on
--      our own structure, awkward via Workspace queries.
--
-- Cell size is a tuning knob. ~30 studs is a good fit:
--   - Larger than the longest collision threshold (CollisionRadius·2 ≈ 4)
--   - Larger than the AI engagement range (CHASE_RANGE = 45) divided by
--     the 3-cell neighborhood width (so 9-cell sweep covers ≥45 studs)
--   - Small enough that average cell occupancy stays low

local SpatialIndex = {}
SpatialIndex.__index = SpatialIndex

export type Entry = {
	Pos: Vector3,
	OwnerName: string, -- worm/bot name; used for self-skip and team check
	TeamIndex: number, -- 0 if no team; non-zero matches WormConfig.TeamColors index
	IsHead: boolean, -- true for head, false for body segment
}

export type SpatialIndex = typeof(setmetatable(
	{} :: {
		_cellSize: number,
		_cells: { [number]: { Entry } }, -- key = packed cell coordinate
	},
	SpatialIndex
))

-- Pack two cell coordinates (each ±2^15 range) into one number key. Bigger
-- range than we need but cheap and avoids string concat (which would
-- allocate per insert).
local CELL_OFFSET = 32768

local function cellKey(cx: number, cz: number): number
	return (cx + CELL_OFFSET) * 65536 + (cz + CELL_OFFSET)
end

function SpatialIndex.new(cellSize: number): SpatialIndex
	local self = setmetatable({
		_cellSize = cellSize,
		_cells = {},
	}, SpatialIndex)
	return (self :: any) :: SpatialIndex
end

-- Reuse the same SpatialIndex across frames to avoid GC churn from
-- recreating the cell tables. Clear empties every cell's entry list but
-- keeps the cell map structure.
function SpatialIndex.Clear(self: SpatialIndex)
	-- Reuse cell arrays where possible; just truncate them. table.clear
	-- preserves the array's backing storage so subsequent inserts don't
	-- allocate.
	for _, list in self._cells do
		table.clear(list)
	end
end

function SpatialIndex.Insert(self: SpatialIndex, entry: Entry)
	local cs = self._cellSize
	local cx = math.floor(entry.Pos.X / cs)
	local cz = math.floor(entry.Pos.Z / cs)
	local key = cellKey(cx, cz)
	local list = self._cells[key]
	if not list then
		list = {}
		self._cells[key] = list
	end
	table.insert(list, entry)
end

-- Iterate every entry in the 3×3 neighborhood around `pos`. Caller passes
-- a callback that receives each entry; returning `true` from the callback
-- stops the iteration early (useful for "find first match" patterns).
function SpatialIndex.ForEachNeighbor(self: SpatialIndex, pos: Vector3, callback: (Entry) -> boolean?)
	local cs = self._cellSize
	local cx = math.floor(pos.X / cs)
	local cz = math.floor(pos.Z / cs)
	for dx = -1, 1 do
		for dz = -1, 1 do
			local list = self._cells[cellKey(cx + dx, cz + dz)]
			if list then
				for i = 1, #list do
					if callback(list[i]) then
						return
					end
				end
			end
		end
	end
end

return SpatialIndex
