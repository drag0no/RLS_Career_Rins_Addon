<template>
  <ComputerWrapper title="Property Offers" back @back="goBack">
    <div class="offers-panel">
        <!-- Property Header -->
        <div class="property-header" v-if="property">
          <div class="header-preview">
            <img v-if="property.preview" :src="property.preview" alt="" class="header-img" />
            <div class="header-fade"></div>
            <div class="header-badges">
              <span class="tag listed">LISTED</span>
            </div>
          </div>
          <div class="header-body">
            <h1 class="header-name">{{ property.name }}</h1>
            <div class="header-prices">
              <div class="price-item">
                <span class="price-label">Your Asking Price</span>
                <span class="price-value">${{ formatPrice(property.askingPrice) }}</span>
              </div>
              <div class="price-divider"></div>
              <div class="price-item">
                <span class="price-label">Market Value</span>
                <span class="price-value dim">${{ formatPrice(property.marketValue) }}</span>
              </div>
              <template v-if="mortgageBalance > 0">
                <div class="price-divider"></div>
                <div class="price-item">
                  <span class="price-label">Mortgage Balance</span>
                  <span class="price-value mortgage">${{ formatPrice(mortgageBalance) }}</span>
                </div>
              </template>
            </div>
          </div>
        </div>

        <!-- Loading -->
        <div v-if="loading" class="loading-state">
          Loading offers...
        </div>

        <!-- No Offers -->
        <div v-else-if="!offers || offers.length === 0" class="empty-offers">
          <div class="empty-card">
            <div class="empty-icon">📭</div>
            <div class="empty-text">No Offers Yet</div>
            <div class="empty-desc">Buyers are reviewing your listing. Offers will come in over time based on your asking price and market conditions.</div>
          </div>
        </div>

        <!-- Offers List -->
        <div v-else class="offers-list">
          <div class="offers-heading">
            <span class="offers-count">{{ offers.length }} {{ offers.length === 1 ? 'Offer' : 'Offers' }}</span>
          </div>

          <div
            v-for="offer in offers"
            :key="offer.index"
            class="offer-card"
            :class="{ underwater: isUnderwater(offer) }"
          >
            <div class="offer-main">
              <div class="offer-buyer">
                <div class="buyer-avatar">{{ offer.buyerName.charAt(0) }}</div>
                <div class="buyer-info">
                  <span class="buyer-name">{{ offer.buyerName }}</span>
                  <span class="offer-time">{{ formatTimeSince(offer.timestamp) }}</span>
                </div>
              </div>
              <div class="offer-price-block" :class="offerColorClass(offerPrice(offer))">
                <div class="offer-price-row">
                  <span class="offer-price-label">Offer</span>
                  <span class="offer-price-value">
                    <template v-if="offer.negotiatedPrice">
                      <span class="original-price">${{ formatPrice(offer.value) }}</span>
                      <span class="negotiated-price">${{ formatPrice(offer.negotiatedPrice) }}</span>
                    </template>
                    <template v-else>
                      ${{ formatPrice(offer.value) }}
                    </template>
                  </span>
                </div>
                <div class="offer-diff-pill" :class="offerColorClass(offerPrice(offer))">
                  {{ offerDiffText(offerPrice(offer)) }}
                </div>
              </div>
            </div>

            <div class="offer-underwater" v-if="isUnderwater(offer)">
              <div class="underwater-title">Cannot sell — offer below mortgage</div>
              <div class="underwater-figures">
                <div class="underwater-fig">
                  <span class="underwater-fig-label">Offer</span>
                  <span class="underwater-fig-value">${{ formatPrice(offerPrice(offer)) }}</span>
                </div>
                <div class="underwater-fig">
                  <span class="underwater-fig-label">Mortgage due</span>
                  <span class="underwater-fig-value">${{ formatPrice(mortgageBalance) }}</span>
                </div>
                <div class="underwater-fig short">
                  <span class="underwater-fig-label">Short by</span>
                  <span class="underwater-fig-value">${{ formatPrice(mortgageBalance - offerPrice(offer)) }}</span>
                </div>
              </div>
            </div>

            <div class="offer-actions">
              <button
                v-if="!isUnderwater(offer)"
                class="btn btn-accept"
                @click="acceptOffer(offer)"
              >
                Accept
              </button>
              <button
                v-else
                class="btn btn-blocked"
                disabled
              >
                Blocked by mortgage
              </button>
              <button class="btn btn-negotiate" @click="negotiateOffer(offer)" :disabled="!offer.negotiationPossible">
                Negotiate
              </button>
              <button class="btn btn-decline" @click="declineOffer(offer)">
                Decline
              </button>
            </div>
          </div>
        </div>

    </div>
  </ComputerWrapper>
</template>

<script setup>
import { ref, onMounted, onUnmounted } from 'vue'
import { lua } from '@/bridge'
import { useEvents } from '@/services/events'
import { useRoute } from 'vue-router'
import ComputerWrapper from './ComputerWrapper.vue'

const route = useRoute()
const events = useEvents()
const garageId = route.params.garageId

const property = ref(null)
const offers = ref([])
const loading = ref(true)
const mortgageBalance = ref(0)

const formatPrice = (value) => {
  if (value === null || value === undefined) return '0'
  return Math.floor(value).toLocaleString('en-US')
}

const formatTimeSince = (timestamp) => {
  if (!timestamp) return ''
  const now = Math.floor(Date.now() / 1000)
  const diff = now - timestamp
  if (diff < 60) return 'Just now'
  if (diff < 3600) return Math.floor(diff / 60) + 'm ago'
  if (diff < 86400) return Math.floor(diff / 3600) + 'h ago'
  return Math.floor(diff / 86400) + 'd ago'
}

const offerPrice = (offer) => offer.negotiatedPrice || offer.value

const isUnderwater = (offer) => {
  return mortgageBalance.value > 0 && offerPrice(offer) < mortgageBalance.value
}

const offerColorClass = (value) => {
  if (!property.value) return ''
  const asking = property.value.askingPrice
  if (!asking) return ''
  const ratio = value / asking
  if (ratio >= 0.95) return 'offer-green'
  if (ratio >= 0.80) return 'offer-yellow'
  return 'offer-red'
}

const offerDiffText = (value) => {
  if (!property.value) return ''
  const asking = property.value.askingPrice
  if (!asking) return ''
  const diff = value - asking
  const pct = Math.round((diff / asking) * 100)
  if (pct === 0) return 'at asking'
  return (pct > 0 ? '+' : '') + pct + '% vs asking'
}

const loadOffers = async () => {
  loading.value = true
  try {
    const data = await lua.career_modules_garageManager.getGarageOffersData(garageId)
    if (data) {
      property.value = data
      offers.value = data.offers || []
    }
  } catch (e) {
    // ignore
  }
  loading.value = false
  try {
    const mortgageInfo = await lua.career_modules_propertyMortgage.getMortgagePaymentInfo(garageId)
    if (mortgageInfo && mortgageInfo.remainingBalance) {
      mortgageBalance.value = mortgageInfo.remainingBalance
    }
  } catch (e) {
    mortgageBalance.value = 0
  }
}

const acceptOffer = async (offer) => {
  await lua.career_modules_garageManager.acceptOffer(garageId, offer.index)
  lua.career_career.closeAllMenus()
}

const declineOffer = async (offer) => {
  await lua.career_modules_garageManager.declineOffer(garageId, offer.index)
  await loadOffers()
}

const negotiateOffer = async (offer) => {
  await lua.career_modules_realEstateNegotiation.startNegotiateSelling(garageId, offer.index)
}

const goBack = () => {
  lua.extensions.ui_router.back()
}

onMounted(() => {
  events.on('garageListingsUpdated', loadOffers)
  loadOffers()
})

onUnmounted(() => {
  events.off('garageListingsUpdated', loadOffers)
})
</script>

<style scoped lang="scss">
.offers-panel {
  color: white;
  background: #0e0e0e;
  height: 100%;
  max-height: calc(100vh - 120px);
  border-radius: 14px;
  overflow: hidden;
  display: flex;
  flex-direction: column;
  padding-bottom: 16px;
  box-sizing: border-box;
}

.property-header {
  overflow: hidden;
  flex-shrink: 0;
}

.header-preview {
  position: relative;
  width: 100%;
  height: 160px;
  background: #000;
  overflow: hidden;
}

.header-img {
  width: 100%;
  height: 100%;
  object-fit: cover;
  display: block;
}

.header-fade {
  position: absolute;
  bottom: 0;
  left: 0;
  right: 0;
  height: 60px;
  background: linear-gradient(to top, #0e0e0e, transparent);
  pointer-events: none;
}

.header-badges {
  position: absolute;
  top: 10px;
  left: 10px;
}

.tag {
  font-size: 9px;
  font-weight: 700;
  padding: 3px 8px;
  border-radius: 4px;
  letter-spacing: 0.6px;

  &.listed {
    background: rgba(249, 115, 22, 0.85);
    color: white;
  }
}

.header-body {
  padding: 16px 20px;
}

.header-name {
  font-size: 20px;
  font-weight: 700;
  margin: 0 0 12px;
}

.header-prices {
  display: flex;
  align-items: center;
  gap: 16px;
  flex-wrap: wrap;
}

.price-item {
  display: flex;
  flex-direction: column;
  gap: 2px;
  min-width: 120px;
}

.price-label {
  font-size: 9px;
  text-transform: uppercase;
  letter-spacing: 1px;
  color: rgba(255, 255, 255, 0.35);
  font-weight: 700;
}

.price-value {
  font-size: 18px;
  font-weight: 800;
  color: white;
  font-variant-numeric: tabular-nums;

  &.dim {
    color: rgba(255, 255, 255, 0.5);
    font-weight: 600;
    font-size: 16px;
  }

  &.mortgage {
    color: #f87171;
  }
}

.price-divider {
  width: 1px;
  height: 32px;
  background: rgba(255, 255, 255, 0.1);
}

.offers-list {
  flex: 1;
  min-height: 0;
  overflow-y: auto;
  padding: 0 12px 16px 20px;

  &::-webkit-scrollbar {
    width: 8px;
  }
  &::-webkit-scrollbar-track {
    background: rgba(255, 255, 255, 0.05);
    border-radius: 4px;
  }
  &::-webkit-scrollbar-thumb {
    background: rgba(255, 255, 255, 0.2);
    border-radius: 4px;
  }
  &::-webkit-scrollbar-thumb:hover {
    background: rgba(255, 255, 255, 0.3);
  }
}

.offers-heading {
  margin-bottom: 12px;
}

.offers-count {
  font-size: 10px;
  text-transform: uppercase;
  letter-spacing: 1.2px;
  color: rgba(255, 255, 255, 0.35);
  font-weight: 700;
}

.offer-card {
  background: rgba(255, 255, 255, 0.03);
  border: 1px solid rgba(255, 255, 255, 0.06);
  border-radius: 10px;
  padding: 16px;
  margin-bottom: 12px;
  transition: border-color 0.2s;

  &:hover {
    border-color: rgba(255, 255, 255, 0.12);
  }

  &.underwater {
    border-color: rgba(239, 68, 68, 0.25);
  }
}

.offer-main {
  display: flex;
  justify-content: space-between;
  align-items: flex-start;
  gap: 16px;
  margin-bottom: 14px;
}

.offer-buyer {
  display: flex;
  align-items: center;
  gap: 10px;
  min-width: 0;
  flex: 1;
}

.buyer-avatar {
  width: 36px;
  height: 36px;
  border-radius: 50%;
  background: rgba(255, 255, 255, 0.08);
  display: flex;
  align-items: center;
  justify-content: center;
  font-size: 14px;
  font-weight: 700;
  color: rgba(255, 255, 255, 0.6);
  flex-shrink: 0;
}

.buyer-info {
  display: flex;
  flex-direction: column;
  gap: 1px;
  min-width: 0;
}

.buyer-name {
  font-size: 14px;
  font-weight: 600;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.offer-time {
  font-size: 11px;
  color: rgba(255, 255, 255, 0.35);
}

.offer-price-block {
  flex-shrink: 0;
  min-width: 168px;
  text-align: right;
  display: flex;
  flex-direction: column;
  align-items: flex-end;
  gap: 6px;
}

.offer-price-row {
  display: flex;
  flex-direction: column;
  align-items: flex-end;
  gap: 2px;
}

.offer-price-label {
  font-size: 9px;
  text-transform: uppercase;
  letter-spacing: 1px;
  font-weight: 700;
  color: rgba(255, 255, 255, 0.35);
}

.offer-price-value {
  font-size: 22px;
  font-weight: 800;
  font-variant-numeric: tabular-nums;
  line-height: 1.15;
  letter-spacing: -0.02em;
}

.original-price {
  text-decoration: line-through;
  color: rgba(255, 255, 255, 0.3);
  font-size: 13px;
  font-weight: 600;
  display: block;
}

.negotiated-price {
  display: block;
}

.offer-diff-pill {
  display: inline-flex;
  align-items: center;
  padding: 3px 9px;
  border-radius: 999px;
  font-size: 12px;
  font-weight: 700;
  font-variant-numeric: tabular-nums;
  background: rgba(255, 255, 255, 0.06);
}

.offer-green {
  color: #4ade80;

  &.offer-diff-pill,
  &.offer-price-block .offer-diff-pill {
    color: #4ade80;
    background: rgba(74, 222, 128, 0.14);
  }
}

.offer-yellow {
  color: #facc15;

  &.offer-diff-pill,
  &.offer-price-block .offer-diff-pill {
    color: #facc15;
    background: rgba(250, 204, 21, 0.14);
  }
}

.offer-red {
  color: #f87171;

  &.offer-diff-pill,
  &.offer-price-block .offer-diff-pill {
    color: #f87171;
    background: rgba(248, 113, 113, 0.14);
  }
}

.offer-underwater {
  padding: 12px 14px;
  background: rgba(239, 68, 68, 0.1);
  border: 1px solid rgba(239, 68, 68, 0.28);
  border-radius: 8px;
  margin-bottom: 12px;
}

.underwater-title {
  color: #fca5a5;
  font-size: 13px;
  font-weight: 700;
  margin-bottom: 10px;
}

.underwater-figures {
  display: grid;
  grid-template-columns: repeat(3, minmax(0, 1fr));
  gap: 10px;
}

.underwater-fig {
  display: flex;
  flex-direction: column;
  gap: 2px;
  min-width: 0;
}

.underwater-fig-label {
  font-size: 9px;
  text-transform: uppercase;
  letter-spacing: 0.8px;
  font-weight: 700;
  color: rgba(252, 165, 165, 0.7);
}

.underwater-fig-value {
  font-size: 15px;
  font-weight: 800;
  font-variant-numeric: tabular-nums;
  color: #fecaca;
  letter-spacing: -0.02em;
}

.underwater-fig.short .underwater-fig-value {
  color: #f87171;
}

.offer-actions {
  display: flex;
  gap: 8px;
}

.loading-state, .empty-offers {
  flex-shrink: 0;
  padding: 40px 24px;
  text-align: center;
  color: rgba(255, 255, 255, 0.5);
}

.empty-card {
  background: rgba(255, 255, 255, 0.03);
  border: 1px solid rgba(255, 255, 255, 0.08);
  border-radius: 12px;
  padding: 40px 32px;
  max-width: 400px;
  margin: 0 auto;
}

.empty-icon {
  font-size: 40px;
  margin-bottom: 12px;
}

.empty-text {
  font-size: 18px;
  font-weight: 600;
  color: rgba(255, 255, 255, 0.7);
  margin-bottom: 8px;
}

.empty-desc {
  font-size: 13px;
  color: rgba(255, 255, 255, 0.35);
  line-height: 1.5;
}

.btn {
  padding: 10px 14px;
  border: none;
  border-radius: 8px;
  font-size: 12px;
  font-weight: 700;
  font-family: inherit;
  cursor: pointer;
  transition: opacity 0.15s ease, transform 0.1s ease;
  color: white;

  &:hover:not(:disabled) { opacity: 0.85; }
  &:active:not(:disabled) { transform: scale(0.97); }
  &:disabled {
    opacity: 0.4;
    cursor: not-allowed;
  }
}

.btn-accept {
  flex: 1.2;
  background: #22c55e;
}

.btn-blocked {
  flex: 1.2;
  background: rgba(239, 68, 68, 0.15);
  color: rgba(252, 165, 165, 0.9);
  border: 1px solid rgba(239, 68, 68, 0.3);
  cursor: not-allowed;
}

.btn-negotiate {
  flex: 1;
  background: rgba(255, 255, 255, 0.08);
  border: 1px solid rgba(255, 255, 255, 0.12);

  &:hover:not(:disabled) {
    background: rgba(255, 255, 255, 0.14);
  }
}

.btn-decline {
  flex: 1;
  background: rgba(239, 68, 68, 0.12);
  color: rgba(239, 68, 68, 0.85);
  border: 1px solid rgba(239, 68, 68, 0.2);

  &:hover:not(:disabled) {
    background: rgba(239, 68, 68, 0.2);
  }
}
</style>
