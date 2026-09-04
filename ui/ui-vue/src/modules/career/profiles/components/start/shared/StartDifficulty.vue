<template>
  <div class="start-difficulty" :class="{ 'start-difficulty--rows': rows }">
    <label v-if="label" class="start-difficulty-label">{{ label }}</label>
    <div class="start-difficulty-cards">
      <button
        v-for="d in difficulties"
        :key="d.id"
        bng-nav-item
        type="button"
        class="sd-card"
        :class="{ 'sd-card--active': d.id === modelValue }"
        :aria-pressed="d.id === modelValue"
        @click="$emit('update:modelValue', d.id)">
        <span class="sd-name">{{ d.label }}</span>
        <span class="sd-stats">
          <span class="sd-stat">{{ formatMultiplier(d.money) }} money</span>
          <span class="sd-stat">{{ formatMultiplier(d.xp) }} XP</span>
          <span class="sd-stat">{{ formatCash(d.startingCash) }} start</span>
        </span>
        <span v-if="!rows" class="sd-blurb">{{ d.blurb }}</span>
      </button>
    </div>
  </div>
</template>

<script setup>
defineProps({
  modelValue: { type: String, default: null },
  difficulties: { type: Array, required: true },
  label: { type: String, default: null },
  /** Card-width layout: one row per difficulty, stats on a single line.
      Aligned columns compare better than side-by-side cards anyway. */
  rows: { type: Boolean, default: false },
})

defineEmits(["update:modelValue"])

function formatMultiplier(value) {
  return `${Number(value) % 1 === 0 ? value.toFixed(1) : value}×`
}

function formatCash(value) {
  if (!value) return "$0"
  return `$${Number(value).toLocaleString("en-US")}`
}
</script>

<style lang="scss" scoped>
.start-difficulty {
  display: flex;
  flex-direction: column;
  gap: 0.4em;
}

.start-difficulty-label {
  font-weight: 600;
  font-size: 0.88em;
  color: rgba(255, 255, 255, 0.75);
}

.start-difficulty-cards {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(9em, 1fr));
  gap: 0.5em;
}

.sd-card {
  display: flex;
  flex-direction: column;
  gap: 0.4em;
  text-align: left;
  padding: 0.7em 0.75em;
  border: 1px solid rgba(71, 85, 105, 0.45);
  border-radius: 10px;
  background: rgba(5, 8, 15, 0.55);
  color: #fff;
  font-family: inherit;
  cursor: pointer;

  &:hover:not(.sd-card--active) {
    border-color: rgba(255, 122, 26, 0.45);
    background: rgba(255, 122, 26, 0.05);
  }

  &.sd-card--active {
    border-color: #ff7a1a;
    background: rgba(255, 122, 26, 0.09);
  }
}

.sd-name {
  font-size: 1em;
  font-weight: 800;
  letter-spacing: -0.01em;
}

.sd-card--active .sd-name {
  color: #ff7a1a;
}

.sd-stats {
  display: flex;
  flex-direction: column;
  gap: 0.1em;
  font-size: 0.72em;
  color: rgba(255, 255, 255, 0.62);
  font-variant-numeric: tabular-nums;
}

.sd-blurb {
  font-size: 0.7em;
  line-height: 1.35;
  color: rgba(255, 255, 255, 0.38);
}

/* ---- card-width variant: one row each, stats inline ---- */

.start-difficulty--rows {
  .start-difficulty-cards {
    display: flex;
    flex-direction: column;
    gap: 0.3em;
  }

  .sd-card {
    flex-direction: row;
    align-items: baseline;
    justify-content: space-between;
    gap: 0.5em;
    padding: 0.45em 0.6em;
  }

  .sd-name {
    font-size: 0.92em;
    flex: 0 0 auto;
  }

  .sd-stats {
    flex-direction: row;
    flex-wrap: wrap;
    justify-content: flex-end;
    gap: 0 0.5em;
    font-size: 0.68em;
    text-align: right;
  }
}
</style>
