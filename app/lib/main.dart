/// Search the map index, hand the hit to a maps app.
///
/// OsmAnd finds a POI by its own name and nothing else, and not at all if the
/// name is mistyped. This searches the index built by `mapidx` - names plus
/// the village, street and hromada around them, typo-tolerant - and opens what
/// you pick in any map app that handles `geo:` URIs. Nothing here needs the
/// network.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

import 'src/from_sheet.dart';
import 'src/here.dart';
import 'src/index.dart';
import 'src/map_picker.dart';
import 'src/origin.dart';
import 'src/search.dart';
import 'src/theme.dart';

const _debounce = Duration(milliseconds: 250);

void main() {
  runApp(const MapIndexApp());
}

class MapIndexApp extends StatelessWidget {
  const MapIndexApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'MapIdx',
        theme: theme(),
        debugShowCheckedModeBanner: false,
        home: const SearchPage(),
      );
}

class SearchPage extends StatefulWidget {
  const SearchPage({super.key});

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final _where = TextEditingController();
  final _here = Here();

  Index? _index;
  String? _trouble;
  var _working = false;

  Timer? _pending;
  List<Hit> _hits = const [];
  var _query = '';
  var _searching = false;
  var _hasText = false;
  Origin? _origin;

  @override
  void initState() {
    super.initState();
    _where.addListener(() {
      if (_where.text.isEmpty != _hasText) {
        setState(() => _hasText = _where.text.isNotEmpty);
      }
    });
    _here.addListener(_onHere);
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _trouble = null;
      _index = null;
    });
    try {
      final index = await Index.openStored();
      if (!mounted) return index?.dispose();
      setState(() => _index = index);
    } catch (error) {
      if (mounted) setState(() => _trouble = '$error');
    }
  }

  Future<void> _import() async {
    setState(() {
      _trouble = null;
      _working = true;
    });
    try {
      final index = await Index.import();
      if (!mounted) return;
      setState(() {
        _index = index;
        _working = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _trouble = '$error';
        _working = false;
      });
    }
  }

  Future<void> _replace() async {
    final old = _index;
    setState(() => _index = null);
    old?.dispose();
    await Index.forget();
    await _import();
  }

  Future<void> _remove() async {
    _index?.dispose();
    await Index.forget();
    if (mounted) setState(() => _index = null);
  }

  void _typedSomething(String query) {
    _pending?.cancel();
    _pending = Timer(_debounce, () => _find(query));
  }

  Future<void> _find(String query) async {
    final index = _index;
    if (index == null) return;
    _query = query;
    if (query.trim().isEmpty) {
      setState(() => _hits = const []);
      return;
    }
    setState(() => _searching = true);
    final origin = _origin;
    final hits = await index.find(
      query,
      origin: origin == null ? null : (origin.lat, origin.lon),
    );
    if (!mounted || _query != query) return;
    setState(() {
      _hits = hits;
      _searching = false;
    });
  }

  void _onHere() {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.clearSnackBars();
    switch (_here.state) {
      case Locating.on:
        if (_here.at != null && _origin?.kind != OriginKind.gps) {
          setState(() => _origin = Origin.gps(_here.at!.$1, _here.at!.$2));
          messenger.showSnackBar(const SnackBar(
            duration: Duration(seconds: 2),
            content: Text('Distances from your location'),
          ));
        }
      case Locating.waiting:
        messenger.showSnackBar(const SnackBar(
          duration: Duration(seconds: 2),
          content: Text('Waiting for the first GPS fix'),
        ));
      case Locating.denied:
        messenger.showSnackBar(const SnackBar(
          content: Text('Location is off or refused'),
        ));
      case Locating.off:
        if (_origin?.kind == OriginKind.gps) {
          setState(() => _origin = null);
        }
    }
    if (_query.isNotEmpty) _find(_query);
  }

  Future<void> _pickFromSearch() async {
    final index = _index;
    if (index == null) return;
    final hit = await showFromSheet(context, index);
    if (hit == null || !mounted) return;
    _here.stop();
    setState(() => _origin = Origin.place(hit, lat: hit.lat, lon: hit.lon));
    if (_query.isNotEmpty) _find(_query);
  }

  Future<void> _pickOnMap() async {
    final initial = _origin == null
        ? null
        : LatLng(_origin!.lat, _origin!.lon);
    final picked = await Navigator.of(context).push<LatLng>(
      MaterialPageRoute(builder: (_) => MapPickerPage(initial: initial)),
    );
    if (picked == null || !mounted) return;
    _here.stop();
    setState(() => _origin = Origin.map(picked.latitude, picked.longitude));
    if (_query.isNotEmpty) _find(_query);
  }

  void _clearOrigin() {
    _here.stop();
    setState(() => _origin = null);
    if (_query.isNotEmpty) _find(_query);
  }

  void _toggleGps() {
    if (_origin?.kind == OriginKind.gps) {
      _here.stop();
      setState(() => _origin = null);
    } else {
      _here.start();
    }
  }

  Future<void> _open(Hit hit) async {
    final label = Uri.encodeComponent(hit.name);
    final where = '${hit.lat.toStringAsFixed(6)},${hit.lon.toStringAsFixed(6)}';
    final opened = await launchUrl(
      Uri.parse('geo:$where?q=$where($label)'),
      mode: LaunchMode.externalApplication,
    );
    if (!opened && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No app on the phone opens geo: links')),
      );
    }
  }

  void _showDetails(Hit hit) {
    final related = hit.exactCount > 0
        ? _hits.where((h) => h.exactCount == 0).take(30).toList()
        : const <Hit>[];
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => _Details(
        hit: hit,
        related: related,
        origin: _origin,
        onOpen: () {
          Navigator.of(context).pop();
          _open(hit);
        },
        onRelated: (h) {
          Navigator.of(context).pop();
          _showDetails(h);
        },
      ),
    );
  }

  /// Hits the user should see inline. When the query hit an area exactly
  /// ("Славсько" -> the town) the prefix-only POIs share the same words but
  /// are not what was asked for; they wait behind the long press instead.
  List<Hit> _primaryHits() {
    if (_hits.isEmpty) return _hits;
    if (_hits.first.exactCount == 0) return _hits;
    return _hits.where((h) => h.exactCount > 0).toList();
  }

  @override
  void dispose() {
    _pending?.cancel();
    _where.dispose();
    _here.removeListener(_onHere);
    _here.dispose();
    _index?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: const Text('MapIdx'),
          actions: [
            if (_index != null)
              PopupMenuButton<_Menu>(
                tooltip: 'Index',
                onSelected: (item) async {
                  switch (item) {
                    case _Menu.replace:
                      await _replace();
                    case _Menu.remove:
                      await _remove();
                  }
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: _Menu.replace, child: Text('Replace index')),
                  PopupMenuItem(value: _Menu.remove, child: Text('Remove index')),
                ],
              ),
          ],
          bottom: const PreferredSize(
            preferredSize: Size.fromHeight(2),
            child: SizedBox(height: 2),
          ),
        ),
        body: _index == null
            ? _Landing(
                trouble: _trouble,
                working: _working,
                onImport: _import,
              )
            : Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                    child: _WhereField(
                      controller: _where,
                      hasText: _hasText,
                      onChanged: _typedSomething,
                      onClear: () {
                        _where.clear();
                        _find('');
                      },
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                    child: _OriginCard(
                      origin: _origin,
                      gpsState: _here.state,
                      onSearch: _pickFromSearch,
                      onGps: _toggleGps,
                      onMap: _pickOnMap,
                      onClear: _clearOrigin,
                    ),
                  ),
                  Expanded(
                    child: _searching && _hits.isEmpty
                        ? const SizedBox.shrink()
                        : _Hits(
                            hits: _primaryHits(),
                            onTap: _open,
                            onLongPress: _showDetails,
                            typed: _query,
                          ),
                  ),
                ],
              ),
      );
}

enum _Menu { replace, remove }

class _WhereField extends StatelessWidget {
  const _WhereField({
    required this.controller,
    required this.hasText,
    required this.onChanged,
    required this.onClear,
  });

  final TextEditingController controller;
  final bool hasText;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) => TextField(
        controller: controller,
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          prefixIcon: const Icon(Icons.search),
          hintText: 'Search by name, street, or village',
          filled: true,
          fillColor: panel,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide.none,
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide.none,
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: accent, width: 1.5),
          ),
          suffixIcon: hasText
              ? IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: onClear,
                )
              : null,
        ),
        onChanged: onChanged,
      );
}

class _OriginCard extends StatelessWidget {
  const _OriginCard({
    required this.origin,
    required this.gpsState,
    required this.onSearch,
    required this.onGps,
    required this.onMap,
    required this.onClear,
  });

  final Origin? origin;
  final Locating gpsState;
  final VoidCallback onSearch;
  final VoidCallback onGps;
  final VoidCallback onMap;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final hasOrigin = origin != null;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      decoration: BoxDecoration(
        color: panel,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(
            hasOrigin ? Icons.my_location : Icons.location_searching,
            color: hasOrigin ? accent : Colors.white.withValues(alpha: 0.5),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  hasOrigin ? 'Distance from' : 'No origin set',
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.white.withValues(alpha: 0.6),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  origin?.describe() ?? 'Pick a place, your GPS, or a map point',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w500),
                ),
              ],
            ),
          ),
          if (hasOrigin)
            IconButton(
              tooltip: 'Clear origin',
              onPressed: onClear,
              icon: const Icon(Icons.close),
            ),
          IconButton(
            tooltip: 'Search a place',
            onPressed: onSearch,
            icon: const Icon(Icons.search),
          ),
          IconButton(
            tooltip: gpsState == Locating.on
                ? 'Stop using GPS'
                : 'Use my location',
            onPressed: onGps,
            icon: Icon(
              gpsState == Locating.on ? Icons.gps_fixed : Icons.gps_not_fixed,
              color: gpsState == Locating.on ? accent : null,
            ),
          ),
          IconButton(
            tooltip: 'Pick on map',
            onPressed: onMap,
            icon: const Icon(Icons.map),
          ),
        ],
      ),
    );
  }
}

class _Hits extends StatelessWidget {
  const _Hits({
    required this.hits,
    required this.onTap,
    required this.onLongPress,
    required this.typed,
  });

  final List<Hit> hits;
  final void Function(Hit hit) onTap;
  final void Function(Hit hit) onLongPress;
  final String typed;

  @override
  Widget build(BuildContext context) {
    if (hits.isEmpty) {
      return Center(
        child: Text(
          typed.trim().isEmpty ? 'Type to search' : 'Nothing like that',
          style: TextStyle(color: Colors.white.withValues(alpha: 0.5)),
        ),
      );
    }
    return ListView.separated(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      itemCount: hits.length,
      separatorBuilder: (_, _) => const Divider(),
      itemBuilder: (context, i) {
        final hit = hits[i];
        return ListTile(
          title: Text(hit.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            _subtitle(hit),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: Colors.white.withValues(alpha: 0.7)),
          ),
          trailing: hit.metres == null ? null : Text(_away(hit.metres!)),
          onTap: () => onTap(hit),
          onLongPress: () => onLongPress(hit),
        );
      },
    );
  }
}

/// The category as readable words: `amenity=pharmacy` becomes
/// `amenity · pharmacy`, which is what tells identical names apart.
String _kind(String category) {
  final pair = category.split('=');
  if (pair.length != 2) return category;
  return '${pair[0]} · ${pair[1].replaceAll('_', ' ')}';
}

/// The subtitle sorts out hits that share a name: the kind first when there
/// is one, then the short address.
String _subtitle(Hit hit) {
  final address = _shortAddress(hit.address);
  final kind = hit.isArea ? '' : _kind(hit.category);
  if (kind.isEmpty) return address;
  if (address.isEmpty) return kind;
  return '$kind, $address';
}

/// OsmAnd-style short subtitle: at most the first settlement and the first
/// street. The raion, hromada and region are in the same brackets but the
/// user has not asked for them; the long press shows the full address.
String _shortAddress(List<String> parts) {
  if (parts.isEmpty) return '';
  final street = parts.firstWhere(
      (part) => part.startsWith('вулиця ') || part.startsWith('площа '),
      orElse: () => '');
  final settlement = parts.firstWhere(
      (part) => !part.startsWith('вулиця ') && !part.startsWith('площа '),
      orElse: () => '');
  if (street.isEmpty) return settlement;
  if (settlement.isEmpty) return street;
  return '$settlement, $street';
}

String _away(double metres) => metres < 1000
    ? '${metres.round()} m'
    : '${(metres / 1000).toStringAsFixed(metres < 10000 ? 1 : 0)} km';

class _Details extends StatelessWidget {
  const _Details({
    required this.hit,
    required this.related,
    required this.origin,
    required this.onOpen,
    required this.onRelated,
  });

  final Hit hit;
  final List<Hit> related;
  final Origin? origin;
  final VoidCallback onOpen;
  final void Function(Hit hit) onRelated;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(hit.name, style: theme.textTheme.titleLarge),
            const SizedBox(height: 4),
            Text(_kind(hit.category),
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: Colors.white.withValues(alpha: 0.8),
                )),
            if (hit.address.isNotEmpty) ...[
              const SizedBox(height: 8),
              for (final line in hit.address)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(line,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: Colors.white.withValues(alpha: 0.8),
                      )),
                ),
            ],
            const SizedBox(height: 16),
            Text('Matched words', style: theme.textTheme.labelLarge),
            const SizedBox(height: 4),
            for (final word in hit.matched)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Row(
                  children: [
                    Expanded(child: Text(word.word)),
                    Text(_score(word.score),
                        style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.7))),
                  ],
                ),
              ),
            if (hit.metres != null && origin != null) ...[
              const SizedBox(height: 16),
              Text('${_away(hit.metres!)} from ${origin!.describe()}',
                  style: TextStyle(color: Colors.white.withValues(alpha: 0.7))),
            ],
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: onOpen,
                icon: const Icon(Icons.map),
                label: const Text('Open in maps'),
              ),
            ),
            if (related.isNotEmpty) ...[
              const SizedBox(height: 24),
              Text('Other places matching these words',
                  style: theme.textTheme.labelLarge),
              const SizedBox(height: 4),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 240),
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: related.length,
                  itemBuilder: (_, i) {
                    final other = related[i];
                    return ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text(other.name,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(_subtitle(other),
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      onTap: () => onRelated(other),
                    );
                  },
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

String _score(double score) => score >= 0.999 ? '1.00' : score.toStringAsFixed(2);

class _Landing extends StatelessWidget {
  const _Landing({required this.trouble, required this.working, required this.onImport});

  final String? trouble;
  final bool working;
  final VoidCallback onImport;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              trouble == null ? 'No index imported' : trouble!,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            const Text(
              'Pick the file ending in -search.sqlite. The app copies it into its '
              'own storage so it can read the database by path. Nothing leaves '
              'the phone.',
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: working ? null : onImport,
              child: Text(working ? 'Importing...' : 'Pick index file'),
            ),
          ],
        ),
      );
}