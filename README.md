# exploren-check

A small macOS app that watches Exploren EV chargers and raises a notification
when one you care about becomes free.

Exploren runs on the [Ampeco](https://www.ampeco.com) charge point management
platform, so most of what follows likely applies to other Ampeco operators with
a different host and channel prefix.

This is an unofficial personal project, not affiliated with or endorsed by
Exploren or Ampeco.

## Why it exists

The Exploren app tells you a charger is occupied. It does not tell you when it
stops being occupied, which is the thing you actually want to know when you are
circling a car park.

## Contents

- `ExplorenCheck` — the macOS app (SwiftUI, a plain window, live updates)
- `exploren_check.py` — the original terminal prototype, stdlib only

## Building

```bash
./build.sh
open -b au.com.automatica.explorencheck
```

Builds an ad-hoc signed bundle and installs it to `~/Applications`. That is
enough to run it yourself, and not enough for anyone else: Gatekeeper refuses
an ad-hoc signature. For a build other people can open, see
`packaging/release.sh`, which signs with a Developer ID certificate, notarises
and staples.

Notification permission is keyed to the bundle identifier and macOS only
prompts once, so changing `CFBundleIdentifier` is the only reliable way to get
a fresh prompt during development.

The bundle is assembled in `/tmp` rather than in the repo on purpose. This repo
lives under `~/Documents`, where a File-Provider cloud sync integration stamps
Finder metadata onto bundles as they are written. codesign refuses to sign a
bundle carrying it, and re-stamping after a successful signing silently
invalidates the signature. It is a race, so it fails intermittently and looks
like something else.

## Choosing chargers

Everything is set up in the app. On first launch it opens on an empty state:
click **Choose Chargers…**, or press Cmd-comma at any time.

Search for a suburb, address or place name, or use **Near Me**, pick a radius,
and tick the chargers you want by **the number printed on the unit**. That is
the only number you can actually see in the real world, and the app resolves
the rest itself. Each result shows its live status, what it costs, and how fast
it is, so you can compare before committing.

Watch as many sites as you like. They are grouped in the window, and each group
collapses to a single line showing how many of its chargers are free, which is
usually all you want from a site you are not heading to right now.

The app notifies when a watched charger frees up, and again beforehand when one
is close to it: finishing, paused by the car, or with its battery above a
threshold. The early warning is the one that buys you time to get there. It
fires once per occupancy and rearms after the bay empties, and a charger
already nearly full when the app launches stays quiet.

**Settings** (Cmd-comma) has the two knobs worth turning: how often to check,
and the battery level that counts as nearly free. The check interval will not
go below a minute, and does not need to: changes arrive over the live
connection as they happen, and the poll only exists to catch a connection that
has quietly died.

## API notes

Everything here was worked out by observing the iOS app's own traffic. It is a
description of how the service behaved at the time of writing, not a contract,
and it can change without warning.

Base URL: `https://exploren.au.charge.ampeco.tech`

### Charger status is public

The status endpoints need **no authentication at all**. No token, no login. The
only header required is `Content-Type`:

```bash
curl -s -X POST \
  'https://exploren.au.charge.ampeco.tech/api/v1/app/locations?operatorCountry=AU' \
  -H 'Content-Type: application/json' \
  -d '{"locations":{"2151":""}}'
```

The map value is an etag slot the app uses for caching. Sending an empty string
always returns fresh data. Several location ids can be requested at once.

This app therefore carries no credentials, sends its own User-Agent rather than
impersonating the iOS client, and touches no write endpoints.

There *is* a login flow, an OAuth2 password grant at `/api/v1/app/oauth/token`
using a client secret embedded in the iOS app. The only thing it unlocks that
matters here is `/api/v1/app/profile/favorites`, which returns the locations
and EVSE ids you have starred. Not worth it, and redistributing someone else's
client secret is a bad idea regardless.

### Pricing

The `locations` response carries a `tariffs` block and a `currencies` block
alongside the locations, and each EVSE has a `tariffId`. **A charger with no
tariff attached is free to use**, which is how the absence is meant to be read.

Three things make this fiddlier than it looks:

- The per-kWh price lives in one of two places. Some tariffs put it in
  `priceForEnergy`; others leave that null and put it in
  `pricePeriods[].energyPerKwh` for time-of-day pricing. You need both paths.
- Tariff ids are **strings, and not always numeric**. A merged
  duration-and-energy tariff comes back with an id like `"732-1507"`.
- Tariffs vary **between chargers at one location**. Monash Clayton runs two
  side by side at different rates, so price belongs per EVSE, not per location.

The fields worth reading are `priceForEnergy`, `priceForIdle` with
`pricingPeriodInMinutes`, `idleFeeGracePeriodMinutes`, `minPrice`,
`preAuthorizeAmount` and `arePricesTaxInclusive`. `priceType` values seen so
far are `standard_tod`, `duration+energy` and `energy tou`. The `currencies`
block even ships format strings, `$%0.02f` for totals and `$%0.04f` for unit
prices.

Idle fees are the part that catches people out: a charger can be free per kWh
and still bill by the minute once charging finishes and the grace period
expires.

### Charger statuses

Values seen in the wild: `available`, `preparing`, `charging`, `suspendedEV`,
`suspendedEVSE`, `finishing`, `faulted`, `out of order`.

The two suspended states are worth telling apart. `suspendedEV` means the car
stopped drawing power, usually because it is full, so the bay is often about to
free up. `suspendedEVSE` means the charger curtailed, typically for load
management, which says nothing about when it frees up. Both mean a vehicle is
still plugged in.

### The four number spaces

This is the part that causes the most confusion. A single charger has several
identifiers and only one of them is visible in the real world:

| Field | Example | Where it appears |
|---|---|---|
| `location.id` | `2151` | API only, never printed anywhere |
| `evse.id` | `8139` | API only, used in other endpoint paths |
| `evse.identifier` | `6451` | **printed on the charger** |
| `connector.id` | `8239` | API only |

The QR code sticker resolves to `evse.qrUrl`, which is
`https://cp.exploren.com.au/public/cs/6451`, so the QR code and the printed
number both carry `identifier`. This app keys its watchlist on `identifier` for
that reason, and resolves the internal ids itself.

### Finding locations

`GET /api/v1/app/pins` takes a bounding box and is also unauthenticated:

```
/api/v1/app/pins?minLatitude=-37.82&maxLatitude=-37.80
                &minLongitude=144.94&maxLongitude=144.97
                &limit=80&withCurrentTypes=true&includeAvailability=true
                &operatorCountry=AU
```

Feed the returned `underlyingLocationIds` into the `locations` call above for
detail. A map-based picker could be built on this without any authentication.

Two things to know. The server caps results at 80 pins whatever `limit` asks
for, so a wide box silently gives you a subset. And once locations are close
enough together the response clusters them: one pin carries several ids in
`underlyingLocationIds` and a `clusterSize` above 1.

#### The `av` availability summary

With `includeAvailability=true` each pin carries an `av` summary of the
chargers it covers, which saves fetching the locations just to count what is
free. For a clustered pin the counts are summed across every location in
`underlyingLocationIds`.

It comes in two shapes, and which one you get depends on a request header:

```bash
# no version header -> self-describing object
{"ava":2,"unk":0,"una":0,"flt":0}

# with 'x-internal-app-version: 3.242.1' -> legacy compact string
"2,0,0,0"
```

The string's fields are in the order `ava,unk,una,flt`. The server keeps that
older form for clients declaring the iOS app's version, so if you pass that
header through you will get a different response shape than if you leave it
off. This app does not send it, which is another small reason not to
impersonate the official client.

| Key | Meaning | Counts EVSEs whose status is |
|---|---|---|
| `ava` | available | `available` |
| `una` | unavailable | `charging`, `preparing`, `finishing`, `suspendedEV` |
| `flt` | faulted | `faulted` |
| `unk` | unknown | never seen non-zero |

`flt` only appears if you ask for it with `extraPinStatuses[]=faulted`, and
without it faulted chargers are counted under `una` instead. One location moved
from `una:9` to `una:8, flt:1` on that parameter alone.

These mappings were checked against the real EVSE statuses for 45 locations
with no mismatches, and the cluster arithmetic against a two-location pin.
`unk` was zero across every pin sampled, so its name is the only evidence for
what it means.

## Live updates over socket.io

Polling works, but the platform broadcasts status changes and you can subscribe
to them anonymously. The configuration is advertised by
`GET /api/v1/app/settings/global`:

```json
"broadcast": {
    "url": "https://echo.au.charge.ampeco.tech",
    "channelPrefix": "exploren"
}
```

That is a Laravel Echo Server, speaking **Engine.IO v3** (`EIO=3`). Note it is
socket.io, not the Pusher protocol, so a Pusher client will not talk to it.

### Handshake

Open with the polling transport to obtain a session id, then optionally upgrade
to websocket at `wss://echo.au.charge.ampeco.tech/socket.io/?EIO=3&transport=websocket&sid=<sid>`.

```bash
BASE='https://echo.au.charge.ampeco.tech/socket.io/?EIO=3&transport=polling'

# 1. handshake, returns JSON containing "sid"
curl -s "$BASE&t=$RANDOM"

# 2. subscribe. Payloads on the polling transport are length-prefixed
#    as <byte length>:<packet>
FRAME='42["subscribe",{"channel":"exploren.locations","auth":{"headers":{}}}]'
curl -s -X POST --data-binary "${#FRAME}:$FRAME" "$BASE&t=$RANDOM&sid=$SID"
# -> ok

# 3. long-poll for events
curl -s "$BASE&t=$RANDOM&sid=$SID"
```

The empty `auth.headers` is the significant part. `exploren.locations` is a
public channel and the subscription is accepted without a token. The
authenticated iOS session also subscribes to `private-exploren.user.<id>`,
which does require a bearer token, but carries account events rather than
charger status.

### Events

Frames arrive as `42["<event>","<channel>",<payload>]`:

| Event | Payload |
|---|---|
| `App\Events\EVSEBecameAvailable` | `{evse_id, location_id, reservation_id}` |
| `App\Events\EVSEBecameUnavailable` | `{evse_id, location_id, reservation_id}` |
| `App\Events\LocationChanged` | `{location_id}` |
| `App\Events\EVSEChargingPercentageChanged` | `{evse_id, soc_percent, location_id}` |

`EVSEBecameAvailable` is the interesting one. Events are emitted for the whole
tenant, not just the locations you care about, so filter them yourself. The app
filters on `location_id`, which it already knows from the watchlist, avoiding
any need to map internal EVSE ids.

`EVSEChargingPercentageChanged` carries `soc_percent`, the battery level of the
connected vehicle, and is most of the traffic by volume. The same figure
appears as `socPercent` on each EVSE in the `locations` response. It is often
null: the car and the charger have to speak a protocol that carries it, so DC
fast chargers tend to report it and slower AC units frequently do not.

Engine.IO v3 expects the **client** to send the heartbeat. Send `2` every
`pingInterval` milliseconds, as advertised in the open packet, or the server
drops the connection after `pingTimeout`.

The app connects directly with `transport=websocket` and no prior polling
handshake, which this server accepts, so the upgrade dance is unnecessary.
While the stream is connected the HTTP poll drops back to a five minute
backstop; if the stream drops, the configured poll interval takes over
again.

## Please be considerate

These endpoints are unauthenticated, which makes it easy to hammer them. Poll
at a sensible interval, subscribe to the event stream rather than polling hard
if you need to be quick, and keep to read-only endpoints. This is somebody
else's infrastructure, and the charging network being reliable is in everyone's
interest.

## Licence

MIT
