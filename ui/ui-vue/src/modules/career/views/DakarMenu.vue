<template>
  <div class="dakar-shell">
    <div class="dakar-panel">
      <header class="topbar">
        <div>
          <h1>Dakar</h1>
          <p>{{ subtitle }}</p>
        </div>
        <BngButton :accent="ACCENTS.secondary" @click="close">Close</BngButton>
      </header>

      <div class="tabs">
        <BngButton :accent="activeTab === 'signup' ? ACCENTS.primary : ACCENTS.secondary" @click="activeTab = 'signup'">Event Sign Up</BngButton>
        <BngButton :accent="activeTab === 'accolades' ? ACCENTS.primary : ACCENTS.secondary" @click="activeTab = 'accolades'">Dakar Accolades</BngButton>
      </div>

      <section v-if="activeTab === 'start'" class="start-confirm">
        <h2>Dakar Start</h2>
        <p>Begin the run when you are ready.</p>
        <div class="details-grid">
          <div class="detail">
            <span>Class</span>
            <strong>{{ data.pending?.classLabel || data.classInfo?.label || 'Unlimited' }}</strong>
          </div>
          <div class="detail">
            <span>Repair Kits</span>
            <strong>{{ data.pending?.repairsLeft || 0 }}</strong>
          </div>
        </div>
        <BngButton class="signup-button" :accent="ACCENTS.primary" @click="startEvent">Start Event</BngButton>
      </section>

      <section v-else-if="showIntroScreen" class="intro">
        <div class="intro-copy">
          <h2>The desert does not care how fast you are.</h2>
          <p>Read the land, protect the machine, and keep moving. Dakar rewards the driver who can finish what they start.</p>
        </div>

        <div class="intro-list">
          <div>Use the checkpoint photo, name, and distance to navigate.</div>
          <div>No GPS route is provided once the Dakar begins.</div>
          <div>Checkpoint markers only appear when you are close.</div>
          <div>Repair Kits must fit in your cargo boxes and add time penalties when used.</div>
          <div>Placement and time bonus are revealed after the finish.</div>
        </div>

        <label class="intro-check">
          <input type="checkbox" v-model="dontShowIntroAgain">
          <span>Do not show again</span>
        </label>

        <BngButton class="signup-button" :accent="ACCENTS.primary" @click="continueIntro">Continue</BngButton>
      </section>

      <section v-else-if="activeTab === 'signup'" class="signup">
        <div v-if="data.setupBlockedReason" class="blocked-banner">
          {{ data.setupBlockedReason }}
        </div>

        <div class="class-section">
          <div class="section-label">Class:</div>
          <div class="class-breakdown">
            <div v-for="classId in classOrder" :key="`${classId}-description`" class="class-description" :class="{ selected: data.classInfo?.id === classId }">
              <strong>{{ classTitle(classId) }} Class <span>{{ classes[classId]?.checkpointCount || 0 }} CP</span></strong>
              <span>{{ classDescriptions[classId] || 'Dakar eligible vehicles.' }}</span>
            </div>
          </div>
        </div>

        <div class="registration-section">
          <div class="section-label">Registration Info:</div>
          <div class="details-grid">
            <div class="detail">
              <span>Registered Vehicle</span>
              <strong>{{ data.classInfo?.vehicleName || 'No vehicle detected' }}</strong>
            </div>
            <div class="detail">
              <span>Cargo Space</span>
              <strong>{{ cargoSpaceLabel }}</strong>
            </div>
            <div class="detail kit-detail">
              <span>Repair Kits Ordered</span>
              <div class="kit-controls">
                <BngButton :accent="ACCENTS.secondary" :disabled="kitCount <= 0" @click="kitCount--">-</BngButton>
                <strong>{{ kitCount }}</strong>
                <BngButton :accent="ACCENTS.secondary" :disabled="kitCount >= maxKits" @click="kitCount++">+</BngButton>
              </div>
            </div>
            <div class="detail">
              <span>Repair Kit Cost</span>
              <strong>{{ money(data.repairKit.cost) }}</strong>
            </div>
          </div>
        </div>

        <div class="totals">
          <span>{{ kitCount * (data.repairKit.slots || 0) }} cargo slots</span>
          <span>{{ kitCount * (data.repairKit.weightKg || 0) }} kg</span>
          <strong>{{ money(kitCount * (data.repairKit.cost || 0)) }}</strong>
        </div>

        <div v-if="data.lastResult && props.tab === 'result'" class="result">
          <h2>{{ data.lastResult.placement }}</h2>
          <div class="result-grid">
            <span>Time</span><strong>{{ time(data.lastResult.adjustedSeconds) }}</strong>
            <span>Target</span><strong>{{ time(data.lastResult.targetSeconds) }}</strong>
            <span>Penalty</span><strong>{{ time(data.lastResult.repairPenaltySeconds) }}</strong>
            <span>Reward</span><strong>{{ money(data.lastResult.totalReward) }}</strong>
          </div>
        </div>

        <BngButton class="signup-button" :accent="ACCENTS.primary" :disabled="data.phase === 'active' || !!data.setupBlockedReason" @click="signUp">Sign Up</BngButton>
      </section>

      <section v-else class="accolades">
        <div v-for="acc in data.accolades" :key="acc.id" class="accolade">
          <div>
            <h2>{{ acc.title }}</h2>
            <p>{{ acc.description }}</p>
            <div class="progress"><span :style="{ width: progressWidth(acc) }"></span></div>
            <div class="accolade-meta">
              <small>{{ acc.progress }} / {{ acc.target }}</small>
              <strong>{{ acc.rewardLabel || money(acc.rewardMoney) }}</strong>
            </div>
          </div>
          <BngButton :accent="acc.ready ? ACCENTS.primary : ACCENTS.secondary" :disabled="!acc.ready" @click="claim(acc.id)">
            {{ acc.claimed ? 'Claimed' : 'Claim' }}
          </BngButton>
        </div>
      </section>
    </div>
  </div>
</template>

<script setup>
import { computed, onMounted, onUnmounted, reactive, ref, watch } from 'vue'
import { BngButton, ACCENTS } from '@/common/components/base'
import { useBridge } from '@/bridge'

const props = defineProps({
  tab: {
    type: String,
    default: 'signup'
  }
})

const { events } = useBridge()
const activeTab = ref(['accolades', 'start'].includes(props.tab) ? props.tab : 'signup')
const kitCount = ref(0)
const introDismissedThisOpen = ref(false)
const dontShowIntroAgain = ref(false)
const data = reactive({
  phase: 'idle',
  classInfo: null,
  setupBlockedReason: null,
  showIntro: false,
  classes: {},
  classOrder: [],
  repairKit: {},
  pending: null,
  accolades: [],
  lastResult: null
})

const classes = computed(() => data.classes || {})
const classOrder = computed(() => data.classOrder || [])
const maxKits = computed(() => Math.max(0, data.repairKit?.maxByCargo || 0))
const subtitle = computed(() => data.phase === 'signedUp' ? 'Proceed to the Dakar start' : 'Navigation and endurance')
const showIntroScreen = computed(() => activeTab.value === 'signup' && data.showIntro && !introDismissedThisOpen.value)
const classDescriptions = {
  SSV: 'Side by Side Vehicles, UTVs, and Buggies.',
  Raid: 'Pickup and SUV bodies only.',
  Heavy: 'Stambecco, MD-series, and T-series.',
  Unlimited: "Everything else that doesn't fit."
}
const cargoSpaceLabel = computed(() => {
  const slots = data.repairKit?.freeCargoSlots || 0
  const boxes = data.repairKit?.cargoContainerCount || 0
  if (!boxes) return `${slots} slots`
  return `${slots} slots / ${boxes} ${boxes === 1 ? 'box' : 'boxes'}`
})

function applyData(payload) {
  if (!payload) return
  data.phase = payload.phase || 'idle'
  data.classInfo = payload.classInfo || null
  data.setupBlockedReason = payload.setupBlockedReason || null
  data.showIntro = payload.showIntro === true
  data.classes = payload.classes || {}
  data.classOrder = payload.classOrder || []
  data.repairKit = payload.repairKit || {}
  data.pending = payload.pending || null
  data.accolades = payload.accolades || []
  data.lastResult = payload.lastResult || null
  kitCount.value = Math.min(kitCount.value, maxKits.value)
}

function luaString(value) {
  return `"${String(value).replace(/\\/g, '\\\\').replace(/"/g, '\\"')}"`
}

function callDakar(expression) {
  window.bngApi.engineLua(`local name = overhaul_maps and overhaul_maps.getOptionalFeatureExtension and overhaul_maps.getOptionalFeatureExtension('dakar'); local feature = name and extensions[name]; if feature then feature.${expression} end`)
}

function refresh() {
  callDakar('requestDakarMenuData()')
}

function money(value) {
  return `$${Math.round(value || 0).toLocaleString()}`
}

function time(seconds) {
  seconds = Math.max(0, Math.floor(seconds || 0))
  return `${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, '0')}`
}

function progressWidth(acc) {
  return `${Math.min(100, Math.round((acc.progress / Math.max(1, acc.target)) * 100))}%`
}

function classTitle(classId) {
  return classes.value[classId]?.label || classId
}

function signUp() {
  callDakar(`signUp(${Math.max(0, Math.floor(kitCount.value || 0))})`)
}

function continueIntro() {
  introDismissedThisOpen.value = true
  callDakar(`dismissIntro(${dontShowIntroAgain.value ? 'true' : 'false'})`)
}

function startEvent() {
  callDakar('startEvent()')
}

function claim(id) {
  callDakar(`claimAccolade(${luaString(id)})`)
}

function close() {
  callDakar('closeMenu()')
}

watch(() => props.tab, tab => {
  if (tab === 'accolades') activeTab.value = 'accolades'
  if (tab === 'start') activeTab.value = 'start'
  if (tab === 'signup' || tab === 'result') activeTab.value = 'signup'
})

onMounted(() => {
  events.on('dakarData', applyData)
  refresh()
})

onUnmounted(() => {
  events.off('dakarData', applyData)
})
</script>

<style scoped lang="scss">
.dakar-shell {
  min-height: 100vh;
  color: white;
  display: flex;
  align-items: center;
  justify-content: center;
  background: rgba(0, 0, 0, 0.55);
}

.dakar-panel {
  width: min(900px, 86vw);
  max-height: 86vh;
  overflow: auto;
  background: rgba(18, 18, 18, 0.94);
  border: 1px solid rgba(255, 255, 255, 0.14);
  border-radius: 8px;
  padding: 22px;
}

.topbar,
.tabs,
.totals,
.accolade {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 12px;
}

h1,
h2,
p {
  margin: 0;
}

.topbar p,
.detail span,
.totals,
.accolade p,
.accolade small {
  color: #cfcfcf;
}

.accolade-meta {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 12px;
}

.accolade-meta strong {
  color: #f5a623;
  white-space: nowrap;
}

.tabs {
  justify-content: flex-start;
  margin: 18px 0;
}

.class-section,
.registration-section {
  display: grid;
  gap: 10px;
}

.registration-section {
  margin-top: 22px;
}

.section-label {
  color: #f5a623;
  font-size: 0.78rem;
  font-weight: 800;
  letter-spacing: 0.06em;
  text-transform: uppercase;
}

.details-grid,
.class-breakdown {
  display: grid;
  gap: 10px;
}

.details-grid {
  grid-template-columns: repeat(2, 1fr);
}

.class-breakdown {
  grid-template-columns: repeat(2, 1fr);
}

.class-description,
.detail,
.totals,
.result,
.intro-list,
.blocked-banner,
.accolade {
  background: rgba(255, 255, 255, 0.08);
  border-radius: 6px;
  padding: 12px;
}

.intro {
  display: grid;
  gap: 14px;
}

.intro-copy {
  display: grid;
  gap: 8px;
}

.intro-copy h2 {
  font-size: 1.35rem;
}

.intro-copy p {
  color: #d9d9d9;
  line-height: 1.4;
}

.intro-list {
  display: grid;
  gap: 8px;
}

.intro-list div {
  position: relative;
  padding-left: 18px;
  color: #efefef;
}

.intro-list div::before {
  content: "";
  position: absolute;
  left: 0;
  top: 0.55em;
  width: 7px;
  height: 7px;
  border-radius: 50%;
  background: #f5a623;
}

.intro-check {
  display: inline-flex;
  align-items: center;
  gap: 8px;
  color: #cfcfcf;
  width: fit-content;
}

.intro-check input {
  width: 16px;
  height: 16px;
}

.blocked-banner {
  margin-bottom: 12px;
  color: #ffd4a8;
  border: 1px solid rgba(255, 160, 80, 0.45);
  background: rgba(255, 120, 40, 0.12);
  font-weight: 700;
}

.class-description {
  display: grid;
  gap: 4px;
  border: 1px solid transparent;
}

.class-description.selected {
  border-color: rgba(245, 166, 35, 0.55);
  background: rgba(245, 166, 35, 0.13);
}

.class-description strong {
  display: flex;
  justify-content: space-between;
  gap: 10px;
  font-size: 0.84rem;
}

.class-description strong span {
  color: #ffffff;
  white-space: nowrap;
}

.class-description span {
  color: #cfcfcf;
  font-size: 0.82rem;
  line-height: 1.25;
}

.detail {
  display: grid;
  gap: 4px;
  min-height: 82px;
}

.kit-detail {
  align-items: center;
}

.kit-controls {
  display: grid;
  grid-template-columns: minmax(76px, 1fr) auto minmax(76px, 1fr);
  align-items: center;
  gap: 14px;
}

.kit-controls strong {
  min-width: 42px;
  text-align: center;
  font-size: 1.75rem;
  line-height: 1;
}

.totals {
  margin-top: 10px;
}

.signup-button {
  width: 100%;
  margin-top: 14px;
}

.result {
  margin-top: 14px;
}

.result-grid {
  display: grid;
  grid-template-columns: repeat(2, 1fr);
  gap: 8px 18px;
  margin-top: 8px;
}

.accolades {
  display: grid;
  gap: 10px;
}

.progress {
  height: 8px;
  background: rgba(255, 255, 255, 0.15);
  border-radius: 4px;
  overflow: hidden;
  margin: 8px 0 4px;
}

.progress span {
  display: block;
  height: 100%;
  background: #f5a623;
}

@media (max-width: 720px) {
  .details-grid,
  .class-breakdown {
    grid-template-columns: 1fr;
  }

  .topbar,
  .accolade {
    align-items: stretch;
    flex-direction: column;
  }
}
</style>
