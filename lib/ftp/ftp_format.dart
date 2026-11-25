/// Opmaak en ontleding van FTP-maplijsten (gedeeld door server en client).
library;

const _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
];

String _two(int n) => n.toString().padLeft(2, '0');

/// Tijd in FTP-formaat (UTC): YYYYMMDDHHMMSS.
String mdtm(DateTime t) {
  final u = t.toUtc();
  return '${u.year}${_two(u.month)}${_two(u.day)}'
      '${_two(u.hour)}${_two(u.minute)}${_two(u.second)}';
}

DateTime? parseMdtm(String s) {
  final m = RegExp(r'^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})').firstMatch(s);
  if (m == null) return null;
  int g(int i) => int.parse(m.group(i)!);
  return DateTime.utc(g(1), g(2), g(3), g(4), g(5), g(6)).toLocal();
}

/// Regel zoals `ls -l` die geeft (begrepen door vrijwel alle clients).
String unixListLine(
    String name, bool isDir, int size, DateTime modified, DateTime now) {
  final perms = isDir ? 'drwxr-xr-x' : '-rw-r--r--';
  final m = modified.toLocal();
  final recent = now.difference(m).inDays.abs() < 180;
  final date = '${_months[m.month - 1]} ${m.day.toString().padLeft(2)} '
      '${recent ? '${_two(m.hour)}:${_two(m.minute)}' : m.year.toString().padLeft(5)}';
  return '$perms 1 ftp ftp ${size.toString().padLeft(12)} $date $name';
}

/// Feitenregel voor MLSD/MLST (RFC 3659).
String mlsxFacts(String name, bool isDir, int size, DateTime modified) =>
    'type=${isDir ? 'dir' : 'file'};size=$size;modify=${mdtm(modified)}; $name';

class RemoteEntry {
  const RemoteEntry({
    required this.name,
    required this.isDir,
    this.size = 0,
    this.modified,
  });

  final String name;
  final bool isDir;
  final int size;
  final DateTime? modified;
}

/// Ontleedt een MLSD-regel; null voor `.`/`..` of onleesbare regels.
RemoteEntry? parseMlsdLine(String line) {
  final sp = line.indexOf(' ');
  if (sp < 0) return null;
  final name = line.substring(sp + 1);
  final facts = <String, String>{};
  for (final f in line.substring(0, sp).split(';')) {
    final eq = f.indexOf('=');
    if (eq > 0) facts[f.substring(0, eq).toLowerCase()] = f.substring(eq + 1);
  }
  final type = facts['type']?.toLowerCase() ?? 'file';
  if (type == 'cdir' || type == 'pdir' || name == '.' || name == '..') {
    return null;
  }
  return RemoteEntry(
    name: name,
    isDir: type == 'dir',
    size: int.tryParse(facts['size'] ?? '') ?? 0,
    modified: facts['modify'] == null ? null : parseMdtm(facts['modify']!),
  );
}

final _unixRe = RegExp(
    r'^([\-dlbcps])[rwxsStT\-]{9}\S*\s+\d+\s+\S+\s+\S+\s+(\d+)\s+(\w{3})\s+(\d{1,2})\s+(\d{1,2}:\d{2}|\d{4})\s+(.+)$');

/// Ontleedt een `ls -l`-regel; null als dat niet lukt.
RemoteEntry? parseUnixListLine(String line, {DateTime? now}) {
  final m = _unixRe.firstMatch(line);
  if (m == null) return null;
  var name = m.group(6)!;
  if (name == '.' || name == '..') return null;
  final kind = m.group(1)!;
  if (kind == 'l') {
    final arrow = name.indexOf(' -> ');
    if (arrow > 0) name = name.substring(0, arrow);
  }
  final month = _months.indexOf(m.group(3)!) + 1;
  DateTime? modified;
  if (month > 0) {
    final day = int.parse(m.group(4)!);
    final t = m.group(5)!;
    if (t.contains(':')) {
      final n = now ?? DateTime.now();
      final hm = t.split(':');
      modified = DateTime(n.year, month, day, int.parse(hm[0]), int.parse(hm[1]));
      if (modified.isAfter(n.add(const Duration(days: 1)))) {
        modified = DateTime(n.year - 1, month, day, modified.hour, modified.minute);
      }
    } else {
      modified = DateTime(int.parse(t), month, day);
    }
  }
  return RemoteEntry(
    name: name,
    isDir: kind == 'd',
    size: int.tryParse(m.group(2)!) ?? 0,
    modified: modified,
  );
}
