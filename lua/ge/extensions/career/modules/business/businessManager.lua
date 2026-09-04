local M = {}

M.dependencies = {'career_career', 'freeroam_facilities', 'career_modules_payment', 'career_modules_playerAttributes', 'career_saveSystem', 'career_modules_bank', 'career_modules_loans'}

local purchasedBusinesses = {}
local purchasedBusinessesOwnershipReady = false
local businessToPurchase = nil
local businessCallbacks = {}
local businessObjects = {}
local purchaseCapitalInjectionAmount = nil

local function registerBusinessCallback(businessType, callbacks)
  businessCallbacks[businessType] = callbacks or {}
end

local function registerBusiness(businessType, businessObject)
  if not businessType or not businessObject then
    return false
  end
  businessObjects[businessType] = businessObject
  return true
end

local function getBusinessObject(businessType)
  if not businessType then
    return nil
  end
  return businessObjects[businessType]
end

local function hasFeature(businessType, featureName)
  local obj = businessObjects[businessType]
  if not obj or not obj.features then
    return false
  end
  return obj.features[featureName] == true
end

local function getAllBusinessObjects()
  return businessObjects
end

local function getPurchaseCapitalInjectionAmount(defaultAmount)
  if type(purchaseCapitalInjectionAmount) == "number" then
    return purchaseCapitalInjectionAmount
  end
  return defaultAmount or 0
end

local function loadPurchasedBusinesses()
  purchasedBusinessesOwnershipReady = false
  if not career_career.isActive() then return end
  local _, currentSavePath = career_saveSystem.getCurrentProfile()
  if not currentSavePath then return end
  
  local filePath = currentSavePath .. "/career/rls_career/businesses.json"
  local data = jsonReadFile(filePath) or {}
  purchasedBusinesses = data.businesses or {}
  purchasedBusinessesOwnershipReady = true

  if career_modules_business_businessPartInventory and career_modules_business_businessPartInventory.onPurchasedBusinessesOwnershipReady then
    career_modules_business_businessPartInventory.onPurchasedBusinessesOwnershipReady()
  end
end

local function savePurchasedBusinesses(currentSavePath)
  if not currentSavePath then return end
  
  local filePath = currentSavePath .. "/career/rls_career/businesses.json"
  local data = {
    businesses = purchasedBusinesses
  }
  jsonWriteFile(filePath, data, true)
end

local function isPurchasedBusiness(businessType, businessId)
  if not purchasedBusinesses[businessType] then return false end
  local businessesByType = purchasedBusinesses[businessType]
  local entry = businessesByType[businessId]
  if not (entry == true or type(entry) == "table") then
    local idStr = tostring(businessId)
    entry = businessesByType[idStr]
  end
  if not (entry == true or type(entry) == "table") then
    local idNum = tonumber(businessId)
    if idNum ~= nil then
      entry = businessesByType[idNum]
      if not (entry == true or type(entry) == "table") then
        entry = businessesByType[tostring(idNum)]
      end
    end
  end
  if not (entry == true or type(entry) == "table") then
    local targetNum = tonumber(businessId)
    local targetStr = tostring(businessId)
    for storedId, storedEntry in pairs(businessesByType) do
      if storedEntry == true or type(storedEntry) == "table" then
        local storedStr = tostring(storedId)
        if storedStr == targetStr then
          entry = storedEntry
          break
        end
        if targetNum ~= nil and tonumber(storedId) == targetNum then
          entry = storedEntry
          break
        end
      end
    end
  end
  if entry == true or (type(entry) == "table") then
    return true
  end
  return false
end

local function getBusinessInfo(businessType, businessId)
  if not purchasedBusinesses[businessType] then return nil end
  local entry = purchasedBusinesses[businessType][businessId]
  if type(entry) == "table" then
    return entry
  elseif entry == true then
    return { name = businessType .. " " .. businessId }
  end
  return nil
end

local function setBusinessName(businessType, businessId, name)
  if not businessType or not businessId then return false end
  if not isPurchasedBusiness(businessType, businessId) then return false end
  local newName = (type(name) == "string" and name:match("^%s*(.-)%s*$")) or ""
  if newName == "" then return false end
  if not purchasedBusinesses[businessType] then return false end
  local entry = purchasedBusinesses[businessType][businessId]
  if type(entry) == "table" then
    entry.name = newName
  else
    purchasedBusinesses[businessType][businessId] = {
      name = newName,
      mapId = getCurrentLevelIdentifier and getCurrentLevelIdentifier() or nil
    }
  end
  career_saveSystem.saveCurrent()
  return true
end

local function addPurchasedBusiness(businessType, businessId, skipCallback)
  if not purchasedBusinesses[businessType] then
    purchasedBusinesses[businessType] = {}
  end
  
  local business = freeroam_facilities.getFacility(businessType, businessId)
  local businessName = business and business.name or (businessType .. " " .. businessId)
  local mapId = getCurrentLevelIdentifier and getCurrentLevelIdentifier() or nil
  
  purchasedBusinesses[businessType][businessId] = {
    name = businessName,
    mapId = mapId
  }

  if gameplay_rawPois and gameplay_rawPois.clear then
    gameplay_rawPois.clear()
  end

  if career_modules_business_businessComputer then
    career_modules_business_businessComputer.setBusinessContext(businessType, businessId)
  end
  
  if career_modules_bank then
    career_modules_bank.createBusinessAccount(businessType, businessId, businessName)
  end
  
  if not skipCallback and businessCallbacks[businessType] and businessCallbacks[businessType].onPurchase then
    businessCallbacks[businessType].onPurchase(businessId)
  end
  
  career_saveSystem.saveCurrent()
end

local function showPurchaseBusinessPrompt(businessType, businessId)
  if not career_career.isActive() then return end
  local business = freeroam_facilities.getFacility(businessType, businessId)
  if not business then return end
  
  businessToPurchase = {
    type = businessType,
    id = businessId,
    facility = business
  }
  
  local price = business.price or 0
  if price == 0 then
    addPurchasedBusiness(businessType, businessId)
    if businessCallbacks[businessType] and businessCallbacks[businessType].onMenuOpen then
      businessCallbacks[businessType].onMenuOpen(businessId)
    end
    return
  end
  
  extensions.ui_router.navigate('purchase-business', {businessType = businessType})
end

local function requestBusinessData()
  if not businessToPurchase then return nil end
  local business = businessToPurchase.facility
  if business then
    local dataGlobalIndex = career_modules_globalEconomy and career_modules_globalEconomy.getGlobalIndex() or 1.0
    local businessData = {
      name = business.name,
      price = math.floor((business.price or 0) * dataGlobalIndex),
      description = business.description or "",
      downPayment = math.floor((business.downPayment or 0) * dataGlobalIndex),
      businessType = businessToPurchase.type,
      businessId = businessToPurchase.id
    }
    return businessData
  end
  return nil
end

local function canPayBusiness()
  if career_modules_cheats and career_modules_cheats.isCheatsMode() then
    return true
  end
  if not businessToPurchase then return false end
  local affordGlobalIndex = career_modules_globalEconomy and career_modules_globalEconomy.getGlobalIndex() or 1.0
  local cost = math.floor((businessToPurchase.facility.price or 0) * affordGlobalIndex)
  return career_modules_playerAttributes.getAttributeValue("money") >= cost
end

local function buyBusiness()
  if businessToPurchase then
    local business = businessToPurchase.facility
    local businessGlobalIndex = career_modules_globalEconomy and career_modules_globalEconomy.getGlobalIndex() or 1.0
    local price = { money = { amount = math.floor((business.price or 0) * businessGlobalIndex), canBeNegative = false } }
    local success = career_modules_payment.pay(price, { label = "Purchased " .. business.name })
    if success then
      local previousCapitalInjectionAmount = purchaseCapitalInjectionAmount
      purchaseCapitalInjectionAmount = math.floor((business.downPayment or 0) * businessGlobalIndex)
      addPurchasedBusiness(businessToPurchase.type, businessToPurchase.id)
      purchaseCapitalInjectionAmount = previousCapitalInjectionAmount
      if businessCallbacks[businessToPurchase.type] and businessCallbacks[businessToPurchase.type].onMenuOpen then
        businessCallbacks[businessToPurchase.type].onMenuOpen(businessToPurchase.id)
      end
    end
    businessToPurchase = nil
  end
end

local function cancelBusinessPurchase()
  guihooks.trigger('ChangeState', {state = 'play'})
  businessToPurchase = nil
end

local function canAffordDownPayment()
  if career_modules_cheats and career_modules_cheats.isCheatsMode() then
    return true
  end
  if not businessToPurchase then return false end
  local downPayGlobalIndex = career_modules_globalEconomy and career_modules_globalEconomy.getGlobalIndex() or 1.0
  local downPaymentAmount = math.floor((businessToPurchase.facility.downPayment or 0) * downPayGlobalIndex)
  if downPaymentAmount <= 0 then return false end
  return career_modules_playerAttributes.getAttributeValue("money") >= downPaymentAmount
end

local function financeBusiness()
  if not businessToPurchase then return false end
  local business = businessToPurchase.facility
  local financeGlobalIndex = career_modules_globalEconomy and career_modules_globalEconomy.getGlobalIndex() or 1.0
  local downPaymentAmount = math.floor((business.downPayment or 0) * financeGlobalIndex)
  local totalPrice = math.floor((business.price or 0) * financeGlobalIndex)
  
  if not canAffordDownPayment() then
    return false
  end
  
  local remainingAmount = totalPrice - downPaymentAmount
  
  local downPaymentPrice = { money = { amount = downPaymentAmount, canBeNegative = false } }
  local success = career_modules_payment.pay(downPaymentPrice, { label = "Down payment for " .. business.name })
  if not success then
    return false
  end
  
  addPurchasedBusiness(businessToPurchase.type, businessToPurchase.id, true)
  
  local businessAccount = nil
  if career_modules_bank then
    businessAccount = career_modules_bank.getBusinessAccount(businessToPurchase.type, businessToPurchase.id)
  end
  
  if remainingAmount > 0 and career_modules_loans and businessAccount then
    local businessAccountId = businessAccount.id
    career_modules_loans.takeLoan("moneyGrabBusiness", remainingAmount, 72, 0, true, businessAccountId)
  end
  
  if businessCallbacks[businessToPurchase.type] and businessCallbacks[businessToPurchase.type].onPurchase then
    local previousCapitalInjectionAmount = purchaseCapitalInjectionAmount
    purchaseCapitalInjectionAmount = downPaymentAmount
    businessCallbacks[businessToPurchase.type].onPurchase(businessToPurchase.id)
    purchaseCapitalInjectionAmount = previousCapitalInjectionAmount
  end
  
  if businessCallbacks[businessToPurchase.type] and businessCallbacks[businessToPurchase.type].onMenuOpen then
    businessCallbacks[businessToPurchase.type].onMenuOpen(businessToPurchase.id)
  end
  
  businessToPurchase = nil
  return true
end

local function openBusinessMenu(businessType, businessId)
  if businessCallbacks[businessType] and businessCallbacks[businessType].onMenuOpen then
    businessCallbacks[businessType].onMenuOpen(businessId)
  else
    log("W", "BusinessManager", "No menu callback registered for business type: " .. tostring(businessType))
  end
end

local function getPurchasedBusinesses(businessType)
  return purchasedBusinesses[businessType] or {}
end

local function getBusinessGarageId(businessType, businessId)
  local business = freeroam_facilities.getFacility(businessType, businessId)
  if business then
    return business.businessGarageId
  end
  return nil
end

local function getBusinessAccountId(businessType, businessId)
  return "business_" .. tostring(businessType) .. "_" .. tostring(businessId)
end

local function getIndexedBusinessPrice(business)
  local globalIndex = career_modules_globalEconomy and career_modules_globalEconomy.getGlobalIndex() or 1.0
  return math.floor((business and business.price or 0) * globalIndex)
end

local function getBusinessLoansForAccount(accountId)
  local loans = {}
  local total = 0
  if career_modules_loans and career_modules_loans.getActiveLoans then
    for _, loan in ipairs(career_modules_loans.getActiveLoans() or {}) do
      if loan.businessAccountId == accountId then
        local principal = tonumber(loan.principalOutstanding) or 0
        total = total + principal
        table.insert(loans, loan)
      end
    end
  end
  return loans, math.floor(total + 0.5)
end

local function getSaleSettlementQuote(businessType, businessId)
  if not businessType or not businessId then
    return { success = false, error = "missing_business" }
  end
  if not isPurchasedBusiness(businessType, businessId) then
    return { success = false, error = "not_owned" }
  end

  local business = freeroam_facilities.getFacility(businessType, businessId)
  if not business then
    return { success = false, error = "business_not_found" }
  end

  local businessObj = businessObjects[businessType]
  local indexedPrice = getIndexedBusinessPrice(business)
  local baseResaleValue = math.floor(indexedPrice * 0.70)
  local assetLiquidationValue = 0
  if businessObj and businessObj.getLiquidationValue then
    assetLiquidationValue = math.floor((businessObj.getLiquidationValue(businessId) or 0) + 0.5)
  end
  local upgradeLiquidationValue = 0
  if career_modules_business_businessSkillTree and career_modules_business_businessSkillTree.getLiquidationValue then
    upgradeLiquidationValue = math.floor((career_modules_business_businessSkillTree.getLiquidationValue(businessType, businessId) or 0) + 0.5)
  end

  local accountId = getBusinessAccountId(businessType, businessId)
  local account = career_modules_bank and career_modules_bank.getBusinessAccount(businessType, businessId) or nil
  local accountBalance = account
    and ((career_modules_bank.getBusinessAccountLiquidationBalance and career_modules_bank.getBusinessAccountLiquidationBalance(accountId))
      or career_modules_bank.getAccountBalance(accountId) or 0)
    or 0
  accountBalance = math.floor(accountBalance + 0.5)
  local positiveAccountBalance = math.max(0, accountBalance)
  local negativeAccountDebt = math.max(0, -accountBalance)
  local grossProceeds = math.max(0, baseResaleValue + assetLiquidationValue + upgradeLiquidationValue + positiveAccountBalance)

  local businessLoans, businessLoanPrincipal = getBusinessLoansForAccount(accountId)
  local availableAfterAccountDebt = math.max(0, grossProceeds - negativeAccountDebt)
  local convertedAccountDebt = math.max(0, negativeAccountDebt - grossProceeds)
  local loanPayoffAmount = math.min(availableAfterAccountDebt, businessLoanPrincipal)
  local convertedLoanPrincipal = math.max(0, businessLoanPrincipal - loanPayoffAmount)
  local netPayout = math.max(0, availableAfterAccountDebt - businessLoanPrincipal)

  return {
    success = true,
    businessType = businessType,
    businessId = businessId,
    businessName = business.name or (businessType .. " " .. tostring(businessId)),
    accountId = accountId,
    indexedPrice = indexedPrice,
    baseResaleValue = baseResaleValue,
    assetLiquidationValue = assetLiquidationValue,
    upgradeLiquidationValue = upgradeLiquidationValue,
    accountBalance = accountBalance,
    positiveAccountBalance = positiveAccountBalance,
    negativeAccountDebt = negativeAccountDebt,
    grossProceeds = grossProceeds,
    businessLoanPrincipal = businessLoanPrincipal,
    loanPayoffAmount = loanPayoffAmount,
    convertedLoanPrincipal = convertedLoanPrincipal,
    convertedAccountDebt = convertedAccountDebt,
    convertedDebt = convertedLoanPrincipal + convertedAccountDebt,
    netPayout = netPayout,
    loans = businessLoans,
  }
end

local function removePurchasedBusiness(businessType, businessId)
  if not purchasedBusinesses[businessType] then return false end
  purchasedBusinesses[businessType][businessId] = nil
  purchasedBusinesses[businessType][tostring(businessId)] = nil
  local idNum = tonumber(businessId)
  if idNum ~= nil then
    purchasedBusinesses[businessType][idNum] = nil
  end
  if not next(purchasedBusinesses[businessType]) then
    purchasedBusinesses[businessType] = nil
  end
  return true
end

local function sellBusiness(businessType, businessId)
  local quote = getSaleSettlementQuote(businessType, businessId)
  if not quote.success then return quote end

  local proceedsAfterAccountDebt = math.max(0, quote.grossProceeds - quote.negativeAccountDebt)
  local accountDebtShortfall = math.max(0, quote.negativeAccountDebt - quote.grossProceeds)
  local loanSettlement = nil
  if career_modules_loans and career_modules_loans.settleBusinessLoans then
    loanSettlement = career_modules_loans.settleBusinessLoans(quote.accountId, proceedsAfterAccountDebt)
  end
  local remainingAvailable = loanSettlement and (loanSettlement.remainingAvailable or 0) or proceedsAfterAccountDebt

  if accountDebtShortfall > 0 and career_modules_loans and career_modules_loans.createPersonalDebtLoan then
    career_modules_loans.createPersonalDebtLoan("moneyGrabBusiness", accountDebtShortfall, 72, 0)
  end

  if remainingAvailable > 0 and career_modules_payment and career_modules_payment.reward then
    career_modules_payment.reward({
      money = { amount = math.floor(remainingAvailable + 0.5) }
    }, {
      label = "Sold " .. (quote.businessName or "business")
    }, true)
  end

  local businessObj = businessObjects[businessType]
  if businessObj and businessObj.resetBusinessForSale then
    businessObj.resetBusinessForSale(businessId)
  end

  if career_modules_business_businessSkillTree and career_modules_business_businessSkillTree.clearBusinessProgress then
    career_modules_business_businessSkillTree.clearBusinessProgress(businessId)
  end

  if career_modules_bank and career_modules_bank.liquidateBusinessAccount then
    career_modules_bank.liquidateBusinessAccount(quote.accountId)
  end

  removePurchasedBusiness(businessType, businessId)

  if gameplay_rawPois and gameplay_rawPois.clear then
    gameplay_rawPois.clear()
  end
  if career_modules_business_businessComputer and career_modules_business_businessComputer.clearBusinessContext then
    career_modules_business_businessComputer.clearBusinessContext(businessId)
  end

  career_saveSystem.saveCurrent()

  local convertedDebt = (loanSettlement and loanSettlement.convertedPrincipal or quote.convertedLoanPrincipal or 0) + accountDebtShortfall
  local paidLoans = loanSettlement and loanSettlement.paidOffPrincipal or quote.loanPayoffAmount or 0
  local payout = math.floor(remainingAvailable + 0.5)

  if guihooks and guihooks.trigger then
    guihooks.trigger("toastrMsg", {
      type = "success",
      title = "Business Sold",
      msg = string.format("Sold %s. Paid $%d toward business debt, paid you $%d, converted $%d to personal debt.",
        tostring(quote.businessName or "business"), math.floor(paidLoans + 0.5), payout, math.floor(convertedDebt + 0.5))
    })
    guihooks.trigger('business:sold', {
      businessType = businessType,
      businessId = businessId,
      payout = payout,
      convertedDebt = math.floor(convertedDebt + 0.5),
      loanSettlement = loanSettlement,
    })
    guihooks.trigger('ChangeState', {state = 'play'})
  end

  quote.loanSettlement = loanSettlement
  quote.netPayout = payout
  quote.convertedDebt = math.floor(convertedDebt + 0.5)
  return quote
end

local function onCareerActivated()
  loadPurchasedBusinesses()
end

local function onSaveCurrentProfile(currentSavePath)
  savePurchasedBusinesses(currentSavePath)
end

local function getAllPurchasedBusinesses()
  return purchasedBusinesses
end

local function isBusinessOwnershipReady()
  if not career_career.isActive() then
    return false
  end
  return purchasedBusinessesOwnershipReady == true
end

M.onCareerActivated = onCareerActivated
M.registerBusinessCallback = registerBusinessCallback
M.registerBusiness = registerBusiness
M.getBusinessObject = getBusinessObject
M.hasFeature = hasFeature
M.getAllBusinessObjects = getAllBusinessObjects
M.getPurchaseCapitalInjectionAmount = getPurchaseCapitalInjectionAmount
M.isPurchasedBusiness = isPurchasedBusiness
M.getBusinessInfo = getBusinessInfo
M.setBusinessName = setBusinessName
M.showPurchaseBusinessPrompt = showPurchaseBusinessPrompt
M.requestBusinessData = requestBusinessData
M.canPayBusiness = canPayBusiness
M.canAffordDownPayment = canAffordDownPayment
M.buyBusiness = buyBusiness
M.financeBusiness = financeBusiness
M.cancelBusinessPurchase = cancelBusinessPurchase
M.openBusinessMenu = openBusinessMenu
M.getPurchasedBusinesses = getPurchasedBusinesses
M.getAllPurchasedBusinesses = getAllPurchasedBusinesses
M.isBusinessOwnershipReady = isBusinessOwnershipReady
M.getBusinessGarageId = getBusinessGarageId
M.requestBusinessSaleData = getSaleSettlementQuote
M.sellBusiness = sellBusiness
M.onSaveCurrentProfile = onSaveCurrentProfile

return M
