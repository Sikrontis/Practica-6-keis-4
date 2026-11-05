
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

void main() => runApp(const NotesApp());

const String kAppName = 'Заметки Аппиа';

/// ======================= МОДЕЛЬ =======================
class Note {
  final String id;
  String title;
  String content;
  DateTime date; // дата мероприятия
  int minutes;   // время в минутах от 00:00
  String storage; // 'db' | 'file'

  Note({
    required this.id,
    required this.title,
    required this.content,
    required this.date,
    required this.minutes,
    required this.storage,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'title': title,
        'content': content,
        'date': date.toIso8601String(),
        'minutes': minutes,
        'storage': storage,
      };

  factory Note.fromMap(Map<String, dynamic> m) => Note(
        id: m['id'] as String,
        title: m['title'] as String,
        content: m['content'] as String,
        date: DateTime.parse(m['date'] as String),
        minutes: m['minutes'] as int,
        storage: m['storage'] as String,
      );

  String get timeText =>
      '${(minutes ~/ 60).toString().padLeft(2, '0')}:${(minutes % 60).toString().padLeft(2, '0')}';
}

/// ==================== ХРАНИЛИЩА ====================
abstract class NotesStore {
  Future<List<Note>> load();
  Future<void> save(Note note);
  Future<void> delete(String id);
}

/// Вариант 1: SQLite (локальная база данных)
class DbStore implements NotesStore {
  Database? _db;

  Future<Database> _open() async {
    if (_db != null) return _db!;
    final dir = await getDatabasesPath();
    _db = await openDatabase(
      p.join(dir, 'appia_notes.db'),
      version: 1,
      onCreate: (db, version) async {
        await db.execute(
          'CREATE TABLE notes(id TEXT PRIMARY KEY, title TEXT NOT NULL, '
          'content TEXT NOT NULL, date TEXT NOT NULL, minutes INTEGER NOT NULL)');
      },
    );
    return _db!;
  }

  @override
  Future<List<Note>> load() async {
    final db = await _open();
    final rows = await db.query('notes', orderBy: 'date DESC, minutes DESC');
    return rows.map((r) => Note.fromMap({...r, 'storage': 'db'})).toList();
  }

  @override
  Future<void> save(Note note) async {
    final db = await _open();
    await db.insert('notes', note.toMap()..remove('storage'),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  @override
  Future<void> delete(String id) async {
    final db = await _open();
    await db.delete('notes', where: 'id = ?', whereArgs: [id]);
  }
}

/// Вариант 2: файловая система устройства (каждая заметка — JSON-файл)
class FileStore implements NotesStore {
  Future<Directory> _dir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, 'appia_notes'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  @override
  Future<List<Note>> load() async {
    final dir = await _dir();
    final notes = <Note>[];
    await for (final f in dir.list()) {
      if (f is File && f.path.endsWith('.json')) {
        try {
          final map = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
          notes.add(Note.fromMap(map));
        } catch (_) {/* повреждённый файл пропускаем */}
      }
    }
    notes.sort((a, b) {
      final c = b.date.compareTo(a.date);
      return c != 0 ? c : b.minutes.compareTo(a.minutes);
    });
    return notes;
  }

  @override
  Future<void> save(Note note) async {
    final dir = await _dir();
    final file = File(p.join(dir.path, '${note.id}.json'));
    await file.writeAsString(jsonEncode(note.toMap()));
  }

  @override
  Future<void> delete(String id) async {
    final dir = await _dir();
    final file = File(p.join(dir.path, '$id.json'));
    if (await file.exists()) await file.delete();
  }
}

/// Фасад: работает с обоими хранилищами как с единым списком
class NotesRepository {
  final DbStore dbStore = DbStore();
  final FileStore fileStore = FileStore();

  Future<List<Note>> loadAll() async =>
      [...await dbStore.load(), ...await fileStore.load()];

  Future<void> upsert(Note note) =>
      note.storage == 'db' ? dbStore.save(note) : fileStore.save(note);

  Future<void> delete(Note note) =>
      note.storage == 'db' ? dbStore.delete(note.id) : fileStore.delete(note.id);
}

/// ==================== ПРИЛОЖЕНИЕ ====================
class NotesApp extends StatelessWidget {
  const NotesApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: kAppName,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFFFF5722)),
        useMaterial3: true,
      ),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final NotesRepository _repo = NotesRepository();
  final TextEditingController _searchCtrl = TextEditingController();

  List<Note> _all = [];
  List<Note> _visible = [];
  DateTime? _filterDate;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    setState(() => _loading = true);
    _all = await _repo.loadAll();
    _applyFilter();
  }

  void _applyFilter() {
    final q = _searchCtrl.text.trim().toLowerCase();
    final fmt = DateFormat('dd.MM.yyyy');
    setState(() {
      _visible = _all.where((n) {
        final okQuery = q.isEmpty ||
            n.title.toLowerCase().contains(q) ||
            n.content.toLowerCase().contains(q);
        final okDate =
            _filterDate == null || fmt.format(n.date) == fmt.format(_filterDate!);
        return okQuery && okDate;
      }).toList();
      _loading = false;
    });
  }

  Future<void> _openEditor([Note? note]) async {
    final saved = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => EditScreen(note: note)),
    );
    if (saved == true) _reload();
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final d = await showDatePicker(
      context: context,
      initialDate: _filterDate ?? now,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
      helpText: 'Фильтр по дате',
    );
    if (d != null) {
      _filterDate = d;
      _applyFilter();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(kAppName),
        actions: [
          IconButton(
            icon: Icon(_filterDate == null ? Icons.event : Icons.event_busy),
            tooltip: 'Фильтр по дате',
            onPressed: _pickDate,
          ),
          if (_filterDate != null)
            IconButton(
              icon: const Icon(Icons.clear),
              tooltip: 'Сбросить фильтр',
              onPressed: () {
                _filterDate = null;
                _applyFilter();
              },
            ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
            child: TextField(
              controller: _searchCtrl,
              onChanged: (_) => _applyFilter(),
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'Поиск по заголовку и тексту…',
                border: OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(24))),
                isDense: true,
              ),
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _visible.isEmpty
                    ? const Center(child: Text('Заметок нет. Нажмите «+», чтобы создать первую.'))
                    : ListView.separated(
                        padding: const EdgeInsets.only(bottom: 88),
                        itemCount: _visible.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 6),
                        itemBuilder: (_, i) {
                          final n = _visible[i];
                          return Dismissible(
                            key: ValueKey(n.id),
                            direction: DismissDirection.endToStart,
                            background: Container(
                              alignment: Alignment.centerRight,
                              padding: const EdgeInsets.only(right: 20),
                              color: Colors.red,
                              child: const Icon(Icons.delete, color: Colors.white),
                            ),
                            onDismissed: (_) async {
                              await _repo.delete(n);
                              _reload();
                            },
                            child: Card(
                              margin: const EdgeInsets.symmetric(horizontal: 12),
                              child: ListTile(
                                title: Text(n.title,
                                    style: const TextStyle(fontWeight: FontWeight.w600)),
                                subtitle: Text(
                                  n.content,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                trailing: Chip(
                                  label: Text(n.storage == 'db' ? 'БД' : 'Файл'),
                                  visualDensity: VisualDensity.compact,
                                ),
                                onTap: () => _openEditor(n),
                              ),
                            ),
                          );
                        },
                      ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _openEditor(),
        child: const Icon(Icons.add),
      ),
    );
  }
}

class EditScreen extends StatefulWidget {
  final Note? note;
  const EditScreen({super.key, this.note});
  @override
  State<EditScreen> createState() => _EditScreenState();
}

class _EditScreenState extends State<EditScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _titleCtrl;
  late final TextEditingController _contentCtrl;
  late DateTime _date;
  late int _minutes;
  late String _storage;

  @override
  void initState() {
    super.initState();
    final n = widget.note;
    _titleCtrl = TextEditingController(text: n?.title ?? '');
    _contentCtrl = TextEditingController(text: n?.content ?? '');
    _date = n?.date ?? DateTime.now();
    final now = TimeOfDay.now();
    _minutes = n?.minutes ?? now.hour * 60 + now.minute;
    _storage = n?.storage ?? 'db';
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    final note = Note(
      id: widget.note?.id ?? DateTime.now().microsecondsSinceEpoch.toString(),
      title: _titleCtrl.text.trim(),
      content: _contentCtrl.text.trim(),
      date: _date,
      minutes: _minutes,
      storage: _storage,
    );
    final repo = NotesRepository();
    await repo.upsert(note);
    if (context.mounted) Navigator.pop(context, true);
  }

  Future<void> _delete() async {
    final repo = NotesRepository();
    await repo.delete(widget.note!);
    if (context.mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final isNew = widget.note == null;
    return Scaffold(
      appBar: AppBar(
        title: Text(isNew ? 'Новая заметка' : 'Редактирование'),
        actions: [
          if (!isNew)
            IconButton(icon: const Icon(Icons.delete), onPressed: _delete),
        ],
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextFormField(
              controller: _titleCtrl,
              decoration: const InputDecoration(
                  labelText: 'Заголовок', border: OutlineInputBorder()),
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? 'Введите заголовок' : null,
            ),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.event),
                  label: Text(DateFormat('dd.MM.yyyy').format(_date)),
                  onPressed: () async {
                    final d = await showDatePicker(
                      context: context,
                      initialDate: _date,
                      firstDate: DateTime(2020),
                      lastDate: DateTime(2100),
                    );
                    if (d != null) setState(() => _date = d);
                  },
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.schedule),
                  label: Text(
                      '${(_minutes ~/ 60).toString().padLeft(2, '0')}:${(_minutes % 60).toString().padLeft(2, '0')}'),
                  onPressed: () async {
                    final t = await showTimePicker(
                      context: context,
                      initialTime: TimeOfDay(hour: _minutes ~/ 60, minute: _minutes % 60),
                    );
                    if (t != null) setState(() => _minutes = t.hour * 60 + t.minute);
                  },
                ),
              ),
            ]),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: _storage,
              decoration: const InputDecoration(
                labelText: 'Способ хранения',
                border: OutlineInputBorder(),
              ),
              items: const [
                DropdownMenuItem(value: 'db', child: Text('SQLite (база данных на устройстве)')),
                DropdownMenuItem(value: 'file', child: Text('Файл на устройстве (JSON)')),
              ],
              onChanged: (v) => setState(() => _storage = v!),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _contentCtrl,
              maxLines: 8,
              decoration: const InputDecoration(
                labelText: 'Содержание',
                alignLabelWithHint: true,
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              icon: const Icon(Icons.save),
              label: const Text('Сохранить'),
              onPressed: _save,
            ),
          ],
        ),
      ),
    );
  }
}
