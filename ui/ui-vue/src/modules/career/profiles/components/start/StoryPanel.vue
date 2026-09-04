<template>
  <!-- The screen is already titled Story and the picker already reads "Select
       Story"; a "Story" label and a "Story mode" heading made it four. -->
  <div class="start-panel start-panel--story">
    <div class="start-panel-picker">
      <ChallengeDropdown ref="challengeDropdownRef" v-model="challengeId" story-labels preload inline />
    </div>

    <p :class="['start-panel-briefing', { 'start-panel-briefing--empty': !challengeId }]">
      {{ briefingText }}
    </p>

    <div class="start-panel-toggles">
      <StartToggle v-model="policeEnabled" label="Police" />
      <StartToggle v-model="maintenanceEnabled" label="Maintenance" />
    </div>
  </div>
</template>

<script setup>
import { ref, computed, watch } from "vue"
import { lua } from "@/bridge"
import ChallengeDropdown from "../ChallengeDropdown.vue"
import StartToggle from "./shared/StartToggle.vue"

const STORY_MODE_HINT = "Pick a story to see what it asks of you."

const challengeId = ref(null)
const challengeDropdownRef = ref(null)
const policeEnabled = ref(true)
const maintenanceEnabled = ref(false)
const challengeMeta = ref(null)

const briefingText = computed(() => {
  if (!challengeId.value) return STORY_MODE_HINT
  const description = challengeMeta.value?.description?.trim()
  return description || "This story has no description."
})

async function loadChallengeMeta(id) {
  if (!id) {
    challengeMeta.value = null
    return
  }
  try {
    challengeMeta.value = await lua.career_challengeModes.getSingleChallengeForUI(id)
  } catch (_) {
    challengeMeta.value = null
  }
}

watch(challengeId, loadChallengeMeta, { immediate: true })

function getStartConfig() {
  if (!challengeId.value) {
    return { valid: false, error: "Select a story to continue." }
  }
  return {
    valid: true,
    challengeId: challengeId.value,
    policeEnabled: policeEnabled.value,
    maintenanceEnabled: maintenanceEnabled.value,
  }
}

function isModalOpen() {
  return challengeDropdownRef.value?.isModalOpen?.() === true
}

defineExpose({ getStartConfig, isModalOpen })
</script>

<style lang="scss" scoped>
.start-panel {
  display: flex;
  flex-direction: column;
  gap: 0.85em;
  min-height: 0;
  flex: 1;
}

.start-panel-picker {
  position: relative;
  z-index: 2;
}

/* Clamped rather than scrolled: a scrollbar inside a card this size is a worse
   answer than an honest truncation, and the story itself carries the full text. */
/* The briefing owns the space between the picker and the toggles, so before a
   story is chosen the prompt sits in the middle of it rather than clinging to
   the top of an empty area. */
.start-panel--story {
  height: 100%;
}

.start-panel--story .start-panel-briefing {
  flex: 1 1 auto;
}

/* Only the empty prompt is centred; a real briefing keeps -webkit-box so the
   line clamp still truncates on line boundaries. */
.start-panel--story .start-panel-briefing--empty {
  display: flex;
  align-items: center;
  justify-content: center;
  text-align: center;
}

.start-panel-briefing {
  margin: 0;
  font-size: 0.84em;
  line-height: 1.45;
  color: rgba(255, 255, 255, 0.78);
  display: -webkit-box;
  -webkit-line-clamp: 5;
  line-clamp: 5;
  -webkit-box-orient: vertical;
  overflow: hidden;

  &--empty {
    color: rgba(255, 255, 255, 0.45);
    font-style: italic;
  }
}

.start-panel-toggles {
  display: flex;
  flex-direction: column;
  gap: 0.35em;
  margin-top: auto;
  padding-top: 0.4em;
  border-top: 1px solid rgba(71, 85, 105, 0.3);
}
</style>
