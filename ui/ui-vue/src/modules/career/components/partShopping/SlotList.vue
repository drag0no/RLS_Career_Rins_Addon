<template>
  <div class="slot-list-root">
    <div class="search-container">
      <BngInput
        v-model="searchValue"
        :leading-icon="icons.search"
        :label="$translate.instant('ui.common.search')"
        floating-label
        @change="searchValueChanged" />
    </div>

    <div
      class="innerList"
      v-bng-ui-nav-scroll
    >
      <!-- show a flat list when the user is searching for something -->
      <Accordion v-if="searchValue.length > 0" class="slot-flat-view">
        <SlotItem
          v-for="slotInfo in partShoppingStore.filteredSlots"
          :key="slotInfo.path"
          :static="true"
          :path="slotInfo.path"
          :nicePath="slotInfo.nicePath"
          :slotNiceName="slotInfo.slotNiceName"
          :partNiceName="slotInfo.partNiceName ? slotInfo.partNiceName : null" />
      </Accordion>

      <!-- else show the part tree only if children exists -->
      <PartSubTree
        v-else-if="partShoppingStore.partShoppingData?.partTree?.children"
        class="slot-tree-view"
        :children="partShoppingStore.partShoppingData.partTree.children" />
    </div>
  </div>
</template>

<script setup>
import { BngInput, icons } from "@/common/components/base"
import PartSubTree from "./PartSubTree.vue"
import SlotItem from "./SlotItem.vue"
import { Accordion } from "@/common/components/utility"
import { vBngUiNavScroll } from "@/common/directives"
import { ref } from "vue"
import { usePartShoppingStore } from "../../stores/partShoppingStore"
import { $translate } from "@/services/translation"

const partShoppingStore = usePartShoppingStore()

defineProps({
  cancel: Function,
})

const searchValue = ref("")

const searchValueChanged = () => {
  partShoppingStore.searchValueChanged(searchValue.value.trim())
}
</script>

<style scoped lang="scss">
.slot-list-root {
  display: flex;
  flex-direction: column;
  flex: 1 1 auto;
  min-height: 0;
  width: 100%;
  overflow: hidden;
}

.search-container {
  flex: 0 0 auto;
  padding: 0.25rem;
}

.innerList {
  flex: 1 1 auto;
  min-height: 0;
  overflow-y: auto;
  & [bng-nav-item] {
    cursor: pointer;
  }
}

.slot-tree-view {
  margin: 0 0.25rem;
}
.slot-flat-view {
  margin: 0 0.75rem;
}
</style>
