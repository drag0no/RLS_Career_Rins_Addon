import { icons } from '@/common/components/base'

export default {
  id: 'real-estate',
  name: 'Real Estate',
  icon: icons.doorFrontCoins,
  iconTile: 'real-estate.png',
  route: '/career/phone-real-estate',
  color: '#f97316',
  iconColor: '#ffffff',
  category: 'Property',
  storeTagline: 'Buy and sell property',
  storeDescription: 'Browse real estate listings, track owned properties, and handle deals on the move.',
  defaultPage: 0,
  defaultPosition: 9,
  notifications: [
    {
      key: 'realEstate.mortgageMissed',
      label: 'Mortgage Missed',
      default: true,
      description: 'Missed payment · rate increase',
      order: 0,
    },
    {
      key: 'realEstate.mortgageForeclosure',
      label: 'Foreclosure',
      default: true,
      description: 'Property repossessed',
      order: 1,
    },
    {
      key: 'realEstate.mortgagePaidOff',
      label: 'Mortgage Paid Off',
      default: true,
      description: 'Mortgage cleared',
      order: 2,
    },
    {
      key: 'realEstate.mortgageCreated',
      label: 'Mortgage Created',
      default: true,
      description: 'Financing approved',
      order: 3,
    },
    {
      key: 'realEstate.mortgagePrepayment',
      label: 'Mortgage Prepayment',
      default: true,
      description: 'Extra payment applied',
      order: 4,
    },
    {
      key: 'realEstate.newOffer',
      label: 'Property Offer',
      default: true,
      description: 'Buyer offers on your listings',
      order: 5,
    },
  ],
  unlockCondition: async (luaBridge) => {
    try {
      await luaBridge.extensions.load('ui_phone_layout')
      const fromLayout = await luaBridge.ui_phone_layout.getCareerActive()
      if (fromLayout) return true
    } catch { }
    try {
      return await luaBridge.career_career.isActive()
    } catch {
      return false
    }
  },
}
