/// Tile provider that caches raster tiles on disk with a TTL.
///
/// A tile is fetched over HTTPS the first time the map shows it, saved to
/// `cacheDir`, and served from there on every subsequent render until it
/// goes older than `maxAge`. Stale tiles are re-fetched in the background -
/// they still paint while the fresh copy is downloading.
///
/// The OSM/Carto tile servers are happy with this because a tile only changes
/// when the underlying map data changes; cache misses come back fast.
///
/// Mobile carriers sometimes fail DNS for one CDN host while another works,
/// so each tile is tried against every URL in [fallbackUrls] in order until
/// one succeeds. The first successful response is what gets cached - the
/// failure is forgotten once the next tile renders.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart' show TileCoordinates, TileLayer, TileProvider;
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

/// Paints tiles from disk when fresh, falls back to network and writes the
/// result back. Cache misses are transparently written so the second render
/// is local.
class FileTileProvider extends TileProvider {
  FileTileProvider({
    required this.cacheDir,
    required this.userAgent,
    this.maxAge = const Duration(days: 7),
    this.fallbackUrls = const [],
  });

  final Directory cacheDir;
  final String userAgent;
  final Duration maxAge;

  /// Additional tile URLs to try in order when the primary one fails (DNS,
  /// timeout, 4xx/5xx). Useful when the user's network resolves one CDN host
  /// but not another.
  final List<String> fallbackUrls;

  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) {
    final primary = super.getTileUrl(coordinates, options);
    // A fallback template containing `{s}` is expanded once per subdomain so
    // a tile where the primary host fails still gets every available mirror
    // tried before giving up, not just whichever (x+y+z) mod len picks.
    final alts = <String>[];
    for (final tpl in fallbackUrls) {
      if (tpl.contains('{s}')) {
        for (final s in options.subdomains) {
          alts.add(_render(tpl, coordinates, options, s));
        }
      } else {
        alts.add(_render(tpl, coordinates, options, null));
      }
    }
    return _CachedTile(
      urls: [primary, ...alts],
      file: File(p.join(cacheDir.path, sha1.convert(utf8.encode(primary)).toString())),
      userAgent: userAgent,
      maxAge: maxAge,
    );
  }
}

String _render(String template, TileCoordinates c, TileLayer options, String? subdomain) {
  return template
      .replaceAll('{s}', subdomain ?? options.subdomains.first)
      .replaceAll('{z}', c.z.toString())
      .replaceAll('{x}', c.x.toString())
      .replaceAll('{y}', c.y.toString());
}

class _CachedTile extends ImageProvider<_CachedTile> {
  const _CachedTile({
    required this.urls,
    required this.file,
    required this.userAgent,
    required this.maxAge,
  });

  /// Tried in order. The first success wins; failures are skipped silently
  /// because a failing tile is reported separately by FlutterMap.
  final List<String> urls;
  final File file;
  final String userAgent;
  final Duration maxAge;

  @override
  Future<_CachedTile> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture(this);
  }

  @override
  ImageStreamCompleter loadImage(_CachedTile key, ImageDecoderCallback decode) {
    return MultiFrameImageStreamCompleter(
      codec: _resolve(decode),
      scale: 1.0,
    );
  }

  Future<ui.Codec> _resolve(ImageDecoderCallback decode) async {
    if (await _fresh()) {
      return decode(await ui.ImmutableBuffer.fromUint8List(await file.readAsBytes()));
    }
    Object? lastError;
    for (final url in urls) {
      try {
        final response = await http.get(Uri.parse(url),
            headers: {'User-Agent': userAgent});
        if (response.statusCode != 200) {
          lastError = 'HTTP ${response.statusCode}';
          continue;
        }
        final bytes = response.bodyBytes;
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes, flush: true);
        return await decode(await ui.ImmutableBuffer.fromUint8List(bytes));
      } catch (error) {
        lastError = error;
      }
    }
    throw StateError('all tile URLs failed ($lastError): $urls');
  }

  Future<bool> _fresh() async {
    if (!file.existsSync()) return false;
    final modified = file.statSync().modified;
    return DateTime.now().difference(modified) <= maxAge;
  }

  @override
  bool operator ==(Object other) =>
      other is _CachedTile && other.urls.first == urls.first;

  @override
  int get hashCode => urls.first.hashCode;
}