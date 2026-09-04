<template>
  <div class="center-wrap">
    <BngCard bng-ui-scope="vehicleNegotiation" class="negotiation-screen" v-bng-blur="1">
      <div class="header-row">
        <BngCardHeading type="ribbon">
          Negotiation with {{ state.opponentName || opponent }}
          <div v-if="state.opponentQuote" class="header-seller-info">
            "{{ state.opponentQuote }}"
          </div>
        </BngCardHeading>
        <BngButton class="close-button" :disabled="acceptancePending" @click="closeNegotiation" :accent="ACCENTS.attention" bng-no-nav="true" tabindex="-1">
          <BngBinding ui-event="menu" controller />
          <BngIcon
            type="xmarkBold"
            :color="'var(--bng-cool-gray-100)'"
          />

        </BngButton>
      </div>

      <div class="main-content">
        <!-- Top summary could show vehicle info when available -->
        <div class="summary">
          <div class="vehicle-info" v-if="state.vehicleNiceName || state.vehicleThumbnail">
            <!--
            <img
              v-if="state.vehicleThumbnail"
              class="vehicle-thumb"
              :src="state.vehicleThumbnail"
              :alt="state.vehicleNiceName || 'Vehicle thumbnail'"
            >
          -->
            <div class="purchase-row">
              <div class="label">
                <div>{{ state.vehicleNiceName || 'Vehicle' }}</div>
                <div class="sub-info">{{ formatMileage(state.vehicleMileage) }}</div>
              </div>
              <div class="price">
                <template v-if="!state.hideMarketValue">
                  Est. Market:
                </template>
                <template v-else>
                  Make the first offer
                </template>
                <div v-if="!state.hideMarketValue">
                  <BngUnit class="money" :money="state.actualVehicleValue || 0" />
                </div>
              </div>
            </div>
          </div>
        </div>

        <!-- Two column panels - ->
        <div class="columns">
          <div class="panel left">
            <div class="panel-title">Your offer</div>
            <div class="info-row"><span class="row-label">Your Current Offer</span><span class="row-value">{{ state.myOffer != null ? units.beamBucks(state.myOffer) : "(Not set)" }}</span></div>
          </div>
          <div class="panel right">
            <div class="panel-title">{{ opponent }}'s offer</div>
            <div class="info-row"><span class="row-label">Their current offer</span><span class="row-value highlight">{{ units.beamBucks(state.theirOffer || 0) }}</span></div>
            <div class="info-row small"><span class="row-label">Difference From Starting Price</span><span class="row-value" :class="{pos: isDiffTheirOfferToStartingGood, neg: !isDiffTheirOfferToStartingGood  }">{{ units.beamBucks(diffTheirOfferToStarting) }}</span></div>
          </div>
        </div>
        -->

        <div v-if="awaitingOpeningOffer" class="opening-offer-panel">
          <div class="opening-title">Make an Opening Offer</div>
          <div class="opening-subtitle">The seller has not named a price. Your first number sets the tone.</div>
          <div class="opening-input-row">
            <button class="opening-step" @click="nudgeOpeningOffer(-5000)">-5000</button>
            <button class="opening-step" @click="nudgeOpeningOffer(-500)">-500</button>
            <input
              class="opening-input"
              :value="openingOfferText"
              type="text"
              inputmode="numeric"
              bng-no-nav="true"
              @input="onOpeningOfferInput"
              @focus="onOpeningInputFocus"
              @blur="onOpeningInputBlur"
              @keydown.stop
              @keyup.stop
              @keypress.stop
              v-bng-text-input>
            <button class="opening-step" @click="nudgeOpeningOffer(500)">+500</button>
            <button class="opening-step" @click="nudgeOpeningOffer(5000)">+5000</button>
          </div>
        </div>

        <div v-else class="offer-container">
          <NegotiationChat
            ref="negotiationChat"
            :offer-history="state.offerHistory || []"
            :negotiation-status="state.negotiationStatus"
            :starting-price="state.startingPrice || 0"
            :am-i-selling="state.amISelling"
          />

          <PriceFinder
            v-if="!state.hideMarketValue"
            :offer-history="state.offerHistory || []"
            :negotiation-status="state.negotiationStatus"
            :starting-price="state.startingPrice || 0"
            :offer-preview="offerPreview || 0"
            :actual-vehicle-value="state.actualVehicleValue"
            :am-i-selling="state.amISelling"
          />
        </div>

        <div class="patience">

          <div class="bar" :class="patienceClass">
            <div class="separator" style="left: 33.0%"></div>
            <div class="separator" style="left: 66.0%"></div>
            <div class="fill" :class="patienceClass" :style="{ width: Math.max(0, Math.min(1, state.patience || 0)) * 100 + '%' }"></div>
          </div>
          <div class="label-row">
            <span>{{ opponent }}'s Patience</span>
          </div>
        </div>


        <!-- Big price offer-controls -->
        <div class="offer-controls">
          <div class="offer-controls-row" v-if="!awaitingOpeningOffer && state.negotiationStatus !== 'failed' && state.negotiationStatus !== 'accepted'">
            <div class="step-buttons-group">
              <BngButton class="step step-large" :disabled="offerDisabled || decreaseOfferDisabled" @click="nudgeOffer(-5000)">-5000</BngButton>
              <BngButton class="step step-medium" :disabled="offerDisabled || decreaseOfferDisabled" @click="nudgeOffer(-500)">-500</BngButton>
              <BngButton class="step" :disabled="offerDisabled || decreaseOfferDisabled" @click="nudgeOffer(-50)">-50</BngButton>

              <BngButton class="step" :disabled="offerDisabled || increaseOfferDisabled" @click="nudgeOffer(50)">+50</BngButton>
              <BngButton class="step step-medium" :disabled="offerDisabled || increaseOfferDisabled" @click="nudgeOffer(500)">+500</BngButton>
              <BngButton class="step step-large" :disabled="offerDisabled || increaseOfferDisabled" @click="nudgeOffer(5000)">+5000</BngButton>
            </div>
          </div>

          <div class="offer-controls-row" v-if="state.negotiationStatus === 'failed' || state.negotiationStatus === 'accepted'" :class="{ accepted: state.negotiationStatus === 'accepted' && !state.purchaseFailureReason, failed: state.negotiationStatus === 'failed', 'purchase-failed': !!state.purchaseFailureReason }">
            <BngIcon :type="resolvedIconType" class="resolved-negotiation-icon" />

            <div class="resolved-negotiation-message" >{{resolvedStatusText}}</div>
          </div>

          <div class="price-column" >
            <div class="price" v-if="noDeal">
              NO DEAL
            </div>
            <div v-else class="price">
              {{ units.beamBucks(offerPreview || 0) }}
            </div>
            <div v-if="awaitingOpeningOffer" class="opening-preview">Opening offer</div>
            <div v-if="!state.hideMarketValue && diffOfferPreviewToStarting !== null" class="diff-percent-offer-preview-to-starting" :class="{ positive: isDiffOfferPreviewToStartingGood && diffOfferPreviewToStarting !== 0, negative: !isDiffOfferPreviewToStartingGood && diffOfferPreviewToStarting !== 0, zero: diffOfferPreviewToStarting === 0, 'hidden': noDeal }">
              <BngUnit v-if="diffOfferPreviewToStarting !== 0" class="money" :money="Math.abs(diffOfferPreviewToStarting)" /> {{ diffOfferPreviewToStarting < 0 ? 'under' : diffOfferPreviewToStarting > 0 ? 'over' : 'Same as' }} starting price
            </div>
            <div v-if="!state.hideMarketValue && diffPercentOfferPreviewToMarket !== null" class="diff-percent-offer-preview-to-market" :class="{ positive: isDiffPercentOfferPreviewToMarketGood, negative: !isDiffPercentOfferPreviewToMarketGood, 'hidden': noDeal }">
              {{ Math.abs(diffPercentOfferPreviewToMarket) }}% {{ diffPercentOfferPreviewToMarket < 0 ? 'under' : 'over' }} Est. Market value
            </div>
          </div>
        </div>

        <!-- Status + primary action box -->
        <!--
        <div class="decision-box" :class="{ accepted: state.negotiationStatus === 'accepted', rejected: isRejected }">
          <div class="status-line">
            <span class="label">Status: </span>
            <span class="value">{{ statusText }}</span>
            <span v-if="state.negotiationStatus === 'thinking'" class="spinner" aria-label="Thinking"></span>
          </div>
          <div class="actions">
            <div v-if="state.negotiationStatus === 'accepted' || state.negotiationStatus === 'counterOffer' || state.negotiationStatus === 'counterOfferLastChance'">
              {{ units.beamBucks(state.theirOffer || 0) }}
              <BngButton :accent="ACCENTS.secondary" @click="takeOffer">Accept</BngButton>
            </div>
          </div>
        </div>
        -->
      </div>

      <template #buttons>
        <div class="action-buttons wide">
          <BngButton
            v-if="awaitingOpeningOffer"
            class="submit-offer"
            :disabled="openingOfferDisabled"
            @click="submitOpeningOffer()"
            :accent="ACCENTS.primary"
          >
            Send Opening Offer
          </BngButton>
          <BngButton
            v-else-if="state.negotiationStatus !== 'accepted' && state.negotiationStatus !== 'failed'"
            class="submit-offer"
            :disabled="state.negotiationStatus === 'counterOfferLastChance' || offerPreview == state.theirOffer || offerPreview == state.myOffer || offerDisabled"
            @click="submitOffer()"
            :accent="ACCENTS.secondary"
          >
            Submit This Offer
          </BngButton>
          <BngButton
            v-if="state.negotiationStatus !== 'accepted' && state.negotiationStatus !== 'failed'"
            class="submit-offer"
            :disabled="state.negotiationStatus === 'counterOfferLastChance' || offerDisabled || !state.hasVisibleTheirOffer"
            show-hold
            v-bng-click="{ holdCallback: takeOffer, holdDelay: 1000, repeatInterval: 0 }"
          >
            Agree to their Price
          </BngButton>

          <BngButton v-if="state.negotiationStatus === 'failed' || state.negotiationStatus === 'accepted'" class="go-back" :disabled="acceptancePending" :accent="ACCENTS.primary" @click="goBack">
            {{ resolvedActionText }}
          </BngButton>
        </div>
      </template>
    </BngCard>
  </div>

</template>

<script setup>
import { computed, onMounted, onUnmounted, ref, watch, nextTick } from "vue"
import { BngButton, ACCENTS, BngCard, BngCardHeading, BngBinding, BngUnit, BngIcon } from "@/common/components/base"
import { lua, useBridge } from "@/bridge"
import { vBngOnUiNav, vBngBlur, vBngClick, vBngTextInput } from "@/common/directives"
import { useUINavScope } from "@/services/uiNav"
import { useEvents } from '@/services/events'
import NegotiationChat from "@/modules/career/components/vehicleShopping/NegotiationChat.vue"
import PriceFinder from "@/modules/career/components/vehicleShopping/PriceFinder.vue"
useUINavScope("vehicleNegotiation")

const { units } = useBridge()
const events = useEvents()

const state = ref({
  active: false,
  startingPrice: 0,
  patience: 0,
  myOffer: null,
  theirOffer: 0,
  thinking: false,
  status: "",
  negotiationStatus: "",
  opponentName: "",
  vehicleNiceName: "",
  vehicleThumbnail: "",
  amISelling: false,
  hideMarketValue: false,
  playerStartsNegotiation: false,
  hasVisibleTheirOffer: true,
  purchaseAfterAccept: false,
  purchaseFailureReason: null,
  returnRoute: "play",
  returnParams: {}
})

const opponent = computed(() => state.value.amISelling ? "Buyer" : "Seller")
const biggerIsBetter = computed(() => state.value.amISelling ? true : false)

const increaseOfferDisabled = computed(() => {
  if (state.value.amISelling) {
    return (state.value.myOffer != null && (offerPreview.value >= state.value.myOffer))
  } else {
    if (!state.value.hasVisibleTheirOffer) return false
    return offerPreview.value >= state.value.theirOffer
  }
})

const decreaseOfferDisabled = computed(() => {
  if (state.value.amISelling) {
    console.log("decreaseOfferDisabled", offerPreview.value, state.value.theirOffer)
    return offerPreview.value <= state.value.theirOffer
  } else {
    if (!state.value.hasVisibleTheirOffer) {
      return state.value.myOffer != null && offerPreview.value <= state.value.myOffer
    }
    return (state.value.myOffer != null && (offerPreview.value <= state.value.myOffer))
  }
})

const offerPreview = ref(0)
const openingOffer = ref(null)
const openingOfferText = ref("0")
const openingOfferTouched = ref(false)
// A spawned listing must sync its live part conditions before Lua can finish the sale.
// Lock every action that could submit or leave the negotiation until that result arrives.
const acceptancePending = ref(false)
const awaitingOpeningOffer = computed(() => {
  return state.value.playerStartsNegotiation && state.value.myOffer == null && !state.value.hasVisibleTheirOffer && state.value.negotiationStatus !== 'failed' && state.value.negotiationStatus !== 'accepted'
})
const openingOfferDisabled = computed(() => !(Number(openingOffer.value) > 0) || offerDisabled.value)
const stepSize = computed(() => {
  const baseStep = state.value.startingPrice / 500
  return Math.round(baseStep / 5) * 5
})

const diffPercentOfferPreviewToStarting = computed(() => {
  const diff = ((offerPreview.value - state.value.startingPrice) / state.value.startingPrice) * 100
  return Math.round(diff)
})

const diffOfferPreviewToStarting = computed(() => {
  return offerPreview.value - state.value.startingPrice
})

const isDiffOfferPreviewToStartingGood = computed(() => {
  return biggerIsBetter.value ? diffOfferPreviewToStarting.value >= 0 : diffOfferPreviewToStarting.value <= 0
})

const diffPercentOfferPreviewToMarket = computed(() => {
  if (!state.value.actualVehicleValue || state.value.actualVehicleValue === 0) return null
  const diff = ((offerPreview.value - state.value.actualVehicleValue) / state.value.actualVehicleValue) * 100
  return Math.round(diff)
})

const isDiffPercentOfferPreviewToMarketGood = computed(() => {
  if (diffPercentOfferPreviewToMarket.value === null) return null
  return biggerIsBetter.value ? diffPercentOfferPreviewToMarket.value >= 0 : diffPercentOfferPreviewToMarket.value <= 0
})

const diffTheirOfferToStarting = computed(() => {
  const diff = state.value.theirOffer - state.value.startingPrice
  return diff
})

const isDiffTheirOfferToStartingGood = computed(() => {
  return biggerIsBetter.value ? diffTheirOfferToStarting.value >= 0 : diffTheirOfferToStarting.value <= 0
})

const nudgeOffer = (delta) => {
  const roundedOfferPreview = Math.max(0, Math.round((offerPreview.value + delta) / 50) * 50)

  let min = 0
  let max = Number.POSITIVE_INFINITY

  if (state.value.amISelling) {
    min = state.value.theirOffer
    if ( state.value.myOffer != null ) {
      max = state.value.myOffer
    }
  } else {
    max = state.value.hasVisibleTheirOffer ? state.value.theirOffer : Number.POSITIVE_INFINITY
    if ( state.value.myOffer != null ) {
      min = state.value.myOffer
    }
  }

  offerPreview.value = Math.min(max, Math.max(min, roundedOfferPreview))
}

const nudgeOpeningOffer = delta => {
  const current = Number(openingOffer.value) || 0
  openingOfferTouched.value = true
  openingOffer.value = Math.max(0, Math.round((current + delta) / 50) * 50)
  openingOfferText.value = String(openingOffer.value)
  offerPreview.value = openingOffer.value
}

const onOpeningOfferInput = event => {
  const digits = String(event.target.value || "").replace(/[^\d]/g, "")
  openingOfferText.value = digits
  openingOffer.value = digits === "" ? null : Number(digits)
  openingOfferTouched.value = true
  offerPreview.value = Number(openingOffer.value) || 0
}

const onOpeningInputFocus = event => {
  try { lua.setCEFTyping(true) } catch (_) {}
  if (event?.target?.select) event.target.select()
}

const onOpeningInputBlur = () => {
  try { lua.setCEFTyping(false) } catch (_) {}
}
const offerDisabled = computed(() => {
  if (acceptancePending.value || state.value.negotiationStatus === 'thinking' || state.value.negotiationStatus === 'typing' || state.value.negotiationStatus === 'accepted' || state.value.negotiationStatus === 'failed') {
    return true
  }
  return false
})

const patienceClass = computed(() => {
  const m = state.value.patience ?? 0
  if (m > 0.66) return "patience-good"
  if (m > 0.33) return "patience-mid"
  return "patience-bad"
})

const noDeal = computed(() => {
  if (state.value.purchaseFailureReason) return false
  return state.value.negotiationStatus === 'failed' && (state.value.amISelling || state.value.playerStartsNegotiation)
})

// Derived status helpers for clearer UI logic (use negotiationStatus from Lua)
const isRejected = computed(() => state.value.negotiationStatus === 'failed')

// Human-readable status label from negotiationStatus
const statusText = computed(() => {
  switch (String(state.value.negotiationStatus || '')) {
    case 'counterOffer':
      return 'Counter offer'
    case 'counterOfferLastChance':
      return 'Last chance counter offer'
    case 'accepted':
      return 'Accepted'
    case 'failed':
      return 'Negotiation failed'
    case 'refused':
      return 'Offer refused'
    case 'initial':
      return 'Initial offer'
    case 'thinking':
      return 'Thinking'
    case 'typing':
      return 'Typing...'
    default:
      return ''
  }
})

const resolvedIconType = computed(() => {
  if (state.value.purchaseFailureReason) return 'danger'
  if (state.value.negotiationStatus === 'accepted') return 'checkmark'
  return 'abandon'
})

const resolvedStatusText = computed(() => {
  if (state.value.purchaseFailureReason) {
    return state.value.purchaseFailureReason
  }
  if (state.value.negotiationStatus === 'failed') {
    if (state.value.amISelling) {
      return 'The other party ran out of patience and does not want to buy this vehicle.'
    } else if (state.value.playerStartsNegotiation) {
      return 'The seller ran out of patience and walked away. No deal.'
    } else {
      return 'The other party ran out of patience. You can still buy the vehicle at the starting price: '
    }
  } else if (state.value.negotiationStatus === 'accepted') {
    return 'Congratulations! You\'ve successfully negotiatied a deal with ' + state.value.opponentName +'.'
  }
  return ''
})

const resolvedActionText = computed(() => {
  if (state.value.purchaseFailureReason) {
    return 'Continue'
  }
  if (state.value.negotiationStatus === 'failed') {
    return 'Close'
  }
  if (state.value.amISelling) return 'Continue'
  if (state.value.purchaseAfterAccept) return 'Purchase'
  return 'Go to Purchase Screen'
})

const formatMileage = mileageMeters => {
  const meters = Number(mileageMeters)
  if (!Number.isFinite(meters) || meters <= 0) return "0 mi"
  return `${Math.round(meters / 1609.344).toLocaleString()} mi`
}

const negotiationChat = ref(null)

const appendAcceptedHistory = () => {
  if (!Array.isArray(state.value.offerHistory)) state.value.offerHistory = []
  const last = state.value.offerHistory[state.value.offerHistory.length - 1]
  if (last?.negotiationStatus === 'accepted' && Number(last.myOffer) === Number(state.value.theirOffer)) return
  state.value.offerHistory.push({
    myOffer: state.value.theirOffer,
    negotiationStatus: 'accepted'
  })
}

const markSaleAccepted = () => {
  acceptancePending.value = false
  state.value.negotiationStatus = 'accepted'
  state.value.status = 'accepted'
  state.value.purchaseFailureReason = null
  state.value.iAccepted = true
  offerPreview.value = state.value.theirOffer ?? offerPreview.value
  appendAcceptedHistory()
}

const applyPurchaseFailure = (result) => {
  acceptancePending.value = false
  const reason = result?.reason || 'Purchase could not be completed.'
  state.value.purchaseFailureReason = reason
  // Keep deal accepted; purchase failure is separate from negotiation failure.
  state.value.negotiationStatus = 'accepted'
  state.value.status = 'accepted'
  state.value.iAccepted = false
  offerPreview.value = state.value.theirOffer ?? offerPreview.value
}

const refresh = async (payload) => {
  const s = payload || await lua.career_modules_marketplace.getNegotiationState()
  if (!s) {
    lua.career_career.closeAllMenus()
    return
  }
  const priorHistory = state.value.offerHistory
  state.value = {
    ...state.value,
    ...s,
    purchaseFailureReason: s.purchaseFailureReason ?? state.value.purchaseFailureReason ?? null
  }

  if (s.saleCompleted) {
    markSaleAccepted()
  } else if (state.value.purchaseFailureReason) {
    acceptancePending.value = false
    // The price agreement still succeeded; show the existing resolved failure screen.
    state.value.negotiationStatus = 'accepted'
    state.value.status = 'accepted'
    state.value.iAccepted = false
  }
  if (!s.offerHistory && priorHistory?.length) {
    state.value.offerHistory = priorHistory
  }
  const base = state.value.myOffer != null ? state.value.myOffer : state.value.startingPrice
  if (!awaitingOpeningOffer.value && !Number.isNaN(Number(base))) offerPreview.value = Number(base)
  if (awaitingOpeningOffer.value) {
    if (!openingOfferTouched.value && openingOffer.value == null) {
      openingOffer.value = 0
      openingOfferText.value = "0"
    }
    offerPreview.value = Number(openingOffer.value) || 0
  }

  if (state.value.negotiationStatus === 'failed' && !state.value.purchaseFailureReason) {
    offerPreview.value = state.value.startingPrice
  }
}

const submitOffer = async () => {
  if (acceptancePending.value) return
  const price = Number(offerPreview.value)
  if (!Number.isFinite(price)) return
  await lua.career_modules_marketplace.makeNegotiationOffer(price)
}

const submitOpeningOffer = async () => {
  if (acceptancePending.value) return
  const price = Number(openingOffer.value)
  if (!Number.isFinite(price) || price <= 0) return
  offerPreview.value = price
  openingOfferTouched.value = true
  await lua.career_modules_marketplace.makeNegotiationOffer(price)
}

const takeOffer = async () => {
  if (acceptancePending.value) return
  acceptancePending.value = true

  let result
  try {
    result = await lua.career_modules_marketplace.takeTheirOffer()
  } catch (error) {
    acceptancePending.value = false
    throw error
  }

  if (result?.ok === false || result?.ok === 0) {
    applyPurchaseFailure(result)
    return
  }
  // Lua will emit negotiationData with saleCompleted or purchaseFailureReason after
  // the spawned vehicle's live part-condition sync finishes.
  if (result?.pending) return

  if (!result?.ok && state.value.purchaseAfterAccept) {
    await refresh()
    if (state.value.purchaseFailureReason) {
      return
    }
  }

  markSaleAccepted()
}

const cancel = async () => {
  if(state.value.negotiationStatus !== 'accepted')
    await lua.career_modules_marketplace.cancelNegotiation()
}

const returnToOrigin = async () => {
  const routeName = typeof state.value.returnRoute === "string" && state.value.returnRoute && state.value.returnRoute !== "career.negotiation"
    ? state.value.returnRoute
    : "play"
  const params = state.value.returnParams && typeof state.value.returnParams === "object"
    ? state.value.returnParams
    : {}
  await lua.extensions.ui_router.navigate(routeName, params)
}

const closeNegotiation = async (event) => {
  if (acceptancePending.value) return
  if (state.value.purchaseFailureReason) {
    await lua.career_modules_marketplace.dismissNegotiation()
  } else if (state.value.negotiationStatus === 'accepted' && state.value.purchaseAfterAccept && !state.value.iAccepted) {
    await lua.career_modules_marketplace.dismissNegotiation()
  } else {
    await cancel()
  }
  await returnToOrigin()
  if (event?.stopPropagation) event.stopPropagation()
}

const goBack = async (event) => {
  if (acceptancePending.value) return
  if (state.value.purchaseFailureReason) {
    await lua.career_modules_marketplace.dismissNegotiation()
    await returnToOrigin()
    if (event?.stopPropagation) event.stopPropagation()
    return
  }

  if (state.value.negotiationStatus === 'accepted' && !state.value.iAccepted) {
    await takeOffer()
    if (acceptancePending.value || state.value.purchaseFailureReason || !state.value.iAccepted) return
  }

  if (state.value.purchaseFailureReason) {
    await lua.career_modules_marketplace.dismissNegotiation()
  } else {
    await cancel()
  }
  if (state.value.purchaseAfterAccept && state.value.negotiationStatus === 'accepted') {
    await lua.career_career.closeAllMenus()
  } else {
    await returnToOrigin()
  }
  if (event?.stopPropagation) event.stopPropagation()
}

const start = async () => {
  await refresh()
  nextTick(() => {
    if (negotiationChat.value) {
      negotiationChat.value.reset()
      negotiationChat.value.scrollToBottom()
    }
  })
}

const kill = async () => {
  try { lua.setCEFTyping(false) } catch (_) {}
  events.off("negotiationData")
}

// Lua events
events.on("negotiationData", data => {
  refresh(data)
})


onMounted(start)
onUnmounted(kill)
</script>

<style scoped lang="scss">
.negotiation-screen {
  width: 47.5rem;
  color: white;
  background-color: rgba(0, 0, 0, 0.7);

  & :deep(.card-cnt) {
    background-color: rgba(0, 0, 0, 0.7);
  }

  :deep(.footer-container) {
    display: flex;
    flex-direction: column;
  }
}

.header-row {
  display: flex;
  flex-direction: row;
  justify-content: space-between;
  align-items: flex-end;
  padding-right: 0.5rem;
  border-bottom: 0.06rem solid rgba(255, 255, 255, 0.1);
  background-color: rgba(0, 0, 0, 0.6);
  border-radius: var(--bng-corners-2) var(--bng-corners-2) 0 0;
  min-height: 3.6rem;

  > * {
    line-height: 1.2;
  }

  .header-seller-info {
    margin-top: 0rem;
    font-size: 0.88rem;
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

.center-wrap {
  position: fixed;
  inset: 0;
  display: flex;
  align-items: center;
  justify-content: center;
  padding: 5rem;
}

.thinking {
  font-size: 1.2rem;
  padding: 1rem 0;
}

.spinner {
  display: inline-block;
  width: 1rem;
  height: 1rem;
  margin-left: 0.5rem;
  border: 0.13rem solid rgba(255, 255, 255, 0.3);
  border-top-color: #ffffff;
  border-radius: 50%;
  animation: spinner-rotate 0.8s linear infinite;
  vertical-align: middle;
}

@keyframes spinner-rotate {
  to {
    transform: rotate(360deg);
  }
}

.main-content {
  display: flex;
  flex-direction: column;
  gap: 1rem;
  padding: 1rem;
}


.summary {
  display: flex;
  flex-direction: column;

  .title {
    font-weight: 800;
    letter-spacing: 0.03rem;
  }
}

.vehicle-info {
  .purchase-row {
    display: flex;
    justify-content: space-between;
    align-items: flex-start;
    width: 100%;
    padding: 0.1rem 0.25rem;
    border-radius: var(--bng-corners-2);
    background: linear-gradient(to right, var(--bng-cool-gray-800), rgba(var(--bng-cool-gray-850-rgb), 0));

    .label {
      text-align: left;
      flex: 1;
      min-width: 0;
      font-weight: 600;
      margin-top: 0.25rem;
    }
    .green-dot {
      width: 0.5rem;
      height: 0.5rem;
      background-color: #6ce17a;
      border-radius: 50%;
      margin-right: 0.5rem;
      content: '';
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
    }

    .sub-info {
      font-size: 0.88rem;
      color: rgba(255, 255, 255, 0.5);
      --bng-icon-color: rgba(255, 255, 255, 0.5);
      font-weight: 300;

      :deep(.value-label) {
        font-weight: 300;
      }
    }
  }
}

.columns {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 1rem;
}

.panel {
  border: 1px solid rgba(255, 255, 255, 0.08);
  background: rgba(13, 21, 31, 0.6);
  border-radius: 0.63rem;
  padding: 1rem 1rem;
}

.panel-title {
  color: #ff9b3a;
  font-weight: 700;
  margin-bottom: 0.63rem;
}

.info-row {
  display: flex;
  justify-content: space-between;
  padding: 0.38rem 0;

  &.small {
    font-size: 0.9rem;
    opacity: 0.9;
  }
}

.row-label {
  color: #9fb0c0;
}

.row-value {
  font-weight: 700;

  &.highlight {
    color: #ffb25e;
  }

  &.pos {
    color: #6ce17a;
  }

  &.neg {
    color: #ff6b6b;
  }
}

.offer-container {
  display: flex;
  flex-direction: row;
  gap: 0.5rem;
  height: 20rem;
}

.opening-offer-panel {
  height: 20rem;
  padding: 2rem;
  border: 1px solid rgba(255, 255, 255, 0.12);
  border-radius: var(--bng-corners-2);
  background: rgba(5, 24, 38, 0.9);
  display: flex;
  flex-direction: column;
  justify-content: center;
  align-items: center;
  gap: 1.2rem;
}

.opening-title {
  font-size: 1.6rem;
  font-weight: 800;
}

.opening-subtitle {
  color: rgba(255, 255, 255, 0.72);
  text-align: center;
}

.opening-input-row {
  display: grid;
  grid-template-columns: auto auto minmax(9rem, 14rem) auto auto;
  align-items: center;
  gap: 0.5rem;
}

.opening-step {
  color: white;
  background: #e85f00;
  border: 0;
  border-radius: 0.25rem;
  min-width: 4rem;
  padding: 0.75rem;
  font-weight: 700;
}

.opening-input {
  color: white;
  text-align: center;
  background: rgba(0, 0, 0, 0.45);
  border: 1px solid rgba(255, 255, 255, 0.2);
  border-radius: 0.25rem;
  padding: 0.65rem;
  font-size: 1.5rem;
  font-weight: 800;
}

.opening-input::-webkit-outer-spin-button,
.opening-input::-webkit-inner-spin-button {
  appearance: none;
  margin: 0;
}

.opening-preview {
  color: rgba(255, 255, 255, 0.66);
  font-weight: 700;
}


.offer-controls {
  display: flex;
  flex-direction: column;
  justify-content: center;
  align-items: center;
  gap: 0.38rem;

  .offer-controls-row {
    display: flex;
    flex-direction: row;
    justify-content: center;
    align-items: center;
    gap: 0.38rem;
    height: 4rem;
    width: 100%;
  }

  .step-buttons-group {
    display: flex;
    flex-direction: row;
    align-items: center;
    --bng-button-min-width: 5rem;
    --bng-button-max-width: 5rem;
  }

  .price-column {
    display: flex;
    flex-direction: column;
    align-items: center;
    gap: 0.25rem;
    &.disabled {
      opacity: 0.5;
      pointer-events: none;
      text-decoration: line-through;
    }
  }

  .price {
    text-align: center;
    font-size: 2.25rem;
    font-weight: 800;
    letter-spacing: 0.06rem;
  }

  .diff-percent-offer-preview-to-starting {
    font-size: 0.88rem;
    font-weight: 600;
    display: flex;
    align-items: center;
    gap: 0.25rem;
    min-height: 2rem;

    &.positive {
      color: #6ce17a;
      --bng-icon-color: #6ce17a;
    }

    &.negative {
      color: #ff6b6b;
      --bng-icon-color: #ff6b6b;
    }

    &.zero {
      color: rgba(255, 255, 255, 0.6);
      --bng-icon-color: rgba(255, 255, 255, 0.6);
    }
    &.hidden {
      opacity: 0;
    }
  }

  .diff-percent-offer-preview-to-market {
    font-size: 0.88rem;
    font-weight: 600;

    &.positive {
      color: #6ce17a;
    }

    &.negative {
      color: #ff6b6b;
    }
    &.hidden {
      opacity: 0;
    }
  }
}


.patience {
  display: flex;
  flex-direction: column;
  gap: 0.38rem;
  align-items: center;

  .label-row {
    display: flex;
    justify-content: space-between;
  }

  .bar {
    width: 100%;
    height: 1rem;
    background: #1b2a3a;
    border-radius: 0.5rem;
    overflow: hidden;
    position: relative;
    &.patience-good {
      border: 1px solid rgba(var(--bng-add-green-400-rgb), 0.3);
    }
    &.patience-mid {
      border: 1px solid rgba(var(--bng-ter-yellow-300-rgb), 0.5);
    }
    &.patience-bad {
      border: 1px solid rgba(var(--bng-add-red-500-rgb), 0.4);
    }
  }

  .separator {
    position: absolute;
    top: 0;
    width: 1px;
    height: 100%;
    background: rgba(255, 255, 255, 0.5);
    z-index: 2;
  }

  .fill {
    height: 100%;
    position: relative;
    z-index: 1;
    transition: width 1s ease-in-out, background-color 1s ease-out;
    ;

    &.patience-good {
      background-color: var(--bng-add-green-400);
    }

    &.patience-mid {
      background-color: var(--bng-ter-yellow-300);
    }

    &.patience-bad {
      background-color: var(--bng-add-red-500);
    }
  }
}

.resolved-negotiation-message {
  font-size: 1.2rem;
  text-align: center;
  padding: 0.5rem 0;
}
.accepted {
  padding: 0.5rem 5rem;
  color: var(--bng-add-green-400);
  --bng-icon-color: var(--bng-add-green-400);
  border-radius: 1rem;
  background: rgba(var(--bng-add-green-400-rgb), 0.2);
}
.failed {
  padding: 0.5rem 5rem;
  color: var(--bng-add-red-400);
  --bng-icon-color: var(--bng-add-red-400);
  border-radius: 1rem;
  background: rgba(var(--bng-add-red-400-rgb), 0.2);
}

.purchase-failed {
  flex-direction: column;
  align-items: center;
  text-align: center;
  padding: 1rem 1.5rem;
  color: var(--bng-ter-yellow-300);
  border-radius: 1rem;
  background: rgba(var(--bng-ter-yellow-300-rgb), 0.15);

  .resolved-negotiation-icon {
    --bng-icon-color: var(--bng-add-red-400);
  }

  .resolved-negotiation-message {
    margin-top: 0.5rem;
    max-width: 28rem;
    line-height: 1.35;
    font-size: 1rem;
  }
}

.resolved-negotiation-icon {
  font-size: 3rem;
  margin-right: 0.5rem;
}

.label {
  font-weight: bold;
}

.value {
  text-align: right;
}

.action-buttons {
  display: flex;
  justify-content: flex-end;

  .submit-offer {
    background: #ff7a1a;
    border-color: #ff7a1a;
    font-weight: 800;
  }
  &.wide {
    width: 100%;
    > * {
      flex: 1;
      max-width: none;
    }
  }
}

.decision-box {
  display: grid;
  grid-template-columns: 1fr auto;
  align-items: center;
  gap: 0.75rem;
  padding: 0.88rem 1rem;
  border: 0.13rem solid rgba(255, 255, 255, 0.18);
  background: rgba(13, 21, 31, 0.85);
  border-radius: 0.75rem;
  margin-top: 0.5rem;

  &.accepted {
    border-color: #6ce17a;
    box-shadow: 0 0 0 0.13rem rgba(108, 225, 122, 0.2) inset;
  }

  &.rejected {
    border-color: #ff6b6b;
    box-shadow: 0 0 0 0.13rem rgba(255, 107, 107, 0.15) inset;
  }

  .status-line {
    font-size: 1.05rem;
  }

  .actions {
    display: flex;
    gap: 0.63rem;
  }

  .accept-offer {
    background: #6ce17a;
    border-color: #6ce17a;
    color: #0b1b10;
    font-weight: 900;
  }
}

.patience-good {
  color: rgb(51, 255, 51);
}

.patience-mid {
  color: rgb(255, 255, 51);
}

.patience-bad {
  color: rgb(255, 51, 51);
}
</style>
