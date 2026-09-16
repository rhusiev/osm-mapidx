# osm-mapidx

Makes OsmAnd able to find a POI by the things around it - the village, the
street, the raion - and adds a typo-tolerant search index on the side.

OsmAnd matches your query against a POI's own `name` tag and nothing else. So a
hotel tagged `name=Медовий двір` is findable as "Медовий двір" and *not* as
"медовий двір славсько", even though OsmAnd knows perfectly well it is near
Славсько and shows you that when you tap it. This project computes that context
from OSM and folds it back into a name OsmAnd can actually match.

## What it produces

Three artefacts from one place table:

- `out/<Region>_mapidx.obf` - a POI-only OsmAnd map. Drop it next to your
  official maps and OsmAnd's own search box starts finding
  `Медовий двір (Нижня Рожанка, Славсько, вул. Устияновичів, ...)`.
  Inherits OsmAnd's prefix matching, so no typo tolerance.
- `out/<region>-search.sqlite` - a word index for the fuzzy layer, queried
  outside OsmAnd. This is the part that survives typos. 91 MB for Lviv oblast,
  and a query answers in 2-60 ms, so it can run per keystroke on a phone.
- `app/build/app/outputs/flutter-apk/app-release.apk` - "POI search", a small
  Android app that hosts that fuzzy layer: type a query, see hits with
  context and distance, tap to jump into OsmAnd via `geo:`.

## Build

```bash
python3 -m venv .venv && .venv/bin/pip install osmium shapely numpy
curl -O https://download.geofabrik.de/europe/ukraine-latest.osm.pbf   # into data/

.venv/bin/python -m mapidx.cli build data/ukraine-latest.osm.pbf --region lviv
./build_obf.sh lviv
```

`--region ukraine` runs the whole country with no bbox clip. Geofabrik has no
oblast-level extracts, so regional runs clip the country file.

Pass 1 must stream the entire country file even for a single oblast, so its
result is cached in `build/<region>-indexes.pickle` and reused. Pass `--refresh`
after downloading newer OSM data.

`build_obf.sh` wraps `mapidx.cli obf`, which does three things MapCreator
does not do for you: it probes which POI categories MapCreator actually accepts
on a node, adds `place=locality` to the ones it would otherwise drop silently
(18% of the Lviv export, mostly streams, rivers and named buildings), and
checks the finished obf contains every node it was given.

## Install on the phone

Copy `out/<Region>_mapidx.obf` into `Android/data/net.osmand.plus/files/`
and restart OsmAnd. It is large - 320 MB for Lviv oblast, nearly all of it the
prefix index over the context names - so check the free space first. It appears
alongside the official maps; nothing is replaced and the official maps keep
updating themselves.

## Fuzzy search

```bash
.venv/bin/python -m mapidx.cli search out/lviv-search.sqlite "медовы двир славско"
.venv/bin/python -m mapidx.cli search out/lviv-search.sqlite "аптека славсько" \
    --near 49.84 24.03
```

Prints scored results with a `geo:` URI per hit, which OsmAnd opens directly,
and the distance from `--near` when given.

Every word must match, each against the place's name or any of its context
names, at 0.6 similarity or better. Misspellings are found by resolving the
typed word against the 114k indexed words - by prefix first, then through a
trigram index over those words - and a word too badly misspelled for either
("двир" for "двір" shares no trigram) is still judged by reading the places the
other words found. This command needs nothing outside the standard library, so
it also runs on the phone under Termux.

A query that hits a place's name as the exact same word ranks that place above
POIs whose names only start with the same prefix, and areas (`place=*`,
`boundary=administrative`) outrank POIs in general - so a search for "Славсько"
or "Львів" returns the town or city first, with streets, shops and bus stops
sharing those names hidden behind the long press.

## Android app

A small Flutter app under `app/` wraps the same fuzzy layer in a searchable
list. Type, see context + distance, tap - OsmAnd opens at that point.
Long-press a hit for the address and which of your words matched what.

### Build

```bash
export PATH="$PATH:$HOME/dotfiles/local/share/flutter/bin"
export JAVA_HOME="$HOME/dotfiles/local/share/jdk"   # Temurin 21; Fedora's /usr/lib/jvm/* are JRE-only
export ANDROID_HOME="$HOME/.local/share/android-sdk"
cd app
flutter build apk --release
```

Output: `app/build/app/outputs/flutter-apk/app-release.apk` (~53 MB). The
template signs release with the debug key, so the APK installs for sideloading
but is not Play-Store ready - swap in a real keystore before publishing.

### Install

1. Sideload `app-release.apk` (Settings -> Apps -> Special access -> Install
   unknown apps, or `adb install`).
2. Open the app. Tap "Pick index file" and choose `out/lviv-search.sqlite`
   (or any file ending in `-search.sqlite`). The system file picker opens -
   no special permission is asked. The app stream-copies the file into its own
   internal storage; the original stays where it was.
3. Grant the location permission when you first tap the location button -
   used for the distance hint, no Play Services required, no network.

The index menu (top right) holds "Replace index" and "Remove index". Replace
picks a fresh copy; Remove deletes the imported copy and shows the picker
again. The chosen path persists across launches.

### Use

The top field searches POIs (name, street, village). The card below it sets
the "distance from" point - search for a place, use GPS, or pick a point on
the map. With an origin set, hits sort by distance from it; without one,
distances are hidden. Tap a hit to open it in any maps app that handles
`geo:` links; long-press shows the address and each typed word with the
score it got, and an Open button.

### Network

Search runs entirely against the local SQLite file. The one exception is the
map picker: it loads OSM raster tiles directly from `tile.openstreetmap.org`
with a descriptive User-Agent per the OSM tile usage policy. Tiles are cached
on disk in the app's documents directory for 7 days and re-fetched in the
background when stale. Attribution is shown on the map as required by the
ODbL. The manifest declares `INTERNET` for this; if you never open the
picker, no network is used.

## How the context is derived

Nothing is hand-written. For every named POI, pass 2 asks three spatial indexes
built in pass 1:

1. **Containing admin units** - point-in-polygon against `boundary=administrative`
   areas at levels 8, 7, 6 and 4, giving the settlement, hromada, raion, oblast.
2. **Nearby settlements** - all `place=*` nodes within 8 km, plus cities and
   towns within 40 km, nearest first. This is what supplies *both* Нижня Рожанка
   and Славсько, and it is deliberate: where OSM is ambiguous about which
   village a POI belongs to, we index both instead of picking.
3. **Street** - `addr:street` if tagged, else the nearest named `highway=*`
   within 120 m.

Names are also romanised into two Latin schemes: the official Ukrainian
standard (KMU 2010) and a naive phonetic one closer to how people actually type.

Since OsmAnd requires *all* query tokens to match, extra context can only add
hits, never remove them - so the pipeline over-generates on purpose.

## Maintenance

Re-run when you want fresher data. Place names are the slowest-changing thing in
OSM, so a year-old index is still almost entirely correct, and it only affects
search - routing and rendering come from the official maps as usual.

See `FINDINGS.md` for the OsmAnd and MapCreator behaviours this depends on.
