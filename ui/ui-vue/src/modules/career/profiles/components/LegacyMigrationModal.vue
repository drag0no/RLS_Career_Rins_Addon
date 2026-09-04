<template>
  <teleport to="body">
    <div class="lmm-backdrop" @click.self="emit('cancel')">
      <section class="lmm" role="dialog" aria-modal="true" aria-labelledby="legacy-migration-title">
        <header class="lmm-header">
          <div class="lmm-title">
            <div class="lmm-kicker">Legacy career save</div>
            <h2 id="legacy-migration-title">Compatibility report</h2>
            <p class="lmm-meta">
              <span>{{ report.profile || "Save" }}</span>
              <span class="lmm-meta-sep">·</span>
              <span>v{{ report.sourceVersion ?? "?" }} → v{{ report.targetVersion }}</span>
              <template v-if="report.level">
                <span class="lmm-meta-sep">·</span>
                <span>{{ report.level }}</span>
              </template>
            </p>
          </div>

          <div class="lmm-header-right">
            <div :class="['lmm-verdict', blocked ? 'lmm-verdict--blocked' : needsReview ? 'lmm-verdict--review' : 'lmm-verdict--ok']">
              <span class="lmm-verdict-dot" />
              {{ blocked ? "Cannot migrate" : needsReview ? "Needs review" : "Ready" }}
            </div>
            <button class="lmm-close" type="button" :disabled="busy" aria-label="Close" @click="emit('cancel')">×</button>
          </div>
        </header>

        <!-- Two steps rather than one long scroll: understand the save, then decide
             what to do with it. Both stay clickable so nothing is trapped behind a wizard. -->
        <nav class="lmm-steps" aria-label="Migration steps">
          <button
            type="button"
            :class="['lmm-step', { 'is-active': step === 'report' }]"
            :aria-current="step === 'report' ? 'step' : undefined"
            @click="step = 'report'">
            <span class="lmm-step-num">1</span>
            <span class="lmm-step-label">Review</span>
            <span v-if="issueTotal" class="lmm-step-badge">{{ issueTotal }}</span>
          </button>
          <span class="lmm-step-line" />
          <button
            type="button"
            :class="['lmm-step', { 'is-active': step === 'options', 'is-disabled': blocked }]"
            :aria-current="step === 'options' ? 'step' : undefined"
            :disabled="blocked"
            @click="step = 'options'">
            <span class="lmm-step-num">2</span>
            <span class="lmm-step-label">Choose what to keep</span>
          </button>
        </nav>

        <div class="lmm-body">
          <!-- ── Step 1 ───────────────────────────────────────────────────── -->
          <template v-if="step === 'report'">
            <div v-if="blocked" class="lmm-banner lmm-banner--blocked">
              <strong>This save cannot be migrated yet</strong>
              <p>Re-enable the missing content below, or pick an earlier healthy autosave, then re-open this report.</p>
            </div>

            <!-- One panel, not four: aligned stat columns over a footer strip for the
                 caveat, sharing the Findings panel's frame so the step reads as two blocks. -->
            <div class="lmm-summary">
              <div class="lmm-stats">
                <div class="lmm-stat">
                  <strong>{{ report.vehicleCount || 0 }}</strong>
                  <span>Vehicles<em v-if="report.incompatibleVehicleCount"> · {{ report.incompatibleVehicleCount }} at risk</em></span>
                </div>
                <div class="lmm-stat">
                  <strong>{{ report.garageCount || 0 }}</strong>
                  <span>Garages<em v-if="report.unavailableGarageCount"> · {{ report.unavailableGarageCount }} at risk</em></span>
                </div>
                <div class="lmm-stat">
                  <strong>${{ formatMoney(totalAssetValue) }}</strong>
                  <span>Estimated asset value</span>
                </div>
              </div>

              <p class="lmm-note">
                <strong>Your original save is never changed.</strong>
                Migration writes a separate copy and leaves the source untouched.
                <button type="button" class="lmm-note-toggle" @click="detailsOpen = !detailsOpen">
                  {{ detailsOpen ? "Hide details" : "What could go wrong?" }}
                </button>
              </p>
              <p v-if="detailsOpen" class="lmm-note-more">
                Missing, disabled, outdated, or changed mods may make vehicles, maps, parts, missions, or progression
                unavailable. Migration is best-effort and may reset unsupported data. The first load can take several
                minutes while vehicle and map caches rebuild, and ambient level audio may start before the loading
                screen closes.
              </p>
            </div>

            <!-- One panel with hairline rows, not a stack of floating cards, and the
                 severity is stated once per bucket instead of on every single row.
                 Repeated codes collapse into a single row with a count. -->
            <section v-if="issueTotal" class="lmm-section">
              <div class="lmm-section-heading">
                <h3>Findings</h3>
                <span class="lmm-count">{{ issueTotal }} total</span>
              </div>

              <div class="lmm-findings">
                <template v-for="bucket in issueBuckets" :key="bucket.severity">
                  <div :class="['lmm-bucket', `lmm-bucket--${bucket.severity}`]">
                    <span class="lmm-bucket-label">{{ bucket.label }}</span>
                    <span class="lmm-bucket-count">{{ bucket.total }}</span>
                  </div>

                  <article v-for="group in bucket.groups" :key="group.key" class="lmm-finding-row">
                    <button
                      type="button"
                      class="lmm-finding"
                      :disabled="group.items.length < 2"
                      :aria-expanded="group.items.length > 1 ? expanded.has(group.key) : undefined"
                      @click="toggleGroup(group.key)">
                      <span :class="['lmm-finding-icon', `lmm-finding-icon--${bucket.severity}`]" aria-hidden="true">
                        {{ bucket.glyph }}
                      </span>
                      <span class="lmm-finding-text">
                        <strong>{{ group.title }}</strong>
                        <span v-if="group.detail" class="lmm-finding-detail">{{ group.detail }}</span>
                      </span>
                      <span v-if="group.items.length > 1" class="lmm-finding-more">
                        {{ expanded.has(group.key) ? "Hide" : "List" }}
                        <span :class="['lmm-finding-chevron', { 'is-open': expanded.has(group.key) }]">▾</span>
                      </span>
                    </button>

                    <ul v-if="group.items.length > 1 && expanded.has(group.key)" class="lmm-finding-list">
                      <li v-for="(item, i) in group.items" :key="i">
                        <span class="lmm-finding-name">{{ item.label }}</span>
                        <span v-if="item.extra" class="lmm-finding-extra">{{ item.extra }}</span>
                      </li>
                    </ul>
                  </article>
                </template>
              </div>
            </section>

            <p v-else class="lmm-empty">No compatibility problems were found in this save.</p>
          </template>

          <!-- ── Step 2 ───────────────────────────────────────────────────── -->
          <template v-else>
            <section class="lmm-section">
              <div class="lmm-section-heading">
                <h3>What should happen to legacy assets?</h3>
              </div>

              <div class="lmm-policy">
                <label
                  v-for="option in policyOptions"
                  :key="option.value"
                  :class="['lmm-policy-card', { 'is-selected': vehiclePolicy === option.value }]">
                  <input v-model="vehiclePolicy" type="radio" :value="option.value" class="lmm-policy-input" />
                  <span class="lmm-policy-mark" aria-hidden="true" />
                  <span class="lmm-policy-body">
                    <span class="lmm-policy-title">
                      {{ option.title }}
                      <em v-if="option.recommended" class="lmm-recommended">Recommended</em>
                    </span>
                    <small>{{ option.blurb }}</small>
                    <span class="lmm-policy-outcome">{{ option.outcome }}</span>
                  </span>
                </label>
              </div>
            </section>

            <section v-if="hasAssets" class="lmm-section">
              <div class="lmm-section-heading">
                <h3>{{ vehiclePolicy === "individual" ? "Pick what to sell" : "Save contents" }}</h3>
                <button v-if="vehiclePolicy !== 'individual'" type="button" class="lmm-link" @click="assetsOpen = !assetsOpen">
                  {{ assetsOpen ? "Hide" : `Show ${assetCount} item${assetCount === 1 ? "" : "s"}` }}
                </button>
                <div v-else class="lmm-bulk">
                  <button type="button" class="lmm-link" @click="selectAll">All</button>
                  <button type="button" class="lmm-link" @click="selectIssuesOnly">Only at-risk</button>
                  <button type="button" class="lmm-link" @click="selectNone">None</button>
                </div>
              </div>

              <p v-if="vehiclePolicy === 'individual'" class="lmm-selection-total">
                Selling <strong>{{ selectedCashOutIds.length + selectedGarageIds.length }}</strong>
                of {{ assetCount }} · credits <strong>${{ formatMoney(individualTotal) }}</strong>
              </p>

              <div v-if="assetsVisible" class="lmm-asset-groups">
                <div v-if="vehicles.length" class="lmm-asset-group">
                  <div class="lmm-asset-group-head">
                    <h4>Vehicles</h4>
                    <span>{{ report.compatibleVehicleCount || 0 }} available · {{ report.incompatibleVehicleCount || 0 }} at risk</span>
                  </div>
                  <div class="lmm-assets">
                    <label
                      v-for="vehicle in vehicles"
                      :key="vehicle.id"
                      :class="[
                        'lmm-asset',
                        { 'lmm-asset--issue': !vehicle.available },
                        { 'lmm-asset--pickable': vehiclePolicy === 'individual' },
                        { 'is-picked': vehiclePolicy === 'individual' && selectedCashOutIds.includes(Number(vehicle.id)) },
                      ]">
                      <input
                        v-if="vehiclePolicy === 'individual'"
                        type="checkbox"
                        class="lmm-asset-check"
                        :checked="selectedCashOutIds.includes(Number(vehicle.id))"
                        @change="toggleVehicle(vehicle.id)" />
                      <span class="lmm-asset-main">
                        <strong>{{ vehicle.name }}</strong>
                        <span class="lmm-asset-sub">{{ vehicle.model || "Unknown model" }}</span>
                        <span v-if="vehicle.issues?.length" class="lmm-asset-reason">{{ vehicle.issues.join(" · ") }}</span>
                      </span>
                      <span :class="['lmm-status', vehicle.available ? 'lmm-status--ok' : 'lmm-status--risk']">
                        {{ vehicle.available ? "Available" : "At risk" }}
                      </span>
                      <span class="lmm-value">${{ formatMoney(vehicle.savedValue) }}</span>
                    </label>
                  </div>
                </div>

                <div v-if="garages.length" class="lmm-asset-group">
                  <div class="lmm-asset-group-head">
                    <h4>Garages</h4>
                    <span>{{ report.availableGarageCount || 0 }} available · {{ report.unavailableGarageCount || 0 }} at risk</span>
                  </div>
                  <p class="lmm-hint">Garage proceeds use the immediate sell-back estimate after any saved mortgage balance.</p>
                  <div class="lmm-assets">
                    <label
                      v-for="garage in garages"
                      :key="garage.id"
                      :class="[
                        'lmm-asset',
                        { 'lmm-asset--issue': !garage.available },
                        { 'lmm-asset--pickable': vehiclePolicy === 'individual' },
                        { 'is-picked': vehiclePolicy === 'individual' && selectedGarageIds.includes(String(garage.id)) },
                      ]">
                      <input
                        v-if="vehiclePolicy === 'individual'"
                        type="checkbox"
                        class="lmm-asset-check"
                        :checked="selectedGarageIds.includes(String(garage.id))"
                        @change="toggleGarage(garage.id)" />
                      <span class="lmm-asset-main">
                        <strong>{{ garage.name }}</strong>
                        <span class="lmm-asset-sub">
                          {{ garage.capacity || 0 }} space{{ garage.capacity === 1 ? "" : "s" }}
                          <template v-if="garage.vehicleCount"> · {{ garage.vehicleCount }} stored vehicle{{ garage.vehicleCount === 1 ? "" : "s" }}</template>
                        </span>
                        <span v-if="garage.issues?.length" class="lmm-asset-reason">{{ garage.issues.join(" · ") }}</span>
                      </span>
                      <span :class="['lmm-status', garage.available ? 'lmm-status--ok' : 'lmm-status--risk']">
                        {{ garage.available ? "Available" : "At risk" }}
                      </span>
                      <span class="lmm-value">${{ formatMoney(garage.savedValue) }}</span>
                    </label>
                  </div>
                </div>
              </div>
            </section>

            <section class="lmm-section">
              <label class="lmm-name-label" for="migration-profile-name">Name the migrated copy</label>
              <input
                id="migration-profile-name"
                v-model="targetProfile"
                class="lmm-name"
                maxlength="100"
                :disabled="busy || report.preparedMigration"
                @focus="onInputFocus"
                @blur="onInputBlur" />
              <p class="lmm-hint">The original profile keeps its name and its data.</p>
            </section>
          </template>

          <p v-if="error" class="lmm-error">{{ error }}</p>
        </div>

        <footer class="lmm-footer">
          <label v-if="step === 'options'" class="lmm-ack">
            <input v-model="acknowledged" type="checkbox" :disabled="busy" />
            <span>
              I understand the selected vehicles, parts, and garages are removed only from the migrated copy, that mod
              compatibility cannot be guaranteed, and that my original save stays untouched.
            </span>
          </label>
          <p v-else class="lmm-footer-hint">
            {{ blocked ? "Migration is unavailable until the blockers above are resolved." : "Review the findings, then choose what to keep." }}
          </p>

          <div class="lmm-actions">
            <span v-if="blockReason" class="lmm-block-reason">{{ blockReason }}</span>
            <button class="lmm-btn lmm-btn--secondary" type="button" :disabled="busy" @click="onSecondary">
              {{ step === "options" ? "Back" : "Cancel" }}
            </button>
            <button
              v-if="step === 'report'"
              class="lmm-btn lmm-btn--primary"
              type="button"
              :disabled="blocked || busy"
              @click="step = 'options'">
              Continue
            </button>
            <button v-else class="lmm-btn lmm-btn--primary" type="button" :disabled="!canMigrate" @click="submit">
              {{ busy ? "Loading…" : report.preparedMigration ? "Load Profile" : "Create and Load Profile" }}
            </button>
          </div>
        </footer>
      </section>
    </div>
  </teleport>
</template>

<script setup>
import { computed, onBeforeUnmount, onMounted, ref, watch } from "vue"
import { lua } from "@/bridge"

const props = defineProps({
  report: { type: Object, required: true },
  busy: Boolean,
  error: { type: String, default: "" },
})

const emit = defineEmits(["cancel", "migrate"])

const targetProfile = ref("")
const vehiclePolicy = ref("sellall")
const selectedCashOutIds = ref([])
const selectedGarageIds = ref([])
const acknowledged = ref(false)

const step = ref("report")
const expanded = ref(new Set())
const detailsOpen = ref(false)
const assetsOpen = ref(false)

/** Lua serialises an empty table as `{}`, not `[]`, so never assume an array came back. */
function asArray(value) {
  return Array.isArray(value) ? value : []
}

const blocked = computed(() => props.report.canMigrate === false || Number(props.report.blockerCount || 0) > 0)
const issues = computed(() => asArray(props.report.issues))
const issueTotal = computed(() => issues.value.length)
const needsReview = computed(() => issueTotal.value > 0)

const canMigrate = computed(() =>
  !props.busy && !blocked.value && acknowledged.value && !!targetProfile.value.trim()
)

/** Says why the primary button is dead instead of leaving a greyed-out mystery. */
const blockReason = computed(() => {
  // The report step already states the blocker case in its banner and footer hint.
  if (props.busy || step.value !== "options") return ""
  if (!targetProfile.value.trim()) return "Name the migrated copy"
  if (!acknowledged.value) return "Tick the acknowledgement to continue"
  return ""
})

watch(
  () => props.report,
  report => {
    targetProfile.value = report?.defaultTargetProfile || report?.profile || ""
    vehiclePolicy.value = "sellall"
    selectedCashOutIds.value = asArray(report?.vehicles)
      .filter(vehicle => !vehicle.available)
      .map(vehicle => Number(vehicle.id))
      .filter(Number.isFinite)
    selectedGarageIds.value = asArray(report?.garages)
      .filter(garage => !garage.available)
      .map(garage => String(garage.id))
    acknowledged.value = false
    step.value = "report"
    expanded.value = new Set()
    detailsOpen.value = false
    assetsOpen.value = false
  },
  { immediate: true }
)

/* ── Findings ──────────────────────────────────────────────────────────── */

const SEVERITY_ORDER = { blocker: 0, action: 1, warning: 2 }

/** Repeated codes get one honest headline instead of N copies of the same sentence. */
const GROUP_TITLES = {
  "vehicle.contentMissing": n => `${n} vehicles cannot currently be spawned`,
  "vehicle.unreadable": n => `${n} vehicle records cannot be migrated safely`,
  "garage.contentMissing": n => `${n} garages cannot currently be found`,
}

/**
 * Longest phrase every title ends with, snapped to a word boundary so shared
 * trailing letters in names ("Bastion"/"Legran") are never eaten. Lets the expanded
 * rows drop "… cannot currently be spawned" once the headline has already said it.
 */
function sharedTitleSuffix(titles) {
  if (titles.length < 2) return ""
  let suffix = titles[0]
  for (let i = 1; i < titles.length && suffix; i++) {
    const other = titles[i]
    let n = 0
    while (n < suffix.length && n < other.length && suffix[suffix.length - 1 - n] === other[other.length - 1 - n]) n++
    suffix = suffix.slice(suffix.length - n)
  }
  const boundary = suffix.indexOf(" ")
  return boundary >= 0 ? suffix.slice(boundary) : ""
}

const issueGroups = computed(() => {
  const byKey = new Map()
  for (const issue of issues.value) {
    const key = `${issue.severity}|${issue.code}`
    let group = byKey.get(key)
    if (!group) {
      group = { key, severity: issue.severity, code: issue.code, items: [] }
      byKey.set(key, group)
    }
    group.items.push(issue)
  }

  return [...byKey.values()]
    .map(group => {
      const count = group.items.length
      const sharedDetail = group.items.every(item => item.detail === group.items[0].detail)
        ? group.items[0].detail
        : null
      const suffix = sharedTitleSuffix(group.items.map(item => item.title))

      return {
        ...group,
        title: count === 1 ? group.items[0].title : GROUP_TITLES[group.code]?.(count) || `${group.items[0].title} + ${count - 1} more`,
        detail: count === 1 ? group.items[0].detail : sharedDetail,
        // Each row keeps only what the headline above it does not already say.
        items: group.items.map(item => ({
          label: (suffix && item.title.endsWith(suffix) ? item.title.slice(0, -suffix.length).trim() : item.title) || item.title,
          extra: item.detail === sharedDetail ? "" : item.detail,
        })),
      }
    })
    .sort((a, b) => (SEVERITY_ORDER[a.severity] ?? 9) - (SEVERITY_ORDER[b.severity] ?? 9))
})

const SEVERITY_BUCKETS = [
  { severity: "blocker", label: "Blocking", glyph: "✕" },
  { severity: "action", label: "Needs attention", glyph: "!" },
  { severity: "warning", label: "Warnings", glyph: "i" },
]

/** Severity is a heading over its rows, so no row has to repeat it. */
const issueBuckets = computed(() =>
  SEVERITY_BUCKETS.map(bucket => {
    const groups = issueGroups.value.filter(group => group.severity === bucket.severity)
    return { ...bucket, groups, total: groups.reduce((sum, group) => sum + group.items.length, 0) }
  }).filter(bucket => bucket.groups.length > 0)
)

function toggleGroup(key) {
  const next = new Set(expanded.value)
  if (next.has(key)) next.delete(key)
  else next.add(key)
  expanded.value = next
}

/* ── Assets & policy ───────────────────────────────────────────────────── */

const vehicles = computed(() => asArray(props.report.vehicles))
const garages = computed(() => asArray(props.report.garages))
const hasAssets = computed(() => vehicles.value.length > 0 || garages.value.length > 0)
const assetCount = computed(() => vehicles.value.length + garages.value.length)
const assetsVisible = computed(() => vehiclePolicy.value === "individual" || assetsOpen.value)

const totalAssetValue = computed(
  () =>
    vehicles.value.reduce((sum, v) => sum + (Number(v.savedValue) || 0), 0)
    + garages.value.reduce((sum, g) => sum + (Number(g.savedValue) || 0), 0)
)

const individualTotal = computed(
  () =>
    vehicles.value
      .filter(v => selectedCashOutIds.value.includes(Number(v.id)))
      .reduce((sum, v) => sum + (Number(v.savedValue) || 0), 0)
    + garages.value
      .filter(g => selectedGarageIds.value.includes(String(g.id)))
      .reduce((sum, g) => sum + (Number(g.savedValue) || 0), 0)
)

const atRiskCount = computed(
  () => vehicles.value.filter(v => !v.available).length + garages.value.filter(g => !g.available).length
)

const policyOptions = computed(() => [
  {
    value: "sellall",
    title: "Sell everything",
    recommended: true,
    blurb: "Removes every legacy vehicle, part, and garage record and credits their estimated value.",
    outcome: `Credits about $${formatMoney(totalAssetValue.value)} · nothing can break later`,
  },
  {
    value: "individual",
    title: "Choose what to sell",
    blurb: "Pick the assets to convert to cash. At-risk items start selected.",
    outcome: `${selectedCashOutIds.value.length + selectedGarageIds.value.length} of ${assetCount.value} selected · $${formatMoney(individualTotal.value)}`,
  },
  {
    value: "preserve",
    title: "Keep everything",
    blurb: "Keeps all vehicle and garage records. Missing content stays quarantined and cannot spawn.",
    outcome: atRiskCount.value
      ? `Keeps ${assetCount.value} items · ${atRiskCount.value} stay quarantined`
      : `Keeps all ${assetCount.value} items`,
  },
])

function selectAll() {
  selectedCashOutIds.value = vehicles.value.map(v => Number(v.id)).filter(Number.isFinite)
  selectedGarageIds.value = garages.value.map(g => String(g.id))
}

function selectNone() {
  selectedCashOutIds.value = []
  selectedGarageIds.value = []
}

function selectIssuesOnly() {
  selectedCashOutIds.value = vehicles.value.filter(v => !v.available).map(v => Number(v.id)).filter(Number.isFinite)
  selectedGarageIds.value = garages.value.filter(g => !g.available).map(g => String(g.id))
}

function formatMoney(value) {
  return Math.max(0, Number(value) || 0).toLocaleString(undefined, { maximumFractionDigits: 0 })
}

function toggleVehicle(id) {
  id = Number(id)
  if (selectedCashOutIds.value.includes(id)) {
    selectedCashOutIds.value = selectedCashOutIds.value.filter(value => value !== id)
  } else {
    selectedCashOutIds.value = [...selectedCashOutIds.value, id]
  }
}

function toggleGarage(id) {
  id = String(id)
  if (selectedGarageIds.value.includes(id)) {
    selectedGarageIds.value = selectedGarageIds.value.filter(value => value !== id)
  } else {
    selectedGarageIds.value = [...selectedGarageIds.value, id]
  }
}

function onInputFocus() {
  try { lua.setCEFTyping(true) } catch (_) {}
}

function onInputBlur() {
  try { lua.setCEFTyping(false) } catch (_) {}
}

function onSecondary() {
  if (step.value === "options") step.value = "report"
  else emit("cancel")
}

function onKeydown(event) {
  if (event.key === "Escape" && !props.busy) emit("cancel")
}

onMounted(() => document.addEventListener("keydown", onKeydown))
onBeforeUnmount(() => {
  document.removeEventListener("keydown", onKeydown)
  onInputBlur()
})

function submit() {
  if (!canMigrate.value) return
  let cashOutVehicleIds = []
  let cashOutGarageIds = []
  if (vehiclePolicy.value === "sellall") {
    cashOutVehicleIds = vehicles.value.map(vehicle => Number(vehicle.id)).filter(Number.isFinite)
    cashOutGarageIds = garages.value.map(garage => String(garage.id))
  } else if (vehiclePolicy.value === "individual") {
    cashOutVehicleIds = [...selectedCashOutIds.value]
    cashOutGarageIds = [...selectedGarageIds.value]
  }

  emit("migrate", {
    targetProfile: targetProfile.value.trim(),
    vehiclePolicy: vehiclePolicy.value,
    cashOutVehicleIds,
    cashOutGarageIds,
    sellParts: vehiclePolicy.value === "sellall",
  })
}
</script>

<style lang="scss" scoped>
@use "@/styles/modules/mixins" as *;

$accent: #ff7a1a;
$risk: #fb923c;
$danger: #f04747;
$ok: #4ade80;
$muted: rgba(255, 255, 255, 0.55);
$line: rgba(71, 85, 105, 0.45);
$surface: rgba(5, 8, 15, 0.55);

.lmm-backdrop {
  position: fixed;
  inset: 0;
  z-index: 10000;
  display: grid;
  place-items: center;
  padding: calc-ui-rem(1.5);
  background: rgba(2, 5, 12, 0.86);
  backdrop-filter: blur(10px);
}

.lmm {
  width: min(calc-ui-rem(58), 94vw);
  max-height: 88vh;
  display: grid;
  grid-template-rows: auto auto minmax(0, 1fr) auto;
  overflow: hidden;
  color: #fff;
  background: linear-gradient(160deg, #101623, #070a12 62%);
  border: 1px solid rgba(71, 85, 105, 0.55);
  border-radius: calc-ui-rem(0.9);
  box-shadow: 0 1.8rem 4.5rem rgba(0, 0, 0, 0.7);
  font-size: calc-ui-rem();
}

/* ── Header ─────────────────────────────────────────────────────────── */

.lmm-header {
  display: flex;
  align-items: flex-start;
  justify-content: space-between;
  gap: 1em;
  padding: 1em 1.15em 0.9em;
  border-bottom: 1px solid rgba(71, 85, 105, 0.3);

  h2 {
    margin: 0.12em 0 0.2em;
    font-size: 1.45em;
    line-height: 1.1;
  }
}

.lmm-kicker {
  color: $accent;
  font-size: 0.68em;
  font-weight: 900;
  letter-spacing: 0.1em;
  text-transform: uppercase;
}

.lmm-meta {
  display: flex;
  flex-wrap: wrap;
  gap: 0.4em;
  margin: 0;
  color: $muted;
  font-size: 0.8em;
}
.lmm-meta-sep { opacity: 0.45; }

.lmm-header-right {
  display: flex;
  align-items: center;
  gap: 0.6em;
}

.lmm-verdict {
  display: inline-flex;
  align-items: center;
  gap: 0.45em;
  padding: 0.3em 0.7em;
  border-radius: 999px;
  border: 1px solid currentColor;
  font-size: 0.72em;
  font-weight: 800;
  letter-spacing: 0.03em;
  text-transform: uppercase;
  white-space: nowrap;
}
.lmm-verdict-dot {
  width: 0.55em;
  height: 0.55em;
  border-radius: 50%;
  background: currentColor;
}
.lmm-verdict--blocked { color: $danger; background: rgba(240, 71, 71, 0.12); }
.lmm-verdict--review { color: $risk; background: rgba(251, 146, 60, 0.12); }
.lmm-verdict--ok { color: $ok; background: rgba(74, 222, 128, 0.12); }

.lmm-close {
  border: 0;
  background: transparent;
  color: rgba(255, 255, 255, 0.55);
  font-size: 1.8em;
  line-height: 1;
  cursor: pointer;

  &:hover { color: #fff; }
}

/* ── Steps ──────────────────────────────────────────────────────────── */

.lmm-steps {
  display: flex;
  align-items: center;
  gap: 0.5em;
  padding: 0.65em 1.15em;
  background: rgba(2, 5, 12, 0.45);
  border-bottom: 1px solid rgba(71, 85, 105, 0.3);
}

.lmm-step {
  display: inline-flex;
  align-items: center;
  gap: 0.5em;
  padding: 0.32em 0.75em 0.32em 0.35em;
  border: 1px solid transparent;
  border-radius: 999px;
  background: transparent;
  color: $muted;
  font-family: inherit;
  font-size: 0.82em;
  cursor: pointer;

  &:hover:not(.is-disabled) { color: #fff; }

  &.is-active {
    color: #fff;
    border-color: rgba(255, 122, 26, 0.55);
    background: rgba(255, 122, 26, 0.12);

    .lmm-step-num { background: $accent; color: #10131a; }
  }

  &.is-disabled,
  &:disabled { opacity: 0.4; cursor: default; }
}

.lmm-step-num {
  display: grid;
  place-items: center;
  width: 1.7em;
  height: 1.7em;
  border-radius: 50%;
  background: rgba(148, 163, 184, 0.2);
  font-size: 0.85em;
  font-weight: 800;
}

.lmm-step-label { font-weight: 700; }

.lmm-step-badge {
  padding: 0.05em 0.45em;
  border-radius: 999px;
  background: rgba(251, 146, 60, 0.2);
  color: $risk;
  font-size: 0.8em;
  font-weight: 800;
}

.lmm-step-line {
  flex: 0 0 1.5em;
  height: 1px;
  background: rgba(148, 163, 184, 0.3);
}

/* ── Body ───────────────────────────────────────────────────────────── */

.lmm-body {
  overflow: auto;
  padding: 1em 1.15em 1.2em;
}

.lmm-banner {
  padding: 0.75em 0.9em;
  border-radius: 10px;
  border-left: 3px solid $danger;
  background: rgba(240, 71, 71, 0.12);

  strong { display: block; }
  p { margin: 0.2em 0 0; color: rgba(255, 255, 255, 0.7); font-size: 0.85em; line-height: 1.4; }
}

.lmm-summary {
  margin-top: 0.75em;
  border: 1px solid rgba(71, 85, 105, 0.35);
  border-radius: 10px;
  background: rgba(15, 23, 42, 0.4);
  overflow: hidden;
}

.lmm-stats {
  display: grid;
  grid-template-columns: repeat(3, 1fr);
}

.lmm-stat {
  display: flex;
  flex-direction: column;
  gap: 0.05em;
  padding: 0.7em 0.9em;
  border-left: 1px solid rgba(71, 85, 105, 0.28);

  &:first-child { border-left: 0; }

  strong { font-size: 1.3em; line-height: 1.15; }
  span { color: $muted; font-size: 0.72em; }
  em { color: $risk; font-style: normal; }
}

.lmm-note {
  margin: 0;
  padding: 0.6em 0.9em;
  border-top: 1px solid rgba(71, 85, 105, 0.28);
  background: rgba(2, 5, 12, 0.4);
  color: rgba(255, 255, 255, 0.58);
  font-size: 0.79em;
  line-height: 1.45;

  strong { color: #fff; }
}

.lmm-note-toggle {
  padding: 0;
  border: 0;
  background: none;
  color: $accent;
  font-family: inherit;
  font-size: 1em;
  font-weight: 700;
  white-space: nowrap;
  cursor: pointer;

  &:hover { text-decoration: underline; }
}

.lmm-note-more {
  margin: 0;
  padding: 0 0.9em 0.7em;
  background: rgba(2, 5, 12, 0.4);
  color: rgba(255, 255, 255, 0.48);
  font-size: 0.77em;
  line-height: 1.5;
}

.lmm-section {
  margin-top: 1.1em;

  h3 { margin: 0; font-size: 0.95em; }
  h4 { margin: 0; font-size: 0.85em; }
}

.lmm-section-heading {
  display: flex;
  align-items: center;
  justify-content: space-between;
  flex-wrap: wrap;
  gap: 0.5em;
  margin-bottom: 0.55em;
}

.lmm-link {
  border: 0;
  background: none;
  padding: 0;
  color: $accent;
  font-family: inherit;
  font-size: 0.78em;
  font-weight: 700;
  cursor: pointer;

  &:hover { text-decoration: underline; }
}

.lmm-bulk {
  display: flex;
  gap: 0.75em;
}

/* ── Findings ───────────────────────────────────────────────────────── */

.lmm-count {
  color: $muted;
  font-size: 0.78em;
}

.lmm-findings {
  border: 1px solid rgba(71, 85, 105, 0.35);
  border-radius: 10px;
  background: rgba(15, 23, 42, 0.4);
  overflow: hidden;
}

.lmm-bucket {
  display: flex;
  align-items: center;
  gap: 0.5em;
  padding: 0.45em 0.8em;
  background: rgba(2, 5, 12, 0.5);
  border-top: 1px solid rgba(71, 85, 105, 0.3);
  font-size: 0.66em;
  font-weight: 900;
  letter-spacing: 0.1em;
  text-transform: uppercase;

  &:first-child { border-top: 0; }
}
.lmm-bucket--blocker { color: $danger; }
.lmm-bucket--action { color: $risk; }
.lmm-bucket--warning { color: #facc15; }

.lmm-bucket-label { flex: 1 1 auto; }

.lmm-bucket-count {
  padding: 0.1em 0.5em;
  border-radius: 999px;
  background: rgba(255, 255, 255, 0.08);
  color: rgba(255, 255, 255, 0.75);
  letter-spacing: 0;
}

.lmm-finding-row {
  border-top: 1px solid rgba(71, 85, 105, 0.22);
}

.lmm-finding {
  display: grid;
  grid-template-columns: auto minmax(0, 1fr) auto;
  align-items: start;
  gap: 0.7em;
  width: 100%;
  padding: 0.6em 0.8em;
  border: 0;
  background: none;
  color: inherit;
  font-family: inherit;
  font-size: 1em;
  text-align: left;
  cursor: pointer;

  &:disabled { cursor: default; }
  &:not(:disabled):hover { background: rgba(255, 255, 255, 0.045); }
}

.lmm-finding-icon {
  display: grid;
  place-items: center;
  width: 1.5em;
  height: 1.5em;
  margin-top: 0.05em;
  border-radius: 6px;
  font-size: 0.8em;
  font-weight: 900;
  line-height: 1;
}
.lmm-finding-icon--blocker { color: $danger; background: rgba(240, 71, 71, 0.18); }
.lmm-finding-icon--action { color: $risk; background: rgba(251, 146, 60, 0.18); }
.lmm-finding-icon--warning { color: #facc15; background: rgba(250, 204, 21, 0.16); }

.lmm-finding-text {
  display: flex;
  flex-direction: column;
  gap: 0.1em;
  min-width: 0;

  strong { font-size: 0.88em; font-weight: 700; }
}

.lmm-finding-detail {
  color: rgba(255, 255, 255, 0.52);
  font-size: 0.76em;
  line-height: 1.4;
}

.lmm-finding-more {
  display: inline-flex;
  align-items: center;
  gap: 0.3em;
  margin-top: 0.1em;
  color: $accent;
  font-size: 0.72em;
  font-weight: 700;
  white-space: nowrap;
}

.lmm-finding-chevron {
  transition: transform 0.15s ease;

  &.is-open { transform: rotate(180deg); }
}

/* Names only, in columns — the headline above already carries the reason. */
.lmm-finding-list {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(11em, 1fr));
  gap: 0.1em 1.2em;
  margin: 0;
  padding: 0 0.8em 0.6em 3em;
  list-style: none;

  li {
    display: flex;
    flex-direction: column;
    font-size: 0.78em;
    line-height: 1.4;
  }
}

.lmm-finding-name {
  color: rgba(255, 255, 255, 0.78);

  &::before {
    content: "·";
    margin-right: 0.45em;
    color: rgba(255, 255, 255, 0.35);
  }
}

.lmm-finding-extra {
  padding-left: 0.9em;
  color: rgba(255, 255, 255, 0.42);
  font-size: 0.92em;
}

.lmm-empty {
  margin: 1.2em 0;
  padding: 1em;
  border: 1px dashed rgba(71, 85, 105, 0.5);
  border-radius: 10px;
  color: $muted;
  text-align: center;
  font-size: 0.88em;
}

/* ── Policy ─────────────────────────────────────────────────────────── */

.lmm-policy {
  display: grid;
  grid-template-columns: repeat(3, 1fr);
  gap: 0.5em;
}

.lmm-policy-card {
  position: relative;
  display: grid;
  grid-template-columns: auto minmax(0, 1fr);
  gap: 0.55em;
  padding: 0.75em;
  border: 1px solid $line;
  border-radius: 10px;
  background: $surface;
  cursor: pointer;
  transition: border-color 0.12s ease, background 0.12s ease;

  &:hover { border-color: rgba(255, 122, 26, 0.45); }

  &.is-selected {
    border-color: rgba(255, 122, 26, 0.9);
    background: rgba(255, 122, 26, 0.1);

    .lmm-policy-mark {
      border-color: $accent;
      background: radial-gradient(circle, $accent 0 42%, transparent 46%);
    }
  }
}

.lmm-policy-input {
  position: absolute;
  opacity: 0;
  pointer-events: none;
}

.lmm-policy-mark {
  width: 1em;
  height: 1em;
  margin-top: 0.15em;
  border: 1px solid rgba(148, 163, 184, 0.7);
  border-radius: 50%;
}

.lmm-policy-body {
  display: flex;
  flex-direction: column;
  gap: 0.2em;
  min-width: 0;

  small { color: rgba(255, 255, 255, 0.55); font-size: 0.74em; line-height: 1.35; }
}

.lmm-policy-title {
  font-size: 0.9em;
  font-weight: 800;
}

.lmm-policy-outcome {
  margin-top: 0.15em;
  color: $accent;
  font-size: 0.72em;
  font-weight: 700;
}

.lmm-recommended {
  display: inline-block;
  margin-left: 0.35em;
  padding: 0.1em 0.4em;
  border-radius: 999px;
  color: #10131a;
  background: $accent;
  font-size: 0.62em;
  font-style: normal;
  font-weight: 900;
  letter-spacing: 0.04em;
  text-transform: uppercase;
  vertical-align: 0.15em;
}

/* ── Assets ─────────────────────────────────────────────────────────── */

.lmm-selection-total {
  margin: -0.15em 0 0.55em;
  color: rgba(255, 255, 255, 0.65);
  font-size: 0.8em;

  strong { color: #fff; }
}

.lmm-asset-groups {
  display: flex;
  flex-direction: column;
  gap: 0.9em;
}

.lmm-asset-group-head {
  display: flex;
  align-items: baseline;
  justify-content: space-between;
  gap: 0.5em;
  margin-bottom: 0.35em;

  span { color: $muted; font-size: 0.74em; }
}

.lmm-assets {
  display: flex;
  flex-direction: column;
  gap: 0.25em;
}

.lmm-asset {
  display: grid;
  grid-template-columns: minmax(0, 1fr) auto 6em;
  align-items: center;
  gap: 0.65em;
  padding: 0.5em 0.7em;
  border: 1px solid transparent;
  border-radius: 8px;
  background: rgba(15, 23, 42, 0.5);
}
.lmm-asset--pickable {
  grid-template-columns: auto minmax(0, 1fr) auto 6em;
  cursor: pointer;

  &:hover { border-color: rgba(255, 122, 26, 0.4); }
  &.is-picked { border-color: rgba(255, 122, 26, 0.65); background: rgba(255, 122, 26, 0.08); }
}
.lmm-asset--issue { border-color: rgba(251, 146, 60, 0.45); }

.lmm-asset-check {
  width: 1em;
  height: 1em;
  accent-color: $accent;
}

.lmm-asset-main {
  display: flex;
  flex-direction: column;
  min-width: 0;

  strong { font-size: 0.88em; }
}
.lmm-asset-sub { color: $muted; font-size: 0.72em; }
.lmm-asset-reason { color: $risk; font-size: 0.7em; }

.lmm-status {
  padding: 0.18em 0.5em;
  border-radius: 999px;
  font-size: 0.66em;
  font-weight: 800;
  white-space: nowrap;
}
.lmm-status--ok { color: $ok; background: rgba(74, 222, 128, 0.14); }
.lmm-status--risk { color: $risk; background: rgba(251, 146, 60, 0.16); }

.lmm-value {
  text-align: right;
  color: rgba(255, 255, 255, 0.75);
  font-size: 0.85em;
  font-variant-numeric: tabular-nums;
}

/* ── Name & footer ──────────────────────────────────────────────────── */

.lmm-name-label {
  display: block;
  margin-bottom: 0.35em;
  font-size: 0.9em;
  font-weight: 800;
}

.lmm-name {
  width: 100%;
  box-sizing: border-box;
  padding: 0.55em 0.7em;
  border: 1px solid $line;
  border-radius: 8px;
  outline: none;
  color: #fff;
  background: rgba(2, 5, 12, 0.75);
  font-family: inherit;
  font-size: 0.95em;

  &:focus { border-color: $accent; }
  &:disabled { opacity: 0.6; }
}

.lmm-hint {
  margin: 0.35em 0 0;
  color: $muted;
  font-size: 0.74em;
}

.lmm-error {
  margin: 0.8em 0 0;
  padding: 0.6em 0.75em;
  border-radius: 8px;
  border-left: 3px solid $danger;
  background: rgba(240, 71, 71, 0.12);
  color: #fecaca;
  font-size: 0.85em;
}

.lmm-footer {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 1.2em;
  padding: 0.85em 1.15em;
  border-top: 1px solid rgba(71, 85, 105, 0.3);
  background: rgba(2, 5, 12, 0.55);
}

.lmm-ack {
  display: flex;
  align-items: flex-start;
  gap: 0.55em;
  min-width: 0;
  color: rgba(255, 255, 255, 0.6);
  font-size: 0.74em;
  line-height: 1.35;
  cursor: pointer;

  input { margin-top: 0.15em; accent-color: $accent; }
  &:hover { color: rgba(255, 255, 255, 0.85); }
}

.lmm-footer-hint {
  margin: 0;
  min-width: 0;
  color: $muted;
  font-size: 0.78em;
}

.lmm-actions {
  display: flex;
  align-items: center;
  gap: 0.55em;
  flex: 0 0 auto;
}

.lmm-block-reason {
  color: $risk;
  font-size: 0.72em;
  text-align: right;
}

.lmm-btn {
  padding: 0.55em 1em;
  border: 1px solid transparent;
  border-radius: 8px;
  color: #fff;
  font-family: inherit;
  font-size: 0.88em;
  font-weight: 800;
  white-space: nowrap;
  cursor: pointer;

  &:disabled { opacity: 0.4; cursor: default; }
}
.lmm-btn--secondary {
  background: rgba(51, 65, 85, 0.6);
  border-color: rgba(100, 116, 139, 0.5);

  &:not(:disabled):hover { background: rgba(71, 85, 105, 0.8); }
}
.lmm-btn--primary {
  background: $accent;
  border-color: #ff9a4d;
  color: #10131a;

  &:not(:disabled):hover { background: #ff8c33; }
}

@media (max-width: 900px) {
  .lmm-policy { grid-template-columns: 1fr; }
  .lmm-footer { flex-direction: column; align-items: stretch; }
  .lmm-actions { justify-content: flex-end; }
}
</style>
