# Developer Storage redesign architecture

Reference: `docs/reference/DeveloperStorage.png`

## Role

Developer Storage answers: **What developer tooling is using space, how reclaimable is it, and which projects or ecosystems drive it?**

Not Safe to Review (generic regenerable junk). Not File Browser. A **developer-storage command center**.

## Current problem

`DeveloperStorageView` is a flat heuristic list of known folder names (`.npm`, `node_modules`, `DerivedData`, …) with “Add to review”. No taxonomy bar, no reclaimable vs keep, no project grouping, no ecosystem rollups, weak explanations.

## Target IA

```
DiskMap sidebar | Header + summary cards + category bar + ecosystems + quick wins + projects/items table | Inspector
```

- Summary: total developer storage, potentially reclaimable, likely active/keep
- Category composition: Dependencies · Caches · Build artifacts · Containers · SDKs & Simulators · Other
- Ecosystem cards (Node, Docker, Xcode, Python, Android, Rust, …)
- Best opportunities (safe / review-first ranked)
- Table tabs: Projects · All items · by category filters
- Contextual inspector (what / why large / can remove / consequences / actions)
- Cleanup only via queue (no Delete on this page)

## Taxonomy

| Category | Examples | Default reclaimability |
|----------|----------|------------------------|
| Dependencies | `node_modules`, Pods, `.venv`, vendor | Review — regenerable with lockfiles |
| Caches | `.npm`, pnpm/yarn/cargo/gradle caches, CocoaPods cache | Safe — tools recreate |
| Build artifacts | DerivedData, `build/`, `.next`, `target/`, `__pycache__` | Safe/Review — regenerable |
| Containers | Docker data, VM disks | Review — volumes may hold data |
| SDKs & Simulators | CoreSimulator, DeviceSupport, Android SDK, rustup | Review / keep — large re-downloads |
| Other | IDE/AI tool dirs (`.cursor`, `.codex`), misc | Review |

Ecosystem is inferred from path/name (Node, Xcode, Docker, Python, Android, Rust, Flutter/Dart, JVM/Gradle, IDE/AI, Other).

## Data correctness

- Reuse `selectedTotals` + existing `FileTree` — **no second scanner**
- Prefer outer directory when nested matches (no double-count ancestor+child)
- Skip firmlink twin shells via same totals already used app-wide
- Safety from `SafetyClassifier`; never invent “safe” without a rule
- Cache catalog after scan on `ScanModel` like Forgotten / Reviewables

## Wire

`.developerStorage` → redesigned `DeveloperStorageView`  
Core: `DeveloperCatalog` in DiskMapCore
