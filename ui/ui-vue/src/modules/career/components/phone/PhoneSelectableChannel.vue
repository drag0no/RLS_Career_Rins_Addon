<template>
  <!-- 1. Cars -->
  <details
    v-if="channel.selectableType === 'fre-cars'"
    class="notif-sub-dropdown"
    :class="{ muted: disabled }"
  >
    <summary class="notif-sub-summary">
      <div class="notif-sub-summary-left">
        <span class="notif-sub-title">{{ channel.label || 'Cars' }}</span>
      </div>
      <div class="notif-sub-meta">
        <span class="notif-count-badge">{{ carsEnabledCount }}/{{ totalCarsCount }}</span>
        <span
          class="notif-switch"
          :class="{ on: isCarsCategoryAllOn }"
          role="button"
          tabindex="0"
          :aria-label="`Toggle all ${channel.label || 'cars'}`"
          @click.stop.prevent="toggleCarsCategory"
          @keydown.enter.stop.prevent="toggleCarsCategory"
          @keydown.space.stop.prevent="toggleCarsCategory"
        >
          <span class="notif-knob"></span>
        </span>
      </div>
    </summary>
    <div class="notif-sub-content">
      <div v-if="filterOptions.ownedCars.length === 0" class="notif-empty-sub">
        No owned vehicle models in garage
      </div>
      <button
        v-for="car in filterOptions.ownedCars"
        :key="car.id"
        type="button"
        class="notif-row notif-row--subchild"
        :class="{ on: isCarEnabled(car.id) }"
        @click="toggleCar(car.id)"
      >
        <span class="notif-copy">
          <span class="notif-label">{{ car.name }}</span>
        </span>
        <span class="notif-switch" :class="{ on: isCarEnabled(car.id) }">
          <span class="notif-knob"></span>
        </span>
      </button>
      <button
        type="button"
        class="notif-row notif-row--subchild"
        :class="{ on: isOtherCarsEnabled }"
        @click="toggleOtherCars"
      >
        <span class="notif-copy">
          <span class="notif-label">Other vehicles</span>
          <span class="notif-desc">Unowned & loaner cars</span>
        </span>
        <span class="notif-switch" :class="{ on: isOtherCarsEnabled }">
          <span class="notif-knob"></span>
        </span>
      </button>
    </div>
  </details>

  <!-- 2. Difficulty -->
  <details
    v-else-if="channel.selectableType === 'fre-difficulty'"
    class="notif-sub-dropdown"
    :class="{ muted: disabled }"
  >
    <summary class="notif-sub-summary">
      <div class="notif-sub-summary-left">
        <span class="notif-sub-title">{{ channel.label || 'Difficulty' }}</span>
      </div>
      <div class="notif-sub-meta">
        <span class="notif-count-badge">{{ difficultyEnabledCount }}/{{ totalDifficultyCount }}</span>
        <span
          class="notif-switch"
          :class="{ on: isDifficultyCategoryAllOn }"
          role="button"
          tabindex="0"
          :aria-label="`Toggle all ${channel.label || 'difficulties'}`"
          @click.stop.prevent="toggleDifficultyCategory"
          @keydown.enter.stop.prevent="toggleDifficultyCategory"
          @keydown.space.stop.prevent="toggleDifficultyCategory"
        >
          <span class="notif-knob"></span>
        </span>
      </div>
    </summary>
    <div class="notif-sub-content">
      <button
        v-for="diff in filterOptions.difficulties"
        :key="diff.id"
        type="button"
        class="notif-row notif-row--subchild"
        :class="{ on: isDifficultyEnabled(diff.id) }"
        @click="toggleDifficulty(diff.id)"
      >
        <span class="notif-copy">
          <span class="notif-label">{{ diff.label }}</span>
        </span>
        <span class="notif-switch" :class="{ on: isDifficultyEnabled(diff.id) }">
          <span class="notif-knob"></span>
        </span>
      </button>
    </div>
  </details>

  <!-- 3. Discipline -->
  <details
    v-else-if="channel.selectableType === 'fre-discipline'"
    class="notif-sub-dropdown"
    :class="{ muted: disabled }"
  >
    <summary class="notif-sub-summary">
      <div class="notif-sub-summary-left">
        <span class="notif-sub-title">{{ channel.label || 'Discipline' }}</span>
      </div>
      <div class="notif-sub-meta">
        <span class="notif-count-badge">{{ disciplineEnabledCount }}/{{ totalDisciplineCount }}</span>
        <span
          class="notif-switch"
          :class="{ on: isDisciplineCategoryAllOn }"
          role="button"
          tabindex="0"
          :aria-label="`Toggle all ${channel.label || 'disciplines'}`"
          @click.stop.prevent="toggleDisciplineCategory"
          @keydown.enter.stop.prevent="toggleDisciplineCategory"
          @keydown.space.stop.prevent="toggleDisciplineCategory"
        >
          <span class="notif-knob"></span>
        </span>
      </div>
    </summary>
    <div class="notif-sub-content">
      <div v-if="filterOptions.disciplines.length === 0" class="notif-empty-sub">
        No disciplines available
      </div>
      <button
        v-for="disc in filterOptions.disciplines"
        :key="disc.id"
        type="button"
        class="notif-row notif-row--subchild"
        :class="{ on: isDisciplineEnabled(disc.id) }"
        @click="toggleDiscipline(disc.id)"
      >
        <span class="notif-copy">
          <span class="notif-label">{{ disc.label }}</span>
        </span>
        <span class="notif-switch" :class="{ on: isDisciplineEnabled(disc.id) }">
          <span class="notif-knob"></span>
        </span>
      </button>
    </div>
  </details>
</template>

<script setup>
import { ref, computed, onMounted, onActivated, onUnmounted } from 'vue'
import { lua } from '@/bridge'
import { usePhoneSettings } from '../../composables/usePhoneSettings'

const props = defineProps({
  channel: {
    type: Object,
    required: true,
  },
  disabled: {
    type: Boolean,
    default: false,
  },
})

const {
  phoneSettings,
  setPhoneSettings,
  getPhoneSettingsSnapshot,
} = usePhoneSettings()

// Shared filter options across all selectable channels
const filterOptions = ref({
  ownedCars: [],
  disciplines: [],
  difficulties: [
    { id: 'easy', label: 'Easy' },
    { id: 'medium', label: 'Medium' },
    { id: 'hard', label: 'Hard' },
  ],
})

let saveTimer = null

async function persistSettings() {
  try {
    await lua.extensions.load('ui_phone_layout')
    await lua.ui_phone_layout?.updateSettings?.(getPhoneSettingsSnapshot())
  } catch (e) {
    console.warn('Failed to save notification settings', e)
  }
}

function queueSave() {
  if (saveTimer) clearTimeout(saveTimer)
  saveTimer = setTimeout(() => {
    saveTimer = null
    persistSettings()
  }, 180)
}

async function fetchFilterOptions() {
  try {
    await lua.extensions.load('ui_phone_freContracts')
    const res = await lua.ui_phone_freContracts?.getNotificationFilterOptions?.()
    if (res && typeof res === 'object') {
      filterOptions.value = {
        ownedCars: Array.isArray(res.ownedCars) ? res.ownedCars : [],
        disciplines: Array.isArray(res.disciplines) ? res.disciplines : [],
        difficulties: Array.isArray(res.difficulties) && res.difficulties.length
          ? res.difficulties
          : filterOptions.value.difficulties,
      }
    }
  } catch (e) {
    console.warn('Failed to load filter options', e)
  }
}

onMounted(() => {
  fetchFilterOptions()
})

onActivated(() => {
  fetchFilterOptions()
})

onUnmounted(() => {
  if (saveTimer) {
    clearTimeout(saveTimer)
    saveTimer = null
    persistSettings()
  }
})

function updateFilters(updater) {
  const current = phoneSettings.freNotificationFilters || {}
  const nextFilters = {
    cars: {
      all: current.cars?.all !== false,
      other: current.cars?.other !== false,
      owned: { ...(current.cars?.owned || {}) },
    },
    difficulty: {
      all: current.difficulty?.all !== false,
      easy: current.difficulty?.easy !== false,
      medium: current.difficulty?.medium !== false,
      hard: current.difficulty?.hard !== false,
    },
    discipline: {
      all: current.discipline?.all !== false,
      ...(current.discipline || {}),
    },
  }
  updater(nextFilters)

  // Sync with phoneSettings.notifications for this channel key
  const nextNotifs = { ...(phoneSettings.notifications || {}) }
  if (props.channel.key === 'fre.cars') {
    nextNotifs['fre.cars'] = nextFilters.cars.all !== false
  } else if (props.channel.key === 'fre.difficulty') {
    nextNotifs['fre.difficulty'] = nextFilters.difficulty.all !== false
  } else if (props.channel.key === 'fre.discipline') {
    nextNotifs['fre.discipline'] = nextFilters.discipline.all !== false
  }

  setPhoneSettings({
    freNotificationFilters: nextFilters,
    notifications: nextNotifs,
  })
  queueSave()
}

// ---------------- Cars Category ----------------
function isCarEnabled(carId) {
  const cars = phoneSettings.freNotificationFilters?.cars
  if (!cars) return true
  if (cars.all === false) return false
  const key = String(carId).toLowerCase()
  if (cars.owned && cars.owned[key] !== undefined) {
    return cars.owned[key] !== false
  }
  return true
}

const isOtherCarsEnabled = computed(() => {
  const cars = phoneSettings.freNotificationFilters?.cars
  if (!cars) return true
  if (cars.all === false) return false
  return cars.other !== false
})

const totalCarsCount = computed(() => {
  return filterOptions.value.ownedCars.length + 1
})

const carsEnabledCount = computed(() => {
  const cars = phoneSettings.freNotificationFilters?.cars
  if (cars?.all === false) return 0
  let count = isOtherCarsEnabled.value ? 1 : 0
  for (const car of filterOptions.value.ownedCars) {
    if (isCarEnabled(car.id)) {
      count++
    }
  }
  return count
})

const isCarsCategoryAllOn = computed(() => {
  return carsEnabledCount.value === totalCarsCount.value && totalCarsCount.value > 0
})

function toggleCarsCategory() {
  updateFilters(filters => {
    if (carsEnabledCount.value < totalCarsCount.value) {
      filters.cars.all = true
      filters.cars.other = true
      for (const car of filterOptions.value.ownedCars) {
        filters.cars.owned[String(car.id).toLowerCase()] = true
      }
    } else {
      filters.cars.all = false
      filters.cars.other = false
      for (const car of filterOptions.value.ownedCars) {
        filters.cars.owned[String(car.id).toLowerCase()] = false
      }
    }
  })
}

function toggleCar(carId) {
  const key = String(carId).toLowerCase()
  updateFilters(filters => {
    const nextVal = !isCarEnabled(key)
    filters.cars.owned[key] = nextVal
    if (nextVal) {
      filters.cars.all = true
    } else {
      const anyOwnedStillOn = filterOptions.value.ownedCars.some(
        c => {
          const cKey = String(c.id).toLowerCase()
          return cKey !== key && (filters.cars.owned[cKey] !== undefined ? filters.cars.owned[cKey] : isCarEnabled(cKey))
        }
      )
      const otherOn = filters.cars.other !== false
      if (!anyOwnedStillOn && !otherOn) {
        filters.cars.all = false
      }
    }
  })
}

function toggleOtherCars() {
  updateFilters(filters => {
    const nextVal = !isOtherCarsEnabled.value
    filters.cars.other = nextVal
    if (nextVal) {
      filters.cars.all = true
    } else {
      const anyOwnedStillOn = filterOptions.value.ownedCars.some(
        c => {
          const cKey = String(c.id).toLowerCase()
          return filters.cars.owned[cKey] !== undefined ? filters.cars.owned[cKey] : isCarEnabled(cKey)
        }
      )
      if (!anyOwnedStillOn) {
        filters.cars.all = false
      }
    }
  })
}

// ---------------- Difficulty Category ----------------
function isDifficultyEnabled(diffId) {
  const diff = phoneSettings.freNotificationFilters?.difficulty
  if (!diff) return true
  if (diff.all === false) return false
  return diff[diffId] !== false
}

const totalDifficultyCount = computed(() => {
  return filterOptions.value.difficulties.length
})

const difficultyEnabledCount = computed(() => {
  const diff = phoneSettings.freNotificationFilters?.difficulty
  if (diff?.all === false) return 0
  let count = 0
  for (const d of filterOptions.value.difficulties) {
    if (isDifficultyEnabled(d.id)) {
      count++
    }
  }
  return count
})

const isDifficultyCategoryAllOn = computed(() => {
  return difficultyEnabledCount.value === totalDifficultyCount.value && totalDifficultyCount.value > 0
})

function toggleDifficultyCategory() {
  updateFilters(filters => {
    if (difficultyEnabledCount.value < totalDifficultyCount.value) {
      filters.difficulty.all = true
      filters.difficulty.easy = true
      filters.difficulty.medium = true
      filters.difficulty.hard = true
    } else {
      filters.difficulty.all = false
      filters.difficulty.easy = false
      filters.difficulty.medium = false
      filters.difficulty.hard = false
    }
  })
}

function toggleDifficulty(diffId) {
  updateFilters(filters => {
    const nextVal = !isDifficultyEnabled(diffId)
    filters.difficulty[diffId] = nextVal
    if (nextVal) {
      filters.difficulty.all = true
    } else {
      const anyDiffStillOn = filterOptions.value.difficulties.some(
        d => d.id !== diffId && (filters.difficulty[d.id] !== undefined ? filters.difficulty[d.id] : isDifficultyEnabled(d.id))
      )
      if (!anyDiffStillOn) {
        filters.difficulty.all = false
      }
    }
  })
}

// ---------------- Discipline Category ----------------
function isDisciplineEnabled(discId) {
  const disc = phoneSettings.freNotificationFilters?.discipline
  if (!disc) return true
  if (disc.all === false) return false
  return disc[discId] !== false
}

const totalDisciplineCount = computed(() => {
  return filterOptions.value.disciplines.length
})

const disciplineEnabledCount = computed(() => {
  const disc = phoneSettings.freNotificationFilters?.discipline
  if (disc?.all === false) return 0
  let count = 0
  for (const d of filterOptions.value.disciplines) {
    if (isDisciplineEnabled(d.id)) {
      count++
    }
  }
  return count
})

const isDisciplineCategoryAllOn = computed(() => {
  return disciplineEnabledCount.value === totalDisciplineCount.value && totalDisciplineCount.value > 0
})

function toggleDisciplineCategory() {
  updateFilters(filters => {
    if (disciplineEnabledCount.value < totalDisciplineCount.value) {
      filters.discipline.all = true
      for (const disc of filterOptions.value.disciplines) {
        filters.discipline[disc.id] = true
      }
    } else {
      filters.discipline.all = false
      for (const disc of filterOptions.value.disciplines) {
        filters.discipline[disc.id] = false
      }
    }
  })
}

function toggleDiscipline(discId) {
  updateFilters(filters => {
    const nextVal = !isDisciplineEnabled(discId)
    filters.discipline[discId] = nextVal
    if (nextVal) {
      filters.discipline.all = true
    } else {
      const anyDiscStillOn = filterOptions.value.disciplines.some(
        d => d.id !== discId && (filters.discipline[d.id] !== undefined ? filters.discipline[d.id] : isDisciplineEnabled(d.id))
      )
      if (!anyDiscStillOn) {
        filters.discipline.all = false
      }
    }
  })
}
</script>
