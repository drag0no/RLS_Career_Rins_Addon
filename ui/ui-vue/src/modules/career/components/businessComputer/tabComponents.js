import BusinessHomeView from "./BusinessHomeView.vue"
import BusinessJobsTab from "./BusinessJobsTab.vue"
import BusinessKitsTab from "./BusinessKitsTab.vue"
import BusinessInventoryTab from "./BusinessInventoryTab.vue"
import BusinessPartsInventoryTab from "./BusinessPartsInventoryTab.vue"
import BusinessTuningTab from "./BusinessTuningTab.vue"
import BusinessPartsCustomizationTab from "./BusinessPartsCustomizationTab.vue"
import BusinessSkillTreeTab from "./BusinessSkillTreeTab.vue"
import BusinessTechsTab from "./BusinessTechsTab.vue"
import BusinessDriversTab from "./BusinessDriversTab.vue"
import BusinessFinancesTab from "./BusinessFinancesTab.vue"
import BusinessRacingTab from "./BusinessRacingTab.vue"
import BusinessVehiclesTab from "./BusinessVehiclesTab.vue"
import BusinessRacingTeamDevConsoleTab from "./BusinessRacingTeamDevConsoleTab.vue"

const componentMap = {
  BusinessHomeView,
  BusinessJobsTab,
  BusinessKitsTab,
  BusinessInventoryTab,
  BusinessPartsInventoryTab,
  BusinessTuningTab,
  BusinessPartsCustomizationTab,
  BusinessSkillTreeTab,
  BusinessTechsTab,
  BusinessDriversTab,
  BusinessFinancesTab,
  BusinessRacingTab,
  BusinessVehiclesTab,
  BusinessRacingTeamDevConsoleTab
}

export function getTabComponent(componentName) {
  return componentMap[componentName] || null
}

export default componentMap

