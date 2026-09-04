<template>
  <div :class="['rt-promo-panel', { 'rt-promo-panel--card': variant === 'card' }]" @click.stop>
    <h2 v-if="title" :class="variant === 'card' ? 'rt-promo-panel__title rt-promo-panel__title--card' : 'rt-promo-panel__title'">
      {{ title }}
    </h2>
    <p v-if="body" class="rt-promo-panel__body">{{ body }}</p>
    <img v-if="imageUrl" class="rt-promo-panel__img" :src="imageUrl" alt="" />
    <p v-if="feeDisplay" class="rt-promo-panel__fee">Registration fee: ${{ feeDisplay }}</p>
    <div v-if="$slots.default" class="rt-promo-panel__actions">
      <slot />
    </div>
  </div>
</template>

<script setup>
import { computed } from "vue"

const props = defineProps({
  title: { type: String, default: "" },
  body: { type: String, default: "" },
  imageUrl: { type: String, default: "" },
  fee: { type: [Number, String], default: null },
  variant: { type: String, default: "modal" },
})

const feeDisplay = computed(() => {
  if (props.fee === null || props.fee === undefined || props.fee === "") return ""
  const n = Number(props.fee)
  return Number.isFinite(n) ? n.toLocaleString() : ""
})
</script>

<style lang="scss">
.rt-promo-overlay {
  position: fixed;
  inset: 0;
  z-index: 13060;
  display: flex;
  align-items: center;
  justify-content: center;
  background: rgba(0, 0, 0, 0.58);
  pointer-events: auto;
}

.rt-promo-panel {
  max-width: 32rem;
  width: calc(100% - 2rem);
  margin: 1rem;
  padding: 1.5rem 1.75rem;
  border-radius: 0.5rem;
  background: rgba(24, 20, 16, 0.98);
  border: 1px solid rgba(245, 73, 0, 0.45);
  box-shadow: 0 12px 40px rgba(0, 0, 0, 0.55);
  color: #f0ebe4;
}

.rt-promo-panel--card {
  max-width: none;
  width: auto;
  margin: 0;
  padding: 1em 1.24em;
  border-radius: 0.75em;
  background: rgba(28, 22, 16, 0.92);
  display: flex;
  flex-direction: column;
  gap: 0.65em;
  box-shadow: none;
}

.rt-promo-panel__title {
  margin: 0 0 0.75rem;
  font-size: 1.35rem;
  font-weight: 700;
  color: #fff;
}

.rt-promo-panel__title--card {
  margin: 0;
  font-size: 1.1em;
  font-weight: 600;
}

.rt-promo-panel__body {
  margin: 0 0 1rem;
  line-height: 1.5;
  white-space: pre-wrap;
  color: rgba(240, 235, 228, 0.92);
  font-size: 0.95rem;
}

.rt-promo-panel--card .rt-promo-panel__body {
  margin: 0;
  font-size: 0.9em;
  color: rgba(255, 255, 255, 0.78);
}

.rt-promo-panel__img {
  display: block;
  max-width: 100%;
  max-height: 12rem;
  margin: 0 0 1rem;
  border-radius: 0.5rem;
  object-fit: cover;
}

.rt-promo-panel--card .rt-promo-panel__img {
  margin: 0;
}

.rt-promo-panel__fee {
  margin: 0 0 1rem;
  font-weight: 600;
  color: rgba(255, 200, 120, 0.95);
}

.rt-promo-panel--card .rt-promo-panel__fee {
  margin: 0;
  font-size: 0.88em;
}

.rt-promo-panel__actions {
  display: flex;
  flex-wrap: wrap;
  gap: 0.65rem;
  justify-content: flex-end;
}

.rt-promo-overlay .btn,
.rt-promo-panel .btn {
  padding: 0.55em 1.25em;
  border-radius: 8px;
  font-weight: 600;
  font-size: 0.9em;
  cursor: pointer;
  border: none;
  transition: background 0.15s, opacity 0.15s, border-color 0.15s;
}

.rt-promo-overlay .btn-primary,
.rt-promo-panel .btn-primary {
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

.rt-promo-overlay .btn-secondary,
.rt-promo-panel .btn-secondary {
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

.rt-promo-fade-enter-active,
.rt-promo-fade-leave-active {
  transition: opacity 0.2s ease;

  .rt-promo-panel {
    transition: transform 0.2s ease, opacity 0.2s ease;
  }
}

.rt-promo-fade-enter-from,
.rt-promo-fade-leave-to {
  opacity: 0;

  .rt-promo-panel {
    transform: scale(0.95);
    opacity: 0;
  }
}
</style>
