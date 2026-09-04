<template>
  <div
    class="home-widget finances-widget"
    :class="{ 'home-widget--compact': compact, 'home-widget--fill': fillHeight }"
  >
    <div class="widget-header">
      <h3>Finances</h3>
      <div class="balance-badge" :class="{ negative: accountBalance < 0 }">
        {{ formatCurrency(accountBalance) }}
      </div>
    </div>

    <div class="widget-content">
      <div v-if="loading" class="loading-state">
        Loading...
      </div>
      <template v-else>
        <div class="ledger-scroll">
          <div v-if="!sortedTransactions.length" class="empty-ledger">
            No transactions yet.
          </div>
          <ul v-else class="ledger-list">
            <li
              v-for="(tx, idx) in displayTransactions"
              :key="tx.id != null ? String(tx.id) : `tx-${idx}-${tx.timestamp ?? ''}`"
              class="ledger-row"
            >
              <div class="ledger-row__info">
                <span class="ledger-row__label">{{ getTransactionLabel(tx) }}</span>
                <span class="ledger-row__date">{{ formatTxDate(tx.timestamp) }}</span>
              </div>
              <div
                class="ledger-row__amount"
                :class="(tx.amount || 0) >= 0 ? 'credit' : 'debit'"
              >
                {{ (tx.amount || 0) >= 0 ? "+" : "−" }}{{ formatCurrency(Math.abs(tx.amount || 0)) }}
              </div>
            </li>
          </ul>
        </div>

        <div class="finance-summary">
          <template v-if="store.businessType === 'racingTeam'">
            <div class="summary-item single team-expenses">
              <span class="value cost team-expenses__amount">{{ formatCurrency(operatingCosts.total || 0) }}</span>
              <span class="label team-expenses__label">Team Expenses</span>
              <span v-if="!compact" class="team-expenses__note">FRE's completed in a team vehicle reward the team</span>
            </div>
          </template>
          <template v-else>
            <div class="summary-item single">
              <span class="label">Operating Costs</span>
              <span class="value cost">{{ formatCurrency(operatingCosts.total || 0) }}</span>
            </div>
          </template>
        </div>
      </template>
    </div>
  </div>
</template>

<script setup>
import { computed, ref, onMounted, onUnmounted } from "vue"
import { useBusinessComputerStore } from "../../../stores/businessComputerStore"
import { useBridge, lua } from "@/bridge"
import { formatCurrency } from "../../../utils/businessUtils"

const props = defineProps({
  compact: { type: Boolean, default: false },
  fillHeight: { type: Boolean, default: false },
})

const store = useBusinessComputerStore()
const { events } = useBridge()

const financesData = ref(null)
const loading = ref(true)
const accountBalance = computed(() => financesData.value?.account?.balance || 0)
const transactions = computed(() => financesData.value?.transactions || [])
const operatingCosts = computed(() => financesData.value?.operatingCosts || {})

const sortedTransactions = computed(() => {
  const list = transactions.value
  if (!Array.isArray(list) || !list.length) return []
  return [...list].sort((a, b) => (b.timestamp || 0) - (a.timestamp || 0))
})

const displayTransactions = computed(() => {
  const list = sortedTransactions.value
  if (props.compact && !props.fillHeight) return list.slice(0, 4)
  return list
})

const getTransactionLabel = (tx) => {
  const amount = tx.amount || 0
  if (tx.label) return tx.label
  return amount >= 0 ? "Deposit" : "Withdrawal"
}

const formatTxDate = (timestamp) => {
  if (timestamp == null || timestamp === "") return "—"
  const sec = typeof timestamp === "number" && timestamp > 1e12 ? timestamp / 1000 : Number(timestamp)
  if (!Number.isFinite(sec)) return "—"
  const date = new Date(sec * 1000)
  const now = Date.now()
  const diffMs = now - date.getTime()
  const diffMins = Math.floor(diffMs / 60000)
  const diffHours = Math.floor(diffMs / 3600000)
  const diffDays = Math.floor(diffMs / 86400000)
  if (diffMins < 1) return "Just now"
  if (diffMins < 60) return `${diffMins}m ago`
  if (diffHours < 24) return `${diffHours}h ago`
  if (diffDays < 7) return `${diffDays}d ago`
  return date.toLocaleDateString("en-US", { month: "short", day: "numeric" })
}

const requestFinancesData = async () => {
  if (!store.businessId || !store.businessType) return

  loading.value = true
  try {
    if (store.businessType === "tuningShop") {
      await lua.career_modules_business_tuningShop.requestFinancesData(store.businessId)
    } else {
      await lua.career_modules_business_businessComputer.requestFinancesData(
        store.businessType,
        store.businessId
      )
    }
  } catch (error) {
    loading.value = false
  }
}

const handleFinancesData = (data) => {
  if (!data || !data.success) {
    loading.value = false
    return
  }
  if (String(data.businessId) !== String(store.businessId)) return

  financesData.value = data.finances
  loading.value = false
}

const handleAccountUpdate = (data) => {
  if (!data || !store.businessType || !store.businessId) return
  const accountId = "business_" + store.businessType + "_" + store.businessId
  if (data.accountId === accountId) {
    requestFinancesData()
  }
}

onMounted(() => {
  events.on("businessComputer:onFinancesData", handleFinancesData)
  events.on("bank:onAccountUpdate", handleAccountUpdate)
  if (store.businessId && store.businessType) {
    requestFinancesData()
  }
})

onUnmounted(() => {
  events.off("businessComputer:onFinancesData", handleFinancesData)
  events.off("bank:onAccountUpdate", handleAccountUpdate)
})
</script>

<style scoped lang="scss">
.home-widget {
  background: rgba(30, 30, 30, 0.6);
  border: 1px solid rgba(255, 255, 255, 0.05);
  border-radius: 1em;
  display: flex;
  flex-direction: column;
  overflow: hidden;
  height: 100%;
}

.widget-header {
  padding: 1em 1.25em;
  border-bottom: 1px solid rgba(255, 255, 255, 0.05);
  display: flex;
  justify-content: space-between;
  align-items: center;
  background: rgba(0, 0, 0, 0.2);
  flex-shrink: 0;

  h3 {
    margin: 0;
    font-size: 1.1em;
    font-weight: 600;
    color: #fff;
  }
}

.balance-badge {
  font-size: 1em;
  font-weight: 600;
  color: #2ecc71;

  &.negative {
    color: #e74c3c;
  }
}

.widget-content {
  padding: 0;
  flex: 1;
  display: flex;
  flex-direction: column;
  min-height: 0;
}

.loading-state {
  padding: 2em;
  text-align: center;
  color: rgba(255, 255, 255, 0.5);
}

.ledger-scroll {
  flex: 1;
  min-height: 0;
  overflow-y: auto;
  background: rgba(0, 0, 0, 0.15);
}

.empty-ledger {
  padding: 2em 1.25em;
  text-align: center;
  color: rgba(255, 255, 255, 0.45);
  font-size: 0.9em;
}

.ledger-list {
  list-style: none;
  margin: 0;
  padding: 0.5em 0;
}

.ledger-row {
  display: flex;
  align-items: flex-start;
  justify-content: space-between;
  gap: 0.75em;
  padding: 0.55em 1.25em;
  border-bottom: 1px solid rgba(255, 255, 255, 0.04);

  &:last-child {
    border-bottom: none;
  }
}

.ledger-row__info {
  display: flex;
  flex-direction: column;
  gap: 0.2em;
  min-width: 0;
}

.ledger-row__label {
  font-size: 0.85em;
  color: rgba(255, 255, 255, 0.9);
  line-height: 1.3;
  word-break: break-word;
}

.ledger-row__date {
  font-size: 0.7em;
  color: rgba(255, 255, 255, 0.4);
  text-transform: uppercase;
  letter-spacing: 0.04em;
}

.ledger-row__amount {
  flex-shrink: 0;
  font-size: 0.85em;
  font-weight: 600;
  font-variant-numeric: tabular-nums;

  &.credit {
    color: #2ecc71;
  }

  &.debit {
    color: #e74c3c;
  }
}

.finance-summary {
  padding: 0.75em 1em;
  display: flex;
  flex-direction: column;
  justify-content: center;
  align-items: stretch;
  gap: 0.5em;
  border-top: 1px solid rgba(255, 255, 255, 0.05);
  background: rgba(0, 0, 0, 0.1);
  flex-shrink: 0;
}

.summary-item {
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 0.25em;

  &.single {
    flex: 1;
  }

  .label {
    font-size: 0.7em;
    color: rgba(255, 255, 255, 0.5);
    text-transform: uppercase;
    letter-spacing: 0.05em;
    white-space: nowrap;
  }

  .value {
    font-size: 0.9em;
    font-weight: 600;
    color: #fff;
    white-space: nowrap;

    &.cost {
      color: #f97316;
    }

    &.hint {
      font-size: 0.72em;
      font-weight: 500;
      color: rgba(255, 255, 255, 0.65);
      white-space: normal;
      text-align: center;
      line-height: 1.35;
      max-width: 100%;
    }
  }
}

.racing-finance-hint .label {
  font-size: 0.65em;
}

.team-expenses {
  align-items: flex-start !important;
  gap: 0.15em !important;
  text-align: left;

  .team-expenses__amount {
    font-size: 1.6em !important;
    font-weight: 700 !important;
    color: #f97316 !important;
    line-height: 1.1;
  }

  .team-expenses__label {
    font-size: 0.7em !important;
    color: rgba(255, 255, 255, 0.55) !important;
    text-transform: uppercase;
    letter-spacing: 0.06em;
  }

  .team-expenses__note {
    margin-top: 0.5em;
    font-size: 0.72em;
    font-weight: 500;
    color: rgba(255, 255, 255, 0.6);
    line-height: 1.35;
    white-space: normal;
  }
}

.home-widget--compact {
  min-height: 0;
  height: auto;
  flex-shrink: 0;

  .widget-header {
    padding: 0.42em 0.55em;

    h3 {
      font-size: 0.82em;
    }
  }

  .balance-badge {
    font-size: 0.78em;
  }

  .ledger-scroll {
    max-height: 6.5em;
  }

  .ledger-row {
    padding: 0.35em 0.55em;
  }

  .ledger-row__label {
    font-size: 0.75em;
  }

  .ledger-row__date,
  .ledger-row__amount {
    font-size: 0.7em;
  }

  .finance-summary {
    padding: 0.35em 0.55em;
  }

  .team-expenses .team-expenses__amount {
    font-size: 1em !important;
  }

  .team-expenses .team-expenses__label {
    font-size: 0.62em !important;
  }
}

.home-widget--compact.home-widget--fill {
  flex: 1;
  min-height: 0;
  height: auto;
  flex-shrink: 1;

  .ledger-scroll {
    max-height: none;
    flex: 1;
    min-height: 0;
    overflow-y: auto;
  }

  .finance-summary {
    padding-bottom: 0.5em;
  }
}
</style>
