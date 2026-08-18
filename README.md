<img width="1494" height="829" alt="image" src="https://github.com/user-attachments/assets/44f2bc6c-f893-4859-b7fe-d57243aa3f52" />

# pr-review-queue

Private, single-user dashboard for the pull requests that actually need me: review requests,
mentions, a watched label, and my own PRs. Rendered server-side — the GitHub token never
reaches the browser.

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

`N reviewed this week` in the header counts reviews you posted in the last 7 days. It is
derived from timelines already fetched, so it costs no extra API calls, but it only sees
PRs still matching `RQ_SCOPE` and undercounts once a PR drops out of the queue.

## Layout

```
app.rb             routes, HTTP basic auth, env config
queue_service.rb   GitHub client, threaded fetch, timeline/state/age logic, TTL cache
views/queue.erb    the table (no JS — tabs and filters are links)
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

The app requires HTTP basic auth (`RQ_USER` / `RQ_PASSWORD`) on every path except `/healthz`.
Only run it behind TLS — basic auth is plaintext. To keep it off the public internet entirely,
skip the domain and reach it over an SSH tunnel to the host's app port instead.

## Token

Fine-grained PAT with **Pull requests: Read** and **Metadata: Read** on the repos in
`RQ_SCOPE` (classic `repo` also works for private repos).

## Local dev

```sh
cp .env.example .env && $EDITOR .env
set -a && source .env && set +a
bundle exec puma -b tcp://127.0.0.1:9292
```
