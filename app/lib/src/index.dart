/// The index file, open in an isolate of its own.
///
/// A query takes a few milliseconds on a desktop and some tens on a phone,
/// which is enough to drop frames if it runs between them. The database is
/// opened once in a background isolate and kept there; the UI sends a string
/// and gets hits back. Answers to queries the user has already typed past are
/// dropped on arrival rather than cancelled - there is nothing to cancel.
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/sqlite3.dart';

import 'picker.dart';
import 'search.dart';

const _prefPath = 'nl.r1a.mapidx.indexPath';

class _Request {
  const _Request(this.id, this.query, this.limit, this.origin);

  final int id;
  final String query;
  final int limit;
  final (double, double)? origin;
}

class _Answer {
  const _Answer(this.id, this.hits, this.error);

  final int id;
  final List<Hit> hits;
  final Object? error;
}

/// Where imported index files live. Writable only by this app, survives until
/// uninstall, picked-and-copied here so the SQLite C library can open them by
/// path.
Future<Directory> indexDir() async {
  final root = await getApplicationDocumentsDirectory();
  final dir = Directory('${root.path}/index');
  if (!dir.existsSync()) dir.createSync(recursive: true);
  return dir;
}

class Index {
  Index._(this._isolate, this._answers, this._requests);

  final Isolate _isolate;
  final ReceivePort _answers;
  final SendPort _requests;
  final _waiting = <int, Completer<List<Hit>>>{};
  var _next = 0;

  /// Open the previously-imported index, or null if none / the file is gone.
  static Future<Index?> openStored() async {
    final path = await _readPath();
    if (path == null) return null;
    if (!File(path).existsSync()) {
      await _writePath(null);
      return null;
    }
    try {
      return await open(path);
    } catch (_) {
      await _writePath(null);
      return null;
    }
  }

  /// Open a known-good index file.
  static Future<Index> open(String path) async {
    final answers = ReceivePort();
    final isolate = await Isolate.spawn(_serve, (path, answers.sendPort));
    final stream = answers.asBroadcastStream();
    final first = await stream.first;
    if (first is! SendPort) {
      isolate.kill(priority: Isolate.immediate);
      answers.close();
      throw StateError('$first');
    }
    final index = Index._(isolate, answers, first);
    stream.listen(index._arrived);
    return index;
  }

  /// Let the user pick an index file, copy it into our storage, and open it.
  /// Returns null if the user cancelled the picker.
  static Future<Index?> import() async {
    final src = await pickIndex();
    if (src == null) return null;
    final name = src.pathSegments.isNotEmpty ? src.pathSegments.last : 'index.sqlite';
    final path = await importTo(src, name: name);
    await _writePath(path);
    return await open(path);
  }

  /// Forget the imported file. The next launch will ask for it again.
  static Future<void> forget() async {
    final path = await _readPath();
    if (path != null) {
      final file = File(path);
      if (file.existsSync()) file.deleteSync();
    }
    await _writePath(null);
  }

  Future<List<Hit>> find(String query,
      {int limit = 30, (double, double)? origin}) {
    final id = _next++;
    final answer = Completer<List<Hit>>();
    _waiting[id] = answer;
    _requests.send(_Request(id, query, limit, origin));
    return answer.future;
  }

  void _arrived(dynamic message) {
    final answer = message as _Answer;
    final waiting = _waiting.remove(answer.id);
    if (waiting == null) return;
    if (answer.error != null) {
      waiting.completeError(answer.error!);
    } else {
      waiting.complete(answer.hits);
    }
  }

  void dispose() {
    _isolate.kill(priority: Isolate.immediate);
    _answers.close();
  }
}

Future<String?> _readPath() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getString(_prefPath);
}

Future<void> _writePath(String? path) async {
  final prefs = await SharedPreferences.getInstance();
  if (path == null) {
    await prefs.remove(_prefPath);
  } else {
    await prefs.setString(_prefPath, path);
  }
}

void _serve((String, SendPort) boot) {
  final (path, answers) = boot;
  final Database db;
  try {
    db = sqlite3.open(path, mode: OpenMode.readOnly);
  } catch (error) {
    answers.send('$error');
    return;
  }

  final requests = ReceivePort();
  answers.send(requests.sendPort);
  requests.listen((message) {
    final request = message as _Request;
    try {
      answers.send(_Answer(
        request.id,
        search(db, request.query, limit: request.limit, origin: request.origin),
        null,
      ));
    } catch (error) {
      answers.send(_Answer(request.id, const [], error));
    }
  });
}