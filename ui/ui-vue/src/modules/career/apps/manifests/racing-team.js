import { icons } from '@/common/components/base'

export default {
  id: 'racing-team',
  name: 'Racing Team',
  icon: icons.cars,
  route: '/career/phone-racing-team',
  color: '#F54900',
  iconColor: '#ffffff',
  category: 'Business',
  storeTagline: 'Drivers, races, and sponsors',
  storeDescription: 'Manage your racing team from the road — schedule races, assign drivers, and get alerts when a team race is ready.',
  defaultPage: 0,
  defaultPosition: 9,
  showInStoreWhenLocked: true,
  notifications: [
    { key: 'racingTeam.raceReady', label: 'Race Ready', default: true, description: 'Scheduled team race ready' },
  ],
  unlockCondition: async (luaBridge) => {
    try {
      const isActive = await luaBridge.career_career.isActive()
      if (!isActive) return false
      await luaBridge.extensions.load('career_modules_business_businessManager')
      await luaBridge.extensions.load('career_modules_business_businessSkillTree')
      const purchased = await luaBridge.career_modules_business_businessManager.getPurchasedBusinesses('racingTeam')
      if (!purchased) return false
      for (const [id, owned] of Object.entries(purchased)) {
        if (!owned) continue
        const level = await luaBridge.career_modules_business_businessSkillTree.getNodeProgress(id, 'team-operations', 'shop-app')
        if (level && level > 0) return true
      }
      return false
    } catch {
      return false
    }
  },
}
