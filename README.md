# Expense Splitter

<p align="center">
  <img src="logo.png" width="240" alt="Expense Splitter logo">
</p>

A Flutter app for splitting expenses among friends. Create events, add expenses with equal, unequal, or percentage splits, and let the app calculate who owes whom using smart debt simplification.

## Features

- **User Profiles** — Name + optional phone, stored locally; editable. Log in
  with the same name again and all of that person's events come back
- **Events (Groups)** — Create, rename, and delete events; add members (the
  same friend is one person across every event)
- **Three Split Modes** — Equal, unequal (per-person consumption), and percentage
- **Expense Edit / Delete** — Full edit flow with validation and safe delete confirmation
- **Categories & Notes** — Categorize expenses (Food, Transport, etc.) with optional notes
- **Smart Settlements** — Greedy debt-simplification minimizes payments;
  mark-as-paid with partial payments and undo; "You owe −₹ / owes you +₹" wording
- **Expense History** — Timeline of all expenses and settlements with search + multi-category filtering
- **Insights page** — Totals, category breakdown, paid / share / net per member
- **Indian Rupees** — Every amount in ₹ with Indian digit grouping (₹1,23,456.00)
- **Export & Share** — Share a plain-text or CSV summary of any event
- **Light / Dark Theme** — System, light, or dark mode; persists across sessions
- **Cross-Platform** — Android, iOS, Windows, macOS, Linux, Web

## Design

The UI follows a **"soft & friendly" Material 3** system, defined once in
`lib/theme/app_theme.dart`:

- Design tokens only — no hardcoded colors outside the theme file, so dark
  mode works end-to-end by construction
- Type scale: 32 / 20 / 16 / 13 px at weights 400 + 600; 8 pt spacing grid
  (8 / 16 / 24 / 32); card radius 20, buttons/inputs 16
- Event page = tappable dashboard summary cards (Spent · to settle · your
  balance) + 3 bottom tabs (Settle · Expenses · More); insights open as their
  own page
- Launcher icon + web favicon are generated from `logo.png`

## Tech Stack

| Component | Technology |
|-----------|------------|
| Framework | Flutter 3.38+ / Dart 3.10+ |
| Database | SQLite via sqflite / sqflite_common_ffi |
| Session | SharedPreferences |
| IDs | UUID v4 |
| Sharing | share_plus |
| Design | Material 3 (token-based theming) |

## Getting Started

```bash
# Clone and install
git clone <repo-url>
cd expense-splitter
flutter pub get

# Run on your platform
flutter run -d linux      # Desktop
flutter run -d <device>   # Android/iOS

# Check for issues
flutter analyze
flutter test
```

## Building an APK

```bash
# Release (R8, tree-shaken icons) → ~58 MB
flutter build apk --release
# → build/app/outputs/flutter-apk/app-release.apk

# Debug
flutter build apk --debug
# → build/app/outputs/flutter-apk/app-debug.apk
```

The Android application ID is `com.expensesplitter.app` (v1.0.0 shipped as
`com.example.expense_splitter`, so v1.0.1 installs as a separate app next to
it). Bump `version:` in `pubspec.yaml` for every release — the build number
after `+` must always increase.

Release builds are signed with the debug key (template default). Generate a
real keystore before publishing to the Play Store. APKs are git-ignored:
attach them to a GitHub Release instead of committing them.

### Regenerating the app icon

After editing `logo.png` (any size; white background works best):

```bash
dart run flutter_launcher_icons
```

This rewrites all Android densities (legacy + adaptive), the web favicon, and
the PWA icons. iOS generation is off because the project has no Xcode setup —
flip `ios: true` in `pubspec.yaml` if that changes. Reinstall the app after
regenerating (launchers cache icons).

## Architecture

This project follows a **3-layer architecture**:

```
UI (Pages) → Repository → Database (SQLite)
```

- **Pages** (`lib/pages/`) — StatefulWidgets handling UI and user interaction
- **Repositories** (`lib/repositories/`) — Business logic and SQL operations
- **Database** (`lib/database/`) — SQLite singleton with schema and migrations
- **Utils** (`lib/utils/`) — Pure functions; `balance_calculator.dart` is the one
  place balances and settlements are computed
- **Models** (`lib/models/`) — Plain Dart classes with serialization
- **Theme** (`lib/theme/`) — Design tokens for light and dark modes

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the full architecture
reference, database schema, algorithm documentation, and coding conventions.

## Documentation

| Doc | Contents |
|-----|----------|
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | Architecture, schema, algorithms, conventions |
| [docs/AUDIT-REPORT.md](docs/AUDIT-REPORT.md) | Feature-build audit (findings F1–F10) |
| [docs/UI-REVIEW.md](docs/UI-REVIEW.md) | Ponytail review of the UI redesign |
| [docs/tasks/](docs/tasks/) | Self-contained per-feature task specs |
| [docs/Project Review/](docs/Project%20Review/) | Project review report and the v1.0.1 fix list |

## Contributing (For AI Models & Developers)

Self-contained task files are in [`docs/tasks/`](docs/tasks/). Each task file
contains everything needed to implement one feature. **All ten are implemented**
(shipped in commit `e96a550`); they remain as specs for reference:

| Task | Feature | Priority | Complexity | Status |
|------|---------|----------|------------|--------|
| [TASK-01](docs/tasks/TASK-01-edit-delete-expense.md) | Edit / Delete Expense | High | Medium | ✅ |
| [TASK-02](docs/tasks/TASK-02-delete-group.md) | Delete Group | High | Low | ✅ |
| [TASK-03](docs/tasks/TASK-03-edit-group.md) | Edit Group | Medium | Medium | ✅ |
| [TASK-04](docs/tasks/TASK-04-expense-history.md) | Expense History Timeline | Medium | Low | ✅ |
| [TASK-05](docs/tasks/TASK-05-profile-edit.md) | User Profile Edit | Low | Low | ✅ |
| [TASK-06](docs/tasks/TASK-06-currency-formatting.md) | Currency Formatting | Low | Low | ✅ |
| [TASK-07](docs/tasks/TASK-07-dark-theme.md) | Dark Theme | Low | Low | ✅ |
| [TASK-08](docs/tasks/TASK-08-export-share.md) | Export / Share Summary | Low | Medium | ✅ |
| [TASK-09](docs/tasks/TASK-09-percentage-split.md) | Percentage Split | Medium | Medium | ✅ |
| [TASK-10](docs/tasks/TASK-10-search-filter.md) | Search & Filter | Low | Low | ✅ |

**To assign a task to a small AI model**, just tell it:
> Read the file `docs/tasks/TASK-XX-<name>.md` and implement the feature described in it. Follow the coding conventions in `docs/ARCHITECTURE.md`.

### Coding Conventions

- Models: `lib/models/` — `toMap()`, `fromMap()`, `copyWith()`
- Repos: `lib/repositories/` — constructor takes `AppDatabase`, all SQL here
- Pages: `lib/pages/` — `StatefulWidget`, `_isLoading`/`_errorMessage` pattern
- Files: `snake_case.dart`, Classes: `PascalCase`
- Transactions: `db.transaction((txn) async { ... })` for multi-table ops
- Navigation: `Navigator.push()` with `MaterialPageRoute`, return `true` to signal refresh
- **Design**: no `Colors.*` outside `lib/theme/app_theme.dart`; use
  `ColorScheme` roles (`primary`, `error`, `surfaceContainer*`,
  `onSurfaceVariant`, …); spacing only 8/16/24/32; text styles from the
  token `TextTheme` at weights 400/600
- Before finishing: `flutter analyze` (must report "No issues found!") and
  `flutter test` (all green)

## License

Private project — not published to pub.dev.
