# Spec: one title card on Search and Discover, with the download flow inside it

Status: Draft
Issue: MickMarch/medialab#101, MickMarch/medialab#103

## Problem

Search and Discover show the same TMDB titles through two different cards.
Search renders every result as a full card with its own "Choose season" or
"Find torrents" button (`partials/tmdb_results.html`), and offers no
trailer. Discover renders a poster that opens a detail card
(`partials/discover_detail.html`) with Download, Watchlist and Watch trailer.
A title therefore behaves differently depending on which page found it, and
trailers are reachable from only one of them.

On both pages every download control targets the page-level `#stage`
section with `hx-swap="innerHTML show:#stage:top"`. The season picker and
the torrent table appear at the top of the page while the card the user
pressed stays where it was. On a phone the user has to scroll to find the
step they just started. The trailer, by contrast, opens in a slot inside the
card and stays under the finger.

## Goal and non-goals

Goal: Search and Discover render the same poster card, opening the same
detail card, which carries every action for a title: Download, Watchlist,
Watch trailer. The download flow (season scope for a show, then the torrent
table, then the started notice) renders in a slot inside that card, exactly
as the trailer does, and the card opens in place in the grid so nothing
moves away from where the user pressed.

Non-goals: the show page and the episode list (they already live on a page
about one show, and keep `#stage`); the redo flow on the Jobs page; the
watchlist follow picker; the trailer list layout (MickMarch/medialab#102);
any change to the gateway or the other services. medialab-web only.

## Design

### Ownership

| Service | Owns |
|---|---|
| medialab-web | every change in this spec |

No contract, orchestrator or downloader change.

### Poster card and detail card

- `partials/tmdb_results.html` becomes a `posters` grid of
  `poster_card(item, open_vals=item | card_vals, browse_href=...)`, the same
  call Discover makes. The per-result title, rating, overview, download and
  watchlist markup moves out; the detail card already renders all of it.
  The results keep the "No results" notice and the TMDB attribution footer.
- `card_vals` gains the typed `query` when it is known (Search), so the
  detail card can pass it down to the torrent search as the alternate
  query, as the inline buttons do today. Discover sends none.
- The detail card opens **in place**: the poster button swaps the detail
  card in with `hx-swap="afterend"` on `closest .poster-card`, and the
  detail card is `grid-column: 1 / -1` so it spans the grid directly under
  the poster that opened it. Opening a card first removes any other open
  `.detail` on the page (one open card, one open player, as the trailer
  does today with `hx-on::load`). Close removes the card. The `#detail`
  section on the Discover page goes away.
- The step strip (`partials/steps.html`, "Step 2 of 4") leaves the Search
  page. Search is a search box and a grid; the card is the flow. The
  "Back to titles" link inside the picker goes away, since the titles never
  left the screen; "Change scope" stays.

### Download slot

- The detail card gets a `<div class="download-slot">` sibling to the
  trailer slot. `partials/download_button.html` targets
  `next .download-slot` with `hx-swap="innerHTML"` (no `show:`), the same
  shape as `partials/trailer_button.html`.
- `partials/scope.html` and `partials/torrents.html` stop naming `#stage`.
  Every control inside them (the scope form, "Change scope", the download
  forms, the started notice) targets `closest .download-slot`. The page
  sections that still host the flow (show page, Jobs redo, watchlist follow)
  add the `download-slot` class to their `#stage` section, so the same two
  partials serve both placements with no template branching.
- `partials/download_started.html` renders into the slot in place of the
  table, with a "Find another" link that reloads the scope or torrent step,
  and the existing out-of-band jobs refresh is unchanged.
- The torrent table inside a card uses the existing narrow layout (the
  `max-width: 700px` rules that stack `table.torrents` rows) at every width
  when it is inside `.detail`, because a card is never wide enough for six
  columns. Release names keep `breakable`.
- The busy indicator for a torrent search is the existing
  `partials/searching.html` text, rendered inside the slot while the request
  is in flight (`hx-indicator` on an element inside the slot), so the
  "Working..." state is also under the finger.

### Routes

| Method | Path | Change |
|---|---|---|
| GET | `/partials/search/tmdb` | renders the poster grid instead of inline cards |
| GET | `/partials/discover/detail` | accepts the optional `query` in `CardQuery` and passes it to the download button |
| GET | `/partials/search/scope` | unchanged input; template no longer references `#stage` |
| GET | `/partials/search/torrents` | unchanged input; template no longer references `#stage` |
| POST | `/downloads` | unchanged |

### medialab-bot

Unchanged.

## Decisions

1. **In-place expansion, not a fixed detail area at the top.** Rejected:
   keeping `#detail` above the grid and only moving the download flow into
   it. That fixes the second jump but keeps the first: on a phone the grid
   is three posters wide and the card still opens off-screen. Spanning the
   grid under the pressed poster keeps every step where the finger is.
2. **One slot class served by one pair of partials, not a `target`
   parameter.** Rejected: passing the HTMX target through `hx-vals` and
   every template. `closest .download-slot` works wherever the partial
   lands, and `#stage` only has to carry the class on the pages that keep
   it.
3. **Search results become posters.** Rejected: keeping the Search inline
   card and adding a trailer button to it. That keeps two cards for one
   title and two places to maintain every future action.
4. **Drop the step strip on Search.** Rejected: keeping it and advancing it
   from inside the card. The strip describes a page-level wizard that no
   longer exists; inside a card it is noise.
5. **Show page, episode list, Jobs redo and follow picker keep `#stage`.**
   Rejected: moving them all into slots in one change. They are page-level
   flows about a single already-chosen title, and widening the change
   risks the redo out-of-band swap for no stated pain.
6. **Web only.** The bot has no cards.

## Open questions

1. When a detail card is open and the user presses "More" on Discover, the
   appended posters land after the open card. Acceptable, or should "More"
   close the open card first?

## Test plan

- **web, search page**: `/partials/search/tmdb` renders a `poster_card`
  per result with `open_vals` carrying `query`, and no inline Download or
  Choose season button; renders no step strip.
- **web, discover detail**: the detail card markup contains a
  `download-slot`; the Download button targets `next .download-slot` and
  has no `show:` modifier; `query` from `CardQuery` reaches the Download
  button's `hx-vals` when given and is absent otherwise.
- **web, scope and torrents partials**: neither rendered partial contains
  the string `#stage`; the scope form, Change scope link and every download
  form target `closest .download-slot`; the started notice renders into the
  slot.
- **web, show page and jobs page**: their `#stage` section carries the
  `download-slot` class, and the redo flow still renders the torrents
  partial into it (existing redo tests keep passing).
- **web, trailers**: existing trailer tests pass unchanged; opening a
  second detail card leaves exactly one `.detail` in the document (markup
  carries the `hx-on` that removes the others).

## Rollout

1. medialab-web PR and release. Redeploy. No host step.
