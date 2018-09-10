--[[
	scanner.lua
		Scanner module for BagSync, scans bags, bank, currency, etc...
--]]

local BSYC = select(2, ...) --grab the addon namespace
local Scanner = BSYC:NewModule("Scanner")
local Unit = BSYC:GetModule("Unit")

--https://github.com/tomrus88/BlizzardInterfaceCode/blob/master/Interface/AddOns/Blizzard_VoidStorageUI/Blizzard_VoidStorageUI.lua
local VOID_DEPOSIT_MAX = 9
local VOID_WITHDRAW_MAX = 9
local VOID_STORAGE_MAX = 80
local VOID_STORAGE_PAGES = 2

local FirstEquipped = INVSLOT_FIRST_EQUIPPED
local LastEquipped = INVSLOT_LAST_EQUIPPED

function Scanner:StartupScans()
	self:SaveEquipment()

	for i = BACKPACK_CONTAINER, BACKPACK_CONTAINER + NUM_BAG_SLOTS do
		self:SaveBag("bag", i)
	end
	
	self:SaveCurrency()
	
	--cleanup the auction DB
	BSYC:GetModule("Data"):CheckExpiredAuctions()
end

function Scanner:SaveBag(bagtype, bagid)
	if not bagtype or not bagid then return end
	if not BSYC.db.player[bagtype] then BSYC.db.player[bagtype] = {} end

	if GetContainerNumSlots(bagid) > 0 then
		
		local slotItems = {}
		
		for slot = 1, GetContainerNumSlots(bagid) do
			local _, count, _,_,_,_, link = GetContainerItemInfo(bagid, slot)
			if link then
				table.insert(slotItems,  BSYC:ParseItemLink(link, count))
			end
		end
		
		--lets also store the bags themselves
		if bagid ~= BACKPACK_CONTAINER and bagid ~= BANK_CONTAINER and bagid ~= REAGENTBANK_CONTAINER then
			local slot = ContainerIDToInventoryID(bagid)
			local link = GetInventoryItemLink('player', slot)
			if link then
				table.insert(slotItems,  BSYC:ParseItemLink(link))
			end
		end
			
		BSYC.db.player[bagtype][bagid] = slotItems
	else
		BSYC.db.player[bagtype][bagid] = nil
	end
end

function Scanner:SaveEquipment()
	if not BSYC.db.player.equip then BSYC.db.player.equip = {} end
	
	local slotItems = {}
	
	for slot = FirstEquipped, LastEquipped do
		local link = GetInventoryItemLink("player", slot)
		local count =  GetInventoryItemCount("player", slot)
		if link then
			table.insert(slotItems,  BSYC:ParseItemLink(link, count))
		end
	end
	
	BSYC.db.player.equip = slotItems
end

function Scanner:SaveBank(rootOnly)
	if not Unit.atBank then return end
	
	--force scan of bank bag -1, since blizzard never sends updates for it
	self:SaveBag("bank", BANK_CONTAINER)
	
	if not rootOnly then
		--https://wow.gamepedia.com/BagId#/search
		for i = NUM_BAG_SLOTS + 1, NUM_BAG_SLOTS + NUM_BANKBAGSLOTS do
			self:SaveBag("bank", i)
		end
		--scan the reagents as part of the bank scan
		self:SaveReagents()
	end
end

function Scanner:SaveReagents()
	if not Unit.atBank then return end
	
	if IsReagentBankUnlocked() then 
		self:SaveBag("reagents", REAGENTBANK_CONTAINER)
	end
end

function Scanner:SaveVoidBank()
	if not Unit.atVoidBank then return end
	if not BSYC.db.player.void then BSYC.db.player.void = {} end
	
	local slotItems = {}
	
	for tab = 1, VOID_STORAGE_PAGES do
		for i = 1, VOID_STORAGE_MAX do
			local link, textureName, locked, recentDeposit, isFiltered = GetVoidItemInfo(tab, i)
			if link then
				table.insert(slotItems, BSYC:ParseItemLink(link))
			end
		end
	end
	
	BSYC.db.player.void = slotItems
end

function Scanner:GetXRGuild()
	if not IsInGuild() then return end
	
	--only return one guild stored from a connected realm list, otherwise we will have multiple entries of the same guild on several connected realms
	local realms = {strsplit(';', Unit:GetRealmKey())}
	local player = Unit:GetUnitInfo()
	
	if #realms > 0 then
		for i = 1, #realms do
			if player.guild and BagSyncDB[realms[i]] and BagSyncDB[realms[i]][player.guild] then
				return BagSyncDB[realms[i]][player.guild]
			end
		end
	end
	
	if not BSYC.db.realm[player.guild] then BSYC.db.realm[player.guild] = {} end
	return BSYC.db.realm[player.guild]
end

function Scanner:SaveGuildBank()
	if not IsInGuild() then return end

	local numTabs = GetNumGuildBankTabs()
	local slotItems = {}
	
	for tab = 1, numTabs do
		local name, icon, isViewable, canDeposit, numWithdrawals, remainingWithdrawals = GetGuildBankTabInfo(tab)
		--if we don't check for isViewable we get a weirdo permissions error for the player when they attempt it
		if isViewable then
			for slot = 1, MAX_GUILDBANK_SLOTS_PER_TAB do
				local link = GetGuildBankItemLink(tab, slot)
				if link then
					local _, count = GetGuildBankItemInfo(tab, slot)
					table.insert(slotItems, BSYC:ParseItemLink(link, count))
				end
			end
		end
	end

	local guildDB = self:GetXRGuild()
	if guildDB then
		guildDB.bag = slotItems
		guildDB.money = GetGuildBankMoney()
		guildDB.faction = Unit:GetUnitInfo().faction
		guildDB.realmKey = Unit:GetRealmKey()
	end
end

function Scanner:SaveMailbox()
	if not Unit.atMailbox then return end
	if not BSYC.db.player.mailbox then BSYC.db.player.mailbox = {} end
	
	if self.isCheckingMail then return end --prevent overflow from CheckInbox()
	self.isCheckingMail = true

	 --used to initiate mail check from server, for some reason GetInboxNumItems() returns zero sometimes
	 --even though the user has mail in the mailbox.  This can be attributed to lag.
	CheckInbox()
	
	local slotItems = {}
	local numInbox = GetInboxNumItems()

	--scan the inbox
	if (numInbox > 0) then
		for mailIndex = 1, numInbox do
			for i = 1, ATTACHMENTS_MAX_RECEIVE do
				local name, itemID, itemTexture, count, quality, canUse = GetInboxItem(mailIndex, i)
				local link = GetInboxItemLink(mailIndex, i)
				if name and link then
					table.insert(slotItems, BSYC:ParseItemLink(link, count))
				end
			end
		end
	end
	
	BSYC.db.player.mailbox = slotItems
	
	self.isCheckingMail = false
end

function Scanner:SaveAuctionHouse()
	if not Unit.atAuction then return end
	if not BSYC.db.player.auction then BSYC.db.player.auction = {} end

	local slotItems = {}
	local numActiveAuctions = GetNumAuctionItems("owner")

	--scan the auction house
	if (numActiveAuctions > 0) then
		for ahIndex = 1, numActiveAuctions do
			local name, texture, count, quality, canUse, level, minBid, minIncrement, buyoutPrice, bidAmount, highBidder, owner, saleStatus  = GetAuctionItemInfo("owner", ahIndex)
			if name then
				local link = GetAuctionItemLink("owner", ahIndex)
				local timeLeft = GetAuctionItemTimeLeft("owner", ahIndex)
				if link and timeLeft then
					count = (count or 1)
					table.insert(slotItems, BSYC:ParseItemLink(link, count)..";"..timeLeft)
				end
			end
		end
	end
	
	BSYC.db.player.auction.bag = slotItems
	BSYC.db.player.auction.count = #slotItems
	BSYC.db.player.auction.lastscan = time()
end

function Scanner:SaveCurrency()
	if Unit:InCombatLockdown() then return end

	local lastHeader
	local limit = GetCurrencyListSize()
	local slotItems = {}
	
	for i=1, limit do
	
		local name, isHeader, isExpanded, _, _, count, icon = GetCurrencyListInfo(i)
		--extraCurrencyType = 1 for arena points, 2 for honor points; 0 otherwise (an item-based currency).

		if name then
			if(isHeader and not isExpanded) then
				ExpandCurrencyList(i,1)
				lastHeader = name
				limit = GetCurrencyListSize()
			elseif isHeader then
				lastHeader = name
			end
			if (not isHeader) then
				slotItems[icon] = slotItems[icon] or {}
				slotItems[icon].name = name
				slotItems[icon].header = lastHeader
				slotItems[icon].count = count
			end
		end
	end
	
	BSYC.db.player.currency = slotItems
end