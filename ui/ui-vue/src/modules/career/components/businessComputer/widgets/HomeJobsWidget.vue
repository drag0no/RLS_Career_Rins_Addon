<template>
  <div class="home-widget jobs-widget" :class="{ 'home-widget--compact': compact }">
    <div class="widget-header">
      <h3>{{ store.businessType === 'racingTeam' ? 'Driver Overview' : 'Jobs Overview' }}</h3>
      <div v-if="store.businessType !== 'racingTeam'" class="tabs">
        <button :class="{ active: activeTab === 'active' }" @click="activeTab = 'active'" data-focusable>
          Active ({{ store.activeJobs.length }})
        </button>
        <button :class="{ active: activeTab === 'new' }" @click="activeTab = 'new'" data-focusable>
          New ({{ store.newJobs.length }})
        </button>
      </div>
    </div>

    <div class="widget-content">
      <template v-if="store.businessType === 'racingTeam'">
        <div v-if="!driverCards.length" class="empty-state">
          <p>No drivers to show.</p>
        </div>
        <div v-else :class="compact ? 'drivers-list-compact' : 'drivers-grid'">
          <div v-for="d in displayDriverCards" :key="d.id" class="driver-card">
            <span class="driver-card__name">{{ d.name }}</span>
            <span class="driver-card__car">{{ d.fleetLabel }}</span>
          </div>
        </div>
      </template>
      <template v-else>
        <div v-if="currentList.length === 0" class="empty-state">
          <p>No {{ activeTab }} jobs available.</p>
        </div>
        <div v-else class="jobs-grid">
          <div v-for="job in displayList" :key="job.id || job.jobId" class="grid-item">
            <BusinessJobCard
              :job="job"
              :is-active="activeTab === 'active'"
              :business-id="store.businessId"
              layout="compact"
              @pull-out="$emit('pull-out', job)"
              @put-away="$emit('put-away', job)"
              @abandon="$emit('abandon', job)"
              @complete="$emit('complete', job)"
              @accept="$emit('accept', job)"
              @decline="$emit('decline', job)"
            />
          </div>
        </div>
      </template>
    </div>
  </div>
</template>

<script setup>
import { ref, computed } from "vue"
import { useBusinessComputerStore } from "../../../stores/businessComputerStore"
import BusinessJobCard from "../BusinessJobCard.vue"

const props = defineProps({
  compact: { type: Boolean, default: false },
})

defineEmits(["open-tab", "pull-out", "put-away", "abandon", "complete", "accept", "decline"])

const store = useBusinessComputerStore()
const activeTab = ref("active")

const currentList = computed(() => {
  return activeTab.value === "active" ? store.activeJobs : store.newJobs
})

const displayList = computed(() => {
  return currentList.value.slice(0, 8)
})

const driverCards = computed(() => {
  const list = store.techs
  if (!Array.isArray(list)) return []
  return list
    .filter((t) => t && !t.fired)
    .map((t) => ({
      id: t.id,
      name: t.name || `Driver #${t.id}`,
      fleetLabel: t.fleetVehicleName || "No fleet car assigned",
    }))
})

const displayDriverCards = computed(() => {
  const max = props.compact ? 5 : 8
  return driverCards.value.slice(0, max)
})
</script>

<style scoped lang="scss">
.home-widget {
  background: rgba(30, 30, 30, 0.6);
  border: 1px solid rgba(255, 255, 255, 0.05);
  border-radius: 1em;
  display: flex;
  flex-direction: column;
  overflow: hidden;
  height: 100%;
}

.widget-header {
  padding: 1em 1.25em;
  border-bottom: 1px solid rgba(255, 255, 255, 0.05);
  display: flex;
  justify-content: space-between;
  align-items: center;
  background: rgba(0, 0, 0, 0.2);

  h3 {
    margin: 0;
    font-size: 1.1em;
    font-weight: 600;
    color: #fff;
  }
}

.tabs {
  display: flex;
  gap: 0.5em;
  background: rgba(0, 0, 0, 0.3);
  padding: 0.25em;
  border-radius: 0.5em;

  button {
    background: transparent;
    border: none;
    color: rgba(255, 255, 255, 0.6);
    padding: 0.35em 0.75em;
    border-radius: 0.25em;
    font-size: 0.8em;
    font-weight: 600;
    cursor: pointer;
    transition: all 0.2s;

    &:hover {
      color: #fff;
    }

    &.active {
      background: rgba(255, 255, 255, 0.1);
      color: #fff;
      box-shadow: 0 1px 2px rgba(0, 0, 0, 0.1);
    }
  }
}

.widget-content {
  padding: 1em;
  flex: 1;
  overflow-y: auto;

  &::-webkit-scrollbar {
    width: 6px;
  }

  &::-webkit-scrollbar-track {
    background: rgba(0, 0, 0, 0.1);
  }

  &::-webkit-scrollbar-thumb {
    background: rgba(255, 255, 255, 0.1);
    border-radius: 3px;
  }
}

.jobs-grid {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(240px, 1fr));
  gap: 1em;
}

.drivers-grid {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(200px, 1fr));
  gap: 0.75em;
}

.driver-card {
  display: flex;
  flex-direction: column;
  gap: 0.35em;
  padding: 0.75em 1em;
  border-radius: 0.5em;
  background: rgba(0, 0, 0, 0.28);
  border: 1px solid rgba(255, 255, 255, 0.08);
}

.driver-card__name {
  font-weight: 600;
  color: #fff;
  font-size: 0.95em;
}

.driver-card__car {
  font-size: 0.85em;
  color: rgba(255, 255, 255, 0.55);
}

.grid-item {
  height: 100%;
}

.empty-state {
  text-align: center;
  padding: 2em;
  color: rgba(255, 255, 255, 0.4);
  font-style: italic;
}

.drivers-list-compact {
  display: flex;
  flex-direction: column;
  gap: 0.35em;
}

.home-widget--compact {
  min-height: 0;
  height: auto;
  flex-shrink: 0;

  .widget-header {
    padding: 0.42em 0.55em;

    h3 {
      font-size: 0.82em;
    }
  }

  .widget-content {
    padding: 0.4em 0.55em 0.5em;
  }

  .driver-card {
    padding: 0.4em 0.5em;
  }

  .driver-card__name {
    font-size: 0.8em;
  }

  .driver-card__car {
    font-size: 0.72em;
  }

  .empty-state {
    padding: 0.75em;
    font-size: 0.78em;
  }
}
</style>
