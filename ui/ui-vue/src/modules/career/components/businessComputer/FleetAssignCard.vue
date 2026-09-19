<template>
  <div class="fleet-assign-card">
    <div class="fleet-assign-card__image">
      <img
        :src="displayImage"
        :alt="displayName"
      />
      <span v-if="vehicle.cooldownSec > 0" class="status-badge status-badge--cooldown">Cooling down</span>
      <span v-else class="status-badge">Fleet</span>
    </div>
    <div class="fleet-assign-card__body">
      <div class="fleet-assign-card__title-block">
        <h3>{{ displayName }}</h3>
        <p v-if="sanctionedClassLabel || classStatusMessage" class="fleet-assign-card__class">{{ sanctionedClassLabel || classStatusMessage }}</p>
        <p v-if="effectiveHpLabel" class="fleet-assign-card__hp">
          {{ effectiveHpLabel }}
          <span v-if="vehicle.dynoStatus === 1" class="dyno-tag">Dyno Certified</span>
          <span v-else-if="vehicle.dynoStatus === -1" class="dyno-tag dyno-tag--required">Dyno Required</span>
        </p>
      </div>
      <button
        type="button"
        class="btn btn-primary fleet-assign-card__button"
        @click.stop="$emit('assign', vehicle)"
        @mousedown.stop
        data-focusable
      >
        Assign
      </button>
    </div>
  </div>
</template>

<script setup>
import { computed } from "vue"
import { formatSanctionedClassWithBucket } from "../../utils/sanctionedClassFormat"

const props = defineProps({
  vehicle: {
    type: Object,
    required: true
  }
})

const displayName = computed(() => {
  const v = props.vehicle
  if (!v) return "Vehicle"
  return v.vehicleName || v.name || `Vehicle #${v.vehicleId ?? v.id ?? ""}`
})

const displayImage = computed(() => {
  const v = props.vehicle
  const src = v?.vehicleImage
  if (typeof src === "string" && src.length > 0) return src
  return "/ui/images/appDefault.png"
})

const sanctionedClassLabel = computed(() => {
  return formatSanctionedClassWithBucket(props.vehicle?.fleetSanctionedClassLabel, props.vehicle?.fleetEffectivePw)
})

const classStatusMessage = computed(() => {
  return typeof props.vehicle?.fleetClassStatusMessage === "string" ? props.vehicle.fleetClassStatusMessage : ""
})

const effectiveHpLabel = computed(() => {
  const hp = Number(props.vehicle?.fleetEffectiveHp)
  const pw = Number(props.vehicle?.fleetEffectivePw)
  const parts = []
  if (Number.isFinite(hp) && hp > 0) parts.push(`${Math.round(hp)} HP`)
  if (Number.isFinite(pw) && pw > 0) parts.push(`${(Math.round(pw * 100) / 100).toFixed(2)} hp/kg`)
  return parts.join(" · ")
})

defineEmits(["assign"])
</script>

<style scoped lang="scss">
.fleet-assign-card {
  background: rgba(23, 23, 23, 0.55);
  border: 1px solid rgba(255, 255, 255, 0.1);
  border-radius: 0.75em;
  padding: 1em;
  display: flex;
  flex-direction: column;
  gap: 0.75em;
  transition: border-color 0.2s, transform 0.2s;

  &:hover {
    border-color: rgba(245, 73, 0, 0.5);
    transform: translateY(-2px);
  }
}

.fleet-assign-card__image {
  position: relative;
  width: 100%;
  border-radius: 0.5em;
  overflow: hidden;
  background: rgba(0, 0, 0, 0.35);

  img {
    width: 100%;
    height: auto;
    display: block;
  }

  .status-badge {
    position: absolute;
    top: 0.5em;
    right: 0.5em;
    padding: 0.25em 0.65em;
    border-radius: 999px;
    font-size: 0.75em;
    font-weight: 500;
    background: rgba(34, 197, 94, 0.75);
    color: white;
    border: none;
  }

  .status-badge--cooldown {
    background: rgba(220, 130, 20, 0.92);
  }
}

.dyno-tag {
  font-size: 0.8em;
  color: #4ade80;
  background: rgba(34, 197, 94, 0.18);
  border: 1px solid rgba(34, 197, 94, 0.4);
  padding: 0.1em 0.35em;
  border-radius: 3px;
  margin-left: 0.4em;
}

.dyno-tag--required {
  color: #facc15;
  background: rgba(234, 179, 8, 0.18);
  border-color: rgba(234, 179, 8, 0.4);
}

.fleet-assign-card__body {
  display: flex;
  flex-direction: column;
  gap: 0.5em;
}

.fleet-assign-card__class {
  margin: 0.25em 0 0;
  font-size: 0.9em;
  font-weight: 600;
  color: rgba(255, 220, 180, 0.95);
}

.fleet-assign-card__hp {
  margin: 0.35em 0 0;
  font-size: 0.85em;
  color: rgba(255, 255, 255, 0.55);
}

.fleet-assign-card__title-block h3 {
  margin: 0;
  color: #fff;
  font-size: 1em;
  font-weight: 600;
}

.fleet-assign-card__button {
  width: 100%;
  margin-top: 0.25em;
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
</style>
