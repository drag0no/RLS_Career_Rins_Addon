<template>
  <div class="start-slider">
    <div class="start-slider-header">
      <label class="start-slider-label" :for="inputId">{{ labelText }}</label>
      <span class="start-slider-value" :class="{ 'start-slider-value--baseline': isAtBaseline }">{{ displayValue }}</span>
    </div>
    <div
      class="start-slider-track"
      :style="{ '--baseline-ratio': standardRatio, '--fill-ratio': fillRatio }">
      <!-- The rail is drawn separately so the input can be transparent. Painting
           the track on the input itself forced a choice between hiding the
           baseline marker behind it or stacking the marker on top of the thumb;
           with three layers the thumb simply sits above both. -->
      <span class="start-slider-rail" aria-hidden="true" />
      <span
        v-if="showBaselineMarker"
        class="start-slider-baseline-marker"
        aria-hidden="true" />
      <input
        :id="inputId"
        type="range"
        class="start-slider-input"
        :min="min"
        :max="max"
        :step="step"
        :value="modelValue"
        :disabled="disabled"
        :aria-valuetext="displayValue"
        @input="onInput" />
    </div>
    <div v-if="leftLabel || rightLabel" class="start-slider-scale">
      <span class="start-slider-scale-end">{{ leftLabel }}</span>
      <span class="start-slider-scale-end start-slider-scale-end--right">{{ rightLabel }}</span>
    </div>
  </div>
</template>

<script>
let uid = 0
</script>

<script setup>
import { computed } from "vue"

const props = defineProps({
  label: { type: String, required: true },
  modelValue: { type: Number, default: 1 },
  min: { type: Number, default: 0.25 },
  max: { type: Number, default: 3 },
  step: { type: Number, default: 0.25 },
  format: { type: Function, default: null },
  disabled: { type: Boolean, default: false },
  leftLabel: { type: String, default: "" },
  rightLabel: { type: String, default: "" },
  standardValue: { type: Number, default: 1 },
  /** Shown in the label when value equals standardValue, e.g. "(Standard)". */
  baselineSuffix: { type: String, default: "" },
  showBaselineMarker: { type: Boolean, default: true },
})

const emit = defineEmits(["update:modelValue"])

const inputId = `start-slider-${++uid}`

const isAtBaseline = computed(() => {
  return Math.abs(props.modelValue - props.standardValue) < 0.001
})

/**
 * 0..1 rather than a percentage. The stylesheet turns it into a position along
 * the thumb's own travel, which is inset by half a thumb at each end — a plain
 * percentage of the full width put the fill edge past the thumb's centre.
 */
function ratioOf(value) {
  const range = props.max - props.min
  if (range <= 0) return 0.5
  const clamped = Math.min(props.max, Math.max(props.min, value))
  return (clamped - props.min) / range
}

const standardRatio = computed(() => ratioOf(props.standardValue))

/** Drives the filled part of the track, so the value is readable at a glance. */
const fillRatio = computed(() => ratioOf(props.modelValue))

const labelText = computed(() => {
  if (isAtBaseline.value && props.baselineSuffix) {
    return `${props.label} ${props.baselineSuffix}`
  }
  return props.label
})

const displayValue = computed(() => {
  if (props.format) return props.format(props.modelValue)
  return `${Math.round(Number(props.modelValue) * 100)}%`
})

function onInput(event) {
  emit("update:modelValue", Number(event.target.value))
}
</script>

<style lang="scss" scoped>
@use "../careerStartTheme.scss" as theme;

.start-slider {
  display: flex;
  flex-direction: column;
  gap: 0.45em;
}

.start-slider-header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 0.5em;
  min-height: 1.2em;
}

.start-slider-label {
  font-weight: 600;
  font-size: 0.88em;
  color: rgba(255, 255, 255, 0.75);
}

.start-slider-value {
  font-size: 0.82em;
  font-weight: 600;
  color: theme.$start-accent-muted;
  font-variant-numeric: tabular-nums;
  text-align: right;
}

/* Always shown now, so at the default it stays quiet rather than reading as a
   change the player made. */
.start-slider-value--baseline {
  color: rgba(255, 255, 255, 0.4);
  font-weight: 500;
}

.start-slider-track {
  position: relative;
  display: flex;
  align-items: center;
  padding: 0.25em 0;

  /* Shared by the rail, the marker and the thumb so all three agree. Callers
     override these two to get a smaller slider; nothing else needs changing. */
  --thumb-size: 0.95em;
  --rail-height: 0.4em;
  --track-pos: calc(var(--thumb-size) / 2 + (100% - var(--thumb-size)) * var(--fill-ratio, 0.5));
  --baseline-pos: calc(var(--thumb-size) / 2 + (100% - var(--thumb-size)) * var(--baseline-ratio, 0.5));
}

/**
 * A tick at the difficulty's own value, so "how far have I moved this from
 * Standard" is answerable without reading the number. It sits above the input
 * because the input paints its own track over anything behind it.
 */
.start-slider-rail {
  position: absolute;
  z-index: 0;
  left: 0;
  right: 0;
  top: 50%;
  transform: translateY(-50%);
  height: var(--rail-height);
  border-radius: 999px;
  pointer-events: none;

  /* Flat: the filled part is the value, nothing else needs to say so. */
  background: linear-gradient(
    90deg,
    #ff7a1a 0%,
    #ff7a1a var(--track-pos),
    rgba(71, 85, 105, 0.5) var(--track-pos)
  );
}

.start-slider-baseline-marker {
  position: absolute;
  top: 50%;
  left: var(--baseline-pos);
  transform: translate(-50%, -50%);
  z-index: 1;
  width: 2px;
  height: 0.8em;
  border-radius: 1px;
  background: rgba(255, 255, 255, 0.45);
  pointer-events: none;
}

.start-slider-scale {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 0.5em;
  font-size: 0.72em;
  color: rgba(255, 255, 255, 0.45);
  padding: 0 0.1em;
}

.start-slider-scale-end {
  flex: 1 1 0;

  &--right {
    text-align: right;
  }
}

.start-slider-input {
  position: relative;
  z-index: 2;
  width: 100%;
  /* Exactly the thumb: the track centres this box, so the thumb lands on the
     rail without an offset that has to be kept in step with the height. */
  height: var(--thumb-size);
  appearance: none;
  background: transparent;
  outline: none;
  cursor: pointer;

  &::-webkit-slider-runnable-track {
    background: transparent;
    height: 100%;
  }

  &::-moz-range-track {
    background: transparent;
  }

  &::-webkit-slider-thumb {
    appearance: none;
    width: var(--thumb-size);
    height: var(--thumb-size);
    border-radius: 50%;
    background: #ff7a1a;
    border: 2px solid #0b0f19;
    cursor: pointer;
  }

  &::-moz-range-thumb {
    width: 0.95em;
    height: 0.95em;
    border-radius: 50%;
    background: #ff7a1a;
    border: 2px solid #0b0f19;
    cursor: pointer;
  }

  &:hover::-webkit-slider-thumb,
  &:focus-visible::-webkit-slider-thumb {
    background: #ff9647;
  }

  &:disabled {
    opacity: 0.4;
    cursor: not-allowed;
  }
}
</style>
