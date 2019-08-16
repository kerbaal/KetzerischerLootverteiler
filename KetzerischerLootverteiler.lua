local ADDON, Addon = ...

local Util = Addon.Util

KetzerischerLootverteilerData = {}

local function getActiveTab()
  local tab = PanelTemplates_GetSelectedTab(KetzerischerLootverteilerFrame)
  return KetzerischerLootverteilerFrame.tabView[tab]
end

function HereticTabView_Update(self)
  self.itemView:HereticUpdate()
end

function Addon:update(reason)
  Util.dbgprint("Updating UI (" .. reason ..")..")
  HereticTabView_Update(getActiveTab())
end

function KetzerischerLootverteilerShow()
  KetzerischerLootverteilerFrame:Show()
  Addon:update("show")
end

function KetzerischerLootverteilerToggle()
  if (KetzerischerLootverteilerFrame:IsVisible()) then
    KetzerischerLootverteilerFrame:Hide()
  else
    KetzerischerLootverteilerShow()
  end
end

-- This function assumes that there is at most one saved ID for each
-- instance name and difficulty.
function FindSavedInstanceID(instanceName, instanceDifficultyID)
  local numInstances = GetNumSavedInstances()
  for i = 1, numInstances do
    local savedInstanceName, id, reset, savedInstanceDifficultyID = GetSavedInstanceInfo(i)
    if savedInstanceName == instanceName and savedInstanceDifficultyID == instanceDifficultyID then
      return id
    end
  end
  return nil
end

function Addon:Initialize()
  Addon.MSG_PREFIX = "KTZR_LT_VERT";
  Addon.MSG_CLAIM_MASTER = "ClaimMaster";
  Addon.MSG_CHECK_MASTER = "CheckMaster";
  Addon.MSG_DELETE_LOOT = "DeleteLoot";
  Addon.MSG_DELETE_LOOT_PATTERN = "^%s+([^ ]+)%s+(.*)$";
  Addon.MSG_RENOUNCE_MASTER = "RenounceMaster";
  Addon.MSG_ANNOUNCE_LOOT = "LootAnnounce";
  Addon.MSG_ANNOUNCE_LOOT_PATTERN = "^%s+([^ ]+)%s+(.*)$";
  Addon.MSG_ANNOUNCE_WINNER = "Winner";
  Addon.MSG_ANNOUNCE_WINNER_PATTERN = "^%s+([^ ]+)%s+([^ ]+)%s+([^ ]+)%s+([^ ]+)%s+([^ ]+)$";
  Addon.TITLE_TEXT = "Ketzerischer Lootverteiler";
  Addon.itemList = HereticList:New("master");
  Addon.activeHistoryIndex = 1;
  Addon.master = nil;
  Addon.lootCount = {};
  Addon.rolls = {};
  C_ChatInfo.RegisterAddonMessagePrefix(Addon.MSG_PREFIX);
end

function Addon:GetActiveHistory()
  return HereticHistory:GetItemListByIndex(Addon.activeHistoryIndex)
end

function Addon:RecomputeLootCount()
  wipe(Addon.lootCount)
  for i,entry in pairs(Addon:GetActiveHistory().entries) do
    if (entry.winner) then
      local cat = entry.winner:GetCategory()
      local record = Addon.lootCount[entry.winner.name] or {}
      Addon.lootCount[entry.winner.name] = record
      record.name = entry.winner.name
      local count = record.count or {}
      record.count = count
      count[cat] = (count[cat] or 0) + 1
    end
    if (entry.donator) then
      local record = Addon.lootCount[entry.donator] or {}
      Addon.lootCount[entry.donator] = record
      record.name = entry.donator
      local donations = record.donations or 0
      record.donations = donations + 1
    end
  end
end

function Addon:AnnouceLootCount()
  Addon:RecomputeLootCount()
  local n = 0
  for k,v in pairs(Addon.lootCount) do
    n=n+1
    local line = Util.ShortenFullName(v.name)
    if (v.donations) then
      line = line .. " donated " .. v.donations .. ""
    end
    if (v.count) then
      if (v.donations) then line = line .. " and" end
      line = line ..  " received " .. Util.formatLootCountMono(v.count, true, true)
    end
    line = line .. "."
    SendChatMessage(line, "RAID")
  end
end

function Addon:CountLootFor(name, cat)
  local entry = Addon.lootCount[name] or {}
  local count = entry.count or {}
  if cat == nil then return count end
  return count[cat] or 0
end

function Addon:CountDonationsFor(name)
  local entry = Addon.lootCount[name] or {}
  local donations = entry.donations or 0
  return donations
end

function Addon:OnWinnerUpdate(entry, prevWinner)
  Addon:RecomputeLootCount()
  Addon:update("on winner update")
  if (Addon:IsMaster()) then
    local msg = Addon.MSG_ANNOUNCE_WINNER .. " " .. entry.donator .. " " ..
      entry.itemLink .. " "

    if entry.winner then
      msg = msg .. entry.winner.name .. " " .. entry.winner.roll ..
        " " .. entry.winner.max
    else
      msg = msg .. "- - -"
    end

    Util.dbgprint ("Announcing winner: " .. msg)
    C_ChatInfo.SendAddonMessage(Addon.MSG_PREFIX, msg, "RAID")
  end
  HereticRollCollectorFrame_Update(HereticRollCollectorFrame)
end

function Addon:SetWinner(itemString, donator, sender, winnerName, rollValue, rollMax)
  local index = Addon:GetActiveHistory():GetEntryId(itemString, donator, sender)
  if not index then
    return
  end
  local entry = Addon:GetActiveHistory():GetEntry(index)
  local prevWinner = entry.winner
  rollValue, rollMax = tonumber(rollValue), tonumber(rollMax)
  if (winnerName == "-" or not rollValue or not rollMax) then
    entry.winner = nil
  else
    entry.winner = HereticRoll:New(winnerName, rollValue, rollMax)
  end
  Addon:OnWinnerUpdate(entry, prevWinner)
end

function Addon:CanModify(owner)
  return Addon:IsMaster()
    or (not Addon:HasMaster())
    or (owner ~= nil and owner ~= Addon.master)
end

local function showIfNotCombat()
  if not UnitAffectingCombat("player") then
    KetzerischerLootverteilerShow()
  end
end

function Addon:AddItem(itemString, from, sender)
  if (Addon:HasMaster() and sender ~= Addon.master) then return end
  itemString = itemString:match("item[%-?%d:]+")
  if (itemString == nil) then return end
  if (from == nil or from:gsub("%s+", "") == "") then return end
  from = from:gsub("%s+", "")
  itemString = itemString:gsub("%s+", "")

  -- Do not filter if the item comes from the lootmaster.
  if (sender ~= Addon.master or Addon:IsMaster()) then
    local quality = select(3,GetItemInfo(itemString))
    if (Addon.minRarity and quality < Addon.minRarity[1]) then
      return
    end
  end

  local item = HereticItem:New(itemString, from, sender)
  Addon.itemList:AddEntry(item)
  local itemList = HereticHistory:GetItemListForCurrentInstance()
  itemList:AddEntry(item)
  --PlaySound("igBackPackCoinSelect")
  PlaySound(SOUNDKIT.TELL_MESSAGE);
  --PlaySound("igMainMenuOptionCheckBoxOn")

  if Addon:IsMaster() then
    local msg = Addon.MSG_ANNOUNCE_LOOT .. " " .. from .. " " .. itemString
    Util.dbgprint("Announcing loot")
    C_ChatInfo.SendAddonMessage(Addon.MSG_PREFIX, msg, "RAID")
  end

  Addon:update("AddItem")
  showIfNotCombat()
end

function Addon:DeleteItem(index)
  local entry = Addon.itemList:GetEntry(index)
  entry.isCurrent = false

  if Addon:IsMaster() then
    local msg = Addon.MSG_DELETE_LOOT .. " " .. entry.donator .. " " .. entry.itemLink
    Util.dbgprint("Announcing loot deletion")
    C_ChatInfo.SendAddonMessage(Addon.MSG_PREFIX, msg, "RAID")
  end

  Addon.itemList:DeleteEntryAt(index)
  PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_OFF);
  Addon:update("DeleteItem")
end

local function updateTitle()
  if (Addon.master) then
    local name, _ = Util.DecomposeName(Addon.master)
    KetzerischerLootverteilerTitleText:SetText(Addon.TITLE_TEXT .. ": "
      .. Util.GetPlayerLink(Addon.master, name))
  else
    KetzerischerLootverteilerTitleText:SetText(Addon.TITLE_TEXT)
  end
end

function Addon:IsMaster()
  return Util.GetFullUnitName("player") == Addon.master
end

function Addon:HasMaster()
  return Addon.master ~= nil and not Addon:IsMaster()
end

function Addon:SetMaster(name)
  Addon.master = name
  updateTitle()
end

local function IsPlayerInPartyOrRaid()
  return GetNumGroupMembers(LE_PARTY_CATEGORY_HOME) > 0
end

function Addon:IsAuthorizedToClaimMaster(unitId)
  -- Reject master claims from instance groups.
  if not unitId then return false end
  if (Util.GetFullUnitName(unitId) == Util.GetFullUnitName("player")
      and not IsPlayerInPartyOrRaid()) then
    return true
  end
  return UnitIsGroupAssistant(unitId) or UnitIsGroupLeader(unitId)
end

function Addon:ClaimMaster()
  if Addon:IsAuthorizedToClaimMaster("player") then
    print ("You proclaim yourself Ketzerischer Lootverteiler.")
    C_ChatInfo.SendAddonMessage(Addon.MSG_PREFIX, Addon.MSG_CLAIM_MASTER, "RAID")
    C_ChatInfo.SendAddonMessage(Addon.MSG_PREFIX, Addon.MSG_CLAIM_MASTER, "WHISPER", Util.GetFullUnitName("player"))
  else
    print ("Only leader or assistant may become Ketzerischer Lootverteiler.")
  end
end

function Addon:GetItemLinkFromId(id)
  local itemIndex = Addon.itemListView:IdToIndex(id);
  return Addon.itemList:GetItemLinkByID(itemIndex)
end

function Addon:ProcessClaimMaster(name)
  if (name == nil) then return end
  if (Addon.master == name) then return end
  Util.dbgprint(name .. " claims lootmastership")

  local unitId = HereticRaidInfo:GetUnitId(name)
  if (Addon:IsAuthorizedToClaimMaster(unitId)) then
    Addon:SetMaster(name)
    print ("You accepted " .. name .. " as your Ketzerischer Lootverteiler.")
  end
end

function Addon:RenounceMaster()
  if (Addon.master ~= Util.GetFullUnitName("player")) then return end
  print ("You renounce your title of Ketzerischer Lootverteiler.")
  C_ChatInfo.SendAddonMessage(Addon.MSG_PREFIX, Addon.MSG_RENOUNCE_MASTER, "RAID")
end

function Addon:ProcessRenounceMaster(name)
  if (Addon.master == name) then
    Addon:SetMaster(nil)
  end
end

function KetzerischerLootverteilerFrame_Update(self, elapsed)
  getActiveTab():Update()
end

function Addon:AddAllItems(itemStrings, from, sender)
  for itemString in string.gmatch(itemStrings, "item[%-?%d:]+") do
    Addon:AddItem(itemString, from, sender)
  end
end

function Addon:IsTrackedDifficulity(difficultyID)
  return 14 <= difficultyID and difficultyID <= 16
end

function Addon:OnAddonLoaded()
  HereticRaidInfo:Deserialize(KetzerischerLootverteilerData)
  HereticRaidInfo:Update()
  if KetzerischerLootverteilerData.histories then
    HereticHistory:Deserialize(KetzerischerLootverteilerData.histories)
  end
  if KetzerischerLootverteilerData.activeHistoryIndex then
    local deserialized = KetzerischerLootverteilerData.activeHistoryIndex
    Addon.activeHistoryIndex = math.min(deserialized, HereticHistory:NumberOfItemLists())
  end
  Addon:RecomputeLootCount()
  if KetzerischerLootverteilerData.minRarity then
    Addon.minRarity = KetzerischerLootverteilerData.minRarity
  end
  if (KetzerischerLootverteilerData.isVisible == nil or
      KetzerischerLootverteilerData.isVisible == true) then
    KetzerischerLootverteilerShow()
  end
  if (KetzerischerLootverteilerData.master and IsPlayerInPartyOrRaid()) then
    C_ChatInfo.SendAddonMessage(Addon.MSG_PREFIX, Addon.MSG_CHECK_MASTER, "WHISPER",
      KetzerischerLootverteilerData.master)
  end
  if KetzerischerLootverteilerData.activeTab then
    HereticTab_SetActiveTab(Util.toRange(KetzerischerLootverteilerFrame.tabView, KetzerischerLootverteilerData.activeTab))
  end
  Addon:update("addon loaded")
end

function Addon:Serialize()
  KetzerischerLootverteilerData.histories = HereticHistory.histories
  KetzerischerLootverteilerData.activeHistoryIndex = Addon.activeHistoryIndex
  KetzerischerLootverteilerData.isVisible = KetzerischerLootverteilerFrame:IsVisible()
  KetzerischerLootverteilerData.master = Addon.master
  KetzerischerLootverteilerData.minRarity = Addon.minRarity
  KetzerischerLootverteilerData.activeTab = PanelTemplates_GetSelectedTab(KetzerischerLootverteilerFrame)
  HereticRaidInfo:Serialize(KetzerischerLootverteilerData)
end

-- Keybindings
BINDING_HEADER_KETZERISCHER_LOOTVERTEILER = "Ketzerischer Lootverteiler"
BINDING_NAME_KETZERISCHER_LOOTVERTEILER_TOGGLE = "Toggle window"

StaticPopupDialogs["HERETIC_LOOT_MASTER_CONFIRM_DELETE_FROM_HISTORY"] = {
  text = "Are you sure you want to delete this item permanently from history?",
  button1 = "Yes",
  button2 = "No",
  OnAccept = function(self)
    self.data.list:DeleteEntryAt(self.data.index)
    Addon:update("delete from history")
  end,
  OnCancel = function()
    -- Do nothing and keep item.
  end,
  timeout = 10,
  whileDead = true,
  hideOnEscape = true,
  hasItemFrame = 1,
}

function MasterLootItem_OnClick(self, button, down, entry)
  if (button == "RightButton" and IsModifiedClick("SHIFT")) then
    if not Addon:CanModify(self.entry.sender) then return end
    if self.index then Addon:DeleteItem(self.index) end
    return true
  end
  if (button == "RightButton" and not IsModifiedClick()) then
    HereticRollCollectorFrame:Toggle()
    return true
  end
  if (button == "LeftButton" and IsModifiedClick("ALT")) then
    local itemLink = select(2,GetItemInfo(entry.itemLink))
    local text = itemLink .. " (" .. Util.ShortenFullName(entry.donator) .. ")"
    SendChatMessage(text, "RAID")
    HereticRollCollectorFrame_BeginRollCollection(HereticRollCollectorFrame, entry)
    return true
  end
  return false
end

function HistoryLootItem_OnClick(self, button, down)
  if (button == "RightButton" and IsModifiedClick()) then
    if not Addon:CanModify(self.entry.sender) then return end
    if self.entry.isCurrent then
      print ("Refusing to delete item from history that is still on Master page.")
    elseif self.entry.winner then
      print ("Refusing to delete item from history that has a winner assigned.")
    else
      StaticPopup_Show("HERETIC_LOOT_MASTER_CONFIRM_DELETE_FROM_HISTORY", "", "",
        {useLinkForItemInfo = true, link = self.entry.itemLink, list = Addon:GetActiveHistory(), index = self.index})
    end
    return true
  end
  -- Disable whispering for history items.
  if (button == "RightButton") then return true end
  return false
end

function KetzerischerLootverteilerFrame_GetItemAtCursor(self)
  local frame = HereticHistoryScrollFrame_GetItemAtCursor(getActiveTab().itemView)
  if frame then return frame end
  frame = HereticRollCollectorFrame
  if (frame and frame:IsMouseOver() and frame:IsVisible()) then
    return frame
  end
  return nil
end

function KetzerischerLootverteilerFrame_OnLoad(self)
  Addon:Initialize()
  HereticRaidInfo:Initialize()
  Addon:InitializeEventHandlers(KetzerischerLootverteilerFrame);

  self:RegisterForDrag("LeftButton");

  KetzerischerLootverteilerFrame.tabView[1].itemView.HereticUpdate = HereticHistoryScrollFrame_Update
  KetzerischerLootverteilerFrame.tabView[1].itemView.itemList = Addon.itemList
  KetzerischerLootverteilerFrame.tabView[1].itemView.HereticOnItemClicked =  MasterLootItem_OnClick
  KetzerischerLootverteilerFrame.tabView[2].itemView.HereticUpdate =
    function (self)
      self.itemList = Addon:GetActiveHistory()
      HereticHistoryScrollFrame_Update(self)
    end
  KetzerischerLootverteilerFrame.tabView[2].itemView.itemList = HereticHistory.histories[1]
  KetzerischerLootverteilerFrame.tabView[2].itemView.HereticOnItemClicked = HistoryLootItem_OnClick
  KetzerischerLootverteilerFrame.tabView[3].itemView.HereticUpdate =
    function (self)
      HereticPlayerInfoScrollFrame_Update(self)
    end

  KetzerischerLootverteilerFrame.GetItemAtCursor = KetzerischerLootverteilerFrame_GetItemAtCursor
  PanelTemplates_SetNumTabs(KetzerischerLootverteilerFrame, #KetzerischerLootverteilerFrame.tabView);
  HereticTab_SetActiveTab(1)
end

function KetzerischerLootverteilerFrame_OnDragStart()
  KetzerischerLootverteilerFrame:StartMoving();
end

function KetzerischerLootverteilerFrame_OnDragStop()
  KetzerischerLootverteilerFrame:StopMovingOrSizing();
end

function HereticTab_SetActiveTab(id)
  PanelTemplates_SetTab(KetzerischerLootverteilerFrame, id);
  for i,tab in pairs(KetzerischerLootverteilerFrame.tabView) do
    if i == id then
      tab:Show();
    else
      tab:Hide();
    end
  end
  Addon:update("set active tab")
end

function HereticTab_OnClick(self)
  HereticTab_SetActiveTab(self:GetID())
end

function Addon:SetCurrentHistory(id)
  Addon.activeHistoryIndex = id
  Addon:RecomputeLootCount()
  Addon:update("change history")
end

function KetzerischerLootverteilerRollButton_OnClick(self)
   HereticRollCollectorFrame:Toggle()
end

function HereticPlayerInfo_OnClick(self)
  Util.dbgprint("clicked")
end

function HereticPlayerInfo_OnEnter(self)

end

function HereticPlayerInfoScrollFrame_OnLoad(self)
  HybridScrollFrame_OnLoad(self);
  self.update = HereticPlayerInfoScrollFrame_Update;
  self.scrollBar.doNotHide = true
  self.dynamic =
    function (offset)
      return math.floor(offset / 20), offset % 20
    end
  HybridScrollFrame_CreateButtons(self, "HereticPlayerInfoTemplate");
end

function HereticLootTally_OnEnter(self)
  GameTooltip:SetOwner(self, "ANCHOR_RIGHT");
  local categories = ""
  local first = true
  for category,max in pairs(HereticRoll.GetCategories()) do
    local coloredCategory = HereticRoll.GetColoredCategoryName(category);
    categories = coloredCategory .. (first and " " or ", ") .. categories
    first = false
  end
  local text = "Shows items |cff00ccffdonated|r and received in categories "
  GameTooltip:SetText(text .. categories);
end

function HereticLootTally_SetFromPlayer(self, name)
  local donations = Addon:CountDonationsFor(name)
  if donations > 0 then
    self.donated:SetFormattedText("|cff00ccff%d|r /", donations);
  else
    self.donated:SetText("");
  end
  local count = Addon:CountLootFor(name)
  self.received:SetText(Util.formatLootCount(count))
end

function HereticPlayerInfoScrollFrame_Update(self)
  local scrollFrame = KetzerischerLootverteilerFrameTabView3Container
  local offset = HybridScrollFrame_GetOffset(scrollFrame);
  local buttons = scrollFrame.buttons;
  local numButtons = #buttons;
  local buttonHeight = buttons[1]:GetHeight();

  local playernames={}
  local n=0

  for k,v in pairs(Addon.lootCount) do
    n=n+1
    playernames[n]=k
  end

  for i=1, numButtons do
    local frame = buttons[i];
    local index = i + offset;
    if (index <= n) then
      frame:SetID(index);
      frame.name:SetText(HereticRaidInfo:GetColoredPlayerName(playernames[index]));
      HereticLootTally_SetFromPlayer(frame.lootTally, playernames[index])
      frame:Show()
    else
      frame:Hide()
    end
  end
  HybridScrollFrame_Update(scrollFrame, n * buttonHeight, scrollFrame:GetHeight());
end
