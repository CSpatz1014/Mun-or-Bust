# Mun or Bust: Discord setup

This update adds a **Join team Discord** button, secure Discord account linking, automatic team-role assignment, selected mission announcements, and an admin delivery/status page. Your existing Discord text channels can be reused. The server is not configured until you complete these steps; no bot token or server access was available during development.

## 1. Create roles and organize the server

In Discord → Server Settings → Roles, create these roles:

| Role | Assignment | Access |
| --- | --- | --- |
| Team Lead | App `admin` | Team channels; optional private coordination channel |
| Mentor | App `mentor` | Team channels and mentor coordination |
| Crew | App `member` | Team discussion, research and voice |
| Mun Mission Control | The custom bot's managed role | Manage Roles and basic channel permissions; placed above the three team roles |

Keep yourself as server owner. **Do not give Crew, Mentor or Team Lead Administrator or Manage Roles.** The integration rejects those permissions on mapped roles. Give all three the basic communication permissions you need: View Channels, Send Messages, Read Message History, Embed Links, Attach Files, Add Reactions, Connect and Speak. Team Lead is a team designation, not automatic Discord administrator access. If you later need trusted human moderation, create a separate manually assigned Moderator role; the integration never assigns it.

Suggested categories/channels (reuse or rename what you already made):

| Category | Channels | Purpose |
| --- | --- | --- |
| START HERE | `#welcome`, `#mission-updates` | Joining instructions and automated updates |
| TEAM WORKSPACE | `#general`, `#base-design`, `#research`, `#mentor-review`, `#meeting-notes` | Discussion supporting the app's structured records |
| CREW LOUNGE | `#off-topic`, voice `Mission Control` | Social chat and team meetings |
| LEADERSHIP (optional) | `#team-coordination`, `#mod-alerts` | Mentor and Team Lead only |

For **TEAM WORKSPACE** and **CREW LOUNGE** category permissions:

1. Deny `View Channel` for `@everyone`.
2. Allow `View Channel` for **Crew, Mentor and Team Lead**; allow the usual text/voice permissions.
3. Keep child channels synchronized with their category. Check existing channels for older permission overrides.
4. For LEADERSHIP, grant access only to Mentor and Team Lead (and the owner).
5. For `#mission-updates`, allow all three to view, but deny **Send Messages** and thread creation/sending for those roles so it stays readable. The webhook posts there.
6. A publicly visible `#welcome` can explain: “Sign in to the Mun or Bust app, then choose Join team Discord to get your team role.” Do not put team work in this channel.

Do not use reaction roles or a generic autorole bot for these three roles: the app verifies membership. An ordinary invite does not grant team access. Remove unrelated role/channel overrides that also grant access if you want app deactivation to remove access reliably. The server owner always retains owner privileges.

## 2. Create the one custom bot needed

Open [Discord Developer Portal](https://discord.com/developers/applications) → **New Application**, named **Mun Mission Control**.

1. Under **Bot**, create/configure the bot and obtain its **bot token**. Store it privately; never put it in GitHub, config.js, a channel, or a chat message.
2. Under **OAuth2**, record the **Client ID** and **Client Secret**.
3. Add this exact OAuth2 redirect URL, replacing PROJECT_REF with your Supabase project reference:
   `https://PROJECT_REF.supabase.co/functions/v1/discord-bridge`
4. Use the application's **OAuth2 URL Generator** (or installation settings) to create a server installation link with the **bot** scope. Select **Manage Roles** plus the basic communication permissions listed above. Do not choose Administrator. Invite it to your Mun or Bust server.
5. Back in Server Settings → Roles, move **Mun Mission Control above Team Lead, Mentor and Crew**. It cannot manage roles above its highest role.
6. No privileged Gateway intents, slash commands, or always-on computer are needed. This bot uses REST calls from Supabase. It may appear offline; that is expected.
7. Enable Discord **User Settings → Advanced → Developer Mode**. Copy the server ID and the IDs of Crew, Mentor and Team Lead (right-click the corresponding item → Copy ID).

For this small private team, no other third-party bot is necessary. Use Discord's built-in AutoMod/spam filters if desired and available in your server settings; send alerts to the private `#mod-alerts` channel. Avoid adding multiple general-purpose moderation/autorole bots with overlapping permissions.

## 3. Create the announcements webhook

Discord Server Settings → **Integrations → Webhooks → New Webhook**. Name it **Mun or Bust Updates**, select `#mission-updates`, and copy its webhook URL privately. This is separate from the bot token. It is a credential, not the link people click to enter the server.

## 4. Prepare Supabase

In the existing Supabase project:

1. SQL Editor → New query → run **[backend/discord-integration.sql](backend/discord-integration.sql)**. It requires the workspace migration from the previous update. Run only this new migration; do not rerun the original base schema or test fixtures.
2. Edge Functions → Secrets: add the following values. These are server-side secrets, not frontend configuration.

| Secret name | Value |
| --- | --- |
| `DISCORD_CLIENT_ID` | Application Client ID |
| `DISCORD_CLIENT_SECRET` | OAuth2 Client Secret |
| `DISCORD_BOT_TOKEN` | Bot token |
| `DISCORD_GUILD_ID` | Server ID |
| `DISCORD_ROLE_CREW` | Crew role ID |
| `DISCORD_ROLE_MENTOR` | Mentor role ID |
| `DISCORD_ROLE_LEAD` | Team Lead role ID |
| `DISCORD_WEBHOOK_URL` | Private announcements webhook URL |
| `DISCORD_DISPATCH_SECRET` | A new random secret, at least 32 characters, shared only with the database webhook below |
| `MUN_SITE_URL` | `https://cspatz1014.github.io/Mun-or-Bust/` |

Generate a dispatcher secret with a password manager's random-password generator (64 characters works well). Supabase supplies `SUPABASE_URL` and the legacy `SUPABASE_SERVICE_ROLE_KEY` to hosted Edge Functions; this implementation uses those server-side variables. If your project has disabled legacy service-role keys, resolve that backend credential configuration before deploying this implementation. Never copy a service-role key into the website.

3. Deploy a function named **discord-bridge**. The repository includes **[supabase/functions/discord-bridge/index.ts](supabase/functions/discord-bridge/index.ts)** as a single, self-contained file: use Edge Functions → deploy/create via editor, replace the starter code with that entire file, and deploy. Alternatively, from the repository with the Supabase CLI installed and linked, run `supabase functions deploy discord-bridge --no-verify-jwt`.
4. For this function, turn off the gateway's **Verify JWT** setting (the repository config does this for CLI deployments). The function implements its own authentication: verified Supabase users for joining, and the private dispatcher secret for database events. Its GET callback only redirects to the app; finishing account linking still requires the original user's session.
5. Database → Webhooks → create **mun-discord-dispatch**:
   - Table: `public.discord_outbox`
   - Event: **INSERT only**
   - Type: HTTP request, method **POST**
   - URL: `https://PROJECT_REF.supabase.co/functions/v1/discord-bridge`
   - Headers: `Content-Type: application/json` and `x-mun-dispatch-secret: YOUR_DISCORD_DISPATCH_SECRET`
   - Use a timeout of 5,000 ms for the outgoing database HTTP request. The outbox records show the processing outcome; do not create UPDATE webhooks on this table.

Without this database webhook, joins can link accounts but role assignments and announcements stay pending. Roles sync independently of the announcement enable switch.

## 5. Deploy the website and test

After Supabase setup succeeds, merge the Discord pull request. Keep the current `config.js`. Wait for GitHub Pages, reload the app, then:

1. Open **Discord** in the app. As an admin, save an ordinary server/channel link such as `https://discord.com/channels/SERVER_ID` or the copied `#mission-updates` channel link. This provides **Open Discord** for linked members.
2. Click **Join team Discord**, authorize Discord, and return to the site. The role is selected from your app account, never from a browser parameter.
3. On iPhone, authorization may return to Safari rather than the installed PWA. Sign in to the **same app account** if asked; the callback fragment is retained for completion. Finish within ten minutes or start again.
4. Refresh status after a few seconds. An admin maps to Team Lead, mentor to Mentor, member to Crew. Test using a normal member too—server owners bypass permission restrictions and cannot prove channel privacy.
5. Enable announcements, select event types, and click **Send test announcement**. Refresh the delivery list and check `#mission-updates`.
6. Test a review request and a meeting with a start time. Discord renders timed dates in each viewer's timezone. All-day deadlines remain dates; the app does not invent a submission cutoff time.
7. Change a test member's app role, then deactivate it. Confirm the app-managed Discord roles change/remove. Deactivation removes the three mapped roles; it does not kick/ban the person or remove manually assigned roles. Re-enable and sync the member when finished.

These are event announcements, not scheduled countdown reminders or a two-way chat mirror. Private message bodies, review feedback, drawings and personal profiles are not forwarded. Item titles/status/dates are visible to everyone allowed into the announcements channel.

## Troubleshooting and maintenance

- **Pending**: confirm the database webhook table/event/URL/header. After five minutes, admins can retry.
- **role_sync_failed**: inspect that member's sync error. `unsafe_role_configuration` means a mapped role is missing, managed by another integration, or has Administrator/Manage Roles. `discord_http_403` usually means bot hierarchy/permissions. `not_in_server` means reconnect/rejoin with the same Discord account.
- **role_sync_busy**: another update holds the short-lived role lock. Wait and refresh before retrying.
- **discord_http_429**: respect the displayed retry-after time. The app does not automatically loop on rate limits.
- **delivery_unconfirmed** or stuck **sending**: check the channel first. A network failure after Discord accepts a message can leave delivery uncertain. Manual retries may duplicate an announcement.
- **Wrong/expired authorization**: choose Start again. Account links are one-to-one. For account replacement, an admin must first remove the old account's team roles in Discord, then repair the corresponding `discord_links` record in Supabase; there is no unsafe self-service switch that leaves old access behind.
- Announcement pause cancels pending announcement posts but leaves role-sync jobs active. Do not disable the database webhook if you expect automatic role revocation.
- Review failed role deliveries after membership changes. Access changes depend on the backend being available; an urgent removal should also be made directly in Discord.
- New OAuth grants are revoked after the join attempt; access/refresh tokens are not persisted. Stored data consists of the Discord ID, app user ID, sync status, ten-minute hashed state, and delivery history.
- This migration does not alter the existing account/login tables or publish webhook secrets. If you revert the frontend, remove/disable the database webhook separately only when you intend to stop role sync.

## References and developer checks

[Discord roles and permissions](https://support.discord.com/hc/en-us/articles/214836687-Discord-Roles-and-Permissions) · [Discord webhooks](https://support.discord.com/hc/en-us/articles/228383668-Intro-to-Webhooks) · [Discord OAuth2](https://github.com/discord/discord-api-docs/blob/main/developers/topics/oauth2.mdx) · [Discord guild API](https://github.com/discord/discord-api-docs/blob/main/developers/resources/guild.mdx) · [Supabase database webhooks](https://supabase.com/docs/guides/database/webhooks) · [Supabase function secrets](https://supabase.com/docs/guides/functions/secrets).

Run `npm ci`, `npm test`, and `npm run check`. Tests use an in-memory PostgreSQL database and mocked Discord/Supabase HTTP calls. They do not send real messages or grant real roles. `handler.js` is the testable source; `index.ts` is generated from it plus `Deno.serve(...)` for easy dashboard deployment. Run `npm run build:discord` after editing the handler, and commit both files.
