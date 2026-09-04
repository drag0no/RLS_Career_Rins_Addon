import { icons } from '@/common/components/base'

export default {
  id: 'dakar',
  name: 'Dakar',
  icon: icons.raceFlag || icons.road || icons.cars,
  route: '/career/phone-dakar',
  color: '#6f5a24',
  iconColor: '#ffffff',
  category: 'Events',
  storeTagline: 'Skeleton Coast rally',
  storeDescription: 'Track checkpoints, use repair kits, and manage your active Dakar run from your phone.',
  defaultPage: 0,
  defaultPosition: 4,
  unlockCondition: async luaBridge => {
    try {
      return !!(await luaBridge.overhaul_maps.hasOptionalFeature('dakar'))
    } catch {
      return false
    }
  },
  notifications: [
    {
      key: 'dakar.signedUp',
      label: 'Signed Up',
      default: true,
      description: 'Drive to the starting line',
      order: 0,
    },
    {
      key: 'dakar.checkpoint',
      label: 'Next Checkpoint',
      default: true,
      description: 'Clue and checkpoint updates',
      order: 1,
    },
  ],
}
