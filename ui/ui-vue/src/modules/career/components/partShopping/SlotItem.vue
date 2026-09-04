<template>
  <AccordionItem
    :static="isStatic"
    :expanded="expanded"
    :primary-action="() => openSlot()"
    :expand-on-context="false"
    navigable
    expand-hint-inline
    primary-hint-inline
    @expanded="itemExpanded"
    @focus="onFocus"
    @unfocus="onUnfocus"
    @selected="selectSlot"
  >
    <template #caption>
      <div v-if="partShoppingStore.slotToScrollTo === path" class="highlighted">
      </div>
      <span class="slot-path" v-if="nicePath">
        {{ nicePath }}
      </span>
      <span ref="slotItem" class="slot-name">
        {{ slotNiceName }}
      </span>
    </template>
    <template #controls>
      <BngButton
        bng-no-nav="true"
        class="buy-button"
        :accent="ACCENTS.outlined"
        @click="openSlot()"
        v-bng-tooltip:top="partNiceName"
        :style="{backgroundColor: partShoppingStore.slotToScrollTo && partShoppingStore.slotToScrollTo == path ? 'rgba(75,75,75,0.8)' : '' }"
      >
        <span class="buy-button-label">
          {{ partNiceName ? partNiceName : "-" }}
        </span>
      </BngButton>
    </template>
    <slot></slot>
  </AccordionItem>
</template>

<script setup>
import { ref, computed, onMounted, watch, nextTick } from "vue"
import { lua } from "@/bridge"
import { vBngTooltip } from "@/common/directives"
import { BngButton, ACCENTS } from "@/common/components/base"
import { AccordionItem } from "@/common/components/utility"
import { usePartShoppingStore } from "../../stores/partShoppingStore"

const slotItem = ref()
const focused = ref(false)

const props = defineProps({
  static: Boolean,
  expanded: Boolean,
  path: String,
  nicePath: String,
  slotNiceName: String,
  partNiceName: String
})

const partShoppingStore = usePartShoppingStore()

const isStatic = computed(() => props.static)

const scrollIntoViewIfTarget = () => {
  if (!partShoppingStore.slotToScrollTo) return
  if (props.path !== partShoppingStore.slotToScrollTo) return
  if (!slotItem.value) return
  // Skip while hidden (v-show); store re-triggers on return to slots.
  if (partShoppingStore.activePanel !== "slots") return
  slotItem.value.scrollIntoView({ block: "center" })
}

const scheduleScrollIntoView = () => {
  nextTick(() => {
    requestAnimationFrame(() => {
      requestAnimationFrame(scrollIntoViewIfTarget)
    })
  })
}

onMounted(scheduleScrollIntoView)

// Store clears then re-sets this on back so keep-alive rows always re-scroll.
watch(
  () => partShoppingStore.slotToScrollTo,
  scheduleScrollIntoView
)

const itemExpanded = val => {
  partShoppingStore.setSlotExpanded(props.path, val)
}

const onFocus = () => {
  focused.value = true
}

const onUnfocus = () => {
  focused.value = false
}

const openSlot = () =>
  lua.extensions.ui_router.navigate("career.computer.partShopping.category.slot", {
    category: partShoppingStore.category,
    slotPath: props.path,
  })

const selectSlot = () => {
  openSlot()
}
</script>

<style lang="scss" scoped>
.buy-button {
  max-width: 10em !important;
  min-height: unset;
  padding-top: 0.3em;
  padding-bottom: 0.2em;
  .buy-button-label {
    display: inline-block;
    max-width: 100%;
    white-space: nowrap;
    text-overflow: ellipsis;
    overflow: hidden;
  }
}
.slot-name,
.slot-path {
  display: block;
  max-width: 100%;
  white-space: nowrap;
  text-overflow: ellipsis;
  overflow: hidden;
}
.slot-path {
  color: #bbb;
  font-size: 0.8em;
}
:deep() {
  .bng-accitem-caption-content {
    overflow: hidden !important;
    z-index: 0;
  }
  .bng-accitem-caption-controls {
    overflow: visible !important;
    z-index: 1;
  }
  .bng-accitem-caption-expander {
    z-index: 1;
  }
}

@keyframes blink {
  0% {
    background-color: rgb(var(--bng-orange-500-rgb),0.8);
  }
  70% {
   background-color: rgb(var(--bng-orange-500-rgb),0.8);
  }
  100% {
    background-color: rgb(var(--bng-orange-500-rgb),0.0);
  }
}

.highlighted {
  animation: blink 1.0s linear ;
  background-image: linear-gradient(90deg,
      rgba(var(--bng-orange-500-rgb),1) 0%,
      rgba(var(--bng-orange-500-rgb),0.8) 0.45em,
      rgba(var(--bng-orange-500-rgb),0.5) 0.451em,
      rgba(var(--bng-orange-100-rgb),0.1) 100%,
    );
  position:absolute;
  z-index: 0;
  top: 0rem;
  right: 0rem;
  left: 0rem;
  bottom:0rem;
  overflow:hidden;
  z-index: -1;
  border-radius:var(--bng-corners-2);

}
</style>
