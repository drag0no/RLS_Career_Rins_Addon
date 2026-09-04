<template>
  <Teleport to="body">
    <Transition name="roadside-repair">
      <div
        v-if="visible"
        class="roadside-repair-root"
        role="dialog"
        aria-modal="true"
        aria-label="Roadside repair"
        @keydown.esc.prevent="close"
      >
        <div class="roadside-repair-backdrop" @click="close" />
        <aside class="roadside-repair-panel" tabindex="-1" ref="panelRef">
          <p class="roadside-repair-blurb">Instantly repair your vehicle on the go.</p>

          <div class="roadside-repair-meta">
            <span class="roadside-repair-label">Vehicle:</span>
            <span class="roadside-repair-value">{{ vehicleName }}</span>
          </div>

          <button
            type="button"
            class="roadside-repair-option"
            :disabled="!privateOption?.canPay || busy"
            @click="choosePrivate"
          >
            <span>Private pay:</span>
            <span class="roadside-repair-price">{{ formatMoney(privateOption?.price) }}</span>
          </button>

          <button
            v-if="insuranceOption"
            type="button"
            class="roadside-repair-option"
            :disabled="!insuranceOption.canPay || busy"
            @click="chooseInsurance"
          >
            <span>Insurance Claim:</span>
            <span class="roadside-repair-price">{{ formatMoney(insuranceOption.price) }}</span>
          </button>

          <button type="button" class="roadside-repair-cancel" :disabled="busy" @click="close">
            Cancel
          </button>
        </aside>
      </div>
    </Transition>
  </Teleport>
</template>

<script setup>
import { nextTick, onBeforeUnmount, onMounted, ref } from "vue"
import { lua, useBridge } from "@/bridge"
import { useAppLayoutsStore } from "@/modules/apps/appLayoutsStore"

const bridge = useBridge()
const appLayouts = useAppLayoutsStore()
const visible = ref(false)
const busy = ref(false)
const vehicleName = ref("")
const invVehId = ref(null)
const privateOption = ref(null)
const insuranceOption = ref(null)
const panelRef = ref(null)
let weHidHudApps = false

const formatMoney = amount => {
  const n = Number(amount)
  if (!Number.isFinite(n)) return "$0.00"
  return `$${n.toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`
}

const normalizePayload = raw => {
  if (Array.isArray(raw)) {
    raw = raw.find(entry => entry && typeof entry === "object") || raw[0]
  }
  if (!raw || typeof raw !== "object") return null
  return raw
}

const hideHudApps = () => {
  if (weHidHudApps) return
  appLayouts.setVisible(false)
  weHidHudApps = true
}

const restoreHudApps = () => {
  if (!weHidHudApps) return
  appLayouts.setVisible(true)
  weHidHudApps = false
}

const reset = () => {
  visible.value = false
  busy.value = false
  vehicleName.value = ""
  invVehId.value = null
  privateOption.value = null
  insuranceOption.value = null
  restoreHudApps()
}

const onPopup = (...args) => {
  const data = normalizePayload(args.length > 0 ? args[0] : null)
  if (!data || data.visible === false) {
    reset()
    return
  }

  vehicleName.value = String(data.vehicleName || "Vehicle")
  invVehId.value = data.invVehId ?? null
  privateOption.value = data.private || null
  insuranceOption.value = data.insurance || null
  busy.value = false
  hideHudApps()
  visible.value = true

  nextTick(() => {
    panelRef.value?.focus?.()
  })
}

const close = () => {
  if (busy.value) return
  reset()
  lua.career_modules_insurance_repairScreen.closeRoadsidePopup()
}

const startRepair = (isInsuranceRepair, option) => {
  if (!option || !option.canPay || invVehId.value == null || busy.value) return
  busy.value = true
  lua.career_modules_insurance_repairScreen.startRepairInGarage(invVehId.value, {
    repairTime: 0,
    isInsuranceRepair: !!isInsuranceRepair,
    cost: {
      repairTimeCost: Number(option.repairTimeCost) || 0,
      deductible: Number(option.deductible != null ? option.deductible : option.damageCost) || 0,
    },
  })
}

const choosePrivate = () => startRepair(false, privateOption.value)
const chooseInsurance = () => startRepair(true, insuranceOption.value)

onMounted(() => {
  bridge.events.on("roadsideRepairPopup", onPopup)
  if (typeof window !== "undefined" && window.vueEventBus && window.vueEventBus !== bridge.events) {
    window.vueEventBus.on("roadsideRepairPopup", onPopup)
  }
})

onBeforeUnmount(() => {
  bridge.events.off("roadsideRepairPopup", onPopup)
  if (typeof window !== "undefined" && window.vueEventBus && window.vueEventBus !== bridge.events) {
    window.vueEventBus.off("roadsideRepairPopup", onPopup)
  }
  reset()
})
</script>

<style scoped lang="scss">
.roadside-repair-root {
  position: fixed;
  inset: 0;
  z-index: 13500;
  display: flex;
  align-items: center;
  justify-content: center;
  padding: max(1.5rem, env(safe-area-inset-top)) max(1.5rem, env(safe-area-inset-right))
    max(1.5rem, env(safe-area-inset-bottom)) max(1.5rem, env(safe-area-inset-left));
  pointer-events: auto;
  font-family: var(--fnt-defs, "Noto Sans", Arial, sans-serif);
}

.roadside-repair-backdrop {
  position: absolute;
  inset: 0;
  background: rgba(0, 0, 0, 0.28);
}

.roadside-repair-panel {
  position: relative;
  z-index: 1;
  width: min(22rem, calc(100vw - 3rem));
  display: flex;
  flex-direction: column;
  gap: 0.7rem;
  padding: 1rem 1.1rem 0.9rem;
  border-radius: 8px;
  background: rgba(18, 24, 36, 0.94);
  border: 1px solid rgba(255, 255, 255, 0.08);
  box-shadow: 0 10px 28px rgba(0, 0, 0, 0.4);
  color: #f3f5f8;
  outline: none;
}

.roadside-repair-blurb {
  margin: 0;
  font-size: 0.95rem;
  line-height: 1.35;
  color: rgba(243, 245, 248, 0.88);
}

.roadside-repair-meta {
  display: flex;
  justify-content: space-between;
  gap: 0.75rem;
  font-size: 0.92rem;
}

.roadside-repair-label {
  color: rgba(243, 245, 248, 0.65);
}

.roadside-repair-value {
  font-weight: 600;
  text-align: right;
}

.roadside-repair-option,
.roadside-repair-cancel {
  appearance: none;
  border: 1px solid rgba(255, 255, 255, 0.12);
  border-radius: 6px;
  background: rgba(255, 255, 255, 0.04);
  color: inherit;
  font: inherit;
  cursor: pointer;
  transition: background 0.12s ease, border-color 0.12s ease, opacity 0.12s ease;
}

.roadside-repair-option {
  display: flex;
  justify-content: space-between;
  align-items: center;
  gap: 0.75rem;
  padding: 0.7rem 0.8rem;
  text-align: left;
}

.roadside-repair-option:hover:not(:disabled) {
  background: rgba(255, 140, 40, 0.18);
  border-color: rgba(255, 140, 40, 0.55);
}

.roadside-repair-option:disabled {
  opacity: 0.45;
  cursor: not-allowed;
}

.roadside-repair-price {
  font-weight: 700;
  color: #ff9a3c;
  white-space: nowrap;
}

.roadside-repair-cancel {
  margin-top: 0.15rem;
  padding: 0.45rem 0.7rem;
  font-size: 0.85rem;
  color: rgba(243, 245, 248, 0.75);
}

.roadside-repair-cancel:hover:not(:disabled) {
  background: rgba(255, 255, 255, 0.08);
}

.roadside-repair-enter-active,
.roadside-repair-leave-active {
  transition: opacity 0.16s ease;
}

.roadside-repair-enter-active .roadside-repair-panel,
.roadside-repair-leave-active .roadside-repair-panel {
  transition: transform 0.16s ease, opacity 0.16s ease;
}

.roadside-repair-enter-from,
.roadside-repair-leave-to {
  opacity: 0;
}

.roadside-repair-enter-from .roadside-repair-panel,
.roadside-repair-leave-to .roadside-repair-panel {
  opacity: 0;
  transform: translateY(0.4rem) scale(0.98);
}
</style>
