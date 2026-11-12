# Mun or Bust workspace upgrade

This upgrade adds a project hub, engineering reference page, notifications, profile pictures and expanded chat. It preserves the existing account setup, login persistence, tasks, ideas and chat history.

## Activate on the existing site

1. Open your **existing Supabase project → SQL Editor → New query**.
2. Copy the entire contents of **[backend/mission-upgrade.sql](backend/mission-upgrade.sql)**, paste it into the editor, and select **Run**. The script is additive, transactional and rerunnable. It requires the original base and chat schemas already in use. Do not rerun the original schema or files under `tests/fixtures` on your live project.
3. When SQL succeeds, merge this upgrade pull request into `main`. Keep the current `config.js` and GitHub Pages settings. No new API key is required.
4. Wait for GitHub Pages to finish deploying. Reload the site. On an installed PWA, close and reopen it after visiting the updated site once. The service worker uses a new cache version.
5. With two team accounts, create a record assigned to the other person; verify their Notifications page. Send a chat mention using the mention picker. Check a file upload, a poll vote and a mentor review.

The GitHub update alone cannot create Supabase tables. Run the SQL before merging so the new chat search and attachment functions exist when the updated app loads. If SQL fails, its transaction rolls back; copy the error for diagnosis before deploying the new frontend.

## New pages and controls

| Area | What it does |
| --- | --- |
| Requirements | Requirement statement, source, verification method, evidence and related record IDs |
| Research library | Sources, citations, findings and applicability limits |
| Decision log | Alternatives, evaluation criteria, rationale and evidence |
| Engineering budgets | Mass (kg), power (W), energy (Wh), water (L), per-item margins and totals grouped by operating case |
| Meetings & notes | Meeting time, agenda, link, notes and action items that convert atomically into tasks |
| Mentor reviews | Review queue, deliverable link, scope and feedback; mentor/admin-only approval and changes-requested outcomes |
| Submission checklist | Project/final-phase items, owners, dates and evidence/receipt links |
| Design revisions | CAD/document links, new revision uploads and historical file downloads |
| Risk register | Likelihood and impact ratings, score, mitigation and warning trigger |
| Availability polls | Meeting slots stored as UTC instants, displayed in each person's device timezone; yes/maybe/no votes |
| Assumptions ledger | Values/units, sources, validation and impact if wrong |
| Engineering refs | Searchable NASA/NIST/BIPM sources, review/submission guidance and six calculators |
| Notifications | Private assignment/review/mention inbox and dated tasks; optional browser alerts while open |
| Chat | Per-channel unread counts, literal text/author/pin search, crew mention picker, files and mentor/admin pins |
| Profiles | Private PNG/JPEG/WebP avatars shown in profiles, crew and chat |

Every project record supports ownership, status, dates, search, JSON export, archive/restore, revision history and version-conflict protection. Restoring an old snapshot creates a new revision. Archived records remain recoverable. Other active team members can collaborate on project records; mentor/admin review decisions are checked server-side.

## Files and privacy

- Existing drawings remain in `drawings`. New avatars, chat attachments and design revisions use private `mission-files` storage.
- New files are limited to 10 MB. Supported types: PNG, JPEG, WebP, PDF, TXT, CSV, ZIP and generic binary (for example STL when the browser reports it as binary). Unsupported MIME types are rejected by storage. ZIP other CAD formats when necessary.
- Downloads use temporary signed URLs. All active crew can read team files; uploads must go into the uploader's folder. Former/inactive members cannot query new workspace data.
- History retains references to older revision files. Do not manually delete those files if you want old versions to remain downloadable. Failed or abandoned uploads may leave unreferenced files for admin maintenance.
- Browser alerts are opt-in and operate while this page/app is running. **Background push notifications when the app is closed are not configured.** The in-app inbox works without notification permission.
- Login still uses the existing Supabase browser session storage. This update does not store passwords or change keys.
- The service worker caches only the static application shell; it does not cache private Supabase responses. Shared records still require connectivity.

## Engineering reference notes

Sources were checked November 12, 2026. Follow current organizer rules and exact cutoff times, not just calendar dates. Calculator inputs are examples, not mission requirements. Each calculator states units, equations and limitations. Budgets separate operating cases to avoid adding nominal and contingency estimates together.

## Backups and rollback

The original Admin export still covers the original workspace records. A new Admin export saves project records and their revision history. Poll votes, notification history, chat metadata and attachment binaries should be backed up through Supabase along with the rest of the project. JSON downloads are exports, not a one-click restore tool.

To roll back the website, revert this frontend commit in GitHub. The additive database schema can remain installed: old accounts, tasks and chat stay compatible. Do not drop tables containing team work as a rollback shortcut.

## Developer validation

This is still a buildless static site. Node dependencies are **test-only**, not required by GitHub Pages.

```sh
npm install
npm test
npm run check
```

Tests run PostgreSQL through PGlite in memory, using test-only copies of the original base/chat schemas. They cover migration reruns, record/history permissions, stale writes, mentor approval, private notifications, voting, meeting task deduplication, chat search/pins/read cursors/attachments, storage ownership and profile privilege restrictions. Calculator tests cover known outputs, invalid physical inputs and separated budget totals.

Browser QA exercised demo navigation, record creation/history, budget totals, availability voting, chat mentions/pins/search and a calculator. Live Supabase Auth/Storage/Realtime integration and physical iPhone/iPad installation still need the post-deployment checks above; no live team data was changed during development.
