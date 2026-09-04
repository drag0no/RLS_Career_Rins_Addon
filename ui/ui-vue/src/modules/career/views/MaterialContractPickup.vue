<template>
  <div
    class="material-loader-shell"
    v-bng-blur
    bng-ui-scope="materialContractPickup"
    v-bng-on-ui-nav:back,menu="close">
    <main class="material-loader">
      <header class="loader-header">
        <div>
          <div class="eyebrow">Material loading point</div>
          <h1>{{ data.material?.name || 'Material Loader' }}</h1>
          <p v-if="data.contract">
            {{ data.contract.sourceName }} <span class="route-arrow">→</span> {{ data.contract.destinationName }}
          </p>
        </div>
        <BngButton accent="secondary" @click="close">Back</BngButton>
      </header>

      <section v-if="!ready" class="state-panel">
        <h2>Connecting to loading equipment…</h2>
      </section>

      <section v-else-if="!data.available" class="state-panel error">
        <h2>Loader unavailable</h2>
        <p>{{ data.reason }}</p>
        <BngButton @click="close">Return</BngButton>
      </section>

      <template v-else>
        <section class="contract-progress">
          <div class="section-heading">
            <div>
              <span class="section-kicker">Active contract</span>
              <h2>Project progress</h2>
            </div>
            <div class="quote">{{ money(data.contract.quotedRewards?.money) }} total</div>
          </div>

          <div class="progress-track" aria-label="Contract delivery progress">
            <span class="delivered" :style="{ width: deliveredPercent + '%' }"></span>
            <span class="transit" :style="{ width: transitPercent + '%' }"></span>
          </div>

          <div class="progress-grid">
            <div><span>Delivered</span><strong>{{ amount(data.contract.deliveredAmount) }}</strong></div>
            <div><span>In transit</span><strong>{{ amount(data.contract.inTransitAmount) }}</strong></div>
            <div><span>Still to move</span><strong>{{ amount(data.contract.remainingAmount) }}</strong></div>
            <div><span>Paid so far</span><strong>{{ money(data.contract.paidMoney) }}</strong></div>
          </div>
        </section>

        <section class="loading-layout">
          <div class="load-controls">
            <div class="section-heading compact">
              <div>
                <span class="section-kicker">This trip</span>
                <h2>Choose load amount</h2>
              </div>
              <strong class="selected-amount">{{ amount(selectedAmount) }}</strong>
            </div>

            <template v-if="data.maximumLoad > 0">
              <BngSlider
                class="amount-slider"
                :min="1"
                :max="data.maximumLoad"
                :step="1"
                v-model="selectedAmount" />
              <div class="quick-actions">
                <BngButton
                  v-if="standardLoad > 0"
                  accent="secondary"
                  @click="selectStandardLoad">
                  Standard load ({{ amount(standardLoad) }})
                </BngButton>
                <BngButton accent="secondary" @click="selectedAmount = data.maximumLoad">Fill compatible space</BngButton>
              </div>
              <p class="load-note">
                The loader will distribute this amount across nearby compatible containers. You can return for the rest of the contract.
              </p>
            </template>
            <div v-else class="no-capacity">
              <strong>No compatible free space nearby</strong>
              <span>Bring a compatible {{ containerTypeLabel }} with empty capacity into the loading area.</span>
            </div>

            <p v-if="resultMessage" :class="['result-message', { error: resultError }]">{{ resultMessage }}</p>
          </div>

          <div class="equipment-panel">
            <div class="section-heading compact">
              <div>
                <span class="section-kicker">Nearby equipment</span>
                <h2>{{ amount(data.compatibleCapacity) }} compatible space</h2>
              </div>
            </div>

            <div v-if="data.equipment?.length" class="equipment-list">
              <article v-for="item in data.equipment" :key="`${item.vehId}-${item.containerId}`" :class="['equipment-card', { eligible: item.eligible }]">
                <div>
                  <strong>{{ item.vehicleName }}</strong>
                  <span>{{ item.containerName }}</span>
                </div>
                <div class="equipment-status">
                  <strong v-if="item.eligible">{{ amount(item.free) }} free</strong>
                  <strong v-else>{{ item.reason }}</strong>
                  <span>{{ amount(item.used) }} / {{ amount(item.capacity) }} used</span>
                </div>
              </article>
            </div>
            <div v-else class="no-equipment">No cargo containers were detected in the loading area.</div>
          </div>
        </section>

        <footer class="loader-actions">
          <div>
            <span>After loading</span>
            <strong>Route automatically switches to {{ data.contract.destinationName }}</strong>
          </div>
          <BngButton
            :disabled="data.maximumLoad <= 0 || loading || selectedAmount <= 0"
            @click="loadSelected">
            {{ loading ? 'Loading…' : `Load ${amount(selectedAmount)}` }}
          </BngButton>
        </footer>
      </template>
    </main>
  </div>
</template>

<script setup>
import { computed, onMounted, onUnmounted, reactive, ref, watch } from 'vue'
import { lua, useBridge } from '@/bridge'
import { BngButton, BngSlider } from '@/common/components/base'
import { vBngBlur, vBngOnUiNav } from '@/common/directives'
import { useUINavScope } from '@/services/uiNav'

useUINavScope('materialContractPickup')

const { events } = useBridge()
const ready = ref(false)
const loading = ref(false)
const selectedAmount = ref(0)
const resultMessage = ref('')
const resultError = ref(false)
const data = reactive({
  available: false,
  contract: null,
  material: null,
  equipment: [],
  compatibleCapacity: 0,
  maximumLoad: 0,
})

const standardLoad = computed(() => Math.min(data.contract?.standardLoad || 0, data.maximumLoad || 0))
const total = computed(() => Math.max(1, data.contract?.totalAmount || 1))
const deliveredPercent = computed(() => Math.min(100, ((data.contract?.deliveredAmount || 0) / total.value) * 100))
const transitPercent = computed(() => Math.min(100 - deliveredPercent.value, ((data.contract?.inTransitAmount || 0) / total.value) * 100))
const containerTypeLabel = computed(() => {
  if (data.material?.type === 'fluid') return 'tank'
  if (data.material?.type === 'dryBulk' || data.material?.type === 'cement') return 'bulk container'
  return 'secure cargo container'
})

function amount(value) {
  return `${Math.max(0, Math.round(Number(value) || 0)).toLocaleString()} ${data.material?.units || data.contract?.units || 'L'}`
}

function money(value) {
  return `$${Math.max(0, Math.round(Number(value) || 0)).toLocaleString()}`
}

function applyData(payload) {
  Object.assign(data, payload || {})
  ready.value = true
  loading.value = Boolean(payload?.loading)
  const preferred = Math.min(payload?.contract?.standardLoad || payload?.maximumLoad || 0, payload?.maximumLoad || 0)
  if (selectedAmount.value <= 0 || selectedAmount.value > (payload?.maximumLoad || 0)) selectedAmount.value = preferred
}

function applyResult(payload) {
  loading.value = false
  resultMessage.value = payload?.message || ''
  resultError.value = payload?.success === false
}

function selectStandardLoad() {
  selectedAmount.value = standardLoad.value || data.maximumLoad
}

function loadSelected() {
  if (loading.value || selectedAmount.value <= 0) return
  loading.value = true
  resultMessage.value = ''
  lua.career_modules_delivery_cargoScreen.loadMaterialContract(data.contract.id, Math.round(selectedAmount.value))
}

function close() {
  lua.career_modules_delivery_cargoScreen.closeMaterialContractPickupScreen(false)
}

watch(() => data.maximumLoad, max => {
  if (selectedAmount.value > max) selectedAmount.value = max
})

onMounted(() => {
  events.on('materialContractPickupData', applyData)
  events.on('materialContractPickupResult', applyResult)
  lua.career_modules_delivery_cargoScreen.requestMaterialContractPickupData()
})

onUnmounted(() => {
  events.off('materialContractPickupData', applyData)
  events.off('materialContractPickupResult', applyResult)
})
</script>

<style scoped lang="scss">
.material-loader-shell {
  width: 100%;
  height: 100%;
  display: grid;
  place-items: center;
  padding: 2rem;
  box-sizing: border-box;
  color: #fff;
  background: radial-gradient(circle at 70% 20%, rgba(255, 102, 0, 0.16), transparent 34%), rgba(5, 8, 10, 0.78);
}

.material-loader {
  width: min(1120px, 96vw);
  max-height: 92vh;
  overflow: auto;
  border: 1px solid rgba(255, 255, 255, 0.16);
  border-top: 4px solid #ff6600;
  border-radius: 4px;
  background: #111820;
  box-shadow: 0 1.5rem 5rem rgba(0, 0, 0, 0.6);
}

.loader-header,
.loader-actions,
.section-heading,
.equipment-card {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 1rem;
}

.loader-header {
  padding: 1.4rem 1.6rem;
  background: linear-gradient(100deg, #17232d, #10161c);
  border-bottom: 1px solid rgba(255, 255, 255, 0.12);
}

h1, h2, p { margin: 0; }
h1 { font-size: 2rem; line-height: 1.05; }
h2 { font-size: 1.15rem; }
.loader-header p { margin-top: 0.4rem; color: #c5ced5; }
.route-arrow { color: #ff6600; padding: 0 0.35rem; }
.eyebrow, .section-kicker, .loader-actions span { color: #ff8a3d; font-size: 0.74rem; font-weight: 800; letter-spacing: 0.11em; text-transform: uppercase; }

.contract-progress, .load-controls, .equipment-panel, .state-panel { padding: 1.35rem 1.6rem; }
.contract-progress { border-bottom: 1px solid rgba(255, 255, 255, 0.1); }
.quote, .selected-amount { color: #ffb27f; font-size: 1.2rem; }
.compact { margin-bottom: 1rem; }

.progress-track {
  position: relative;
  display: flex;
  height: 0.7rem;
  margin: 1rem 0;
  overflow: hidden;
  border-radius: 1rem;
  background: #303943;
}
.progress-track span { height: 100%; }
.progress-track .delivered { background: #55bd72; }
.progress-track .transit { background: #ff8a24; }

.progress-grid { display: grid; grid-template-columns: repeat(4, 1fr); gap: 0.7rem; }
.progress-grid div { padding: 0.75rem; background: #1b252e; border-radius: 3px; }
.progress-grid span, .equipment-card span { display: block; color: #aab6bf; font-size: 0.8rem; }
.progress-grid strong { display: block; margin-top: 0.2rem; font-size: 1.05rem; }

.loading-layout { display: grid; grid-template-columns: minmax(0, 1.12fr) minmax(300px, 0.88fr); }
.load-controls { border-right: 1px solid rgba(255, 255, 255, 0.1); }
.amount-slider { margin: 1.5rem 0 1rem; }
.quick-actions { display: flex; flex-wrap: wrap; gap: 0.5rem; }
.load-note { margin-top: 1rem; color: #aab6bf; line-height: 1.45; }

.equipment-list { display: grid; gap: 0.45rem; max-height: 250px; overflow: auto; }
.equipment-card { padding: 0.75rem; border-left: 3px solid #555f67; background: #192229; }
.equipment-card.eligible { border-left-color: #55bd72; }
.equipment-status { text-align: right; }
.equipment-status strong { display: block; max-width: 240px; }
.no-capacity, .no-equipment { display: grid; gap: 0.35rem; padding: 1rem; color: #c3ccd2; background: rgba(198, 60, 44, 0.14); border: 1px solid rgba(255, 93, 73, 0.3); }
.no-capacity strong { color: #ff8d7e; }
.result-message { margin-top: 0.8rem; color: #79d894; }
.result-message.error, .state-panel.error { color: #ff8d7e; }

.loader-actions { padding: 1rem 1.6rem; background: #0c1116; border-top: 1px solid rgba(255, 255, 255, 0.12); }
.loader-actions > div { display: grid; gap: 0.2rem; }

@media (max-width: 800px) {
  .loading-layout { grid-template-columns: 1fr; }
  .load-controls { border-right: 0; border-bottom: 1px solid rgba(255, 255, 255, 0.1); }
  .progress-grid { grid-template-columns: repeat(2, 1fr); }
}
</style>
