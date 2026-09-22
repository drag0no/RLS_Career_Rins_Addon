<template>
  <article class="race-offer-card" @click.stop @mousedown.stop>
    <div class="race-offer-card__header">
      <span class="race-offer-card__title">{{ title }}</span>
      <span
        class="race-offer-card__laps"
        :class="{ 'race-offer-card__laps--status': !!statusText }"
      >{{ headerMeta }}</span>
    </div>
    <div v-if="classBadge || pwLabel || driverName" class="race-offer-card__class-strip">
      <span v-if="classBadge" class="race-offer-class-badge">{{ classBadge }}</span>
      <span v-if="pwLabel" class="race-offer-class-range">{{ pwLabel }}</span>
      <span v-if="driverName" class="race-offer-driver-name">{{ driverName }}</span>
    </div>
    <div class="race-offer-card__podium">
      <div v-for="(place, index) in places" :key="index" class="race-offer-place">
        <span class="race-offer-place__label">{{ place.label }}</span>
        <span class="race-offer-place__value">{{ formatMoney(place.value) }}</span>
        <span v-if="Number(place.xp) > 0" class="race-offer-place__xp">{{ formatMoney(place.xp) }} XP</span>
      </div>
    </div>
    <div v-if="isInBackgroundSim" class="race-offer-card__sim-progress">
      <div class="race-offer-card__sim-info">
        <span class="race-offer-card__sim-badge">{{ simBadge || statusText }}</span>
      </div>
      <div class="race-offer-card__progress-track" aria-hidden="true">
        <div
          class="race-offer-card__progress-fill"
          :style="{ width: `${Math.min(100, Math.max(0, Math.round((simProgress || 0) * 100)))}%` }"
        />
      </div>
    </div>
    <div class="race-offer-card__actions">
      <div class="actions-dispatch-row">
        <button
          v-if="!hidePrimary"
          type="button"
          class="btn btn-primary btn-action"
          data-focusable
          :disabled="declining || primaryDisabled"
          @click.stop="$emit('accept')"
          @mousedown.stop
        >
          <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
            <path d="M1 12s4-8 11-8 11 8 11 8-4 8-11 8-11-8-11-8z"/><circle cx="12" cy="12" r="3"/>
          </svg>
          <span>{{ primaryLabel }}</span>
        </button>

        <button
          v-if="showSendWithManager"
          type="button"
          class="btn btn-manager btn-action"
          data-focusable
          :disabled="declining || sendWithManagerDisabled"
          :title="sendWithManagerTooltip || ''"
          @click.stop="$emit('send-with-manager')"
          @mousedown.stop
        >
          <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
            <polygon points="13 2 3 14 12 14 11 22 21 10 12 10 13 2"/>
          </svg>
          <span>{{ sendWithManagerLabel }}</span>
        </button>
      </div>

      <button
        v-if="!hideSecondary"
        type="button"
        class="btn-cancel-link"
        data-focusable
        :disabled="declining || secondaryDisabled"
        @click.stop="$emit('decline')"
        @mousedown.stop
      >
        <span>✕ {{ secondaryLabel }}</span>
      </button>
    </div>
  </article>
</template>

<script setup>
import { computed } from "vue"
import { formatSanctionedClassCompact, pwBucketX1000 } from "../../utils/sanctionedClassFormat"

const props = defineProps({
  offer: {
    type: Object,
    required: true
  },
  declining: {
    type: Boolean,
    default: false
  },
  driverName: {
    type: String,
    default: ""
  },
  primaryLabel: {
    type: String,
    default: "Accept"
  },
  secondaryLabel: {
    type: String,
    default: "Decline"
  },
  primaryDisabled: {
    type: Boolean,
    default: false
  },
  secondaryDisabled: {
    type: Boolean,
    default: false
  },
  hidePrimary: {
    type: Boolean,
    default: false
  },
  hideSecondary: {
    type: Boolean,
    default: false
  },
  showSendWithManager: {
    type: Boolean,
    default: false
  },
  sendWithManagerDisabled: {
    type: Boolean,
    default: false
  },
  sendWithManagerTooltip: {
    type: String,
    default: ""
  },
  sendWithManagerLabel: {
    type: String,
    default: "With Manager"
  },
  isInBackgroundSim: {
    type: Boolean,
    default: false
  },
  simProgress: {
    type: Number,
    default: 0
  },
  simBadge: {
    type: String,
    default: ""
  },
  statusText: {
    type: String,
    default: ""
  }
})

defineEmits(["accept", "decline", "send-with-manager"])

const title = computed(() => props.offer?.raceLabel || props.offer?.raceName || "Race")

const lapsLabel = computed(() => {
  const n = Math.max(1, Math.floor(Number(props.offer?.lapCount) || 3))
  return n === 1 ? "1 lap" : `${n} laps`
})

const headerMeta = computed(() => {
  const status = String(props.statusText || "").trim()
  if (status) return status
  return lapsLabel.value
})

const classBadge = computed(() =>
  formatSanctionedClassCompact(props.offer?.hpBracketLabel, props.offer?.hpBracketBranch)
)

const pwLabel = computed(() => {
  const offer = props.offer
  if (!offer) return ""
  const branch = String(offer.hpBracketBranch || offer.hpBracketLabel || "").toLowerCase()
  if (branch.includes("open")) return "500+"
  const src = offer.classPwMin ?? offer.classPwMax
  const bucket = pwBucketX1000(src)
  return bucket != null ? String(bucket) : ""
})

const places = computed(() => {
  const offer = props.offer
  if (!offer) return []
  return [
    { label: "1st", value: offer.payoutFirst, xp: offer.xpFirst },
    { label: "2nd", value: offer.payoutSecond, xp: offer.xpSecond },
    { label: "3rd", value: offer.payoutThird, xp: offer.xpThird }
  ]
})

function formatMoney(n) {
  const v = Number(n)
  if (!Number.isFinite(v)) return "$0"
  return `$${Math.round(v).toLocaleString()}`
}
</script>

<style scoped lang="scss">
.race-offer-card {
  display: flex;
  flex-direction: column;
  gap: 0.65em;
  padding: 0.85em 0.95em;
  border-radius: 0.75em;
  background: rgba(20, 28, 36, 0.88);
  border: 1px solid rgba(245, 73, 0, 0.22);
  min-width: 0;
}

.race-offer-card__header {
  display: flex;
  align-items: baseline;
  justify-content: space-between;
  gap: 0.65em;
}

.race-offer-card__title {
  font-size: 1.05em;
  font-weight: 700;
  color: #fff;
  line-height: 1.2;
  min-width: 0;
}

.race-offer-card__laps {
  flex-shrink: 0;
  font-size: 0.82em;
  font-weight: 600;
  color: rgba(255, 255, 255, 0.55);
}

.race-offer-card__laps--status {
  color: rgba(245, 73, 0, 0.9);
  text-align: right;
  max-width: 55%;
  line-height: 1.25;
}

.race-offer-driver-name {
  font-size: 0.8em;
  font-weight: 600;
  color: rgba(255, 255, 255, 0.88);
}

.race-offer-card__class-strip {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 0.45em 0.65em;
}

.race-offer-class-badge {
  padding: 0.3em 0.55em;
  border-radius: 0.45em;
  background: rgba(245, 73, 0, 0.18);
  border: 1px solid rgba(245, 73, 0, 0.32);
  color: rgba(255, 200, 160, 0.95);
  font-size: 0.72em;
  font-weight: 700;
  text-transform: uppercase;
  letter-spacing: 0.04em;
}

.race-offer-class-range {
  font-size: 0.8em;
  font-weight: 600;
  color: rgba(255, 255, 255, 0.72);
}

.race-offer-card__podium {
  display: flex;
  gap: 0.4em;
}

.race-offer-place {
  flex: 1;
  min-width: 0;
  padding: 0.55em 0.35em;
  border-radius: 0.55em;
  border: 1px solid rgba(255, 255, 255, 0.08);
  background: rgba(0, 0, 0, 0.2);
  text-align: center;
  display: flex;
  flex-direction: column;
  gap: 0.2em;
}

.race-offer-place__label {
  font-size: 0.68em;
  font-weight: 700;
  letter-spacing: 0.05em;
  text-transform: uppercase;
  color: rgba(255, 255, 255, 0.5);
}

.race-offer-place__value {
  font-size: 1.05em;
  font-weight: 700;
  line-height: 1.15;
  color: rgba(228, 233, 242, 0.88);
}

.race-offer-place:first-child .race-offer-place__value {
  color: #f4c49c;
}

.race-offer-place__xp {
  font-size: 0.72em;
  font-weight: 600;
  color: rgba(255, 255, 255, 0.5);
}

.race-offer-place:first-child .race-offer-place__xp {
  color: rgba(244, 196, 156, 0.78);
}

.race-offer-card__sim-progress {
  display: flex;
  flex-direction: column;
  gap: 0.35em;
  margin-top: 0.15em;
}

.race-offer-card__sim-info {
  display: flex;
  align-items: center;
  justify-content: space-between;
}

.race-offer-card__sim-badge {
  font-size: 0.72em;
  font-weight: 700;
  text-transform: uppercase;
  letter-spacing: 0.04em;
  color: #ff9933;
}

.race-offer-card__progress-track {
  height: 6px;
  background: rgba(255, 255, 255, 0.08);
  border-radius: 3px;
  overflow: hidden;
}

.race-offer-card__progress-fill {
  height: 100%;
  background: linear-gradient(90deg, #ff6600, #ff9933);
  border-radius: 3px;
  transition: width 0.15s linear;
}

.race-offer-card__actions {
  display: flex;
  flex-direction: column;
  gap: 0.45em;
  width: 100%;
  margin-top: 0.25em;
}

.actions-dispatch-row {
  display: flex;
  gap: 0.45em;
  width: 100%;

  .btn-action {
    flex: 1 1 0;
    min-width: 0;
    display: inline-flex;
    align-items: center;
    justify-content: center;
    gap: 0.4em;
    padding: 0.52em 0.65em;
    border-radius: 6px;
    font-size: 0.8em;
    font-weight: 600;
    letter-spacing: 0.02em;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
    cursor: pointer;
    border: none;
    transition: background 0.15s, opacity 0.15s;

    svg {
      flex-shrink: 0;
    }

    &:disabled {
      opacity: 0.45;
      cursor: default;
    }
  }

  .btn-primary {
    background: rgba(245, 73, 0, 0.9);
    color: #fff;
    border: 1px solid rgba(255, 120, 50, 0.3);

    &:hover:not(:disabled) {
      background: rgba(255, 100, 30, 1);
    }
  }

  .btn-manager {
    background: rgba(24, 60, 100, 0.7);
    color: #70c4ff;
    border: 1px solid rgba(70, 160, 255, 0.4);

    &:hover:not(:disabled) {
      background: rgba(30, 85, 145, 0.9);
      color: #fff;
    }
  }
}

.btn-cancel-link {
  background: transparent;
  border: none;
  color: rgba(255, 110, 110, 0.65);
  font-size: 0.74em;
  font-weight: 500;
  cursor: pointer;
  padding: 0.15em 0;
  align-self: center;
  transition: color 0.15s ease;

  &:hover:not(:disabled) {
    color: rgba(255, 110, 110, 1);
    text-decoration: underline;
  }

  &:disabled {
    opacity: 0.4;
    cursor: default;
  }
}
</style>