Script.Load("lua/GeneralOpti/CacheUtility.lua")

local table_new = require "table.new"
local max = math.max
local abs = math.abs
local band = bit.band
local origin = Vector.origin
local type = type
local Shared_GetTime = Shared.GetTime
local inf = math.huge
local Vector = Vector

local diff = CacheUtility.VectorDiff
local near = CacheUtility.ScalarNear

local kCacheSize        = 64
local kCacheElements    = 8
local keyStart          = 0
local keyStop           = 1
local keyInvRadius      = 2
local keyInvHeight      = 3
local keyCollisionRep   = 4
local keyPhysicsMask    = 5
local keyFilter         = 6
local keyTrace          = 7
local kAcceptance       = 0.3
local kScalarAcceptance = 0.2

local cache = table_new(kCacheSize*kCacheElements, 0)
--[=[
local cache = setmetatable({}, {
	__index = _cache,
	__newindex = function(self, key, value)
		if band(key, 0x7) == keyStart then
			Log("Trace assigned to keyStart: %s", value)
			--Log(debug.callstack())
		end
		_cache[key] = value
	end
})
--]=]
local prev_time
local last = 0

local function set(i, start, stop, inv_radius, inv_height, collisionRep, physicsMask, filter, trace)
	--[=[
	assert(start:isa "Vector")
	assert(stop:isa "Vector")
	assert(type(inv_radius) == "number")
	assert(type(inv_height) == "number")
	assert(type(collisionRep) == "number")
	assert(type(physicsMask) == "number")
	assert(type(filter) == "function" or filter == nil)
	assert(trace == nil or type(trace) == "cdata")
	--]=]
	cache[i+keyStart]        = start
	cache[i+keyStop]         = stop
	cache[i+keyInvRadius]    = inv_radius
	cache[i+keyInvHeight]    = inv_height
	cache[i+keyCollisionRep] = collisionRep
	cache[i+keyPhysicsMask]  = physicsMask
	cache[i+keyFilter]       = filter
	cache[i+keyTrace]        = trace
end

local function clear()
	prev_time = Shared_GetTime()
	last = 0
	local i = 0
	while i < kCacheSize * kCacheElements do
		set(i, origin, origin, 0, 0, 0, 0)
		i = i + kCacheElements
	end
end

local old = Shared.TraceCapsule

local cache_hits   = 0
local cache_misses = 0
local caching_enabled = true
log = false and Log or Lambda ""

function Shared.TraceCapsule(start, stop, radius, height, collisionRep, physicsMask, filter)
	physicsMask = physicsMask or 0

	if caching_enabled then
		if Shared_GetTime() ~= prev_time then
			clear()
		else
			local i = 0
			::loop::
			if --[=[ Cheapest operations ]=]
			  collisionRep == cache[i+keyCollisionRep] and
			  physicsMask  == cache[i+keyPhysicsMask] and
  			  filter       == cache[i+keyFilter] and
			  diff(start, cache[i+keyStart]) < kAcceptance and
			  diff(stop, cache[i+keyStop]) < kAcceptance
			  then
				goto slow_path --[=[ Ignoring a jump is cheaper than taking one. 1/kCacheSize cache entries will match.]=]
			end
			::loop_step::
			i = i + kCacheElements
			if i >= kCacheSize*kCacheElements then
				goto cache_miss
			end
			goto loop

			::slow_path::
			if
			  near(radius, cache[i+keyInvRadius], kScalarAcceptance) and
			  near(height, cache[i+keyInvHeight], kScalarAcceptance)
			  then
				cache_hits = cache_hits + 1
				return cache[i+keyTrace]
			end

			goto loop_step
		end

		::cache_miss::
		cache_misses = cache_misses + 1
	end

	local trace
	if filter then
		trace = old(start, stop, radius, height, collisionRep, physicsMask, filter)
	else
		trace = old(start, stop, radius, height, collisionRep, physicsMask)
	end

	if caching_enabled then
		set(last, Vector(start), Vector(stop), 1/radius, 1/height, collisionRep, physicsMask, filter, trace)
		last = (last + kCacheElements) % (kCacheSize * kCacheElements)
	end

	return trace
end

Event.Hook("Console_capsule_cache_stats", function()
	Log("Capsule Cache hits:   %s", cache_hits)
	Log("Capsule Cache misses: %s", cache_misses)
end)

clear()