local addonName = "AHCrafterPrice"
local frame = CreateFrame("Frame")
local scanQueue = {}
local isScanning = false
local professionPriceFrame = nil
local lastProfessionRecipeID = nil
local lastProfessionAHOpen = nil
local professionTicker = nil
local mainFrame = nil
local mainStatusText = nil
local mainLogText = nil
local minimapButton = nil
local uiLogLines = {}
local db = nil
local PRICE_CACHE_HIT_TTL = 30 * 60
local PRICE_CACHE_MISS_TTL = 5 * 60
local PRICE_CACHE_MAX_ENTRIES = 2000

-- Forward declarations for functions referenced before their definitions.
local CreateProfessionPriceFrame
local UpdateProfessionPriceDisplay
local StartProfessionWatcher
local EnqueueAuctionQuery
local InitializeAddonUI
local AppendUILogLine
local SetMainStatus

local recipes = {
    ["mochila de seda de fogo solar"] = {
        itemName = "mochila de seda de fogo solar",
        reagents = {
            ["filamento de bordado"] = 2,
            ["granulo de energia primeva"] = 6,
            ["rolo de seda de fogo solar"] = 10,
            ["desa de fogo solar"] = 32,
        },
    },
}

local function Print(msg)
    if DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[" .. addonName .. "]|r " .. msg)
    else
        print("[" .. addonName .. "] " .. msg)
    end
    if AppendUILogLine then
        AppendUILogLine(msg)
    end
    if SetMainStatus then
        SetMainStatus(msg)
    end
end

local function FormatCopper(copper)
    if not copper or copper <= 0 then
        return "sem preço"
    end
    local gold = math.floor(copper / 10000)
    local silver = math.floor((copper % 10000) / 100)
    local copperRem = copper % 100
    return string.format("%dg %02ds %02dc", gold, silver, copperRem)
end

local function IsRetailAH()
    return type(C_AuctionHouse) == "table" and type(C_AuctionHouse.SendBrowseQuery) == "function"
end

local function BuildRetailBrowseSorts()
    local sortOrder = (type(Enum) == "table" and type(Enum.AuctionHouseSortOrder) == "table") and Enum.AuctionHouseSortOrder or nil
    local priceSort = (sortOrder and sortOrder.Price) or 0
    local nameSort = (sortOrder and sortOrder.Name) or 1

    return {
        { sortOrder = priceSort, reverseSort = false },
        { sortOrder = nameSort, reverseSort = false },
    }
end

local function NormalizeSearchText(search)
    local text = tostring(search or "")
    text = text:gsub("[%c\r\n\t]+", " ")
    text = text:gsub("%s+", " ")
    text = text:gsub("^%s+", "")
    text = text:gsub("%s+$", "")
    return text
end

local function GetNowTimestamp()
    if type(GetServerTime) == "function" then
        local nowTs = GetServerTime()
        if nowTs and nowTs > 0 then
            return nowTs
        end
    end
    return time()
end

local function GetPriceCacheTable()
    if type(db) ~= "table" then
        return nil
    end
    if type(db.priceCache) ~= "table" then
        db.priceCache = {}
    end
    return db.priceCache
end

local function BuildPriceCacheKey(search)
    return string.lower(NormalizeSearchText(search))
end

local function IsPriceCacheEntryFresh(entry, nowTs)
    if type(entry) ~= "table" then
        return false
    end

    local ts = tonumber(entry.ts or 0) or 0
    if ts <= 0 then
        return false
    end

    local ttl = entry.hasPrice and PRICE_CACHE_HIT_TTL or PRICE_CACHE_MISS_TTL
    local age = nowTs - ts
    return age >= 0 and age <= ttl
end

local function GetCachedAuctionPrice(search)
    local cache = GetPriceCacheTable()
    if not cache then
        return false, nil
    end

    local key = BuildPriceCacheKey(search)
    if key == "" then
        return false, nil
    end

    local entry = cache[key]
    if not entry then
        return false, nil
    end

    local nowTs = GetNowTimestamp()
    if not IsPriceCacheEntryFresh(entry, nowTs) then
        return false, nil
    end

    if entry.hasPrice then
        return true, tonumber(entry.price)
    end

    return true, nil
end

local function GetCachedAuctionPriceInfo(search, allowStale)
    local cache = GetPriceCacheTable()
    if not cache then
        return false, nil, false, 0
    end

    local key = BuildPriceCacheKey(search)
    if key == "" then
        return false, nil, false, 0
    end

    local entry = cache[key]
    if not entry then
        return false, nil, false, 0
    end

    local nowTs = GetNowTimestamp()
    local isFresh = IsPriceCacheEntryFresh(entry, nowTs)
    if not isFresh and not allowStale then
        return false, nil, false, 0
    end

    local ageSeconds = math.max(0, nowTs - (tonumber(entry.ts or nowTs) or nowTs))
    if entry.hasPrice then
        return true, tonumber(entry.price), isFresh, ageSeconds
    end

    return true, nil, isFresh, ageSeconds
end

local function FormatCacheAge(ageSeconds)
    local seconds = math.floor(tonumber(ageSeconds or 0) or 0)
    if seconds < 60 then
        return string.format("%ds", seconds)
    end

    local minutes = math.floor(seconds / 60)
    if minutes < 60 then
        return string.format("%dm", minutes)
    end

    local hours = math.floor(minutes / 60)
    if hours < 24 then
        return string.format("%dh %dm", hours, minutes % 60)
    end

    local days = math.floor(hours / 24)
    return string.format("%dd %dh", days, hours % 24)
end

local function BuildCachedProfessionStatusText(recipeData, allowStale)
    local statusLines = {}
    local totalReagentCost = 0
    local pricedReagents = 0
    local totalReagents = 0
    local missingData = 0
    local staleEntries = 0

    for reagentName, qty in pairs(recipeData.reagents) do
        totalReagents = totalReagents + 1
        local hasEntry, price, isFresh, ageSeconds = GetCachedAuctionPriceInfo(reagentName, allowStale)

        if hasEntry and price then
            pricedReagents = pricedReagents + 1
            totalReagentCost = totalReagentCost + (price * qty)

            local cacheTag = ""
            if not isFresh then
                staleEntries = staleEntries + 1
                cacheTag = string.format(" (cache %s)", FormatCacheAge(ageSeconds))
            end
            statusLines[#statusLines + 1] = string.format("%s x%d = %s%s", reagentName, qty, FormatCopper(price), cacheTag)
        elseif hasEntry then
            missingData = missingData + 1
            local cacheTag = ""
            if not isFresh then
                staleEntries = staleEntries + 1
                cacheTag = string.format(" (cache %s)", FormatCacheAge(ageSeconds))
            end
            statusLines[#statusLines + 1] = string.format("%s x%d = sem preco%s", reagentName, qty, cacheTag)
        else
            missingData = missingData + 1
            statusLines[#statusLines + 1] = string.format("%s x%d = sem cache", reagentName, qty)
        end
    end

    if pricedReagents > 0 then
        if pricedReagents < totalReagents then
            statusLines[#statusLines + 1] = string.format("Total reagentes (parcial): %s", FormatCopper(totalReagentCost))
        else
            statusLines[#statusLines + 1] = string.format("Total reagentes: %s", FormatCopper(totalReagentCost))
        end
    else
        statusLines[#statusLines + 1] = "Total reagentes: sem dados em cache"
    end

    local itemEntry, itemPrice, itemFresh, itemAge = GetCachedAuctionPriceInfo(recipeData.itemName, allowStale)
    if itemEntry and itemPrice then
        local itemTag = ""
        if not itemFresh then
            staleEntries = staleEntries + 1
            itemTag = string.format(" (cache %s)", FormatCacheAge(itemAge))
        end
        statusLines[#statusLines + 1] = string.format("Preco item AH: %s%s", FormatCopper(itemPrice), itemTag)
        if totalReagentCost > 0 then
            statusLines[#statusLines + 1] = string.format("Lucro estimado: %s", FormatCopper(itemPrice - totalReagentCost))
        end
    elseif itemEntry then
        missingData = missingData + 1
        local itemTag = ""
        if not itemFresh then
            staleEntries = staleEntries + 1
            itemTag = string.format(" (cache %s)", FormatCacheAge(itemAge))
        end
        statusLines[#statusLines + 1] = "Preco item AH: sem preco" .. itemTag
    else
        missingData = missingData + 1
        statusLines[#statusLines + 1] = "Preco item AH: sem cache"
    end

    local hasAnyData = (pricedReagents > 0) or itemEntry
    return table.concat(statusLines, "\n"), hasAnyData, missingData, staleEntries
end

local function SaveCachedAuctionPrice(search, price)
    local cache = GetPriceCacheTable()
    if not cache then
        return
    end

    local key = BuildPriceCacheKey(search)
    if key == "" then
        return
    end

    cache[key] = {
        ts = GetNowTimestamp(),
        hasPrice = price ~= nil,
        price = price or 0,
        search = NormalizeSearchText(search),
    }
end

local function PrunePriceCache()
    local cache = GetPriceCacheTable()
    if not cache then
        return 0
    end

    local nowTs = GetNowTimestamp()
    local keysByAge = {}
    local count = 0

    for key, entry in pairs(cache) do
        if IsPriceCacheEntryFresh(entry, nowTs) then
            count = count + 1
            keysByAge[#keysByAge + 1] = { key = key, ts = tonumber(entry.ts or 0) or 0 }
        else
            cache[key] = nil
        end
    end

    if count <= PRICE_CACHE_MAX_ENTRIES then
        return count
    end

    table.sort(keysByAge, function(a, b)
        return a.ts < b.ts
    end)

    local toRemove = count - PRICE_CACHE_MAX_ENTRIES
    for i = 1, toRemove do
        cache[keysByAge[i].key] = nil
    end

    return PRICE_CACHE_MAX_ENTRIES
end

local function ClearPriceCache()
    local cache = GetPriceCacheTable()
    if not cache then
        return 0
    end

    local removed = 0
    for key in pairs(cache) do
        cache[key] = nil
        removed = removed + 1
    end

    return removed
end

local function GetPriceCacheStats()
    local cache = GetPriceCacheTable()
    if not cache then
        return 0, 0, 0
    end

    local nowTs = GetNowTimestamp()
    local total = 0
    local fresh = 0
    local withPrice = 0

    for _, entry in pairs(cache) do
        total = total + 1
        if IsPriceCacheEntryFresh(entry, nowTs) then
            fresh = fresh + 1
            if entry.hasPrice then
                withPrice = withPrice + 1
            end
        end
    end

    return total, fresh, withPrice
end

local function BuildRetailBrowseFilters()
    local filters = {}
    local filterEnum = (type(Enum) == "table" and type(Enum.AuctionHouseFilter) == "table") and Enum.AuctionHouseFilter or nil

    if filterEnum then
        local qualityFilters = {
            filterEnum.PoorQuality,
            filterEnum.CommonQuality,
            filterEnum.UncommonQuality,
            filterEnum.RareQuality,
            filterEnum.EpicQuality,
            filterEnum.LegendaryQuality,
        }
        for _, filterValue in ipairs(qualityFilters) do
            if filterValue ~= nil then
                table.insert(filters, filterValue)
            end
        end
    end

    if #filters == 0 and filterEnum and filterEnum.None ~= nil then
        table.insert(filters, filterEnum.None)
    end
    if #filters == 0 then
        table.insert(filters, 0)
    end

    return filters
end

local function CreateRetailBrowseQuery(search)
    local normalizedSearch = NormalizeSearchText(search)
    local sorts = BuildRetailBrowseSorts()
    local filters = BuildRetailBrowseFilters()
    local itemClassFilters = {}

    if type(C_AuctionHouse) == "table" and type(C_AuctionHouse.MakeBrowseQuery) == "function" then
        local ok, query = pcall(C_AuctionHouse.MakeBrowseQuery, normalizedSearch, sorts, filters, itemClassFilters)
        if ok and query then
            return query
        end
    end

    return {
        searchString = normalizedSearch,
        sorts = sorts,
        filters = filters,
        itemClassFilters = itemClassFilters,
    }
end

local function RetailSendBrowseQuery(search)
    local query = CreateRetailBrowseQuery(search)
    if type(C_AuctionHouse.SendBrowseQuery) == "function" then
        Print("Enviando consulta AH Retail para: " .. search)
        local ok, err = pcall(C_AuctionHouse.SendBrowseQuery, query)
        if ok then
            return true
        end

        -- Compatibility fallback for older signatures.
        local okLegacy, legacyErr = pcall(C_AuctionHouse.SendBrowseQuery, query, query.sorts, false)
        if okLegacy then
            return true
        end

        Print("Falha ao enviar BrowseQuery: " .. tostring(err or legacyErr))
        return false
    end
    Print("C_AuctionHouse.SendBrowseQuery não disponível")
    return false
end

local function StartScan()
    if isScanning or #scanQueue == 0 then
        return
    end

    local query = scanQueue[1]
    if not query then
        return
    end

    Print("Iniciando scan para: " .. query.search)
    if IsRetailAH() then
        isScanning = true
        if not RetailSendBrowseQuery(query.search) then
            Print("Falha ao enviar consulta para a Casa de Leilões.")
            scanQueue = {}
            isScanning = false
        end
        return
    end

    if type(QueryAuctionItems) ~= "function" then
        Print("API de leilões não disponível nesta versão do WoW.")
        scanQueue = {}
        isScanning = false
        return
    end

    isScanning = true
    QueryAuctionItems(query.search, nil, nil, nil, nil, 0, false, 0, false)
end

local function GetAuctionPrice(search)
    if IsRetailAH() then
        if type(C_AuctionHouse.GetBrowseResults) == "function" then
            local browseResults = C_AuctionHouse.GetBrowseResults()
            local lowest = nil

            if type(browseResults) == "table" then
                for _, result in ipairs(browseResults) do
                    local unitPrice = result and (result.minPrice or result.buyoutPrice)
                    if unitPrice and unitPrice > 0 then
                        if not lowest or unitPrice < lowest then
                            lowest = unitPrice
                        end
                    end
                end
            end

            if lowest then
                return lowest
            end
        end

        if type(C_AuctionHouse.GetNumBrowseResults) == "function" and type(C_AuctionHouse.GetBrowseResultInfo) == "function" then
            local numAuctions = C_AuctionHouse.GetNumBrowseResults()
            local lowest = nil

            for i = 1, numAuctions do
                local info = C_AuctionHouse.GetBrowseResultInfo(i)
                local buyoutPrice = nil
                local count = nil

                if type(info) == "table" then
                    buyoutPrice = info.minPrice or info.buyoutPrice
                    count = info.totalQuantity or info.quantity
                else
                    local itemID
                    itemID, _, count, _, _, _, _, _, buyoutPrice = C_AuctionHouse.GetBrowseResultInfo(i)
                end

                if buyoutPrice and buyoutPrice > 0 then
                    local unitPrice = buyoutPrice
                    if count and count > 0 then
                        unitPrice = buyoutPrice / count
                    end
                    if not lowest or unitPrice < lowest then
                        lowest = unitPrice
                    end
                end
            end

            return lowest
        end

        return nil
    end

    if type(GetNumAuctionItems) ~= "function" or type(GetAuctionItemInfo) ~= "function" then
        return nil
    end

    local numAuctions = GetNumAuctionItems("list")
    local lowest = nil

    for i = 1, numAuctions do
        local name, _, count, _, _, _, _, _, buyoutPrice = GetAuctionItemInfo("list", i)
        if name and buyoutPrice and buyoutPrice > 0 then
            local unitPrice = buyoutPrice
            if count and count > 0 then
                unitPrice = buyoutPrice / count
            end
            if not lowest or unitPrice < lowest then
                lowest = unitPrice
            end
        end
    end

    return lowest
end

local function ProcessNextScan()
    if #scanQueue == 0 then
        isScanning = false
        return
    end

    local query = scanQueue[1]
    local price = GetAuctionPrice(query.search)
    query.result = price
    SaveCachedAuctionPrice(query.search, price)
    PrunePriceCache()

    if type(query.callback) == "function" then
        query.callback(price)
    end
    table.remove(scanQueue, 1)
    isScanning = false
    C_Timer.After(0.2, StartScan)
end

frame:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        local loadedName = ...
        if loadedName == addonName then
            Print("ADDON_LOADED recebido")
            if InitializeAddonUI then
                InitializeAddonUI()
            end
            if CreateProfessionPriceFrame then
                CreateProfessionPriceFrame()
            end
            if StartProfessionWatcher then
                StartProfessionWatcher()
            end
        end
    elseif event == "PLAYER_LOGIN" or event == "PLAYER_ENTERING_WORLD" then
        Print("PLAYER_LOGIN recebido")
        if InitializeAddonUI then
            InitializeAddonUI()
        end
        if CreateProfessionPriceFrame then
            CreateProfessionPriceFrame()
        end
        if StartProfessionWatcher then
            StartProfessionWatcher()
        end
    elseif event == "TRADE_SKILL_SHOW" or event == "CRAFT_SHOW" or event == "PROFESSION_SHOW" then
        Print("Evento de profissão recebido: " .. event)
        if CreateProfessionPriceFrame then
            CreateProfessionPriceFrame()
        end
        if UpdateProfessionPriceDisplay then
            UpdateProfessionPriceDisplay()
        end
    elseif event == "TRADE_SKILL_CLOSE" or event == "CRAFT_CLOSE" or event == "PROFESSION_CLOSE" then
        if professionPriceFrame then
            professionPriceFrame:Hide()
        end
        lastProfessionRecipeID = nil
        lastProfessionAHOpen = nil
    elseif event == "AUCTION_ITEM_LIST_UPDATE" or event == "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED" or event == "AUCTION_HOUSE_BROWSE_RESULTS_ADDED" then
        if isScanning and #scanQueue > 0 then
            Print("Evento recebido: " .. event)
            ProcessNextScan()
        end
    elseif event == "AUCTION_HOUSE_SHOW" then
        if isScanning and #scanQueue > 0 then
            Print("Evento recebido: " .. event)
            ProcessNextScan()
        end
        lastProfessionRecipeID = nil
        lastProfessionAHOpen = nil
        if UpdateProfessionPriceDisplay and ProfessionsFrame and ProfessionsFrame:IsShown() then
            UpdateProfessionPriceDisplay()
        end
    elseif event == "AUCTION_HOUSE_CLOSED" then
        scanQueue = {}
        isScanning = false
        lastProfessionRecipeID = nil
        lastProfessionAHOpen = nil
        if UpdateProfessionPriceDisplay and ProfessionsFrame and ProfessionsFrame:IsShown() then
            UpdateProfessionPriceDisplay()
        end
    end
end)

local function RegisterEventSafe(eventName)
    local ok, err = pcall(frame.RegisterEvent, frame, eventName)
    if not ok then
        Print("Evento indisponível nesta versão do WoW: " .. eventName)
        if err then
            Print("Detalhe: " .. tostring(err))
        end
    end
end

RegisterEventSafe("ADDON_LOADED")
RegisterEventSafe("PLAYER_LOGIN")
RegisterEventSafe("PLAYER_ENTERING_WORLD")
RegisterEventSafe("TRADE_SKILL_SHOW")
RegisterEventSafe("TRADE_SKILL_CLOSE")
RegisterEventSafe("CRAFT_SHOW")
RegisterEventSafe("CRAFT_CLOSE")
RegisterEventSafe("PROFESSION_SHOW")
RegisterEventSafe("PROFESSION_CLOSE")
RegisterEventSafe("AUCTION_ITEM_LIST_UPDATE")
RegisterEventSafe("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
RegisterEventSafe("AUCTION_HOUSE_BROWSE_RESULTS_ADDED")
RegisterEventSafe("AUCTION_HOUSE_SHOW")
RegisterEventSafe("AUCTION_HOUSE_CLOSED")

local function IsAuctionHouseOpen()
    return (AuctionHouseFrame and (AuctionHouseFrame:IsShown() or AuctionHouseFrame:IsVisible())) or (AuctionFrame and (AuctionFrame:IsShown() or AuctionFrame:IsVisible()))
end

CreateProfessionPriceFrame = function()
    local parent = UIParent
    if ProfessionsFrame and ProfessionsFrame.CraftingPage then
        parent = ProfessionsFrame.CraftingPage
    elseif ProfessionsFrame then
        parent = ProfessionsFrame
    end

    if professionPriceFrame then
        if professionPriceFrame:GetParent() ~= parent then
            professionPriceFrame:SetParent(parent)
        end
        professionPriceFrame:ClearAllPoints()
        professionPriceFrame:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -20, -80)
        return
    end

    professionPriceFrame = CreateFrame("Frame", "AHCrafterPriceProfessionFrame", parent, "BackdropTemplate")
    professionPriceFrame:SetFrameStrata("DIALOG")
    professionPriceFrame:SetFrameLevel(1000)
    professionPriceFrame:SetClampedToScreen(true)
    professionPriceFrame:SetSize(280, 150)
    professionPriceFrame:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -20, -80)
    professionPriceFrame:SetBackdrop({
        bgFile = "Interface/Tooltips/UI-Tooltip-Background",
        edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
        tile = true,
        tileSize = 16,
        edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    professionPriceFrame:SetBackdropColor(0, 0, 0, 0.85)
    professionPriceFrame:Hide()
    Print("Painel de profissão criado com parent: UIParent")

    professionPriceFrame.title = professionPriceFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    professionPriceFrame.title:SetPoint("TOPLEFT", 8, -8)
    professionPriceFrame.title:SetText("AH Price")

    professionPriceFrame.status = professionPriceFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    professionPriceFrame.status:SetPoint("TOPLEFT", professionPriceFrame.title, "BOTTOMLEFT", 0, -6)
    professionPriceFrame.status:SetPoint("BOTTOMRIGHT", professionPriceFrame, "BOTTOMRIGHT", -8, 8)
    professionPriceFrame.status:SetJustifyH("LEFT")
    professionPriceFrame.status:SetJustifyV("TOP")
    professionPriceFrame.status:SetNonSpaceWrap(true)
    professionPriceFrame.status:SetText("Aguardando receita...")
end

local function GetSelectedRecipeFromProfessionUI()
    local craftingPage = ProfessionsFrame and ProfessionsFrame.CraftingPage
    local schematicForm = craftingPage and craftingPage.SchematicForm
    if not craftingPage then
        return nil, nil
    end

    local infoGetters = {
        function()
            if schematicForm and type(schematicForm.GetRecipeInfo) == "function" then
                return schematicForm:GetRecipeInfo()
            end
            return nil
        end,
        function()
            if schematicForm and type(schematicForm.GetCurrentRecipeInfo) == "function" then
                return schematicForm:GetCurrentRecipeInfo()
            end
            return nil
        end,
        function()
            if type(craftingPage.GetRecipeInfo) == "function" then
                return craftingPage:GetRecipeInfo()
            end
            return nil
        end,
    }

    for _, getter in ipairs(infoGetters) do
        local ok, info = pcall(getter)
        if ok and type(info) == "table" then
            local recipeID = info.recipeID or info.recipeId or info.id
            local recipeName = info.name or info.recipeName
            if recipeID and recipeID ~= 0 then
                return recipeID, recipeName
            end
        end
    end

    local idGetters = {
        function()
            if schematicForm and type(schematicForm.GetSelectedRecipeID) == "function" then
                return schematicForm:GetSelectedRecipeID()
            end
            return nil
        end,
        function()
            if type(craftingPage.GetSelectedRecipeID) == "function" then
                return craftingPage:GetSelectedRecipeID()
            end
            return nil
        end,
    }

    for _, getter in ipairs(idGetters) do
        local ok, recipeID = pcall(getter)
        if ok and recipeID and recipeID ~= 0 then
            return recipeID, nil
        end
    end

    return nil, nil
end

local function GetSelectedProfessionRecipeID()
    if type(C_TradeSkillUI) == "table" and type(C_TradeSkillUI.GetSelectedRecipeID) == "function" then
        local recipeID = C_TradeSkillUI.GetSelectedRecipeID()
        if recipeID and recipeID ~= 0 then
            return recipeID, nil
        end
    end
    return GetSelectedRecipeFromProfessionUI()
end

local function GetItemNameFromID(itemID)
    if not itemID or itemID <= 0 then
        return nil
    end
    if type(C_Item) == "table" and type(C_Item.GetItemNameByID) == "function" then
        local name = C_Item.GetItemNameByID(itemID)
        if name then
            return name
        end
    end
    return GetItemInfo(itemID)
end

local function BuildProfessionRecipeData(recipeID, recipeNameHint)
    if type(C_TradeSkillUI) ~= "table" then
        return nil
    end
    if not recipeID or recipeID == 0 then
        return nil
    end

    local info = nil
    if type(C_TradeSkillUI.GetRecipeInfo) == "function" then
        info = C_TradeSkillUI.GetRecipeInfo(recipeID)
    end

    local itemName = recipeNameHint
    if not itemName and info and info.name then
        itemName = info.name
    end

    local reagents = {}

    if type(C_TradeSkillUI.GetRecipeSchematic) == "function" then
        local okSchematic, schematic = pcall(C_TradeSkillUI.GetRecipeSchematic, recipeID, false)
        if okSchematic and type(schematic) == "table" then
            if not itemName then
                itemName = GetItemNameFromID(schematic.outputItemID)
            end

            if type(schematic.reagentSlotSchematics) == "table" then
                for _, slot in ipairs(schematic.reagentSlotSchematics) do
                    local qty = tonumber(slot.quantityRequired or slot.requiredQuantity or slot.quantity or 0) or 0
                    local name = nil

                    if type(slot.reagents) == "table" then
                        local reagent = slot.reagents[1]
                        if type(reagent) == "table" then
                            name = reagent.name
                            if not name then
                                name = GetItemNameFromID(reagent.itemID)
                            end
                        end
                    end

                    if name and qty > 0 then
                        reagents[name] = qty
                    end
                end
            end
        end
    end

    if not next(reagents) and type(C_TradeSkillUI.GetRecipeReagentInfo) == "function" then
        local reagentCount = 0
        if type(C_TradeSkillUI.GetRecipeNumReagents) == "function" then
            reagentCount = C_TradeSkillUI.GetRecipeNumReagents(recipeID)
        end

        for reagentIndex = 1, reagentCount do
            local name, _, qty, _, _, _, _, _, link = C_TradeSkillUI.GetRecipeReagentInfo(recipeID, reagentIndex)
            if not name and link then
                name = GetItemInfo(link)
            end
            if name and qty and qty > 0 then
                reagents[name] = qty
            end
        end
    end

    if not itemName and info and info.name then
        itemName = info.name
    end
    if not itemName then
        itemName = tostring(recipeID)
    end

    if not next(reagents) then
        return nil
    end

    return { itemName = itemName, reagents = reagents }
end

UpdateProfessionPriceDisplay = function()
    if not professionPriceFrame then
        CreateProfessionPriceFrame()
    end

    if not professionPriceFrame then
        return
    end

    professionPriceFrame:Show()

    local recipeID, recipeNameHint = GetSelectedProfessionRecipeID()
    if not recipeID or recipeID == 0 then
        professionPriceFrame.status:SetText("Selecione uma receita na aba de profissao.")
        lastProfessionRecipeID = nil
        lastProfessionAHOpen = nil
        return
    end

    local ahOpen = IsAuctionHouseOpen()
    if recipeID == lastProfessionRecipeID and ahOpen == lastProfessionAHOpen then
        return
    end

    local recipeData = BuildProfessionRecipeData(recipeID, recipeNameHint)
    if not recipeData or not next(recipeData.reagents) then
        professionPriceFrame.status:SetText("Nao foi possivel obter os reagentes desta receita.")
        lastProfessionRecipeID = nil
        lastProfessionAHOpen = nil
        return
    end

    professionPriceFrame.title:SetText("AH Price: " .. recipeData.itemName)
    lastProfessionRecipeID = recipeID
    lastProfessionAHOpen = ahOpen

    if not ahOpen then
        local cachedText, hasAnyData, missingData, staleEntries = BuildCachedProfessionStatusText(recipeData, true)
        if hasAnyData then
            local footer = "Fonte: cache local (AH fechada). Abra a AH para atualizar."
            if staleEntries > 0 then
                footer = footer .. " Alguns valores estao antigos."
            end
            if missingData > 0 then
                footer = footer .. " Itens sem cache: " .. tostring(missingData) .. "."
            end
            professionPriceFrame.status:SetText(cachedText .. "\n" .. footer)
        else
            professionPriceFrame.status:SetText("Sem dados em cache para esta receita.\nAbra a casa de leiloes para pesquisar precos.")
        end
        return
    end

    professionPriceFrame.status:SetText("Pesquisando precos na AH...")

    local totalReagentCost = 0
    local results = {}
    local pending = 0

    for reagentName, qty in pairs(recipeData.reagents) do
        pending = pending + 1
        EnqueueAuctionQuery(reagentName, function(price)
            results[reagentName] = { qty = qty, price = price }
            pending = pending - 1
            if pending == 0 then
                local statusLines = {}
                local missing = false
                for name, info in pairs(results) do
                    if info.price then
                        totalReagentCost = totalReagentCost + info.price * info.qty
                        statusLines[#statusLines + 1] = string.format("%s x%d = %s", name, info.qty, FormatCopper(info.price))
                    else
                        statusLines[#statusLines + 1] = string.format("%s x%d = sem preco", name, info.qty)
                        missing = true
                    end
                end
                statusLines[#statusLines + 1] = string.format("Total reagentes: %s", FormatCopper(totalReagentCost))

                EnqueueAuctionQuery(recipeData.itemName, function(itemPrice)
                    if itemPrice then
                        statusLines[#statusLines + 1] = string.format("Preco item AH: %s", FormatCopper(itemPrice))
                        if totalReagentCost > 0 then
                            local profit = itemPrice - totalReagentCost
                            statusLines[#statusLines + 1] = string.format("Lucro estimado: %s", FormatCopper(profit))
                        end
                    else
                        statusLines[#statusLines + 1] = "Preco do item: sem preco"
                    end
                    if missing then
                        statusLines[#statusLines + 1] = "Alguns reagentes nao tem preco disponivel."
                    end
                    professionPriceFrame.status:SetText(table.concat(statusLines, "\n"))
                end)
            end
        end)
    end
end
StartProfessionWatcher = function()
    if professionTicker then
        return
    end
    professionTicker = C_Timer.NewTicker(1.0, function()
        if ProfessionsFrame and ProfessionsFrame:IsShown() then
            UpdateProfessionPriceDisplay()
        elseif professionPriceFrame then
            professionPriceFrame:Hide()
            lastProfessionRecipeID = nil
            lastProfessionAHOpen = nil
        end
    end)
end

EnqueueAuctionQuery = function(search, callback)
    local normalizedSearch = NormalizeSearchText(search)
    if normalizedSearch == "" then
        if callback then
            callback(nil)
        end
        return
    end

    local cacheHit, cachedPrice = GetCachedAuctionPrice(normalizedSearch)
    if cacheHit then
        if callback then
            callback(cachedPrice)
        end
        return
    end

    table.insert(scanQueue, {search = normalizedSearch, callback = callback})
    StartScan()
end

local function GetKnownRecipes()
    if type(C_TradeSkillUI) ~= "table" or type(C_TradeSkillUI.GetAllRecipeIDs) ~= "function" then
        return nil
    end

    local recipeIDs = C_TradeSkillUI.GetAllRecipeIDs()
    if not recipeIDs or #recipeIDs == 0 then
        Print("GetKnownRecipes: nenhuma receita encontrada via GetAllRecipeIDs.")
        return nil
    end

    local recipesMap = {}
    for _, recipeID in ipairs(recipeIDs) do
        local recipeNameHint = nil
        if type(C_TradeSkillUI.GetRecipeInfo) == "function" then
            local recipeInfo = C_TradeSkillUI.GetRecipeInfo(recipeID)
            if recipeInfo then
                recipeNameHint = recipeInfo.name
            end
        end

        local recipeData = BuildProfessionRecipeData(recipeID, recipeNameHint)
        if recipeData and recipeData.itemName and next(recipeData.reagents or {}) then
            recipesMap[recipeData.itemName] = recipeData
        end
    end
    return next(recipesMap) and recipesMap or nil
end

local function GetRecipeData(recipeName)
    local recipe = recipes[recipeName]
    if recipe then
        return recipe
    end
    local knownRecipes = GetKnownRecipes()
    if knownRecipes then
        return knownRecipes[recipeName]
    end
    return nil
end

local function BuildPriceScanList(recipeSet)
    local uniqueNames = {}
    for itemName, recipe in pairs(recipeSet) do
        uniqueNames[itemName] = true
        for reagentName in pairs(recipe.reagents) do
            uniqueNames[reagentName] = true
        end
    end
    local list = {}
    for name in pairs(uniqueNames) do
        table.insert(list, name)
    end
    return list
end

local function ScanAllRecipes()
    local recipeSet = GetKnownRecipes()
    local usingStatic = false
    if not recipeSet then
        recipeSet = recipes
        usingStatic = true
        Print("Não foi possível ler receitas do ofício. Usando receitas estáticas do addon.")
    else
        local recipeCount = 0
        for _ in pairs(recipeSet) do
            recipeCount = recipeCount + 1
        end
        Print("Receitas do ofício carregadas: " .. recipeCount)
    end

    local searchList = BuildPriceScanList(recipeSet)
    if #searchList == 0 then
        Print("Nenhuma receita disponível para escanear.")
        return
    end

    local results = {}
    local pending = #searchList
    Print(string.format("Escaneando %d termos na AH. Aguarde...", pending))

    for _, searchName in ipairs(searchList) do
        EnqueueAuctionQuery(searchName, function(price)
            results[searchName] = price
            pending = pending - 1
            if pending == 0 then
                local recipeSummaries = {}
                for recipeName, recipe in pairs(recipeSet) do
                    local totalReagentCost = 0
                    local missing = false
                    for reagentName, qty in pairs(recipe.reagents) do
                        local reagentPrice = results[reagentName]
                        if reagentPrice then
                            totalReagentCost = totalReagentCost + reagentPrice * qty
                        else
                            missing = true
                        end
                    end
                    local itemPrice = results[recipeName]
                    local profit = (itemPrice and totalReagentCost > 0) and (itemPrice - totalReagentCost) or nil
                    table.insert(recipeSummaries, {
                        name = recipeName,
                        reagentCost = totalReagentCost,
                        itemPrice = itemPrice,
                        profit = profit,
                        missing = missing,
                    })
                end

                table.sort(recipeSummaries, function(a, b)
                    local aProfit = a.profit or -math.huge
                    local bProfit = b.profit or -math.huge
                    return aProfit > bProfit
                end)

                if usingStatic then
                    Print("Resultados com base nas receitas estáticas definidas no addon:")
                else
                    Print("Resultados com base nas receitas conhecidas na sua janela de ofício:")
                end
                for _, summary in ipairs(recipeSummaries) do
                    local priceText = summary.itemPrice and FormatCopper(summary.itemPrice) or "sem preço do item"
                    local profitText = summary.profit and FormatCopper(summary.profit) or "sem lucro calculado"
                    local missingText = summary.missing and " (faltam dados de reagentes)" or ""
                    Print(string.format("%s: reagentes %s, item %s, lucro %s%s", summary.name, FormatCopper(summary.reagentCost), priceText, profitText, missingText))
                end
            end
        end)
    end
end

local function PrintRecipeCosts(recipeName)
    local recipe = GetRecipeData(recipeName)
    if not recipe then
        Print("Receita não encontrada: " .. recipeName)
        return
    end

    Print("Receita: " .. recipe.itemName)
    Print("Reagentes:")
    local reagentPrices = {}
    local totalReagentCost = 0
    local pending = 0

    for reagentName, qty in pairs(recipe.reagents) do
        pending = pending + 1
        EnqueueAuctionQuery(reagentName, function(price)
            reagentPrices[reagentName] = {qty = qty, price = price}
            if price then
                totalReagentCost = totalReagentCost + price * qty
            end
            pending = pending - 1
            if pending == 0 then
                for name, info in pairs(reagentPrices) do
                    Print(string.format("  %s x%d = %s cada", name, info.qty, FormatCopper(info.price)))
                end
                Print("Custo total dos reagentes: " .. FormatCopper(totalReagentCost))

                EnqueueAuctionQuery(recipe.itemName, function(itemPrice)
                    Print("Preço AH do item craftado: " .. FormatCopper(itemPrice))
                    if itemPrice and totalReagentCost > 0 then
                        local profit = itemPrice - totalReagentCost
                        Print("Margem estimada: " .. FormatCopper(profit))
                    end
                end)
            end
        end)
    end
end

local function EnsureDatabase()
    if type(AHCrafterPriceDB) ~= "table" then
        AHCrafterPriceDB = {}
    end

    db = AHCrafterPriceDB
    if type(db.minimap) ~= "table" then
        db.minimap = {}
    end
    if db.minimap.angle == nil then
        db.minimap.angle = 220
    end
    if db.minimap.hide == nil then
        db.minimap.hide = false
    end

    if type(db.priceCache) ~= "table" then
        db.priceCache = {}
    end
    PrunePriceCache()
end

SetMainStatus = function(message)
    if mainStatusText then
        mainStatusText:SetText(message or "")
    end
end

AppendUILogLine = function(message)
    if not mainLogText then
        return
    end

    local timeText = date("%H:%M:%S")
    table.insert(uiLogLines, string.format("[%s] %s", timeText, tostring(message)))
    if #uiLogLines > 12 then
        table.remove(uiLogLines, 1)
    end

    mainLogText:SetText(table.concat(uiLogLines, "\n"))
end

local function ComputeAngle(y, x)
    if math.atan2 then
        return math.atan2(y, x)
    end

    if x == 0 then
        if y > 0 then
            return math.pi / 2
        end
        if y < 0 then
            return -math.pi / 2
        end
        return 0
    end

    local angle = math.atan(y / x)
    if x < 0 then
        angle = angle + math.pi
    end
    return angle
end

local function UpdateMinimapButtonPosition()
    if not minimapButton or not Minimap or not db or not db.minimap then
        return
    end

    local angle = tonumber(db.minimap.angle) or 220
    local radius = 80
    local radians = math.rad(angle)
    local x = math.cos(radians) * radius
    local y = math.sin(radians) * radius

    minimapButton:ClearAllPoints()
    minimapButton:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

local function CreateMainFrame()
    if mainFrame then
        return
    end

    mainFrame = CreateFrame("Frame", "AHCrafterPriceMainFrame", UIParent, "BasicFrameTemplateWithInset")
    mainFrame:SetSize(460, 320)
    mainFrame:SetPoint("CENTER")
    mainFrame:SetMovable(true)
    mainFrame:EnableMouse(true)
    mainFrame:RegisterForDrag("LeftButton")
    mainFrame:SetScript("OnDragStart", function(self)
        self:StartMoving()
    end)
    mainFrame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
    end)
    mainFrame:Hide()

    if mainFrame.TitleText then
        mainFrame.TitleText:SetText("AH Crafter Price")
    end

    local helpText = mainFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    helpText:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", 16, -36)
    helpText:SetText("Use o minimapa ou os botoes abaixo para escanear receitas.")

    local recipeLabel = mainFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    recipeLabel:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", 16, -62)
    recipeLabel:SetText("Receita")

    local recipeEdit = CreateFrame("EditBox", nil, mainFrame, "InputBoxTemplate")
    recipeEdit:SetSize(220, 20)
    recipeEdit:SetPoint("TOPLEFT", recipeLabel, "BOTTOMLEFT", 0, -6)
    recipeEdit:SetAutoFocus(false)

    local scanButton = CreateFrame("Button", nil, mainFrame, "UIPanelButtonTemplate")
    scanButton:SetSize(80, 22)
    scanButton:SetPoint("LEFT", recipeEdit, "RIGHT", 8, 0)
    scanButton:SetText("Scan")
    scanButton:SetScript("OnClick", function()
        local recipeName = strtrim(recipeEdit:GetText() or "")
        if recipeName == "" then
            Print("Digite o nome de uma receita.")
            return
        end
        if not IsAuctionHouseOpen() then
            Print("Abra a casa de leiloes antes de escanear.")
            return
        end
        PrintRecipeCosts(recipeName)
    end)

    local scanSelectedButton = CreateFrame("Button", nil, mainFrame, "UIPanelButtonTemplate")
    scanSelectedButton:SetSize(120, 22)
    scanSelectedButton:SetPoint("TOPLEFT", recipeEdit, "BOTTOMLEFT", 0, -8)
    scanSelectedButton:SetText("Scan Selecionada")
    scanSelectedButton:SetScript("OnClick", function()
        local recipeID, recipeNameHint = GetSelectedProfessionRecipeID()
        if not recipeID or recipeID == 0 then
            Print("Selecione uma receita na janela de profissao.")
            return
        end

        local recipeData = BuildProfessionRecipeData(recipeID, recipeNameHint)
        if not recipeData or not recipeData.itemName then
            Print("Nao foi possivel ler a receita selecionada.")
            return
        end

        recipes[recipeData.itemName] = recipeData
        recipeEdit:SetText(recipeData.itemName)

        if not IsAuctionHouseOpen() then
            Print("Abra a casa de leiloes antes de escanear.")
            return
        end

        PrintRecipeCosts(recipeData.itemName)
    end)

    local scanAllButton = CreateFrame("Button", nil, mainFrame, "UIPanelButtonTemplate")
    scanAllButton:SetSize(80, 22)
    scanAllButton:SetPoint("LEFT", scanSelectedButton, "RIGHT", 8, 0)
    scanAllButton:SetText("Scan All")
    scanAllButton:SetScript("OnClick", function()
        if not IsAuctionHouseOpen() then
            Print("Abra a casa de leiloes antes de escanear.")
            return
        end
        ScanAllRecipes()
    end)

    local togglePanelButton = CreateFrame("Button", nil, mainFrame, "UIPanelButtonTemplate")
    togglePanelButton:SetSize(140, 22)
    togglePanelButton:SetPoint("LEFT", scanAllButton, "RIGHT", 8, 0)
    togglePanelButton:SetText("Painel Profissao")
    togglePanelButton:SetScript("OnClick", function()
        CreateProfessionPriceFrame()
        if not professionPriceFrame then
            return
        end
        if professionPriceFrame:IsShown() then
            professionPriceFrame:Hide()
            Print("Painel de profissao ocultado.")
        else
            professionPriceFrame:Show()
            UpdateProfessionPriceDisplay()
        end
    end)

    local statusLabel = mainFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    statusLabel:SetPoint("TOPLEFT", scanSelectedButton, "BOTTOMLEFT", 0, -10)
    statusLabel:SetText("Status")

    mainStatusText = mainFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    mainStatusText:SetPoint("TOPLEFT", statusLabel, "BOTTOMLEFT", 0, -4)
    mainStatusText:SetPoint("TOPRIGHT", mainFrame, "TOPRIGHT", -16, -120)
    mainStatusText:SetJustifyH("LEFT")
    mainStatusText:SetNonSpaceWrap(true)
    mainStatusText:SetText("Aguardando acao...")

    local logLabel = mainFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    logLabel:SetPoint("TOPLEFT", mainStatusText, "BOTTOMLEFT", 0, -10)
    logLabel:SetText("Log recente")

    mainLogText = mainFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    mainLogText:SetPoint("TOPLEFT", logLabel, "BOTTOMLEFT", 0, -4)
    mainLogText:SetPoint("BOTTOMRIGHT", mainFrame, "BOTTOMRIGHT", -16, 16)
    mainLogText:SetJustifyH("LEFT")
    mainLogText:SetJustifyV("TOP")
    mainLogText:SetNonSpaceWrap(true)
    mainLogText:SetText("Sem logs ainda.")
end

local function ToggleMainFrame()
    if not mainFrame then
        CreateMainFrame()
    end

    if not mainFrame then
        return
    end

    if mainFrame:IsShown() then
        mainFrame:Hide()
    else
        mainFrame:Show()
    end
end

local function ToggleProfessionPanel()
    CreateProfessionPriceFrame()
    if not professionPriceFrame then
        return
    end

    if professionPriceFrame:IsShown() then
        professionPriceFrame:Hide()
        Print("Painel de profissao ocultado.")
    else
        professionPriceFrame:Show()
        UpdateProfessionPriceDisplay()
    end
end

local function CreateMinimapButton()
    if minimapButton or not Minimap then
        return
    end

    minimapButton = CreateFrame("Button", "AHCrafterPriceMinimapButton", Minimap)
    minimapButton:SetSize(32, 32)
    minimapButton:SetFrameStrata("MEDIUM")
    minimapButton:SetFrameLevel(8)
    minimapButton:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    minimapButton:RegisterForDrag("LeftButton")
    minimapButton:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    local icon = minimapButton:CreateTexture(nil, "ARTWORK")
    icon:SetTexture("Interface\\Icons\\INV_Misc_Coin_02")
    icon:SetSize(18, 18)
    icon:SetPoint("CENTER", 1, -1)

    local border = minimapButton:CreateTexture(nil, "OVERLAY")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    border:SetSize(53, 53)
    border:SetPoint("TOPLEFT")

    minimapButton:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:SetText("AH Crafter Price")
        GameTooltip:AddLine("Botao esquerdo: abrir interface", 1, 1, 1)
        GameTooltip:AddLine("Botao direito: painel de profissao", 1, 1, 1)
        GameTooltip:AddLine("Arraste para mover no minimapa", 1, 1, 1)
        GameTooltip:Show()
    end)
    minimapButton:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
    minimapButton:SetScript("OnClick", function(_, button)
        if button == "RightButton" then
            ToggleProfessionPanel()
            return
        end
        ToggleMainFrame()
    end)
    minimapButton:SetScript("OnDragStart", function(self)
        self.isDragging = true
    end)
    minimapButton:SetScript("OnDragStop", function(self)
        self.isDragging = false
    end)
    minimapButton:SetScript("OnUpdate", function(self)
        if not self.isDragging or not db or not db.minimap then
            return
        end

        local mx, my = Minimap:GetCenter()
        local cx, cy = GetCursorPosition()
        local scale = Minimap:GetEffectiveScale()
        cx = cx / scale
        cy = cy / scale

        local angle = math.deg(ComputeAngle(cy - my, cx - mx))
        db.minimap.angle = angle
        UpdateMinimapButtonPosition()
    end)

    UpdateMinimapButtonPosition()
    if db and db.minimap and db.minimap.hide then
        minimapButton:Hide()
    else
        minimapButton:Show()
    end
end

InitializeAddonUI = function()
    EnsureDatabase()
    CreateMainFrame()
    CreateMinimapButton()
end

SLASH_AHCRAFTERPRICE1 = "/craftprice"
SlashCmdList["AHCRAFTERPRICE"] = function(msg)
    if InitializeAddonUI then
        InitializeAddonUI()
    end

    local command, rest = msg:match("^(%S*)%s*(.-)$")
    command = string.lower(command or "")
    rest = rest or ""

    if command == "" or command == "list" or command == "help" then
        Print("Comandos: /craftprice ui | panel | scan <receita> | scanall | minimap show|hide | cache stats|clear")
        local knownRecipes = GetKnownRecipes()
        if knownRecipes then
            Print("Receitas conhecidas no seu oficio:")
            for name in pairs(knownRecipes) do
                Print("  " .. name)
            end
        end
        Print("Receitas estaticas:")
        for name in pairs(recipes) do
            Print("  " .. name)
        end
    elseif command == "ui" or command == "toggle" then
        ToggleMainFrame()
    elseif command == "panel" then
        ToggleProfessionPanel()
    elseif command == "minimap" then
        if not db then
            EnsureDatabase()
        end

        local option = string.lower(strtrim(rest))
        if option == "hide" then
            db.minimap.hide = true
            if minimapButton then
                minimapButton:Hide()
            end
            Print("Icone do minimapa ocultado.")
        elseif option == "show" or option == "" then
            db.minimap.hide = false
            if minimapButton then
                minimapButton:Show()
                UpdateMinimapButtonPosition()
            end
            Print("Icone do minimapa exibido.")
        else
            Print("Use /craftprice minimap show ou /craftprice minimap hide")
        end
    elseif command == "cache" then
        if not db then
            EnsureDatabase()
        end

        local option = string.lower(strtrim(rest))
        if option == "clear" then
            local removed = ClearPriceCache()
            Print(string.format("Cache de preco limpo: %d entradas removidas.", removed))
        elseif option == "" or option == "stats" then
            local total, fresh, withPrice = GetPriceCacheStats()
            Print(string.format("Cache de preco: total=%d, validas=%d, com preco=%d", total, fresh, withPrice))
            Print(string.format("TTL: com preco=%d min, sem preco=%d min", math.floor(PRICE_CACHE_HIT_TTL / 60), math.floor(PRICE_CACHE_MISS_TTL / 60)))
        else
            Print("Use /craftprice cache stats ou /craftprice cache clear")
        end
    elseif command == "scan" and rest ~= "" then
        if not ((AuctionFrame and AuctionFrame:IsShown()) or (AuctionHouseFrame and (AuctionHouseFrame:IsShown() or AuctionHouseFrame:IsVisible()))) then
            Print("Abra a casa de leiloes antes de usar /craftprice scan.")
            return
        end
        Print("Escaneando receita: " .. rest)
        PrintRecipeCosts(rest)
    elseif command == "scanall" then
        if not ((AuctionFrame and AuctionFrame:IsShown()) or (AuctionHouseFrame and (AuctionHouseFrame:IsShown() or AuctionHouseFrame:IsVisible()))) then
            Print("Abra a casa de leiloes antes de usar /craftprice scanall.")
            return
        end
        Print("Escaneando todas as receitas conhecidas. Isso pode demorar alguns segundos.")
        ScanAllRecipes()
    else
        Print("Comando invalido. Use /craftprice help")
    end
end
