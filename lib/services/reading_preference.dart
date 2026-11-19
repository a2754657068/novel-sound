import 'app_log.dart';
import 'library_store.dart';

/// 从本地阅读记录里归纳「这个人常读什么类型」。
///
/// 数据全部来自本机：`LibraryStore` 的 `read_time` 盒子（按天累计秒数）与
/// `history` 盒子（`MediaItem.toJson()`，带 `categories`）。只把类型名交给
/// 自己的后端去加权采样，不外传书名、进度或时长。
///
/// 冷启动保护：样本太少（< [_minBooks] 本）时返回空列表，让推荐退回中性随机，
/// 避免刚看两本书就被锁死口味。
class ReadingPreference {
  ReadingPreference._();

  /// 参与统计的书籍上限。读得最多的排前面，多的也没意义。
  static const int _maxBooks = 40;

  /// 少于这么多本有类型标注的书就不给偏好。
  static const int _minBooks = 3;

  /// 最多给几个类型，太多了等于没偏好。
  static const int _maxTags = 3;

  /// 命中书数少于这个数的类型不参与（只读过一本的类型权重太低）。
  static const int _minHits = 2;

  /// 缓存结果，避免每次进首页都重扫两个 Hive 盒子。
  static List<String>? _cached;
  static DateTime? _cachedAt;

  /// 常读类型（按权重降序）。返回空列表表示「不给偏好」。
  static List<String> topTags({Duration ttl = const Duration(minutes: 10)}) {
    final cachedAt = _cachedAt;
    final cached = _cached;
    if (cached != null &&
        cachedAt != null &&
        DateTime.now().difference(cachedAt) < ttl) {
      return cached;
    }
    final tags = _compute();
    _cached = tags;
    _cachedAt = DateTime.now();
    return tags;
  }

  /// 记录变化（读完一本、导入历史）后调用，下次取用重新计算。
  static void invalidate() {
    _cached = null;
    _cachedAt = null;
  }

  static List<String> _compute() {
    final store = LibraryStore.instance;
    final Map<String, Map<String, dynamic>> byId = {};
    try {
      for (final record in store.historySnapshot()) {
        final id = (record['id'] ?? '').toString();
        if (id.isEmpty) continue;
        byId[id] = record;
      }
    } catch (e) {
      AppLog.w('preference', '读历史失败，退化为无偏好：$e');
      return const [];
    }
    if (byId.isEmpty) return const [];

    // bookId → 阅读秒数。盒子里的值是「日期 → 秒数」的 map，以 `_` 开头的
    // 是内部字段（分类标签、更新时间），不能当秒数累加。
    final Map<String, int> seconds = {};
    try {
      final box = store.readTimeListenable.value;
      for (final key in box.keys) {
        final raw = box.get(key);
        if (raw is! Map) continue;
        var total = 0;
        for (final entry in raw.entries) {
          final name = entry.key.toString();
          if (name.startsWith('_')) continue;
          final value = entry.value;
          if (value is num) total += value.toInt();
        }
        if (total > 0) seconds[key.toString()] = total;
      }
    } catch (e) {
      AppLog.w('preference', '读阅读时长失败，按历史条数排序：$e');
    }

    final ids = byId.keys.toList()
      ..sort((a, b) {
        final sa = seconds[a] ?? 0;
        final sb = seconds[b] ?? 0;
        if (sa != sb) return sb.compareTo(sa);
        final ta = (byId[a]?['time'] as num?)?.toInt() ?? 0;
        final tb = (byId[b]?['time'] as num?)?.toInt() ?? 0;
        return tb.compareTo(ta);
      });

    final Map<String, int> hits = {};
    var annotated = 0;
    for (final id in ids.take(_maxBooks)) {
      final record = byId[id]!;
      final categories = _categoriesOf(record);
      if (categories.isEmpty) continue;
      annotated++;
      for (final tag in categories) {
        hits[tag] = (hits[tag] ?? 0) + 1;
      }
    }
    if (annotated < _minBooks) return const [];

    final ranked = hits.entries.where((e) => e.value >= _minHits).toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final tags = [for (final e in ranked.take(_maxTags)) e.key];
    if (tags.isNotEmpty) {
      AppLog.d('preference', '常读类型：$tags（样本 $annotated 本）');
    }
    return tags;
  }

  /// 一本书的类型标签。优先 `categories`，其次 `category` 单值。
  static List<String> _categoriesOf(Map<String, dynamic> record) {
    final out = <String>[];
    void add(Object? value) {
      final text = value?.toString().trim() ?? '';
      if (text.isEmpty) return;
      // 太长的是简介片段，太短的（如单字）没法当类型。
      if (text.length < 2 || text.length > 8) return;
      if (text == '全部' || text == '精品' || text == '推荐') return;
      if (!out.contains(text)) out.add(text);
    }

    final categories = record['categories'];
    if (categories is List) {
      for (final entry in categories) {
        add(entry);
      }
    }
    add(record['category']);
    return out;
  }

  /// 调试用：把统计结果压成一行。
  static String describe(Iterable<String> tags) =>
      tags.isEmpty ? '无偏好（走中性随机）' : tags.join('、');

  /// 给后端用的紧凑参数：`a,b,c`。空列表返回空串。
  static String encode(Iterable<String> tags) =>
      tags.map((t) => t.replaceAll(',', ' ')).join(',').trim();
}
