import { ref, nextTick } from "vue"
import { defineStore } from "pinia"
import { useBridge, lua } from "@/bridge"

export const usePartShoppingStore = defineStore("partShopping", () => {
  const { events } = useBridge()

  // Backend-owned, route-selected state (filled from the partShoppingData payload)
  const partShoppingData = ref({})
  const filteredParts = ref([])
  const category = ref("")
  const path = ref("")
  const activePanel = ref("categories")

  // Genuinely UI-local state
  const filteredSlots = ref([])
  const expandedSlots = ref({})
  const slotToScrollTo = ref()
  let searchString = ""

  // Slot path the player last opened, so returning to the slot list can scroll
  // back to it by path (pixel scrollTop is unreliable after tree refreshes).
  let lastViewedSlot = ""

  let slotsDict = {}
  let filteredSlotsDict = {}

  function getSlotsFromSearchString() {
    let resultSlots = {}
    for (const [_, part] of Object.entries(partShoppingData.value.partsInShop)) {
      if (!slotsDict[part.slot]) continue
      if (part.description.description.toLowerCase().includes(searchString.toLowerCase()) ||
          slotsDict[part.slot].toLowerCase().includes(searchString.toLowerCase())) {
        resultSlots[part.containingSlot] = true
      }
    }
    return resultSlots
  }

  function doesSlotPassFilter(slot) {
    return filteredSlotsDict[slot.path]
  }

  function filterSlots() {
    if (searchString.length > 0 && partShoppingData.value.partsInShop) {
      filteredSlotsDict = getSlotsFromSearchString()
      filteredSlots.value = partShoppingData.value.searchSlotList.filter(doesSlotPassFilter)
    } else {
      filteredSlots.value = []
    }
  }

  // Build the slot -> nice name lookup used by the local search.
  function buildSlotsDict() {
    slotsDict = {}
    if (!partShoppingData.value.partsInShop) return
    for (const [_, part] of Object.entries(partShoppingData.value.partsInShop)) {
      if (!part.slot) continue
      const niceName = partShoppingData.value.slotsNiceName?.[part.slot]
      slotsDict[part.slot] = niceName !== null && niceName !== undefined ? niceName : part.slot
    }
  }

  function setSlotExpanded(path, expanded) {
    expandedSlots.value[path] = expanded
  }

  const requestInitialData = () => {
    lua.career_modules_partShopping.sendShoppingDataToUI()
  }

  const cancelShopping = () => {
    expandedSlots.value = {}
    lastViewedSlot = ""
    slotToScrollTo.value = undefined
    lua.career_modules_partShopping.cancelShopping()
  }

  // Re-assign so keep-alive SlotItems always re-run scrollIntoView on back.
  const scrollToLastViewedSlot = () => {
    const target = lastViewedSlot
    if (!target) {
      slotToScrollTo.value = undefined
      return
    }
    slotToScrollTo.value = undefined
    nextTick(() => {
      slotToScrollTo.value = target
    })
  }

  // convert the children object to an array and sort the children by their nice names
  function fixSlots(slot) {
    if (!("children" in slot)) return

    if (!Array.isArray(slot.children)) {
      // Convert object to array, preserving non-null values
      slot.children = Object.values(slot.children).filter(Boolean)
    }

    // Sort children by their nice names
    slot.children.sort((a, b) => {
      const aName = a.slotNiceName || a.slot
      const bName = b.slotNiceName || b.slot
      return aName < bName ? -1 : 1
    })

    for (const childSlot of slot.children) {
      fixSlots(childSlot)
    }
  }

  const handleShoppingData = data => {
    if (data.partTree) fixSlots(data.partTree)
    partShoppingData.value = data

    // Route-selected fields are prepared by the backend; render them directly.
    // Panels stay mounted (v-show) in PartShoppingMain; restore by slot path on back.
    category.value = data.category ?? ""
    path.value = data.slot ?? ""
    activePanel.value = data.activePanel ?? "categories"
    filteredParts.value = data.filteredParts ?? []

    // Remember the opened slot, or scroll back to it when returning to the list.
    if (path.value) lastViewedSlot = path.value
    else if (activePanel.value === "slots") scrollToLastViewedSlot()

    // Search results stay UI-local; recompute against the fresh data.
    buildSlotsDict()
    filterSlots()
  }

  const searchValueChanged = _searchString => {
    searchString = _searchString
    filterSlots()
  }

  // Lua events
  const listen = state => {
    const method = state ? "on" : "off"
    events[method]("partShoppingData", handleShoppingData)
  }
  listen(true)

  function dispose() {
    listen(false)
  }

  return {
    partShoppingData,
    slot: path,
    filteredSlots,
    filteredParts,
    category,
    activePanel,
    expandedSlots,
    slotToScrollTo,
    searchValueChanged,
    requestInitialData,
    cancelShopping,
    dispose,
    setSlotExpanded,
  }
})
