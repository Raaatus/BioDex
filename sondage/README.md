# The public-server poll

The website asks visitors whether they would use a public Biodex server. The site itself is static (GitHub Pages), so the counter lives in a tiny [Cloudflare Worker](https://workers.cloudflare.com/) — free tier, nothing to host — guarded by [Turnstile](https://www.cloudflare.com/products/turnstile/), Cloudflare's free captcha.

One vote per IP address: the worker keeps a salted hash of the address for a year, never the address itself.

## Deploy it (once, about five minutes)

1. A Cloudflare account, and the CLI: `npm install -g wrangler && wrangler login`.
2. In the dashboard, **Turnstile → Add site**: hostname `raaatus.github.io` (yours), widget mode *Managed*. Note the **site key** (public) and the **secret key**.
3. From this folder:

   ```bash
   wrangler kv namespace create VOTES        # paste the id into wrangler.toml
   wrangler secret put TURNSTILE_SECRET      # the secret key from step 2
   wrangler secret put SEL                   # any long random string
   wrangler deploy                           # prints the worker's URL
   ```

4. In `docs/index.html`, on the `.sondage` element, set `data-url` to the worker's URL and `data-cle` to the Turnstile site key. Commit, push: the counter is live.

`GET` on the worker's URL returns `{"total": n}` if you just want the number.
