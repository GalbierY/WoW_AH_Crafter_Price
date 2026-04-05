local addonName = "AHCrafterPrice"
local frame = CreateFrame("Frame")
local scanQueue = {}
local isScanning = false

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
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[" .. addonName .. "]|r " .. msg)
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

local function CreateRetailBrowseQuery(search)
    if type(C_AuctionHouse.CreateBrowseQuery) == "function" then
        local query = C_AuctionHouse.CreateBrowseQuery()
        if query then
            if query.SetName then
                query:SetName(search)
            elseif query.SetSearchString then
                query:SetSearchString(search)
            elseif query.SetText then
                query:SetText(search)
            end
            if query.SetPage then
                query:SetPage(0)
            end
            return query
        end
    end

    return {name = search, page = 0}
end

local function RetailSendBrowseQuery(search)
    local query = CreateRetailBrowseQuery(search)
    if type(C_AuctionHouse.SendBrowseQuery) == "function" then
        C_AuctionHouse.SendBrowseQuery(query)
        return true
    end
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
        if type(C_AuctionHouse.GetNumBrowseResults) ~= "function" or type(C_AuctionHouse.GetBrowseResultInfo) ~= "function" then
            return nil
        end

        local numAuctions = C_AuctionHouse.GetNumBrowseResults()
        local lowest = nil

        for i = 1, numAuctions do
            local itemID, itemName, count, quality, canUse, level, minBid, minIncrement, buyoutPrice = C_AuctionHouse.GetBrowseResultInfo(i)
            if itemName and buyoutPrice and buyoutPrice > 0 then
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
    query.callback(price)
    table.remove(scanQueue, 1)
    isScanning = false
    C_Timer.After(0.2, StartScan)
end

frame:SetScript("OnEvent", function(self, event, ...)
    if event == "AUCTION_ITEM_LIST_UPDATE" or event == "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED" then
        if isScanning and #scanQueue > 0 then
            ProcessNextScan()
        end
    elseif event == "AUCTION_HOUSE_CLOSED" then
        scanQueue = {}
        isScanning = false
    end
end)

frame:RegisterEvent("AUCTION_ITEM_LIST_UPDATE")
frame:RegisterEvent("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
frame:RegisterEvent("AUCTION_HOUSE_CLOSED")

local function EnqueueAuctionQuery(search, callback)
    table.insert(scanQueue, {search = search, callback = callback})
    StartScan()
end

local function GetKnownRecipes()
    if type(C_TradeSkillUI) ~= "table" or type(C_TradeSkillUI.GetAllRecipeIDs) ~= "function" then
        return nil
    end

    local recipeIDs = C_TradeSkillUI.GetAllRecipeIDs()
    if not recipeIDs or #recipeIDs == 0 then
        return nil
    end

    local recipesMap = {}
    for _, recipeID in ipairs(recipeIDs) do
        local recipeInfo = C_TradeSkillUI.GetRecipeInfo(recipeID)
        if recipeInfo and recipeInfo.name then
            local itemName = recipeInfo.name
            local reagents = {}
            local reagentCount = C_TradeSkillUI.GetRecipeNumReagents(recipeID)
            for reagentIndex = 1, reagentCount do
                local reagentName, _, qty, _, _, _, _, _, reagentLink = C_TradeSkillUI.GetRecipeReagentInfo(recipeID, reagentIndex)
                if not reagentName and reagentLink then
                    reagentName = GetItemInfo(reagentLink)
                end
                if reagentName and qty and qty > 0 then
                    reagents[reagentName] = qty
                end
            end
            if next(reagents) then
                recipesMap[itemName] = {itemName = itemName, reagents = reagents}
            end
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

SLASH_AHCRAFTERPRICE1 = "/craftprice"
SlashCmdList["AHCRAFTERPRICE"] = function(msg)
    local command, rest = msg:match("^(%S*)%s*(.-)$")
    if command == "" or command == "list" then
        Print("Use /craftprice scan <nome da receita> ou /craftprice scanall")
        local knownRecipes = GetKnownRecipes()
        if knownRecipes then
            Print("Receitas conhecidas no seu ofício:")
            for name in pairs(knownRecipes) do
                Print("  " .. name)
            end
        end
        Print("Receitas estáticas:")
        for name in pairs(recipes) do
            Print("  " .. name)
        end
    elseif command == "scan" and rest ~= "" then
        if not ((AuctionFrame and AuctionFrame:IsShown()) or (AuctionHouseFrame and AuctionHouseFrame:IsShown())) then
            Print("Abra a casa de leilões antes de usar /craftprice scan.")
            return
        end
        Print("Escaneando receita: " .. rest)
        PrintRecipeCosts(rest)
    elseif command == "scanall" then
        if not ((AuctionFrame and AuctionFrame:IsShown()) or (AuctionHouseFrame and AuctionHouseFrame:IsShown())) then
            Print("Abra a casa de leilões antes de usar /craftprice scanall.")
            return
        end
        Print("Escaneando todas as receitas conhecidas. Isso pode demorar alguns segundos.")
        ScanAllRecipes()
    else
        Print("Comando inválido. Use /craftprice scan <nome da receita> ou /craftprice scanall")
    end
end
