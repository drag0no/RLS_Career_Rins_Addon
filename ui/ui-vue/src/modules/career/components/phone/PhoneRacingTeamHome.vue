<template>
  <div class="phone-home">
    <div class="phone-home__scheduled">
      <HomeScheduledRacesWidget compact @open-tab="$emit('navigate', 'races')" />
    </div>
    <div class="phone-home__sponsors">
      <HomeSponsorshipWidget compact />
    </div>
    <div class="phone-home__finances">
      <HomeFinancesWidget compact fill-height />
    </div>
  </div>
</template>

<script setup>
import HomeScheduledRacesWidget from "../businessComputer/widgets/HomeScheduledRacesWidget.vue"
import HomeSponsorshipWidget from "../businessComputer/widgets/HomeSponsorshipWidget.vue"
import HomeFinancesWidget from "../businessComputer/widgets/HomeFinancesWidget.vue"

defineEmits(["navigate"])
</script>

<style scoped lang="scss">
.phone-home {
  display: flex;
  flex-direction: column;
  align-items: stretch;
  height: 100%;
  min-height: 0;
  gap: 0.35em;
  padding-bottom: 0.7em;
  overflow: hidden;
  box-sizing: border-box;
}

.phone-home__scheduled,
.phone-home__sponsors {
  flex-shrink: 0;
  width: 100%;
  min-width: 0;
}

.phone-home__finances {
  flex: 1;
  min-height: 0;
  display: flex;
  flex-direction: column;
  width: 100%;
  min-width: 0;
  padding-bottom: 0.15em;
}

.phone-home__finances :deep(.home-widget) {
  flex: 1;
  min-height: 0;
}

.phone-home__finances :deep(.home-widget--fill .finance-summary) {
  padding-bottom: 0.5em;
}

.phone-home :deep(.home-widget--compact) {
  border-radius: 0.4em;
  text-align: left;

  .widget-header {
    padding: 0.35em 0.5em;
    justify-content: flex-start;
    gap: 0.45em;

    h3 {
      font-size: 0.78em;
    }

    .balance-badge,
    .count-badge {
      margin-left: auto;
    }
  }

  .widget-content {
    text-align: left;
  }

  .finance-summary .summary-item {
    align-items: flex-start;
  }

  .race-row,
  .sponsor-compact-row {
    border-radius: 0.25em;
    padding: 0.3em 0.4em;
  }

  .race-list {
    gap: 0.3em;
  }

  .widget-content.empty {
    align-items: flex-start;
    text-align: left;
  }

  .sponsor-body {
    align-items: flex-start;
  }

  .btn-schedule-pill {
    align-self: flex-start;
  }
}
</style>
