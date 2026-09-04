local M = {}

M.dependencies = {
  'career_career',
  'career_saveSystem',
}

local function finalizePurchase(businessId, vehicleId, callback)
  if not businessId or not vehicleId then
    if callback then callback(false) end
    return
  end

  if career_modules_business_businessPartCustomization then
    career_modules_business_businessPartCustomization.clearPreviewVehicle(businessId)
    local ok = career_modules_business_businessPartCustomization.initializePreviewVehicle(businessId, vehicleId)
    if not ok then
      log("W", "businessVehicleModificationUtil",
        "initializePreviewVehicle failed after purchase businessId=" .. tostring(businessId) ..
          " vehicleId=" .. tostring(vehicleId) .. " — save still runs")
    end
    if career_modules_business_businessPartCustomization.requestVehiclePowerWeightAfterPurchase then
      career_modules_business_businessPartCustomization.requestVehiclePowerWeightAfterPurchase(businessId, vehicleId)
    end
  end

  if career_modules_business_businessVehicleTuning then
    career_modules_business_businessVehicleTuning.clearTuningDataCache()
  end

  if career_saveSystem and career_saveSystem.saveCurrent then
    career_saveSystem.saveCurrent()
  end

  if callback then callback(true) end
end

M.finalizePurchase = finalizePurchase

return M
