<template>
  <div class="car-meet-offers">
    <div class="panel">
      <div class="panel-header">
        <div>
          <div class="eyebrow">{{ saleData?.guaranteed ? "Car Bazaar" : "Car Meet" }}</div>
          <h1>Offers on Your Car</h1>
        </div>
        <BngButton accent="attention" @click="close">Close</BngButton>
      </div>

      <div v-if="!saleData" class="empty">
        No active car meet offers.
      </div>

      <template v-else>
        <div class="vehicle-strip">
          <img v-if="saleData.listing?.thumbnail" :src="saleData.listing.thumbnail" alt="" />
          <div>
            <h2>{{ saleData.listing?.niceName || "Brought vehicle" }}</h2>
            <p v-if="saleData.sold">Sold</p>
            <p v-else-if="saleData.needsVehicleAtMeet">Park your vehicle at the meet to start receiving offers.</p>
            <p v-else-if="saleData.guaranteed">
              {{ saleData.guaranteedGenerated || 0 }}/{{ saleData.guaranteedTarget || 0 }} guaranteed offers generated
            </p>
            <p v-else>Meet buyers can make offers while the event is active.</p>
          </div>
        </div>

        <section class="price-panel">
          <div class="price-stats">
            <div>
              <span>Est. Market</span>
              <strong>${{ formatMoney(marketValue) }}</strong>
            </div>
            <div>
              <span>Asking</span>
              <strong>${{ formatMoney(askingPrice) }}</strong>
            </div>
          </div>
          <div class="price-editor">
            <input
              v-model.number="askingInput"
              type="number"
              :min="minAskingPrice"
              :max="maxAskingPrice"
              step="50"
              v-bng-text-input
              @focus="setTyping(true)"
              @blur="setTyping(false)" />
            <BngButton accent="primary" @click="applyAskingPrice">Set Price</BngButton>
          </div>
          <div class="quick-prices">
            <BngButton accent="secondary" @click="setQuickPrice(1)">Market</BngButton>
            <BngButton accent="secondary" @click="setQuickPrice(1.1)">+10%</BngButton>
            <BngButton accent="secondary" @click="setQuickPrice(1.25)">+25%</BngButton>
          </div>
        </section>

        <div v-if="offers.length" class="offer-list">
          <article
            v-for="(offer, index) in offers"
            :key="index"
            class="offer-card"
            :class="{ expired: offer.expiredViewCounter }">
            <div>
              <div class="buyer">{{ offer.buyerPersonality?.name || "Meet Buyer" }}</div>
              <div class="price">${{ formatMoney(offer.value) }}</div>
              <div class="status">
                {{ offer.expiredViewCounter ? "Expired" : offerComparison(offer.value) }}
              </div>
            </div>
            <div class="actions">
              <BngButton accent="secondary" @click="declineOffer(index)">
                {{ offer.expiredViewCounter ? "Discard" : "Deny" }}
              </BngButton>
              <BngButton
                v-if="!offer.expiredViewCounter"
                accent="secondary"
                :disabled="!offer.negotiationPossible"
                @click="negotiateOffer(index)">
                Negotiate
              </BngButton>
              <BngButton
                v-if="!offer.expiredViewCounter"
                accent="primary"
                :disabled="offer.disabled"
                @click="acceptOffer(index)">
                Accept
              </BngButton>
            </div>
          </article>
        </div>

        <div v-else class="empty">
          No offers right now. Check back at your car when buyers show interest.
        </div>
      </template>
    </div>
  </div>
</template>

<script setup>
import { computed, onMounted, onUnmounted, ref, watch } from "vue"
import { BngButton } from "@/common/components/base"
import { lua, useBridge } from "@/bridge"

const { events } = useBridge()
const saleData = ref(null)
const asArray = value => {
  if (Array.isArray(value)) return value
  if (!value || typeof value !== "object") return []
  return Object.values(value)
}
const offers = computed(() => asArray(saleData.value?.offers))
const askingInput = ref(0)
const marketValue = computed(() => Number(saleData.value?.listing?.marketValue || 0))
const askingPrice = computed(() => Number(saleData.value?.listing?.value || marketValue.value || 0))
const minAskingPrice = computed(() => Number(saleData.value?.listing?.minAskingPrice || marketValue.value * 0.5 || 50))
const maxAskingPrice = computed(() => Number(saleData.value?.listing?.maxAskingPrice || marketValue.value * 2 || 50))

const refresh = async () => {
  lua.career_modules_carmeets.requestMeetSaleOfferData()
}

const updateSaleData = data => {
  saleData.value = data || null
}

watch(saleData, data => {
  if (data?.listing) askingInput.value = Math.round(Number(data.listing.value || data.listing.marketValue || 0))
}, { immediate: true })

const updateFromOverview = data => {
  if (!data) return
  const overviewSale = data.sale || data.bazaar
  if (overviewSale) saleData.value = overviewSale
}

const formatMoney = value => Math.round(Number(value || 0)).toLocaleString()

const clampAsking = value => Math.max(minAskingPrice.value, Math.min(maxAskingPrice.value, Number(value || marketValue.value || 0)))

const applyAskingPrice = async () => {
  const data = await lua.career_modules_carmeets.setMeetSaleAskingPrice(clampAsking(askingInput.value))
  if (data) updateSaleData(data)
}

const setQuickPrice = multiplier => {
  askingInput.value = Math.round((marketValue.value * multiplier) / 50) * 50
  applyAskingPrice()
}

const offerComparison = value => {
  const offer = Number(value || 0)
  const ask = askingPrice.value || 1
  const market = marketValue.value || 1
  const askPct = Math.round(((offer - ask) / ask) * 100)
  const marketPct = Math.round(((offer - market) / market) * 100)
  const askText = askPct === 0 ? "at asking" : `${Math.abs(askPct)}% ${askPct > 0 ? "over" : "under"} asking`
  const marketText = marketPct === 0 ? "at market" : `${Math.abs(marketPct)}% ${marketPct > 0 ? "over" : "under"} market`
  return `${askText}, ${marketText}`
}

const setTyping = active => {
  try { lua.setCEFTyping(active) } catch (_) {}
}

const acceptOffer = async index => {
  await lua.career_modules_carmeets.acceptBazaarOffer(index + 1)
  await refresh()
}

const declineOffer = async index => {
  await lua.career_modules_carmeets.declineBazaarOffer(index + 1)
  await refresh()
}

const negotiateOffer = async index => {
  await lua.career_modules_carmeets.negotiateBazaarOffer(index + 1)
}

const close = () => {
  lua.career_career.closeAllMenus()
}

onMounted(() => {
  events.on("onCarMeetSaleOfferData", updateSaleData)
  events.on("onCarMeetOverview", updateFromOverview)
  events.on("marketplaceListingsUpdated", refresh)
  refresh()
})

onUnmounted(() => {
  events.off("onCarMeetSaleOfferData", updateSaleData)
  events.off("onCarMeetOverview", updateFromOverview)
  events.off("marketplaceListingsUpdated", refresh)
  setTyping(false)
})
</script>

<style scoped lang="scss">
.car-meet-offers {
  display: flex;
  align-items: center;
  justify-content: center;
  width: 100%;
  height: 100%;
  color: white;
}

.panel {
  width: min(760px, 80vw);
  max-height: 82vh;
  overflow: auto;
  padding: 16px;
  border-radius: 8px;
  background: rgba(0, 0, 0, 0.86);
  border: 1px solid rgba(255, 122, 34, 0.45);
}

.panel-header,
.vehicle-strip,
.offer-card,
.actions,
.price-panel {
  display: grid;
  gap: 10px;
}

.panel-header {
  grid-template-columns: 1fr auto;
  align-items: start;
  margin-bottom: 12px;
}

.eyebrow,
.status,
.vehicle-strip p {
  color: #bdbdbd;
}

h1,
h2,
p {
  margin: 0;
}

.vehicle-strip {
  grid-template-columns: 140px 1fr;
  align-items: center;
  padding: 10px;
  border-radius: 6px;
  background: rgba(255, 255, 255, 0.08);
}

.vehicle-strip img {
  width: 100%;
  aspect-ratio: 16 / 9;
  object-fit: cover;
  border-radius: 4px;
}

.offer-list {
  display: flex;
  flex-direction: column;
  gap: 8px;
  margin-top: 12px;
}

.price-panel {
  margin-top: 12px;
  padding: 10px;
  border-radius: 6px;
  background: rgba(255, 255, 255, 0.07);
}

.price-stats,
.price-editor,
.quick-prices {
  display: grid;
  gap: 8px;
}

.price-stats,
.price-editor {
  grid-template-columns: 1fr 1fr;
  align-items: end;
}

.quick-prices {
  grid-template-columns: repeat(3, 1fr);
}

.price-stats span {
  display: block;
  color: #bdbdbd;
}

.price-editor input {
  width: 100%;
  min-width: 0;
  box-sizing: border-box;
  padding: 10px;
  border: 1px solid rgba(255, 255, 255, 0.18);
  border-radius: 4px;
  color: white;
  background: rgba(0, 0, 0, 0.35);
  font-size: 1.1em;
  font-weight: 700;
}

.offer-card {
  grid-template-columns: 1fr auto;
  align-items: center;
  padding: 10px;
  border-radius: 6px;
  background: rgba(255, 255, 255, 0.08);
}

.offer-card.expired {
  opacity: 0.65;
}

.buyer {
  font-weight: 700;
}

.price {
  font-size: 1.6em;
  font-weight: 800;
}

.actions {
  grid-template-columns: repeat(3, minmax(110px, 1fr));
}

.empty {
  padding: 24px;
  text-align: center;
  color: #bdbdbd;
}
</style>
