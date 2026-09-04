import { icons } from '@/common/components/base'

export default {
  id: 'road-authority',
  name: 'Road Authority',
  icon: icons.road || icons.warning || icons.location || icons.cars,
  route: '/career/phone-road-authority',
  color: '#476b43',
  iconColor: '#ffffff',
  category: 'Tools',
  storeTagline: 'Cleanup reports',
  storeDescription: 'View Road Authority cleanup assignments and track debris clearances on Skeleton Coast.',
  defaultPage: 0,
  defaultPosition: 5,
  unlockCondition: async luaBridge => {
    try {
      return !!(await luaBridge.overhaul_maps.hasOptionalFeature('roadAuthority'))
    } catch {
      return false
    }
  },
  notifications: [
    {
      key: 'roadAuthority.newReport',
      label: 'New Report',
      default: true,
      description: 'Cleanup location assigned',
      order: 0,
    },
    {
      key: 'roadAuthority.reportsAvailable',
      label: 'Reports Available',
      default: true,
      description: 'Intro complete · reports live',
      order: 1,
    },
  ],
}
