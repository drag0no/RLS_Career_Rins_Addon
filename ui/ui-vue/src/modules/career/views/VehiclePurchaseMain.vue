<template>
  <!-- TODO - remove inline styling? -->
  <LayoutSingle class="purchase-layout">
    <BngCard v-if="vehiclePurchaseStore.vehicleInfo.niceName" bng-ui-scope="vehiclePurchase" class="purchase-screen" v-bng-blur="1">
      <div class="header-row">
        <BngCardHeading type="ribbon">
          Purchase Information
          <div class="header-seller-info">
            Purchasing from: {{ vehiclePurchaseStore.vehicleInfo.sellerName }}
          </div>
        </BngCardHeading>
        <BngButton class="close-button" @click="cancel" :accent="ACCENTS.attention" bng-no-nav="true" tabindex="-1">
          <BngBinding ui-event="menu" controller  />
          <BngIcon
            type="xmarkBold"
              :color="'var(--bng-cool-gray-100)'"
            />

        </BngButton>
      </div>
      <div class="purchase-list">
        <!--
        <div class="purchase-row purchase-header">
          <div class="label"></div>
          <div class="price">Price</div>
        </div>-->
        <div class="purchase-row">
          <div class="label">
            <div>{{ vehiclePurchaseStore.vehicleInfo.year }} {{ vehiclePurchaseStore.vehicleInfo.niceName }}</div>
            <div class="sub-info">({{ formatMileage(vehiclePurchaseStore.vehicleInfo.Mileage) }})</div>
          </div>
          <div class="price">
            <div class="current-price-line">
              <span v-if="vehiclePurchaseStore.vehicleInfo.originalSellValue" class="old-price">
                <BngUnit :money="vehiclePurchaseStore.vehicleInfo.originalSellValue" />
              </span>
              <BngUnit class="money" :money="vehiclePurchaseStore.vehicleInfo.valueAdjusted || vehiclePurchaseStore.vehicleInfo.Value" />
            </div>
            <div class="sub-info" v-if="!vehiclePurchaseStore.vehicleInfo.hideMarketValue">
              <div>
                Est. Market:
                <BngUnit class="money" :money="vehiclePurchaseStore.vehicleInfo.marketValueAdjusted || vehiclePurchaseStore.vehicleInfo.marketValue" />
              </div>
            </div>
          </div>

        </div>
        <div class="purchase-divider"></div>
        <div v-if="vehiclePurchaseStore.insuranceOptions.insuranceId > 0" class="purchase-row thin light-blue">
          <div class="label category ">{{ vehiclePurchaseStore.insuranceOptions.spendingReason }}</div>
          <div class="price category"><BngUnit class="money" :money="vehiclePurchaseStore.insuranceOptions.priceMoney" /></div>
        </div>
        <div class="purchase-row thin light-blue">
          <div class="label">Dealership Fees</div>
          <div class="price"><BngUnit class="money" :money="vehiclePurchaseStore.vehicleInfo.fees" /></div>
        </div>
        <div class="purchase-divider" v-if="vehiclePurchaseStore.tradeInVehicleInfo?.niceName"></div>
        <div v-if="vehiclePurchaseStore.tradeInVehicleInfo.niceName" class="purchase-row thin green">
          <div class="label">Trade-in: {{ vehiclePurchaseStore.tradeInVehicleInfo.niceName }}</div>
          <div class="price"><BngUnit class="money" :money="-vehiclePurchaseStore.tradeInVehicleInfo.Value" /></div>
        </div>
        <div class="purchase-divider"></div>

        <div class="purchase-row">
          <div class="label">Subtotal</div>
          <div class="price">
            <BngUnit class="money" :money="vehiclePurchaseStore.finalPackagePrice
              - vehiclePurchaseStore.prices.taxes
              - (vehiclePurchaseStore.buyCustomLicensePlate ? vehiclePurchaseStore.prices.customLicensePlate : 0)
              - (vehiclePurchaseStore.makeDelivery && vehiclePurchaseStore.deliveryQuote && !vehiclePurchaseStore.deliveryQuote.disabled ? vehiclePurchaseStore.deliveryQuote.finalPrice : 0)" />
          </div>
        </div>

        <div class="purchase-row thin yellow ">
          <div class="label ">Sales Tax (7%)</div>
          <div class="price "><BngUnit class="money" :money="vehiclePurchaseStore.prices.taxes" /></div>
        </div>

        <div v-if="vehiclePurchaseStore.buyCustomLicensePlate" class="purchase-row thin">
          <div class="label">Custom License Plate</div>
          <div class="price"><BngUnit class="money" :money="vehiclePurchaseStore.prices.customLicensePlate" /></div>
        </div>
        <div v-if="vehiclePurchaseStore.makeDelivery && vehiclePurchaseStore.deliveryQuote && !vehiclePurchaseStore.deliveryQuote.disabled" class="purchase-row thin light-blue">
          <div class="label">
            Garage delivery
            <div class="sub-info">
              {{ formatDistance(vehiclePurchaseStore.deliveryQuote.roadDistance) }} ·
              ETA {{ formatEta(vehiclePurchaseStore.deliveryQuote.etaSeconds) }}
              <span v-if="vehiclePurchaseStore.deliveryQuote.discount > 0">
                · {{ Math.round(vehiclePurchaseStore.deliveryQuote.discount * 100) }}% loyalty discount
              </span>
            </div>
          </div>
          <div class="price">
            <BngUnit
              v-if="vehiclePurchaseStore.deliveryQuote.discount > 0"
              class="old-price"
              :money="vehiclePurchaseStore.deliveryQuote.fullPrice"
            />
            <BngUnit class="money" :money="vehiclePurchaseStore.deliveryQuote.finalPrice" />
          </div>
        </div>

        <div class="purchase-divider"></div>
        <div class="purchase-row ">
          <div class="label highlight-category">Total</div>
          <div class="price highlight-category"><BngUnit class="money" :money="vehiclePurchaseStore.finalPackagePrice" /></div>
        </div>

        <div v-if="!vehiclePurchaseStore.racingTeamVehicleShop" class="purchase-row thin">
          <div class="label">Your cash</div>
          <div class="price"><BngUnit class="money" :money="vehiclePurchaseStore.playerMoney" /></div>
        </div>
        <div v-if="vehiclePurchaseStore.racingTeamVehicleShop" class="purchase-row thin">
          <div class="label">Team account</div>
          <div class="price"><BngUnit class="money" :money="vehiclePurchaseStore.racingTeamBusinessMoney" /></div>
        </div>

        <div v-if="vehiclePurchaseStore.finalPackagePrice > vehiclePurchaseStore.spendableMoney" class="purchase-row money-warning red">
          <div class="label"><BngIcon type="danger" /> {{ vehiclePurchaseStore.racingTeamVehicleShop ? "Additional team funds required" : "Additional funds required" }}</div>
          <div class="price">
            <BngUnit class="money" :money="(vehiclePurchaseStore.finalPackagePrice - vehiclePurchaseStore.spendableMoney)" />
          </div>
        </div>



        <div v-if="!isCarMeetPurchase" class="purchase-customization-group">
          <h4>Purchase Options</h4>
          <div v-if="vehiclePurchaseStore.garageDeliveryAllowed && vehiclePurchaseStore.deliveryGarages.length" class="purchase-option delivery-option">
            <BngSwitch label-before :disabled="vehiclePurchaseStore.forceNoDelivery" v-model="vehiclePurchaseStore.makeDelivery">
              Deliver this vehicle to an owned garage?
            </BngSwitch>
            <BngDropdown
              v-if="vehiclePurchaseStore.makeDelivery"
              class="garage-select"
              v-model="vehiclePurchaseStore.selectedGarageId"
              :items="deliveryGarageOptions"
              @update:model-value="selectDeliveryGarage"
            />
            <div v-if="vehiclePurchaseStore.deliveryQuote?.disabled" class="delivery-warning">
              {{ vehiclePurchaseStore.deliveryQuote.reason }}
            </div>
            <div v-else-if="!vehiclePurchaseStore.makeDelivery" class="delivery-note">
              Leave delivery off to collect this vehicle at Freight Pickup. It will be listed in Vehicle Inventory under Freight Pickup.
            </div>
          </div>
          <div v-else-if="vehiclePurchaseStore.garageDeliveryAllowed" class="delivery-warning">
            No owned garage has free capacity for delivery.
          </div>
          <div v-else-if="vehiclePurchaseStore.vehicleInfo.salesChannel === 'factory' || vehiclePurchaseStore.vehicleInfo.salesChannel === 'remanufactured'" class="delivery-note">
            Freight pickup is required until this dealer reaches reputation level 2.
          </div>
          <div v-if="!vehiclePurchaseStore.freightAvailable && !vehiclePurchaseStore.makeDelivery" class="delivery-warning">
            {{ vehiclePurchaseStore.freightUnavailableReason }}
          </div>
          <!--
            <div v-if="vehiclePurchaseStore.locationSelectionEnabled" class="purchase-option">
              <BngSwitch label-before :disabled="vehiclePurchaseStore.forceNoDelivery" v-model="vehiclePurchaseStore.makeDelivery">
                Deliver this vehicle to your garage?
              </BngSwitch>
            </div>

            <div class="purchase-option">
              <BngSwitch label-before v-model="vehiclePurchaseStore.buyCustomLicensePlate"> Personalize license plate </BngSwitch>
            </div>

            <div v-if="vehiclePurchaseStore.buyCustomLicensePlate">
              <BngInput style="background-color: rgb(82, 82, 82);" v-model="vehiclePurchaseStore.customLicensePlateText" maxlength="10" floatingLabel="Custom License Plate" :validate="isLicensePlateTextValid" />
            </div>
          -->

          <BngButton :disabled="!vehiclePurchaseStore.vehicleInfo.negotiationPossible" accent="secondary" @click="negotiatePrice">
            Negotiate Price
          </BngButton>

          <BngButton  v-bng-tooltip:top="tradeInButtonMessage" :disabled="!vehiclePurchaseStore.tradeInEnabled || !hasVehicle" accent="secondary" @click="chooseTradeInVehicle"
            >Choose Trade-In</BngButton>
          <BngButton
            v-if="vehiclePurchaseStore.tradeInEnabled && vehiclePurchaseStore.tradeInVehicleInfo.niceName"
            @click="removeTradeInVehicle"
            :accent="ACCENTS.attention"
            >Remove Trade-In</BngButton>

          <BngButton @click="chooseInsurance" :accent="ACCENTS.secondary">Choose Insurance</BngButton>
        </div>
      </div>


      <template #buttons>

        <div class="button-group">
          <BngButton v-if="!isCarMeetPurchase" :disabled="vehiclePurchaseStore.purchaseType !== 'inspect' || vehiclePurchaseStore.alreadyDidTestDrive"
          v-bng-tooltip:top="testDriveButtonMessage"
          @click="startTestDrive" :accent="ACCENTS.secondary">Test Drive</BngButton>

          <BngButton
            :disabled="
              vehiclePurchaseStore.finalPackagePrice > vehiclePurchaseStore.spendableMoney ||
              !vehicleFitsInventory ||
              (vehiclePurchaseStore.forceTradeIn && !vehiclePurchaseStore.tradeInVehicleInfo.niceName) ||
              (vehiclePurchaseStore.buyCustomLicensePlate && !licensePlateTextValid) ||
              (vehiclePurchaseStore.makeDelivery && (!vehiclePurchaseStore.selectedGarageId || !vehiclePurchaseStore.deliveryQuote || vehiclePurchaseStore.deliveryQuote.disabled)) ||
              (!vehiclePurchaseStore.makeDelivery && !vehiclePurchaseStore.freightAvailable)
            "
            show-hold
            v-bng-on-ui-nav:ok.asMouse.focusRequired
            v-bng-click="{
              holdCallback: buy,
              holdDelay: 1000,
              repeatInterval: 0,
            }">
            <div v-if="vehiclePurchaseStore.finalPackagePrice > vehiclePurchaseStore.spendableMoney">{{ vehiclePurchaseStore.racingTeamVehicleShop ? "Insufficient team funds" : "Insufficient Funds" }}</div>
            <div v-else-if="!vehicleFitsInventory">No free inventory slots</div>
            <div v-else>{{ purchaseActionLabel }}</div>
          </BngButton>
        </div>
      </template>

    </BngCard>
    <div class="right-side">
      <BngCard class="status-container">
        <CareerStatus class="profile-status" />
      </BngCard>
      <TaskList
        class="task-list"
        :header="store.header"
        :tasks="store.tasks" />
    </div>
  </LayoutSingle>
</template>

<script setup>
import { computed, onMounted, onUnmounted, ref } from "vue"
import { BngButton, ACCENTS, BngCard, BngCardHeading, BngSwitch, BngDropdown, BngInput, BngUnit, BngIcon, BngBinding } from "@/common/components/base"
import { useVehiclePurchaseStore } from "../stores/vehiclePurchaseStore"
import { lua, useBridge } from "@/bridge"
import { vBngClick, vBngTooltip } from "@/common/directives"
import { LayoutSingle } from "@/common/layouts"
import { CareerStatus, ChooseInsuranceMain } from "@/modules/career/components"
import { addPopup, openConfirmation } from "@/services/popup"
import { $translate } from "@/services/translation"
import { vBngOnUiNav, vBngBlur } from "@/common/directives"
import { useUINavScope } from "@/services/uiNav"
import { useTasksStore } from "@/services/tasklistStore"
import TaskList from "@/modules/tasks/components/TaskList.vue"
useUINavScope("vehiclePurchase")
import useControls from "@/services/controls"
import { storeToRefs } from "pinia"

const Controls = useControls()
const { showIfController } = storeToRefs(Controls)

const { units } = useBridge()

const hasVehicle = ref(false)
const licensePlateTextValid = ref(true)

const vehiclePurchaseStore = useVehiclePurchaseStore()
const store = useTasksStore()

const isCarMeetPurchase = computed(() => vehiclePurchaseStore.vehicleInfo.source === "carMeet")
const isOnlinePurchase = computed(() =>
  vehiclePurchaseStore.vehicleInfo.salesChannel === "factory" ||
  vehiclePurchaseStore.vehicleInfo.salesChannel === "remanufactured"
)
const purchaseActionLabel = computed(() => {
  if (vehiclePurchaseStore.racingTeamVehicleShop) return "Purchase for Team"
  if (isOnlinePurchase.value && !vehiclePurchaseStore.makeDelivery) return "Order for Pickup"
  if (isOnlinePurchase.value && vehiclePurchaseStore.makeDelivery) return "Purchase & Deliver"
  return "Purchase"
})
const deliveryGarageOptions = computed(() =>
  vehiclePurchaseStore.deliveryGarages.map(garage => ({
    value: String(garage.id),
    label: `${garage.name} (${garage.freeSlots} free)`
  }))
)

const isLicensePlateTextValid = (text) => {
  lua.career_modules_inventory.isLicensePlateValid(text).then(valid => {
    licensePlateTextValid.value = valid
  })
  return licensePlateTextValid.value
}

const formatMileage = mileageMeters => {
  const meters = Number(mileageMeters)
  if (!Number.isFinite(meters) || meters <= 0) return "0 mi"
  return `${Math.round(meters / 1609.344).toLocaleString()} mi`
}

const tradeInButtonMessage = computed(() => {
  if (!vehiclePurchaseStore.tradeInEnabled) return "Trade in only possible in person at a dealership"

  return !hasVehicle.value ? "You don't own any vehicles" : undefined
})

const testDriveButtonMessage = computed(() => {
  if (vehiclePurchaseStore.purchaseType !== 'inspect') return "Test drive only available for inspect purchases"
  if (vehiclePurchaseStore.alreadyDidTestDrive) return "You have already done a test drive"
  return "You will be charged 50% of repair costs for any damage caused"
})

const vehicleFitsInventory = computed(() => {
  if (vehiclePurchaseStore.vehicleInfo.takesNoInventorySpace) return true

  return vehiclePurchaseStore.inventoryHasFreeSlot || (vehiclePurchaseStore.tradeInVehicleInfo.niceName && !vehiclePurchaseStore.tradeInVehicleInfo.takesNoInventorySpace)
})

vehiclePurchaseStore.inventoryIsEmpty().then(empty => {
  hasVehicle.value = !empty
})

const buy = () => buyVehicle(vehiclePurchaseStore.makeDelivery)

const cancel = () => {
  lua.extensions.ui_router.back()
}

const startTestDrive = () => {
  vehiclePurchaseStore.startTestDrive()
}

const chooseTradeInVehicle = () => {
  vehiclePurchaseStore.chooseTradeInVehicle()
}

const chooseInsurance = () => {
  addPopup(ChooseInsuranceMain, {
    menuMode: 'purchase',
    params: {
      purchaseType: vehiclePurchaseStore.purchaseType,
      shopId: vehiclePurchaseStore.vehicleInfo.shopId,
      insuranceId: vehiclePurchaseStore.insuranceOptions.insuranceId
    }
  })
}

const negotiatePrice = () => {
  lua.career_modules_marketplace.startNegotiateSellingOffer(vehiclePurchaseStore.vehicleInfo.shopId)
}

const removeTradeInVehicle = () => {
  vehiclePurchaseStore.removeTradeInVehicle()
}

const buyVehicle = _makeDelivery => {
  vehiclePurchaseStore.buyVehicle(_makeDelivery)
}

const selectDeliveryGarage = async garageId => {
  await vehiclePurchaseStore.requestDeliveryQuote(garageId)
}

const formatDistance = meters => `${Math.max(0, Number(meters) || 0) / 1609.344 < 0.1
  ? '<0.1'
  : (Math.max(0, Number(meters) || 0) / 1609.344).toFixed(1)} mi`

const formatEta = seconds => {
  const value = Math.max(0, Math.round(Number(seconds) || 0))
  if (value < 60) return `${value}s`
  return `${Math.ceil(value / 60)} min`
}

const start = () => {
  vehiclePurchaseStore.requestPurchaseData()
}

const kill = async () => {
  await lua.career_modules_inspectVehicle.onPurchaseMenuClosed()
  vehiclePurchaseStore.$dispose()
}
onMounted(start)
onUnmounted(kill)
</script>

<style scoped lang="scss">
// Layout
.purchase-layout {
  --content-flow: row nowrap;
  --content-max-width: unset;
  --safezone-sides: 1rem;
  --safezone-top: 1rem;
}

.purchase-screen {
  width: 35rem;
  color: white;
  background-color: var(--bng-black-o6);
  & :deep(.card-cnt) {
    background-color: var(--bng-black-o6);
  }
  :deep(.footer-container) {
    display: flex;
    flex-direction: column;
  }
}

.right-side {
  flex: 1;
  display: flex;
  flex-direction: column;
  gap: 0.5rem;
  justify-self: flex-end;
}

// Header
.header-row {
  display: flex;
  flex-direction: row;
  justify-content: space-between;
  align-items: flex-end;
  padding-right: 0.5rem;
  border-bottom: 1px solid rgba(255, 255, 255, 0.1);
  background-color: rgba(0, 0, 0, 0.6);
  border-radius: var(--bng-corners-2) var(--bng-corners-2) 0 0;
  min-height: 3.6rem;
  >* {
    line-height: 1.2;
  }
  .header-seller-info {
    margin-top: 0rem;
    font-size: 0.875rem;
    font-weight: 400;
    color: rgba(255, 255, 255, 0.5);
  }
}

.close-button {
  cursor: pointer;
  height: 2.25rem;
  min-width: 5.25rem;
  display: flex;
  gap: 0.5rem;
  align-items: center;
  justify-content: center;
  align-self: flex-start;
  margin-top: 0.75rem !important;
}

// Purchase list
.purchase-list {
  display: flex;
  flex-direction: column;
  padding: 1rem 2.5rem 0;
  gap: 0.25rem;
}

.purchase-divider {
  width: 100%;
  height: 1px;
  background-color: rgba(255, 255, 255, 0.2);
  margin: 0.4rem 0;
}

// Purchase row
.purchase-row {
  display: flex;
  justify-content: space-between;
  align-items: flex-start;
  width: 100%;
  padding: 0.1rem 0.25rem;
  border-radius: var(--bng-corners-2);
  background: linear-gradient(to right, var(--bng-cool-gray-800), rgba(var(--bng-cool-gray-850-rgb), 0));

  &.thin {
    .label {
      font-weight: 300;
    }
    .price {
      :deep(.icon) {
        --icon-size: 1.5em;
      }
      :deep(.value-label) {
        font-weight: 300;
      }
    }
  }

  &.light-blue {
    background: linear-gradient(to right, var(--bng-add-blue-800), rgba(var(--bng-add-blue-200-rgb), 0));
  }

  &.yellow {
    background: linear-gradient(to right, var(--bng-ter-yellow-800), rgba(var(--bng-ter-yellow-300-rgb), 0));
  }

  &.green {
    background: linear-gradient(to right, var(--bng-add-green-800), rgba(var(--bng-add-green-300-rgb), 0));
  }

  &.red {
    background: linear-gradient(to right, var(--bng-add-red-800), rgba(var(--bng-add-red-300-rgb), 0));
    color: var(--bng-add-red-400);
    --bng-icon-color: var(--bng-add-red-400);
  }
}

.label {
  text-align: left;
  flex: 1;
  min-width: 0;
  font-weight: 600;
  margin-top: 0.25rem;
}

.price {
  align-self: flex-start;
  align-items: flex-end;
  flex: 0 0 auto;
  display: flex;
  flex-direction: column;
  min-width: 0;
  margin-top: -0.1rem;
  :deep(.info-item) {
    padding: 0;
  }
  .old-price {
    font-size: 0.85em;
    opacity: 0.5;
    :deep(.value-label) {
      text-decoration: line-through;
    }

    :deep(.icon) {
      --icon-size: 1.1em;
    }
  }
  .current-price-line {
    display: flex;
    gap: 0.4rem;
    align-items: baseline;
  }
}

.sub-info {
  font-size: 0.875rem;
  color: rgba(255, 255, 255, 0.5);
  --bng-icon-color: rgba(255, 255, 255, 0.5);
  font-weight: 300;
  :deep(.value-label) {
    font-weight: 300;
  }
}

.highlight-category {
  font-size: 1.5em;
  font-weight: 900 !important;
  :deep(.value-label) {
    font-weight: 900 !important;
  }
  :deep(.icon) {
    --icon-size: 1.4em;
  }
}

// Purchase options
.purchase-customization-group {
  --bng-button-margin: 0;
  margin: 1rem 2rem 0.5rem;
  border-radius: var(--bng-corners-2);
  border: 1px solid rgba(255, 255, 255, 0.2);
  padding: 0.75rem;
  display: flex;
  flex-direction: column;
  gap: 0.5rem;
  justify-content: stretch;
  h4 {
    padding: 0;
    margin: 0;
  }
  >* {
    width: 100%;
    max-width: 100% !important;
  }
}

.delivery-option {
  display: flex;
  flex-direction: column;
  gap: 0.5rem;
}

.garage-select {
  width: 100%;
  padding: 0.55rem 0.7rem;
  color: white;
  background: rgba(0, 0, 0, 0.45);
  border: 1px solid rgba(255, 255, 255, 0.25);
  border-radius: var(--bng-corners-1);
}

.delivery-note,
.delivery-warning {
  padding: 0.5rem 0.65rem;
  border-radius: var(--bng-corners-1);
  background: rgba(80, 150, 210, 0.2);
}

.delivery-warning {
  color: #ffd1d1;
  background: rgba(180, 45, 45, 0.3);
}

// Buttons
.button-group {
  --bng-button-margin: 0;
  display: flex;
  flex-direction: row;
  flex-wrap: wrap;
  width: 100%;
  gap: 0.5rem;
  padding: 0.125rem;
  >* {
    flex: 1;
  }
}

// Status sidebar
.status-container {
  color: white;
  align-self: flex-end;
  flex: 0 0 auto;
  .status-add {
    text-align: center;
    padding: 0.25rem 0.5rem;
  }
}

.profile-status {
  background-color: rgba(0, 0, 0, 0.7);
  & :deep(.card-cnt) {
    background-color: rgba(0, 0, 0, 0.7);
  }
}

.task-list {
  width: 33rem;
  align-self: flex-end;
}
</style>
