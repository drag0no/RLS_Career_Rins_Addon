<template>
  <ComputerPanel
    class="cart"
    :class="{ expanded }"
    :active="active"
    heading-hint-start-icon="arrowLargeRight"
    :heading-hint-start-binding-event="activateBindingUiEvent"
  >
    <template #heading-content>
      <div class="cart-heading">
        <span class="cart-heading-text">{{ $translate.instant("ui.career.shoppingCart.title") }}</span>
        <BngButton
          class="cart-expand"
          bng-no-nav="true"
          v-bng-on-ui-nav:action_2="() => (expanded = !expanded)"
          v-bng-ui-nav-label:action_2="$translate.instant('ui.career.shoppingCart.toggleExpanded')"
          :accent="ACCENTS.outlined"
          :icon="expanded ? icons.arrowLargeDown : icons.arrowLargeUp"
          @click="expanded = !expanded" />
      </div>
    </template>
    <div class="cart-main">
      <div class="cart-row cart-header">
        <div></div>
        <div>{{ $translate.instant("ui.career.shoppingCart.part") }}</div>
        <div>{{ $translate.instant("ui.career.shoppingCart.price") }}</div>
      </div>
      <div class="cart-list" bng-nav-scroll>
        <template v-if="cartData">
          <div v-for="item in cartData.items" :key="item.name" class="cart-row" :class="item.type ? [`type-${item.type}`] : null">
            <div>
              <BngButton
                v-if="item.removeShow"
                accent="attention"
                :icon="icons.abandon"
                :disabled="item.removeDisabled"
                @click="emit('remove-item', item)" />
            </div>
            <div :style="{ paddingLeft: item.level ? `${item.level - 1}em` : undefined }">
              {{ item.name }}
              <div v-if="item.extraInfo" class="extra-info-text">
                {{ item.extraInfo }}
              </div>
            </div>
            <div v-if="!item.priceHide">
              {{ units.beamBucks(item.price) }}
            </div>
            <div v-else></div>
          </div>
        </template>
        <div class="cart-row cart-subtotal">
          <div></div>
          <div>{{ $translate.instant("ui.career.shoppingCart.subtotal") }}</div>
          <div>{{ units.beamBucks(subtotal) }}</div>
        </div>
        <div class="cart-row cart-tax">
          <div></div>
          <div>{{ $translate.instant("ui.career.shoppingCart.salesTax", { rate: 7 }) }}</div>
          <div>{{ units.beamBucks(salesTax) }}</div>
        </div>
      </div>
      <div class="cart-row cart-total">
        <div></div>
        <div>{{ $translate.instant("ui.career.shoppingCart.total") }}</div>
        <div><BngUnit :money="cartData ? cartData.total : 0" /></div>
      </div>
    </div>
    <template #footer>
      <div v-if="showSaveForLater && restoreInProgress" class="restore-banner">
        Restoring saved build… {{ restoreProgress.current }}/{{ restoreProgress.total }}
      </div>
      <BngButton
        v-if="holdToConfirm"
        ref="confirmBtn"
        show-hold
        :disabled="confirmDisabled"
        v-bng-on-ui-nav:ok.asMouse.focusRequired
        v-bng-click="{
          holdCallback: completeHoldSound,
          holdDelay: 1000,
          repeatInterval: 0,
          holdSoundInstanceId: 'shopping-cart-purchase',
        }"
      >
        {{ confirmButtonText || $translate.instant("ui.career.vehiclePurchase.purchase") }}
      </BngButton>
      <BngButton
        v-else
        ref="confirmBtn"
        :disabled="confirmDisabled"
        :accent="ACCENTS.primary"
        @click.stop="onConfirmClick"
      >
        {{ confirmButtonText || "Confirm" }}
      </BngButton>
      <BngButton
        v-if="showSaveForLater"
        :disabled="saveForLaterDisabled"
        :accent="ACCENTS.secondary"
        @click="emit('save-for-later')"
      >
        Save for later
      </BngButton>
      <BngButton
        :disabled="showSaveForLater && restoreInProgress"
        @click="emit('cancel')"
        :accent="ACCENTS.secondary">
        {{ $translate.instant("ui.common.cancel") }}
      </BngButton>
    </template>
  </ComputerPanel>
</template>

<script setup>
import { ref, computed, watch, nextTick } from "vue"
import { useBridge } from "@/bridge"
import { BngButton, ACCENTS, BngUnit, icons } from "@/common/components/base"
import ComputerPanel from "./ComputerPanel.vue"
import { $translate } from "@/services/translation"
import { vBngClick, vBngOnUiNav, vBngUiNavLabel } from "@/common/directives"
import { useUINavBlocker } from "@/services/uiNavTracker"
import { setFocus } from "@/services/uiNavFocus"

const props = defineProps({
  cartData: Object,
  playerMoney: Number,
  confirmButtonText: String,
  activateBindingUiEvent: {
    type: String,
    default: "context",
  },
  active: Boolean,
  showSaveForLater: Boolean,
  restoreInProgress: Boolean,
  restoreProgress: {
    type: Object,
    default: () => ({ current: 0, total: 0 }),
  },
  holdToConfirm: {
    type: Boolean,
    default: true,
  },
})

const emit = defineEmits(["apply", "cancel", "save-for-later", "remove-item"])

const { units } = useBridge()

const expanded = ref(false)
const confirmBtn = ref(null)

const confirmDisabled = computed(() =>
  (props.showSaveForLater && props.restoreInProgress) ||
  !props.cartData ||
  props.cartData.items.length === 0 ||
  (Number(props.cartData.total) > 0 &&
    props.playerMoney != null &&
    Number.isFinite(Number(props.playerMoney)) &&
    Number(props.cartData.total) > Number(props.playerMoney))
)

const saveForLaterDisabled = computed(() =>
  props.restoreInProgress ||
  !props.cartData ||
  !props.cartData.items ||
  props.cartData.items.length === 0
)

function focusConfirm() {
  if (confirmDisabled.value) return
  nextTick(() => {
    const el = confirmBtn.value?.getElement?.()
    if (el) setFocus(el)
  })
}

const navBlocker = useUINavBlocker()
watch(
  () => props.active,
  show => {
    show ? navBlocker.blockOnly() : navBlocker.blockOnly(["action_2"])
    // Dual-scope cart often lands focus on Cancel; put it on Confirm when the cart activates.
    if (show) focusConfirm()
  },
  { immediate: true }
)

// If the cart was already active while empty, focus Confirm once items become purchasable.
watch(confirmDisabled, (disabled, wasDisabled) => {
  if (props.active && wasDisabled && !disabled) focusConfirm()
})

const subtotal = computed(() => {
  if (!props.cartData) return 0
  return (Number(props.cartData.total) || 0) - (Number(props.cartData.taxes) || 0)
})

const salesTax = computed(() => props.cartData && props.cartData.taxes ? props.cartData.taxes : 0)

function isPrimaryInteraction(event) {
  return !event || event.fromController || event.button === 0
}

function completeHoldSound(event) {
  if (!isPrimaryInteraction(event)) return
  emit("apply")
}

function onConfirmClick(event) {
  if (confirmDisabled.value) return
  if (event && event.button != null && event.button !== 0) return
  emit("apply")
}
</script>

<style scoped lang="scss">
.cart {
  align-self: flex-start;
  width: 100%;
  flex: 1 0 auto;
  height: 27em;
  color: white;
  background-color: rgba(0, 0, 0, 0.85);
  transition: background-color 0.15s ease;
  & :deep(.card-cnt) {
    background-color: transparent;
  }
  &.expanded {
    height: auto;
    min-height: 27em;
    max-height: 100%;
  }
}

.cart-heading {
  display: flex;
  align-items: center;
  justify-content: flex-start;
  gap: 0.5em;
}

.cart-heading-text {
  flex: 0 1 auto;
}

.cart-expand {
  margin-left: auto;
}

.cart-main {
  display: flex;
  flex-direction: column;
  width: 100%;
  max-height: 100%;
  overflow: hidden;

  .cart-row {
    display: flex;
    flex-direction: row;
    flex-wrap: nowrap;
    align-items: center;
    justify-content: stretch;
    $size: 3rem;
    flex: 0 0 $size;
    height: $size;
    overflow: hidden;
    > * {
      flex: 1 0 auto;
      &:first-child {
        $size: 4rem;
        flex: 0 0 $size;
        width: $size;
        font-size: 1rem !important;
        text-align: center;
      }
      &:last-child {
        $size: 8rem;
        flex: 0 0 $size;
        width: $size;
        padding-right: 1.5rem;
        text-align: right;
      }
    }
  }

  .cart-header {
    $size: 2rem;
    flex: 0 0 $size;
    align-items: flex-start;
    height: $size;
    font-size: 1.1em;
    font-weight: 600;
    border-bottom: 1px solid #aaa8;
  }

  .cart-total {
    flex: 0 0 auto;
    font-size: 1.3em;
    font-weight: 600;
    border-top: 1px solid #aaa8;
    > * {
      &:last-child {
        $size: 9rem;
        flex: 0 0 $size;
        width: $size;
        :deep(.info-item) {
          padding: 0;
        }
      }
    }
  }
}

.extra-info-text {
  font-size: 0.9em;
  font-weight: normal;
  color: rgba(255, 255, 255, 0.8);
}

.cart-list {
  display: flex;
  flex-direction: column;
  overflow: auto scroll;
  flex: 1 1 auto;
  min-height: 0;
  .cart-row > *:last-child {
    padding-right: calc(1.5rem - 6px);
  }
  .cart-subtotal,
  .cart-tax {
    $size: 2.3rem;
    flex: 0 0 $size;
    height: $size;
    font-weight: 600;
  }
  .cart-subtotal {
    align-items: flex-end;
    border-top: 1px solid #aaa4;
  }
  .cart-tax {
    padding-bottom: 0.3rem;
    font-weight: 600;
  }
}

.restore-banner {
  width: 100%;
  padding: 0.5em 0.75em;
  margin-bottom: 0.5em;
  border-radius: var(--bng-corners-1);
  background: rgba(245, 73, 0, 0.15);
  border: 1px solid rgba(245, 73, 0, 0.4);
  color: rgba(255, 255, 255, 0.9);
  font-size: 0.95em;
  text-align: center;
}

.cart-row {
  &.type-category {
    font-size: 1.2rem;
    font-weight: 600;
  }
  &.type-subCategory {
    font-size: 1.1rem;
    font-weight: 600;
  }
  &.type-item {
    font-size: 1rem;
  }
}
</style>
