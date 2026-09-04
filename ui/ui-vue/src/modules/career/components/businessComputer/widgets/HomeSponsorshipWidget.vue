<template>
  <div class="home-widget sponsorship-widget" :class="{ 'home-widget--compact': compact }">
    <div class="widget-header">
      <h3>Sponsorship</h3>
      <span v-if="!compact && isRacingTeamLeague2 && bonusSummary" class="widget-sub">{{ bonusSummary }}</span>
    </div>
    <div v-if="!isRacingTeam" class="widget-content placeholder">
      <p class="placeholder-text">Sponsor tools are for the racing team business.</p>
    </div>
    <div v-else-if="!isLeague2" class="widget-content placeholder">
      <p class="placeholder-text">
        {{ compact ? "League 2 unlocks sponsor contracts." : `Join ${store.league2Invite.acronym} (League 2) from the Goals tab to unlock team sponsor contracts. Bonuses apply to proxy race payouts.` }}
      </p>
    </div>
    <div v-else class="widget-content sponsor-body">
      <div class="sponsor-slots-line">
        Slots: <strong>{{ sponsorSlotsUsed }}</strong> / <strong>{{ sponsorSlotsMax }}</strong>
        <span v-if="compact && bonusSummary" class="sponsor-slots-line__bonus"> · {{ bonusSummary }}</span>
      </div>
      <div v-if="!compact && availableOffers.length" class="sponsor-section">
        <h4 class="sponsor-section__title">Available offers</h4>
        <div
          v-for="o in availableOffers"
          :key="o.id"
          class="sponsor-card sponsor-card--available"
        >
          <div class="sponsor-card__name">{{ o.name }}</div>
          <div v-if="o.focusLabel" class="sponsor-card__focus">{{ o.focusLabel }}</div>
          <div class="sponsor-card__bonuses">
            +{{ pct(o.bonusMoneyPercent) }} race payout · +{{ pct(o.bonusXpPercent) }} XP
          </div>
          <div class="sponsor-card__actions">
            <button
              type="button"
              class="btn btn-primary"
              data-focusable
              :disabled="sponsorSlotsUsed >= sponsorSlotsMax"
              @click="onAccept(o.id)"
            >
              Sign
            </button>
            <button type="button" class="btn btn-secondary" data-focusable @click="onDecline(o.id)">
              Pass
            </button>
          </div>
        </div>
      </div>
      <div v-else-if="!compact" class="sponsor-empty">
        No sponsor offer right now.
      </div>
      <div v-if="active.length" class="sponsor-section" :class="{ 'sponsor-section--compact': compact }">
        <h4 v-if="!compact" class="sponsor-section__title">Active contracts</h4>
        <template v-if="compact">
          <ul class="sponsor-compact-list">
            <li v-for="o in active" :key="o.id" class="sponsor-compact-row">
              <span class="sponsor-compact-row__name">{{ o.name }}</span>
              <span class="sponsor-compact-row__bonus">+{{ pct(o.bonusMoneyPercent) }} · +{{ pct(o.bonusXpPercent) }} XP</span>
            </li>
          </ul>
        </template>
        <template v-else>
          <div
            v-for="o in active"
            :key="o.id"
            class="sponsor-card sponsor-card--active"
          >
            <div class="sponsor-card__name">{{ o.name }}</div>
            <div class="sponsor-card__bonuses">
              +{{ pct(o.bonusMoneyPercent) }} · +{{ pct(o.bonusXpPercent) }} XP
            </div>
            <button type="button" class="btn btn-secondary" data-focusable @click="onDrop(o.id)">
              End contract
            </button>
          </div>
        </template>
      </div>
      <p v-else-if="compact" class="sponsor-empty sponsor-empty--compact">No active sponsors.</p>
    </div>
  </div>
</template>

<script setup>
import { computed } from "vue"
import { useBusinessComputerStore } from "../../../stores/businessComputerStore"

defineProps({
  compact: { type: Boolean, default: false },
})

const store = useBusinessComputerStore()

const isRacingTeam = computed(() => store.businessType === "racingTeam")
const isLeague2 = computed(() => (store.businessData?.currentLeague || "") === "league2")
const isRacingTeamLeague2 = computed(() => isRacingTeam.value && isLeague2.value)

const sp = computed(() => store.racingTeamSponsors || {})

const availableOffers = computed(() => {
  const a = sp.value.available
  return Array.isArray(a) ? a : []
})

const active = computed(() => {
  const a = sp.value.active
  return Array.isArray(a) ? a : []
})

const sponsorSlotsUsed = computed(() => Number(sp.value.sponsorSlotsUsed) || 0)
const sponsorSlotsMax = computed(() => Number(sp.value.sponsorSlots) || 2)

const bonusSummary = computed(() => {
  const m = sp.value.bonusMoneyTotal
  const x = sp.value.bonusXpTotal
  if ((m == null || m === 0) && (x == null || x === 0)) {
    return ""
  }
  return `Active: +${pct(m)} payout · +${pct(x)} XP`
})

function pct (v) {
  if (v == null || v === "") return "0%"
  const n = Number(v)
  if (!Number.isFinite(n)) return "0%"
  return `${Math.round(n * 100)}%`
}

async function onAccept (id) {
  await store.acceptRacingTeamSponsorOffer(id)
}

async function onDecline (id) {
  await store.declineRacingTeamSponsorOffer(id)
}

async function onDrop (id) {
  await store.dropRacingTeamSponsorActive(id)
}
</script>

<style scoped lang="scss">
.home-widget {
  background: rgba(30, 30, 30, 0.6);
  border: 1px solid rgba(255, 255, 255, 0.05);
  border-radius: 1em;
  display: flex;
  flex-direction: column;
  overflow: hidden;
  height: 100%;
}

.widget-header {
  padding: 1em 1.25em;
  border-bottom: 1px solid rgba(255, 255, 255, 0.05);
  display: flex;
  flex-direction: column;
  align-items: flex-start;
  gap: 0.35em;
  background: rgba(0, 0, 0, 0.2);

  h3 {
    margin: 0;
    font-size: 1.1em;
    font-weight: 600;
    color: #fff;
  }
}

.widget-sub {
  font-size: 0.78em;
  color: rgba(160, 230, 200, 0.85);
  line-height: 1.35;
}

.widget-content.placeholder {
  flex: 1;
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  gap: 0.5em;
  padding: 1.5em 1.25em;
  min-height: 0;
  text-align: center;
}

.placeholder-text {
  margin: 0;
  color: rgba(255, 255, 255, 0.65);
  font-size: 0.9em;
  line-height: 1.45;
}

.sponsor-body {
  flex: 1;
  padding: 1em 1.15em 1.25em;
  display: flex;
  flex-direction: column;
  gap: 1em;
  min-height: 0;
  overflow-y: auto;
}

.sponsor-slots-line {
  font-size: 0.82em;
  color: rgba(255, 255, 255, 0.65);
  strong {
    color: rgba(255, 255, 255, 0.9);
  }
}

.sponsor-section__title {
  margin: 0 0 0.5em;
  font-size: 0.82em;
  font-weight: 600;
  text-transform: uppercase;
  letter-spacing: 0.05em;
  color: rgba(255, 255, 255, 0.45);
}

.sponsor-empty {
  font-size: 0.85em;
  color: rgba(255, 255, 255, 0.45);
  line-height: 1.4;
}

.sponsor-card {
  padding: 0.75em 0.85em;
  border-radius: 0.55em;
  margin-bottom: 0.55em;
  &:last-child {
    margin-bottom: 0;
  }
}

.sponsor-card--available {
  background: rgba(40, 90, 75, 0.22);
  border: 1px solid rgba(100, 200, 165, 0.2);
}

.sponsor-card--active {
  background: rgba(255, 255, 255, 0.04);
  border: 1px solid rgba(255, 255, 255, 0.08);
}

.sponsor-card__name {
  font-weight: 600;
  color: #fff;
  font-size: 0.92em;
}

.sponsor-card__focus {
  font-size: 0.78em;
  color: rgba(255, 255, 255, 0.45);
  margin-top: 0.2em;
}

.sponsor-card__bonuses {
  font-size: 0.82em;
  color: rgba(180, 245, 215, 0.9);
  margin-top: 0.35em;
}

.sponsor-card__actions {
  display: flex;
  flex-wrap: wrap;
  gap: 0.45em;
  margin-top: 0.75em;
}

.sponsor-card__actions .btn,
.sponsor-card--active .btn {
  font-size: 0.8em;
  padding: 0.4em 0.75em;
}

.sponsor-card--active .btn {
  margin-top: 0.5em;
}

.btn {
  padding: 0.55em 1.25em;
  border-radius: 8px;
  font-weight: 600;
  font-size: 0.9em;
  cursor: pointer;
  border: none;
  transition: background 0.15s, opacity 0.15s;
}

.btn-primary {
  background: rgba(245, 73, 0, 0.9);
  color: #fff;
  &:hover:not(:disabled) {
    background: rgba(255, 100, 30, 1);
  }
  &:disabled {
    opacity: 0.5;
    cursor: default;
  }
}

.btn-secondary {
  background: rgba(40, 52, 64, 0.95);
  color: rgba(255, 255, 255, 0.92);
  border: 1px solid rgba(245, 73, 0, 0.35);
  &:hover:not(:disabled) {
    border-color: rgba(245, 73, 0, 0.55);
    background: rgba(50, 64, 78, 0.98);
  }
  &:disabled {
    opacity: 0.5;
    cursor: default;
  }
}

.sponsor-compact-list {
  margin: 0;
  padding: 0;
  list-style: none;
  display: flex;
  flex-direction: column;
  gap: 0.3em;
}

.sponsor-compact-row {
  display: flex;
  flex-direction: column;
  gap: 0.1em;
  padding: 0.35em 0.45em;
  border-radius: 0.35em;
  background: rgba(0, 0, 0, 0.22);
  border: 1px solid rgba(255, 255, 255, 0.06);
}

.sponsor-compact-row__name {
  font-size: 0.78em;
  font-weight: 600;
  color: #fff;
}

.sponsor-compact-row__bonus {
  font-size: 0.68em;
  color: rgba(160, 230, 200, 0.85);
}

.sponsor-slots-line__bonus {
  color: rgba(160, 230, 200, 0.85);
}

.home-widget--compact {
  min-height: 0;
  height: auto;
  flex-shrink: 0;

  .widget-header {
    padding: 0.42em 0.55em;
    flex-direction: row;
    align-items: center;
    justify-content: space-between;

    h3 {
      font-size: 0.82em;
    }
  }

  .widget-content.placeholder {
    padding: 0.5em 0.55em;
  }

  .placeholder-text {
    font-size: 0.75em;
  }

  .sponsor-body {
    padding: 0.4em 0.55em 0.5em;
    gap: 0.4em;
  }

  .sponsor-slots-line {
    font-size: 0.72em;
  }

  .sponsor-empty--compact {
    margin: 0;
    font-size: 0.72em;
    color: rgba(255, 255, 255, 0.45);
  }
}
</style>
