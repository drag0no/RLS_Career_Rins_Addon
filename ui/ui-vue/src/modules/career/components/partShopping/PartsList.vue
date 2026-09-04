<template>
  <div class="parts-wrapper">
    <div class="search-container">
      <BngInput
        v-model="searchTerm"
        :leading-icon="icons.search"
        :label="$translate.instant('ui.common.search')"
        floating-label
      />
    </div>

    <div
      v-if="displayedParts.length > 0"
      ref="partsListEl"
      class="parts-list"
      @scroll="onPartsListScroll"
    >
      <div
        v-for="part in displayedParts"
        :key="partKey(part)"
        class="part-item"
        :class="{ 'part-installed': partShoppingStore.partShoppingData?.vehicleSlotToPartMap?.[part.containingSlot]?.description?.description === part.description.description,
        'disabled': part.disabled }"
      >
        <div class="part-info-col">
          <div>
            <span class="part-name">
              <div v-if="part.partId">
                {{ part.description.description }} ({{ $translate.instant("ui.career.partShopping.inventory") }})
              </div>
              <div v-else-if="part.emptyPlaceholder">
                {{ $translate.instant("ui.career.partShopping.removeCurrentPart") }}
              </div>
              <div v-else>
                {{ part.description.description }}
              </div>
            </span>
          </div>
          <div class="part-info-row">
            <span v-if="part.partId" class="mileage-text">
              {{ $translate.instant("ui.career.shared.mileagePrefix") }}{{ units.buildString("length", part.partCondition.odometer, 0) }}
            </span>
            <span v-if="partShoppingStore.category === 'cargo'">
              {{ partShoppingStore.partShoppingData?.slotsNiceName?.[part.containingSlot] }}
            </span>
            <span v-if="part.disabled && part.disabledReason" class="disabled-reason">{{ part.disabledReason }}</span>
            <span v-if="!part.partId && !part.emptyPlaceholder" class="right"><BngPropVal :iconType="icons.beamCurrency" :valueLabel="units.beamBucks(part.finalValue)" /></span>
          </div>
        </div>

        <BngButton
          :accent="getCorrespondingPartInShoppingCart(part) ? ACCENTS.attention : ACCENTS.outlined"
          class="part-button"
          :disabled="partShoppingStore.partShoppingData?.restoreInProgress || part.disabled || tutorialBlocksPart(part) || isPartInShoppingCartButNotRemovable(part)"
          @click="isPartRemovableFromShoppingCart(part) ? lua.career_modules_partShopping.removePartBySlot(part.containingSlot) : lua.career_modules_partShopping.installPartByPartShopId(part.partShopId)"
          :icon="getCorrespondingPartInShoppingCart(part) ? icons.undo : ''">
          <div v-if="!getCorrespondingPartInShoppingCart(part)">
            {{ part.emptyPlaceholder ? $translate.instant("ui.career.partShopping.remove") : $translate.instant("ui.career.partShopping.install") }}
          </div>
        </BngButton>
      </div>
    </div>
    <div v-else-if="searchTerm && (partShoppingStore.filteredParts?.length > 0)" class="no-results">
      No parts matching "{{ searchTerm }}"
    </div>
  </div>
</template>

<script setup>
import { BngButton, BngPropVal, BngInput, ACCENTS, icons } from "@/common/components/base"
import { lua, useBridge } from "@/bridge"
import { ref, computed, watch, nextTick } from "vue"
import { usePartShoppingStore } from "../../stores/partShoppingStore"
import { $translate } from "@/services/translation"

const partShoppingStore = usePartShoppingStore()

const { units } = useBridge()
const searchTerm = ref("")
const partsListEl = ref(null)
let savedScrollTop = 0
let restoringScroll = false

const displayedParts = computed(() => {
  const parts = partShoppingStore.filteredParts || []
  if (!searchTerm.value) return parts

  const term = searchTerm.value.toLowerCase()
  return parts.filter(part =>
    part.description?.description?.toLowerCase?.().includes(term)
  )
})

const partKey = (part) => {
  if (part.partShopId != null) return `shop-${part.partShopId}`
  if (part.partId != null) return `inv-${part.partId}`
  if (part.emptyPlaceholder) return `empty-${part.containingSlot || "slot"}`
  return `${part.containingSlot || "slot"}-${part.name || "part"}`
}

const onPartsListScroll = () => {
  // Ignore the transient scrollTop=0 that Vue emits while the list re-renders after install.
  if (restoringScroll || !partsListEl.value) return
  savedScrollTop = partsListEl.value.scrollTop
}

// Opening a different slot should start at the top; returning to the same slot keeps scroll.
watch(
  () => partShoppingStore.slot,
  (next, prev) => {
    if (next && next !== prev) {
      savedScrollTop = 0
      if (partsListEl.value) partsListEl.value.scrollTop = 0
    }
  }
)

// Install/remove refreshes filteredParts and would otherwise snap the list to top.
watch(
  () => partShoppingStore.filteredParts,
  () => {
    if (partsListEl.value && !restoringScroll) {
      savedScrollTop = partsListEl.value.scrollTop
    }
    restoringScroll = true
    nextTick(() => {
      requestAnimationFrame(() => {
        if (partsListEl.value) {
          partsListEl.value.scrollTop = savedScrollTop
        }
        restoringScroll = false
      })
    })
  },
  { flush: "pre" }
)

const getCorrespondingPartInShoppingCart = (part) => {
  if (!partShoppingStore.partShoppingData || !partShoppingStore.partShoppingData.shoppingCart) return false
  let partList = partShoppingStore.partShoppingData.shoppingCart.partsInList
  for (let i = 0; i < partList.length; i++) {
    let shoppingCartPart = partList[i]
    if (shoppingCartPart.partId == part.partId && part.name == shoppingCartPart.name && part.containingSlot == shoppingCartPart.containingSlot) return shoppingCartPart
  }
  return false
}

const isShoppingCartPartSourcePart = (part) => {
  return part.sourcePart
}

const isPartRemovableFromShoppingCart = (part) => {
  let shoppingCartPart = getCorrespondingPartInShoppingCart(part)
  return shoppingCartPart && isShoppingCartPartSourcePart(shoppingCartPart)
}

const isPartInShoppingCartButNotRemovable = (part) => {
  let shoppingCartPart = getCorrespondingPartInShoppingCart(part)
  return shoppingCartPart && !isShoppingCartPartSourcePart(shoppingCartPart)
}

const tutorialBlocksPart = (part) => {
  const tutorialPartNames = partShoppingStore.partShoppingData?.tutorialPartNames
  if (tutorialPartNames === undefined) return false
  return !tutorialPartNames[part.name] || isPartRemovableFromShoppingCart(part)
}
</script>

<style lang="scss" scoped>
.parts-wrapper {
  display: flex;
  flex-direction: column;
  flex: 1 1 auto;
  min-height: 0;
  width: 100%;
  height: 100%;
  max-height: 100%;
  overflow: hidden;
}

.search-container {
  flex: 0 0 auto;
  padding: 0.25rem;
}

.parts-list {
  flex: 1 1 auto;
  min-height: 0;
  width: 100%;
  padding: 0 1em;
  overflow: hidden auto;
}

.part-item {
  display: flex;
  flex-direction: row;
  flex-wrap: nowrap;
  justify-content: stretch;
  align-items: center;
  overflow: hidden;
  width: 100%;
  height: 4em;
  color: #fff;
  > *:first-child {
    padding-left: 0.25em;
  }
  &.part-installed {
    border-radius: var(--bng-corners-1) 0 0 var(--bng-corners-1);
    background-image: linear-gradient(90deg, rgba(#f60, 0.5), rgba(#f60, 0.0) 65%);
  }
  > * {
    flex: 1 1 auto;
  }
  &:not(:last-child) {
    border-bottom: 1px solid #666;
  }
  &.disabled {
    opacity: 0.5;
  }
}

.part-info-col {
  display: flex;
  flex-direction: column;
  justify-content: stretch;
  flex: 1 1 auto; /* Allows it to grow but keeps it within bounds */
  max-width: calc(100% - 100px); /* Adjust according to the button width */
  overflow: hidden;

  > * {
    max-width: 100%;
    overflow: hidden;
  }
}

.part-info-row {
  display: flex;
  flex-direction: row;
  flex-wrap: nowrap;
  justify-content: stretch;
  align-items: baseline;
  > * {
    flex: 1 1 auto;
  }
}

.part-button {
  min-width: 100px;
  flex: 0 0 auto; /* Prevent it from shrinking or growing */
}

.part-name {
  display: block;
  font-size: 1.1em;
  font-weight: 600;
  white-space: nowrap;
  text-overflow: ellipsis;
  overflow: hidden;
}

.mileage-text {
  font-size: 0.9em;
  font-weight: normal;
  color: rgba(255, 255, 255, 0.8);
}

.disabled-reason {
  font-size: 0.9em;
  align-self: center;
  white-space: normal;
  overflow-wrap: anywhere;
  word-break: break-word;
  margin-right: 0.5em;
}

.center {
  text-align: center;
}
.right {
  text-align: right;
}

.no-results {
  padding: 1em;
  text-align: center;
  color: rgba(255, 255, 255, 0.7);
  font-style: italic;
}
</style>
