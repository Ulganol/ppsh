import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:path_provider/path_provider.dart';

final _rnd = Random.secure();
String randStr(int n, [String chars = 'abcdefghijklmnopqrstuvwxyz0123456789']) =>
    List.generate(n, (_) => chars[_rnd.nextInt(chars.length)]).join();
String randomKey() => List.generate(4, (_) => randStr(4)).join('-');

String fmtSize(int b) {
  if (b < 1024) return '$b Б';
  if (b < 1048576) return '${(b / 1024).toStringAsFixed(1)} КБ';
  if (b < 1073741824) return '${(b / 1048576).toStringAsFixed(1)} МБ';
  return '${(b / 1073741824).toStringAsFixed(2)} ГБ';
}

class Settings {
  bool dark;
  int maxFileMb; // файлы до этого размера сохраняются автоматически
  int capMb; // лимит папки с файлами, 0 = без лимита
  String uid;
  Settings(this.dark, this.maxFileMb, this.capMb, this.uid);
  factory Settings.fromJson(dynamic j, bool defaultDark) {
    if (j is! Map) return Settings(defaultDark, 25, 2048, randStr(16));
    return Settings(j['dark'] ?? defaultDark, j['max'] ?? 25, j['cap'] ?? 2048, j['uid'] ?? randStr(16));
  }
  Map<String, dynamic> toJson() => {'dark': dark, 'max': maxFileMb, 'cap': capMb, 'uid': uid};
}

class Store {
  static late Directory root, filesDir, tmpDir;

  static Future<void> init() async {
    final d = await getApplicationSupportDirectory();
    root = Directory('${d.path}/p2pchat')..createSync(recursive: true);
    filesDir = Directory('${root.path}/files')..createSync(recursive: true);
    tmpDir = Directory('${root.path}/tmp');
    if (tmpDir.existsSync()) tmpDir.deleteSync(recursive: true);
    tmpDir.createSync(recursive: true);
  }

  static String filePath(String fid) => '${filesDir.path}/$fid';
  static bool has(String fid) => File(filePath(fid)).existsSync();
  static String chatPath(String id) => '${root.path}/chat_$id.json';

  static Future<dynamic> readJson(String name) async {
    try {
      final f = File(name.startsWith('/') || name.contains(':') ? name : '${root.path}/$name');
      if (!await f.exists()) return null;
      return jsonDecode(await f.readAsString());
    } catch (_) {
      return null;
    }
  }

  static Future<void> writeJson(String name, dynamic v) async {
    try {
      final path = name.startsWith('/') || name.contains(':') ? name : '${root.path}/$name';
      final tmp = File('$path.tmp');
      await tmp.writeAsString(jsonEncode(v));
      await tmp.rename(path);
    } catch (_) {}
  }

  static int usedBytes() {
    var t = 0;
    for (final e in filesDir.listSync()) {
      if (e is File) t += e.lengthSync();
    }
    return t;
  }

  /// Удаляет самые старые файлы, пока папка не уложится в лимит.
  static void prune(int capMb) {
    if (capMb <= 0) return;
    final cap = capMb * 1024 * 1024;
    final files = filesDir.listSync().whereType<File>().map((f) => (f, f.statSync())).toList();
    var total = files.fold<int>(0, (a, e) => a + e.$2.size);
    if (total <= cap) return;
    files.sort((a, b) => a.$2.modified.compareTo(b.$2.modified));
    for (final e in files) {
      if (total <= cap) break;
      try {
        e.$1.deleteSync();
        total -= e.$2.size;
      } catch (_) {}
    }
  }

  static void clearFiles() {
    for (final e in filesDir.listSync()) {
      try {
        e.deleteSync();
      } catch (_) {}
    }
  }
}
