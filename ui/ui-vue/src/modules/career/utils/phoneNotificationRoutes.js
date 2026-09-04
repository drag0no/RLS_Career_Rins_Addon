import { NOTIFICATION_CHANNEL_APP_IDS } from './phoneNotificationRegistry'
import { APP_MANIFESTS } from '../apps/manifests/index.js'

const APP_ROUTES_BY_ID = {}
for (const manifest of APP_MANIFESTS) {
  if (manifest?.id && manifest?.route) {
    APP_ROUTES_BY_ID[manifest.id] = manifest.route
  }
}

const SOURCE_APP_IDS = {
  'car meets': 'car-meet',
  'racing team': 'racing-team',
  'fre contracts': 'fre-contracts',
  'tuning shop': 'tuning-shop',
  loans: 'loans',
  marketplace: 'marketplace',
  'real estate': 'real-estate',
  rentals: 'rentals',
  beameats: 'beam-eats',
  'beam eats': 'beam-eats',
  logistics: 'logistics',
}

export function resolveNotificationAppId(payload) {
  if (!payload || typeof payload !== 'object') return null
  if (typeof payload.appId === 'string' && payload.appId) return payload.appId
  if (typeof payload.channelKey === 'string' && NOTIFICATION_CHANNEL_APP_IDS[payload.channelKey]) {
    return NOTIFICATION_CHANNEL_APP_IDS[payload.channelKey]
  }
  const source = String(payload.source || '').trim().toLowerCase()
  return SOURCE_APP_IDS[source] || null
}

export function resolveNotificationRoute(payload) {
  if (!payload || typeof payload !== 'object') return null
  if (typeof payload.route === 'string' && payload.route) return payload.route
  const appId = resolveNotificationAppId(payload)
  if (!appId) return null
  return APP_ROUTES_BY_ID[appId] || null
}
