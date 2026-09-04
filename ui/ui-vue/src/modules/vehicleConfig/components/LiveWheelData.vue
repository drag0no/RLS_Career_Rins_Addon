<template>
  <div class="awd-container bngApp">
    <table class="awd-table" v-if="orderedData && orderedData.length > 0">
      <thead>
        <tr>
          <th>Name</th>
          <th>Camber</th>
          <th>Toe</th>
          <th>Caster</th>
          <th>SAI</th>
        </tr>
      </thead>
      <tr v-for="w in orderedData" :key="w.name">
        <td class="data-name">{{ w.name }}</td>
        <td>{{ format(w.camber) }}</td>
        <td>{{ format(w.toe) }}</td>
        <td>{{ format(w.caster) }}</td>
        <td>{{ format(w.sai) }}</td>
      </tr>
    </table>
  </div>
</template>

<script setup>
import { ref, computed, onUnmounted } from "vue"
import { useBridge } from "@/bridge"
import { useEvents, useStreams } from "@/services/events"

const { api } = useBridge()
const events = useEvents()

const data = ref([])
const hasData = computed(() => Array.isArray(data.value) && data.value.length > 0)
const orderedData = computed(() => {
  if (!Array.isArray(data.value)) return []
  return data.value.slice().sort((a, b) => a.name.toLowerCase().localeCompare(b.name.toLowerCase()))
})

defineExpose({ hasData })

const register = () => api.activeObjectLua('extensions.advancedwheeldebug.registerDebugUser("advancedWheelDebugApp", true)')

const format = value => (value ? parseFloat(value).toFixed(3) : "")

useStreams(["advancedWheelDebugData"], streams => (data.value = streams["advancedWheelDebugData"]))

events.on("VehicleReset", register)
events.on("VehicleChange", register)

register()

onUnmounted(() => {
  api.activeObjectLua('extensions.advancedwheeldebug.registerDebugUser("advancedWheelDebugApp", false)')
})
</script>

<style scoped lang="scss">
.awd-container {
  padding: 0;

  .awd-table {
    width: 100%;

    thead > tr {
      text-align: justify;
    }

    th {
      text-align: left;
    }
    th:first-child {
      text-align: center;
    }

    td {
      width: 20%;
      font-size: 0.875em;
      font-weight: 400;
      letter-spacing: 0.01em;
      line-height: 1.4em;
      text-align: left;

      &.data-name {
        font-weight: 500;
        line-height: 1.7em;
        text-align: center;
      }
    }
  }
}
</style>
