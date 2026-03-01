--!strict

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Knit = require(ReplicatedStorage.Packages.Knit)
local Promise = require(ReplicatedStorage.Packages.Promise)

local LeaderboardConfig = require(ReplicatedStorage.Shared.Configs.LeaderboardConfig)

--[=[
	@class LeaderboardService
	OrderedDataStore-backed leaderboards with caching, budget-aware queue
	processing, and automatic period rotation.
]=]
local LeaderboardService = Knit.CreateService({
	Name = "LeaderboardService",
	Client = {
		LeaderboardUpdated = Knit.CreateSignal(),
	},
})

-- System configuration
local SYSTEM_CONFIG = {
	UPDATE_INTERVAL = 90,
	CACHE_DURATION_BASE = 300,
	CACHE_STAGGER_OFFSET = 60,
	MAX_RETRIES = 2,
	PAGE_SIZE_DEFAULT = 50,
	PAGE_SIZE_MAX = 100,
	CLEANUP_INTERVAL = 3600,
	MAX_CACHE_ENTRIES = 1000,
	MAX_PLAYER_RANK_CACHE = 500,
	PLAYER_RANK_CACHE_DURATION = 300,
	PLAYER_RANK_INACTIVE_TIMEOUT = 300,
	TOP_RANK_THRESHOLD = 100,
	BUDGET_RESERVE = 5,
	SUBMISSION_COOLDOWN = 30,
}

local PERIOD_TYPES = {
	ALL_TIME = "AllTime",
	MONTHLY = "Monthly",
	WEEKLY = "Weekly",
	DAILY = "Daily",
}

local pendingFetches: { [string]: any } = {}
local pendingFetchesMutex = { locked = false :: any }

-- Build property order once during initialization
local PROPERTY_CACHE_ORDER: { string } = {}

function LeaderboardService:_initializePropertyCacheOrder()
	for propertyName in LeaderboardConfig.Properties do
		table.insert(PROPERTY_CACHE_ORDER, propertyName)
	end
	table.sort(PROPERTY_CACHE_ORDER)
end

-- Get cache expiration time with property-based staggering
function LeaderboardService:_getCacheDuration(_period: string, property: string): number
	local baseDuration = SYSTEM_CONFIG.CACHE_DURATION_BASE

	local propertyIndex = 0
	for i, prop in PROPERTY_CACHE_ORDER do
		if prop == property then
			propertyIndex = i - 1
			break
		end
	end

	local offset = propertyIndex * SYSTEM_CONFIG.CACHE_STAGGER_OFFSET
	return baseDuration + offset
end

-- Internal state
local updateQueue: { [string]: any } = {}
local cache: { [string]: any } = {}
local playerRankCache: { [string]: any } = {}
local playerRankCacheCount = 0
local currentPeriodIds = {
	month = 0,
	week = 0,
	day = 0,
}
local dataStores: { [string]: { [string]: OrderedDataStore } } = {}

-- Queue mutex for thread safety
local queueMutex = { locked = false :: any }

-- Cache mutex for thread safety
local cacheMutex = { locked = false :: any }

-- Player rank cache mutex for thread safety
local rankCacheMutex = { locked = false :: any }

-- Helper function: Execute function with queue lock
local function withQueueLock(fn: () -> any): any
	local lockId = newproxy()

	while true do
		if not queueMutex.locked then
			queueMutex.locked = lockId
			if queueMutex.locked == lockId then
				break
			end
		end
		task.wait()
	end

	local ok, result = pcall(fn)

	if queueMutex.locked == lockId then
		queueMutex.locked = false
	end

	if not ok then
		error(result)
	end
	return result
end

-- Helper function: Execute function with cache lock
local function withCacheLock(fn: () -> any): any
	local lockId = newproxy()

	while true do
		if not cacheMutex.locked then
			cacheMutex.locked = lockId
			if cacheMutex.locked == lockId then
				break
			end
		end
		task.wait()
	end

	local ok, result = pcall(fn)

	if cacheMutex.locked == lockId then
		cacheMutex.locked = false
	end

	if not ok then
		error(result)
	end
	return result
end

-- Helper function: Execute function with rank cache lock
local function withRankCacheLock(fn: () -> any): any
	local lockId = newproxy()

	while true do
		if not rankCacheMutex.locked then
			rankCacheMutex.locked = lockId
			if rankCacheMutex.locked == lockId then
				break
			end
		end
		task.wait()
	end

	local ok, result = pcall(fn)

	if rankCacheMutex.locked == lockId then
		rankCacheMutex.locked = false
	end

	if not ok then
		error(result)
	end
	return result
end

-- Helper function: Validate queue integrity
local function validateQueueIntegrity(): number
	local count = 0
	for _ in updateQueue do
		count += 1
	end
	return count
end

-- Helper function: Validate score
local function isValidScore(score: any): boolean
	return type(score) == "number" and score >= 0 and score <= 2 ^ 53 and score == math.floor(score)
end

-- Helper function: Validate property
local function isValidProperty(property: string): boolean
	return LeaderboardConfig.Properties[property] ~= nil
end

-- Helper function: Check if period is enabled for property
local function isPeriodEnabled(property: string, period: string): boolean
	if not isValidProperty(property) then
		return false
	end
	return LeaderboardConfig.Properties[property].Periods[period] == true
end

-- Helper function: Generate cache key
local function getCacheKey(property: string, period: string, pageNumber: number?, pageSize: number?): string
	return string.format(
		"%s_%s_page_%d_size_%d",
		property,
		period,
		pageNumber or 1,
		pageSize or SYSTEM_CONFIG.PAGE_SIZE_DEFAULT
	)
end

-- Helper function: Limit player rank cache size
local function limitPlayerRankCache()
	if playerRankCacheCount <= SYSTEM_CONFIG.MAX_PLAYER_RANK_CACHE then
		return
	end

	local oldest: string? = nil
	local oldestTime = math.huge
	for key, data in playerRankCache do
		if data.lastQuery < oldestTime then
			oldest = key
			oldestTime = data.lastQuery
		end
	end

	if oldest then
		playerRankCache[oldest] = nil
		playerRankCacheCount = math.max(0, playerRankCacheCount - 1)
	end
end

-------------------------------------------------
-- Period management
-------------------------------------------------

function LeaderboardService:_getCurrentPeriodId(periodType: string): number
	local currentTime = os.time()
	if periodType == "month" then
		local date = os.date("!*t", currentTime) :: { year: number, month: number }
		return date.year * 12 + date.month
	elseif periodType == "week" then
		return math.floor(currentTime / 604800)
	elseif periodType == "day" then
		return math.floor(currentTime / 86400)
	end
	return 0
end

function LeaderboardService:_getNextResetTime(periodType: string): number
	local currentTime = os.time()
	if periodType == "day" then
		return (math.floor(currentTime / 86400) + 1) * 86400
	elseif periodType == "week" then
		return (math.floor(currentTime / 604800) + 1) * 604800
	elseif periodType == "month" then
		local date =
			os.date("!*t", currentTime) :: { year: number, month: number, day: number, hour: number, min: number, sec: number }
		date.month = date.month + 1
		if date.month > 12 then
			date.month = 1
			date.year = date.year + 1
		end
		date.day = 1
		date.hour = 0
		date.min = 0
		date.sec = 0
		return os.time(date :: any)
	end
	return currentTime + 86400
end

-------------------------------------------------
-- DataStore initialization
-------------------------------------------------

function LeaderboardService:_initializeDataStores()
	for property, config in LeaderboardConfig.Properties do
		dataStores[property] = {}

		for period, enabled in config.Periods do
			if enabled then
				local storeName: string?
				if period == PERIOD_TYPES.ALL_TIME then
					storeName = string.format("Leaderboard_%s_AllTime", property)
				elseif period == PERIOD_TYPES.MONTHLY then
					local monthId = self:_getCurrentPeriodId("month")
					currentPeriodIds.month = monthId
					storeName = string.format("Leaderboard_%s_Monthly_%d", property, monthId)
				elseif period == PERIOD_TYPES.WEEKLY then
					local weekId = self:_getCurrentPeriodId("week")
					currentPeriodIds.week = weekId
					storeName = string.format("Leaderboard_%s_Weekly_%d", property, weekId)
				elseif period == PERIOD_TYPES.DAILY then
					local dayId = self:_getCurrentPeriodId("day")
					currentPeriodIds.day = dayId
					storeName = string.format("Leaderboard_%s_Daily_%d", property, dayId)
				end

				if storeName then
					dataStores[property][period] = DataStoreService:GetOrderedDataStore(storeName)
				end
			end
		end
	end
end

function LeaderboardService:_checkPeriodReset(): boolean
	local monthId = self:_getCurrentPeriodId("month")
	local weekId = self:_getCurrentPeriodId("week")
	local dayId = self:_getCurrentPeriodId("day")

	local resetOccurred = false

	if monthId ~= currentPeriodIds.month then
		currentPeriodIds.month = monthId
		for property, config in LeaderboardConfig.Properties do
			if config.Periods[PERIOD_TYPES.MONTHLY] then
				local storeName = string.format("Leaderboard_%s_Monthly_%d", property, monthId)
				dataStores[property][PERIOD_TYPES.MONTHLY] = DataStoreService:GetOrderedDataStore(storeName)
			end
		end
		withCacheLock(function()
			for key in cache do
				if string.find(key, "_Monthly_", 1, true) then
					cache[key] = nil
				end
			end
		end)
		resetOccurred = true
	end

	if weekId ~= currentPeriodIds.week then
		currentPeriodIds.week = weekId
		for property, config in LeaderboardConfig.Properties do
			if config.Periods[PERIOD_TYPES.WEEKLY] then
				local storeName = string.format("Leaderboard_%s_Weekly_%d", property, weekId)
				dataStores[property][PERIOD_TYPES.WEEKLY] = DataStoreService:GetOrderedDataStore(storeName)
			end
		end
		withCacheLock(function()
			for key in cache do
				if string.find(key, "_Weekly_", 1, true) then
					cache[key] = nil
				end
			end
		end)
		resetOccurred = true
	end

	if dayId ~= currentPeriodIds.day then
		currentPeriodIds.day = dayId
		for property, config in LeaderboardConfig.Properties do
			if config.Periods[PERIOD_TYPES.DAILY] then
				local storeName = string.format("Leaderboard_%s_Daily_%d", property, dayId)
				dataStores[property][PERIOD_TYPES.DAILY] = DataStoreService:GetOrderedDataStore(storeName)
			end
		end
		withCacheLock(function()
			for key in cache do
				if string.find(key, "_Daily_", 1, true) then
					cache[key] = nil
				end
			end
		end)
		resetOccurred = true
	end

	return resetOccurred
end

-------------------------------------------------
-- DataStore operations
-------------------------------------------------

function LeaderboardService:_safeDataStoreOperation(
	operation: () -> any,
	requestType: Enum.DataStoreRequestType?,
	maxRetries: number?
): (boolean, any)
	requestType = requestType or Enum.DataStoreRequestType.UpdateAsync
	maxRetries = maxRetries or SYSTEM_CONFIG.MAX_RETRIES
	local retryDelay = 1
	local lastError: any

	for attempt = 1, maxRetries :: number do
		local budget = DataStoreService:GetRequestBudgetForRequestType(requestType :: Enum.DataStoreRequestType)
		if budget <= 0 then
			warn(
				"[LeaderboardService] DataStore budget exhausted for:",
				(requestType :: Enum.DataStoreRequestType).Name
			)
			return false, "Budget exhausted"
		end

		local success, result = pcall(operation)
		if success then
			return true, result
		end

		lastError = result
		warn(
			string.format(
				"[LeaderboardService] DataStore operation failed (attempt %d/%d): %s",
				attempt,
				maxRetries :: number,
				tostring(result)
			)
		)

		if attempt < maxRetries :: number then
			task.wait(retryDelay)
			retryDelay = retryDelay * 2
		end
	end

	return false, lastError
end

-------------------------------------------------
-- Cache
-------------------------------------------------

function LeaderboardService:_getFromCache(property: string, period: string, pageNumber: number?, pageSize: number?): any
	pageNumber = pageNumber or 1
	pageSize = pageSize or SYSTEM_CONFIG.PAGE_SIZE_DEFAULT
	local cacheKey = getCacheKey(property, period, pageNumber, pageSize)

	return withCacheLock(function()
		local cached = cache[cacheKey]

		if cached then
			local currentTime = tick()
			if currentTime - cached.lastUpdate < cached.ttl then
				return cached.data
			else
				cache[cacheKey] = nil
			end
		end

		return nil
	end)
end

function LeaderboardService:_storeInCache(
	property: string,
	period: string,
	pageNumber: number?,
	pageSize: number?,
	data: any
)
	local cacheKey = getCacheKey(property, period, pageNumber, pageSize)
	local duration = self:_getCacheDuration(period, property)

	withCacheLock(function()
		cache[cacheKey] = {
			data = data,
			lastUpdate = tick(),
			ttl = duration,
		}
	end)
end

local function withPendingFetchesLock(fn: () -> any): any
	local lockId = newproxy()
	while true do
		if not pendingFetchesMutex.locked then
			pendingFetchesMutex.locked = lockId
			if pendingFetchesMutex.locked == lockId then
				break
			end
		end
		task.wait()
	end

	local ok, result = pcall(fn)

	if pendingFetchesMutex.locked == lockId then
		pendingFetchesMutex.locked = false
	end

	if not ok then
		error(result)
	end
	return result
end

function LeaderboardService:_refreshCache(property: string, period: string, pageNumber: number?, pageSize: number?): any
	pageNumber = pageNumber or 1
	pageSize = pageSize or SYSTEM_CONFIG.PAGE_SIZE_DEFAULT

	if not dataStores[property] or not dataStores[property][period] then
		return nil
	end

	local cacheKey = getCacheKey(property, period, pageNumber, pageSize)

	local fetchPromise = withPendingFetchesLock(function()
		local existing = pendingFetches[cacheKey]
		if existing then
			return existing
		end

		local newPromise = Promise.new(function(resolve, _reject)
			local dataStore = dataStores[property][period]

			local success, pages = self:_safeDataStoreOperation(function()
				return dataStore:GetSortedAsync(false, pageSize :: number)
			end, Enum.DataStoreRequestType.GetSortedAsync)

			if not success then
				resolve(nil)
				return
			end

			for _i = 2, pageNumber :: number do
				if pages.IsFinished then
					resolve({ entries = {}, pageNumber = pageNumber, hasMore = false })
					return
				end

				local advanceSuccess = pcall(function()
					pages:AdvanceToNextPageAsync()
				end)

				if not advanceSuccess then
					resolve({ entries = {}, pageNumber = pageNumber, hasMore = false })
					return
				end
			end

			local entries = {}
			local currentPage = pages:GetCurrentPage()
			local startRank = ((pageNumber :: number) - 1) * (pageSize :: number) + 1

			for i, entry in currentPage do
				table.insert(entries, {
					userId = tonumber(entry.key),
					score = entry.value,
					rank = startRank + i - 1,
				})
			end

			local data = {
				entries = entries,
				pageNumber = pageNumber,
				hasMore = not pages.IsFinished,
			}

			self:_storeInCache(property, period, pageNumber, pageSize, data)
			resolve(data)
		end)

		newPromise:finally(function()
			withPendingFetchesLock(function()
				pendingFetches[cacheKey] = nil
			end)
		end)

		pendingFetches[cacheKey] = newPromise
		return newPromise
	end)

	local success, result = fetchPromise:await()
	if success then
		return result
	end
	return nil
end

-------------------------------------------------
-- Queue processing
-------------------------------------------------

function LeaderboardService:_processUpdateQueue()
	local availableBudget = DataStoreService:GetRequestBudgetForRequestType(Enum.DataStoreRequestType.UpdateAsync)
	local maxWrites = math.max(0, availableBudget - SYSTEM_CONFIG.BUDGET_RESERVE)
	if maxWrites == 0 then
		return
	end

	local queueCopy = withQueueLock(function()
		if next(updateQueue) == nil then
			return nil
		end

		local copy = table.clone(updateQueue)
		updateQueue = {}
		local postCount = validateQueueIntegrity()

		if postCount ~= 0 then
			warn(
				string.format(
					"[LeaderboardService] Queue integrity violation: expected 0, got %d after clear",
					postCount
				)
			)
		end

		return copy
	end)

	if not queueCopy then
		return
	end

	local flatUpdates = {}
	for queueKey, update in queueCopy do
		local userId = tonumber(queueKey:match("^(%d+)_"))
		table.insert(flatUpdates, {
			queueKey = queueKey,
			userId = userId,
			score = update.score,
			property = update.property,
			period = update.period,
			periodId = update.periodId,
		})
	end

	table.sort(flatUpdates, function(a, b)
		local aIsAllTime = a.period == PERIOD_TYPES.ALL_TIME
		local bIsAllTime = b.period == PERIOD_TYPES.ALL_TIME
		if aIsAllTime ~= bIsAllTime then
			return aIsAllTime
		end
		if a.property ~= b.property then
			return a.property < b.property
		end
		return a.period < b.period
	end)

	local writesPerformed = 0
	local failedWrites: { [string]: any } = {}
	local deferredWrites: { [string]: any } = {}
	local updatedCombos: { [string]: { string } } = {}

	for _, entry in flatUpdates do
		if writesPerformed >= maxWrites then
			deferredWrites[entry.queueKey] = {
				score = entry.score,
				property = entry.property,
				period = entry.period,
				periodId = entry.periodId,
			}
			continue
		end

		local property = entry.property
		local period = entry.period
		local periodId = entry.periodId

		local dataStore: OrderedDataStore?
		if periodId then
			local storeName: string?
			if period == PERIOD_TYPES.MONTHLY then
				storeName = string.format("Leaderboard_%s_Monthly_%d", property, periodId)
			elseif period == PERIOD_TYPES.WEEKLY then
				storeName = string.format("Leaderboard_%s_Weekly_%d", property, periodId)
			elseif period == PERIOD_TYPES.DAILY then
				storeName = string.format("Leaderboard_%s_Daily_%d", property, periodId)
			end
			if storeName then
				dataStore = DataStoreService:GetOrderedDataStore(storeName)
			end
		else
			dataStore = dataStores[property] and dataStores[property][period]
		end

		if not dataStore then
			continue
		end

		local score = entry.score
		local userId = entry.userId

		local success = self:_safeDataStoreOperation(function()
			(dataStore :: OrderedDataStore):UpdateAsync(tostring(userId), function(oldValue)
				if not oldValue or score > oldValue then
					return score
				end
				return nil
			end)
		end, Enum.DataStoreRequestType.UpdateAsync)

		writesPerformed += 1

		if success then
			withRankCacheLock(function()
				local rankCacheKey = string.format("%d_%s_%s", userId, property, period)
				local existed = playerRankCache[rankCacheKey] ~= nil
				playerRankCache[rankCacheKey] = nil
				if existed then
					playerRankCacheCount = math.max(0, playerRankCacheCount - 1)
				end
			end)

			local comboKey = string.format("%s_%s", property, period)
			if not updatedCombos[comboKey] then
				updatedCombos[comboKey] = { property, period }
			end
		else
			failedWrites[entry.queueKey] = {
				score = score,
				property = property,
				period = period,
				periodId = periodId,
			}
		end
	end

	local toRequeue = table.clone(failedWrites)
	for queueKey, update in deferredWrites do
		toRequeue[queueKey] = update
	end

	if next(toRequeue) then
		withQueueLock(function()
			for queueKey, update in toRequeue do
				if not updateQueue[queueKey] then
					updateQueue[queueKey] = update
				else
					updateQueue[queueKey].score = math.max(updateQueue[queueKey].score, update.score)
				end
			end
		end)
	end

	local combosList = {}
	for _, combo in updatedCombos do
		table.insert(combosList, combo)
	end
	if #combosList > 0 then
		self.Client.LeaderboardUpdated:FireAll(combosList)
	end
end

-------------------------------------------------
-- Cleanup
-------------------------------------------------

function LeaderboardService:_cleanupOldData()
	withCacheLock(function()
		local currentTime = tick()
		for key, cached in cache do
			if currentTime - cached.lastUpdate >= cached.ttl then
				cache[key] = nil
			end
		end

		local cacheCount = 0
		for _ in cache do
			cacheCount = cacheCount + 1
		end

		if cacheCount > SYSTEM_CONFIG.MAX_CACHE_ENTRIES then
			local sortedCache = {}
			for key, cached in cache do
				table.insert(sortedCache, { key = key, lastUpdate = cached.lastUpdate })
			end
			table.sort(sortedCache, function(a, b)
				return a.lastUpdate > b.lastUpdate
			end)
			for i = SYSTEM_CONFIG.MAX_CACHE_ENTRIES + 1, #sortedCache do
				cache[sortedCache[i].key] = nil
			end
		end
	end)

	withRankCacheLock(function()
		local currentTime = tick()
		for key, cached in playerRankCache do
			if currentTime - cached.lastQuery > SYSTEM_CONFIG.PLAYER_RANK_INACTIVE_TIMEOUT then
				playerRankCache[key] = nil
				playerRankCacheCount = math.max(0, playerRankCacheCount - 1)
			end
		end

		local actualCount = 0
		for _ in playerRankCache do
			actualCount = actualCount + 1
		end
		playerRankCacheCount = actualCount
	end)
end

-------------------------------------------------
-- Public API: Score submission
-------------------------------------------------

function LeaderboardService:SubmitScore(userId: number, property: string, score: number, period: string?): boolean
	if type(userId) ~= "number" or userId <= 0 then
		return false
	end

	if not isValidScore(score) then
		warn(
			string.format("[LeaderboardService] Invalid score: %s for property %s", tostring(score), tostring(property))
		)
		return false
	end

	if not isValidProperty(property) then
		warn(string.format("[LeaderboardService] Invalid property: %s", tostring(property)))
		return false
	end

	period = period or PERIOD_TYPES.ALL_TIME

	if not isPeriodEnabled(property, period :: string) then
		return false
	end

	local periodId: number? = nil
	if period == PERIOD_TYPES.MONTHLY then
		periodId = self:_getCurrentPeriodId("month")
	elseif period == PERIOD_TYPES.WEEKLY then
		periodId = self:_getCurrentPeriodId("week")
	elseif period == PERIOD_TYPES.DAILY then
		periodId = self:_getCurrentPeriodId("day")
	end

	local queueKey: string
	if periodId then
		queueKey = string.format("%d_%s_%s_%d", userId, property, period :: string, periodId)
	else
		queueKey = string.format("%d_%s_%s", userId, property, period :: string)
	end

	withQueueLock(function()
		if not updateQueue[queueKey] then
			updateQueue[queueKey] = {
				score = score,
				property = property,
				period = period,
				periodId = periodId,
			}
		else
			updateQueue[queueKey].score = math.max(updateQueue[queueKey].score, score)
		end
	end)

	return true
end

function LeaderboardService:SubmitScoreAllPeriods(userId: number, property: string, score: number): boolean
	if not isValidProperty(property) then
		warn("[LeaderboardService] Invalid property:", property)
		return false
	end

	local config = LeaderboardConfig.Properties[property]
	for period, enabled in config.Periods do
		if enabled then
			self:SubmitScore(userId, property, score, period)
		end
	end

	return true
end

-------------------------------------------------
-- Public API: Queries
-------------------------------------------------

function LeaderboardService:GetTopPlayers(
	property: string,
	period: string?,
	pageNumber: number?,
	pageSize: number?
): any
	period = period or PERIOD_TYPES.ALL_TIME
	pageNumber = pageNumber or 1
	pageSize = pageSize or SYSTEM_CONFIG.PAGE_SIZE_DEFAULT

	pageSize = math.min(pageSize :: number, SYSTEM_CONFIG.PAGE_SIZE_MAX)
	pageSize = math.max(pageSize :: number, 1)

	if not isValidProperty(property) then
		return { entries = {}, pageNumber = 1, hasMore = false }
	end

	if not isPeriodEnabled(property, period :: string) then
		return { entries = {}, pageNumber = 1, hasMore = false }
	end

	if (pageNumber :: number) < 1 then
		pageNumber = 1
	end

	self:_checkPeriodReset()

	local cached = self:_getFromCache(property, period :: string, pageNumber, pageSize)
	if cached then
		return cached
	end

	local data = self:_refreshCache(property, period :: string, pageNumber, pageSize)
	if not data then
		return { entries = {}, pageNumber = pageNumber, hasMore = false }
	end

	return data
end

function LeaderboardService:GetPlayerRank(userId: number, property: string, period: string?): any
	period = period or PERIOD_TYPES.ALL_TIME

	if not isValidProperty(property) then
		return { rank = nil, score = nil }
	end

	if not isPeriodEnabled(property, period :: string) then
		return { rank = nil, score = nil }
	end

	local rankCacheKey = string.format("%d_%s_%s", userId, property, period :: string)

	local cached = withRankCacheLock(function()
		local entry = playerRankCache[rankCacheKey]
		if entry and tick() - entry.lastQuery < SYSTEM_CONFIG.PLAYER_RANK_CACHE_DURATION then
			entry.lastQuery = tick()
			return { rank = entry.rank, score = entry.score }
		end
		return nil
	end)

	if cached then
		return cached
	end

	self:_checkPeriodReset()

	if not dataStores[property] or not dataStores[property][period :: string] then
		return { rank = nil, score = nil }
	end

	local dataStore = dataStores[property][period :: string]

	local success, score = self:_safeDataStoreOperation(function()
		return dataStore:GetAsync(tostring(userId))
	end, Enum.DataStoreRequestType.GetAsync)

	if not success or not score then
		return { rank = nil, score = nil }
	end

	local cachedTop100 = self:_getFromCache(property, period :: string, 1, SYSTEM_CONFIG.TOP_RANK_THRESHOLD)

	if not cachedTop100 then
		cachedTop100 = self:_refreshCache(property, period :: string, 1, SYSTEM_CONFIG.TOP_RANK_THRESHOLD)
	end

	local rank: number? = nil
	if cachedTop100 and cachedTop100.entries then
		for _, entry in cachedTop100.entries do
			if entry.userId == userId then
				rank = entry.rank
				break
			end
		end
	end

	withRankCacheLock(function()
		if not playerRankCache[rankCacheKey] then
			playerRankCacheCount = playerRankCacheCount + 1
		end
		playerRankCache[rankCacheKey] = {
			rank = rank,
			score = score,
			lastQuery = tick(),
		}
		limitPlayerRankCache()
	end)

	return { rank = rank, score = score }
end

function LeaderboardService:GetPlayerStats(userId: number, property: string): { [string]: number? }
	if not isValidProperty(property) then
		return {}
	end

	local stats: { [string]: number? } = {}
	local config = LeaderboardConfig.Properties[property]

	for period, enabled in config.Periods do
		if enabled then
			local result = self:GetPlayerRank(userId, property, period)
			stats[period] = result.score
		end
	end

	return stats
end

function LeaderboardService:GetAllPlayerStats(userId: number): { [string]: { [string]: number? } }
	local allStats: { [string]: { [string]: number? } } = {}

	for property in LeaderboardConfig.Properties do
		allStats[property] = self:GetPlayerStats(userId, property)
	end

	return allStats
end

function LeaderboardService:GetLeaderboardData(
	userId: number,
	property: string,
	period: string?,
	pageNumber: number?,
	pageSize: number?
): any
	local topData = self:GetTopPlayers(property, period, pageNumber, pageSize)

	local playerInList = false
	for _, entry in topData.entries do
		if entry.userId == userId then
			playerInList = true
			break
		end
	end

	local playerRankData = nil
	if not playerInList then
		playerRankData = self:GetPlayerRank(userId, property, period)
	end

	return {
		topPlayers = topData,
		playerRank = playerRankData,
		playerInList = playerInList,
	}
end

function LeaderboardService:ForceRefreshCache(
	property: string,
	period: string?,
	pageNumber: number?,
	pageSize: number?
): any
	period = period or PERIOD_TYPES.ALL_TIME
	pageNumber = pageNumber or 1
	pageSize = pageSize or SYSTEM_CONFIG.PAGE_SIZE_DEFAULT

	pageSize = math.min(pageSize :: number, SYSTEM_CONFIG.PAGE_SIZE_MAX)
	pageSize = math.max(pageSize :: number, 1)

	local cacheKey = getCacheKey(property, period :: string, pageNumber, pageSize)
	withCacheLock(function()
		cache[cacheKey] = nil
	end)

	return self:_refreshCache(property, period :: string, pageNumber, pageSize)
end

-------------------------------------------------
-- Client-exposed methods
-------------------------------------------------

function LeaderboardService.Client:GetLeaderboardData(
	player: Player,
	property: string,
	period: string?,
	pageNumber: number?,
	pageSize: number?
)
	return self.Server:GetLeaderboardData(player.UserId, property, period, pageNumber, pageSize)
end

function LeaderboardService.Client:GetTopPlayers(
	_player: Player,
	property: string,
	period: string?,
	pageNumber: number?,
	pageSize: number?
)
	return self.Server:GetTopPlayers(property, period, pageNumber, pageSize)
end

function LeaderboardService.Client:GetPlayerRank(player: Player, userId: number?, property: string, period: string?)
	userId = userId or player.UserId
	return self.Server:GetPlayerRank(userId :: number, property, period)
end

function LeaderboardService.Client:GetPlayerStats(player: Player, userId: number?, property: string)
	userId = userId or player.UserId
	return self.Server:GetPlayerStats(userId :: number, property)
end

function LeaderboardService.Client:GetAllPlayerStats(player: Player, userId: number?)
	userId = userId or player.UserId
	return self.Server:GetAllPlayerStats(userId :: number)
end

-------------------------------------------------
-- Knit lifecycle
-------------------------------------------------

function LeaderboardService:KnitInit()
	self:_initializePropertyCacheOrder()
end

function LeaderboardService:KnitStart()
	self:_initializeDataStores()

	------------------------------------------------------------------------
	-- TODO: Wire your game-specific score sources below.
	--
	-- This template provides the full leaderboard infrastructure. You only
	-- need to implement two things:
	--
	--   1. submitAllScoresForPlayer(player) — reads current stats from your
	--      game's data service and calls throttledSubmit() for each property.
	--
	--   2. Event listeners that call submitAllScoresForPlayer() when scores
	--      change (e.g., after a round ends, a kill occurs, etc.).
	------------------------------------------------------------------------

	-- Submission throttle state (keeps DataStore writes manageable)
	local lastSubmission: { [string]: number } = {}
	local pendingUpdates: { [string]: { userId: number, property: string, score: number } } = {}

	local function submitScore(userId: number, property: string, score: number)
		local key = `{userId}_{property}`
		lastSubmission[key] = tick()
		pendingUpdates[key] = nil
		self:SubmitScoreAllPeriods(userId, property, score)
	end

	-- selene: allow(unused_variable)
	local function throttledSubmit(userId: number, property: string, score: number)
		local key = `{userId}_{property}`
		local lastTime = lastSubmission[key] or 0

		if tick() - lastTime >= SYSTEM_CONFIG.SUBMISSION_COOLDOWN then
			submitScore(userId, property, score)
		else
			local existing = pendingUpdates[key]
			if not existing or score > existing.score then
				pendingUpdates[key] = {
					userId = userId,
					property = property,
					score = score,
				}
			end
		end
	end

	-- TODO: Implement this function to read your game's current scores for a player.
	-- For each property in LeaderboardConfig, read the player's current value and
	-- call throttledSubmit(). Example:
	--
	--   local function submitAllScoresForPlayer(player: Player)
	--       if not player.Parent then return end
	--       local userId = player.UserId
	--
	--       local PlayerDataService = Knit.GetService("PlayerDataService")
	--
	--       local score1 = PlayerDataService:Read(player, { "Stats", "Score1" }) or 0
	--       if score1 > 0 then
	--           throttledSubmit(userId, "Score1", score1)
	--       end
	--
	--       local score2 = PlayerDataService:Read(player, { "Level" }) or 0
	--       if score2 > 0 then
	--           throttledSubmit(userId, "Score2", score2)
	--       end
	--   end
	-- selene: allow(unused_variable)
	local function submitAllScoresForPlayer(_player: Player)
		-- TODO: Replace this stub with your game-specific score reads.
		warn("[LeaderboardService] submitAllScoresForPlayer is not implemented — wire your game's data here.")
	end

	-- TODO: Connect to your game's events that trigger score updates.
	-- Examples:
	--
	--   -- After a round ends:
	--   RoundService.RoundEnded:Connect(function(player, roundScore)
	--       submitAllScoresForPlayer(player)
	--   end)
	--
	--   -- After a kill:
	--   CombatService.PlayerKilled:Connect(function(killer)
	--       submitAllScoresForPlayer(killer)
	--   end)
	--
	--   -- After leveling up:
	--   LevelService.LevelUp:Connect(function(player)
	--       submitAllScoresForPlayer(player)
	--   end)

	-- Flush pending updates periodically
	task.spawn(function()
		while true do
			task.wait(SYSTEM_CONFIG.SUBMISSION_COOLDOWN)

			for key, update in pendingUpdates do
				local lastTime = lastSubmission[key] or 0
				if
					tick() - lastTime >= SYSTEM_CONFIG.SUBMISSION_COOLDOWN and Players:GetPlayerByUserId(update.userId)
				then
					submitScore(update.userId, update.property, update.score)
				end
			end
		end
	end)

	-- Flush pending throttled updates when player leaves
	Players.PlayerRemoving:Connect(function(player)
		local userId = player.UserId

		for key, update in pendingUpdates do
			if update.userId == userId then
				self:SubmitScoreAllPeriods(userId, update.property, update.score)
				pendingUpdates[key] = nil
				lastSubmission[key] = nil
			end
		end

		-- If last player, flush queue immediately
		if #Players:GetPlayers() <= 1 then
			self:_processUpdateQueue()
		end
	end)

	-- TODO: Submit initial scores when a player joins. Example using PlayerDataService:
	--
	--   local PlayerDataService = Knit.GetService("PlayerDataService")
	--
	--   for _, player in Players:GetPlayers() do
	--       task.spawn(function()
	--           PlayerDataService:WaitForProfile(player)
	--               :andThen(function()
	--                   submitAllScoresForPlayer(player)
	--               end)
	--               :catch(function(err)
	--                   warn("[LeaderboardService] Failed to load initial scores:", err)
	--               end)
	--       end)
	--   end
	--
	--   Players.PlayerAdded:Connect(function(player)
	--       PlayerDataService:WaitForProfile(player)
	--           :andThen(function()
	--               submitAllScoresForPlayer(player)
	--           end)
	--           :catch(function(err)
	--               warn("[LeaderboardService] Failed to load initial scores:", err)
	--           end)
	--   end)

	-- Update queue processor
	task.spawn(function()
		while true do
			task.wait(SYSTEM_CONFIG.UPDATE_INTERVAL)
			self:_processUpdateQueue()
		end
	end)

	-- Period reset checker
	task.spawn(function()
		while true do
			local now = os.time()
			local nextDayReset = self:_getNextResetTime("day")
			local nextWeekReset = self:_getNextResetTime("week")
			local nextMonthReset = self:_getNextResetTime("month")

			local waitTime = math.min(nextDayReset - now, nextWeekReset - now, nextMonthReset - now)
			waitTime = math.max(1, waitTime)

			task.wait(waitTime)
			self:_checkPeriodReset()
		end
	end)

	-- Cleanup routine
	task.spawn(function()
		while true do
			task.wait(SYSTEM_CONFIG.CLEANUP_INTERVAL)
			self:_cleanupOldData()
		end
	end)

	-- Flush queue on server shutdown
	game:BindToClose(function()
		local queueCopy = withQueueLock(function()
			return table.clone(updateQueue)
		end)

		for queueKey, update in queueCopy do
			local property = update.property
			local period = update.period
			local periodId = update.periodId
			local score = update.score
			local userId = tonumber(queueKey:match("^(%d+)_"))

			local dataStore: OrderedDataStore?
			if periodId then
				local storeName: string?
				if period == PERIOD_TYPES.MONTHLY then
					storeName = string.format("Leaderboard_%s_Monthly_%d", property, periodId)
				elseif period == PERIOD_TYPES.WEEKLY then
					storeName = string.format("Leaderboard_%s_Weekly_%d", property, periodId)
				elseif period == PERIOD_TYPES.DAILY then
					storeName = string.format("Leaderboard_%s_Daily_%d", property, periodId)
				end
				if storeName then
					dataStore = DataStoreService:GetOrderedDataStore(storeName)
				end
			else
				dataStore = dataStores[property] and dataStores[property][period]
			end

			if dataStore then
				pcall(function()
					(dataStore :: OrderedDataStore):UpdateAsync(tostring(userId), function(oldValue)
						if not oldValue or score > oldValue then
							return score
						end
						return nil
					end)
				end)
			end
		end

		withQueueLock(function()
			updateQueue = {}
		end)
	end)
end

return LeaderboardService
