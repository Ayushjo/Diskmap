# OSS Disk Analyzer — Product & UX Feature Specification
## Master Product Requirements Document (PRD)
### Version 1.0 — Pre-UI/Visual Design

---

# 0. Executive Summary

This document defines the product behavior, information architecture, analysis model, safety model, interaction model, and implementation requirements for a modern open-source macOS disk analysis and cleanup application.

The goal is **not** to build a prettier clone of DiskBuddy.

The goal is to build a disk utility that makes the filesystem understandable.

The core product promise is:

> **See what is using your storage, understand why it is using it, know whether it is safe to remove, and know what to do next.**

The application should preserve advanced filesystem visualization capabilities—Treemap, Sunburst, Flame, Bubbles, Mind Map, Age Map, Top Sizes, folder browser—but those visualizations should support a user's task rather than become the task themselves.

The product should be:

- exceptionally clean
- native-feeling on macOS
- fast
- understandable to non-technical users
- powerful enough for developers
- safe by default
- transparent about why recommendations are made
- keyboard-friendly
- fully navigable without relying on color
- suitable for an OSS project

This document deliberately focuses on **what the product should do and how it should behave**, not the final visual design. UI design should happen after this product model is agreed upon.

---

# 1. Product Philosophy: Explain the Disk, Don't Merely Show It

## Objective

The application should answer six questions for every meaningful storage item:

1. What is it?
2. How large is it?
3. Why is it large?
4. Is its size normal/expected?
5. Can I remove it?
6. What happens if I remove it?

A traditional disk analyzer primarily answers questions 1 and 2.

This product should answer all six.

## Core principle

Every visualization, list, card, recommendation, and inspector should ultimately help the user make a decision.

The application should avoid presenting technical information merely because it is available.

## Product hierarchy

The system should prioritize:

**Understand → Find → Investigate → Decide → Act**

rather than:

**Visualization → Visualization → Visualization → Cleanup**

## Example

Instead of showing:

> `.npm — 3.35 GB`

the application should be able to explain:

> **npm cache — 3.35 GB**  
> Stores downloaded npm packages so future installs can be faster.  
> **Safe to clear:** Yes. npm will recreate the cache when required.  
> **Potential recovery:** 3.35 GB.

## Implementation

Create a central `StorageExplanation` model that can be attached to files/folders:

```text
StorageExplanation
- title
- category
- summary
- whyLarge
- safetyLevel
- removable
- consequences
- recommendedAction
- confidence
- documentationURL
```

The analysis engine produces filesystem facts. A rules/knowledge layer turns those facts into explanations.

## Acceptance criteria

A user selecting any major storage category should be able to understand what it is without opening Finder or searching the web.

---

# 2. Overview Dashboard

## Objective

The first screen should answer:

> "Why is my Mac full?"

within approximately five seconds.

## Required content

The Overview should show:

- total capacity
- used capacity
- available capacity
- percentage used
- high-level storage categories
- largest folders
- largest individual files
- cleanup opportunities
- unusual/important findings
- scan freshness

## Example information hierarchy

```text
Your Mac

220 GB used
25 GB free
90% full

Where is your storage going?

Library       68.4 GB
Downloads     34.2 GB
Developer     21.7 GB
Videos        16.8 GB
Caches        12.6 GB

Largest opportunities

Downloads          34.2 GB
Caches             12.6 GB
iOS Simulators      9.59 GB
```

## Implementation

Create a `StorageSummary` service that aggregates:

```text
Disk
 ├─ capacity
 ├─ used
 ├─ available
 ├─ categories
 ├─ topFiles
 ├─ topFolders
 ├─ cleanupCandidates
 └─ warnings
```

Do not calculate these values independently in multiple UI components.

The summary should come from one canonical analysis snapshot.

## Empty state

Before scanning:

> Scan your Mac to understand where your storage is going.

Primary action:

**Scan This Mac**

## Acceptance criteria

A first-time user can identify the three largest storage consumers without opening a visualization.

---

# 3. Storage Jobs / Task-Oriented Navigation

## Objective

Users should navigate based on what they want to accomplish.

Recommended primary concepts:

### Overview
Understand the whole disk.

### Biggest
Find large files and folders.

### Cleanup
Find removable/reviewable data.

### Explore
Browse and investigate the filesystem.

### Visualize
Use advanced visual representations.

## Why

Users do not naturally think:

> "I need a Flame visualization."

They think:

> "I need to find what is taking 20 GB."

## Implementation

Navigation should map human goals to internal capabilities.

```text
Overview
Biggest
Cleanup
Explore
Visualize
Duplicates
```

The exact final navigation can be decided during UI design, but the conceptual model should remain task-oriented.

## Acceptance criteria

A new user can predict what each primary navigation item does without a tutorial.

---

# 4. Visualization Purpose Labels

## Objective

Every visualization must communicate its purpose in plain language.

Recommended mapping:

| Visualization | User-facing purpose |
|---|---|
| Treemap | Where is the space? |
| Sunburst | How does storage break down? |
| Flame | Where is the hierarchy deepest? |
| Bubbles | What are the largest clusters? |
| Mind Map | How does the filesystem branch? |
| Age Map | What has been forgotten? |
| Top Sizes | What are the biggest items? |
| Folders | Browse storage folder-by-folder |

## Implementation

Each visualization should have:

- human-readable title
- one-line explanation
- optional help tooltip
- context-sensitive subtitle

Example:

> **Storage Map**  
> Every rectangle represents storage. Larger rectangles use more space.

## Important

Do not make users learn visualization terminology before they can use the feature.

The internal component may still be called `TreemapView`; the product should explain what it does.

---

# 5. Visualization Switcher as Secondary Navigation

## Objective

Avoid turning eight visualization types into eight equally important top-level concepts.

## Proposed model

```text
Explore
  ├─ Files
  ├─ Folders
  └─ Visualize
       ├─ Treemap
       ├─ Sunburst
       ├─ Flame
       ├─ Bubbles
       ├─ Mind Map
       └─ Age Map
```

## Implementation

All visualization views should consume the same analysis graph.

Do not make each visualization perform its own filesystem scan.

Architecture:

```text
Filesystem Scanner
       ↓
Normalized File Graph
       ↓
Analysis Snapshot
       ↓
Visualization Adapters
       ├─ Treemap
       ├─ Sunburst
       ├─ Flame
       └─ ...
```

This ensures every visualization agrees about sizes.

---

# 6. Intelligent Treemap

## Objective

Make the treemap useful for exploration rather than visual spectacle.

## Required interactions

- click to zoom
- double click to enter folder
- breadcrumb updates
- hover inspector
- keyboard selection
- focus mode
- search/filter
- file/folder distinction
- zoom out
- reset view

## Example flow

```text
Mac
 ↓
Users
 ↓
Library
 ↓
Application Support
 ↓
Claude
 ↓
claudevm.bundle
```

At every step the visualization should recalculate the visible layout around the selected subtree.

## Implementation

Represent every node with:

```text
id
parentID
name
path
size
logicalSize
kind
modifiedDate
createdDate
children
flags
```

The treemap should render only the current subtree plus context.

## Important UX rule

Do not attempt to display every tiny item with equal visual prominence.

Use thresholds and aggregation:

```text
< 0.1% of current view
```

can be grouped into:

> Other — 420 MB

The user can expand "Other" if necessary.

---

# 7. Breadcrumb / “You Are Here” Navigation

## Objective

Users must never become lost while drilling into a large filesystem.

## Example

```text
Macintosh HD
/
Users
/
username
/
Library
/
Application Support
/
Claude
```

Each segment is clickable.

## Current context

Always display:

- current folder
- current size
- percentage of parent
- path

## Implementation

The breadcrumb should derive from the canonical path model.

Avoid maintaining independent UI navigation state that can become inconsistent with the selected filesystem node.

## Edge cases

Handle:

- symlinks
- aliases
- inaccessible folders
- deleted folders during scan
- renamed folders
- mounted volumes

## Acceptance criteria

From any nested view, the user can return to any ancestor with one click.

---

# 8. Decision-Oriented Inspector Panel

## Objective

Turn the right-side inspector from a metadata dump into an investigation/action panel.

## Inspector structure

### Identity

```text
Claude
14.5 GB
Folder
```

### What is it?

Plain-language explanation.

### What's inside?

Top children.

### Why is it large?

Largest contributors.

### Can I remove it?

Safety classification.

### What happens if I remove it?

Consequences.

### Actions

- Reveal
- Quick Look
- Copy Path
- Focus
- Review
- Cleanup, where appropriate

## Implementation

Create a reusable inspector component:

```text
Inspector
 ├─ Header
 ├─ Explanation
 ├─ Breakdown
 ├─ Safety
 ├─ Metadata
 └─ Actions
```

The inspector should adapt to:

- file
- folder
- cache
- application data
- developer artifact
- duplicate group
- cleanup candidate

---

# 9. “Review Cleanup” Instead of Aggressive Deletion

## Objective

Change cleanup from a destructive-looking operation into a controlled review process.

## Recommended language

Prefer:

- Review cleanup
- Review 12.6 GB
- Potential recovery
- Clear cache
- Move to Trash

Avoid making:

> Delete

the default action.

## Cleanup flow

```text
Candidate
 ↓
Explain
 ↓
Review
 ↓
Select
 ↓
Confirm
 ↓
Trash/Delete
 ↓
Verify recovered space
```

## Safety

Never silently delete files.

For potentially destructive operations:

- show exact items
- show total size
- explain consequences
- require confirmation
- provide undo/recovery where technically possible

---

# 10. Safety Classification System

## Objective

Give users confidence before touching unfamiliar filesystem data.

## Levels

### Green — Safe to review/remove

Examples:

- disposable caches
- temporary files
- stale package caches
- known generated artifacts

### Yellow — Review first

Examples:

- Downloads
- old videos
- archives
- application data
- development artifacts

### Red — Protected / Do not manually remove

Examples:

- system-critical files
- boot files
- protected OS structures
- unknown application databases
- files whose removal could cause data loss

## Important

Safety should never be based solely on filename.

Use:

- path
- file type
- ownership
- application association
- known cache conventions
- system protection flags
- dependency knowledge
- application state

## Model

```text
SafetyAssessment
- level
- reason
- consequences
- recommendedAction
- confidence
- reversible
```

## Acceptance criteria

Every automated cleanup recommendation must explain why it is classified as safe or unsafe.

---

# 11. Human Explanations for Technical Folders

## Objective

Make technical directories understandable.

Examples:

- `.npm`
- `.cache`
- `.nvm`
- `.codex`
- `.cursor`
- `DerivedData`
- simulator data
- application support
- browser caches

## Example

```text
.npm
3.35 GB

What is this?

npm's local package cache.

Why does it exist?

It keeps downloaded packages so npm can reuse them.

Can I clear it?

Yes.

What happens?

npm will download packages again when necessary.

Potential recovery:
3.35 GB
```

## Implementation

Create a knowledge/rules registry.

Example conceptual rule:

```text
Path pattern:
~/.npm

Category:
Developer Cache

Explanation:
...

Safety:
SafeToClear

Action:
ClearCache
```

Rules should be versioned and tested.

Unknown paths should never receive a confident explanation.

---

# 12. Universal “Why Is This So Big?” Investigation

## Objective

Every major folder should be explainable recursively.

## Example

```text
Claude
14.5 GB

Why?

claudevm.bundle      12.2 GB
Application data      1.7 GB
Cache                  420 MB
Other                  180 MB
```

The user can continue asking:

> Why is `claudevm.bundle` 12.2 GB?

The system responds with the next breakdown.

## Implementation

Build a recursive explanation generator:

```text
explain(node):
    identify node
    rank children
    detect known categories
    produce explanation
    calculate dominant contributors
```

The output should be deterministic where possible.

Do not rely on generative AI for core filesystem facts.

AI can improve wording, but the underlying numbers and safety decisions must come from deterministic analysis.

---

# 13. Storage Stories

## Objective

Convert raw measurements into short, useful narratives.

## Example

### Your Downloads folder is large

**34.2 GB**

The largest items are several videos, including a 5.02 GB file that has not been modified in about a year.

**Potential review:** 27 GB

[Review Downloads]

## Story types

- unusually large folder
- unusually old data
- large removable cache
- duplicate-heavy folder
- developer storage growth
- many huge files
- recently grown folder
- nearly full disk
- unusually deep hierarchy

## Implementation

A rules engine evaluates:

```text
size
shareOfDisk
shareOfParent
age
fileTypes
knownCategory
duplicatePotential
growth
```

and selects only a small number of high-value stories.

## Important

Never overwhelm the user with 20 stories.

Show the most important 3–5.

---

# 14. Biggest Files as a First-Class Workflow

## Objective

Make it trivial to find individual files responsible for large amounts of storage.

## Required features

- sort by size
- filter by file type
- size thresholds
- path
- modified date
- last access date where available
- Quick Look
- Reveal
- Copy Path
- selection
- multi-select
- cleanup review

## Example filters

```text
All
Videos
Archives
Documents
Images
Developer
Applications

>100 MB
>500 MB
>1 GB
>5 GB
```

## Implementation

The scanner should maintain a top-K structure rather than sorting millions of files repeatedly.

For example:

```text
max heap / bounded priority queue
```

can maintain the largest N files during scanning.

---

# 15. Focus Mode

## Objective

Remove unrelated visual information so the user can investigate one subtree.

## Behavior

When the user selects:

> Library — 68.4 GB

and activates Focus:

- selected subtree becomes primary
- unrelated nodes disappear or become heavily subdued
- header changes to current context
- breadcrumb remains visible
- escape returns to previous context

## Animation

The selected region should smoothly expand into the available visualization area.

## Keyboard

Recommended:

```text
Enter / Space → Focus
Esc → Exit Focus
Backspace → Parent
```

## Acceptance criteria

A complex filesystem visualization should become understandable after focusing on one folder.

---

# 16. Age Map → Forgotten Files

## Objective

Turn file age into an actionable cleanup workflow.

Instead of asking:

> How old are these bytes?

the product should ask:

> What have you forgotten?

## Age buckets

Example:

```text
Last 7 days
8–30 days
1–3 months
3–12 months
1–2 years
2+ years
```

## Interactions

Clicking:

> 3–12 months — 48.1 GB

should open a ranked list of those files.

## Filters

- age
- size
- file type
- location

## Important technical limitation

File access times can be unreliable or disabled depending on filesystem behavior and macOS settings.

Prefer clearly defined timestamps:

- modified
- created

If access-time information is unavailable or unreliable, say so.

---

# 17. Clear Information Architecture

## Recommended conceptual architecture

```text
APP
│
├── Overview
│
├── Biggest
│   ├── Files
│   └── Folders
│
├── Cleanup
│   ├── Safe to Review
│   ├── Caches
│   ├── Large Files
│   ├── Forgotten Files
│   └── Duplicates
│
├── Explore
│   ├── Files
│   ├── Folders
│   └── Search
│
└── Visualize
    ├── Treemap
    ├── Sunburst
    ├── Flame
    ├── Bubbles
    ├── Mind Map
    └── Age Map
```

## Principle

Users should be able to accomplish common tasks without ever entering the visualization area.

Advanced users can use visualization when they want it.

---

# 18. Visual Design System Direction

## Objective

Achieve a cleaner aesthetic than the reference product without adding visual noise.

## Design direction

Target:

> Native macOS + modern developer tool + editorial clarity.

Avoid:

- excessive gradients
- neon colors
- excessive glass
- unnecessary 3D
- giant shadows
- excessive rounded cards
- decorative animation

## Base principles

- high readability
- generous whitespace
- strong hierarchy
- subtle borders
- minimal chrome
- consistent alignment
- predictable controls

The visualizations themselves can provide richness.

---

# 19. Semantic Color System

## Objective

Color should communicate meaning, not merely decorate the interface.

Recommended semantic categories:

### Neutral

Normal filesystem information.

### Blue

Informational.

### Green

Safe / healthy / recoverable.

### Amber

Needs review.

### Red

Danger / destructive / attention.

### Purple

Optional developer/system ecosystem grouping.

## Accessibility

Never communicate a state through color alone.

Example:

```text
🟢 Safe
```

should also say:

> Safe to clear

Do not rely on:

> green = safe

alone.

---

# 20. Numeric Hierarchy

## Objective

Make storage numbers immediately scannable.

## Priority

Largest number:

> **68.4 GB**

Supporting information:

> 58% of parent

Metadata:

> 5,342,235 files

## Formatting rules

Use sensible units:

```text
950 KB
1.2 MB
68.4 GB
1.02 TB
```

Avoid unnecessary precision.

Do not show:

> 68.438271 GB

unless the user specifically requests exact values.

## Consistency

All parts of the application should use one formatting utility.

---

# 21. Progressive Disclosure

## Objective

Expose complexity only when needed.

## Levels

### Level 1

> Mac is 90% full.

### Level 2

> Library is 68.4 GB.

### Level 3

> Application Support is 40.2 GB.

### Level 4

> Claude is 14.5 GB.

### Level 5

> claudevm.bundle is 12.2 GB.

### Level 6

> Explanation and safety details.

## Rule

Do not make the user understand level 6 to accomplish level 1.

---

# 22. “Explain My Storage”

## Objective

Provide a single high-level explanation of the user's storage state.

## Example

```text
Your Mac has 25 GB free.

Your largest storage consumers are:

1. Library — 68.4 GB
2. Downloads — 34.2 GB
3. Developer — 21.7 GB

We found several areas worth reviewing:

12.6 GB caches
34.2 GB downloads
5.77 GB untouched for 1–2 years
```

## Implementation

This should use deterministic analysis results.

Generate:

- summary
- top consumers
- unusual findings
- cleanup opportunities
- warnings

The system must not invent facts.

---

# 23. Command Palette

## Objective

Give power users extremely fast access to actions.

Suggested shortcut:

```text
⌘K
```

## Commands

```text
Find files larger than 1 GB
Find files older than 1 year
Show Downloads
Show caches
Show duplicates
Show biggest folders
Show videos
Show archives
Show developer storage
Scan again
Open settings
```

## Implementation

Represent commands as structured actions:

```text
Command
- id
- title
- keywords
- icon
- action
- arguments
```

Some commands open filters rather than directly executing destructive actions.

Example:

> Clear npm cache

should open the review state, not immediately delete.

---

# 24. Natural-Language / Semantic Search

## Objective

Let users describe what they want in normal language.

Examples:

```text
videos larger than 500 MB
large files in Downloads
files older than 2 years
node cache
things I can safely delete
```

## Implementation strategy

Do not start with a fully autonomous AI system.

Build a query parser for structured intents:

```text
type = file/folder
size > X
age > Y
extension = mp4
path = Downloads
category = cache
safety = removable
```

Example:

```text
"videos larger than 500 MB"

→ kind=file
→ type=video
→ size>500MB
```

AI can be added later for more complex language, but parsed constraints should be visible to the user.

---

# 25. Developer Storage Mode

## Objective

Provide a dedicated experience for developers.

## Categories

Potential categories:

- Xcode
- DerivedData
- simulators
- npm
- pnpm
- yarn
- node_modules
- Python environments/caches
- Rust/Cargo
- CocoaPods
- Gradle
- Android SDK/emulators
- Docker-related data
- IDE caches
- AI coding tool data

## Example

```text
Developer Storage
21.7 GB

Xcode                 9.6 GB
Node / npm            6.2 GB
Caches                2.5 GB
Claude                1.8 GB
Other                 1.6 GB
```

## Safety

Developer cleanup requires dependency awareness.

For example, deleting a cache may be safe; deleting an SDK or active project environment may not be.

Every recommendation needs an explanation.

---

# 26. Duplicates Workflow

## Objective

Make duplicate discovery a dedicated, understandable task.

## Dashboard

```text
Potentially recoverable

17.4 GB
```

Break down:

```text
Exact duplicates      8.2 GB
Similar images        4.1 GB
Duplicate videos      5.1 GB
```

## Exact duplicate detection

Use content hashes.

Efficient pipeline:

```text
size
 ↓
small hash / chunk
 ↓
full cryptographic hash
 ↓
duplicate groups
```

Do not hash every byte of every file unnecessarily if sizes already differ.

## Safety

Never automatically select the only copy.

For duplicate groups:

- identify all copies
- show paths
- show modified dates
- allow user to choose keeper
- recommend conservatively

---

# 27. “Why Is My Mac Full?” Storage Stories / Recommendations Engine

## Objective

Create a recommendation layer above raw analysis.

## Recommendation categories

### High impact

Large reclaimable amount.

### High confidence

Known safe cleanup.

### High relevance

Directly explains abnormal usage.

### Low confidence

Should not be presented aggressively.

## Recommendation score

Conceptually:

```text
score =
    impact
  × confidence
  × relevance
  × safety
```

The exact formula can be tuned experimentally.

## Example

```text
Review npm cache
2.1 GB

High confidence
Safe to clear
```

should rank above:

```text
Review old project folder
3.0 GB

Unknown importance
```

even though the project folder is larger.

---

# 28. Storage Health / Capacity State

## Objective

Make disk capacity understandable at a glance.

## States

Example:

```text
<70%     Healthy
70–85%   Getting full
85–95%   Low space
>95%     Critical
```

These thresholds should be configurable and should not be presented as medical-like certainty.

## Behavior

At high usage:

> Your disk is nearly full.

Then immediately provide the highest-value actions.

Do not use fear-based messaging.

---

# 29. Scan Experience

## Objective

Make scanning transparent and reassuring.

## Suggested stages

```text
Analyzing your Mac

✓ Reading filesystem
✓ Calculating folder sizes
✓ Grouping file types
→ Finding large files
→ Detecting cleanup candidates
```

## Technical requirements

Scanning should:

- be cancellable
- tolerate permission failures
- tolerate files disappearing during scan
- avoid freezing the UI
- report progress where meaningful
- support incremental updates

## Architecture

Use a background scanner:

```text
Scanner Thread/Task
        ↓
Event Stream
        ↓
Analysis Store
        ↓
UI
```

The UI should not wait for the entire filesystem traversal before displaying anything.

---

# 30. Micro-interactions and Spatial Navigation

## Objective

Make navigation feel physical and understandable.

## Example

When clicking:

> Library — 68.4 GB

the selected region can expand while surrounding regions recede.

When navigating back:

> Library → Home

the previous context should visually return.

## Principles

Animations should:

- communicate continuity
- indicate hierarchy
- never block interaction
- be short
- respect Reduce Motion

## Accessibility

If macOS Reduce Motion is enabled:

- use fades or instant transitions
- avoid large spatial movement

---

# 31. Search and Filtering System

## Objective

Make millions of files manageable.

## Required filters

- name
- extension
- size
- date
- path
- category
- safety
- duplicate state

## Filter chips

Example:

```text
Videos
>500 MB
Older than 1 year
Downloads
```

Each filter must be removable independently.

## Implementation

Filtering should happen against indexed metadata where possible.

Do not repeatedly traverse the entire filesystem for every keystroke.

---

# 32. File/Folder Detail Model

## Objective

Ensure every object has consistent metadata.

## File model

```text
File
- id
- name
- path
- parent
- size
- logicalSize
- allocatedSize
- type
- extension
- created
- modified
- accessed (if reliable)
- permissions
- owner
- flags
- symlinkTarget
- category
- safety
```

## Folder model

```text
Folder
- id
- path
- aggregateSize
- fileCount
- folderCount
- children
- category
- safety
```

## Important

Different filesystem concepts should not be collapsed incorrectly.

For example:

- logical size
- allocated size
- compressed size

can differ.

The UI should explain the difference when it matters.

---

# 33. Accessibility and Understandability

## Objective

The application must be usable without relying on visual intuition alone.

## Requirements

- keyboard navigation
- VoiceOver labels
- sufficient contrast
- focus indicators
- Reduce Motion support
- no color-only state
- readable text
- tooltips for unfamiliar controls
- predictable tab order
- large enough hit targets

## Visualization accessibility

Complex visualizations need alternative representations.

For example, if a treemap is selected:

> Selected: Downloads, 34.2 GB, 15.5% of disk.

The user should also be able to switch to a list/table representation.

## Principle

Every visual insight should have a textual equivalent.

---

# 34. “Do Not Touch” Protection and Safe Actions

## Objective

Prevent users from accidentally damaging their system.

## Protected behavior

The cleanup engine should have explicit policies for:

- system files
- protected folders
- active application data
- files required by running services
- mounted volumes
- cloud placeholders
- permission-restricted locations

## Action levels

### Informational

No mutation.

### Review

User explicitly chooses items.

### Move to Trash

Reversible through Finder.

### Permanent deletion

Requires an additional explicit confirmation and should be used sparingly.

## Important

The product should prefer:

> Move to Trash

over:

> Permanently Delete

where possible.

---

# 35. Signature Feature: “Explain My Mac” / Storage Assistant

## Objective

Combine the entire analysis system into one signature experience.

This is the feature that differentiates the product from a conventional disk analyzer.

## Entry point

A primary action such as:

> Explain My Storage

## Output

```text
Your Mac

220 GB used
25 GB free

Here's what's taking up the most space:

Library
68.4 GB
Mostly application support and developer data.

Downloads
34.2 GB
Several very large videos and archives.

Developer
21.7 GB
Mostly Xcode, node tooling, and development data.

You could review:

12.6 GB of caches
9.59 GB of simulator data
Several files larger than 1 GB
```

## Each statement is actionable

Example:

> 12.6 GB of caches

[Review caches]

The user should never reach a dead end.

## Implementation

This is an orchestration layer over:

- storage summary
- filesystem classification
- safety engine
- age analysis
- duplicate engine
- top-K files
- developer detector
- recommendation engine

Architecture:

```text
                    ┌───────────────┐
                    │ Explain My Mac│
                    └───────┬───────┘
                            ↓
                 Recommendation Engine
                            ↓
       ┌────────────┬──────┼──────┬─────────────┐
       ↓            ↓      ↓      ↓             ↓
    Storage       Age   Duplicates Safety    Developer
    Analysis    Analysis  Engine    Engine     Engine
       └────────────┴──────┼──────┴─────────────┘
                           ↓
                   Explainable Results
```

## Non-negotiable rule

The assistant may improve explanations, but it must never invent:

- file sizes
- file paths
- deletion safety
- dependencies
- recovery amounts

All facts must originate from the analysis engine.

---

# 36. Cross-Cutting Product Architecture

Although the requested feature list is complete at 35 core product requirements, several engineering systems are required underneath them.

## Canonical filesystem graph

Everything should derive from one graph.

```text
Root
 ├─ Folder
 │   ├─ Folder
 │   └─ File
 └─ Folder
```

## Analysis snapshot

Every scan produces a versioned snapshot:

```text
ScanSnapshot
- scanID
- timestamp
- volumeID
- filesystem
- capacity
- nodes
- analysisVersion
```

This allows different views to remain consistent.

## Event-driven updates

The UI should consume analysis events:

```text
ScanStarted
FolderDiscovered
FileDiscovered
FolderSizeUpdated
AnalysisCompleted
ScanCancelled
PermissionDenied
```

---

# 37. Performance Requirements

## Primary objective

The application must feel fast even when scanning millions of files.

## Requirements

- scanning must be asynchronous
- UI must remain responsive
- analysis should stream results
- top-K structures should avoid huge sorts
- repeated calculations should be cached
- visualization layouts should use current subtree only
- expensive hashes should be deferred until duplicate analysis
- metadata should be indexed

## Memory

Do not blindly retain enormous per-file objects if the scan contains tens of millions of files.

Consider:

- compact structs
- memory-mapped indexes
- SQLite or another local index
- incremental aggregation
- on-demand metadata loading

---

# 38. Permissions Model

## Objective

Make permission failures understandable.

Instead of:

> Permission denied

show:

> Some protected folders could not be analyzed.

[Grant Full Disk Access]

Explain why it is useful and what data the permission enables.

Do not imply that the application requires more access than it actually does.

---

# 39. Filesystem Correctness

## Objective

Numbers must be trustworthy.

The analyzer should distinguish:

- logical size
- allocated size
- compressed size
- sparse file behavior
- hard links
- symlinks
- aliases
- APFS clones
- cloud placeholders where detectable

## Hard links

Avoid double-counting the same underlying inode where appropriate.

## Symlinks

Do not recursively follow symlinks by default in a way that causes cycles or double counting.

Represent:

> Symbolic link → target

and allow controlled inspection.

---

# 40. Incremental / Cached Scanning

## Objective

Avoid rescanning everything unnecessarily.

## Model

First scan:

```text
Full filesystem scan
```

Later:

```text
Incremental scan
```

Use filesystem change notifications where reliable, plus periodic validation.

## Important

Never assume a notification system guarantees complete historical correctness.

The application should occasionally validate cached state against the filesystem.

---

# 41. Cleanup Transaction Model

## Objective

Make cleanup operations safe and auditable.

## Proposed transaction

```text
Selection
 ↓
Preflight
 ↓
Show exact files
 ↓
Confirm
 ↓
Move to Trash
 ↓
Record operation
 ↓
Show recovered/estimated space
```

## Preflight checks

Before deletion:

- file still exists
- path still matches
- permissions still allow operation
- file has not changed unexpectedly
- item is not protected
- item is not the target of a changed symlink

## Operation log

Record:

```text
timestamp
items
paths
sizes
operation
result
```

This is valuable for debugging and user trust.

---

# 42. Empty, Error, and Partial-Data States

Every major screen should handle:

### No scan

> Scan your Mac to begin.

### Scanning

> Analyzing...

### Partial scan

> Some protected locations could not be analyzed.

### Permission error

> Additional permission is required to inspect this location.

### Empty result

> No files match these filters.

### File disappeared

> This item no longer exists.

### Stale result

> This result was calculated during the previous scan.

The product should never silently present stale or incomplete data as current.

---

# 43. Search Result Explainability

When a user searches:

> files older than 2 years

show:

```text
Showing:
Age > 2 years
```

If the parser interpreted:

> big videos in Downloads

as:

```text
Type: Video
Location: Downloads
Size: Large
```

show those constraints as editable chips.

This makes natural-language search trustworthy.

---

# 44. User Trust Principles

The product should establish these rules:

1. Never hide destructive consequences.
2. Never fabricate explanations.
3. Never claim a file is safe without a reason.
4. Never silently delete.
5. Always show the path of an item being acted upon.
6. Clearly distinguish scan results from recommendations.
7. Clearly distinguish facts from interpretations.
8. Prefer reversible actions.
9. Respect macOS permissions.
10. Make the OSS implementation inspectable.

---

# 45. Recommended Development Order

Do not implement all features simultaneously.

## Phase 1 — Foundation

Build:

- filesystem scanner
- canonical node graph
- storage calculations
- permissions handling
- file/folder models
- scan progress
- basic search
- top-K calculations

## Phase 2 — Core exploration

Build:

- Overview
- Biggest Files
- Biggest Folders
- Folder browser
- Inspector
- breadcrumbs
- filtering

## Phase 3 — Visualization

Build:

- Treemap
- Sunburst
- Flame
- Bubbles
- Mind Map
- Age Map

All should consume the same graph.

## Phase 4 — Intelligence

Build:

- folder explanations
- safety classification
- storage stories
- recommendations
- Explain My Storage
- developer storage detection

## Phase 5 — Cleanup

Build:

- cleanup review
- caches
- duplicates
- forgotten files
- Trash integration
- transaction logging

## Phase 6 — Power-user experience

Build:

- command palette
- natural language search
- advanced filters
- keyboard navigation
- automation/incremental scanning

---

# 46. Suggested Internal Module Architecture

```text
App
│
├── Scanner
│   ├── FileScanner
│   ├── MetadataReader
│   ├── PermissionManager
│   └── ChangeMonitor
│
├── StorageModel
│   ├── FileNode
│   ├── FolderNode
│   ├── Volume
│   └── ScanSnapshot
│
├── Analysis
│   ├── SizeAnalyzer
│   ├── AgeAnalyzer
│   ├── TypeAnalyzer
│   ├── DuplicateAnalyzer
│   ├── DeveloperAnalyzer
│   └── CategoryAnalyzer
│
├── Knowledge
│   ├── FolderRules
│   ├── CacheRules
│   ├── DeveloperRules
│   └── SafetyRules
│
├── Recommendations
│   ├── RecommendationEngine
│   ├── StoryGenerator
│   └── ExplainStorage
│
├── Cleanup
│   ├── CleanupCandidates
│   ├── Preflight
│   ├── TrashManager
│   └── OperationLog
│
├── Search
│   ├── Index
│   ├── FilterEngine
│   └── QueryParser
│
└── UI
    ├── Overview
    ├── Biggest
    ├── Cleanup
    ├── Explore
    ├── Visualize
    └── Inspector
```

---

# 47. Data Flow

The complete product should conceptually work like this:

```text
Filesystem
    ↓
Scanner
    ↓
Raw Metadata
    ↓
Canonical File Graph
    ↓
Aggregations
    ↓
Specialized Analysis
 ┌──────┬──────┬──────┬──────┬──────┐
 ↓      ↓      ↓      ↓      ↓      ↓
Size   Age   Type  Duplicate Safety Developer
 └──────┴──────┴──────┴──────┴──────┘
                ↓
       Recommendation Engine
                ↓
       Explainable Findings
                ↓
        ┌───────┴────────┐
        ↓                ↓
      Human UI      Visualization
```

This separation is critical.

The UI should not become responsible for filesystem intelligence.

---

# 48. Product Success Metrics

Even an OSS application should define success.

## Comprehension

Can users identify the largest storage consumer quickly?

## Discovery

How long does it take to find a 1 GB+ file?

## Safety

How often do users understand why an item is safe/review-required?

## Cleanup

How much space can users recover without confusion?

## Navigation

Can users move from root to a deeply nested folder and return easily?

## Performance

Does the UI remain responsive during scanning?

## Trust

Do users understand what the application is recommending and why?

---

# 49. What NOT to Build

The product should deliberately avoid:

### Visualization overload

Do not make every possible graph a primary feature.

### AI everywhere

Do not use an LLM for deterministic filesystem facts.

### Automatic deletion

Never make aggressive cleanup the product's identity.

### Mystery recommendations

Every recommendation needs a reason.

### Excessive modal dialogs

Prefer inline review flows.

### Excessive onboarding

The UI should explain itself.

### Decorative complexity

A storage utility should feel calm.

---

# 50. Final Product Definition

The application should ultimately feel like this:

> **A map of your Mac that can explain itself.**

A user opens it and sees:

```text
Your Mac
220 GB used
25 GB free

You're using 90% of your storage.

Largest consumers:
Library          68.4 GB
Downloads        34.2 GB
Developer        21.7 GB

Worth reviewing:
Caches            12.6 GB
Simulator data     9.59 GB
Large downloads   27+ GB

[Explain My Storage]
```

They click:

> Library

and the application explains:

```text
Library
68.4 GB

Application Support
40.2 GB

Developer
15.8 GB

Caches
7.29 GB
```

They click:

> Claude

and get:

```text
Claude
14.5 GB

Most of the space is:
claudevm.bundle
12.2 GB

What is it?
Virtual-machine/application data.

Can I delete it?
Review first.

Why?
It may be required by the application.
```

They click:

> Downloads

and get:

```text
Downloads
34.2 GB

You have several very large videos.

Largest:
5.02 GB
Modified ~1 year ago

[Quick Look]
[Reveal]
[Review cleanup]
```

They click:

> Caches

and get:

```text
Caches
12.6 GB

Potentially removable
High confidence

[Review 12.6 GB]
```

That is the experience we should build.

---

# 51. Final Design Principle

The most important sentence in this entire specification is:

> **DiskBuddy shows the user their storage. This application should help the user understand their storage.**

The visualizations remain important.

The difference is that the application builds an intelligence and explanation layer around them.

The final product should make a filesystem containing millions of files feel simple:

**What is taking space?**

**Why?**

**Is it normal?**

**Can I remove it?**

**How much can I recover?**

**What should I do next?**

If every major interaction answers one of those questions, the application will be substantially more useful—not merely more beautiful.
