'use strict'

function rlsYankemEnsureStylesheet() {
  if (document.getElementById('rls-yankem-css')) return
  var link = document.createElement('link')
  link.id = 'rls-yankem-css'
  link.rel = 'stylesheet'
  link.type = 'text/css'
  link.href = '/ui/modModules/rlsYankem/rlsYankem.css?v=2'
  document.head.appendChild(link)
}

angular.module('beamng.stuff')
  .controller('RlsYankemController', ['$scope', '$rootScope', function ($scope, $rootScope) {
    var angularRootScope = window.globalAngularRootScope || $rootScope
    var state = { available: false, state: 'idle' }
    var reelingFromUi = false
    var dragState = null
    var panelStorageKey = 'rlsYankem.panelPosition.v1'

    $scope.visible = false
    $scope.state = state

    function safeApply(fn) {
      if ($scope.$$phase === '$apply' || $scope.$$phase === '$digest') fn()
      else $scope.$apply(fn)
    }

    function getApi() {
      if (typeof bngApi !== 'undefined' && bngApi && bngApi.engineLua) return bngApi
      if (window.bngApi && window.bngApi.engineLua) return window.bngApi
      return null
    }

    function engineCall(expression, callback) {
      var api = getApi()
      if (!api) return
      var lua = '(function() if not extensions.rlsYankem then extensions.load("rlsYankem") end; if extensions.rlsYankem then ' + expression + ' end end)()'
      api.engineLua(lua, callback)
    }

    function applyState(nextState) {
      if (!nextState || typeof nextState !== 'object') return
      var wasVisible = $scope.visible
      safeApply(function () {
        state = nextState
        $scope.state = state
        $scope.visible = state.available === true && state.state !== 'idle'
      })
      if (!wasVisible && $scope.visible) window.setTimeout(restorePanelPosition, 0)
    }

    function refreshState() {
      engineCall('return extensions.rlsYankem.getUiState()', applyState)
    }

    function getPanel() {
      return document.querySelector('#rls-yankem-container .rls-yankem-panel')
    }

    function clampPanelPosition(panel, left, top) {
      var margin = 8
      return {
        left: Math.min(Math.max(left, margin), Math.max(margin, window.innerWidth - panel.offsetWidth - margin)),
        top: Math.min(Math.max(top, margin), Math.max(margin, window.innerHeight - panel.offsetHeight - margin))
      }
    }

    function positionPanel(left, top, save) {
      var panel = getPanel()
      if (!panel) return
      var position = clampPanelPosition(panel, left, top)
      panel.style.left = position.left + 'px'
      panel.style.top = position.top + 'px'
      panel.style.right = 'auto'
      panel.style.bottom = 'auto'
      // bng-blur tracks size but deliberately does not observe position. Its
      // registered blur rectangle otherwise stays behind at the old location
      // after this absolutely-positioned panel is dragged.
      $scope.$broadcast('windowResize')
      if (save) {
        try { window.localStorage.setItem(panelStorageKey, JSON.stringify(position)) } catch (_error) {}
      }
    }

    function restorePanelPosition() {
      var panel = getPanel()
      if (!panel) return
      try {
        var stored = JSON.parse(window.localStorage.getItem(panelStorageKey) || 'null')
        if (stored && Number.isFinite(Number(stored.left)) && Number.isFinite(Number(stored.top))) {
          positionPanel(Number(stored.left), Number(stored.top), false)
        }
      } catch (_error) {}
    }

    $scope.startDrag = function ($event) {
      if (!$event || $event.button !== 0) return
      var panel = getPanel()
      if (!panel) return
      var rect = panel.getBoundingClientRect()
      dragState = {
        offsetX: $event.clientX - rect.left,
        offsetY: $event.clientY - rect.top
      }
      panel.classList.add('is-dragging')
      $event.preventDefault()
      $event.stopPropagation()
    }

    function documentMouseMove(event) {
      if (!dragState) return
      positionPanel(event.clientX - dragState.offsetX, event.clientY - dragState.offsetY, false)
      event.preventDefault()
      event.stopPropagation()
    }

    function finishDrag(event) {
      if (!dragState) return
      dragState = null
      var panel = getPanel()
      if (panel) {
        panel.classList.remove('is-dragging')
        var rect = panel.getBoundingClientRect()
        positionPanel(rect.left, rect.top, true)
      }
      if (event) event.stopPropagation()
    }

    function windowResize() {
      var panel = getPanel()
      if (!panel || !panel.style.left) return
      var rect = panel.getBoundingClientRect()
      positionPanel(rect.left, rect.top, true)
    }

    function stopReeling() {
      if (!reelingFromUi) return
      reelingFromUi = false
      engineCall('extensions.rlsYankem.setReelDirection(0)')
    }

    $scope.isSelecting = function () {
      return state.state === 'selectingFirst' || state.state === 'selectingSecond'
    }

    $scope.lengthText = function (value) {
      var number = Number(value)
      return Number.isFinite(number) ? number.toFixed(2) + ' m' : '--'
    }

    $scope.tensionText = function () {
      var tension = Number(state.tension) || 0
      if (tension < 1000) return Math.round(tension) + ' N'
      return (tension / 1000).toFixed(tension >= 100000 ? 0 : 1) + ' kN'
    }

    $scope.endpointText = function (endpoint) {
      if (!endpoint) return 'Not selected'
      return endpoint.vehicleName + ' — ' + endpoint.pointLabel
    }

    $scope.toggleWinch = function ($event) {
      if ($event) {
        $event.preventDefault()
        $event.stopPropagation()
      }
      stopReeling()
      engineCall('extensions.rlsYankem.toggleWinch()', refreshState)
    }

    $scope.startReel = function (direction, $event) {
      if ($event) {
        $event.preventDefault()
        $event.stopPropagation()
      }
      if (state.state !== 'connected' || state.ready !== true) return
      reelingFromUi = true
      engineCall('extensions.rlsYankem.setReelDirection(' + (direction < 0 ? '-1' : '1') + ')')
    }

    $scope.stopReel = function ($event) {
      if ($event) $event.stopPropagation()
      stopReeling()
    }

    var stateListener = angularRootScope.$on('RlsYankemState', function (_event, payload) {
      applyState(payload)
    })

    function documentMouseUp(event) {
      stopReeling()
      finishDrag(event)
    }
    function windowBlur(event) {
      stopReeling()
      finishDrag(event)
    }
    document.addEventListener('mousemove', documentMouseMove)
    document.addEventListener('mouseup', documentMouseUp)
    window.addEventListener('blur', windowBlur)
    window.addEventListener('resize', windowResize)

    $scope.$on('$destroy', function () {
      stopReeling()
      finishDrag()
      stateListener()
      document.removeEventListener('mousemove', documentMouseMove)
      document.removeEventListener('mouseup', documentMouseUp)
      window.removeEventListener('blur', windowBlur)
      window.removeEventListener('resize', windowResize)
    })

    window.setTimeout(refreshState, 250)
  }])

const rlsYankemModule = angular.module('rlsYankem', ['ui.router'])
  .run(function () {
    function initialize() {
      rlsYankemEnsureStylesheet()
      if (document.getElementById('rls-yankem-container')) return

      var angularRoot = document.getElementById('angular-root') || document.body
      var rootElement = angular.element(angularRoot)
      var injector = rootElement.injector()
      if (!injector) {
        window.setTimeout(initialize, 100)
        return
      }

      var $compile = injector.get('$compile')
      var $rootScope = injector.get('$rootScope')
      var container = angular.element(
        '<div id="rls-yankem-container" ng-controller="RlsYankemController" ng-include="\'/ui/modModules/rlsYankem/rlsYankem.html?v=2\'"></div>'
      )
      angular.element(document.body).append(container)
      $compile(container)($rootScope)
    }

    if (document.readyState === 'loading') {
      document.addEventListener('DOMContentLoaded', initialize, { once: true })
    } else {
      window.setTimeout(initialize, 300)
    }
  })

export default rlsYankemModule
