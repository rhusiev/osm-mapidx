/// Pick a point on a slippy map and return its (lat, lon).
///
/// Tiles come from the volunteer OpenStreetMap raster servers, which serve
/// the same tiles under the ODbL without an API key. The User-Agent header
/// identifies the app per the OSM tile usage policy. Attribution is shown
/// on screen as required by the licence.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart' hide FileTileProvider;
import 'package:latlong2/latlong.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'theme.dart';
import 'tile_cache.dart';

class MapPickerPage extends StatefulWidget {
  const MapPickerPage({super.key, this.initial});

  /// Where the map centres on first open. Defaults to central Lviv.
  final LatLng? initial;

  @override
  State<MapPickerPage> createState() => _MapPickerPageState();
}

class _MapPickerPageState extends State<MapPickerPage> {
  late final MapController _controller = MapController();
  LatLng? _picked;
  FileTileProvider? _tiles;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _setup();
  }

  Future<void> _setup() async {
    final root = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(root.path, 'tiles'));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    setState(() => _tiles = FileTileProvider(
          cacheDir: dir,
          // OSM tile usage policy wants contact info in the UA so their admins
          // can reach an app that misbehaves. The same UA is reused for every
          // fallback host so the same string reaches every server.
          userAgent: 'nl.r1a.mapidx/0.1 (https://github.com/rhusiev/osm-mapidx)',
          fallbackUrls: const [
            // `d.tile.openstreetmap.org` is the host most likely to fail DNS
            // on mobile carriers, so it is not in the rotation at all; a/b/c
            // cover the cases where the no-subdomain host is blocked.
            'https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png',
          ],
        ));
  }

  @override
  Widget build(BuildContext context) {
    final initial = widget.initial ?? const LatLng(49.8397, 24.0297);
    return Scaffold(
      appBar: AppBar(title: const Text('Pick a point')),
      body: _tiles == null
          ? const Center(child: CircularProgressIndicator())
          : Stack(
              children: [
                FlutterMap(
                  mapController: _controller,
                  options: MapOptions(
                    initialCenter: initial,
                    initialZoom: 12,
                    onTap: (_, point) => setState(() => _picked = point),
                  ),
                  children: [
                    TileLayer(
                      urlTemplate:
                          'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                      // `d.tile.openstreetmap.org` fails DNS on some mobile
                      // carriers while a/b/c still resolve, so we keep the
                      // OSM subdomain hosts as fallbacks rather than as the
                      // primary rotation.
                      subdomains: const ['a', 'b', 'c'],
                      tileProvider: _tiles,
                      errorTileCallback: (_, error, _) {
                        if (_error == null) setState(() => _error = error);
                      },
                    ),
                    if (_picked != null)
                      MarkerLayer(
                        markers: [
                          Marker(
                            point: _picked!,
                            width: 40,
                            height: 40,
                            child:
                                Icon(Icons.location_pin, color: accent, size: 40),
                          ),
                        ],
                      ),
                    const RichAttributionWidget(
                      attributions: [
                        TextSourceAttribution('OpenStreetMap contributors'),
                      ],
                    ),
                  ],
                ),
                if (_picked == null)
                  const Positioned(
                    left: 0,
                    right: 0,
                    bottom: 80,
                    child: Center(
                      child: Card(
                        child: Padding(
                          padding: EdgeInsets.symmetric(
                              horizontal: 12, vertical: 8),
                          child: Text('Tap on the map to place a marker'),
                        ),
                      ),
                    ),
                  ),
                if (_error != null)
                  Positioned(
                    left: 12,
                    right: 12,
                    top: 12,
                    child: Card(
                      color: Colors.red.shade900,
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: Text(
                          'Tiles failed to load: $_error',
                          style: const TextStyle(color: Colors.white),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: FilledButton(
            onPressed: _picked == null
                ? null
                : () => Navigator.of(context).pop(_picked),
            child: const Text('Use this point'),
          ),
        ),
      ),
    );
  }
}