import { useHorizontalSwipeDismiss } from './useHorizontalSwipeDismiss'

/** @deprecated Use useHorizontalSwipeDismiss */
export function usePhoneHeadsUpSwipeDismiss({ getBannerEl, onDismiss }) {
  const result = useHorizontalSwipeDismiss({
    getElementEl: getBannerEl,
    onDismiss,
  })
  return {
    ...result,
    bannerStyle: result.swipeStyle,
  }
}
