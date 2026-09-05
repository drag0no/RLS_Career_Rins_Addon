<template>
  <div class="marketplace-container">
    <Accordion class="part-groups" :items="listings" >
      <template v-for="listing in listings" :key="listing.id">
        <AccordionItem :expanded="true" class="marketplace-listing" :class="{ 'disabled': listing.disabled }" >
          <template #caption>
            <div class="veh-part-caption" >
              <div v-if="listing.thumbnail" class="veh-preview" :style="{ backgroundImage: `url('${listing.thumbnail}')` }" ></div>
              <span class="veh-name">
                {{ listing.niceName }}
                <span class="veh-name-count">({{ listing.offers.length || 0 }})</span>
              </span>
              <span class="veh-price">
                <div>
                  Asking Price:
                  <BngUnit :money="listing.value" />
                </div>
                <div>
                  Estimated Market Value:
                <BngUnit :money="listing.marketValue || listing.marketSellValue || listing.value" />
                </div>
              </span>

              <span class="veh-remove">
                <BngButton
                  @click.stop="editListingPrice(listing)"
                  :accent="ACCENTS.secondary"
                >
                  Edit price
                </BngButton>
                <BngButton
                  @click.stop="confirmRemoveListingScreen(listing.id)"
                  :icon="icons.trashBin1"
                  :accent="ACCENTS.attentionghost"
                >
                </BngButton>
              </span>
            </div>
          </template>
          <div v-if="listing.disabled" class="offer-card red">
            {{ listing.disableReason }}
          </div>
          <div class="offer-card" v-bng-scoped-nav v-for="(offer, index) in listing.offers" @mouseover="onOfferHovered(offer)" @mouseleave="onOfferUnhovered(offer)" @activate="onActivated(offer)" @deactivate="onDeactivated(offer)" :class="{ 'expired': offer.expiredViewCounter == 1 }">
            <div class="offer-info">
              <div class="offer-header">
                <span class="buyer-name">{{ offer.buyerPersonality.name }}</span>
                <span v-if="offer.expiredViewCounter" class="expired-badge">EXPIRED</span>
              </div>
              <div class="offer-details">
                <div class="detail-row">
                  <span class="detail-label">Offer:</span>
                  <BngUnit :money="offer.value" />
                  <span class="delta" :class="{ up: offer.value > listing.value, down: offer.value < listing.value }">
                    ( {{ offer.value > listing.value ? '+' : '-' }}<BngUnit :money="Math.abs(offer.value - listing.value)" />)
                  </span>
                </div>
                <div class="detail-row">
                  <span class="detail-label">Vehicle:</span>
                  <span>{{ listing.niceName }}</span>
                </div>
              </div>
            </div>
            <div class="spec-actions">
              <BngButton
                class="part-button"
                @click="declineOffer(listing, offer, index)"
                :accent="ACCENTS.attention"
              >
                {{offer.expiredViewCounter ? 'Discard' : 'Deny'}}
              </BngButton>
              <BngButton
                class="part-button negotiate-button"
                @click="startNegotiateBuyingOffer(listing, offer, index)"
                :accent="ACCENTS.secondary"
                :disabled="!offer.negotiationPossible || offer.value >= listing.value || listing.disabled || listing.damagedAfterListing"
                v-if="!offer.expiredViewCounter"
              >
                Negotiate
              </BngButton>
              <BngButton
                v-if="!offer.expiredViewCounter"
                class="part-button"
                @click="acceptOffer(listing, offer, index)"
                :disabled="listing.disabled || offer.disabled || listing.damagedAfterListing"
                :accent="ACCENTS.main"
              >
                Accept Offer
              </BngButton>
            </div>
          </div>
          <div v-if="Object.keys(listing.offers || {}).length === 0" class="offer-card">
            {{ $translate.instant("ui.career.vehicleMarketplace.noOffers") }}
          </div>
        </AccordionItem>
      </template>
    </Accordion>
    <BngButton
      class="add-listing-button"
      @click="listVehicle"
      :accent="ACCENTS.custom"
    >
      <span class="add-listing-button-icon">+</span> Add Listing
    </BngButton>
  </div>
</template>

<script setup>
import { ref, onMounted, onUnmounted, nextTick } from "vue"

const props = defineProps({
  racingTeamBusinessId: {
    type: String,
    default: "",
  },
})
import { lua, useBridge } from "@/bridge"
import { Accordion, AccordionItem } from "@/common/components/utility"
import { BngCard, BngUnit, BngPropVal, BngButton, BngIcon, ACCENTS, icons, BngInput } from "@/common/components/base"
import { vBngBlur, vBngScopedNav } from "@/common/directives"
import { useComputerStore } from "../../stores/computerStore"
import { openConfirmation, openPrompt } from "@/services/popup"
import { $translate } from "@/services/translation"

const computerStore = useComputerStore()
const { events } = useBridge()

const listings = ref([])

const confirmRemoveListingScreen = async listingId => {
  const res = await openConfirmation("", "Do you want to remove this listing?", [
    { label: $translate.instant("ui.common.yes"), value: true, extras: { default: true } },
    { label: $translate.instant("ui.common.no"), value: false, extras: { accent: ACCENTS.secondary } },
  ])

  if (res) {
    removeVehicleListing(listingId)
  }
}

const editListingPrice = async listing => {
  const current = Math.max(50, Math.round((Number(listing.value) || 0) / 50) * 50)
  const res = await openPrompt("Enter a new asking price.", "Edit asking price", {
    defaultValue: String(current),
    buttons: [
      { label: $translate.instant("ui.common.cancel"), value: false, extras: { cancel: true, accent: ACCENTS.secondary } },
      { label: $translate.instant("ui.common.okay"), value: text => text, extras: { accent: ACCENTS.primary } },
    ],
    validate: text => {
      const n = Number(String(text).replace(/[^0-9.]/g, ""))
      return Number.isFinite(n) && n > 0
    },
    errorMessage: "Enter a valid price",
    disableWhenInvalid: true,
  })
  if (res === false || res == null) return
  const price = Number(String(res).replace(/[^0-9.]/g, ""))
  if (!Number.isFinite(price) || price <= 0) return
  lua.career_modules_marketplace.updateListingValue(listing.id, price).then(getNewData)
}

const onActivated = (offer) => { offer.active = true }

const onDeactivated = (offer) => { offer.active = false }

const onOfferHovered = (offer) => { offer.hovered = true }

const onOfferUnhovered = (offer) => { offer.hovered = false }

const handleListings = (data) => { listings.value = data }

const getNewData = () => {
  lua.career_modules_marketplace.getListings().then(handleListings)
}

// getListings() reverses offers and pushes disabled ones to the end, so a row index does not
// match listing.offers on the Lua side. Resolve by stable offer id when one is available.
const acceptOffer = (listing, offer, offerIndex) => {
  const call = offer.id != null
    ? lua.career_modules_marketplace.acceptOfferById(offer.id)
    : lua.career_modules_marketplace.acceptOffer(listing.id, offerIndex + 1)
  call.then(getNewData)
}

const declineOffer = (listing, offer, offerIndex) => {
  const call = offer.id != null
    ? lua.career_modules_marketplace.declineOfferById(offer.id)
    : lua.career_modules_marketplace.declineOffer(listing.id, offerIndex + 1)
  call.then(getNewData)
}

const startNegotiateBuyingOffer = (listing, offer, offerIndex) => {
  const call = offer.id != null
    ? lua.career_modules_marketplace.startNegotiateBuyingOfferById(offer.id, false)
    : lua.career_modules_marketplace.startNegotiateBuyingOffer(listing.id, offerIndex + 1)
  call.then(getNewData)
}

const removeVehicleListing = (inventoryId) => {
  lua.career_modules_marketplace.removeVehicleListing(inventoryId).then(getNewData)
}

const listVehicle = async () => {
  const bid = props.racingTeamBusinessId && String(props.racingTeamBusinessId)
  if (bid) {
    let rows = []
    try {
      rows = await lua.career_modules_business_businessComputer.getRtFleetOpts(bid)
    } catch (_err) {
      rows = []
    }
    const arr = Array.isArray(rows) ? rows : Object.values(rows || {})
    if (!arr.length) return
    const lines = arr.map((r, i) => `${i + 1}. ${r.label || r.vehicleId}`)
    const pick = window.prompt(`Pick vehicle:\n${lines.join("\n")}\nEnter number:`)
    const n = parseInt(String(pick), 10)
    if (!n || n < 1 || n > arr.length) return
    const askRaw = window.prompt("Asking price:", "10000")
    const price = parseFloat(String(askRaw))
    if (!(price > 0)) return
    try {
      await lua.career_modules_marketplace.addRtListing(bid, arr[n - 1].vehicleId, price)
    } catch (_e2) {}
    getNewData()
    return
  }
  lua.career_modules_inventory.openInventoryMenuForChoosingListing()
}

const start = () => {
  lua.career_modules_marketplace.menuOpened(true)
  events.on("marketplaceListingsUpdated", handleListings)
  getNewData()
}

const stop = () => {
  lua.career_modules_marketplace.menuOpened(false)
  events.off("marketplaceListingsUpdated")
}

onMounted(start)
onUnmounted(stop)

</script>

<style scoped lang="scss">

.marketplace-container {
  display: flex;
  flex-direction: column;
  flex: 1;
  min-height: 0;
  height: 100%;
}

.offer-card {
  display: flex;
  justify-content: space-between;
  align-items: center;
  gap: 1em;
  outline: 2px solid rgba(var(--bng-cool-gray-50-rgb), 0.5);
  border-radius: 4px;
  white-space: nowrap;
  padding: 0.75em 0.9em;
  background-color: rgba(var(--bng-cool-gray-900-rgb), 0.8);
  margin-top: 0.5em;
  margin-bottom: 0.5em;
  &.red {
    background-color: rgba(var(--bng-add-red-400-rgb), 0.1);
    outline-color: rgba(var(--bng-add-red-400-rgb), 0.5);
    color: var(--bng-add-red-200);
  }
}

.expired {
  .offer-info {
    opacity: 0.5;
  }
}
.offer-info {
  display: flex;
  flex-direction: column;
  gap: 0.25em;
}

.offer-header {
  display: flex;
  align-items: center;
  gap: 0.5em;
  font-weight: 600;
}

.buyer-name { color: var(--bng-off-white); }

.expired-badge {
  padding: 0.05em 0.5em;
  border-radius: 3px;
  font-size: 0.85em;
  color: var(--bng-add-red-400);
  background-color: rgba(var(--bng-add-red-400-rgb), 0.1);
}

.offer-details { color: var(--bng-off-white); }

.detail-row {
  display: flex;
  align-items: baseline;
  gap: 0.5em;
}

.detail-label {
  color: var(--bng-cool-gray-200);
}

.delta { margin-left: 0.25em; }
.delta.up { color: var(--bng-add-green-400); }
.delta.down { color: var(--bng-add-red-400); }


.add-listing-button {
  display: flex;
  max-width: none !important;
  padding: 0.5em;
  font-size: 1.5em;
  line-height: 1.5em;
  color: var(--bng-off-white);
  display: flex;
  align-items: center !important;
  justify-content: center;

  --bng-button-custom-enabled: var(--bng-cool-gray-750);
  --bng-button-custom-hover: var(--bng-cool-gray-700);
  --bng-button-custom-active: var(--bng-cool-gray-900);
  --bng-button-custom-disabled: var(--bng-cool-gray-700);
  --bng-button-custom-enabled-opacity: 0.5;
  --bng-button-custom-hover-opacity: 0.5;
  --bng-button-custom-active-opacity: 1;
  --bng-button-custom-disabled-opacity: 0.2;
  --bng-button-custom-margin: 0.25em 0 0 0;


  border: 0.125rem dashed rgba(var(--bng-off-white-rgb), 0.25);

  .add-listing-button-icon {
    font-size: 1.5em;
    margin-right: 0.25em;
    font-weight: 700;
  }
}

.spec-actions {
  visibility: visible;
  display: flex;
  gap: 0.5em;
}

.part-info-col,
.part-info-row {
  display: none;
}

.part-button {
  flex: 0 0 auto;
}

.center {
  text-align: center;
}
.right {
  text-align: left;
}

.marketplace-card {
  color: white;
}

.veh-part-caption {
  display: flex;
  flex-flow: row nowrap;
  justify-content: stretch;
  align-items: center;
  overflow: hidden;
  //width: 100%;
  height: 4em;
  .veh-preview {
    height: 100%;
    aspect-ratio: 16 / 9;
    width: auto;
    flex-shrink: 0;
    align-self: center;
    background-size: cover;
    background-position: 50% 50%;
    background-repeat: no-repeat;
    border-radius: var(--bng-corners-1);
  }
  .veh-name {
    flex: 0 0 30%;
    padding-left: 0.3em;
    font-size: 1.2em;
    text-align: left;
    padding-left: 0.5em;
    .veh-name-count {
      font-weight: 300;
    }
  }

  .veh-price {
    flex: 0 0 40%;
    text-align: center;
  }

  .veh-remove {
    flex: 1 0 10%;
    display: flex;
    align-items: center;
    justify-content: flex-end;
    gap: 0.4em;
    text-align: right;
  }


}

.part-groups {
  overflow: hidden auto;
  background-color: rgba(var(--bng-cool-gray-900-rgb), 0.0);
  border-radius: var(--bng-corners-2);
  gap: 0.3em;
  flex: 1;
  min-height: 0;
  :deep(.bng-accitem) {
    margin: 0;
  }
  :deep(.bng-accitem-caption) {
    background-color: rgba(var(--bng-cool-gray-700-rgb), 0.6);
  }
}
.disabled {
  .veh-name, .veh-price {
    color: var(--bng-add-red-400);
    --bng-icon-color: var(--bng-add-red-400);
  }

  background-color: rgba(var(--bng-add-red-400-rgb), 0.1);
  border-radius: var(--bng-corners-2);
}
</style>
