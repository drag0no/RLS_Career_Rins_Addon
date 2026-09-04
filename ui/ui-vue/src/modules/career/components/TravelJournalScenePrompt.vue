<template>
  <Teleport to="body">
    <Transition name="journal-prompt">
      <div
        v-if="prompt.visible"
        class="prompt-backdrop"
        bng-ui-scope="travelJournalScenePrompt"
        bng-scoped-nav-autofocus
        v-bng-on-ui-nav:back,menu.asMouse="dismiss"
      >
      <section class="prompt-card" aria-modal="true" role="dialog" aria-labelledby="travel-journal-prompt-title">
        <span class="eyebrow">Travel Journal</span>
        <h1 id="travel-journal-prompt-title">Ready for Photo Mode</h1>
        <p class="location-name">{{ prompt.locationName }}</p>
        <p class="description">{{ prompt.firstDiscovery ? 'Location discovered. ' : '' }}Park here to enter the curated photography scene.</p>
        <p v-if="error" class="error">{{ error }}</p>
        <div class="prompt-actions">
          <BngButton :accent="ACCENTS.primary" :disabled="busy" @click="enterScene">
            <BngBinding :action="prompt.action || 'gameplay_interact'" show-unassigned />
            {{ busy ? 'Opening...' : 'Enter Photo Scene' }}
          </BngButton>
          <BngButton :accent="ACCENTS.secondary" :disabled="busy" @click="dismiss">
            Continue Driving
          </BngButton>
        </div>
      </section>
      </div>
    </Transition>
  </Teleport>
</template>

<script setup>
import { onBeforeUnmount, onMounted, reactive, ref } from 'vue'
import { BngBinding, BngButton, ACCENTS } from '@/common/components/base'
import { vBngOnUiNav } from '@/common/directives'
import { useBridge } from '@/bridge'
import { runRaw, serialize } from '@/bridge/libs/Lua'

const bridge = useBridge()
const prompt = reactive({
  visible: false,
  mapId: '',
  locationId: '',
  locationName: '',
  action: 'gameplay_interact',
  firstDiscovery: false,
})
const busy = ref(false)
const error = ref('')

function updatePrompt(payload = {}) {
  if (Array.isArray(payload)) payload = payload.find(entry => entry && typeof entry === 'object') || payload[0] || {}
  prompt.visible = payload.visible === true
  prompt.mapId = payload.mapId || ''
  prompt.locationId = payload.locationId || ''
  prompt.locationName = payload.locationName || 'Scenic location'
  prompt.action = payload.action || 'gameplay_interact'
  prompt.firstDiscovery = payload.firstDiscovery === true
  busy.value = false
  error.value = ''
}

function sceneFailureMessage(reason) {
  const messages = {
    scene_active: 'A Travel Journal photography scene is already active.',
    app_not_installed: 'Install Travel Journal before entering this scene.',
    wrong_map: 'This Travel Journal location is no longer on the current map.',
    activity_blocked: 'Finish the current activity before entering this scene.',
    content_missing: 'This location is missing its parking spot or scenic zone.',
    outside_zone: 'Park inside the scenic area before entering this scene.',
    trailer_attached: 'Detach the trailer before entering this scene.',
    location_changed: 'The selected Travel Journal location changed.',
    not_ready: 'Reopen this location from its parking marker.',
  }
  return messages[reason] || 'The photography scene could not be opened.'
}

async function enterScene() {
  if (busy.value || !prompt.mapId || !prompt.locationId) return
  busy.value = true
  error.value = ''
  try {
    const result = await runRaw(`gameplay_travelJournal.enterPromptedScene(${serialize(prompt.mapId)}, ${serialize(prompt.locationId)})`)
    if (!result?.success) {
      error.value = sceneFailureMessage(result?.reason)
      busy.value = false
    }
  } catch (_) {
    error.value = 'The photography scene could not be opened.'
    busy.value = false
  }
}

async function dismiss() {
  if (busy.value) return
  prompt.visible = false
  try {
    await runRaw('gameplay_travelJournal.dismissScenePrompt()')
  } catch (_) {
    // It is already hidden locally; the parking marker can reopen it immediately.
  }
}

onMounted(() => {
  bridge.events.on('TravelJournalScenePrompt', updatePrompt)
  if (typeof window !== 'undefined' && window.vueEventBus && window.vueEventBus !== bridge.events) {
    window.vueEventBus.on('TravelJournalScenePrompt', updatePrompt)
  }
})
onBeforeUnmount(() => {
  bridge.events.off('TravelJournalScenePrompt', updatePrompt)
  if (typeof window !== 'undefined' && window.vueEventBus && window.vueEventBus !== bridge.events) {
    window.vueEventBus.off('TravelJournalScenePrompt', updatePrompt)
  }
})
</script>

<style scoped lang="scss">
.prompt-backdrop {
  position: fixed;
  inset: 0;
  z-index: 1500;
  display: flex;
  align-items: center;
  justify-content: center;
  padding: 2rem;
  pointer-events: auto;
  background: rgba(10, 9, 8, 0.42);
  backdrop-filter: blur(2px);
}

.prompt-card {
  width: min(36rem, calc(100vw - 3rem));
  box-sizing: border-box;
  padding: 1.45rem;
  color: #342a25;
  border: 1px solid rgba(92, 65, 46, 0.35);
  border-radius: 0.45rem;
  background:
    radial-gradient(circle at 15% 18%, rgba(121, 84, 54, 0.09) 0 1px, transparent 1.6px),
    linear-gradient(145deg, #f8f1e5, #e8dcc8);
  background-size: 25px 28px, auto;
  box-shadow: 0 1.25rem 3rem rgba(0, 0, 0, 0.55);
  text-align: center;
  font-family: Georgia, 'Times New Roman', serif;
}

.eyebrow {
  color: #a95e62;
  font: 700 0.72rem/1.1 Arial, sans-serif;
  letter-spacing: 0.15em;
  text-transform: uppercase;
}

h1 {
  margin: 0.35rem 0 0.2rem;
  font-size: 2rem;
  line-height: 1.05;
}

.location-name {
  margin: 0;
  color: #55735b;
  font-size: 1.15rem;
  font-weight: 700;
}

.description {
  margin: 0.8rem auto 1.2rem;
  color: #786a61;
  font: 0.9rem/1.4 Arial, sans-serif;
}

.error {
  margin: -0.5rem 0 0.8rem;
  color: #9f4c4c;
  font: 700 0.8rem Arial, sans-serif;
}

.prompt-actions {
  display: grid;
  grid-template-columns: repeat(2, minmax(0, 1fr));
  gap: 0.65rem;
}

.prompt-actions :deep(.bng-binding) { margin-right: 0.35rem; }

.journal-prompt-enter-active,
.journal-prompt-leave-active { transition: opacity 0.16s ease; }
.journal-prompt-enter-from,
.journal-prompt-leave-to { opacity: 0; }

@media (max-width: 42rem) {
  .prompt-actions { grid-template-columns: 1fr; }
}
</style>
