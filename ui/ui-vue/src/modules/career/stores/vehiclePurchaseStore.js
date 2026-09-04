import { ref, computed } from "vue"
import { defineStore } from "pinia"
import { useBridge, lua } from "@/bridge"

export const useVehiclePurchaseStore = defineStore("vehiclePurchase", () => {
  const { events } = useBridge()

  const purchaseType = ref("")
  const vehicleInfo = ref({})
  const playerMoney = ref(0)
  const racingTeamBusinessMoney = ref(0)
  const alreadyDidTestDrive = ref(false)
  const inventoryHasFreeSlot = ref(false)
  const garageAvailability = ref("ok")
  const tradeInVehicleInfo = ref({})
  const tradeInEnabled = ref(false)
  const forceTradeIn = ref(false)
  const locationSelectionEnabled = ref(false)
  const forceNoDelivery = ref(false)
  const makeDelivery = ref(false)
  const garageDeliveryAllowed = ref(false)
  const deliveryGarages = ref([])
  const selectedGarageId = ref("")
  const deliveryQuote = ref(null)
  const freightAvailable = ref(true)
  const freightUnavailableReason = ref("")
  const buyCustomLicensePlate = ref(false)
  const customLicensePlateText = ref("")
  const dealershipId = ref("")
  const prices = ref({})
  const insuranceOptions = ref({})
  /** Authoritative for this purchase session (set from Lua); avoids sessionStorage/global rtBiz races. */
  const racingTeamFleetPurchase = ref(false)

  function isRacingTeamVehicleShop () {
    if (racingTeamFleetPurchase.value) return true
    try {
      return !!sessionStorage.getItem("rtVehicleShop")
    } catch (e) {
      return false
    }
  }

  const racingTeamVehicleShop = computed(() => {
    if (racingTeamFleetPurchase.value) return true
    try {
      return !!sessionStorage.getItem("rtVehicleShop")
    } catch (e) {
      return false
    }
  })

  const spendableMoney = computed(() => {
    if (isRacingTeamVehicleShop()) {
      return Number(racingTeamBusinessMoney.value) || 0
    }
    return Number(playerMoney.value) || 0
  })

  const finalPackagePrice = computed(() => {
    let price = prices.value.finalPrice
    if (isRacingTeamVehicleShop()) {
      return price
    }

    if (buyCustomLicensePlate.value) {
      price += prices.value.customLicensePlate
    }

    if (insuranceOptions.value.insuranceId > 0) {
      price += insuranceOptions.value.priceMoney
    }
    if (makeDelivery.value && deliveryQuote.value && !deliveryQuote.value.disabled) {
      price += Number(deliveryQuote.value.finalPrice) || 0
    }

    return price
  })

  const handlePurchaseData = data => {
    vehicleInfo.value = data.vehicleInfo
    playerMoney.value = data.playerMoney
    racingTeamFleetPurchase.value = data.racingTeamFleetPurchase === true
    racingTeamBusinessMoney.value = data.racingTeamBusinessMoney != null ? Number(data.racingTeamBusinessMoney) || 0 : 0
    inventoryHasFreeSlot.value = data.inventoryHasFreeSlot
    garageAvailability.value = data.garageAvailability || "ok"
    purchaseType.value = data.purchaseType
    tradeInEnabled.value = data.tradeInEnabled
    locationSelectionEnabled.value = data.locationSelectionEnabled
    forceNoDelivery.value = data.forceNoDelivery
    prices.value = data.prices
    garageDeliveryAllowed.value = data.garageDeliveryAllowed === true
    deliveryGarages.value = Array.isArray(data.deliveryGarages) ? data.deliveryGarages : []
    makeDelivery.value =
      garageDeliveryAllowed.value &&
      deliveryGarages.value.length > 0 &&
      !forceNoDelivery.value
    selectedGarageId.value = makeDelivery.value
      ? String(deliveryGarages.value[0].id)
      : ""
    deliveryQuote.value = null
    freightAvailable.value = data.freightAvailable !== false
    freightUnavailableReason.value = data.freightUnavailableReason || ""
    buyCustomLicensePlate.value = false
    customLicensePlateText.value = ""
    dealershipId.value = data.dealershipId

    forceTradeIn.value = data.forceTradeIn
    insuranceOptions.value = data.insuranceOptions

    if (data.tradeInVehicleInfo !== undefined) {
      tradeInVehicleInfo.value = data.tradeInVehicleInfo
    } else {
      tradeInVehicleInfo.value = {}
    }

    if (makeDelivery.value) {
      requestDeliveryQuote(selectedGarageId.value)
    }
  }

  function requestPurchaseData() {
    lua.career_modules_vehicleShopping.sendPurchaseDataToUi()
  }

  function buyVehicle(makeDelivery) {
    let options = {
      makeDelivery: makeDelivery,
      insuranceId: insuranceOptions.value.insuranceId
    }
    if (makeDelivery) options.targetGarageId = selectedGarageId.value
    if (buyCustomLicensePlate.value) {
      options.licensePlateText = customLicensePlateText.value
    }
    options.dealershipId = dealershipId.value
    if (isRacingTeamVehicleShop()) {
      options.insuranceId = -1
      delete options.licensePlateText
    }
    if (vehicleInfo.value.source === "carMeet") {
      options.insuranceId = -1
    }
    lua.career_modules_vehicleShopping.buyFromPurchaseMenu(purchaseType.value, options)
  }

  async function requestDeliveryQuote(garageId) {
    const requestedGarageId = garageId != null ? String(garageId) : ""
    selectedGarageId.value = requestedGarageId
    deliveryQuote.value = null
    if (!requestedGarageId) return null
    const quote = await lua.career_modules_vehicleShopping.getDeliveryQuote(requestedGarageId)
    if (selectedGarageId.value === requestedGarageId) {
      deliveryQuote.value = quote
    }
    return quote
  }

  function inventoryIsEmpty() {
    return lua.career_modules_inventory.isEmpty()
  }

  function chooseTradeInVehicle() {
    lua.career_modules_vehicleShopping.openInventoryMenuForTradeIn()
  }

  function removeTradeInVehicle() {
    lua.career_modules_vehicleShopping.removeTradeInVehicle()
  }

  function cancel() {
    lua.career_modules_vehicleShopping.cancelPurchase(purchaseType.value)
  }

  function startTestDrive() {
    lua.career_modules_inspectVehicle.startTestDrive()
  }

  function dispose() {
    racingTeamFleetPurchase.value = false
    listen(false)
  }

  // Lua events
  const listen = state => {
    const method = state ? "on" : "off"
    events[method]("vehiclePurchaseData", handlePurchaseData)
  }
  listen(true)

  return {
    buyVehicle,
    cancel,
    chooseTradeInVehicle,
    purchaseType,
    startTestDrive,
    dispose,
    forceNoDelivery,
    forceTradeIn,
    inventoryIsEmpty,
    inventoryHasFreeSlot,
    garageAvailability,
    locationSelectionEnabled,
    makeDelivery,
    garageDeliveryAllowed,
    deliveryGarages,
    selectedGarageId,
    deliveryQuote,
    freightAvailable,
    freightUnavailableReason,
    requestDeliveryQuote,
    playerMoney,
    racingTeamBusinessMoney,
    spendableMoney,
    prices,
    finalPackagePrice,
    removeTradeInVehicle,
    requestPurchaseData,
    tradeInEnabled,
    tradeInVehicleInfo,
    vehicleInfo,
    buyCustomLicensePlate,
    customLicensePlateText,
    alreadyDidTestDrive,
    insuranceOptions,
    racingTeamVehicleShop,
    racingTeamFleetPurchase,
  }
})
