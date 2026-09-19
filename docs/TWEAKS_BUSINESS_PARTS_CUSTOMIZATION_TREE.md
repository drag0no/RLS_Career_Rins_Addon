# RLS Career: Business Vehicle Parts Customization — Collapsible Tree Menu

## TL;DR — What It Does
- **In-Place Collapsible Tree**: Replaced single-category drill-down root windows with an in-place accordion tree matching the official BeamNG career garage experience.
- **Dedicated Part Selector**: Clicking a slot's installed part badge opens its replacement list, with a `← Back to Vehicle Parts` button that keeps open categories intact.
- **Compact & Clean**: Tightened row spacing and uniform indentation (12px per level) with tree guidelines, avoiding text truncation on deep slots.
- **Quick Controls**: Added "Expand All" and "Collapse All" toolbar buttons.

---

## 1. Motivation

In the Business Computer vehicle part customization menu clicking a category previously pushed it as an isolated root window, wiping the entire view and requiring tedious breadcrumb backtracking.

---

## 2. Key Improvements

- **Collapsible Tree Menu**: Categories with sub-slots expand and collapse in-place with chevrons and counter badges (e.g. `+4`). Top-level assemblies (Body, Engine, Suspension) start open on initial load.
- **Slot Part Customization**: Clicking any slot's installed part badge switches to a focused part selection view with search and an instant back button.
- **Full Compatibility**: Business inventory owned parts (mileage/condition), discount pricing, cart operations, and global vehicle search work seamlessly.

---

## 3. Summary of Files

| File | Type | Changes |
| :--- | :--- | :--- |
| [`BusinessSlotTreeItem.vue`](../ui/ui-vue/src/modules/career/components/businessComputer/BusinessSlotTreeItem.vue) | Vue Component (New) | • In-place expandable/collapsible tree item.<br>• Compact vertical layout and anti-truncation sizing.<br>• Subcategory counter badges (`+N`) and interactive part badges. |
| [`BusinessPartsCustomizationTab.vue`](../ui/ui-vue/src/modules/career/components/businessComputer/BusinessPartsCustomizationTab.vue) | Vue Component | • Switched from root-window navigation to hierarchical slot tree.<br>• Added toolbar with slot counter, "Expand All", and "Collapse All".<br>• Dedicated slot part selection panel with back button.<br>• Auto-expands top-level assemblies on load. |
