---
name: swiftui-expert-skill
description: Use when writing, reviewing, or refactoring SwiftUI code for iOS or macOS, including state and `@Observable` data flow, view composition, resizable layouts, safe areas, display scale, performance, lists, environment, localization, animation, Liquid Glass, and API migration. Also use for iPhone Duo, foldable, or large-display layouts (`NavigationSplitView` on large displays, iPhone tab sidebar, two-column reflow, foldable grids, `ArrangementView`, `ReservedRegion`), hinge effects, vertical bars, `@State` initialization or synthesized-property diagnostics, `@ContentBuilder` ambiguity, `reorderable` drag/drop, custom `AsyncImage` `URLSession`, swipe actions outside List, item-bound `alert`/`confirmationDialog`, `ToolbarOverflowMenu`, `AnimatableValues`, Document APIs (`Document`/`DocumentReader`), and Instruments `.trace` capture or analysis.
---

# SwiftUI Expert Skill

## Operating Rules

- Treat each `View` type as an invalidation boundary: give it only the data it reads and keep frequently changing dependencies close to the smallest affected subtree
- Search `references/latest-apis.md` when writing, reviewing, or migrating API usage; look up only the APIs relevant to the task
- Replace hard-deprecated APIs with modern equivalents. During feature work, flag soft-deprecated APIs and leave them in place (see `references/soft-deprecation.md`)
- Prefer native SwiftUI APIs over UIKit/AppKit bridging unless bridging is necessary
- Focus on correctness and performance; do not enforce specific architectures (MVVM, VIPER, etc.)
- Encourage separating business logic from views for testability without mandating how
- Follow Apple's Human Interface Guidelines and API design patterns
- Only adopt Liquid Glass when explicitly requested by the user (see `references/liquid-glass.md`)
- Present performance optimizations as suggestions, not requirements
- Use `#available` gating with sensible fallbacks for version-specific APIs
- For layout and rendering inputs, read the value nearest the SwiftUI view that consumes it; do not substitute process-global screen state

## Task Workflow

### Review existing SwiftUI code
- Read the code under review and identify which topics apply
- Flag deprecated APIs (compare against `references/latest-apis.md`); replace hard-deprecated APIs, and flag soft-deprecated APIs without rewriting them unless the user asked to migrate
- Run the Topic Router below for each relevant topic
- Validate `#available` gating and fallback paths for version-specific features
- For broad codebase reviews, first identify smaller focus areas and present them one at a time; if the user requests a whole-codebase review, divide it into a TODO list

### Improve existing SwiftUI code
- Audit current implementation against the Topic Router topics
- Replace hard-deprecated APIs with modern equivalents from `references/latest-apis.md`; flag soft-deprecated APIs and do not rewrite them during feature work
- Refactor hot paths to reduce unnecessary state updates
- Extract complex view bodies into separate subviews
- Suggest image downsampling when `UIImage(data:)` is encountered (optional optimization, see `references/image-optimization.md`)

### Implement new SwiftUI feature
- Design data flow first: identify owned vs injected state
- Structure views for optimal diffing (extract subviews early)
- Apply correct animation patterns (implicit vs explicit, transitions)
- Use `Button` for all tappable elements; add accessibility grouping and labels
- Gate version-specific APIs with `#available` and provide fallbacks

### Topic Router

> Vendored subset: only references present in `references/` are available locally; skip rows whose file is missing. Instruments trace scripts were intentionally not vendored.

Consult the reference file for each topic relevant to the current task:

| Topic | Reference |
|-------|-----------|
| State management | `references/state-management.md` |
| Environment and `@Entry` | `references/environment-patterns.md` |
| View composition | `references/view-structure.md` |
| View modifiers and identity | `references/modifier-patterns.md` |
| Performance | `references/performance-patterns.md` |
| Lists and ForEach | `references/list-patterns.md` |
| Resizable layout, safe areas, two-column reflow, foldable grids, arrangements, and reserved regions | `references/layout-best-practices.md` |
| iPhone Duo, foldable, or large-display screens (read first to choose the technique) | `references/iphone-duo.md` |
| Sheets, navigation, `NavigationSplitView` on large displays, and tab bar/sidebar (`sidebarAdaptable`) | `references/sheet-navigation-patterns.md` |
| ScrollView, scroll position, and scroll geometry | `references/scroll-patterns.md` |
| Focus management | `references/focus-patterns.md` |
| Animations (basics) | `references/animation-basics.md` |
| Animations (transitions) | `references/animation-transitions.md` |
| Animations (advanced) | `references/animation-advanced.md` |
| Accessibility | `references/accessibility-patterns.md` |
| Swift Charts | `references/charts.md` |
| Charts accessibility | `references/charts-accessibility.md` |
| Image optimization and display scale | `references/image-optimization.md` |
| Toolbars | `references/toolbar-patterns.md` |
| Document-based apps | `references/document-apps.md` |
| WebKit | `references/webkit-integration.md` |
| Styled text editing | `references/styled-text-editing.md` |
| Liquid Glass (iOS 26+) | `references/liquid-glass.md` |
| macOS scenes | `references/macos-scenes.md` |
| macOS window styling | `references/macos-window-styling.md` |
| macOS views | `references/macos-views.md` |
| Text patterns | `references/text-patterns.md` |
| Localization | `references/localization.md` |
| Deprecated API lookup | `references/latest-apis.md` |
| Handling soft-deprecated APIs | `references/soft-deprecation.md` |
| Previews | `references/previews.md` |
| Instruments trace analysis | `references/trace-analysis.md` |
| Instruments trace recording | `references/trace-recording.md` |

## Correctness Checklist

These are hard rules -- violations are always bugs:

- [ ] `@State` properties are `private`
- [ ] `@Binding` only where a child modifies parent state
- [ ] Changing parent-owned inputs are not stored as `@State`/`@StateObject`; intentional state seeds are documented as one-time
- [ ] `@StateObject` for view-owned objects; `@ObservedObject` for injected
- [ ] iOS 17+: `@State` with `@Observable`; `@Bindable` for injected observables needing bindings
- [ ] `ForEach` uses stable identity (never `.indices`/`\.offset`; id outlives the view and isn't derived from mutable content)
- [ ] Constant number of views per `ForEach` element; `List` rows are unary
- [ ] No closures stored in custom `@Environment`/`@FocusedValue` keys
- [ ] Custom `@Entry` default values are stable (no `Model()`/`Date()`/`UUID()` expressions)
- [ ] SwiftUI display scale comes from `@Environment(\.displayScale)`, not global screen state
- [ ] Safe-area content does not double-apply `GeometryProxy.safeAreaInsets`
- [ ] `.animation(_:value:)` always includes the `value` parameter
- [ ] `@FocusState` properties are `private`
- [ ] No redundant `@FocusState` writes inside tap gesture handlers on `.focusable()` views
- [ ] Version-specific APIs are gated with `#available` and have sensible fallbacks
- [ ] `import Charts` present in files using chart types
- [ ] Previews use self-contained mock data; no dependency on live services or network
