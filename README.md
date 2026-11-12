# Mun or Bust — Mission Control

A GitHub Pages-ready PWA for your NASA Moon base design challenge team. Static HTML/CSS/JavaScript with Supabase providing authenticated, private collaboration. No build step required.

## Included

- Mission dashboard and individual assignments.
- All ten NASA milestones supplied by Cabot, November 7, 2026–May 6, 2027. All-day dates preserve the supplied calendar day across timezones. Exact submission cutoffs were not supplied; confirm them before submitting.
- Task board with owners, priority, status, timed or all-day deadlines, search, and calendar export.
- Idea feed, discipline tags, comments, image/PDF attachments (5 MB), and finger/stylus/mouse sketch pad.
- Individual member, mentor and admin profiles; invite-only email/password registration and password reset.
- Admin authorization list, membership deactivation, role management and JSON record exports.
- iPhone home-screen icon, standalone display and an offline application shell.
- Clearly labeled demo: changes exist only in memory and reset on reload. Demo access never exposes live team data.

## What still needs setup

The source is complete, but it is not deployed to your GitHub account and no Supabase project has been provisioned. Live authentication, email delivery, database policies and upload persistence must be tested against your project. The demo can be explored before setup.

GitHub Pages serves the interface; Supabase stores team records and private files. The interface's source code is public when deployed on public Pages, but records require an active authorized account. Never put private team documents into the repository.

## 1. Create the backend

1. Create a new project at https://supabase.com/dashboard . Use a dedicated project for this one team.
2. In SQL Editor, run `backend/schema.sql` once. This creates tables, row-level security, invite-only signup, membership functions and the private `drawings` bucket.
3. Run `backend/milestones.sql`. It inserts all ten supplied milestones. It is safe to rerun and preserves existing edits.
4. Authorize your first admin by running the following, replacing the example with YOUR lowercase email:

   ```sql
   insert into public.invites(email,role)
   values ('your-email@example.com','admin');
   ```

5. In Authentication settings, enable email/password signup and keep email confirmation enabled. Signup must stay enabled because the database invite list controls who may register. Choose a minimum password length of at least 10.
6. Configure your project's email delivery/SMTP for confirmation and password-reset emails to all teammates. Test actual delivery; the provider's built-in email service may restrict recipients and throughput.
7. Copy the project URL and **public anon key** (or supported publishable key) into `config.js`:

   ```js
   window.MUN_CONFIG = {
     supabaseUrl: 'https://YOUR-PROJECT.supabase.co',
     supabaseAnonKey: 'YOUR-PUBLIC-ANON-KEY'
   };
   ```

   These are public client values. **Never use a service_role key, secret key, database password, or personal access token.** Access enforcement happens in the database, not by hiding the client key.

## 2. Deploy on GitHub Pages

1. Create a repository named `mun-or-bust` (or any preferred name).
2. Extract the ZIP and upload the **contents** of its `mun-or-bust` folder to the repository root. `index.html` must be at the root, not inside an extra nested folder. Include `.github/workflows/pages.yml`; dot folders may be hidden by your file manager. Git or GitHub Desktop reliably includes it.
3. Commit to `main`.
4. Open repository **Settings → Pages → Build and deployment → Source → GitHub Actions**.
5. Open **Actions**, select **Deploy GitHub Pages**, and use **Run workflow** if the initial push happened before Pages was enabled.
6. Open the URL reported by the completed Pages deployment. Relative asset paths support repository subpaths and custom domains.
7. In Supabase **Authentication → URL Configuration**, set Site URL to that exact HTTPS Pages URL, including the repository path and trailing slash. Add the same URL to allowed Redirect URLs. Update these settings if your domain changes.
8. On the deployed site, enter your authorized admin email and a new password, select **Activate invited account**, confirm the email, then sign in.

Alternative without Actions: publish `main` / `(root)` in Pages settings. An empty `.nojekyll` is included. This serves repository files, including setup documentation; do not commit secrets.

## 3. Bring your crew aboard

In **Admin**, authorize each of the five students' emails and your mentor's email. Assign `mentor` to the mentor and `admin` only to people who should control access. Share the site URL yourself; the authorize button does not send email. Each person activates their own account, confirms their email, and fills in **My profile**.

- All active members and the mentor may read team records, create/update/delete tasks, share ideas, comment, and view drawings.
- Idea authors can edit/delete their own ideas and delete their own comments. Admins may moderate all ideas and comments.
- Only admins can view authorized emails and manage roles or membership.
- Members cannot promote themselves by modifying profile data or making direct API calls.
- Removing an email authorization prevents future registration; deactivate the profile separately to stop existing access.
- Admins cannot demote/deactivate themselves. Have another admin do it. The last active admin cannot be removed.
- Deactivation blocks new database/storage requests. Already displayed/downloaded material cannot be recalled; issued file links expire after five minutes.

## 4. Install on an iPhone

Open the deployed HTTPS URL in Safari → Share → Add to Home Screen → enable **Open as Web App** if offered → Add. Launch the icon and sign in. The standalone app may maintain a separate session from Safari.

The cached shell can open offline, but live accounts, files and collaboration require a connection. There is no offline edit queue, push notification service, or simultaneous whiteboard editing. Shared changes load after your saves and when you choose Refresh. Drawings are saved snapshots. Calendar exports are one-time downloads, not live subscriptions; import into your calendar and configure reminders there.

## Local demo

From this folder run `python3 -m http.server 8080`, open `http://localhost:8080`, and select **Explore demo workspace**. Use an HTTP server; opening `index.html` directly as a file is not a supported PWA test.

## Operations and backups

- Use Admin → Export records for JSON metadata. This does not export uploaded binary files or passwords. Back up private files through Supabase Storage and database backups separately.
- Deleted idea records leave their uploaded files in storage for manual cleanup/recovery. Remove unreferenced files from the bucket when appropriate.
- Edits use last-write-wins. Coordinate if two people edit the same task or idea at once.
- Mentor feedback can be added as comments or assigned review tasks.
- To update the app, commit changed files. Increment the cache name in `sw.js` when changing the application shell; reload after deployment.
- Fonts use Google Fonts; live authentication uses a pinned Supabase SDK from jsDelivr. The demo and layout have system-font fallbacks.

## Verification completed / still required

Completed: JavaScript syntax checks, desktop browser inspection, all ten milestone renderings, demo task creation with an all-day date, and demo comment submission. Automated checks cover calendar dates, HTML escaping and demo CRUD. Responsive CSS and install assets are included.

Before inviting the crew, run these live acceptance checks:

1. An uninvited email cannot register; an invited email can register and confirm.
2. A signed-out browser cannot read profiles, tasks, ideas, comments or private storage.
3. Two accounts see each other's saved task/idea/comment after Refresh.
4. A normal member cannot update `profiles.role`, edit the invite list, or call `manage_member` successfully.
5. Upload a drawing and PDF; open each from another active account.
6. Deactivate a test member and verify their subsequent reads/writes are denied.
7. Test password recovery, iPhone installation and sign-in from the installed app.
8. Import the calendar and verify January 25, February 22 and April 19 remain all-day dates.

Live Supabase policy execution, real email delivery, cross-device persistence, and physical iPhone installation have not been verified in this environment.

## Documentation

- GitHub Pages: https://docs.github.com/en/pages/getting-started-with-github-pages/creating-a-github-pages-site
- Supabase row-level security: https://supabase.com/docs/guides/database/postgres/row-level-security
- Supabase storage policies: https://supabase.com/docs/guides/storage/security/access-control
- Supabase auth redirects: https://supabase.com/docs/guides/auth/redirect-urls
- Apple home-screen web apps: https://support.apple.com/guide/iphone/iphea86e5236/ios

Independent student-team workspace. Not an official NASA website. Milestone dates are reproduced from the NASA table supplied by the team, not independently verified against a linked challenge page.
