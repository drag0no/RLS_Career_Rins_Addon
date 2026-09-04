<template>
  <LayoutSingle class="level-switch-layout">
    <div class="level-switch-overlay">
      <BngCard class="level-switch-card">
        <BngCardHeading>What level do you want to switch to?</BngCardHeading>

        <div class="modal-content">
          <div class="map-selector-container">
            <BngDropdown
              v-model="selectedMap"
              :items="mapOptions"
              class="map-dropdown"
            />
          </div>
        </div>

        <p v-if="!loading && mapOptions.length === 0" class="empty-message">
          No other compatible Overhaul maps are installed.
        </p>

        <div class="travel-button-container">
          <BngButton
            @click="cancelTravel"
            :accent="ACCENTS.secondary"
            class="travel-button"
          >
            Cancel
          </BngButton>
          <BngButton
            ref="travelButton"
            @click="confirmTravel"
            :accent="ACCENTS.primary"
            :disabled="!selectedMap"
            class="travel-button"
          >
            Travel
          </BngButton>
        </div>
      </BngCard>
    </div>
  </LayoutSingle>
</template>

<script setup>
import { ref, onMounted } from 'vue'
import { lua } from '@/bridge'
import {
  BngButton,
  BngDropdown,
  ACCENTS,
  BngCard,
  BngCardHeading
} from '@/common/components/base'
import { LayoutSingle } from '@/common/layouts'

const travelButton = ref(null)
const selectedMap = ref(null)
const mapOptions = ref([])
const loading = ref(true)

// BngDropdown expects items in format: { label: "Display Name", value: "actual_value" }

onMounted(async () => {
  try {
    // Get compatible maps from the career system
    const compatibleMaps = await lua.overhaul_maps.getOtherAvailableMaps()
    if (compatibleMaps) {
      // Convert the map data to options format for BngDropdown
      const dynamicMaps = Object.entries(compatibleMaps)
        .map(([key, value]) => ({
          value: key,
          label: value
        }))
        .sort((a, b) => a.label.localeCompare(b.label, undefined, { sensitivity: 'base' }))
      if (dynamicMaps.length > 0) {
        mapOptions.value = dynamicMaps
      }
    }
  } catch (error) {
    console.error('Failed to load maps:', error)
  } finally {
    loading.value = false
  }
})

function confirmTravel() {
  if (selectedMap.value) {
    try {
      lua.career_modules_switchMap.switchMap(selectedMap.value)
    } catch (error) {
      console.error('Failed to switch level:', error)
      lua.career_career.closeAllMenus()
    }
  }
}

function cancelTravel() {
  lua.career_modules_switchMap.cancelSwitch()
}

</script>

<style scoped lang="scss">
.level-switch-layout {
  display: flex;
  align-items: center;
  justify-content: center;
  height: 100%;
  color: white;
}

.level-switch-overlay {
  position: fixed;
  top: 0;
  left: 0;
  right: 0;
  bottom: 0;
  display: flex;
  align-items: center;
  justify-content: center;
  background: rgba(0, 0, 0, 0.5);
  z-index: 100;
}

.level-switch-card {
  min-width: 400px;
  max-width: 500px;
  
  :deep(.card-cnt) {
    background: rgba(0, 0, 0, 0.8);
    border-radius: 0.75em;
    padding: 0.5em;
    box-shadow: 0 0 20px rgba(0, 0, 0, 0.4);
    border: 1px solid rgba(255, 255, 255, 0.15);
  }
}

.modal-content {
  text-align: center;
  margin: 0.5em 0;
}

.map-selector-container {
  padding: 0.25em;
}

.map-dropdown {
  width: 100%;
  margin: 0.5em 0;
}

.travel-button-container {
  display: flex;
  justify-content: flex-end;
  gap: 0.5em;
  margin-top: 0.5em;
}

.empty-message {
  margin: 0.75em 0;
  color: rgba(255, 255, 255, 0.75);
}

.travel-button {
  min-width: 120px;
}
</style>
