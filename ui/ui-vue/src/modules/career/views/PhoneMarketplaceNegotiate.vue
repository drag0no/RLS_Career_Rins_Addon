<template>
  <PhoneWrapper app-name="Marketplace" :custom-back="handleBack">
    <div class="phone-negotiate">
      <header class="negotiate-header">
        <span class="avatar avatar--md" :style="{ background: avatarBg }">{{ initials }}</span>
        <div class="who">
          <div class="who-name-row">
            <span class="who-name">{{ opponentName }}</span>
            <span class="who-role">{{ roleTag }}</span>
          </div>
          <div class="who-vehicle">{{ vehicleLine }}</div>
        </div>
        <div v-if="marketValue !== null" class="market">
          <div class="market-label">Est. market</div>
          <div class="market-value">{{ money(marketValue) }}</div>
        </div>
      </header>

      <div ref="negotiationChat" class="chat">
        <div v-for="message in messages" :key="message.key" class="msg" :class="{ mine: message.mine }">
          <span v-if="!message.mine" class="avatar avatar--xs" :style="{ background: avatarBg }">{{ initials }}</span>
          <div class="msg-stack">
            <div class="msg-label" :class="message.tone ? `tone-${message.tone}` : ''">{{ message.label }}</div>
            <div class="bubble" :class="[message.mine ? 'bubble--mine' : 'bubble--theirs', message.tone ? `bubble--${message.tone}` : '']">
              <span v-if="message.price != null" class="bubble-price">{{ money(message.price) }}</span>
              <div v-if="message.note" class="bubble-note">{{ message.note }}</div>
            </div>
          </div>
        </div>
      </div>

      <div class="negotiate-footer">
        <div class="turn-row">
          <span class="turn" :class="turnClass">
            <span v-if="isWaitingOnThem" class="spinner spinner--dark"></span>
            <span v-else-if="isMyTurn" class="pulse-dot"></span>
            {{ turnText }}
          </span>
          <span class="patience-text" :class="patienceClass">{{ patienceText }}</span>
        </div>

        <div class="patience-bar">
          <span class="patience-fill" :class="patienceClass" :style="{ width: `${patiencePercent}%` }"></span>
        </div>

        <template v-if="awaitingOpeningOffer">
          <div class="opening-panel">
            <div class="opening-label">Your opening offer</div>
            <div class="opening-row">
              <button type="button" class="step-btn" @click="nudgeOpeningOffer(-500)">−500</button>
              <input
                class="opening-input"
                :value="openingOfferText"
                type="text"
                inputmode="numeric"
                @input="onOpeningOfferInput"
                @focus="onOpeningInputFocus"
                @blur="onOpeningInputBlur"
              >
              <button type="button" class="step-btn" @click="nudgeOpeningOffer(500)">+500</button>
            </div>
          </div>
          <div class="action-row">
            <button type="button" class="action-btn primary" :disabled="openingOfferDisabled" @click="submitOpeningOffer">
              Send {{ money(offerPreview) }}
            </button>
          </div>
        </template>

        <template v-else-if="!isResolved">
          <div class="offer-head">
            <div>
              <div class="offer-label">Your next offer</div>
              <div class="offer-value">{{ money(offerPreview) }}</div>
            </div>
            <div v-if="marketDiffText" class="offer-diff" :class="isDiffPercentOfferPreviewToMarketGood ? 'good' : 'warn'">
              {{ marketDiffText }}
            </div>
          </div>

          <div class="range">
            <span class="range-track"></span>
            <span class="range-gap" :style="{ left: `${gapFill.left}%`, width: `${gapFill.width}%` }"></span>
            <span v-if="showMarketTick" class="range-market" :style="{ left: `${marketPercent}%` }" title="Est. market value"></span>
            <span class="range-handle" :style="{ left: `${previewPercent}%` }"></span>
          </div>
          <div class="range-labels">
            <span>{{ rangeLowLabel ? `${rangeLowLabel.prefix} ${money(rangeLowLabel.value)}` : '' }}</span>
            <span>{{ rangeHighLabel ? `${rangeHighLabel.prefix} ${money(rangeHighLabel.value)}` : '' }}</span>
          </div>

          <div class="step-row">
            <button type="button" class="step-btn" :disabled="offerDisabled || decreaseOfferDisabled" @click="nudgeOffer(-500)">−500</button>
            <button type="button" class="step-btn" :disabled="offerDisabled || decreaseOfferDisabled" @click="nudgeOffer(-50)">−50</button>
            <button type="button" class="step-btn" :disabled="offerDisabled || increaseOfferDisabled" @click="nudgeOffer(50)">+50</button>
            <button type="button" class="step-btn" :disabled="offerDisabled || increaseOfferDisabled" @click="nudgeOffer(500)">+500</button>
            <button
              type="button"
              class="step-btn split"
              :class="{ spent: splitGapUsed }"
              :disabled="!splitGapAvailable"
              :title="splitGapUsed ? 'Already used this negotiation' : 'Meet in the middle — once per negotiation'"
              @click="splitTheGap"
            >
              {{ splitGapUsed ? 'Gap split' : 'Split gap' }}
            </button>
          </div>

          <p v-if="splitGapUsed" class="split-note">Split gap is once per negotiation — the rest is on you.</p>
          <p v-if="clampHint" class="clamp-hint">{{ clampHint }}</p>

          <div class="action-row">
            <button
              v-if="state.hasVisibleTheirOffer"
              type="button"
              class="action-btn secondary"
              :disabled="!canTakeTheirOffer"
              @click="takeOffer"
            >
              Take {{ money(state.theirOffer) }}
            </button>
            <button type="button" class="action-btn primary wide" :disabled="sendDisabled" @click="submitOffer">
              Send {{ money(offerPreview) }}
            </button>
          </div>
        </template>

        <template v-else>
          <div class="resolved" :class="{ failed: state.negotiationStatus === 'failed' }">
            <div class="resolved-title">
              {{ resolvedTitle }}<template v-if="state.negotiationStatus === 'accepted'"> at {{ money(state.theirOffer) }}</template>
            </div>
            <p class="resolved-body">{{ resolvedStatusText }}</p>
          </div>
          <div class="action-row">
            <button type="button" class="action-btn primary wide" @click="goBack">{{ resolvedActionText }}</button>
          </div>
        </template>
      </div>
    </div>
  </PhoneWrapper>
</template>

<script setup>
import { computed, nextTick, watch } from 'vue'
import PhoneWrapper from './PhoneWrapper.vue'
import { lua } from '@/bridge'
import { usePhoneMarketplaceUi } from '../composables/usePhoneMarketplaceUi'
import { requestSellTab } from '../composables/usePhoneMarketplaceListings'
import { useVehicleNegotiation } from '../composables/useVehicleNegotiation'
import {
  avatarColour,
  avatarInitials,
  usePhoneMarketplaceMoney,
} from '../composables/usePhoneMarketplaceFormat'

usePhoneMarketplaceUi()

const { money } = usePhoneMarketplaceMoney()

/** Selling ends up back in the offers inbox; buying returns to the browse feed. */
const exitToMarketplace = finalState => {
  if (finalState?.amISelling) {
    requestSellTab('offers')
    lua.extensions.ui_router.navigate('phone-marketplace-sell')
    return
  }
  lua.extensions.ui_router.navigate('phone-marketplace')
}

const {
  state,
  opponent,
  offerPreview,
  openingOfferText,
  awaitingOpeningOffer,
  openingOfferDisabled,
  increaseOfferDisabled,
  decreaseOfferDisabled,
  isDiffPercentOfferPreviewToMarketGood,
  marketValue,
  marketDiffText,
  offerDisabled,
  isResolved,
  isWaitingOnThem,
  isMyTurn,
  messages,
  previewPercent,
  gapFill,
  showMarketTick,
  marketPercent,
  rangeLowLabel,
  rangeHighLabel,
  clampHint,
  splitGapAvailable,
  splitGapUsed,
  canTakeTheirOffer,
  sendDisabled,
  turnText,
  turnClass,
  patienceClass,
  patiencePercent,
  patienceText,
  resolvedTitle,
  resolvedStatusText,
  resolvedActionText,
  formatMileage,
  negotiationChat,
  nudgeOffer,
  splitTheGap,
  nudgeOpeningOffer,
  onOpeningOfferInput,
  onOpeningInputFocus,
  onOpeningInputBlur,
  submitOffer,
  submitOpeningOffer,
  takeOffer,
  exitNegotiation,
  goBack,
} = useVehicleNegotiation(exitToMarketplace)

const opponentName = computed(() => state.value.opponentName || opponent.value)
const initials = computed(() => avatarInitials(opponentName.value))
const avatarBg = computed(() => avatarColour(opponentName.value))
const roleTag = computed(() => (state.value.amISelling ? 'buying from you' : 'private seller'))
const vehicleLine = computed(() => [
  state.value.vehicleNiceName,
  state.value.vehicleMileage != null ? formatMileage(state.value.vehicleMileage) : null,
].filter(Boolean).join(' · '))

watch(messages, () => {
  nextTick(() => {
    const el = negotiationChat.value
    if (el) el.scrollTop = el.scrollHeight
  })
}, { deep: true })

const handleBack = () => {
  exitNegotiation()
  return true
}
</script>

<style scoped lang="scss">
@use '../styles/phone-marketplace' as *;

.phone-negotiate {
  display: flex;
  flex-direction: column;
  height: 100%;
  min-height: 0;
  box-sizing: border-box;
  color: #fff;
  overflow: hidden;
}

.negotiate-header {
  flex: none;
  display: flex;
  align-items: center;
  gap: 10px;
  padding: 42px 14px 10px;
  border-bottom: 1px solid rgba(255, 255, 255, 0.07);
}

.who {
  flex: 1;
  min-width: 0;
}

.who-name-row {
  display: flex;
  align-items: baseline;
  gap: 6px;
}

.who-name {
  font-size: 13.5px;
  font-weight: 700;
}

.who-role {
  padding: 2px 5px;
  border-radius: 5px;
  background: rgba(126, 182, 255, 0.16);
  color: #9ec8ff;
  font-size: 9px;
  font-weight: 700;
  letter-spacing: 0.08em;
  text-transform: uppercase;
  white-space: nowrap;
}

.who-vehicle {
  margin-top: 2px;
  font-size: 10.5px;
  color: rgba(255, 255, 255, 0.45);
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.market {
  flex: none;
  text-align: right;
}

.market-label {
  font-size: 8.5px;
  font-weight: 600;
  letter-spacing: 0.07em;
  text-transform: uppercase;
  color: rgba(255, 255, 255, 0.35);
}

.market-value {
  font-size: 12.5px;
  font-weight: 700;
  font-variant-numeric: tabular-nums;
  color: rgba(255, 255, 255, 0.8);
}

.chat {
  @include mkt-scrollbar;
  flex: 1;
  min-height: 0;
  overflow-y: auto;
  display: flex;
  flex-direction: column;
  gap: 11px;
  padding: 11px 12px 6px;
}

.msg {
  display: flex;
  gap: 7px;
  justify-content: flex-start;
  animation: bubbleIn 0.25s ease-out both;

  &.mine {
    justify-content: flex-end;
  }
}

.avatar--xs {
  width: 22px;
  height: 22px;
  font-size: 8.5px;
  line-height: 22px;
  margin-top: 13px;
}

.msg-stack {
  display: flex;
  flex-direction: column;
  align-items: flex-start;
  max-width: 76%;
  min-width: 0;
}

.msg.mine .msg-stack {
  align-items: flex-end;
}

.msg-label {
  margin: 0 2px 3px;
  font-size: 8.5px;
  font-weight: 700;
  letter-spacing: 0.1em;
  color: rgba(255, 255, 255, 0.42);

  &.tone-accepted { color: #29c15a; }
  &.tone-failed { color: #f44336; }
}

.bubble {
  min-width: 0;
  padding: 8px 12px;
  border: 1px solid rgba(255, 255, 255, 0.06);
  border-radius: 13px 13px 13px 3px;
  background: #2c3542;

  &--mine {
    border-radius: 13px 13px 3px 13px;
    background: #c2500f;
  }

  &--accepted {
    background: rgba(41, 193, 90, 0.12);
    border-color: rgba(41, 193, 90, 0.35);
    color: #6fe094;
  }

  &--failed {
    background: rgba(244, 67, 54, 0.12);
    border-color: rgba(244, 67, 54, 0.35);
    color: #ff8a80;
  }
}

.bubble-price {
  font-size: 20px;
  font-weight: 800;
  line-height: 1.15;
  font-variant-numeric: tabular-nums;
}

.bubble-note {
  margin-top: 4px;
  font-size: 11px;
  font-style: italic;
  line-height: 1.4;
  color: rgba(255, 255, 255, 0.68);
}

.bubble--accepted .bubble-note,
.bubble--failed .bubble-note {
  color: inherit;
  font-style: normal;
}

.spinner {
  width: 11px;
  height: 11px;
  border: 2px solid rgba(255, 255, 255, 0.25);
  border-top-color: #fff;
  border-radius: 50%;
  animation: spin 0.8s linear infinite;

  &--dark {
    width: 10px;
    height: 10px;
    border-color: rgba(255, 255, 255, 0.28);
    border-top-color: currentColor;
  }
}

.pulse-dot {
  width: 6px;
  height: 6px;
  border-radius: 50%;
  background: currentColor;
  animation: pulseDot 1.4s ease-in-out infinite;
}

.negotiate-footer {
  flex: none;
  padding: 9px 14px 13px;
  background: #0b0d12;
  border-top: 1px solid rgba(255, 255, 255, 0.07);
}

.turn-row {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 8px;
  margin-bottom: 8px;
}

.turn {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  padding: 4px 9px;
  border-radius: 8px;
  font-size: 10.5px;
  font-weight: 700;
  letter-spacing: 0.02em;
  background: rgba(255, 255, 255, 0.09);
  color: rgba(255, 255, 255, 0.7);

  &.turn--yours {
    background: rgba(41, 193, 90, 0.16);
    color: #6fe094;
  }

  &.turn--failed {
    background: rgba(244, 67, 54, 0.16);
    color: #ff8a80;
  }

  &.turn--done {
    background: rgba(41, 193, 90, 0.16);
    color: #6fe094;
  }

  &.turn--waiting {
    background: rgba(255, 255, 255, 0.09);
    color: rgba(255, 255, 255, 0.72);
  }
}

.patience-text {
  font-size: 10px;
  font-weight: 600;
  text-align: right;

  &.patience-good { color: #29c15a; }
  &.patience-mid { color: #ffad66; }
  &.patience-bad { color: #f44336; }
}

.patience-bar {
  position: relative;
  height: 5px;
  margin-bottom: 10px;
  border-radius: 3px;
  background: rgba(255, 255, 255, 0.1);
  overflow: hidden;
}

.patience-fill {
  display: block;
  height: 100%;
  transition: width 0.3s ease;

  &.patience-good { background: #29c15a; }
  &.patience-mid { background: #ffad66; }
  &.patience-bad { background: #f44336; }
}

.offer-head {
  display: flex;
  align-items: baseline;
  justify-content: space-between;
  gap: 10px;
  margin-bottom: 7px;
}

.offer-label {
  font-size: 8.5px;
  font-weight: 600;
  letter-spacing: 0.08em;
  text-transform: uppercase;
  color: rgba(255, 255, 255, 0.4);
}

.offer-value {
  margin-top: 1px;
  font-size: 26px;
  font-weight: 800;
  line-height: 1.1;
  font-variant-numeric: tabular-nums;
}

.offer-diff {
  font-size: 11px;
  font-weight: 700;
  text-align: right;

  &.good { color: #29c15a; }
  &.warn { color: #ffad66; }
}

.range {
  position: relative;
  height: 18px;
  margin: 4px 12px 0;
}

.range-track,
.range-gap {
  position: absolute;
  top: 7px;
  height: 5px;
  border-radius: 3px;
}

.range-track {
  left: 0;
  right: 0;
  background: rgba(255, 255, 255, 0.09);
}

.range-gap {
  background: linear-gradient(90deg, rgba(126, 182, 255, 0.35), rgba(126, 182, 255, 0.75));
}

.range-market {
  position: absolute;
  top: 2px;
  width: 2px;
  height: 15px;
  transform: translateX(-50%);
  background: rgba(255, 255, 255, 0.55);
}

.range-handle {
  position: absolute;
  top: 1px;
  width: 16px;
  height: 16px;
  transform: translateX(-50%);
  border-radius: 50%;
  border: 3px solid #10141c;
  background: #7eb6ff;
  box-shadow: 0 0 0 1px rgba(126, 182, 255, 0.6);
  transition: left 0.18s ease;
}

.range-labels {
  display: flex;
  justify-content: space-between;
  gap: 10px;
  margin-top: 5px;
  font-size: 9px;
  font-weight: 700;
  color: rgba(255, 255, 255, 0.5);
}

.step-row {
  display: flex;
  gap: 5px;
  margin-top: 9px;
}

.step-btn {
  flex: 1;
  min-height: 36px;
  padding: 7px 6px;
  border: 1px solid rgba(255, 255, 255, 0.12);
  border-radius: 8px;
  background: rgba(255, 255, 255, 0.06);
  color: #f6f3ee;
  font: inherit;
  font-size: 10.5px;
  font-weight: 700;
  cursor: pointer;

  &.split {
    flex: 1.4;
    border-color: rgba(126, 182, 255, 0.3);
    background: rgba(126, 182, 255, 0.12);
    color: #9ec8ff;
  }

  &.split.spent {
    border-color: rgba(255, 255, 255, 0.12);
    background: rgba(255, 255, 255, 0.04);
    color: rgba(255, 255, 255, 0.45);
  }

  &:disabled {
    opacity: 0.3;
    cursor: not-allowed;
  }
}

.split-note,
.clamp-hint {
  margin: 7px 0 0;
  font-size: 10.5px;
  line-height: 1.35;
}

.split-note {
  color: rgba(255, 255, 255, 0.42);
}

.clamp-hint {
  color: #ffad66;
}

.opening-panel {
  padding: 10px 0 0;
}

.opening-label {
  font-size: 8.5px;
  font-weight: 600;
  letter-spacing: 0.08em;
  text-transform: uppercase;
  color: rgba(255, 255, 255, 0.4);
}

.opening-row {
  display: flex;
  align-items: center;
  gap: 8px;
  margin-top: 6px;
}

.opening-input {
  flex: 1;
  min-width: 0;
  padding: 10px;
  border: 1px solid rgba(255, 255, 255, 0.15);
  border-radius: 10px;
  background: rgba(0, 0, 0, 0.35);
  color: #fff;
  font: inherit;
  font-size: 16px;
  font-weight: 700;
  text-align: center;
}

.resolved {
  padding: 13px;
  border-radius: 13px;
  background: rgba(41, 193, 90, 0.13);
  border: 1px solid rgba(41, 193, 90, 0.35);
  color: #8ceaad;

  &.failed {
    background: rgba(244, 67, 54, 0.13);
    border-color: rgba(244, 67, 54, 0.35);
    color: #ff9a90;
  }
}

.resolved-title {
  font-size: 15px;
  font-weight: 800;
}

.resolved-body {
  margin: 4px 0 0;
  font-size: 12px;
  line-height: 1.45;
  opacity: 0.85;
}

.action-row {
  display: flex;
  gap: 7px;
  margin-top: 9px;
}

.action-btn {
  flex: 1;
  min-height: 40px;
  padding: 10px 8px;
  border: none;
  border-radius: 10px;
  font: inherit;
  font-size: 12px;
  font-weight: 700;
  cursor: pointer;

  &.wide {
    flex: 1.25;
  }

  &.primary {
    background: #7eb6ff;
    color: #0f1116;
    font-weight: 800;
  }

  &.secondary {
    border: 1px solid rgba(255, 255, 255, 0.14);
    background: rgba(255, 255, 255, 0.08);
    color: #fff;
  }

  &:disabled {
    opacity: 0.4;
    cursor: not-allowed;
  }
}

@keyframes spin {
  to { transform: rotate(360deg); }
}

@keyframes bubbleIn {
  from { opacity: 0; transform: translateY(6px); }
  to { opacity: 1; transform: translateY(0); }
}

@keyframes pulseDot {
  0%, 100% { opacity: 0.35; }
  50% { opacity: 1; }
}
</style>
