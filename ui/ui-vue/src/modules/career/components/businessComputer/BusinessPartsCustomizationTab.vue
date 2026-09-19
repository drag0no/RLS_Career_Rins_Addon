<template>
  <div class="parts-customization">
    <!-- Search Bar - Always visible -->
    <div class="search-section">
      <svg class="search-icon" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
        <circle cx="11" cy="11" r="8"/>
        <path d="m21 21-4.35-4.35"/>
      </svg>
      <input
        v-model="searchQuery"
        type="text"
        placeholder="Search for parts across vehicle..."
        class="search-input"
        @focus="onSearchFocus"
        @blur="onSearchBlur"
        @keydown.enter.stop="triggerSearch"
        @keydown.stop @keyup.stop @keypress.stop
        v-bng-text-input
        :disabled="loading"
      />
      <button
        v-if="searchQuery.length > 0"
        @click="clearSearch"
        class="clear-search-button"
        type="button"
        data-focusable
      >
        <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
          <line x1="18" y1="6" x2="6" y2="18"/>
          <line x1="6" y1="6" x2="18" y2="18"/>
        </svg>
      </button>
    </div>

    <!-- Loading State -->
    <div v-if="loading" class="loading-state">
      <p>Loading parts...</p>
    </div>

    <!-- Content - Only show when not loading -->
    <template v-else>
      <!-- Scrollable Content Area -->
      <div class="scrollable-content">
        <!-- 1. Search Results View -->
        <div v-if="hasActiveSearch">
          <div v-if="searchResults.length === 0" class="empty-state">
            <p>No parts found matching "{{ activeSearchQuery }}"</p>
          </div>

          <div v-else class="search-results">
            <div
              v-for="result in searchResults"
              :key="result.slotPath"
              class="search-result-section"
              :class="{ collapsed: !openSearchSections[result.slotPath] }"
            >
              <button
                class="result-section-header"
                @click.stop="toggleSearchSection(result.slotPath)"
                @mousedown.stop
                data-focusable
              >
                <h3>{{ result.slotNiceName || result.slotName }}</h3>
                <svg
                  v-if="openSearchSections[result.slotPath]"
                  class="chevron-icon"
                  width="20"
                  height="20"
                  viewBox="0 0 24 24"
                  fill="none"
                  stroke="currentColor"
                  stroke-width="2"
                >
                  <polyline points="18 15 12 9 6 15"/>
                </svg>
                <svg
                  v-else
                  class="chevron-icon"
                  width="20"
                  height="20"
                  viewBox="0 0 24 24"
                  fill="none"
                  stroke="currentColor"
                  stroke-width="2"
                >
                  <polyline points="6 9 12 15 18 9"/>
                </svg>
              </button>

              <div v-if="openSearchSections[result.slotPath]" class="result-parts-list">
                <div
                  v-for="part in result.parts"
                  :key="part.name"
                  class="option-item"
                  :class="{ 'is-installed': part.installed }"
                >
                  <div class="option-info">
                    <h4>{{ part.niceName || part.name }}</h4>
                    <span v-if="part.installed" class="installed-indicator">Currently Installed</span>
                  </div>
                  <div class="option-actions">
                    <span class="option-price">$ {{ formatPrice(part.value) }}</span>
                    <div v-if="part.installed" class="installed-button-wrapper">
                      <button
                        v-if="result.canRemove !== true"
                        class="btn btn-disabled"
                        data-focusable
                      >
                        Installed
                      </button>
                      <template v-else>
                        <button
                          class="btn btn-disabled"
                          @click.stop="toggleRemoveMenu(result.slotPath, part.name)"
                          data-focusable
                        >
                          Installed
                          <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                            <polyline points="6 9 12 15 18 9"/>
                          </svg>
                        </button>
                        <div v-if="removeMenuVisible === `${result.slotPath}_${part.name}`" class="remove-menu">
                          <button class="remove-menu-item" @click="removePart(part, result)" data-focusable>
                            Remove
                          </button>
                        </div>
                      </template>
                    </div>
                    <div v-else class="install-button-wrapper">
                      <button
                        v-if="!hasOwnedVariants(part)"
                        class="btn btn-primary"
                        @click="installPart(part, result)"
                        data-focusable
                      >
                        Install
                      </button>
                      <div v-else class="install-dropdown-wrapper">
                        <button
                          class="btn btn-primary"
                          @click.stop="toggleInstallMenu(result.slotPath, part.name)"
                          data-focusable
                        >
                          Install
                          <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                            <polyline points="6 9 12 15 18 9"/>
                          </svg>
                        </button>
                        <div v-if="installMenuVisible === `${result.slotPath}_${part.name}`" class="install-menu">
                          <button v-if="!part.fromInventory" class="install-menu-item-button" @click="installPart(part, result)" data-focusable>
                            <span>New</span>
                            <span class="price-badge">$ {{ formatPrice(part.value) }}</span>
                          </button>
                          <div v-for="usedPart in getOwnedVariants(part)" :key="usedPart.partId" class="install-menu-item">
                            <button class="install-menu-item-button" @click="installUsedPart(usedPart, result)" data-focusable>
                              <span>Owned</span>
                              <span class="mileage-badge">{{ formatMileage(getUsedPartMileage(usedPart)) }}</span>
                              <span class="price-badge">$ {{ formatPrice(usedPart.finalValue || usedPart.value) }}</span>
                            </button>
                          </div>
                        </div>
                      </div>
                    </div>
                  </div>
                </div>
              </div>
            </div>
          </div>
        </div>

        <!-- 2. Slot Parts Selection View (when customizing a specific slot) -->
        <div v-else-if="activeSlotForParts" class="slot-parts-view">
          <!-- Back button and slot header -->
          <div class="slot-parts-header">
            <button
              class="back-btn"
              @click="closeSlotParts"
              type="button"
              data-focusable
            >
              <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                <polyline points="15 18 9 12 15 6" />
              </svg>
              <span>Back to Vehicle Parts</span>
            </button>

            <div class="slot-title-info">
              <div class="slot-title-row">
                <h3 class="slot-header-title">{{ activeSlotForParts.slotNiceName || activeSlotForParts.slotName }}</h3>
              </div>
              <div class="installed-tag-row">
                <span class="installed-label">Installed:</span>
                <span class="installed-val">{{ activeInstalledPartLabel }}</span>
              </div>
            </div>
          </div>

          <!-- In-slot filter input if slot has more than 5 parts -->
          <div v-if="activeSlotForParts.availableParts && activeSlotForParts.availableParts.length > 5" class="in-slot-search">
            <input
              v-model="slotPartsSearchQuery"
              type="text"
              :placeholder="'Filter ' + (activeSlotForParts.slotNiceName || activeSlotForParts.slotName) + ' parts...'"
              class="search-input in-slot-input"
              @focus="onSearchFocus"
              @blur="onSearchBlur"
              @keydown.stop @keyup.stop @keypress.stop
              v-bng-text-input
            />
          </div>

          <!-- Parts Options List -->
          <div v-if="activeSlotParts.length > 0" class="options-list">
            <div
              v-for="option in activeSlotParts"
              :key="option.name"
              class="option-item"
              :class="{ 'is-installed': option.installed }"
            >
              <div class="option-info">
                <h4>{{ option.niceName || option.name }}</h4>
                <span v-if="option.installed" class="installed-indicator">Currently Installed</span>
              </div>
              <div class="option-actions">
                <span class="option-price">$ {{ formatPrice(option.value) }}</span>
                <div v-if="option.installed" class="installed-button-wrapper">
                  <button
                    v-if="activeSlotForParts.canRemove !== true"
                    class="btn btn-disabled"
                    data-focusable
                  >
                    Installed
                  </button>
                  <template v-else>
                    <button
                      class="btn btn-disabled"
                      @click.stop="toggleRemoveMenu(activeSlotForParts.path, option.name)"
                      data-focusable
                    >
                      Installed
                      <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                        <polyline points="6 9 12 15 18 9"/>
                      </svg>
                    </button>
                    <div v-if="removeMenuVisible === `${activeSlotForParts.path}_${option.name}`" class="remove-menu">
                      <button class="remove-menu-item" @click="removePart(option, activeSlotForParts)" data-focusable>
                        Remove
                      </button>
                    </div>
                  </template>
                </div>
                <div v-else class="install-button-wrapper">
                  <button
                    v-if="!hasOwnedVariants(option)"
                    class="btn btn-primary"
                    @click="installPart(option, activeSlotForParts)"
                    data-focusable
                  >
                    Install
                  </button>
                  <div v-else class="install-dropdown-wrapper">
                    <button
                      class="btn btn-primary"
                      @click.stop="toggleInstallMenu(activeSlotForParts.path, option.name)"
                      data-focusable
                    >
                      Install
                      <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                        <polyline points="6 9 12 15 18 9"/>
                      </svg>
                    </button>
                    <div v-if="installMenuVisible === `${activeSlotForParts.path}_${option.name}`" class="install-menu">
                      <button v-if="!option.fromInventory" class="install-menu-item-button" @click="installPart(option, activeSlotForParts)" data-focusable>
                        <span>New</span>
                        <span class="price-badge">$ {{ formatPrice(option.value) }}</span>
                      </button>
                      <div v-for="usedPart in getOwnedVariants(option)" :key="usedPart.partId" class="install-menu-item">
                        <button class="install-menu-item-button" @click="installUsedPart(usedPart, activeSlotForParts)" data-focusable>
                          <span>Owned</span>
                          <span class="mileage-badge">{{ formatMileage(getUsedPartMileage(usedPart)) }}</span>
                          <span class="price-badge">$ {{ formatPrice(usedPart.finalValue || usedPart.value) }}</span>
                        </button>
                      </div>
                    </div>
                  </div>
                </div>
              </div>
            </div>
          </div>

          <div v-else class="empty-state">
            <p>No parts available matching your search</p>
          </div>
        </div>

        <!-- 3. Hierarchical Slot Tree View (Normal mode) -->
        <div v-else class="slot-tree-view">
          <!-- Tree Toolbar with stats and Expand/Collapse All buttons -->
          <div class="tree-action-bar">
            <span class="tree-summary-text">{{ totalSlotsCount }} vehicle slots</span>
            <div class="tree-controls">
              <button class="tree-action-btn" type="button" @click="expandAll" data-focusable title="Expand all categories">
                <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                  <polyline points="7 13 12 18 17 13"/>
                  <polyline points="7 6 12 11 17 6"/>
                </svg>
                <span>Expand All</span>
              </button>
              <button class="tree-action-btn" type="button" @click="collapseAll" data-focusable title="Collapse all categories">
                <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                  <polyline points="17 11 12 6 7 11"/>
                  <polyline points="17 18 12 13 7 18"/>
                </svg>
                <span>Collapse All</span>
              </button>
            </div>
          </div>

          <!-- Tree of Slots -->
          <div v-if="partsTree.length > 0" class="tree-root-list">
            <BusinessSlotTreeItem
              v-for="rootNode in partsTree"
              :key="rootNode.id"
              :node="rootNode"
              :level="0"
              :expanded-slots="expandedSlots"
              :selected-slot-id="activeSlotForParts?.id"
              @toggle-expand="toggleSlotExpand"
              @select-slot="selectSlotForParts"
            />
          </div>

          <div v-else class="empty-state">
            <p>No parts available for this vehicle</p>
          </div>
        </div>
      </div>
    </template>
  </div>
</template>

<script setup>
import { ref, computed, onMounted, watch, onBeforeUnmount } from "vue"
import { useBusinessComputerStore } from "../../stores/businessComputerStore"
import { lua } from "@/bridge"
import { vBngTextInput } from "@/common/directives"
import { useEvents } from "@/services/events"
import BusinessSlotTreeItem from "./BusinessSlotTreeItem.vue"

const store = useBusinessComputerStore()
const events = useEvents()

const normalizeVehicleCacheKey = (value) => {
  if (value === undefined || value === null) {
    return 'noveh'
  }
  return String(value)
}

const getCacheKeyForVehicle = () => {
  if (!store.pulledOutVehicle) {
    return null
  }
  return normalizeVehicleCacheKey(store.pulledOutVehicle.vehicleId)
}

const searchQuery = ref("")
const activeSearchQuery = ref("")
const partsTree = ref([])
const slotsNiceName = ref({})
const partsNiceName = ref({})
const loading = ref(true)
const openSearchSections = ref({})
const removeMenuVisible = ref(null)
const installMenuVisible = ref(null)

// Hierarchical tree state
const expandedSlots = ref({})
const activeSlotForParts = ref(null)
const slotPartsSearchQuery = ref("")

const hasActiveSearch = computed(() => activeSearchQuery.value.length > 0)

const onSearchFocus = () => {
  try { lua.setCEFTyping(true) } catch (_) {}
}

const onSearchBlur = () => {
  try { triggerSearch() } catch (_) {}
  try { lua.setCEFTyping(false) } catch (_) {}
}

const triggerSearch = () => {
  activeSearchQuery.value = searchQuery.value.trim()
  if (hasActiveSearch.value && searchResults.value.length > 0) {
    searchResults.value.forEach(result => {
      openSearchSections.value[result.slotPath] = true
    })
  } else {
    openSearchSections.value = {}
  }
}

const toggleSearchSection = (slotPath) => {
  openSearchSections.value[slotPath] = !openSearchSections.value[slotPath]
}

const clearSearch = () => {
  searchQuery.value = ""
  activeSearchQuery.value = ""
  openSearchSections.value = {}
  try { lua.setCEFTyping(false) } catch (_) {}
}

// Tree Navigation Helpers
const toggleSlotExpand = (nodeId) => {
  expandedSlots.value[nodeId] = !expandedSlots.value[nodeId]
}

const expandAll = () => {
  const markAll = (nodes) => {
    if (!nodes || !Array.isArray(nodes)) return
    for (const node of nodes) {
      if (node.children && node.children.length > 0) {
        expandedSlots.value[node.id] = true
        markAll(node.children)
      }
    }
  }
  markAll(partsTree.value)
}

const collapseAll = () => {
  expandedSlots.value = {}
}

const selectSlotForParts = (node) => {
  activeSlotForParts.value = node
  slotPartsSearchQuery.value = ""
  removeMenuVisible.value = null
  installMenuVisible.value = null
}

const closeSlotParts = () => {
  activeSlotForParts.value = null
  slotPartsSearchQuery.value = ""
  removeMenuVisible.value = null
  installMenuVisible.value = null
}

const totalSlotsCount = computed(() => {
  let count = 0
  const countNodes = (nodes) => {
    if (!nodes || !Array.isArray(nodes)) return
    for (const n of nodes) {
      count++
      if (n.children && n.children.length > 0) {
        countNodes(n.children)
      }
    }
  }
  countNodes(partsTree.value)
  return count
})

const activeSlotParts = computed(() => {
  if (!activeSlotForParts.value || !activeSlotForParts.value.availableParts) return []
  const parts = activeSlotForParts.value.availableParts
  let list = [...parts].sort((a, b) => {
    if (a.installed && !b.installed) return -1
    if (!a.installed && b.installed) return 1
    const nameA = (a.niceName || a.name || "").toLowerCase()
    const nameB = (b.niceName || b.name || "").toLowerCase()
    return nameA.localeCompare(nameB)
  })

  if (slotPartsSearchQuery.value.trim()) {
    const q = slotPartsSearchQuery.value.trim().toLowerCase()
    list = list.filter(p => (p.niceName || p.name || "").toLowerCase().includes(q))
  }
  return list
})

const activeInstalledPartLabel = computed(() => {
  if (!activeSlotForParts.value) return "-"
  if (activeSlotForParts.value.availableParts && activeSlotForParts.value.availableParts.length > 0) {
    const installedOption = activeSlotForParts.value.availableParts.find(opt => opt.installed)
    if (installedOption) {
      return installedOption.niceName || installedOption.name || "-"
    }
  }
  const categoryPart = activeSlotForParts.value.partNiceName
  if (categoryPart && categoryPart !== "-") {
    return categoryPart
  }
  return "-"
})

const findNodeByPathOrId = (nodes, idOrPath) => {
  if (!nodes || !Array.isArray(nodes)) return null
  for (const node of nodes) {
    if (node.id === idOrPath || node.path === idOrPath) return node
    if (node.children && node.children.length > 0) {
      const found = findNodeByPathOrId(node.children, idOrPath)
      if (found) return found
    }
  }
  return null
}

const searchResults = computed(() => {
  if (!hasActiveSearch.value || !partsTree.value.length) return []

  const query = activeSearchQuery.value.toLowerCase()
  const results = []
  const slotMap = {}

  const searchTree = (nodes) => {
    if (!nodes || !Array.isArray(nodes)) return

    nodes.forEach(node => {
      if (node.availableParts && node.availableParts.length > 0) {
        const matchingParts = node.availableParts.filter(part => {
          const partName = (part.niceName || part.name || '').toLowerCase()
          return partName.includes(query)
        })

        if (matchingParts.length > 0) {
          const slotKey = node.path || node.id
          if (!slotMap[slotKey]) {
            slotMap[slotKey] = {
              slotPath: slotKey,
              slotName: node.slotName || '',
              slotNiceName: node.slotNiceName || node.slotName || '',
              canRemove: node.canRemove === true,
              parts: [],
              compatibleInventoryParts: node.compatibleInventoryParts || []
            }
            results.push(slotMap[slotKey])
          }
          slotMap[slotKey].parts.push(...matchingParts)
        }
      }

      if (node.children && node.children.length > 0) {
        searchTree(node.children)
      }
    })
  }

  searchTree(partsTree.value)

  return results.map(result => ({
    ...result,
    parts: [...result.parts].sort((a, b) => {
      const nameA = (a.niceName || a.name || '').toLowerCase()
      const nameB = (b.niceName || b.name || '').toLowerCase()
      return nameA.localeCompare(nameB)
    })
  })).sort((a, b) => {
    const nameA = (a.slotNiceName || a.slotName || '').toLowerCase()
    const nameB = (b.slotNiceName || b.slotName || '').toLowerCase()
    return nameA.localeCompare(nameB)
  })
})

const installPart = async (part, slot) => {
  let slotPath = slot.slotPath || slot.path

  if (!slotPath.startsWith('/')) {
    slotPath = '/' + slotPath
  }
  if (!slotPath.endsWith('/')) {
    slotPath = slotPath + '/'
  }

  const normalizedSlot = {
    path: slotPath,
    slotPath: slotPath,
    slotNiceName: slot.slotNiceName || slot.slotName,
    slotName: slot.slotName
  }

  await store.addPartToCart(part, normalizedSlot)
}

const toggleRemoveMenu = (slotPath, partName) => {
  const menuKey = `${slotPath}_${partName}`
  if (removeMenuVisible.value === menuKey) {
    removeMenuVisible.value = null
  } else {
    removeMenuVisible.value = menuKey
    installMenuVisible.value = null
  }
}

const toggleInstallMenu = (slotPath, partName) => {
  const menuKey = `${slotPath}_${partName}`
  if (installMenuVisible.value === menuKey) {
    installMenuVisible.value = null
  } else {
    installMenuVisible.value = menuKey
    removeMenuVisible.value = null
  }
}

const formatMileage = (miles) => {
  if (!miles || miles === 0) return "0 mi"
  if (miles < 1000) return `${Math.round(miles)} mi`
  return `${(miles / 1000).toFixed(1)}k mi`
}

const formatPrice = (value) => {
  const num = value || 0
  return num.toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 })
}

const getUsedPartMileage = (usedPart) => {
  if (!usedPart) return 0
  if (typeof usedPart.mileage === "number") {
    return usedPart.mileage
  }
  const odometer = usedPart.partCondition && typeof usedPart.partCondition.odometer === "number"
    ? usedPart.partCondition.odometer
    : 0
  return odometer / 1609.344
}

const getOwnedVariants = (part) => {
  if (!part) return []
  if (Array.isArray(part.ownedVariants) && part.ownedVariants.length > 0) {
    return part.ownedVariants
  }
  if (part.fromInventory && part.partId) {
    return [{
      partId: part.partId,
      name: part.name,
      partCondition: part.partCondition,
      finalValue: part.finalValue,
      value: part.value,
      mileage: part.mileage
    }]
  }
  return []
}

const hasOwnedVariants = (part) => {
  return getOwnedVariants(part).length > 0
}

const installUsedPart = async (usedPart, slot) => {
  installMenuVisible.value = null

  let slotPath = slot.slotPath || slot.path
  if (!slotPath.startsWith('/')) {
    slotPath = '/' + slotPath
  }
  if (!slotPath.endsWith('/')) {
    slotPath = slotPath + '/'
  }

  const normalizedSlot = {
    path: slotPath,
    slotPath: slotPath,
    slotNiceName: slot.slotNiceName || slot.slotName,
    slotName: slot.slotName
  }

  const partToAdd = {
    name: usedPart.name,
    partName: usedPart.name,
    partNiceName: usedPart.niceName || usedPart.name,
    value: usedPart.finalValue || usedPart.value || 0,
    fromInventory: true,
    partId: usedPart.partId,
    partCondition: usedPart.partCondition,
    mileage: usedPart.mileage
  }

  await store.addPartToCart(partToAdd, normalizedSlot)
}

const removePart = async (part, slot) => {
  removeMenuVisible.value = null

  let slotPath = slot.slotPath || slot.path

  if (!slotPath.startsWith('/')) {
    slotPath = '/' + slotPath
  }
  if (!slotPath.endsWith('/')) {
    slotPath = slotPath + '/'
  }

  await store.removePartBySlotPath(slotPath)

  setTimeout(() => {
    loadPartsTree()
  }, 300)
}

const handlePartsTreeData = (data) => {
  if (!data || !data.success) {
    partsTree.value = []
    slotsNiceName.value = {}
    partsNiceName.value = {}
    loading.value = false
    return
  }

  if (
    String(data.vehicleId) === String(store.pulledOutVehicle?.vehicleId) &&
    String(data.businessId) === String(store.businessId)
  ) {
    if (data.partsTree) {
      const cacheKey = normalizeVehicleCacheKey(data.vehicleId)
      if (store.partsTreeCache) {
        store.partsTreeCache[cacheKey] = {
          vehicleId: data.vehicleId,
          partsTree: data.partsTree,
          slotsNiceName: data.slotsNiceName,
          partsNiceName: data.partsNiceName
        }
      }

      slotsNiceName.value = data.slotsNiceName || {}
      partsNiceName.value = data.partsNiceName || {}
      const tree = buildHierarchy(data.partsTree, data.slotsNiceName || {})
      partsTree.value = tree

      // If active slot is currently open, refresh its data so installed states update
      if (activeSlotForParts.value) {
        const updated = findNodeByPathOrId(tree, activeSlotForParts.value.id || activeSlotForParts.value.path)
        if (updated) {
          activeSlotForParts.value = updated
        }
      }

      // Auto-expand top-level categories on first load
      if (Object.keys(expandedSlots.value).length === 0 && tree.length > 0) {
        tree.forEach(node => {
          expandedSlots.value[node.id] = true
        })
      }
    } else {
      partsTree.value = []
      slotsNiceName.value = {}
      partsNiceName.value = {}
    }
    loading.value = false
  } else {
    loading.value = false
  }
}

const loadPartsTree = async () => {
  if (!store.pulledOutVehicle || !store.businessId) {
    loading.value = false
    return
  }

  loading.value = true

  const cacheKey = getCacheKeyForVehicle()
  const cachedEntry = cacheKey && store.partsTreeCache && store.partsTreeCache[cacheKey]
  if (cachedEntry && cachedEntry.vehicleId === store.pulledOutVehicle.vehicleId) {
    slotsNiceName.value = cachedEntry.slotsNiceName || {}
    partsNiceName.value = cachedEntry.partsNiceName || {}
    const tree = buildHierarchy(cachedEntry.partsTree || [], cachedEntry.slotsNiceName || {})
    partsTree.value = tree

    if (activeSlotForParts.value) {
      const updated = findNodeByPathOrId(tree, activeSlotForParts.value.id || activeSlotForParts.value.path)
      if (updated) {
        activeSlotForParts.value = updated
      }
    }

    if (Object.keys(expandedSlots.value).length === 0 && tree.length > 0) {
      tree.forEach(node => {
        expandedSlots.value[node.id] = true
      })
    }

    loading.value = false
    return
  }

  store.requestVehiclePartsTree(store.pulledOutVehicle.vehicleId).catch(() => {
    loading.value = false
  })
}

const buildHierarchy = (flatList, slotsNiceNameMap) => {
  const map = {}
  const roots = []

  const getOrCreateNode = (pathParts) => {
    const id = pathParts.join('-')
    if (map[id]) {
      return map[id]
    }

    const path = '/' + pathParts.join('/')
    const slotName = pathParts[pathParts.length - 1]

    let slotNiceName = slotName
    if (slotName && slotsNiceNameMap[slotName]) {
      slotNiceName = typeof slotsNiceNameMap[slotName] === 'object'
        ? slotsNiceNameMap[slotName].description || slotsNiceNameMap[slotName]
        : slotsNiceNameMap[slotName]
    }

    const node = {
      id: id,
      path: path,
      slotName: slotName,
      slotNiceName: slotNiceName,
      partNiceName: '-',
      canRemove: false,
      availableParts: [],
      children: []
    }

    map[id] = node

    if (pathParts.length > 1) {
      const parentPathParts = pathParts.slice(0, -1)
      const parent = getOrCreateNode(parentPathParts)
      parent.children.push(node)
    } else {
      roots.push(node)
    }

    return node
  }

  flatList.forEach(slot => {
    const pathParts = slot.path.split('/').filter(p => p)
    const slotName = pathParts[pathParts.length - 1] || slot.slotName || ''

    let slotNiceName = slot.slotNiceName
    if (!slotNiceName && slotName && slotsNiceNameMap[slotName]) {
      slotNiceName = typeof slotsNiceNameMap[slotName] === 'object'
        ? slotsNiceNameMap[slotName].description || slotsNiceNameMap[slotName]
        : slotsNiceNameMap[slotName]
    }
    if (!slotNiceName && slotName) {
      slotNiceName = slotName
    }

    const node = getOrCreateNode(pathParts)

    node.slotName = slotName
    node.slotNiceName = slotNiceName
    node.partNiceName = slot.partNiceName || '-'
    node.canRemove = slot.canRemove === true
    node.availableParts = slot.availableParts || []
    node.compatibleInventoryParts = slot.compatibleInventoryParts || []
  })

  return roots.sort((a, b) => {
    const nameA = (a.slotNiceName || a.slotName || '').toLowerCase()
    const nameB = (b.slotNiceName || b.slotName || '').toLowerCase()
    return nameA.localeCompare(nameB)
  })
}

watch(() => store.pulledOutVehicle, (newVehicle, oldVehicle) => {
  if (!newVehicle) {
    partsTree.value = []
    expandedSlots.value = {}
    activeSlotForParts.value = null
    slotsNiceName.value = {}
    partsNiceName.value = {}
    loading.value = false
    store.clearCart()
  } else {
    activeSlotForParts.value = null
    if (oldVehicle && newVehicle && oldVehicle.vehicleId !== newVehicle.vehicleId && store.vehicleView === 'parts') {
      loading.value = true
      setTimeout(() => {
        loadPartsTree()
      }, 100)
    }
  }
})

watch(() => searchResults.value, (newResults) => {
  if (hasActiveSearch.value && newResults.length > 0) {
    newResults.forEach(result => {
      if (openSearchSections.value[result.slotPath] === undefined) {
        openSearchSections.value[result.slotPath] = true
      }
    })
  }
}, { immediate: true })

watch(() => store.activeTabId, async (newTabId, oldTabId) => {
  if (newTabId && newTabId !== oldTabId && store.pulledOutVehicle && store.vehicleView === 'parts') {
    if (store.isCurrentTabApplied) {
      return
    }
    setTimeout(() => {
      if (!store.isCurrentTabApplied) {
        loadPartsTree()
      }
    }, 600)
  }
})

const handleClickOutside = (e) => {
  if (!e.target.closest('.installed-button-wrapper')) {
    removeMenuVisible.value = null
  }
  if (!e.target.closest('.install-dropdown-wrapper')) {
    installMenuVisible.value = null
  }
}

onMounted(() => {
  events.on('businessComputer:onVehiclePartsTree', handlePartsTreeData)
  document.addEventListener('click', handleClickOutside)

  requestAnimationFrame(() => {
    setTimeout(() => {
      if (store.pulledOutVehicle && store.vehicleView === 'parts') {
        loadPartsTree()
      }
    }, 600)
  })
})

onBeforeUnmount(() => {
  events.off('businessComputer:onVehiclePartsTree', handlePartsTreeData)
  document.removeEventListener('click', handleClickOutside)
})
</script>

<style scoped lang="scss">
.parts-customization {
  display: flex;
  flex-direction: column;
  height: 100%;
  overflow: hidden;
  gap: 0.5em;
}

.search-section {
  position: relative;
  flex-shrink: 0;
  display: flex;
  align-items: center;

  .search-icon {
    position: absolute;
    left: 0.75em;
    top: 50%;
    transform: translateY(-50%);
    color: rgba(255, 255, 255, 0.4);
    width: 1em;
    height: 1em;
    pointer-events: none;
    z-index: 1;
  }

  .search-input {
    width: 100%;
    padding: 0.6em 1em 0.6em 2.5em;
    background: rgba(23, 23, 23, 0.5);
    border: 1px solid rgba(255, 255, 255, 0.1);
    border-radius: 0.35em;
    color: white;
    font-size: 0.875em;

    &::placeholder {
      color: rgba(255, 255, 255, 0.5);
    }

    &:focus {
      outline: none;
      border-color: rgba(245, 73, 0, 0.5);
      padding-right: 2.5em;
    }
  }

  .clear-search-button {
    position: absolute;
    right: 0.5em;
    top: 50%;
    transform: translateY(-50%);
    background: transparent;
    border: none;
    cursor: pointer;
    padding: 0.25em;
    display: flex;
    align-items: center;
    justify-content: center;
    color: rgba(255, 255, 255, 0.5);
    transition: color 0.2s;
    z-index: 1;

    &:hover {
      color: rgba(255, 255, 255, 0.8);
    }

    svg {
      width: 1em;
      height: 1em;
    }
  }
}

.scrollable-content {
  flex: 1;
  overflow-y: auto;
  min-height: 0;
  padding-right: 0.2em;

  &::-webkit-scrollbar {
    width: 8px;
  }

  &::-webkit-scrollbar-track {
    background: rgba(0, 0, 0, 0.2);
    border-radius: 4px;
  }

  &::-webkit-scrollbar-thumb {
    background: rgba(255, 255, 255, 0.1);
    border-radius: 4px;

    &:hover {
      background: rgba(255, 255, 255, 0.18);
    }
  }
}

/* Tree Toolbar */
.tree-action-bar {
  display: flex;
  align-items: center;
  justify-content: space-between;
  margin-bottom: 0.35em;
  padding: 0.25em 0.1em;
  border-bottom: 1px solid rgba(255, 255, 255, 0.06);

  .tree-summary-text {
    color: rgba(255, 255, 255, 0.5);
    font-size: 0.8em;
    font-weight: 500;
    text-transform: uppercase;
    letter-spacing: 0.05em;
  }

  .tree-controls {
    display: flex;
    align-items: center;
    gap: 0.4em;
  }

  .tree-action-btn {
    display: inline-flex;
    align-items: center;
    gap: 0.35em;
    background: rgba(255, 255, 255, 0.05);
    border: 1px solid rgba(255, 255, 255, 0.08);
    border-radius: 0.3em;
    padding: 0.25em 0.55em;
    color: rgba(255, 255, 255, 0.65);
    font-size: 0.75em;
    font-weight: 500;
    cursor: pointer;
    transition: all 0.15s ease;

    &:hover {
      background: rgba(245, 73, 0, 0.15);
      border-color: rgba(245, 73, 0, 0.5);
      color: white;
    }
  }
}

.tree-root-list {
  display: flex;
  flex-direction: column;
}

/* Slot Parts View (Dedicated panel for choosing parts in a slot) */
.slot-parts-view {
  display: flex;
  flex-direction: column;
  gap: 0.85em;
}

.slot-parts-header {
  display: flex;
  flex-direction: column;
  gap: 0.6em;
  padding: 0.75em 0.9em;
  background: rgba(18, 18, 18, 0.85);
  border: 1px solid rgba(255, 255, 255, 0.08);
  border-radius: 0.5em;
  box-shadow: 0 6px 16px rgba(0, 0, 0, 0.28);

  .back-btn {
    display: inline-flex;
    align-items: center;
    gap: 0.4em;
    background: transparent;
    border: none;
    color: rgba(245, 73, 0, 1);
    font-size: 0.85em;
    font-weight: 600;
    cursor: pointer;
    padding: 0;
    align-self: flex-start;
    transition: color 0.15s, transform 0.1s;

    &:hover {
      color: rgba(245, 73, 0, 0.8);
      transform: translateX(-2px);
    }
  }

  .slot-title-info {
    display: flex;
    flex-direction: column;
    gap: 0.3em;

    .slot-title-row {
      display: flex;
      align-items: baseline;
      justify-content: space-between;
      gap: 0.5em;

      .slot-header-title {
        margin: 0;
        color: white;
        font-size: 1.1em;
        font-weight: 600;
      }
    }

    .installed-tag-row {
      display: flex;
      align-items: center;
      gap: 0.4em;
      font-size: 0.825em;

      .installed-label {
        color: rgba(255, 255, 255, 0.5);
      }

      .installed-val {
        color: rgba(245, 73, 0, 0.9);
        font-weight: 500;
        background: rgba(245, 73, 0, 0.1);
        border: 1px solid rgba(245, 73, 0, 0.3);
        padding: 0.15em 0.5em;
        border-radius: 0.25em;
      }
    }
  }
}

.in-slot-search {
  .in-slot-input {
    padding: 0.55em 0.85em;
    font-size: 0.825em;
  }
}

/* Options List */
.options-list {
  display: flex;
  flex-direction: column;
  gap: 0.6em;
}

.option-item {
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding: 0.75em 0.9em;
  background: rgba(23, 23, 23, 0.6);
  border: 1px solid rgba(255, 255, 255, 0.08);
  border-radius: 0.5em;
  transition: border-color 0.2s, background 0.2s;

  &:hover {
    border-color: rgba(245, 73, 0, 0.5);
    background: rgba(28, 28, 28, 0.8);
  }

  &.is-installed {
    border-left: 3px solid rgba(245, 73, 0, 0.9);
    background: rgba(35, 24, 18, 0.5);
  }

  .option-info {
    flex: 1;
    min-width: 0;

    h4 {
      margin: 0;
      color: white;
      font-size: 0.875em;
      font-weight: 600;
      text-align: left;
      word-wrap: break-word;
    }

    .installed-indicator {
      display: inline-block;
      margin-top: 0.25em;
      color: rgba(245, 73, 0, 0.9);
      font-size: 0.75em;
      font-weight: 500;
    }
  }

  .option-actions {
    display: flex;
    align-items: center;
    gap: 0.75em;
    flex-shrink: 0;

    .option-price {
      color: rgba(245, 73, 0, 1);
      font-size: 0.875em;
      font-weight: 500;
      min-width: 5.5em;
      text-align: right;
    }
  }
}

/* Search Results View */
.search-results {
  display: flex;
  flex-direction: column;
  gap: 0.75em;
}

.search-result-section {
  margin-bottom: 1.25em;
  flex-shrink: 0;

  &.collapsed {
    margin-bottom: 0;

    .result-section-header {
      margin-bottom: 0;
    }
  }

  .result-section-header {
    width: 100%;
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 0.75em 0.9em;
    background: rgba(18, 18, 18, 0.85);
    border: 1px solid rgba(255, 255, 255, 0.08);
    cursor: pointer;
    transition: background 0.15s, border-color 0.15s, transform 0.1s, box-shadow 0.15s;
    margin-bottom: 0.6em;
    border-radius: 0.5em;
    box-shadow: 0 6px 16px rgba(0, 0, 0, 0.28);

    &:hover {
      background: rgba(28, 28, 28, 0.95);
      border-color: rgba(245, 73, 0, 0.5);
      transform: translateY(-1px);
      box-shadow: 0 8px 18px rgba(0, 0, 0, 0.35);
    }

    &:active {
      transform: translateY(0);
      border-color: rgba(245, 73, 0, 0.75);
    }

    h3 {
      margin: 0;
      color: white;
      font-size: 0.95em;
      font-weight: 600;
    }

    .chevron-icon {
      color: rgba(255, 255, 255, 0.4);
      flex-shrink: 0;
    }
  }

  .result-parts-list {
    display: flex;
    flex-direction: column;
    gap: 0.6em;
  }
}

/* Common UI States & Buttons */
.empty-state,
.loading-state {
  padding: 3em;
  text-align: center;
  color: rgba(255, 255, 255, 0.5);

  p {
    margin: 0;
  }
}

.btn {
  padding: 0.5em 1em;
  border-radius: 0.375em;
  font-size: 0.875em;
  font-weight: 500;
  cursor: pointer;
  transition: all 0.2s;
  border: none;
  flex-shrink: 0;

  &.btn-primary {
    background: rgba(55, 55, 55, 1);
    color: white;

    &:hover:not(:disabled) {
      background: rgba(245, 73, 0, 1);
    }
  }

  &.btn-disabled {
    background: rgba(55, 55, 55, 1);
    color: rgba(255, 255, 255, 0.4);
    cursor: pointer;
    display: flex;
    align-items: center;
    gap: 0.5em;

    svg {
      width: 12px;
      height: 12px;
      transition: transform 0.2s;
    }

    &:hover {
      background: rgba(65, 65, 65, 1);
    }
  }
}

.installed-button-wrapper,
.install-button-wrapper,
.install-dropdown-wrapper {
  position: relative;
  display: inline-block;
}

.remove-menu,
.install-menu {
  position: absolute;
  top: 100%;
  right: 0;
  margin-top: 0.25em;
  background: rgba(24, 24, 24, 0.98);
  border: 1px solid rgba(255, 255, 255, 0.15);
  border-radius: 0.375em;
  padding: 0.25em;
  z-index: 100;
  min-width: 12em;
  box-shadow: 0 8px 24px rgba(0, 0, 0, 0.6);
  display: flex;
  flex-direction: column;
  gap: 0.2em;
}

.remove-menu-item {
  width: 100%;
  padding: 0.5em 0.75em;
  background: transparent;
  border: none;
  color: rgba(255, 80, 80, 0.9);
  font-size: 0.85em;
  text-align: left;
  cursor: pointer;
  border-radius: 0.25em;
  transition: background 0.15s;

  &:hover {
    background: rgba(255, 0, 0, 0.15);
    color: white;
  }
}

.install-menu-item {
  width: 100%;
}

.install-menu-item-button {
  width: 100%;
  padding: 0.5em 0.75em;
  background: transparent;
  border: none;
  color: white;
  font-size: 0.85em;
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 0.5em;
  cursor: pointer;
  border-radius: 0.25em;
  transition: background 0.15s;

  &:hover {
    background: rgba(245, 73, 0, 0.2);
  }

  .price-badge {
    color: rgba(245, 73, 0, 1);
    font-weight: 500;
  }

  .mileage-badge {
    color: rgba(255, 255, 255, 0.6);
    font-size: 0.8em;
  }
}
</style>
