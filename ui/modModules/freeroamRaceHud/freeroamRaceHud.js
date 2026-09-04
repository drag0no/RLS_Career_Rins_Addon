'use strict'

angular.module('beamng.stuff')
.controller('FreeroamRaceHudController', ['$scope', '$rootScope', '$timeout', function($scope, $rootScope, $timeout) {
  const angularRootScope = window.globalAngularRootScope || $rootScope
  $scope.visible = false
  $scope.state = {}
  $scope.criticalWarningText = null

  var standingsPrevPlace = {}
  var standingsAnimTimeout = null

  function applyStandingsOvertakeAnimations(standings) {
    if (standingsAnimTimeout) {
      $timeout.cancel(standingsAnimTimeout)
      standingsAnimTimeout = null
    }
    if (!standings || !standings.length) {
      standingsPrevPlace = {}
      return
    }
    for (var i = 0; i < standings.length; i++) {
      var row = standings[i]
      var key = row.label
      var prev = standingsPrevPlace[key]
      if (prev != null && prev !== row.place) {
        row._stAnim = row.place < prev ? 'up' : 'down'
      } else {
        delete row._stAnim
      }
    }
    var nextPrev = {}
    for (var j = 0; j < standings.length; j++) {
      nextPrev[standings[j].label] = standings[j].place
    }
    standingsPrevPlace = nextPrev
    standingsAnimTimeout = $timeout(function() {
      standingsAnimTimeout = null
      var st = $scope.state && $scope.state.standings
      if (!st) return
      for (var k = 0; k < st.length; k++) {
        delete st[k]._stAnim
      }
    }, 520)
  }

  var DEFAULT_LAYOUT = { x: 12, y: 12, width: 340 }
  var hudLayout = { x: 12, y: 12, width: 340 }
  var drag = null
  var resize = null
  var blurNotifyScheduled = false

  function safeApply(fn) {
    const phase = $scope.$$phase
    if (phase === '$apply' || phase === '$digest') fn()
    else $scope.$apply(fn)
  }

  function clampLayout(l) {
    var vw = window.innerWidth, vh = window.innerHeight
    l.x = Math.max(0, Math.min(l.x, vw - 100))
    l.y = Math.max(0, Math.min(l.y, vh - 40))
    l.width = Math.max(240, Math.min(560, l.width))
    return l
  }

  function notifyGameBlur() {
    if (blurNotifyScheduled) return
    blurNotifyScheduled = true
    window.requestAnimationFrame(function() {
      blurNotifyScheduled = false
      angularRootScope.$broadcast('windowResize')
    })
  }

  function applyLayout() {
    var root = document.querySelector('.frh-overlay-root')
    if (!root) return
    root.style.left = hudLayout.x + 'px'
    root.style.top = hudLayout.y + 'px'
    var panel = root.querySelector('.frh-panel')
    if (panel) panel.style.width = hudLayout.width + 'px'
    notifyGameBlur()
  }

  function persistLayout() {
    if (typeof bngApi !== 'undefined') {
      bngApi.engineLua(
        "extensions.overhaul_settings.setSetting('freeroamRaceHudLayout', " +
        "{x = " + hudLayout.x + ", y = " + hudLayout.y + ", width = " + hudLayout.width + "})"
      )
    }
  }

  function loadLayout(cb) {
    if (typeof bngApi !== 'undefined') {
      bngApi.engineLua("extensions.overhaul_settings.getSetting('freeroamRaceHudLayout')", function(result) {
        if (result && typeof result === 'object') {
          hudLayout.x = result.x != null ? result.x : DEFAULT_LAYOUT.x
          hudLayout.y = result.y != null ? result.y : DEFAULT_LAYOUT.y
          hudLayout.width = result.width != null ? result.width : DEFAULT_LAYOUT.width
        }
        clampLayout(hudLayout)
        if (cb) cb()
      })
    } else {
      clampLayout(hudLayout)
      if (cb) cb()
    }
  }

  function onMouseDown(e) {
    if (!$scope.visible) return
    var header = e.target.closest('.frh-header')
    if (header && header.closest('.frh-overlay-root')) {
      drag = {
        startX: e.clientX, startY: e.clientY,
        origX: hudLayout.x, origY: hudLayout.y
      }
      document.body.style.userSelect = 'none'
      document.body.style.cursor = 'grabbing'
      e.preventDefault()
      return
    }
    var handle = e.target.closest('.frh-resize-handle')
    if (handle && handle.closest('.frh-overlay-root')) {
      resize = { startX: e.clientX, origWidth: hudLayout.width }
      document.body.style.userSelect = 'none'
      document.body.style.cursor = 'ew-resize'
      e.preventDefault()
    }
  }

  function onMouseMove(e) {
    if (drag) {
      hudLayout.x = Math.max(0, drag.origX + e.clientX - drag.startX)
      hudLayout.y = Math.max(0, drag.origY + e.clientY - drag.startY)
      applyLayout()
    } else if (resize) {
      hudLayout.width = Math.max(240, Math.min(560, resize.origWidth + e.clientX - resize.startX))
      applyLayout()
    }
  }

  function onMouseUp() {
    if (drag || resize) {
      document.body.style.userSelect = ''
      document.body.style.cursor = ''
      drag = null
      resize = null
      persistLayout()
    }
  }

  document.addEventListener('mousedown', onMouseDown, true)
  document.addEventListener('mousemove', onMouseMove, true)
  document.addEventListener('mouseup', onMouseUp, true)

  $scope.formatTime = function(seconds) {
    if (seconds == null || typeof seconds !== 'number' || !isFinite(seconds)) return '—'
    const sign = seconds < 0 ? '-' : ''
    seconds = Math.abs(seconds)
    const m = Math.floor(seconds / 60)
    const s = seconds % 60
    const whole = Math.floor(s)
    const cent = Math.floor((s - whole) * 100)
    return sign + (m < 10 ? '0' : '') + m + ':' + (whole < 10 ? '0' : '') + whole + '.' + (cent < 10 ? '0' : '') + cent
  }

  $scope.formatTimeWhole = function(seconds) {
    if (seconds == null || typeof seconds !== 'number' || !isFinite(seconds)) return '—'
    const sign = seconds < 0 ? '-' : ''
    seconds = Math.max(0, Math.floor(Math.abs(seconds)))
    const m = Math.floor(seconds / 60)
    const s = seconds % 60
    return sign + (m < 10 ? '0' : '') + m + ':' + (s < 10 ? '0' : '') + s
  }

  $scope.formatCountdownTime = function(seconds) {
    if (seconds == null || typeof seconds !== 'number' || !isFinite(seconds)) return '—'
    seconds = Math.max(0, Math.ceil(seconds))
    const m = Math.floor(seconds / 60)
    const s = seconds % 60
    return (m < 10 ? '0' : '') + m + ':' + (s < 10 ? '0' : '') + s
  }

  $scope.formatDelta = function(delta) {
    if (delta == null || typeof delta !== 'number' || !isFinite(delta)) return '—'
    const sign = delta > 0 ? '+' : (delta < 0 ? '' : '')
    return sign + delta.toFixed(2) + 's'
  }

  $scope.formatSectorValue = function(v, useScore) {
    if (v == null || typeof v !== 'number' || !isFinite(v)) return '—'
    if (useScore) return String(Math.round(v))
    return $scope.formatTime(v)
  }

  $scope.formatSectorDelta = function(delta, useScore) {
    if (delta == null || typeof delta !== 'number' || !isFinite(delta)) return '—'
    if (useScore) {
      const sign = delta > 0 ? '+' : (delta < 0 ? '' : '')
      return sign + Math.round(delta)
    }
    return $scope.formatDelta(delta)
  }

  $scope.deltaClass = function(delta, useScore) {
    if (delta == null || typeof delta !== 'number') return ''
    if (useScore) {
      if (delta > 0) return 'frh-delta-fast'
      if (delta < 0) return 'frh-delta-slow'
      return ''
    }
    if (delta < 0) return 'frh-delta-fast'
    if (delta > 0) return 'frh-delta-slow'
    return ''
  }

  $scope.formatMoney = function(n) {
    if (n == null || typeof n !== 'number' || !isFinite(n)) return '0'
    return (Math.round(n * 100) / 100).toFixed(2)
  }

  $scope.formatSpeedMph = function(n) {
    if (n == null || typeof n !== 'number' || !isFinite(n)) return '—'
    return n.toFixed(2) + ' mph'
  }

  $scope.formatStandingsGap = function(row) {
    if (!row || row.isPlayer) return '—'
    var g = row.gapSec
    if (g != null && typeof g === 'number' && isFinite(g)) {
      var sign = g > 0 ? '+' : ''
      return sign + g.toFixed(2) + 's'
    }
    return '—'
  }

  // Hide vanilla drag apps while FRE drag HUD is visible (do not touch mount/.run).
  // Covers topLeft dragInfo and topCenter tree staging (app id "drag").
  var DRAG_INFO_SUPPRESS_STYLE_ID = 'rls-frh-suppress-draginfo'
  function isDragRaceHud() {
    var s = $scope.state
    if (!s || typeof s !== 'object') return false
    if (s.isDragRace) return true
    return !!(s.completion && s.completion.kind === 'drag')
  }
  function setVanillaDragInfoSuppressed(suppressed) {
    var existing = document.getElementById(DRAG_INFO_SUPPRESS_STYLE_ID)
    if (!suppressed) {
      if (existing && existing.parentNode) existing.parentNode.removeChild(existing)
      return
    }
    if (existing) return
    var style = document.createElement('style')
    style.id = DRAG_INFO_SUPPRESS_STYLE_ID
    style.textContent = [
      '.ui-app-host[data-app-name="dragInfo"],',
      '.ui-app-host[data-app-name="drag"],',
      '.ui-app-host[data-app-name="dragDialControl"],',
      '.app-slot--drag-info { display: none !important; visibility: hidden !important; }'
    ].join('\n')
    document.head.appendChild(style)
  }
  function syncVanillaDragInfoSuppress() {
    setVanillaDragInfoSuppressed(!!$scope.visible && isDragRaceHud())
  }

  const showListener = angularRootScope.$on('FreeroamRaceHudShow', function() {
    loadLayout(function() {
      safeApply(function() {
        standingsPrevPlace = {}
        if (standingsAnimTimeout) {
          $timeout.cancel(standingsAnimTimeout)
          standingsAnimTimeout = null
        }
        $scope.visible = true
        $scope.state = {}
        $scope.criticalWarningText = null
        syncVanillaDragInfoSuppress()
      })
      $timeout(applyLayout, 0, false)
    })
  })

  const hideListener = angularRootScope.$on('FreeroamRaceHudHide', function() {
    safeApply(function() {
      standingsPrevPlace = {}
      if (standingsAnimTimeout) {
        $timeout.cancel(standingsAnimTimeout)
        standingsAnimTimeout = null
      }
      $scope.visible = false
      $scope.state = {}
      $scope.criticalWarningText = null
      syncVanillaDragInfoSuppress()
    })
    notifyGameBlur()
  })

  const criticalListener = angularRootScope.$on('FreeroamRaceHudCriticalWarning', function(_evt, data) {
    safeApply(function() {
      var t = data && data.text
      $scope.criticalWarningText = (t != null && String(t).length > 0) ? String(t) : null
    })
    $timeout(notifyGameBlur, 0, false)
  })

  const stateListener = angularRootScope.$on('FreeroamRaceHudState', function(_evt, data) {
    safeApply(function() {
      $scope.state = data && typeof data === 'object' ? data : {}
      var st = $scope.state.standings
      if (st && st.length) {
        applyStandingsOvertakeAnimations(st)
      } else {
        standingsPrevPlace = {}
        if (standingsAnimTimeout) {
          $timeout.cancel(standingsAnimTimeout)
          standingsAnimTimeout = null
        }
      }
      syncVanillaDragInfoSuppress()
    })
  })

  // ── Demo elimination toasts ──────────────────────────────
  $scope.demoToasts = []
  var toastIdCounter = 0
  var toastTimeouts = []

  const elimToastListener = angularRootScope.$on('DemoEliminationToast', function(_evt, data) {
    safeApply(function() {
      var id = ++toastIdCounter
      var toast = {
        id: id,
        label: data && data.label || 'Unknown',
        placementStr: data && data.placementStr || null,
        fading: false
      }
      $scope.demoToasts.push(toast)
      // Start fade at 2.5s
      toastTimeouts.push($timeout(function() {
        safeApply(function() { toast.fading = true })
      }, 2500))
      // Remove at 3.5s
      toastTimeouts.push($timeout(function() {
        safeApply(function() {
          var idx = $scope.demoToasts.indexOf(toast)
          if (idx !== -1) $scope.demoToasts.splice(idx, 1)
        })
      }, 3500))
    })
  })

  $scope.$on('$destroy', function() {
    if (standingsAnimTimeout) {
      $timeout.cancel(standingsAnimTimeout)
      standingsAnimTimeout = null
    }
    for (var i = 0; i < toastTimeouts.length; i++) {
      $timeout.cancel(toastTimeouts[i])
    }
    toastTimeouts = []
    setVanillaDragInfoSuppressed(false)
    showListener()
    hideListener()
    criticalListener()
    stateListener()
    elimToastListener()
    document.removeEventListener('mousedown', onMouseDown, true)
    document.removeEventListener('mousemove', onMouseMove, true)
    document.removeEventListener('mouseup', onMouseUp, true)
  })
}])

angular.module('beamng.stuff')
.controller('SanctionedParkingStagingController', ['$scope', '$rootScope', function($scope, $rootScope) {
  const angularRootScope = window.globalAngularRootScope || $rootScope
  $scope.spVisible = false
  $scope.payload = {}

  function safeApply(fn) {
    const phase = $scope.$$phase
    if (phase === '$apply' || phase === '$digest') fn()
    else $scope.$apply(fn)
  }

  $scope.formatRewardDollars = function(n) {
    if (n == null || (typeof n !== 'number' && typeof n !== 'string')) return '0'
    const v = Number(n)
    if (!isFinite(v)) return '0'
    return String(Math.floor(v))
  }

  $scope.stagingHeadline = function(p) {
    if (!p || typeof p !== 'object') return 'Sanctioned event'
    const laps = Math.max(1, Math.floor(Number(p.lapCount) || 1))
    const label = (p.raceLabel != null && String(p.raceLabel).trim() !== '') ? String(p.raceLabel).trim() : 'Track'
    return laps + '-Lap ' + label + ' Event'
  }

  $scope.stageAndSpawn = function() {
    if (typeof bngApi !== 'undefined') {
      bngApi.engineLua('gameplay_events_freeroam_competitiveTrackFlow.sanctionedParkingStageAndSpawn()')
    }
  }

  $scope.startEvent = function() {
    if (typeof bngApi !== 'undefined') {
      bngApi.engineLua('gameplay_events_freeroam_competitiveTrackFlow.sanctionedParkingStartEvent()')
    }
  }

  const spListener = angularRootScope.$on('SanctionedParkingStagingUi', function(_evt, data) {
    safeApply(function() {
      $scope.spVisible = !!(data && data.visible)
      $scope.payload = data && data.payload && typeof data.payload === 'object' ? data.payload : {}
    })
  })

  $scope.$on('$destroy', function() {
    spListener()
  })
}])

angular.module('beamng.stuff')
.controller('DemoStagingController', ['$scope', '$rootScope', function($scope, $rootScope) {
  const angularRootScope = window.globalAngularRootScope || $rootScope
  $scope.dmsVisible = false
  $scope.aiCount = 6
  $scope.aiOptions = []
  $scope.eventKey = ''
  $scope.eventLabel = 'Demolition Derby'
  $scope.startEnabled = true
  $scope.startDisabledReason = ''
  $scope.phase = 'configure'
  $scope.modeOptions = []
  $scope.selectedMode = 'loaner'
  $scope.entryFee = 0
  $scope.rewardPreview = 0
  $scope.repairCutPreview = 0
  $scope.netRewardPreview = 0
  $scope.winnerRepairInsuranceAvailable = false
  $scope.winnerRepairInsuranceSelected = false
  $scope.winnerRepairInsurancePercent = 50
  $scope.introTitle = ''
  $scope.introSubtitle = ''
  $scope.introBody = ''
  $scope.introFeatures = []
  $scope.introContinueLabel = 'Continue'
  $scope.intro = { dontShowAgain: false }

  function safeApply(fn) {
    const phase = $scope.$$phase
    if (phase === '$apply' || phase === '$digest') fn()
    else $scope.$apply(fn)
  }

  function computeEffectiveWinnerRepairInsurance() {
    return $scope.winnerRepairInsuranceSelected === true
      && $scope.winnerRepairInsuranceAvailable === true
      && $scope.selectedMode !== 'loaner'
  }

  $scope.setAiCount = function(n) {
    $scope.aiCount = n
    refreshSelectedModeSummary()
    requestModeAvailability()
  }

  $scope.setMode = function(modeKey) {
    $scope.selectedMode = modeKey
    if (modeKey === 'loaner') {
      $scope.winnerRepairInsuranceSelected = false
    }
    refreshSelectedModeSummary()
    requestModeAvailability()
  }

  $scope.toggleWinnerRepairInsurance = function() {
    $scope.winnerRepairInsuranceSelected = !$scope.winnerRepairInsuranceSelected
    refreshSelectedModeSummary()
    requestModeAvailability()
  }

  function requestModeAvailability() {
    if (typeof bngApi === 'undefined' || !$scope.dmsVisible || $scope.phase !== 'configure') {
      return
    }
    var aiCount = Math.max(1, Math.floor(Number($scope.aiCount) || 1))
    var modeKey = encodeLuaString($scope.selectedMode)
    var insuranceArg = computeEffectiveWinnerRepairInsurance() ? 'true' : 'false'
    bngApi.engineLua('gameplay_events_freeroam_demolitionDerby.refreshStagingAvailability(' + modeKey + ', ' + aiCount + ', ' + insuranceArg + ')')
  }

  function refreshSelectedModeSummary() {
    var options = Array.isArray($scope.modeOptions) ? $scope.modeOptions : []
    var selected = null
    for (var i = 0; i < options.length; i++) {
      if (options[i] && options[i].key === $scope.selectedMode) {
        selected = options[i]
        break
      }
    }
    if (!selected && options.length > 0) {
      selected = options[0]
      $scope.selectedMode = selected.key
    }
    $scope.entryFee = selected ? Math.max(0, Math.floor(Number(selected.entryFee) || 0)) : 0
    var grossPreview = selected ? Math.max(0, Math.floor(Number(selected.rewardPreview) || 0)) : 0
    if (grossPreview <= 0 && selected) {
      var basePreview = Math.max(0, Number(selected.rewardBase) || 0)
      var perAiPreview = Math.max(0, Number(selected.rewardPerAi) || 0)
      var aiCount = Math.max(1, Math.floor(Number($scope.aiCount) || 1))
      grossPreview = Math.max(0, Math.floor(basePreview + (perAiPreview * aiCount)))
    }
    $scope.rewardPreview = grossPreview
    var repairCut = 0
    if (computeEffectiveWinnerRepairInsurance()) {
      var pct = Math.max(0, Math.min(100, Number($scope.winnerRepairInsurancePercent) || 0))
      repairCut = Math.max(0, Math.floor((grossPreview * pct / 100) + 0.5))
    }
    $scope.repairCutPreview = repairCut
    $scope.netRewardPreview = Math.max(0, grossPreview - repairCut)
  }

  function encodeLuaString(value) {
    var str = value == null ? '' : String(value)
    str = str.replace(/[\\"\n\r\t\x00-\x1F\x7F]/g, function(ch) {
      if (ch === '\\') return '\\\\'
      if (ch === '"') return '\\"'
      if (ch === '\n') return '\\n'
      if (ch === '\r') return '\\r'
      if (ch === '\t') return '\\t'
      var code = ch.charCodeAt(0).toString(10)
      while (code.length < 3) code = '0' + code
      return '\\' + code
    })
    return '"' + str + '"'
  }

  $scope.startEvent = function() {
    if (!$scope.startEnabled) {
      return
    }
    if (typeof bngApi !== 'undefined') {
      var aiCount = Math.max(1, Math.floor(Number($scope.aiCount) || 1))
      var eventKey = encodeLuaString($scope.eventKey)
      var modeKey = encodeLuaString($scope.selectedMode)
      if ($scope.phase === 'ready') {
        bngApi.engineLua('gameplay_events_freeroam_demolitionDerby.beginCountdown()')
      } else {
        var insuranceArg = computeEffectiveWinnerRepairInsurance() ? 'true' : 'false'
        bngApi.engineLua('gameplay_events_freeroam_demolitionDerby.startEvent(' + aiCount + ', ' + eventKey + ', ' + modeKey + ', ' + insuranceArg + ')')
      }
    }
  }

  $scope.cancelStaging = function() {
    $scope.dmsVisible = false
    $scope.intro.dontShowAgain = false
    if (typeof bngApi !== 'undefined') {
      bngApi.engineLua('gameplay_events_freeroam_demolitionDerby.cancelStaging()')
    }
  }

  $scope.continueIntro = function() {
    if (typeof bngApi !== 'undefined') {
      var eventKey = encodeLuaString($scope.eventKey)
      if ($scope.intro.dontShowAgain && $scope.eventKey) {
        bngApi.engineLua('extensions.career_modules_guide.markDemoIntroSkipped(' + eventKey + ')')
      }
      bngApi.engineLua('gameplay_events_freeroam_demolitionDerby.dismissDemoIntro(false, ' + eventKey + ')')
    }
    $scope.intro.dontShowAgain = false
  }

  const dmsListener = angularRootScope.$on('DemoStagingUi', function(_evt, data) {
    safeApply(function() {
      $scope.dmsVisible = !!(data && data.visible)
      if (!data || !data.visible) {
        $scope.intro.dontShowAgain = false
        return
      }
      if (data && data.eventKey) {
        $scope.eventKey = data.eventKey
      }
      if (data && data.label) {
        $scope.eventLabel = data.label
      }
      if (data && data.phase) {
        $scope.phase = data.phase
      }
      if (data.introTitle) {
        $scope.introTitle = data.introTitle
      }
      if (data.introSubtitle) {
        $scope.introSubtitle = data.introSubtitle
      }
      if (data.introBody) {
        $scope.introBody = data.introBody
      }
      if (data && Array.isArray(data.introFeatures)) {
        $scope.introFeatures = data.introFeatures
      }
      if (data.introContinueLabel) {
        $scope.introContinueLabel = data.introContinueLabel
      }
      if (data && Array.isArray(data.modeOptions)) {
        $scope.modeOptions = data.modeOptions
      }
      if (data && data.selectedMode) {
        $scope.selectedMode = data.selectedMode
      }
      if (data && typeof data.winnerRepairInsuranceAvailable === 'boolean') {
        $scope.winnerRepairInsuranceAvailable = data.winnerRepairInsuranceAvailable
      }
      if (data && typeof data.winnerRepairInsuranceSelected === 'boolean') {
        $scope.winnerRepairInsuranceSelected = data.winnerRepairInsuranceSelected
      }
      if (data && typeof data.winnerRepairInsurancePercent === 'number') {
        $scope.winnerRepairInsurancePercent = Math.max(0, Math.min(100, Math.floor(data.winnerRepairInsurancePercent)))
      }
      if (data && typeof data.maxAi === 'number') {
        var maxAi = Math.max(0, Math.floor(data.maxAi))
        var opts = []
        for (var i = 1; i <= maxAi; i++) {
          opts.push(i)
        }
        $scope.aiOptions = opts
        var currentAiCount = Math.max(0, Math.floor(Number($scope.aiCount) || 0))
        $scope.aiCount = Math.min(currentAiCount, maxAi)
      }
      if (data && typeof data.aiCount === 'number') {
        $scope.aiCount = Math.max(0, Math.floor(data.aiCount))
      }
      var hasNoAiSlots = data && typeof data.maxAi === 'number' && Math.floor(data.maxAi) <= 0
      $scope.startEnabled = !(data && data.startEnabled === false) && !hasNoAiSlots
      if (hasNoAiSlots && !(data && data.startDisabledReason)) {
        $scope.startDisabledReason = 'No parking spots available for AI opponents.'
      } else {
        $scope.startDisabledReason = data && data.startDisabledReason ? String(data.startDisabledReason) : ''
      }
      refreshSelectedModeSummary()
    })
  })

  $scope.$on('$destroy', function() {
    dmsListener()
  })
}])

angular.module('beamng.stuff')
.controller('DemoCongratulationsController', ['$scope', '$rootScope', function($scope, $rootScope) {
  const angularRootScope = window.globalAngularRootScope || $rootScope
  $scope.dmcVisible = false
  $scope.payload = {}

  function safeApply(fn) {
    const phase = $scope.$$phase
    if (phase === '$apply' || phase === '$digest') fn()
    else $scope.$apply(fn)
  }

  $scope.dismiss = function() {
    if (typeof bngApi !== 'undefined') {
      bngApi.engineLua('gameplay_events_freeroam_demolitionDerby.dismissCongratulations()')
    }
  }

  const dmcListener = angularRootScope.$on('DemoCongratulationsUi', function(_evt, data) {
    safeApply(function() {
      $scope.dmcVisible = !!(data && data.visible)
      $scope.payload = data && typeof data === 'object' ? data : {}
    })
  })

  $scope.$on('$destroy', function() {
    dmcListener()
  })
}])

angular.module('beamng.stuff')
.controller('DakarCompassController', ['$scope', '$rootScope', function($scope, $rootScope) {
  const angularRootScope = window.globalAngularRootScope || $rootScope
  $scope.visible = false
  $scope.payload = {}
  var DEFAULT_LAYOUT = { x: 24, y: 120, width: 180 }
  var layout = { x: DEFAULT_LAYOUT.x, y: DEFAULT_LAYOUT.y, width: DEFAULT_LAYOUT.width }
  var drag = null
  var layoutLoaded = false

  function safeApply(fn) {
    const phase = $scope.$$phase
    if (phase === '$apply' || phase === '$digest') fn()
    else $scope.$apply(fn)
  }

  function clampLayout() {
    layout.x = Math.max(8, Math.min(layout.x, window.innerWidth - 120))
    layout.y = Math.max(8, Math.min(layout.y, window.innerHeight - 80))
    layout.width = Math.max(150, Math.min(layout.width, 240))
  }

  function persistLayout() {
    if (typeof bngApi !== 'undefined') {
      bngApi.engineLua(
        "extensions.overhaul_settings.setSetting('dakarCompassLayout', " +
        "{x = " + layout.x + ", y = " + layout.y + ", width = " + layout.width + "})"
      )
    }
  }

  function loadLayout(cb) {
    if (layoutLoaded) {
      if (cb) cb()
      return
    }
    if (typeof bngApi !== 'undefined') {
      bngApi.engineLua("extensions.overhaul_settings.getSetting('dakarCompassLayout')", function(result) {
        if (result && typeof result === 'object') {
          layout.x = result.x != null ? result.x : DEFAULT_LAYOUT.x
          layout.y = result.y != null ? result.y : DEFAULT_LAYOUT.y
          layout.width = result.width != null ? result.width : DEFAULT_LAYOUT.width
        }
        clampLayout()
        layoutLoaded = true
        if (cb) cb()
      })
    } else {
      clampLayout()
      layoutLoaded = true
      if (cb) cb()
    }
  }

  $scope.cardStyle = function() {
    clampLayout()
    return { left: layout.x + 'px', top: layout.y + 'px', width: layout.width + 'px' }
  }

  $scope.needleStyle = function() {
    var degrees = Number($scope.payload.vehicleHeadingDegrees)
    if (!isFinite(degrees)) degrees = 0
    return { transform: 'rotate(' + degrees + 'deg)' }
  }

  $scope.startDrag = function(e) {
    if (!e) return
    drag = { startX: e.clientX, startY: e.clientY, origX: layout.x, origY: layout.y }
    document.body.style.userSelect = 'none'
    document.body.style.cursor = 'grabbing'
    e.preventDefault()
  }

  function onMouseMove(e) {
    if (!drag) return
    safeApply(function() {
      layout.x = drag.origX + e.clientX - drag.startX
      layout.y = drag.origY + e.clientY - drag.startY
      clampLayout()
    })
  }

  function onMouseUp() {
    if (!drag) return
    drag = null
    document.body.style.userSelect = ''
    document.body.style.cursor = ''
    persistLayout()
  }

  document.addEventListener('mousemove', onMouseMove, true)
  document.addEventListener('mouseup', onMouseUp, true)

  const listener = angularRootScope.$on('DakarCompassUi', function(_evt, data) {
    loadLayout(function() {
      safeApply(function() {
        $scope.visible = !!(data && data.visible)
        $scope.payload = data && data.payload && typeof data.payload === 'object' ? data.payload : {}
      })
    })
  })

  $scope.$on('$destroy', function() {
    listener()
    document.removeEventListener('mousemove', onMouseMove, true)
    document.removeEventListener('mouseup', onMouseUp, true)
  })
}])

angular.module('beamng.stuff')
.controller('DakarStartController', ['$scope', '$rootScope', function($scope, $rootScope) {
  const angularRootScope = window.globalAngularRootScope || $rootScope
  $scope.visible = false
  $scope.payload = {}
  var layout = { x: null, y: null, width: 380 }
  var drag = null

  function safeApply(fn) {
    const phase = $scope.$$phase
    if (phase === '$apply' || phase === '$digest') fn()
    else $scope.$apply(fn)
  }

  function centerLayout() {
    layout.width = 380
    layout.x = Math.max(16, Math.floor((window.innerWidth - layout.width) / 2))
    layout.y = Math.max(16, Math.floor((window.innerHeight - 220) / 2))
  }

  function clampLayout() {
    layout.x = Math.max(8, Math.min(layout.x, window.innerWidth - 120))
    layout.y = Math.max(8, Math.min(layout.y, window.innerHeight - 80))
  }

  $scope.cardStyle = function() {
    if (layout.x == null || layout.y == null) centerLayout()
    return { left: layout.x + 'px', top: layout.y + 'px', width: layout.width + 'px' }
  }

  $scope.startDrag = function(e) {
    if (!e || e.target.closest('button')) return
    drag = { startX: e.clientX, startY: e.clientY, origX: layout.x, origY: layout.y }
    document.body.style.userSelect = 'none'
    document.body.style.cursor = 'grabbing'
    e.preventDefault()
  }

  function onMouseMove(e) {
    if (!drag) return
    safeApply(function() {
      layout.x = drag.origX + e.clientX - drag.startX
      layout.y = drag.origY + e.clientY - drag.startY
      clampLayout()
    })
  }

  function onMouseUp() {
    if (!drag) return
    drag = null
    document.body.style.userSelect = ''
    document.body.style.cursor = ''
  }

  document.addEventListener('mousemove', onMouseMove, true)
  document.addEventListener('mouseup', onMouseUp, true)

  $scope.startEvent = function() {
    if (typeof bngApi !== 'undefined') {
      bngApi.engineLua("local name = overhaul_maps and overhaul_maps.getOptionalFeatureExtension and overhaul_maps.getOptionalFeatureExtension('dakar'); local feature = name and extensions[name]; if feature and feature.startEvent then feature.startEvent() end")
    }
  }

  $scope.close = function() {
    $scope.visible = false
    if (typeof bngApi !== 'undefined') {
      bngApi.engineLua("local name = overhaul_maps and overhaul_maps.getOptionalFeatureExtension and overhaul_maps.getOptionalFeatureExtension('dakar'); local feature = name and extensions[name]; if feature and feature.closeStartPrompt then feature.closeStartPrompt() end")
    }
  }

  const listener = angularRootScope.$on('DakarStartUi', function(_evt, data) {
    safeApply(function() {
      $scope.visible = !!(data && data.visible)
      $scope.payload = data && data.payload && typeof data.payload === 'object' ? data.payload : {}
      if ($scope.visible && (layout.x == null || layout.y == null)) centerLayout()
    })
  })

  $scope.$on('$destroy', function() {
    listener()
    document.removeEventListener('mousemove', onMouseMove, true)
    document.removeEventListener('mouseup', onMouseUp, true)
  })
}])

angular.module('beamng.stuff')
.controller('RoadAuthorityIntroController', ['$scope', '$rootScope', function($scope, $rootScope) {
  const angularRootScope = window.globalAngularRootScope || $rootScope
  $scope.visible = false
  $scope.payload = {}
  var layout = { x: null, y: null, width: 760 }
  var drag = null

  function safeApply(fn) {
    const phase = $scope.$$phase
    if (phase === '$apply' || phase === '$digest') fn()
    else $scope.$apply(fn)
  }

  function centerLayout() {
    layout.width = Math.min(760, window.innerWidth - 48)
    layout.x = Math.max(16, Math.floor((window.innerWidth - layout.width) / 2))
    layout.y = Math.max(16, Math.floor((window.innerHeight - 560) / 2))
  }

  function clampLayout() {
    layout.x = Math.max(8, Math.min(layout.x, window.innerWidth - 120))
    layout.y = Math.max(8, Math.min(layout.y, window.innerHeight - 80))
  }

  $scope.cardStyle = function() {
    if (layout.x == null || layout.y == null) centerLayout()
    return { left: layout.x + 'px', top: layout.y + 'px', width: layout.width + 'px' }
  }

  $scope.startDrag = function(e) {
    if (!e || e.target.closest('button')) return
    drag = { startX: e.clientX, startY: e.clientY, origX: layout.x, origY: layout.y }
    document.body.style.userSelect = 'none'
    document.body.style.cursor = 'grabbing'
    e.preventDefault()
  }

  function onMouseMove(e) {
    if (!drag) return
    safeApply(function() {
      layout.x = drag.origX + e.clientX - drag.startX
      layout.y = drag.origY + e.clientY - drag.startY
      clampLayout()
    })
  }

  function onMouseUp() {
    if (!drag) return
    drag = null
    document.body.style.userSelect = ''
    document.body.style.cursor = ''
  }

  document.addEventListener('mousemove', onMouseMove, true)
  document.addEventListener('mouseup', onMouseUp, true)

  $scope.dismiss = function() {
    $scope.visible = false
    if (typeof bngApi !== 'undefined') {
      bngApi.engineLua('if skeletonCoast_roadAuthority and skeletonCoast_roadAuthority.dismissIntro then skeletonCoast_roadAuthority.dismissIntro() end')
    }
  }

  const listener = angularRootScope.$on('RoadAuthorityIntroUi', function(_evt, data) {
    safeApply(function() {
      $scope.visible = !!(data && data.visible)
      $scope.payload = data && data.payload && typeof data.payload === 'object' ? data.payload : {}
      if ($scope.visible && (layout.x == null || layout.y == null)) centerLayout()
    })
  })

  $scope.$on('$destroy', function() {
    listener()
    document.removeEventListener('mousemove', onMouseMove, true)
    document.removeEventListener('mouseup', onMouseUp, true)
  })
}])

angular.module('beamng.stuff')
.controller('RoadAuthorityClearController', ['$scope', '$rootScope', function($scope, $rootScope) {
  const angularRootScope = window.globalAngularRootScope || $rootScope
  $scope.visible = false
  $scope.payload = {}
  var layout = { x: null, y: null, width: 380 }
  var drag = null

  function safeApply(fn) {
    const phase = $scope.$$phase
    if (phase === '$apply' || phase === '$digest') fn()
    else $scope.$apply(fn)
  }

  function centerLayout() {
    layout.width = 380
    layout.x = Math.max(16, Math.floor((window.innerWidth - layout.width) / 2))
    layout.y = Math.max(16, Math.floor((window.innerHeight - 190) / 2))
  }

  function clampLayout() {
    layout.x = Math.max(8, Math.min(layout.x, window.innerWidth - 120))
    layout.y = Math.max(8, Math.min(layout.y, window.innerHeight - 80))
  }

  $scope.cardStyle = function() {
    if (layout.x == null || layout.y == null) centerLayout()
    return { left: layout.x + 'px', top: layout.y + 'px', width: layout.width + 'px' }
  }

  $scope.startDrag = function(e) {
    if (!e || e.target.closest('button')) return
    drag = { startX: e.clientX, startY: e.clientY, origX: layout.x, origY: layout.y }
    document.body.style.userSelect = 'none'
    document.body.style.cursor = 'grabbing'
    e.preventDefault()
  }

  function onMouseMove(e) {
    if (!drag) return
    safeApply(function() {
      layout.x = drag.origX + e.clientX - drag.startX
      layout.y = drag.origY + e.clientY - drag.startY
      clampLayout()
    })
  }

  function onMouseUp() {
    if (!drag) return
    drag = null
    document.body.style.userSelect = ''
    document.body.style.cursor = ''
  }

  document.addEventListener('mousemove', onMouseMove, true)
  document.addEventListener('mouseup', onMouseUp, true)

  $scope.clearDebris = function() {
    if (typeof bngApi !== 'undefined' && $scope.payload.reportId) {
      bngApi.engineLua('if skeletonCoast_roadAuthority and skeletonCoast_roadAuthority.clearReport then skeletonCoast_roadAuthority.clearReport(' + JSON.stringify($scope.payload.reportId) + ') end')
    }
  }

  $scope.close = function() {
    $scope.visible = false
    if (typeof bngApi !== 'undefined') {
      bngApi.engineLua('if skeletonCoast_roadAuthority and skeletonCoast_roadAuthority.closeClearPrompt then skeletonCoast_roadAuthority.closeClearPrompt() end')
    }
  }

  const listener = angularRootScope.$on('RoadAuthorityClearUi', function(_evt, data) {
    safeApply(function() {
      $scope.visible = !!(data && data.visible)
      $scope.payload = data && data.payload && typeof data.payload === 'object' ? data.payload : {}
      if ($scope.visible && (layout.x == null || layout.y == null)) centerLayout()
    })
  })

  $scope.$on('$destroy', function() {
    listener()
    document.removeEventListener('mousemove', onMouseMove, true)
    document.removeEventListener('mouseup', onMouseUp, true)
  })
}])

angular.module('beamng.stuff')
.controller('DakarFinishController', ['$scope', '$rootScope', function($scope, $rootScope) {
  const angularRootScope = window.globalAngularRootScope || $rootScope
  $scope.visible = false
  $scope.payload = {}
  var layout = { x: null, y: null, width: 420 }
  var drag = null
  var hudDefaulted = false

  function safeApply(fn) {
    const phase = $scope.$$phase
    if (phase === '$apply' || phase === '$digest') fn()
    else $scope.$apply(fn)
  }

  function centerLayout() {
    layout.width = 420
    layout.x = Math.max(16, Math.floor((window.innerWidth - layout.width) / 2))
    layout.y = Math.max(16, Math.floor((window.innerHeight - 500) / 2))
  }

  function clampLayout() {
    layout.x = Math.max(8, Math.min(layout.x, window.innerWidth - 120))
    layout.y = Math.max(8, Math.min(layout.y, window.innerHeight - 80))
  }

  $scope.cardStyle = function() {
    if (layout.x == null || layout.y == null) centerLayout()
    return { left: layout.x + 'px', top: layout.y + 'px', width: layout.width + 'px' }
  }

  $scope.startDrag = function(e) {
    if (!e || e.target.closest('button')) return
    drag = { startX: e.clientX, startY: e.clientY, origX: layout.x, origY: layout.y }
    document.body.style.userSelect = 'none'
    document.body.style.cursor = 'grabbing'
    e.preventDefault()
  }

  function onMouseMove(e) {
    if (!drag) return
    safeApply(function() {
      layout.x = drag.origX + e.clientX - drag.startX
      layout.y = drag.origY + e.clientY - drag.startY
      clampLayout()
    })
  }

  function onMouseUp() {
    if (!drag) return
    drag = null
    document.body.style.userSelect = ''
    document.body.style.cursor = ''
  }

  document.addEventListener('mousemove', onMouseMove, true)
  document.addEventListener('mouseup', onMouseUp, true)

  $scope.dismiss = function() {
    $scope.visible = false
    if (typeof bngApi !== 'undefined') {
      bngApi.engineLua("local name = overhaul_maps and overhaul_maps.getOptionalFeatureExtension and overhaul_maps.getOptionalFeatureExtension('dakar'); local feature = name and extensions[name]; if feature and feature.dismissFinish then feature.dismissFinish() end")
    }
  }

  $scope.seconds = function(value) {
    var s = Math.max(0, Math.floor(Number(value) || 0))
    return Math.floor(s / 60) + ':' + String(s % 60).padStart(2, '0')
  }

  $scope.money = function(value) {
    var n = Math.max(0, Math.floor(Number(value) || 0))
    return '$' + n.toLocaleString()
  }

  const listener = angularRootScope.$on('DakarFinishUi', function(_evt, data) {
    safeApply(function() {
      $scope.visible = !!(data && data.visible)
      $scope.payload = data && data.payload && typeof data.payload === 'object' ? data.payload : {}
      if ($scope.visible && (layout.x == null || layout.y == null)) centerLayout()
    })
  })

  $scope.$on('$destroy', function() {
    listener()
    document.removeEventListener('mousemove', onMouseMove, true)
    document.removeEventListener('mouseup', onMouseUp, true)
  })
}])

angular.module('beamng.stuff')
.controller('CareerFastTravelController', ['$scope', '$rootScope', function($scope, $rootScope) {
  const angularRootScope = window.globalAngularRootScope || $rootScope
  $scope.visible = false
  $scope.payload = {}
  var layout = { x: null, y: null, width: 430 }
  var drag = null

  function safeApply(fn) {
    const phase = $scope.$$phase
    if (phase === '$apply' || phase === '$digest') fn()
    else $scope.$apply(fn)
  }

  function centerLayout() {
    layout.width = Math.min(430, window.innerWidth - 48)
    layout.x = Math.max(16, Math.floor((window.innerWidth - layout.width) / 2))
    layout.y = Math.max(16, Math.floor((window.innerHeight - 300) / 2))
  }

  function clampLayout() {
    layout.x = Math.max(8, Math.min(layout.x, window.innerWidth - 120))
    layout.y = Math.max(8, Math.min(layout.y, window.innerHeight - 80))
  }

  $scope.cardStyle = function() {
    if (layout.x == null || layout.y == null) centerLayout()
    return { left: layout.x + 'px', top: layout.y + 'px', width: layout.width + 'px' }
  }

  $scope.startDrag = function(e) {
    if (!e || e.target.closest('button')) return
    drag = { startX: e.clientX, startY: e.clientY, origX: layout.x, origY: layout.y }
    document.body.style.userSelect = 'none'
    document.body.style.cursor = 'grabbing'
    e.preventDefault()
  }

  function onMouseMove(e) {
    if (!drag) return
    safeApply(function() {
      layout.x = drag.origX + e.clientX - drag.startX
      layout.y = drag.origY + e.clientY - drag.startY
      clampLayout()
    })
  }

  function onMouseUp() {
    if (!drag) return
    drag = null
    document.body.style.userSelect = ''
    document.body.style.cursor = ''
  }

  document.addEventListener('mousemove', onMouseMove, true)
  document.addEventListener('mouseup', onMouseUp, true)

  function encodeLuaString(value) {
    var str = value == null ? '' : String(value)
    str = str.replace(/[\\"\n\r\t\x00-\x1F\x7F]/g, function(ch) {
      if (ch === '\\') return '\\\\'
      if (ch === '"') return '\\"'
      if (ch === '\n') return '\\n'
      if (ch === '\r') return '\\r'
      if (ch === '\t') return '\\t'
      var code = ch.charCodeAt(0).toString(10)
      while (code.length < 3) code = '0' + code
      return '\\' + code
    })
    return '"' + str + '"'
  }

  $scope.money = function(value) {
    var n = Number(value)
    if (!isFinite(n)) n = 0
    return '$' + (Math.round(n * 100) / 100).toLocaleString(undefined, {
      minimumFractionDigits: n % 1 === 0 ? 0 : 2,
      maximumFractionDigits: 2
    })
  }

  $scope.travelTo = function(destination) {
    if (!destination || !destination.id || destination.canPay === false) return
    if (typeof bngApi !== 'undefined') {
      bngApi.engineLua('if career_modules_fastTravel and career_modules_fastTravel.travelTo then career_modules_fastTravel.travelTo(' + encodeLuaString(destination.id) + ') end')
    }
  }

  $scope.close = function() {
    $scope.visible = false
    if (typeof bngApi !== 'undefined') {
      bngApi.engineLua('if career_modules_fastTravel and career_modules_fastTravel.closeTravelMenu then career_modules_fastTravel.closeTravelMenu() end')
    }
  }

  const listener = angularRootScope.$on('CareerFastTravelUi', function(_evt, data) {
    safeApply(function() {
      $scope.visible = !!(data && data.visible)
      $scope.payload = data && data.payload && typeof data.payload === 'object' ? data.payload : {}
      if ($scope.visible && (layout.x == null || layout.y == null)) centerLayout()
    })
  })

  $scope.$on('$destroy', function() {
    listener()
    document.removeEventListener('mousemove', onMouseMove, true)
    document.removeEventListener('mouseup', onMouseUp, true)
  })
}])

angular.module('beamng.stuff')
.controller('MiningHaulController', ['$scope', '$rootScope', function($scope, $rootScope) {
  const angularRootScope = window.globalAngularRootScope || $rootScope
  $scope.visible = false
  $scope.payload = {}
  var layout = { x: null, y: null, width: 420 }
  var drag = null
  var hudDefaulted = false
  var hasSavedLayout = false
  var layoutStorageKey = 'rlsMiningHaulLayout'

  function safeApply(fn) {
    const phase = $scope.$$phase
    if (phase === '$apply' || phase === '$digest') fn()
    else $scope.$apply(fn)
  }

  function restoreLayout() {
    try {
      if (!window.localStorage) return false
      var saved = JSON.parse(window.localStorage.getItem(layoutStorageKey) || 'null')
      if (!saved || !isFinite(saved.x) || !isFinite(saved.y)) return false
      layout.x = Number(saved.x)
      layout.y = Number(saved.y)
      layout.width = Math.max(260, Math.min(Number(saved.width) || 340, window.innerWidth - 32))
      clampLayout()
      return true
    } catch (_err) {
      return false
    }
  }

  function saveLayout() {
    try {
      if (!window.localStorage || layout.x == null || layout.y == null) return
      window.localStorage.setItem(layoutStorageKey, JSON.stringify({
        x: Math.round(layout.x),
        y: Math.round(layout.y),
        width: Math.round(layout.width || 340)
      }))
      hasSavedLayout = true
    } catch (_err) {}
  }

  function centerLayout() {
    layout.width = Math.min(420, window.innerWidth - 48)
    layout.x = Math.max(16, Math.floor((window.innerWidth - layout.width) / 2))
    layout.y = Math.max(16, Math.floor((window.innerHeight - 340) / 2))
  }

  function hudLayout() {
    layout.width = Math.min(340, window.innerWidth - 32)
    layout.x = 16
    layout.y = Math.max(74, Math.min(118, window.innerHeight - 220))
  }

  function clampLayout() {
    layout.x = Math.max(8, Math.min(layout.x, window.innerWidth - 120))
    layout.y = Math.max(8, Math.min(layout.y, window.innerHeight - 80))
  }

  hasSavedLayout = restoreLayout()

  function luaCall(code) {
    if (typeof bngApi !== 'undefined') bngApi.engineLua(code)
  }

  $scope.cardStyle = function() {
    if (layout.x == null || layout.y == null) centerLayout()
    return { left: layout.x + 'px', top: layout.y + 'px', width: layout.width + 'px' }
  }

  $scope.startDrag = function(e) {
    if (!e || e.target.closest('button')) return
    drag = { startX: e.clientX, startY: e.clientY, origX: layout.x, origY: layout.y }
    document.body.style.userSelect = 'none'
    document.body.style.cursor = 'grabbing'
    e.preventDefault()
  }

  function onMouseMove(e) {
    if (!drag) return
    safeApply(function() {
      layout.x = drag.origX + e.clientX - drag.startX
      layout.y = drag.origY + e.clientY - drag.startY
      clampLayout()
    })
  }

  function onMouseUp() {
    if (!drag) return
    drag = null
    document.body.style.userSelect = ''
    document.body.style.cursor = ''
    saveLayout()
  }

  document.addEventListener('mousemove', onMouseMove, true)
  document.addEventListener('mouseup', onMouseUp, true)

  $scope.money = function(value) {
    var n = Math.max(0, Math.floor(Number(value) || 0))
    return '$' + n.toLocaleString()
  }

  $scope.startShift = function() { luaCall('if gameplay_miningHaul and gameplay_miningHaul.startShift then gameplay_miningHaul.startShift() end') }
  $scope.loadTruck = function() { luaCall('if gameplay_miningHaul and gameplay_miningHaul.loadTruck then gameplay_miningHaul.loadTruck() end') }
  $scope.processOre = function() { luaCall('if gameplay_miningHaul and gameplay_miningHaul.processOre then gameplay_miningHaul.processOre() end') }
  $scope.repairTruck = function() { luaCall('if gameplay_miningHaul and gameplay_miningHaul.repairTruck then gameplay_miningHaul.repairTruck() end') }
  $scope.endShift = function() { luaCall('if gameplay_miningHaul and gameplay_miningHaul.endShift then gameplay_miningHaul.endShift() end') }
  $scope.close = function() {
    $scope.visible = false
    luaCall('if gameplay_miningHaul and gameplay_miningHaul.closeUi then gameplay_miningHaul.closeUi() end')
  }

  const listener = angularRootScope.$on('MiningHaulUi', function(_evt, data) {
    safeApply(function() {
      $scope.visible = !!(data && data.visible)
      $scope.payload = data && typeof data === 'object' ? data : {}
      if ($scope.visible && $scope.payload.mode === 'hud' && !hudDefaulted) {
        if (hasSavedLayout) clampLayout()
        else hudLayout()
        hudDefaulted = true
      }
      else if ($scope.visible && (layout.x == null || layout.y == null)) centerLayout()
    })
  })

  $scope.$on('$destroy', function() {
    listener()
    document.removeEventListener('mousemove', onMouseMove, true)
    document.removeEventListener('mouseup', onMouseUp, true)
  })
}])

const freeroamRaceHudModule = angular.module('freeroamRaceHud', ['ui.router'])
.run(function() {
  function initializeFreeroamRaceHudOverlay() {
    const bodyElement = angular.element(document.body)
    const angularRoot = document.getElementById('angular-root')
    const injector = angularRoot && angular.element(angularRoot).injector()
    if (!injector) {
      window.setTimeout(initializeFreeroamRaceHudOverlay, 100)
      return
    }

    const $compile = injector.get('$compile')
    const $rootScope = injector.get('$rootScope')
    if (!document.getElementById('freeroam-race-hud-overlay-container')) {
      const container = angular.element(
        '<div id="freeroam-race-hud-overlay-container" ng-controller="FreeroamRaceHudController" ng-include="\'/ui/modModules/freeroamRaceHud/freeroamRaceHud.html\'"></div>'
      )
      bodyElement.append(container)
      $compile(container)($rootScope)
    }
    if (!document.getElementById('sanctioned-parking-staging-overlay-container')) {
      const spContainer = angular.element(
        '<div id="sanctioned-parking-staging-overlay-container" ng-controller="SanctionedParkingStagingController" ng-include="\'/ui/modModules/freeroamRaceHud/sanctionedParkingStaging.html\'"></div>'
      )
      bodyElement.append(spContainer)
      $compile(spContainer)($rootScope)
    }
    if (!document.getElementById('demo-staging-overlay-container')) {
      const dmsContainer = angular.element(
        '<div id="demo-staging-overlay-container" ng-controller="DemoStagingController" ng-include="\'/ui/modModules/freeroamRaceHud/demoStaging.html\'"></div>'
      )
      bodyElement.append(dmsContainer)
      $compile(dmsContainer)($rootScope)
    }
    if (!document.getElementById('demo-congratulations-overlay-container')) {
      const dmcContainer = angular.element(
        '<div id="demo-congratulations-overlay-container" ng-controller="DemoCongratulationsController" ng-include="\'/ui/modModules/freeroamRaceHud/demoCongratulations.html\'"></div>'
      )
      bodyElement.append(dmcContainer)
      $compile(dmcContainer)($rootScope)
    }
    if (!document.getElementById('dakar-start-overlay-container')) {
      const dakarStartContainer = angular.element(
        '<div id="dakar-start-overlay-container" ng-controller="DakarStartController" ng-include="\'/ui/modModules/freeroamRaceHud/dakarStart.html\'"></div>'
      )
      bodyElement.append(dakarStartContainer)
      $compile(dakarStartContainer)($rootScope)
    }
    if (!document.getElementById('dakar-compass-overlay-container')) {
      const dakarCompassContainer = angular.element(
        '<div id="dakar-compass-overlay-container" ng-controller="DakarCompassController" ng-include="\'/ui/modModules/freeroamRaceHud/dakarCompass.html\'"></div>'
      )
      bodyElement.append(dakarCompassContainer)
      $compile(dakarCompassContainer)($rootScope)
    }
    if (!document.getElementById('road-authority-clear-overlay-container')) {
      const roadAuthorityClearContainer = angular.element(
        '<div id="road-authority-clear-overlay-container" ng-controller="RoadAuthorityClearController" ng-include="\'/ui/modModules/freeroamRaceHud/roadAuthorityClear.html\'"></div>'
      )
      bodyElement.append(roadAuthorityClearContainer)
      $compile(roadAuthorityClearContainer)($rootScope)
    }
    if (!document.getElementById('road-authority-intro-overlay-container')) {
      const roadAuthorityIntroContainer = angular.element(
        '<div id="road-authority-intro-overlay-container" ng-controller="RoadAuthorityIntroController" ng-include="\'/ui/modModules/freeroamRaceHud/roadAuthorityIntro.html\'"></div>'
      )
      bodyElement.append(roadAuthorityIntroContainer)
      $compile(roadAuthorityIntroContainer)($rootScope)
    }
    if (!document.getElementById('dakar-finish-overlay-container')) {
      const dakarFinishContainer = angular.element(
        '<div id="dakar-finish-overlay-container" ng-controller="DakarFinishController" ng-include="\'/ui/modModules/freeroamRaceHud/dakarFinish.html\'"></div>'
      )
      bodyElement.append(dakarFinishContainer)
      $compile(dakarFinishContainer)($rootScope)
    }
    if (!document.getElementById('career-fast-travel-overlay-container')) {
      const fastTravelContainer = angular.element(
        '<div id="career-fast-travel-overlay-container" ng-controller="CareerFastTravelController" ng-include="\'/ui/modModules/freeroamRaceHud/fastTravel.html\'"></div>'
      )
      bodyElement.append(fastTravelContainer)
      $compile(fastTravelContainer)($rootScope)
    }
    if (!document.getElementById('mining-haul-overlay-container')) {
      const miningHaulContainer = angular.element(
        '<div id="mining-haul-overlay-container" ng-controller="MiningHaulController" ng-include="\'/ui/modModules/freeroamRaceHud/miningHaul.html\'"></div>'
      )
      bodyElement.append(miningHaulContainer)
      $compile(miningHaulContainer)($rootScope)
    }
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', initializeFreeroamRaceHudOverlay)
  } else {
    window.setTimeout(initializeFreeroamRaceHudOverlay, 300)
  }
})

export default freeroamRaceHudModule
