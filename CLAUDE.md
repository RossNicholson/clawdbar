# ClawdBar

Mac menu bar app showing Claude Code's 5-hour and 7-day usage limits. Release with
`make release VERSION=x.y.z` (see RELEASING.md); Ross runs releases.

## Where we left off (2026-11-12)
- **Review fixes on main, waiting for a release** (after 1.3.2):
  - Usage now comes from `GET https://api.anthropic.com/api/oauth/usage` (what Claude Code's
    `/usage` reads; `five_hour`/`seven_day` → `utilization` in percent, `resets_at` ISO 8601).
    It's read-only, so polling no longer spends quota or keeps a 5-hour window open. On a 404
    it falls back to the old 1-token Haiku message + `anthropic-ratelimit-unified-*` headers.
  - Sign-in: the Keychain item is updated in place (and kept in memory if the save fails);
    logout/login during a renewal can't be undone by it; forced renewals at most every 5 min;
    a still-valid token is used while a renewal backs off; the OAuth state is checked.
  - No silent switch to Claude Code's token when ClawdBar's own login fails or expires.
  - Keychain reads run off the main thread; a "Don't Allow" isn't re-asked for 15 min.
  - 15 s request timeouts; forecast budget capped at what's left, "Over by reset" never ~100%.
- At release, update the website: RossNicholsonWebsite/clawdbar.html:275 still says "Each check is
  a tiny one-token request". It's now a read-only usage request (README already updated).
