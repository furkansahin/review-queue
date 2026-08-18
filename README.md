<img width="1494" height="829" alt="image" src="https://github.com/user-attachments/assets/44f2bc6c-f893-4859-b7fe-d57243aa3f52" />

# pr-review-queue

Dashboard for the pull requests that actually need you: review requests, mentions, a watched
label, and your own PRs. Sign in with GitHub and the queue is fetched with your own account,
so each person sees their own. Rendered server-side — no JS.

## State model

One merged timeline per PR (issue comments, review comments, submitted reviews, head-commit push):

| Situation | State |
| --- | --- |
| My event is the newest | **Reviewed** |
| My event is newest, PR is mine | **Waiting on them** |
| Someone else posted or pushed after me | **To review** |
| …and the PR is mine | **Your turn** |

The bar and the `Waiting` column measure time since the last event that wasn't mine, so a
re-push resets the clock: green below `RQ_WARN_DAYS`, amber at `RQ_WARN_DAYS`, orange at
`RQ_HOT_DAYS`, red at `RQ_STALE_DAYS`.

Snapshots cache for `RQ_CACHE_TTL` seconds; the page self-refreshes every 3 minutes and
`Refresh` forces a rebuild. Roughly 6 GitHub API calls per PR per rebuild.

## Getting through the queue

The list is ordered reddest-first, so row one is always the next thing to review; it is
also lifted into a **Next up** card above the table. A progress bar and the tab title
(`(4) Review queue`) count what is still waiting, and clearing the list earns a proper
empty state.

The **Size** column estimates reading time from the diff churn at `RQ_LINES_PER_MIN`
lines per minute. **Quick wins** filters to non-draft PRs of `RQ_QUICK_LINES` churn or
less — the cheapest way to make the number go down.

`N reviewed this week` in the header counts the pull requests you reviewed in the last 7
days. It reads your public events feed, not the queue. This matters: GitHub removes you from
the requested reviewers as soon as you submit a review, and a reviewed pull request is usually
merged soon after, so a reviewed pull request leaves the queue almost immediately. An earlier
version counted inside the queue and showed `0` while 25 reviews had been done that week.

The feed costs one extra API call for each rebuild. It holds **public** events only, which is
sufficient because `RQ_SCOPE` must be public repositories anyway — if you ever add a private
repository, this counter stops seeing those reviews. A `+` after the number (`18+`) means the
pages read did not reach back a full 7 days, so the number is a floor, not a total.

## Snooze

`Snooze` on a row hides it for `RQ_SNOOZE_DAYS` days. The **Snoozed** tab shows what you hid,
and `Wake` puts a row back immediately.

A snoozed row also comes back on its own when there is new activity on it. If a person pushes
a commit or writes a comment after you snooze the pull request, the row returns to the queue
at the next rebuild. You do not hide the pull request. You say "nothing for me until this
changes".

The list is per browser. It lives in the session cookie, so there is no database. A cookie
holds about 4 KB, so the list keeps at most 25 entries and drops the oldest snoozes first.
Entries also go away when the snooze time is complete or when the pull request leaves the
queue. Clearing your cookies clears the list, and the list does not follow you to another
browser.

## Layout

```
app.rb             routes, session/OAuth, allowlist, env config
queue_service.rb   GitHub client, threaded fetch, timeline/state/age logic, TTL cache
views/queue.erb    the table (no JS — tabs and filters are links)
auth.rb            GitHub OAuth flow + per-user service registry
snooze.rb          per-browser snooze list, kept in the session cookie
views/login.erb    the sign-in page
Procfile app.json  Dokku process + zero-downtime health check
setup.sh           one-shot dokku app create + config:set
```

## Create the repo

```sh
cd review-queue
git init -b main
bundle install            # commit the lockfile — the Ruby buildpack needs it
git add -A && git commit -m "Initial commit"
gh repo create pr-review-queue --private --source=. --push
```

The Ruby version lives in `.ruby-version`. The Gemfile reads it (`ruby file: ".ruby-version"`),
so `bundle install` records it as `RUBY VERSION` in `Gemfile.lock` — which is where the buildpack
looks. To bump Ruby: edit `.ruby-version`, run `bundle install`, commit the lockfile.

## Deploy with Dokku

On the Dokku host, edit and run `setup.sh` (creates the app, sets config, sets the domain),
then from your checkout:

```sh
git remote add dokku dokku@<dokku-host>:review-queue
git push dokku main
```

### DNS (Cloudflare)

In the Cloudflare zone for the apex domain, add one record pointing at the VM's public IPv4:

```
Type  Name    Content            Proxy
A     review  <vm-public-ip>     DNS only (grey cloud)  ← during setup
```

Then on the Dokku host:

```sh
dokku domains:set review-queue review.furkansahin.work
```

The Ubicloud VM firewall needs inbound 80 and 443 (80 is required for the ACME HTTP-01
challenge and for the redirect Dokku installs).

Issue the cert with the proxy **off**, so Let's Encrypt talks to the origin directly. Once
`https://review.furkansahin.work` works, you can switch the record to **Proxied** (orange) and
set the zone's SSL/TLS mode to **Full (strict)** — the origin already has a real cert, so strict
validates. Leave it grey if you'd rather Cloudflare never see the traffic; the certificate
renews the same way either way.

TLS, once DNS points at the host:

```sh
dokku letsencrypt:set review-queue email you@example.com
dokku letsencrypt:enable review-queue
```

Config lives in `dokku config`. `dokku config:set review-queue RQ_LABEL=foo` restarts the app
with the new watch label; no code change needed.

## Access

Sign-in is GitHub OAuth. Every path except `/healthz` and the auth routes requires a session.

`RQ_ALLOWED_LOGINS` is a required, comma-separated, case-insensitive list of GitHub logins.
It **fails closed**: the app refuses to boot without it, and a login that is not on the list is
rejected after the OAuth round-trip. Without this anyone with a GitHub account could sign in
and spend your server's CPU on their own queue.

Sessions are signed and encrypted cookies (`RQ_SESSION_SECRET`, at least 64 chars), so there
is no database. Changing that secret signs everyone out.

## OAuth App

Register one at **Settings → Developer settings → OAuth Apps**:

- Homepage URL: `https://review.furkansahin.work`
- Authorization callback URL: `https://review.furkansahin.work/auth/callback` (must match exactly)

Put the Client ID and Secret in `RQ_GITHUB_CLIENT_ID` / `RQ_GITHUB_CLIENT_SECRET`.

The app requests **no scopes at all**. A scopeless user token still resolves `GET /user` (needed
to expand `@me` in the search queries) and still gets the 5000/hr authenticated rate limit, but
it cannot write to anything. This is only sufficient because `RQ_SCOPE` covers **public** repos —
pointing it at a private repo would require the classic `repo` scope, which also grants *write*
access to every repo the user can reach. Revisit this choice before adding a private repo.

Rate limits are per user token, so they scale with users. The server-side cost does not:
each rebuild fans out worker threads, so `RQ_MAX_USERS` caps concurrently cached users and
`RQ_IDLE_TTL` drops a user's cached queue once they go idle.

## Local dev

```sh
cp .env.example .env && $EDITOR .env
set -a && source .env && set +a
bundle exec puma -b tcp://127.0.0.1:9292
```

For local sign-in, register a second OAuth App with callback `http://127.0.0.1:9292/auth/callback`
and keep `RQ_INSECURE_COOKIES=1` set — otherwise the session cookie is `Secure` and the browser
will drop it over plain http.
