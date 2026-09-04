<template>
  <div class="grid-row grid" v-if="demandInfo">
    <div class="label primary">{{ demandInfo.label || 'High demand' }} (+{{ demandInfo.pct }}%)</div>
    <div class="rewards primary demand-bonus">
      <BngUnit :money="demandInfo.bonusMoney" />
    </div>
  </div>
</template>

<script setup>
import { BngUnit } from "@/common/components/base"

defineProps({
  demandInfo: { type: Object, default: null },
})
</script>

<style scoped>
.grid-row.grid {
  display: grid;
  grid-template-columns: 1fr minmax(5em, 2fr);
  grid-gap: 0.5rem;
}
.label {
  grid-column: 1 / span 1;
}
.rewards {
  grid-column: 2 / span 1;
}
.primary {
  font-weight: bold;
}
.demand-bonus {
  color: #34d399;
  font-weight: 700;
}
</style>
