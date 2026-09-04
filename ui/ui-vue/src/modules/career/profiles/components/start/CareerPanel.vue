<template>
  <div class="start-panel">
    <StartDifficulty v-model="difficulty" :difficulties="difficulties" label="Difficulty" />

    <template v-if="hardcoreLocks">
      <div class="start-panel-locked">
        <span class="start-panel-locked-title">Hardcore sets the rest for you</span>
        <ul class="start-panel-locked-list">
          <li v-for="lock in hardcoreLocks" :key="lock">{{ lock }}</li>
        </ul>
      </div>
      <div class="start-panel-toggles">
        <StartToggle v-model="maintenanceEnabled" label="Maintenance Mode" />
      </div>
    </template>

    <!-- Where you start is a refinement, not a first-run decision. -->
    <template v-else>
      <div class="start-panel-pair">
        <StartDropdown v-model="startingMap" label="Starting Map" :options="mapOptions" />
        <StartDropdown v-model="startingGarage" label="Starting Garage" :options="garageOptions" />
      </div>
      <div class="start-panel-toggles">
        <StartToggle v-model="policeEnabled" label="Police" />
        <StartToggle v-model="maintenanceEnabled" label="Maintenance Mode" />
      </div>
    </template>
  </div>
</template>

<script setup>
import { computed, ref, watch } from "vue"
import StartDifficulty from "./shared/StartDifficulty.vue"
import StartDropdown from "./shared/StartDropdown.vue"
import StartToggle from "./shared/StartToggle.vue"
import { useStartMaps } from "./useStartMaps.js"
import { useStartGarages } from "./useStartGarages.js"
import { CAREER_PATH_DIFFICULTY_IDS, getDifficulties, getDifficulty } from "./careerStartModes.js"

const emit = defineEmits(["name-hint"])

const difficulties = getDifficulties(CAREER_PATH_DIFFICULTY_IDS)
const difficulty = ref("standard")


const { mapOptions, startingMap } = useStartMaps()
const { garageOptions, startingGarage } = useStartGarages(startingMap)
const policeEnabled = ref(true)
const maintenanceEnabled = ref(false)

/** Lets the card suggest "Standard" rather than "Profile 216" while untouched. */
watch(
  difficulty,
  id => {
    emit("name-hint", getDifficulty(id)?.label || null)
  },
  { immediate: true }
)

/**
 * Hardcore forces map, garage and police in the Lua whatever the UI sends, so
 * those controls are replaced by a statement of what it does. Maintenance stays
 * player-choice and is shown under the locks.
 */
const hardcoreLocks = computed(() => getDifficulty(difficulty.value)?.locks || null)

function getStartConfig() {
  return {
    valid: true,
    difficulty: difficulty.value,
    startingMap: startingMap.value,
    startingGarage: startingGarage.value,
    policeEnabled: policeEnabled.value,
    maintenanceEnabled: maintenanceEnabled.value,
  }
}

defineExpose({ getStartConfig })
</script>

<style lang="scss" scoped>
.start-panel {
  display: flex;
  flex-direction: column;
  gap: 1em;
}

.start-panel-pair {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 0.75em;
  min-width: 0;

  > * {
    min-width: 0;
  }

  &--stacked {
    grid-template-columns: 1fr;
    gap: 0.6em;
  }
}

.start-panel-toggles {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 0.75em 1em;
  padding-top: 0.25em;
}

/* Unboxed: the dashed frame's own padding was most of the overflow, and plain
   lines under a heading read the same as a panel without costing 26px. */
.start-panel-locked {
  display: flex;
  flex-direction: column;
  gap: 0.2em;
}

.start-panel-locked-title {
  font-size: 0.82em;
  font-weight: 700;
  color: #fff;
}

.start-panel-locked-list {
  margin: 0;
  padding-left: 1em;
  font-size: 0.76em;
  line-height: 1.35;
  color: rgba(255, 255, 255, 0.6);

  li {
    margin: 0.05em 0;
  }
}
</style>

