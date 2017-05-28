
do
	local nearest_commandstation_key = newproxy()

	function Observatory:FindCommandStation()
		self[nearest_commandstation_key] = GetNearest(self:GetOrigin(), "CommandStation", self:GetTeamNumber(), Lambda [[(...):GetIsBuilt() and (...):GetIsAlive()]]):GetId()
		return Shared.GetEntity(self[nearest_commandstation_key])
	end

	function Observatory:GetCommandStation()
		return Shared.GetEntity(self[nearest_commandstation_key]) or self:FindCommandStation()
	end

	function Observatory:GetDistressOrigin()
		local cc = self:GetCommandStation()
		return cc and cc:GetModelOrigin()
	end
end

--[[
	Only server
]]
if not Server then return end


local kDistressBeaconTime = Observatory.kDistressBeaconTime
local kDistressBeaconRange = Observatory.kDistressBeaconRange

local kIgnorePlayers = kNS2OptiConfig.InfinitePlayerRelevancy

local kRelevantToAll = kRelevantToAll
local oldUpdateIncludeRelevancyMask_key = newproxy()
local old_include_mask = newproxy()

local function GetPlayersToBeacon(self)
	local players = { }

	self:GetTeam():ForEachPlayer(Closure [[
		self toOrigin players
		args player
		if not player:isa "Marine" or (player:GetOrigin() - toOrigin):GetLengthSquared() < (kDistressBeaconRange*1.1)^2 then
			return
		end

		table.insert(players, player)
	]] {self:GetDistressOrigin(), players})

	return players
end

local function altUpdateIncludeRelevancyMask(self)
	self:SetIncludeRelevancyMask(kRelevantToAll)
end

local function makeRelevant(self)
	self[old_include_mask] = self:GetIncludeRelevancyMask()
	self:SetIncludeRelevancyMask(kRelevantToAll)
end

local function makePlayerRelevant(self)
	self[oldUpdateIncludeRelevancyMask_key] = self.UpdateClientRelevancyMask
	self.UpdateIncludeRelevancyMask = altUpdateIncludeRelevancyMask
	self:UpdateIncludeRelevancyMask()
end

local function makeIrrelevant(self)
	self:SetIncludeRelevancyMask(self[old_include_mask])
	self[old_include_mask] = nil
end

local makePlayerIrrelevant

if kIgnorePlayers then
	function makePlayerIrrelevant(self)
		self:SetLOSUpdates(true)
	end
else
	function makePlayerIrrelevant(self)
		self.UpdateIncludeRelevancyMask = self[oldUpdateIncludeRelevancyMask_key]
		self[oldUpdateIncludeRelevancyMask_key] = nil
		self:UpdateIncludeRelevancyMask()
		self:SetLOSUpdates(true)
	end
end

local function beaconStart(self, target, delay)
	if not kIgnorePlayers then
		self:AddTimedCallback(makePlayerRelevant, delay)
	end
	self:AddTimedCallback(makePlayerIrrelevant, kDistressBeaconTime + 5)
	self:SetLOSUpdates(false)
end

local oldTriggerDistressBeacon = Observatory.TriggerDistressBeacon

function Observatory:TriggerDistressBeacon()
	self:FindCommandStation()
	local distressOrigin = self:GetDistressOrigin()

	-- May happen at the end of the game?
	if not distressOrigin or self:GetIsBeaconing() then
		return false, true
	end

	local step = kDistressBeaconTime / Server.GetNumPlayers()
	local closure_self = {beaconStart, step, distressOrigin, delay = 0}

	local functor = Closure [=[
		self beaconStart step target
		args player

		if player:isa "Marine" then
			beaconStart(player, target, self.delay)
			self.delay = self.delay + step
		end
	]=] (closure_self)

	GetGamerules():GetTeam1():ForEachPlayer(functor) -- Marines
	GetGamerules():GetTeam2():ForEachPlayer(functor) -- Aliens

	local entities = self:GetCommandStation():GetLocationEntity():GetEntitiesInTrigger()
	local constructs = {}
	local ips = {}
	if #entities == 0 then
		entities = GetEntitiesWithMixinWithinRange("Construct", distressOrigin, 20)
		constructs = entities
		for i = 1, #constructs do
			if constructs[i]:isa "InfantryPortal" then
				table.insert(ips, constructs[i])
			end
		end
	else
		for i = 1, #entities do
			if entities[i]:isa "InfantryPortal" then
				table.insert(ips, entities[i])
				table.insert(constructs, entities[i])
			elseif HasMixin(entities[i], "Construct") then
				table.insert(constructs, entities[i])
			end
		end
	end
	local step = kDistressBeaconTime / #constructs

	Shared.Message("Found " .. #constructs .. " constructs and " .. #ips .. " IPs; step: " .. step)

	local delay = 0
	for i = 1, #constructs do
		local construct = constructs[i]

		construct:AddTimedCallback(makeRelevant, delay)
		construct:AddTimedCallback(makeIrrelevant, kDistressBeaconTime + 5)
		delay = delay + step
	end

	local step = kDistressBeaconTime / #ips
	local delay = 0
	for i = 1, #ips do
		ips[i]:AddTimedCallback(ips[i].FinishSpawn, delay)
		delay = delay + step
	end

	return oldTriggerDistressBeacon(self)
end

function Observatory:PerformDistressBeacon()

	self.distressBeaconSound:Stop()

	local distressOrigin = self:GetDistressOrigin()
	if not distressOrigin then
		return
	end

	local to_beacon = GetPlayersToBeacon(self)

	Shared.Message("Found " .. #to_beacon .. " players to beacon")

	local spawnPoints = GetBeaconPointsForTechPoint(self:GetCommandStation().attachedId)
	
	if not spawnPoints then
		return
	end

	for i = 1, #to_beacon do
		local player = to_beacon[i]

		if HasMixin(player, "SmoothedRelevancy") then
			player:StartSmoothedRelevancy(spawnPoints[i])
		end
		player:SetOrigin(spawnPoints[i])
		player:TriggerBeaconEffects()
	end

	self:TriggerEffects("distress_beacon_complete")

end