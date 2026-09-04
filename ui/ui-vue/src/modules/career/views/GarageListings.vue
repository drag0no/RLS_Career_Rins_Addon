<template>
  <ComputerWrapper title="Garage Listings" back @back="goBack">
    <div class="listings-panel">
      <!-- Subtitle -->
      <div class="panel-header">
        <p class="panel-subtitle">Manage your properties and listings</p>
      </div>

        <!-- Loading -->
        <div v-if="loading" class="loading-state">
          <span>Loading properties...</span>
        </div>

        <!-- Empty State -->
        <div v-else-if="garages.length === 0" class="empty-state">
          <span>You don't own any properties yet.</span>
        </div>

        <!-- Garage Cards -->
        <div v-else class="garages-grid">
          <div
            v-for="garage in garages"
            :key="garage.garageId"
            class="garage-card"
            :class="{ 'is-listed': garage.isListed }"
          >
            <!-- Preview Image -->
            <div class="card-preview">
              <img v-if="garage.preview" :src="garage.preview" alt="" class="card-img" />
              <div v-else class="card-img-placeholder"></div>
              <div class="card-fade"></div>

              <div class="card-badges">
                <span v-if="garage.canReclaim" class="tag starter">RECLAIM</span>
                <span v-if="garage.isRented" class="tag rented">RENTED</span>
                <span v-if="garage.isStarter" class="tag starter">STARTER</span>
                <span v-else-if="garage.isGranted" class="tag starter">GRANTED</span>
                <span v-if="garage.isListed" class="tag listed">LISTED</span>
                <span v-if="garage.offerCount > 0" class="tag offers">
                  {{ garage.offerCount }} {{ garage.offerCount === 1 ? 'OFFER' : 'OFFERS' }}
                </span>
              </div>

              <div class="card-price" v-if="garage.isListed">
                ${{ formatPrice(garage.askingPrice) }}
              </div>
            </div>

            <!-- Card Body -->
            <div class="card-body">
              <div class="card-info">
                <h2 class="card-name">{{ garage.name }}</h2>
                <div class="card-location" v-if="garage.neighborhood">
                  <svg width="11" height="11" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5"><circle cx="12" cy="10" r="3"/><path d="M12 21.7C17.3 17 20 13 20 10a8 8 0 10-16 0c0 3 2.7 7 8 11.7z"/></svg>
                  {{ garage.neighborhood }}
                </div>
              </div>

              <div class="card-details">
                <div class="detail-chip">
                  <span class="chip-label">Capacity</span>
                  <span class="chip-value">{{ garage.capacity }}</span>
                </div>
                <div class="detail-chip">
                  <span class="chip-label">Vehicles</span>
                  <span class="chip-value">{{ garage.vehicleCount }}</span>
                </div>
                <div class="detail-chip">
                  <span class="chip-label">Market Value</span>
                  <span class="chip-value money">${{ formatPrice(garage.marketValue) }}</span>
                </div>
              </div>

              <!-- Reclaim previously granted property -->
              <div v-if="garage.canReclaim" class="card-actions">
                <button
                  class="btn btn-list-start"
                  @click="confirmReclaim(garage)"
                >
                  Reclaim Free
                </button>
                <div class="starter-notice">
                  You moved out earlier — reclaim access at no cost.
                </div>
              </div>

              <!-- Rented: show status only (cannot list for sale) -->
              <div v-else-if="garage.isRented" class="card-actions">
                <div class="rented-note">Rented property — cannot list for sale.</div>
              </div>

              <!-- Listed State: show offers button + remove listing -->
              <div v-else-if="garage.isListed" class="card-actions">
                <button
                  class="btn btn-offers"
                  @click="viewOffers(garage)"
                >
                  View Offers
                  <span v-if="garage.offerCount > 0" class="offer-badge">{{ garage.offerCount }}</span>
                </button>
                <button class="btn btn-remove" @click="removeListing(garage)">
                  Remove Listing
                </button>
              </div>

              <!-- Granted / unpaid ownership: Move out instead of selling -->
              <div v-else-if="garage.isGranted" class="card-actions">
                <button
                  class="btn btn-list-start"
                  :disabled="!garage.canMoveOut"
                  :title="moveOutTitle(garage)"
                  @click="confirmMoveOut(garage)"
                >
                  Move Out
                </button>
                <div v-if="!garage.canMoveOut && garage.vehicleCount > 0" class="cant-list-hint">
                  {{ garage.vehicleCount }} vehicle{{ garage.vehicleCount !== 1 ? 's' : '' }} still in garage
                </div>
                <div v-else class="starter-notice">
                  No refund — you'll give up access to this property.
                </div>
              </div>

              <!-- Not Listed: show listing form -->
              <div v-else class="card-actions">
                <!-- Listing Form (expanded) -->
                <div v-if="expandedGarage === garage.garageId" class="listing-form">
                  <div class="form-row">
                    <label class="form-label">Asking Price</label>
                    <div class="price-stepper">
                      <div class="step-buttons left">
                        <button class="step-btn" @click="adjustPrice(-10000, garage)">-10,000</button>
                        <button class="step-btn" @click="adjustPrice(-1000, garage)">-1,000</button>
                        <button class="step-btn" @click="adjustPrice(-100, garage)">-100</button>
                      </div>
                      <div class="price-input-wrap">
                        <span class="currency-sign">$</span>
                        <input
                          ref="priceInputRef"
                          type="number"
                          class="price-input"
                          v-model.number="listingPrice"
                          v-bng-text-input
                          :placeholder="garage.marketValue"
                          min="1000"
                          @keydown.stop @keyup.stop @keypress.stop
                          @input="updateGuidance(garage)"
                        />
                      </div>
                      <div class="step-buttons right">
                        <button class="step-btn" @click="adjustPrice(100, garage)">+100</button>
                        <button class="step-btn" @click="adjustPrice(1000, garage)">+1,000</button>
                        <button class="step-btn" @click="adjustPrice(10000, garage)">+10,000</button>
                      </div>
                    </div>
                  </div>

                  <!-- Price Guidance -->
                  <div v-if="priceGuidance" class="price-guidance" :class="guidanceClass">
                    <div class="guidance-bar">
                      <div class="guidance-fill" :style="{ width: guidanceWidth }"></div>
                    </div>
                    <div class="guidance-label">{{ priceGuidance.label }}</div>
                    <div class="guidance-desc">{{ priceGuidance.description }}</div>
                  </div>

                  <div class="form-buttons">
                    <button class="btn btn-list" @click="confirmListing(garage)" :disabled="!listingPrice || listingPrice <= 0">
                      List for Sale
                    </button>
                    <button class="btn btn-cancel-form" @click="expandedGarage = null">
                      Cancel
                    </button>
                  </div>
                </div>

                <!-- Collapsed: List button -->
                <div v-else>
                  <button
                    class="btn btn-list-start"
                    :disabled="!garage.canSell"
                    :title="!garage.canSell ? (garage.vehicleCount > 0 ? 'Remove all vehicles from this garage first' : 'Cannot sell this garage') : ''"
                    @click="startListing(garage)"
                  >
                    List for Sale
                  </button>
                  <div v-if="!garage.canSell && garage.vehicleCount > 0" class="cant-list-hint">
                    {{ garage.vehicleCount }} vehicle{{ garage.vehicleCount !== 1 ? 's' : '' }} still in garage
                  </div>
                </div>
              </div>
            </div>
          </div>
        </div>

    </div>
  </ComputerWrapper>
</template>

<script setup>
import { ref, nextTick, onMounted, onUnmounted } from 'vue'
import { lua } from '@/bridge'
import { useEvents } from '@/services/events'
import { openConfirmation } from '@/services/popup'
import { vBngTextInput } from '@/common/directives'
import ComputerWrapper from './ComputerWrapper.vue'

const events = useEvents()

const garages = ref([])
const loading = ref(true)
const expandedGarage = ref(null)
const listingPrice = ref(null)
const priceGuidance = ref(null)
const priceInputRef = ref(null)

const formatPrice = (value) => {
  if (value === null || value === undefined) return '0'
  return Math.floor(value).toLocaleString('en-US')
}

const guidanceClass = ref('')
const guidanceWidth = ref('50%')

const loadGarages = async () => {
  loading.value = true
  try {
    const data = await lua.career_modules_garageManager.getOwnedGaragesListingData()
    garages.value = data || []
  } catch (e) {
    garages.value = []
  }
  loading.value = false
}

const startListing = (garage) => {
  expandedGarage.value = garage.garageId
  listingPrice.value = garage.marketValue
  priceGuidance.value = null
  updateGuidance(garage)
  nextTick(() => {
    if (priceInputRef.value) priceInputRef.value.focus()
  })
}

const adjustPrice = (amount, garage) => {
  const newPrice = Math.max(1000, (listingPrice.value || 0) + amount)
  listingPrice.value = newPrice
  updateGuidance(garage)
}

const updateGuidance = async (garage) => {
  if (!listingPrice.value || listingPrice.value <= 0) {
    priceGuidance.value = null
    return
  }
  try {
    const data = await lua.career_modules_garageManager.getGarageListingPriceGuidance(garage.computerId, listingPrice.value)
    if (data) {
      priceGuidance.value = data
      const ratio = data.marketRatio || 1
      if (ratio < 0.98) {
        guidanceClass.value = 'guidance-low'
        guidanceWidth.value = Math.max(10, ratio * 50) + '%'
      } else if (ratio <= 1.10) {
        guidanceClass.value = 'guidance-fair'
        guidanceWidth.value = '60%'
      } else if (ratio <= 1.30) {
        guidanceClass.value = 'guidance-high'
        guidanceWidth.value = '80%'
      } else {
        guidanceClass.value = 'guidance-extreme'
        guidanceWidth.value = '95%'
      }
    }
  } catch (e) {
    priceGuidance.value = null
  }
}

const confirmListing = async (garage) => {
  if (!listingPrice.value || listingPrice.value <= 0) return
  await lua.career_modules_garageManager.listGarageForSale(garage.computerId, listingPrice.value)
  expandedGarage.value = null
  listingPrice.value = null
  priceGuidance.value = null
  await loadGarages()
}

const removeListing = async (garage) => {
  await lua.career_modules_realEstateNegotiation.removePropertyListing(garage.garageId)
  await loadGarages()
}

const moveOutTitle = (garage) => {
  if (garage?.canMoveOut) return 'Give up access with no refund'
  if (garage?.vehicleCount > 0) return 'Remove all vehicles from this garage first'
  return 'Cannot move out of this garage'
}

const confirmMoveOut = async (garage) => {
  if (!garage?.canMoveOut || !garage?.garageId) return
  const ok = await openConfirmation(
    'Move Out',
    `Move out of ${garage.name || 'this garage'}?\n\nYou will lose access with no refund. You can reclaim it for free later from Real Estate.`
  )
  if (!ok) return
  await lua.career_modules_garageManager.moveOutOfGarage(garage.garageId)
  await loadGarages()
}

const confirmReclaim = async (garage) => {
  if (!garage?.canReclaim || !garage?.garageId) return
  const ok = await openConfirmation(
    'Reclaim Garage',
    `Reclaim ${garage.name || 'this garage'} for free?`
  )
  if (!ok) return
  await lua.career_modules_garageManager.reclaimGrantedGarage(garage.garageId)
  await loadGarages()
}

const viewOffers = (garage) => {
  lua.extensions.ui_router.navigate('garage-offers', { garageId: garage.garageId })
}

const goBack = () => {
  lua.extensions.ui_router.back()
}

onMounted(() => {
  events.on('garageListingsUpdated', loadGarages)
  loadGarages()
})

onUnmounted(() => {
  events.off('garageListingsUpdated', loadGarages)
})
</script>

<style scoped lang="scss">
.listings-panel {
  color: white;
  background: #0e0e0e;
  height: 100%;
  max-height: 100%;
  border-radius: 0.875rem;
  overflow-y: auto;
  box-sizing: border-box;
  display: flex;
  flex-direction: column;

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

.panel-header {
  flex: 0 0 auto;
  padding: 0.25rem 1.5rem 0;
}

.panel-subtitle {
  font-size: 0.8125rem;
  color: rgba(255, 255, 255, 0.4);
  margin: 0.25rem 0 0;
}

.loading-state, .empty-state {
  padding: 2.5rem 1.5rem;
  text-align: center;
  color: rgba(255, 255, 255, 0.5);
  font-size: 0.875rem;
}

.garages-grid {
  flex: 1 1 auto;
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(22rem, 1fr));
  gap: 1rem;
  padding: 1.25rem 1.5rem;
  align-content: start;
}

.garage-card {
  background: rgba(255, 255, 255, 0.03);
  border: 1px solid rgba(255, 255, 255, 0.06);
  border-radius: 0.75rem;
  overflow: hidden;
  transition: border-color 0.2s ease;
  display: flex;
  flex-direction: column;
  min-width: 0;

  &:hover {
    border-color: rgba(255, 255, 255, 0.12);
  }

  &.is-listed {
    border-color: rgba(249, 115, 22, 0.25);
  }
}

.card-preview {
  position: relative;
  width: 100%;
  aspect-ratio: 16 / 9;
  height: auto;
  flex: 0 0 auto;
  background: #000;
  overflow: hidden;
}

.card-img {
  width: 100%;
  height: 100%;
  object-fit: cover;
  display: block;
}

.card-img-placeholder {
  width: 100%;
  height: 100%;
  background: linear-gradient(135deg, #1a1a1a, #0a0a0a);
}

.card-fade {
  position: absolute;
  bottom: 0;
  left: 0;
  right: 0;
  height: 60px;
  background: linear-gradient(to top, rgba(14, 14, 14, 0.95), transparent);
  pointer-events: none;
}

.card-badges {
  position: absolute;
  top: 10px;
  left: 10px;
  display: flex;
  gap: 6px;
}

.tag {
  font-size: 9px;
  font-weight: 700;
  padding: 3px 8px;
  border-radius: 4px;
  letter-spacing: 0.6px;

  &.starter {
    background: rgba(255, 255, 255, 0.12);
    color: rgba(255, 255, 255, 0.7);
  }
  &.rented {
    background: rgba(59, 130, 246, 0.85);
    color: white;
  }
  &.listed {
    background: rgba(249, 115, 22, 0.85);
    color: white;
  }
  &.offers {
    background: rgba(34, 197, 94, 0.85);
    color: white;
  }
}

.rented-note {
  width: 100%;
  font-size: 12px;
  color: rgba(255, 255, 255, 0.55);
  padding: 8px 0 0;
}

.card-price {
  position: absolute;
  bottom: 10px;
  right: 14px;
  font-size: 20px;
  font-weight: 800;
  color: white;
  text-shadow: 0 2px 8px rgba(0, 0, 0, 0.9);
}

.card-body {
  padding: 0.875rem 1rem 1rem;
  display: flex;
  flex-direction: column;
  flex: 1 1 auto;
  min-height: 0;
}

.card-info {
  margin-bottom: 12px;
}

.card-name {
  font-size: 17px;
  font-weight: 700;
  margin: 0;
  line-height: 1.2;
}

.card-location {
  display: flex;
  align-items: center;
  gap: 4px;
  color: rgba(255, 255, 255, 0.45);
  font-size: 12px;
  margin-top: 3px;
}

.card-details {
  display: flex;
  gap: 10px;
  margin-bottom: 14px;
}

.detail-chip {
  background: rgba(255, 255, 255, 0.04);
  border: 1px solid rgba(255, 255, 255, 0.06);
  border-radius: 8px;
  padding: 6px 10px;
  display: flex;
  flex-direction: column;
  gap: 2px;
}

.chip-label {
  font-size: 9px;
  text-transform: uppercase;
  letter-spacing: 0.8px;
  color: rgba(255, 255, 255, 0.35);
  font-weight: 700;
}

.chip-value {
  font-size: 13px;
  font-weight: 600;
  color: white;

  &.money {
    font-variant-numeric: tabular-nums;
    color: #4caf50;
  }
}

.card-actions {
  display: flex;
  flex-direction: column;
  gap: 8px;
}

// Listing form styles
.listing-form {
  display: flex;
  flex-direction: column;
  gap: 12px;
  padding: 12px;
  background: rgba(255, 255, 255, 0.02);
  border: 1px solid rgba(255, 255, 255, 0.06);
  border-radius: 10px;
}

.form-row {
  display: flex;
  flex-direction: column;
  gap: 4px;
}

.form-label {
  font-size: 10px;
  text-transform: uppercase;
  letter-spacing: 1px;
  color: rgba(255, 255, 255, 0.4);
  font-weight: 700;
}

.price-stepper {
  display: flex;
  align-items: center;
  gap: 8px;
}

.step-buttons {
  display: flex;
  gap: 4px;

  &.left { flex-direction: row; }
  &.right { flex-direction: row; }
}

.step-btn {
  background: rgba(255, 255, 255, 0.08);
  border: 1px solid rgba(255, 255, 255, 0.12);
  border-radius: 6px;
  color: rgba(255, 255, 255, 0.7);
  font-size: 12px;
  font-weight: 600;
  padding: 6px 10px;
  cursor: pointer;
  white-space: nowrap;
  transition: all 0.15s ease;

  &:hover {
    background: rgba(255, 255, 255, 0.14);
    color: white;
  }

  &:active {
    background: rgba(249, 115, 22, 0.3);
    border-color: rgba(249, 115, 22, 0.5);
  }
}

.price-input-wrap {
  display: flex;
  align-items: center;
  background: rgba(0, 0, 0, 0.4);
  border: 1px solid rgba(255, 255, 255, 0.12);
  border-radius: 8px;
  padding: 0 12px;
  flex: 1;
  min-width: 140px;
  transition: border-color 0.2s;

  &:focus-within {
    border-color: rgba(249, 115, 22, 0.5);
  }
}

.currency-sign {
  font-size: 16px;
  font-weight: 700;
  color: rgba(255, 255, 255, 0.5);
  margin-right: 6px;
}

.price-input {
  flex: 1;
  background: none;
  border: none;
  outline: none;
  color: white;
  font-size: 18px;
  font-weight: 700;
  padding: 10px 0;
  font-family: inherit;
  font-variant-numeric: tabular-nums;

  &::placeholder {
    color: rgba(255, 255, 255, 0.2);
  }

  &::-webkit-inner-spin-button,
  &::-webkit-outer-spin-button {
    -webkit-appearance: none;
    margin: 0;
  }
}

// Price guidance
.price-guidance {
  padding: 10px;
  border-radius: 8px;
  background: rgba(255, 255, 255, 0.02);

  &.guidance-low {
    border-left: 3px solid #3b82f6;
    .guidance-label { color: #3b82f6; }
    .guidance-fill { background: #3b82f6; }
  }
  &.guidance-fair {
    border-left: 3px solid #22c55e;
    .guidance-label { color: #22c55e; }
    .guidance-fill { background: #22c55e; }
  }
  &.guidance-high {
    border-left: 3px solid #eab308;
    .guidance-label { color: #eab308; }
    .guidance-fill { background: #eab308; }
  }
  &.guidance-extreme {
    border-left: 3px solid #ef4444;
    .guidance-label { color: #ef4444; }
    .guidance-fill { background: #ef4444; }
  }
}

.guidance-bar {
  height: 4px;
  background: rgba(255, 255, 255, 0.06);
  border-radius: 2px;
  margin-bottom: 8px;
  overflow: hidden;
}

.guidance-fill {
  height: 100%;
  border-radius: 2px;
  transition: width 0.3s ease, background 0.3s ease;
}

.guidance-label {
  font-size: 12px;
  font-weight: 700;
  letter-spacing: 0.3px;
  margin-bottom: 2px;
}

.guidance-desc {
  font-size: 11px;
  color: rgba(255, 255, 255, 0.45);
}

.form-buttons {
  display: flex;
  gap: 8px;
}

.cant-list-hint {
  font-size: 11px;
  color: rgba(239, 68, 68, 0.7);
  margin-top: 4px;
  padding-left: 2px;
}

.starter-notice {
  font-size: 12px;
  color: rgba(255, 255, 255, 0.3);
  padding: 8px 0;
}

// Buttons
.btn {
  padding: 10px 16px;
  border: none;
  border-radius: 8px;
  font-size: 12px;
  font-weight: 700;
  font-family: inherit;
  cursor: pointer;
  transition: opacity 0.15s ease, transform 0.1s ease;
  color: white;
  text-align: center;

  &:hover:not(:disabled) { opacity: 0.85; }
  &:active:not(:disabled) { transform: scale(0.97); }
  &:disabled {
    opacity: 0.35;
    cursor: not-allowed;
  }
}

.btn-offers {
  flex: 1;
  background: #f97316;
  display: flex;
  align-items: center;
  justify-content: center;
  gap: 6px;
}

.offer-badge {
  background: rgba(255, 255, 255, 0.25);
  font-size: 10px;
  padding: 2px 7px;
  border-radius: 10px;
  font-weight: 700;
}

.btn-remove {
  background: rgba(239, 68, 68, 0.12);
  color: rgba(239, 68, 68, 0.85);
  border: 1px solid rgba(239, 68, 68, 0.2);

  &:hover:not(:disabled) {
    background: rgba(239, 68, 68, 0.2);
  }
}

.btn-list-start {
  width: 100%;
  background: rgba(255, 255, 255, 0.08);
  border: 1px solid rgba(255, 255, 255, 0.12);

  &:hover:not(:disabled) {
    background: rgba(255, 255, 255, 0.14);
  }
}

.btn-list {
  flex: 1;
  background: #f97316;
}

.btn-cancel-form {
  background: rgba(255, 255, 255, 0.06);
  color: rgba(255, 255, 255, 0.5);
  border: 1px solid rgba(255, 255, 255, 0.08);
}

/* footer removed - ComputerWrapper handles back */
</style>
