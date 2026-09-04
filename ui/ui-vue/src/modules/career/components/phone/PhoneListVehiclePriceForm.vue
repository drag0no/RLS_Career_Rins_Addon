<template>
  <div v-if="formModel" class="phone-list-price">
    <div class="vehicle-meta">
      <div class="name">{{ formModel.vehicleName }}</div>
      <div class="meta" v-if="metaText">{{ metaText }}</div>
    </div>

    <div class="price-box">
      <div class="label">Your asking price</div>
      <div class="price">{{ moneyText(formModel.price || 0) }}</div>
      <div class="step-row">
        <button type="button" class="step-btn large" @click="adjustPrice(-5000)">-5k</button>
        <button type="button" class="step-btn" @click="adjustPrice(-500)">-500</button>
        <button type="button" class="step-btn small" @click="adjustPrice(-50)">-50</button>
        <button type="button" class="step-btn small" @click="adjustPrice(50)">+50</button>
        <button type="button" class="step-btn" @click="adjustPrice(500)">+500</button>
        <button type="button" class="step-btn large" @click="adjustPrice(5000)">+5k</button>
      </div>
      <div v-if="priceHint.text" class="hint" :class="priceHint.class">{{ priceHint.text }}</div>
      <div v-if="offerHint.text" class="offer-hint" :class="offerHint.class">{{ offerHint.text }}</div>
    </div>
  </div>
</template>

<script setup>
import { computed } from 'vue'
import { moneyText } from '../../composables/usePhoneMarketplaceFormat'

const props = defineProps({
  modelValue: {
    type: Object,
    default: null,
  },
})
const emit = defineEmits(['update:modelValue'])


const formModel = computed({
  get: () => props.modelValue,
  set: value => emit('update:modelValue', value),
})

const metaText = computed(() => {
  if (!formModel.value) return ''
  const mv = formModel.value.marketValue || 0
  if (formModel.value.odometerKm) {
    return `${new Intl.NumberFormat().format(Math.round(formModel.value.odometerKm))} km — Market ${moneyText(mv)}`
  }
  return `Market value: ${moneyText(mv)}`
})

function adjustPrice(amount) {
  const price = Math.max(0, Math.round(((formModel.value.price || 0) + amount) / 50) * 50)
  emit('update:modelValue', { ...formModel.value, price })
}

const priceHint = computed(() => {
  const mv = Number(formModel.value?.marketValue || 0)
  const p = Number(formModel.value?.price || 0)
  if (!mv || !p) return { text: '', class: '' }
  const diff = (p - mv) / mv
  const percent = Math.round(Math.abs(diff) * 100)
  if (percent < 1) return { text: 'Fair market value', class: 'ok' }
  if (diff > 0) return { text: `${percent}% above market`, class: 'high' }
  return { text: `${percent}% below market`, class: 'low' }
})

const offerHint = computed(() => {
  const mv = Number(formModel.value?.marketValue || 0)
  const p = Number(formModel.value?.price || 0)
  if (!mv || !p) return { text: 'Regular offers expected', class: 'regular' }
  const ratio = p / mv
  if (ratio <= 0.90) return { text: 'More offers expected', class: 'more' }
  if (ratio >= 1.20) return { text: 'Fewer offers expected', class: 'fewer' }
  return { text: 'Regular offers expected', class: 'regular' }
})
</script>

<style scoped lang="scss">
.phone-list-price {
  display: flex;
  flex-direction: column;
  gap: 12px;
}

.vehicle-meta {
  .name {
    font-size: 14px;
    font-weight: 700;
    margin-bottom: 4px;
  }
  .meta {
    font-size: 11px;
    color: rgba(255, 255, 255, 0.6);
  }
}

.price-box {
  padding: 12px;
  border-radius: 12px;
  background: rgba(0, 0, 0, 0.25);
  border: 1px solid rgba(255, 255, 255, 0.08);
  text-align: center;

  .label {
    font-size: 11px;
    font-weight: 700;
    letter-spacing: 0.04em;
    text-transform: uppercase;
    color: rgba(255, 255, 255, 0.55);
    margin-bottom: 6px;
  }

  .price {
    font-size: 26px;
    font-weight: 800;
    margin-bottom: 10px;
  }

  .step-row {
    display: flex;
    flex-wrap: wrap;
    justify-content: center;
    gap: 6px;
    margin-bottom: 8px;
  }

  .step-btn {
    padding: 8px 10px;
    border: 1px solid rgba(255, 255, 255, 0.12);
    border-radius: 8px;
    background: rgba(255, 255, 255, 0.06);
    color: #f6f3ee;
    font: inherit;
    font-size: 11px;
    font-weight: 700;
    cursor: pointer;

    &.small {
      min-width: 44px;
    }

    &.large {
      min-width: 48px;
    }

    &:active {
      background: rgba(126, 182, 255, 0.2);
    }
  }

  .hint {
    font-size: 11px;
    margin-top: 4px;
    &.ok { color: #29c15a; }
    &.low { color: #7fb6ff; }
    &.high { color: #ffad66; }
  }

  .offer-hint {
    font-size: 10px;
    opacity: 0.8;
    margin-top: 2px;
    &.more { color: #29c15a; }
    &.regular { color: #7fb6ff; }
    &.fewer { color: #ffad66; }
  }
}
</style>
