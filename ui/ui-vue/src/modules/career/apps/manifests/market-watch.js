import { icons } from '@/common/components/base'

export default {
  id: 'market-watch',
  name: 'Market Watch',
  icon: icons.trendingUp || icons.chartLine || icons.analytics || icons.beamCurrency,
  iconTile: 'market-watch.png',
  route: '/career/phone-market-watch',
  color: '#3b82f6',
  iconColor: '#ffffff',
  category: 'Finance',
  defaultPage: 0,
  defaultPosition: 10,
  defaultDock: 3,
  systemApp: true,
  hideFromStore: true,
  // Single gate for surge alerts + marker opportunity ads (activityHeat: settings.notifications.jobMarket).
  notifications: [
    {
      key: 'jobMarket',
      label: 'Job Market',
      default: true,
      description: 'Alerts when jobs enter high demand, plus occasional opportunity ads at work markers',
      order: 0,
    },
  ],
}
