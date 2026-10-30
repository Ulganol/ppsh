import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:crypto/crypto.dart' as hash;
import 'package:cryptography/cryptography.dart' show AesGcm, Hmac, Pbkdf2, SecretBox, SecretKey;
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:open_filex/open_filex.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'store.dart';

const chunk = 32768;
const _mb = 1024 * 1024;
final _fidRe = RegExp(r'^[0-9a-f]{64}$');

// ---------- модели ----------

class FileRef {
  final String fid, name;
  final int size;
  FileRef(this.fid, this.name, this.size);
  Map<String, dynamic> toJson() => {'h': fid, 'n': name, 's': size};
  factory FileRef.fromJson(Map j) {
    final h = j['h'], n = j['n'], s = j['s'];
    if (h is! String || !_fidRe.hasMatch(h) || n is! String || s is! int || s < 0) {
      throw const FormatException();
    }
    return FileRef(h, n.length > 200 ? n.substring(0, 200) : n, s);
  }

  bool get isImage {
    final e = name.toLowerCase().split('.').last;
    return const {'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp'}.contains(e);
  }
}

class Msg {
  final String id, nick, text, uid;
  final int ts;
  final FileRef? file;
  Msg(this.id, this.ts, this.nick, this.text, this.uid, this.file);
  Map<String, dynamic> toJson() =>
      {'id': id, 'ts': ts, 'n': nick, 'x': text, 'u': uid, if (file != null) 'f': file!.toJson()};
  factory Msg.fromJson(Map j) {
    final id = j['id'], ts = j['ts'], n = j['n'], x = j['x'], u = j['u'];
    if (id is! String || id.isEmpty || id.length > 64 || ts is! int || n is! String || x is! String || u is! String) {
      throw const FormatException();
    }
    final f = j['f'] == null ? null : FileRef.fromJson(Map.from(j['f']));
    return Msg(id, ts, n.length > 40 ? n.substring(0, 40) : n, x.length > 4000 ? x.substring(0, 4000) : x,
        u.length > 64 ? u.substring(0, 64) : u, f);
  }
}

class ChatInfo {
  String key, nick, title;
  ChatInfo(this.key, this.nick, this.title);
  Map<String, dynamic> toJson() => {'key': key, 'nick': nick, 'title': title};
  factory ChatInfo.fromJson(Map j) => ChatInfo(j['key'], j['nick'], j['title']);
}

class Conn {
  Conn(this.pc, this.offerer);
  final RTCPeerConnection pc;
  final bool offerer;
  String offerId = '', remoteId = '', localSdp = '';
  RTCDataChannel? ch;
  bool open = false, dead = false;
  int bad = 0;
  final created = DateTime.now();
}

class Dl {
  Dl(this.ref);
  final FileRef ref;
  bool running = false;
  String? peerId;
  final tried = <String>{};
  List<bool> got = [];
  int received = 0, total = 0, winStart = 0, winEnd = 0;
  RandomAccessFile? raf;
  File? tmp;
  DateTime last = DateTime.now();
  String status = 'queued'; // queued | run | unavailable
}

// ---------- комната ----------

const _trackers = [
  'wss://tracker.openwebtorrent.com',
  'wss://tracker.webtorrent.dev',
  'wss://tracker.btorrent.xyz',
  'wss://tracker.files.fm:7073/announce',
];

const _rtcConfig = {
  'iceServers': [
    {
      'urls': ['stun:stun.l.google.com:19302', 'stun:stun1.l.google.com:19302', 'stun:global.stun.twilio.com:3478']
    },
    {
      'urls': ['turn:openrelay.metered.ca:80', 'turn:openrelay.metered.ca:443', 'turns:openrelay.metered.ca:443?transport=tcp'],
      'username': 'openrelayproject',
      'credential': 'openrelayproject',
    },
  ],
  'sdpSemantics': 'unified-plan',
};

class Room extends ChangeNotifier {
  Room(this.info, this.settings);
  final ChatInfo info;
  final Settings settings;

  final msgs = <Msg>[];
  final _byId = <String, Msg>{};
  final peers = <String, Conn>{};
  final _conns = <Conn>{};
  final _pending = <String, Conn>{};
  final _socks = <String, WebSocketChannel>{};
  final _dls = <String, Dl>{};
  final myId = randStr(20);
  final _log = <String>[];
  void log(String t) {
    _log.add('${DateTime.now().toIso8601String().substring(11, 19)} $t');
    if (_log.length > 80) _log.removeAt(0);
  }

  int get trackersUp => _socks.length;
  int get trackersTotal => _trackers.length;
  String diag() =>
      'Трекеры: ${_socks.length}/${_trackers.length}\nУчастников подключено: ${peers.length}\nСоединений в процессе: ${_conns.length}\n---\n${_log.join('\n')}';
  final _aes = AesGcm.with256bits();

  late Uint8List _hashBytes;
  late String _ih, id;
  late SecretKey _key;
  Timer? _tickT, _saveT;
  int _tickN = 0;
  bool _closed = false;

  Dl? dl(String fid) => _dls[fid];
  bool mine(Msg m) => m.uid == settings.uid;
  void _notify() {
    if (!_closed) notifyListeners();
  }

  Future<void> start() async {
    final kdf = Pbkdf2(macAlgorithm: Hmac.sha256(), iterations: 20000, bits: 512);
    final k = await kdf.deriveKey(secretKey: SecretKey(utf8.encode(info.key)), nonce: utf8.encode('p2pchat-v1'));
    final out = await k.extractBytes();
    _hashBytes = Uint8List.fromList(out.sublist(0, 20));
    _key = SecretKey(out.sublist(20, 52));
    _ih = String.fromCharCodes(_hashBytes);
    id = _hashBytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    final l = await Store.readJson(Store.chatPath(id));
    if (l is List) {
      for (final x in l) {
        try {
          final m = Msg.fromJson(Map.from(x));
          if (_byId.putIfAbsent(m.id, () => m) == m) msgs.add(m);
        } catch (_) {}
      }
      _sort();
    }
    if (_closed) return;
    _notify();
    for (final u in _trackers) {
      _connectTracker(u);
    }
    _tickT = Timer.periodic(const Duration(seconds: 10), (_) => _tick());
  }

  void _sort() => msgs.sort((a, b) {
        final c = a.ts.compareTo(b.ts);
        return c != 0 ? c : a.id.compareTo(b.id);
      });

  void _saveSoon() {
    _saveT?.cancel();
    _saveT = Timer(const Duration(seconds: 1), _saveNow);
  }

  Future<void> _saveNow() => Store.writeJson(Store.chatPath(id), msgs.map((m) => m.toJson()).toList());

  Future<void> deleteData() async {
    final p = Store.chatPath(id);
    dispose();
    try {
      await File(p).delete();
    } catch (_) {}
  }

  @override
  void dispose() {
    _closed = true;
    _tickT?.cancel();
    _saveT?.cancel();
    for (final s in _socks.values) {
      try {
        s.sink.close();
      } catch (_) {}
    }
    for (final c in _conns.toList()) {
      _drop(c);
    }
    for (final d in _dls.values) {
      try {
        d.raf?.closeSync();
        d.tmp?.deleteSync();
      } catch (_) {}
    }
    super.dispose();
  }

  // ---------- трекеры (поиск участников) ----------

  Future<void> _connectTracker(String url) async {
    if (_closed) return;
    WebSocketChannel? ws;
    try {
      ws = WebSocketChannel.connect(Uri.parse(url));
      await ws.ready;
      final w = ws;
      _socks[url] = w;
      log('трекер подключён: ${Uri.parse(url).host}');
      w.stream.listen((d) => _onTracker(w, d), onDone: () => _retry(url, w), onError: (_) => _retry(url, w));
      _announce(w);
    } catch (e) {
      log('трекер недоступен ${Uri.parse(url).host}: $e');
      _retry(url, ws);
    }
  }

  void _retry(String url, WebSocketChannel? ws) {
    if (ws != null && _socks[url] != ws) return;
    _socks.remove(url);
    if (!_closed) Future.delayed(const Duration(seconds: 15), () => _connectTracker(url));
  }

  void _tsend(WebSocketChannel ws, Map j) {
    try {
      ws.sink.add(jsonEncode(j));
    } catch (_) {}
  }

  Future<void> _announce(WebSocketChannel ws) async {
    try {
      final res = await Future.wait(List.generate(
          3,
          (_) => _newOffer().then<Conn?>((c) => c).catchError((Object e) {
                log('ошибка создания оффера: $e');
                return null;
              })));
      final cs = res.whereType<Conn>().toList();
      if (cs.isEmpty) return;
      _tsend(ws, {
        'action': 'announce',
        'info_hash': _ih,
        'peer_id': myId,
        'numwant': cs.length,
        'offers': [
          for (final c in cs)
            {
              'offer_id': c.offerId,
              'offer': {'type': 'offer', 'sdp': c.localSdp}
            }
        ],
        'uploaded': 0,
        'downloaded': 0,
        'left': 1,
      });
    } catch (e) {
      log('ошибка announce: $e');
    }
  }

  Future<void> _onTracker(WebSocketChannel ws, dynamic raw) async {
    try {
      final j = jsonDecode(raw is String ? raw : utf8.decode(raw));
      if (j is! Map) return;
      if (j['failure reason'] != null) {
        log('трекер: ${j['failure reason']}');
        return;
      }
      if (j['info_hash'] != _ih && j['info_hash'] != id) return;
      final pid = j['peer_id'];
      if (pid is! String || pid == myId) return;
      final oid = j['offer_id'];
      if (oid is! String) return;
      if (j['offer'] is Map) {
        log('получен оффер от ${pid.substring(0, 6)}');
        await _answer(ws, pid, oid, j['offer']);
      } else if (j['answer'] is Map) {
        log('получен ответ от ${pid.substring(0, 6)}');
        final c = _pending.remove(oid);
        if (c != null && !c.dead) {
          c.remoteId = pid;
          await c.pc.setRemoteDescription(RTCSessionDescription(j['answer']['sdp'], 'answer'));
        }
      }
    } catch (e) {
      log('ошибка обработки сообщения трекера: $e');
    }
  }

  Future<void> _gathered(RTCPeerConnection pc) {
    final done = Completer<void>();
    pc.onIceGatheringState = (s) {
      if (s == RTCIceGatheringState.RTCIceGatheringStateComplete && !done.isCompleted) done.complete();
    };
    return done.future.timeout(const Duration(seconds: 6), onTimeout: () {});
  }

  void _watch(Conn c) {
    _conns.add(c);
    c.pc.onConnectionState = (s) {
      log('соединение ${c.remoteId.isEmpty ? '?' : c.remoteId.substring(0, 6)}: ${s.name}');
      if (s == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
          s == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
        _drop(c);
      }
    };
  }

  Future<Conn> _newOffer() async {
    final pc = await createPeerConnection(_rtcConfig);
    final c = Conn(pc, true)..offerId = randStr(20);
    _watch(c);
    c.ch = await pc.createDataChannel('c', RTCDataChannelInit()..ordered = true);
    _wire(c);
    final offer = await pc.createOffer();
    final g = _gathered(pc);
    await pc.setLocalDescription(offer);
    await g;
    final d = await pc.getLocalDescription();
    c.localSdp = d!.sdp!;
    _pending[c.offerId] = c;
    return c;
  }

  Future<void> _answer(WebSocketChannel ws, String pid, String offerId, Map offer) async {
    if (peers.containsKey(pid) || peers.length >= 12) return;
    final pc = await createPeerConnection(_rtcConfig);
    final c = Conn(pc, false)
      ..remoteId = pid
      ..offerId = offerId;
    _watch(c);
    pc.onDataChannel = (ch) {
      c.ch = ch;
      _wire(c);
      if (ch.state == RTCDataChannelState.RTCDataChannelOpen) _onOpen(c);
    };
    await pc.setRemoteDescription(RTCSessionDescription(offer['sdp'], 'offer'));
    final ans = await pc.createAnswer();
    final g = _gathered(pc);
    await pc.setLocalDescription(ans);
    await g;
    final d = await pc.getLocalDescription();
    _tsend(ws, {
      'action': 'announce',
      'info_hash': _ih,
      'peer_id': myId,
      'to_peer_id': pid,
      'offer_id': offerId,
      'answer': {'type': 'answer', 'sdp': d!.sdp},
    });
  }

  void _wire(Conn c) {
    final ch = c.ch!;
    ch.onDataChannelState = (s) {
      if (s == RTCDataChannelState.RTCDataChannelOpen) {
        _onOpen(c);
      } else if (s == RTCDataChannelState.RTCDataChannelClosed) {
        _drop(c);
      }
    };
    ch.onMessage = (m) {
      if (m.isBinary) _onData(c, m.binary);
    };
  }

  void _onOpen(Conn c) {
    if (c.open || c.dead || c.remoteId.isEmpty) return;
    c.open = true;
    log('канал открыт: ${c.remoteId.substring(0, 6)}');
    _pending.remove(c.offerId);
    final ex = peers[c.remoteId];
    if (ex != null && ex != c) {
      // оба соединились друг с другом дважды: оставляем то, где оферит участник с меньшим id
      final keeper = myId.compareTo(c.remoteId) < 0 ? myId : c.remoteId;
      final cKeeps = (c.offerer ? myId : c.remoteId) == keeper;
      if (!cKeeps) {
        _drop(c);
        return;
      }
      peers[c.remoteId] = c;
      _drop(ex, keepEntry: true);
    } else {
      peers[c.remoteId] = c;
    }
    _notify();
    _sendHave(c);
    for (final d in _dls.values) {
      if (d.status == 'unavailable') {
        d.tried.clear();
        d.status = 'queued';
      }
    }
    _pump();
  }

  void _drop(Conn c, {bool keepEntry = false}) {
    if (c.dead) return;
    c.dead = true;
    _conns.remove(c);
    _pending.remove(c.offerId);
    if (!keepEntry && peers[c.remoteId] == c) {
      peers.remove(c.remoteId);
      for (final d in _dls.values) {
        if (d.running && d.peerId == c.remoteId) {
          d.running = false;
          d.status = 'queued';
        }
      }
      if (!_closed) _pump();
      _notify();
    }
    try {
      c.ch?.close();
    } catch (_) {}
    try {
      c.pc.close().whenComplete(() => c.pc.dispose()).ignore();
    } catch (_) {}
  }

  void _tick() {
    _tickN++;
    final now = DateTime.now();
    for (final c in _conns.toList()) {
      if (!c.open && now.difference(c.created).inSeconds > 90) _drop(c);
    }
    for (final d in _dls.values) {
      if (d.running && now.difference(d.last).inSeconds > 15) {
        d.tried.add(d.peerId ?? '');
        d.running = false;
        d.status = 'queued';
      }
    }
    if (_tickN % 3 == 0 && peers.length < 6) {
      for (final ws in _socks.values) {
        _announce(ws);
      }
    }
    _pump();
  }

  // ---------- шифрование и обмен ----------

  Future<void> _send(Conn c, Map j) async {
    try {
      final box = await _aes.encrypt(utf8.encode(jsonEncode(j)), secretKey: _key);
      await c.ch?.send(RTCDataChannelMessage.fromBinary(Uint8List.fromList(box.concatenation())));
    } catch (_) {}
  }

  void _broadcast(Map j, {Conn? except}) {
    for (final c in peers.values) {
      if (c != except) _send(c, j);
    }
  }

  Future<void> _onData(Conn c, Uint8List b) async {
    Map j;
    try {
      final box = SecretBox.fromConcatenation(b, nonceLength: 12, macLength: 16);
      j = jsonDecode(utf8.decode(await _aes.decrypt(box, secretKey: _key)));
    } catch (_) {
      if (++c.bad > 3) _drop(c);
      return;
    }
    try {
      switch (j['t']) {
        case 'have':
          final miss = [
            for (final i in (j['ids'] as List)) if (i is String && i.length <= 64 && !_byId.containsKey(i)) i
          ];
          if (miss.isNotEmpty) _send(c, {'t': 'want', 'ids': miss});
        case 'want':
          final list = [
            for (final i in (j['ids'] as List).take(1000))
              if (i is String && _byId[i] != null) _byId[i]!.toJson()
          ];
          for (var i = 0; i < list.length; i += 50) {
            _send(c, {'t': 'msgs', 'list': list.sublist(i, min(i + 50, list.length))});
          }
        case 'msgs':
          _ingest(j['list'] as List, from: c, live: j['live'] == true);
        case 'fwant':
          _serve(c, j);
        case 'fchunk':
          _gotChunk(c, j);
        case 'fnone':
          final d = _dls[j['fid']];
          if (d != null && d.peerId == c.remoteId) {
            d.tried.add(c.remoteId);
            d.running = false;
            _pump();
            _notify();
          }
      }
    } catch (_) {}
  }

  Future<void> _sendHave(Conn c) async {
    final all = msgs.map((m) => m.id).toList();
    for (var i = 0; i == 0 || i < all.length; i += 1000) {
      await _send(c, {'t': 'have', 'ids': all.sublist(i, min(i + 1000, all.length))});
    }
  }

  void _ingest(List l, {Conn? from, bool live = false}) {
    final fresh = <Msg>[];
    for (final x in l.take(200)) {
      try {
        final m = Msg.fromJson(Map.from(x));
        if (!_byId.containsKey(m.id)) {
          _byId[m.id] = m;
          fresh.add(m);
        }
      } catch (_) {}
    }
    if (fresh.isEmpty) return;
    msgs.addAll(fresh);
    _sort();
    _saveSoon();
    if (live) _broadcast({'t': 'msgs', 'live': true, 'list': fresh.map((m) => m.toJson()).toList()}, except: from);
    for (final m in fresh) {
      _autoFetch(m);
    }
    _notify();
  }

  Msg _mk(String text, FileRef? f) =>
      Msg(randStr(32, '0123456789abcdef'), DateTime.now().millisecondsSinceEpoch, info.nick, text, settings.uid, f);

  void sendText(String text) => _ingest([_mk(text, null).toJson()], live: true);

  Future<void> sendFile(String path, String name) async {
    final src = File(path);
    final fid = (await hash.sha256.bind(src.openRead()).first).toString();
    final dst = File(Store.filePath(fid));
    if (!dst.existsSync()) await src.copy(dst.path);
    _ingest([_mk('', FileRef(fid, name, await dst.length())).toJson()], live: true);
    Store.prune(settings.capMb);
  }

  Future<void> openFile(FileRef f) async {
    final dir = Directory('${Store.tmpDir.path}/open')..createSync(recursive: true);
    final safe = f.name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    final p = '${dir.path}/$safe';
    await File(Store.filePath(f.fid)).copy(p);
    await OpenFilex.open(p);
  }

  // ---------- файлы ----------

  void _autoFetch(Msg m) {
    final f = m.file;
    if (f == null || Store.has(f.fid) || f.size > settings.maxFileMb * _mb) return;
    fetch(f);
  }

  void fetch(FileRef f) {
    if (Store.has(f.fid)) return;
    _dls.putIfAbsent(f.fid, () => Dl(f));
    _pump();
    _notify();
  }

  void retry(FileRef f) {
    final d = _dls[f.fid];
    if (d == null) return fetch(f);
    d.tried.clear();
    d.status = 'queued';
    _pump();
    _notify();
  }

  void _pump() {
    if (_closed) return;
    var active = _dls.values.where((d) => d.running).length;
    for (final d in _dls.values.toList()) {
      if (active >= 2) break;
      if (d.running || d.status == 'unavailable') continue;
      if (_start(d)) active++;
    }
  }

  bool _start(Dl d) {
    Conn? c;
    for (final p in peers.values) {
      if (!d.tried.contains(p.remoteId)) {
        c = p;
        break;
      }
    }
    if (c == null) {
      d.status = peers.isEmpty ? 'queued' : 'unavailable';
      return false;
    }
    if (d.tmp == null) {
      d.total = (d.ref.size + chunk - 1) ~/ chunk;
      d.got = List.filled(d.total, false);
      d.received = 0;
      d.tmp = File('${Store.tmpDir.path}/${id.substring(0, 8)}_${d.ref.fid}.part');
      d.raf = d.tmp!.openSync(mode: FileMode.write);
    }
    d.peerId = c.remoteId;
    d.running = true;
    d.status = 'run';
    d.last = DateTime.now();
    _next(d, c);
    return true;
  }

  void _next(Dl d, Conn c) {
    final i = d.got.indexOf(false);
    if (i < 0) {
      _finish(d);
      return;
    }
    d.winStart = i;
    d.winEnd = min(d.total, i + 8);
    _send(c, {'t': 'fwant', 'fid': d.ref.fid, 'from': i, 'n': d.winEnd - i});
  }

  void _serve(Conn c, Map j) {
    final fid = j['fid'], from = j['from'], n = j['n'];
    if (fid is! String || !_fidRe.hasMatch(fid) || from is! int || n is! int || n < 1 || n > 16 || from < 0) return;
    final f = File(Store.filePath(fid));
    if (!f.existsSync()) {
      _send(c, {'t': 'fnone', 'fid': fid});
      return;
    }
    final raf = f.openSync();
    try {
      final len = raf.lengthSync();
      final total = (len + chunk - 1) ~/ chunk;
      for (var i = from; i < from + n && i < total; i++) {
        raf.setPositionSync(i * chunk);
        final b = raf.readSync(min(chunk, len - i * chunk));
        _send(c, {'t': 'fchunk', 'fid': fid, 'i': i, 'd': base64Encode(b)});
      }
    } finally {
      raf.closeSync();
    }
  }

  void _gotChunk(Conn c, Map j) {
    final d = _dls[j['fid']];
    if (d == null || !d.running || c.remoteId != d.peerId) return;
    final i = j['i'];
    if (i is! int || i < 0 || i >= d.total || d.got[i]) return;
    final data = base64Decode(j['d'] as String);
    final expected = i == d.total - 1 ? d.ref.size - i * chunk : chunk;
    if (data.length != expected) return;
    d.raf!.setPositionSync(i * chunk);
    d.raf!.writeFromSync(data);
    d.got[i] = true;
    d.received++;
    d.last = DateTime.now();
    if (d.received == d.total) {
      _finish(d);
      return;
    }
    if (d.received % 4 == 0) _notify();
    for (var k = d.winStart; k < d.winEnd; k++) {
      if (!d.got[k]) return;
    }
    _next(d, c);
  }

  Future<void> _finish(Dl d) async {
    d.running = false;
    d.status = 'verify';
    final bad = d.peerId ?? '';
    try {
      d.raf?.closeSync();
    } catch (_) {}
    d.raf = null;
    try {
      final ok = (await hash.sha256.bind(d.tmp!.openRead()).first).toString() == d.ref.fid;
      if (ok) {
        await d.tmp!.rename(Store.filePath(d.ref.fid));
        _dls.remove(d.ref.fid);
        Store.prune(settings.capMb);
      } else {
        try {
          d.tmp!.deleteSync();
        } catch (_) {}
        d.tmp = null;
        d.tried.add(bad);
        d.status = 'queued';
      }
    } catch (_) {
      d.tmp = null;
      d.status = 'queued';
    }
    _pump();
    _notify();
  }
}
