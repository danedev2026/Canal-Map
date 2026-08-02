import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A selectable colour theme (brand seed). The app bar takes a dark shade of
/// the seed so it stays boldly branded in both light and dark mode.
class SeedTheme {
  const SeedTheme(this.name, this.seed);
  final String name;
  final Color seed;
}

const List<SeedTheme> kSeedThemes = [
  SeedTheme('Canal green', Color(0xFF16302B)),
  SeedTheme('Narrowboat red', Color(0xFF8E2B20)),
  SeedTheme('Slate blue', Color(0xFF1F3A5F)),
  SeedTheme('Heather', Color(0xFF5E2A5B)),
];

/// App-wide appearance settings: light/dark/system + which colour theme.
/// Persisted with shared_preferences; a ChangeNotifier so MaterialApp rebuilds
/// on change. £0: purely on-device, nothing networked.
class AppSettings extends ChangeNotifier {
  static final AppSettings instance = AppSettings._();
  AppSettings._();

  static const _kMode = 'theme_mode';
  static const _kSeed = 'seed_index';

  ThemeMode _mode = ThemeMode.system;
  int _seedIndex = 0;

  ThemeMode get mode => _mode;
  int get seedIndex => _seedIndex;
  Color get seed => kSeedThemes[_seedIndex].seed;

  Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    _mode = ThemeMode.values[
        (p.getInt(_kMode) ?? ThemeMode.system.index).clamp(0, ThemeMode.values.length - 1)];
    _seedIndex = (p.getInt(_kSeed) ?? 0).clamp(0, kSeedThemes.length - 1);
    notifyListeners();
  }

  Future<void> setMode(ThemeMode m) async {
    if (m == _mode) return;
    _mode = m;
    notifyListeners();
    final p = await SharedPreferences.getInstance();
    await p.setInt(_kMode, m.index);
  }

  Future<void> setSeedIndex(int i) async {
    if (i == _seedIndex) return;
    _seedIndex = i;
    notifyListeners();
    final p = await SharedPreferences.getInstance();
    await p.setInt(_kSeed, i);
  }

  /// A ThemeData built from the current seed for the given brightness.
  ThemeData themeFor(Brightness brightness) {
    final scheme = ColorScheme.fromSeed(seedColor: seed, brightness: brightness);
    // Keep a bold, dark, branded app bar in both modes.
    final barColor = HSLColor.fromColor(seed)
        .withLightness(brightness == Brightness.dark ? 0.10 : 0.14)
        .withSaturation(
            (HSLColor.fromColor(seed).saturation).clamp(0.25, 1.0))
        .toColor();
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
      appBarTheme: AppBarTheme(
        backgroundColor: barColor,
        foregroundColor: Colors.white,
        elevation: 2,
      ),
    );
  }
}
