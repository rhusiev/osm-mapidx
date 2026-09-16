# Findings about things we don't control

## OsmAnd search

- OsmAnd's offline POI search matches query tokens against a POI's **own name
  tag only**. Neither the containing settlement nor the street is part of the
  POI name index, even though OsmAnd computes and *displays* the settlement in
  the POI info panel. This is the entire reason this project exists.
- Confirmed empirically: "Медовий двір" finds the hotel, while
  "медовий двір славсько", "славсько медовий двір" and
  "медовий двір устияновичів" all return nothing.
- The docs describe city-scoped queries such as "Bratislava Billa" working, but
  that path does not apply to ordinary POIs. Word order does not rescue it.
- Matching is prefix-based per token, so truncation is free ("медов двір" works)
  but a typo in the middle of a word is fatal. Nothing in the index can change
  this; the matcher lives in the app.
- Because matching is AND over query tokens, adding context tokens to a name can
  only make more queries succeed, never fewer. Over-generating context is safe.
- `alt_name` handling has changed across releases and `alt_name:en` is still not
  searchable (osmandapp/OsmAnd#15504, #22089). We therefore never rely on OsmAnd
  reading alternative name tags - every variant is flattened into `name` on a
  node we generate ourselves.
- Known trap: if two installed maps cover the same address region, cities from
  the second file silently fail to load until the app restarts, while its POIs
  still appear (osmandapp/OsmAnd#25993).

## OsmAnd map files

- OsmAnd loads every `.obf` in its data directory, additively. A POI-only `.obf`
  therefore supplements the official maps instead of replacing them, and the
  official maps keep auto-updating.
- Android path: `Android/data/net.osmand.plus/files/`. If storage permissions
  get in the way, OsmAnd can be pointed at a `/media/`-based path instead.
- `OsmAndMapCreator/utilities.sh generate-poi <file> --chars-build-poi-nameindex=N`
  produces an obf containing only a POI index. MapCreator derives the obf name
  from the input filename, and that name is what OsmAnd shows in its map list.
- MapCreator silently drops objects whose tags it does not recognise as a POI
  type **on a node**, so the output POI count must always be checked against
  the input node count rather than assumed. Measured on the first Lviv run:
  72,087 of 400,216 nodes (18%) vanished - `waterway=stream` (22,545),
  `waterway=river` (8,761), every `building=*` (~23,000 across 60 values),
  `railway=rail` (7,047), `historic=yes`/`heritage`, `place=municipality`,
  `man_made=pipeline`, `emergency=yes`. 224 of the 1,013 categories in the
  export are rejected.
- That accepted set is **not** derivable from `poi_types.xml` inside
  `lib/OsmAnd-java-master-snapshot.jar`: `waterway=stream` and `waterway=river`
  are declared there yet rejected on nodes, while `amenity=atm`, `shop=yes` and
  `place=square` are accepted without appearing in it. The only reliable way to
  learn it is to run generate-poi on one probe node per category and read back
  which survived - 1,013 probe nodes cost 9 s, so this is done on every obf
  build (`mapidx/obf.py`).
- A node carrying both a rejected and an accepted tag is kept, indexed under the
  accepted type, with the rejected tag preserved as an extra attribute. Adding
  `place=locality` alongside the original therefore rescues an entry without
  losing what it is.
- A node with two accepted types is written to the POI index once per type, so
  the count check must compare distinct `osmid=` values, not printed entries
  (the first Lviv run printed 328,150 entries for 328,129 distinct ids).
- `inspector.sh` defaults to `-Xmx512M` and dies with `OutOfMemoryError` in
  `readFullNameIndex` on a 265 MB POI-only obf. `-vpoi` needs `JAVA_OPTS`
  raised (12 GB is comfortable), and it reads the whole name index before it
  prints even the object count, so there is no cheap way to get that count.

## OSM data shape in Ukraine

- Mountain villages carry many `place=neighbourhood` nodes for присілки (hamlet
  districts). Around the Медовий двір test point there are twelve of them within
  3.3 km, while the names a person would actually type - Славсько (`town`,
  3397 m) and Нижня Рожанка (`village`, 3851 m) - are further away. Selecting
  context by distance alone therefore returns names nobody searches for.
  Settlement ranks (`city`/`town`/`village`/`hamlet`) must be chosen separately
  from subdivision ranks rather than competing with them on distance.
- The vocabulary prefix lookup matches "Славсько" against every indexed word
  starting with that prefix: "Славсько" itself, "Славського", "Славське" and so
  on. Without a per-word exact/prefix distinction they all score 1.0, and a
  search for the town of Славсько returns Головецьке лісництво Славського ДЛГ
  and Нижньорожанківська школа (which contains "Славсько" in its context) ahead
  of the town. Tracking whether each query word matched the place's name as an
  exact word, and ordering by `-exact_count`, puts the town itself first and
  moves the prefix-only POIs behind the long press. Areas vs POIs need a second
  sort key: with thousands of "Львів" hits all exact-matched, the city only
  wins because `place=*` and `boundary=administrative` outrank every POI type.
- The 2020 raion reform is reflected in the data: the test point is in
  `Стрийський район`, not the pre-reform Сколівський. Trust the extract, not
  older sources.
- POIs frequently carry no `addr:*` tags at all. The test hotel (node
  4289542373, `tourism=hotel`) has none, so its street can only come from a
  spatial join against nearby named highways.

## SQLite

- `LIKE` only case-folds ASCII. A lowercase Cyrillic probe will not match
  capitalised Cyrillic stored text, which silently returns zero rows. Both sides
  must be normalised (casefold + NFKD) in Python before they reach the database.
- The FTS5 trigram tokenizer makes `LIKE '%abc%'` an indexed operation, but only
  for patterns of at least three characters.
- A trigram index finds nothing for a short misspelled word: "двир" and "двір"
  share no three characters in a row, and neither do "славско" and "славсько".
  Fuzzy matching over an index alone therefore cannot be complete - something
  has to fall back to comparing the words themselves.

## Flutter / Android

- The `sqlite3` Dart package on pub (3.6.0) bundles a recent SQLite with FTS5
  via its native build hooks, so the older `sqlite3_flutter_libs` package is
  EOL and unnecessary. Drop-in replacement.
- `flutter_map` 7.x against the volunteer OSM raster tile servers is
  sufficient for a "drop a pin on the map" picker without an API key. The
  User-Agent header on the request is required by the OSM tile usage policy -
  it tells their admins who to contact if a user hammers them - and should
  contain an app identifier plus a contact URL or email.
- Some mobile carriers fail DNS for `d.tile.openstreetmap.org` while a/b/c
  still resolve, and corporate firewalls (Datura, etc.) can drop the app's
  network entirely until internet access is granted in their settings. The
  picker therefore rotates `[a, b, c]` rather than `[a, b, c, d]`, and
  treats each tile fetch as a primary URL plus a list of fallback templates -
  expanded to one URL per subdomain so a failing host does not skip the other
  mirrors - before giving up on the tile.
- `flutter_map`'s `FileTileProvider` collides by name with one shipped inside
  `flutter_map_cache`; importing `flutter_map.dart` without `hide FileTileProvider`
  makes the constructor ambiguous. A custom tile provider that does its own disk
  caching also needs `crypto`, `http` and `path` listed explicitly in
  `pubspec.yaml` - they are not transitive deps of `flutter_map`.
- On API 30+ an AndroidManifest must declare `<queries>` for any intent it
  wants to start externally, otherwise the package manager returns zero
  resolvers and `url_launcher` opens nothing. For `geo:` URIs that is
  `<intent><action android:name="android.intent.action.VIEW"/><data android:scheme="geo"/></intent>`.
- Scoped storage (API 29+) makes `/sdcard/Android/data/<other-app>/` off-limits
  to a regular app. There is no workaround - the file must come in through
  the Storage Access Framework (`Intent.ACTION_OPEN_DOCUMENT`). The picker
  hands back a `content://` URI; SQLite's C library cannot open a content
  URI directly, so the file must be stream-copied into the app's own
  `filesDir` first via `ContentResolver.openInputStream` and then opened by
  path. The copy is a one-time cost (Lviv index ~91 MB) and lives under
  `getApplicationDocumentsDirectory()` until the app is uninstalled or the
  user picks "Remove index".
- `LocationManager` (no Play Services) works on F-Droid-clean devices. The
  manifest must request both `ACCESS_COARSE_LOCATION` and
  `ACCESS_FINE_LOCATION`; on API 31+ runtime grant is also needed.
- Gradle does not find a usable JDK on Fedora by default:
  `/usr/lib/jvm/java-25-openjdk` has no `JAVA_COMPILER` (it's a JRE) and
  `java-21-openjdk` is the same. The Temurin install under
  `~/dotfiles/local/share/jdk` works for AGP 8.x. Set `JAVA_HOME` for the
  build; do not change global Flutter config - a missing `JAVA_HOME` makes
  Gradle fall back to the broken default and fail with a vague "does not
  provide JAVA_COMPILER" error.
- Flutter template signs release builds with the auto-generated debug
  keystore. Fine for sideloading, not for Play.

## Python

- `difflib.SequenceMatcher(...).ratio()` costs ~30 µs a pair, most of it in
  building `__chain_b` for the second string. Scoring a query word against the
  ~30 words of a place is ~1 ms, so anything that does it per candidate row is
  limited to a few hundred rows per query. Comparing against the 114k distinct
  words once, and reaching places through the word index, is what makes it
  affordable - and skipping candidates whose first letter differs cuts what is
  left by about 8x.

## Geofabrik

- Ukraine is **not** split into oblast sub-extracts; only
  `europe/ukraine-latest.osm.pbf` exists (~837 MB as of 2026-09). Regional runs
  therefore clip a bbox out of the country file rather than downloading less.

## Measured cost (whole of Ukraine, 8-core Fedora box, 31 GB RAM)

| pass | time | peak RSS |
|---|---|---|
| tag-filtered scan, no geometry | 11 s | low |
| named ways with node locations | 57 s | 2.0 GB |
| administrative area assembly | 82 s | 4.8 GB |

Whole-country named objects: 326k nodes, 649k ways, 119k relations, 44k place
nodes, 9.7k administrative areas. Small enough that no disk-backed node index or
pre-clipping is needed.

Pass 1 streams the whole country even for a single oblast, so it is cached.
Lviv oblast + padding retains 430 admin areas, 11.8k place nodes and 77.4k
streets; the cache is 29 MB and loads in 0.8 s.

The obf step for Lviv (400,216 synthetic nodes) takes 281 s wall: 9 s to probe
1,013 categories, ~4 min in generate-poi, the rest in the verification pass.
The result is 320 MB - 265 MB before rejected categories were rescued. The POI
name index is what dominates that size: at `--chars-build-poi-nameindex=3` it
holds 145,380 prefixes over 36.6M tokens.

Per-place context costs ~1 ms rural, ~1.6 ms in central Lviv. Reaching that
needed three things, each of which had made the first implementation roughly
50x slower:

- never call `shapely.affinity.scale()` per candidate to convert degrees to
  metres - use arithmetic, and numpy over the candidate array
- call `shapely.prepare()` once on the admin polygons, or every
  point-in-polygon test rebuilds the structure for a 50k-vertex oblast
- do a single wide tree query and filter by rank with numpy masks, rather than
  one query per radius
