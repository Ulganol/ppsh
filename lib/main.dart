import 'dart:io';
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'p2p.dart';
import 'store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Store.init();
  final app = AppState();
  await app.load();
  runApp(App(app));
}

class AppState extends ChangeNotifier {
  late Settings settings;
  final rooms = <Room>[];
  Room? active;

  Future<void> load() async {
    final dark = WidgetsBinding.instance.platformDispatcher.platformBrightness == Brightness.dark;
    settings = Settings.fromJson(await Store.readJson('settings.json'), dark);
    final l = await Store.readJson('chats.json');
    if (l is List) {
      for (final x in l) {
        try {
          _add(ChatInfo.fromJson(Map.from(x)));
        } catch (_) {}
      }
    }
    saveSettings();
  }

  Room _add(ChatInfo i) {
    final r = Room(i, settings)..addListener(notifyListeners);
    rooms.add(r);
    r.start();
    return r;
  }

  void join(String key, String nick, String title) {
    final ex = rooms.where((r) => r.info.key == key);
    if (ex.isNotEmpty) {
      ex.first.info.nick = nick;
      active = ex.first;
    } else {
      active = _add(ChatInfo(key, nick, title.isEmpty ? 'Чат ${rooms.length + 1}' : title));
    }
    saveChats();
    notifyListeners();
  }

  void select(Room? r) {
    active = r;
    notifyListeners();
  }

  Future<void> remove(Room r) async {
    if (active == r) active = null;
    rooms.remove(r);
    await r.deleteData();
    saveChats();
    notifyListeners();
  }

  void saveChats() => Store.writeJson('chats.json', rooms.map((r) => r.info.toJson()).toList());
  void saveSettings() {
    Store.writeJson('settings.json', settings.toJson());
    notifyListeners();
  }
}

class App extends StatelessWidget {
  final AppState app;
  const App(this.app, {super.key});
  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: app,
        builder: (_, __) => MaterialApp(
          title: 'P2P Chat',
          debugShowCheckedModeBanner: false,
          themeMode: app.settings.dark ? ThemeMode.dark : ThemeMode.light,
          theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.teal, brightness: Brightness.light),
          darkTheme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.teal, brightness: Brightness.dark),
          home: Home(app),
        ),
      );
}

class Home extends StatelessWidget {
  final AppState app;
  const Home(this.app, {super.key});
  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (ctx, bc) {
        final wide = bc.maxWidth >= 760;
        final list = ChatList(app);
        final r = app.active;
        final chat = r == null
            ? const Scaffold(body: Center(child: Text('Выберите чат или добавьте новый')))
            : ChatView(key: ValueKey(r.info.key), room: r, app: app, onBack: wide ? null : () => app.select(null));
        if (wide) {
          return Scaffold(
              body: Row(children: [SizedBox(width: 300, child: list), const VerticalDivider(width: 1), Expanded(child: chat)]));
        }
        return PopScope(
          canPop: r == null,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) app.select(null);
          },
          child: r == null ? list : chat,
        );
      });
}

class ChatList extends StatelessWidget {
  final AppState app;
  const ChatList(this.app, {super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Чаты'), actions: [
          IconButton(
              icon: const Icon(Icons.settings),
              onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => SettingsPage(app)))),
        ]),
        floatingActionButton: FloatingActionButton(onPressed: () => joinDialog(context, app), child: const Icon(Icons.add)),
        body: app.rooms.isEmpty
            ? const Center(child: Text('Нет чатов. Нажмите +'))
            : ListView(children: [
                for (final r in app.rooms)
                  ListTile(
                    selected: r == app.active,
                    leading: CircleAvatar(child: Text(r.info.title.isEmpty ? '?' : r.info.title[0].toUpperCase())),
                    title: Text(r.info.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text(
                        r.msgs.isEmpty ? 'Нет сообщений' : (r.msgs.last.file != null ? '📎 ${r.msgs.last.file!.name}' : r.msgs.last.text),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Icons.circle, size: 10, color: r.peers.isNotEmpty ? Colors.green : Colors.grey),
                      const SizedBox(width: 4),
                      Text('${r.peers.length}'),
                    ]),
                    onTap: () => app.select(r),
                  ),
              ]),
      );
}

Future<void> joinDialog(BuildContext ctx, AppState app) async {
  final key = TextEditingController();
  final nick = TextEditingController(text: app.rooms.isEmpty ? '' : app.rooms.last.info.nick);
  final title = TextEditingController();
  final ok = await showDialog<bool>(
    context: ctx,
    builder: (c) => AlertDialog(
      title: const Text('Войти в чат'),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
              controller: key,
              decoration: InputDecoration(
                  labelText: 'Ключ сессии',
                  suffixIcon: IconButton(
                      icon: const Icon(Icons.casino), tooltip: 'Сгенерировать', onPressed: () => key.text = randomKey()))),
          TextField(controller: nick, decoration: const InputDecoration(labelText: 'Ник')),
          TextField(controller: title, decoration: const InputDecoration(labelText: 'Название (необязательно)')),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Отмена')),
        FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Войти')),
      ],
    ),
  );
  if (ok == true && key.text.trim().isNotEmpty && nick.text.trim().isNotEmpty) {
    app.join(key.text.trim(), nick.text.trim(), title.text.trim());
  }
}

class ChatView extends StatefulWidget {
  final Room room;
  final AppState app;
  final VoidCallback? onBack;
  const ChatView({super.key, required this.room, required this.app, this.onBack});
  @override
  State<ChatView> createState() => _ChatViewState();
}

class _ChatViewState extends State<ChatView> {
  final ctrl = TextEditingController();
  bool emoji = false;
  Room get r => widget.room;

  void send() {
    final t = ctrl.text.trim();
    if (t.isEmpty) return;
    r.sendText(t);
    ctrl.clear();
  }

  Future<void> attach() async {
    final res = await FilePicker.platform.pickFiles(allowMultiple: true);
    if (res == null) return;
    for (final f in res.files) {
      if (f.path != null) await r.sendFile(f.path!, f.name);
    }
  }

  Future<void> menu(String v) async {
    if (v == 'nick') {
      final c = TextEditingController(text: r.info.nick);
      final ok = await showDialog<bool>(
          context: context,
          builder: (d) => AlertDialog(
                title: const Text('Ник в этом чате'),
                content: TextField(controller: c, autofocus: true),
                actions: [
                  TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Отмена')),
                  FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('OK')),
                ],
              ));
      if (ok == true && c.text.trim().isNotEmpty) {
        r.info.nick = c.text.trim();
        widget.app.saveChats();
        setState(() {});
      }
    } else if (v == 'copy') {
      await Clipboard.setData(ClipboardData(text: r.info.key));
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Ключ скопирован')));
    } else if (v == 'delete') {
      final ok = await showDialog<bool>(
          context: context,
          builder: (d) => AlertDialog(
                title: const Text('Удалить чат?'),
                content: const Text('История будет удалена с этого устройства.'),
                actions: [
                  TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Отмена')),
                  FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Удалить')),
                ],
              ));
      if (ok == true) widget.app.remove(r);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: r,
        builder: (ctx, _) {
          final list = r.msgs.reversed.toList();
          return Scaffold(
            appBar: AppBar(
              automaticallyImplyLeading: false,
              leading: widget.onBack == null ? null : BackButton(onPressed: widget.onBack),
              title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(r.info.title),
                Text('${r.peers.length} онлайн · ник: ${r.info.nick}', style: Theme.of(context).textTheme.bodySmall),
              ]),
              actions: [
                PopupMenuButton<String>(
                  onSelected: menu,
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'nick', child: Text('Сменить ник')),
                    PopupMenuItem(value: 'copy', child: Text('Скопировать ключ')),
                    PopupMenuItem(value: 'delete', child: Text('Удалить чат')),
                  ],
                ),
              ],
            ),
            body: Column(children: [
              Expanded(
                child: ListView.builder(
                  reverse: true,
                  itemCount: list.length,
                  itemBuilder: (_, i) => Bubble(room: r, m: list[i]),
                ),
              ),
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                    IconButton(icon: const Icon(Icons.attach_file), onPressed: attach),
                    IconButton(
                        icon: Icon(emoji ? Icons.keyboard : Icons.emoji_emotions_outlined),
                        onPressed: () => setState(() => emoji = !emoji)),
                    Expanded(
                      child: CallbackShortcuts(
                        bindings: {const SingleActivator(LogicalKeyboardKey.enter): send},
                        child: TextField(
                          controller: ctrl,
                          minLines: 1,
                          maxLines: 5,
                          inputFormatters: [LengthLimitingTextInputFormatter(2000)],
                          decoration: const InputDecoration(hintText: 'Сообщение', border: OutlineInputBorder()),
                        ),
                      ),
                    ),
                    IconButton(icon: const Icon(Icons.send), onPressed: send),
                  ]),
                ),
              ),
              if (emoji) SizedBox(height: 256, child: EmojiPicker(textEditingController: ctrl, config: const Config(height: 256))),
            ]),
          );
        },
      );
}

class Bubble extends StatelessWidget {
  final Room room;
  final Msg m;
  const Bubble({super.key, required this.room, required this.m});
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final mine = room.mine(m);
    final color = HSLColor.fromAHSL(1, (m.uid.hashCode.abs() % 360).toDouble(), .6, .5).toColor();
    final t = DateTime.fromMillisecondsSinceEpoch(m.ts);
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
              color: mine ? cs.primaryContainer : cs.surfaceContainerHighest, borderRadius: BorderRadius.circular(14)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text(m.nick, style: TextStyle(fontWeight: FontWeight.bold, color: color)),
            if (m.file != null) FileTile(room: room, f: m.file!),
            if (m.text.isNotEmpty) SelectableText(m.text),
            Text(TimeOfDay.fromDateTime(t).format(context), style: Theme.of(context).textTheme.labelSmall),
          ]),
        ),
      ),
    );
  }
}

class FileTile extends StatelessWidget {
  final Room room;
  final FileRef f;
  const FileTile({super.key, required this.room, required this.f});
  @override
  Widget build(BuildContext context) {
    final path = Store.filePath(f.fid);
    if (File(path).existsSync()) {
      if (f.isImage) {
        return GestureDetector(
          onTap: () => showDialog(
              context: context, builder: (_) => Dialog(child: InteractiveViewer(child: Image.file(File(path))))),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.file(File(path),
                width: 280, cacheWidth: 560, errorBuilder: (_, __, ___) => const Icon(Icons.broken_image)),
          ),
        );
      }
      return ListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        leading: const Icon(Icons.insert_drive_file),
        title: Text(f.name),
        subtitle: Text(fmtSize(f.size)),
        onTap: () => room.openFile(f),
      );
    }
    final d = room.dl(f.fid);
    String label = '${f.name} · ${fmtSize(f.size)}';
    Widget? action = TextButton(onPressed: () => room.fetch(f), child: const Text('Скачать'));
    Widget? bar;
    if (d != null && d.status == 'unavailable') {
      label += '\nНедоступен: никто из онлайн его не хранит';
      action = TextButton(onPressed: () => room.retry(f), child: const Text('Повторить'));
    } else if (d != null) {
      label += d.running ? '\nЗагрузка…' : '\nОжидание участников…';
      action = null;
      bar = LinearProgressIndicator(value: d.total == 0 ? null : d.received / d.total);
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.insert_drive_file_outlined),
        const SizedBox(width: 8),
        Flexible(child: Text(label)),
      ]),
      if (bar != null) Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: bar),
      if (action != null) action,
    ]);
  }
}

class SettingsPage extends StatefulWidget {
  final AppState app;
  const SettingsPage(this.app, {super.key});
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  Settings get s => widget.app.settings;
  static const caps = [0, 500, 1024, 2048, 5120, 10240];
  @override
  Widget build(BuildContext context) {
    final cap = caps.contains(s.capMb) ? s.capMb : 2048;
    return Scaffold(
      appBar: AppBar(title: const Text('Настройки')),
      body: ListView(children: [
        SwitchListTile(
          title: const Text('Тёмная тема'),
          value: s.dark,
          onChanged: (v) {
            s.dark = v;
            widget.app.saveSettings();
            setState(() {});
          },
        ),
        ListTile(
          title: Text('Автосохранение файлов до ${s.maxFileMb} МБ'),
          subtitle: Slider(
            min: 1,
            max: 500,
            divisions: 499,
            value: s.maxFileMb.toDouble(),
            onChanged: (v) => setState(() => s.maxFileMb = v.round()),
            onChangeEnd: (_) => widget.app.saveSettings(),
          ),
        ),
        ListTile(
          title: const Text('Лимит папки с файлами'),
          subtitle: const Text('Когда лимит превышен, старые файлы удаляются первыми'),
          trailing: DropdownButton<int>(
            value: cap,
            items: [for (final c in caps) DropdownMenuItem(value: c, child: Text(c == 0 ? 'Без лимита' : fmtSize(c * 1024 * 1024)))],
            onChanged: (v) {
              s.capMb = v ?? 2048;
              Store.prune(s.capMb);
              widget.app.saveSettings();
              setState(() {});
            },
          ),
        ),
        ListTile(
          title: Text('Занято файлами: ${fmtSize(Store.usedBytes())}'),
          trailing: TextButton(
              onPressed: () {
                Store.clearFiles();
                setState(() {});
              },
              child: const Text('Очистить')),
        ),
      ]),
    );
  }
}
