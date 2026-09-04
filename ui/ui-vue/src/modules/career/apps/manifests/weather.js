import { icons } from '@/common/components/base'

export default {
  id: 'weather',
  name: 'Weather',
  icon: icons.weather,
  route: '/career/phone-weather',
  color: '#2563a9',
  iconColor: '#ffffff',
  category: 'Tools',
  storeTagline: 'Live conditions and forecast',
  storeDescription: 'Check current road and air conditions, hourly changes, the seven-day outlook, and weather preferences.',
  defaultPage: 0,
  defaultPosition: 12,
  notifications: [
    {
      key: 'weather.rainSoon',
      label: 'Rain Approaching',
      default: true,
      description: 'Warn one in-game hour before rain',
      order: 0,
    },
    {
      key: 'weather.stormSoon',
      label: 'Storm Approaching',
      default: true,
      description: 'Warn one in-game hour before a storm',
      order: 1,
    },
    {
      key: 'weather.fogSoon',
      label: 'Fog Forming',
      default: true,
      description: 'Warn one in-game hour before morning fog',
      order: 2,
    },
  ],
}
