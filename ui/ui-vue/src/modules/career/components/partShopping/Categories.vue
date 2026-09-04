<template>
  <div class="mainCategories">
    <Button class="computer-function-tile"
      bng-scoped-nav-autofocus
      :disabled="partShoppingStore.partShoppingData?.tutorialPartNames !== undefined"
      @click="openCategory('everything')"
    >
      <BngIcon class="icon" :type="icons.doorFrontCoins" />
      <span class="label">{{ $translate.instant("ui.career.partShopping.allParts") }}</span>
    </Button>
    <Button class="computer-function-tile"
      @click="openCategory('cargo')"
    >
      <BngIcon class="icon" :type="icons.boxPickUp03" />
      <span class="label">{{ $translate.instant("ui.career.partShopping.cargoParts") }}</span>
    </Button>
  </div>
</template>

<script setup>
import { lua } from "@/bridge"
import { BngIcon, icons } from "@/common/components/base"
import { Button } from "@/common/components/utility"
import { usePartShoppingStore } from "../../stores/partShoppingStore"
import { $translate } from "@/services/translation"

const partShoppingStore = usePartShoppingStore()
defineProps({
  cancel: Function,
})

const openCategory = category =>
  lua.extensions.ui_router.navigate("career.computer.partShopping.category", { category })
</script>

<style scoped lang="scss">
@use "@/styles/modules/mixins" as *;
.mainCategories {
  display: flex;
  flex-direction: column;
  gap: 0.5em;
  padding: 1em;
}

.computer-function-tile {
  --bng-content-flow: row;
  --bng-content-align: center;
  --bng-content-justify: flex-start;
  --bng-button-min-width: 100%;
  --bng-button-max-width: 100%;
  --bng-button-margin: 0;
  --bng-button-padding: 0.5em;
  --bng-button-padding-top: 0.5em;
  --bng-button-padding-bottom: 0.5em;
  --bng-bg-border-radius: var(--bng-corners-1);
  --bng-bg-border-width: 1px;
  --bng-bg-enabled: rgba(0, 0, 0, 0.6);
  --bng-bg-hover: rgba(var(--bng-cool-gray-700-rgb), 0.8);
  --bng-bg-active: rgba(var(--bng-cool-gray-700-rgb), 0.8);
  --bng-bg-focus: rgba(var(--bng-cool-gray-700-rgb), 0.8);
  --bng-bg-disabled: rgba(0, 0, 0, 0.6);
  --bng-bg-enabled-opacity: 1;
  --bng-bg-hover-opacity: 1;
  --bng-bg-active-opacity: 1;
  --bng-bg-focus-opacity: 1;
  --bng-bg-disabled-opacity: 1;
  --bng-bg-border-enabled: rgba(255, 255, 255, 0.15);
  --bng-bg-border-hover: rgba(255, 255, 255, 0.15);
  --bng-bg-border-active: rgba(255, 255, 255, 0.15);
  --bng-bg-border-focus: var(--bng-cool-gray-300);
  --bng-bg-border-disabled: rgba(255, 255, 255, 0.15);

  gap: 0.5em;
  transition: background-color ease-in 75ms;
  @include modify-focus(var(--bng-corners-1), 0.25rem);

  .icon {
    font-size: 2.5em;
  }
  .label {
    flex: 1 1 auto;
    font-size: 1.3em;
    font-weight: 400;
    text-align: left;
  }
}
</style>
