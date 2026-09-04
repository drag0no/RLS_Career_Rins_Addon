<template>
  <!--
    .39 boots Vue from ui-vue/dist, so mod App.vue overlays never mount.
    This host is mounted by mods/rls_career_overhaul/index.js into the live app context.
  -->
  <RacingTeamProxyOverlay />
  <RacingTeamProxyTeamLoading />
  <RlsCareerLoadingOverlay />
  <BetaCycleSplash />
  <RacingTeamMilestoneSplash />
  <SceneToastOverlay />
  <TravelJournalScenePrompt />
  <PhoneLockNotificationOverlay />
  <PhoneTutorialOverlay />
  <RoadsideRepairOverlay />
</template>

<script setup>
import RacingTeamProxyOverlay from "@/modules/career/components/RacingTeamProxyOverlay.vue"
import RacingTeamProxyTeamLoading from "@/modules/career/components/RacingTeamProxyTeamLoading.vue"
import RlsCareerLoadingOverlay from "@/modules/career/components/RlsCareerLoadingOverlay.vue"
import BetaCycleSplash from "@/modules/career/components/BetaCycleSplash.vue"
import RacingTeamMilestoneSplash from "@/modules/career/components/RacingTeamMilestoneSplash.vue"
import SceneToastOverlay from "@/modules/career/components/SceneToastOverlay.vue"
import TravelJournalScenePrompt from "@/modules/career/components/TravelJournalScenePrompt.vue"
import PhoneLockNotificationOverlay from "@/modules/career/components/PhoneLockNotificationOverlay.vue"
import PhoneTutorialOverlay from "@/modules/career/components/PhoneTutorialOverlay.vue"
import RoadsideRepairOverlay from "@/modules/career/components/RoadsideRepairOverlay.vue"
</script>
