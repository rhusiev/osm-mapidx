/// Storage Access Framework wrapper for picking the index file.
///
/// On Android 11+ the OS blocks direct access to
/// `/sdcard/Android/data/<other-package>/`, so the user has to hand the file
/// over via SAF. The picker returns a `content://` URI; we then stream-copy it
/// into the app's own filesDir so the SQLite C library can open it by path.
library;

import 'dart:io';

import 'package:flutter/services.dart';

const _channel = MethodChannel('nl.r1a.mapidx/picker');

/// Open the system file picker. Returns null if the user cancels.
Future<Uri?> pickIndex() async {
  final result = await _channel.invokeMethod<String>('pick');
  return result == null ? null : Uri.parse(result);
}

/// Stream the file at [src] into the app's filesDir under [name]. Returns the
/// absolute path of the copy.
Future<String> importTo(Uri src, {required String name}) async {
  final path = await _channel.invokeMethod<String>(
    'import',
    <String, String>{'uri': src.toString(), 'name': name},
  );
  if (path == null) {
    throw const FileSystemException('Import returned no path');
  }
  return path;
}