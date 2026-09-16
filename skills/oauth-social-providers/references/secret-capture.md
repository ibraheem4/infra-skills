# Capturing a provider client secret — one shot, no retry

Both Google and Microsoft display a client secret exactly once. There is no second look and
no recovery, only rotation. Everything here exists because a step out of order destroyed a
credential.

## The safe order

1. **Create the destination secret first.** An app whose secret has nowhere to go is an
   orphan the moment the dialog closes.
2. Arm a sentinel on the clipboard, so "did the copy work" has an unambiguous answer:
   `printf 'SENTINEL_%s' "$(date +%s)" | pbcopy`
3. Create the app or client.
4. Copy the secret with the console's own copy control.
5. Verify locally — prefix and length — then bank it, then clear the clipboard.
6. Only now scrub anything.

If the sentinel survives step 4, the copy did not happen. **Do not reload and do not
navigate**: the value is still on screen, so hand the click to a human instead.

## Verify before banking, on shape not content

Guard on the provider's constant prefix **and** the length. A length-only check passes stale
clipboard content — a leftover shell command once sailed through a `>= 10` test and was
written into a secret as though it were a credential.

```
v="$(pbpaste)"
case "$v" in GOCSPX-*) ;; *) echo "not a Google client secret"; exit 1;; esac
[ "${#v}" -eq 35 ] || { echo "unexpected length"; exit 1; }
```

To prove a replacement differs from a value you know is compromised, compare
`shasum -a 256` digests. That reveals nothing about either.

## If an agent drives the browser

These are the mechanics of doing the above through browser automation. They are specific to
an agent with screenshot and DOM tooling; a human clicking the button needs none of it.

🔴 **The secret's only in-page existence is the copy control's accessible name** — Google puts
the literal value in the button's `aria-label`. Two consequences:

- **Every ordinary way of finding that control leaks the value** into the transcript: an
  accessibility-tree read (including one filtered to interactive elements only — the label
  *is* the button's name), a natural-language element search, and any screenshot of that pane.
  The masked `****xxxx` in the secrets *table* is safe; the copy control is not.
- **A page reload loses the secret forever.** The control exists only in the session that
  created it.

So the only safe capture returns coordinates and nothing else:

```js
const P = 'Copy to clipboard: GOCSPX-';
const c = [...document.querySelectorAll('button')]
  .filter(b => (b.getAttribute('aria-label') || '').startsWith(P));
const b = c[c.length - 1], r = b.getBoundingClientRect();
({ n: c.length, x: Math.round(r.left + r.width/2), y: Math.round(r.top + r.height/2) })
```

Then click those coordinates with a real synthesized gesture.

🔴 **Never scrub the label before clicking.** The console's copy handler reads the value from
that attribute, so scrubbing first destroys the only copy — confirmed by a DOM sweep
afterwards finding zero occurrences anywhere. Scrub only after the value is banked, as
defence against a later accidental read.

**Page-context clipboard writes do not work.** `navigator.clipboard.writeText` hangs past the
tool's timeout waiting on focus, and `document.execCommand('copy')` returns `false`. Only a
real click fires the console's own handler.

### Coordinates: convert, never pass through

`getBoundingClientRect` is in **viewport** CSS pixels. Click tooling generally works in the
**screenshot frame**, which can be slightly smaller — seen at `1496x812` against a viewport of
`1512x821`, about 1%. Passing viewport coordinates straight through lands ~10px off: harmless
on a button, fatal on a 19x19px copy icon, where it hits the edge and silently does nothing.

```
frame_x = round(viewport_x * frame_w / innerWidth)
frame_y = round(viewport_y * frame_h / innerHeight)
```

Before clicking a small target, have the page confirm it is actually hittable:
`document.elementFromPoint(cx, cy)` should return the button or a descendant. That catches an
overlay or a stale position before it costs a one-shot secret.

Console side panels often scroll independently of `window`, so `window.scrollBy` and
`scrollIntoView` do nothing — scroll over the panel itself. Prefer reference-based clicks for
anything that is not a secret-bearing control; references survive reflow, coordinates do not.

### Other things that look like success

- **Tooling may redact its own output.** A returned object key matching `/secret/i` can come
  back blanked, which reads as a failure when the call actually worked. Name the field
  something neutral.
- **Do not batch clicks straight after a save.** The page reflows while saving; the next click
  lands on nothing and the dialog silently never opens. Confirm state between steps.
- **Dialogs animate in.** A click sent before one finishes rendering hits nothing and looks
  like the action failed silently. Screenshot to confirm it is painted, then click.
- **A save can no-op while looking exactly like success.** Verified 2026-09-06 on the consent
  screen's *Add users* dialog: it closed with no error and added nobody, while still rendering
  the entries and their count. The identical action worked on retry, and the same run's other
  project saved first time — so it is intermittent, not a per-project quirk. Reload and re-read
  the stored count; the post-save view is not evidence.

## Saving onto the credential record

The dashboard is the only way in — the management mutation takes the secret as an argument, so
calling it would put the value in the transcript. Instead:

1. `oauth-secrets.sh copy <secret-id> <KEY>` — prints nothing, value on the clipboard.
2. Click the field, paste with the platform shortcut.
3. Verify in-page by **length only**.
4. Save, then confirm over the API that the state moved to valid and the redacted tail matches.

Client IDs are public — type those directly.

⚠️ Environment-scoped dashboard URLs may redirect to a generic start page. Use the project and
environment switchers instead of deep-linking.

## Cleaning up

Any command that stages a secret to disk must remove **every** file it creates, intermediates
included. A trap listing `$tmp` and `$tmp.req` but not `$tmp.clean` leaves the plaintext
behind — that exact gap left a live client secret in `$TMPDIR`.

⚠️ An interactive shell may alias the file-moving commands to `-i` — `rm`, `mv` **and `cp`**.
A scripted `rm -f` or `cp` then prompts, gets no answer, and **exits 0 having done nothing**,
so cleanup silently fails and a "successful" merge writes the wrong content. Confirmed on
`cp` 2026-09-06, overwriting a file that was never overwritten. Call them by absolute path in
inline commands — `/bin/rm -Pf`, `/bin/cp -f`, `mv -f`. Scripts with their own shebang do not
inherit the alias.

Sweep the temp directory for mode-600 files afterwards and grep for the provider's secret
prefix before declaring the work done.

## Read the callback URI before you enable anything

The dialog shows the callback URI as soon as it opens, before any save. Verified on WorkOS
2026-09-14: the slug was identical across a cancel-and-reopen *and* a full page reload, while
the provider still read `Enable` on the list behind it — so it is allocated per environment
and provider, not minted per dialog.

That matters because it inverts the obvious order. If you enable first to obtain the URI, the
environment runs on the identity provider's demo client for as long as the upstream
registration takes. Read the URI, cancel, register upstream, capture the secret, and only then
enable and save — the environment goes straight from off to correctly configured.

Confirm the reload before trusting it. A slug minted per dialog would leave you registering a
URI upstream that no longer matches, and the failure appears only at first sign-in.
