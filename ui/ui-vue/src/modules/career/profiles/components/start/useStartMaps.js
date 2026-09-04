import { onMounted, ref } from "vue"
import { lua } from "@/bridge"

export function useStartMaps(defaultMap = "west_coast_usa") {
  const mapOptions = ref([])
  const startingMap = ref(defaultMap)

  async function loadMaps() {
    try {
      const maps = await lua.overhaul_maps.getCompatibleMaps()
      if (!maps || typeof maps !== "object") return

      mapOptions.value = Object.entries(maps)
        .map(([value, label]) => ({ value, label }))
        .sort((a, b) => a.label.localeCompare(b.label))

      if (!maps[startingMap.value] && mapOptions.value.length) {
        startingMap.value = mapOptions.value[0].value
      }
    } catch (_) {
      mapOptions.value = [{ value: defaultMap, label: "West Coast USA" }]
    }
  }

  onMounted(loadMaps)

  return { mapOptions, startingMap, loadMaps }
}
