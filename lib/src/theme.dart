import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ─── Tema aplicației: luminoasă, întunecată sau ca telefonul ──────────────────
// Alegerea e a telefonului (nu intră în backup și nu se sincronizează).
class AppTheme {
  static const prefsKey = 'theme_mode';

  static final ValueNotifier<ThemeMode> mode = ValueNotifier<ThemeMode>(ThemeMode.system);

  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    mode.value = switch (prefs.getString(prefsKey)) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
  }

  static Future<void> set(ThemeMode m) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(prefsKey, m.name);
    mode.value = m;
  }

  // Paleta: verde-petrol adânc, cu accent auriu.
  static const _primary = Color(0xFF0F766E);
  static const _gold = Color(0xFFD4A537);

  static ThemeData light() => _build(
        ColorScheme.fromSeed(seedColor: _primary, brightness: Brightness.light).copyWith(
          primary: _primary,
          secondary: _gold,
          surface: Colors.white,
          surfaceContainerLowest: Colors.white,
          surfaceContainerLow: const Color(0xFFF7FAF9),
          surfaceContainer: const Color(0xFFF0F5F4),
          surfaceContainerHigh: const Color(0xFFE8EFEE),
          outlineVariant: const Color(0xFFE1E8E6),
        ),
        scaffold: const Color(0xFFF3F6F5),
        appBar: const Color(0xFF0B3D38),
      );

  static ThemeData dark() => _build(
        ColorScheme.fromSeed(seedColor: _primary, brightness: Brightness.dark).copyWith(
          primary: const Color(0xFF4FD1C0),
          onPrimary: const Color(0xFF00201C),
          secondary: _gold,
          surface: const Color(0xFF141D1C),
          surfaceContainerLowest: const Color(0xFF0E1615),
          surfaceContainerLow: const Color(0xFF172120),
          surfaceContainer: const Color(0xFF1B2625),
          surfaceContainerHigh: const Color(0xFF222E2D),
          outlineVariant: const Color(0xFF2A3735),
        ),
        scaffold: const Color(0xFF0C1312),
        appBar: const Color(0xFF0F1A19),
      );

  static ThemeData _build(ColorScheme scheme, {required Color scaffold, required Color appBar}) {
    final radius = BorderRadius.circular(16);
    final buttonShape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(14));
    const buttonPadding = EdgeInsets.symmetric(horizontal: 18, vertical: 14);
    final base = ThemeData(colorScheme: scheme, useMaterial3: true, brightness: scheme.brightness);
    return base.copyWith(
      scaffoldBackgroundColor: scaffold,
      appBarTheme: AppBarTheme(
        backgroundColor: appBar,
        foregroundColor: Colors.white,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: const TextStyle(fontSize: 19, fontWeight: FontWeight.w600, color: Colors.white, letterSpacing: 0.2),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: scheme.surface,
        margin: const EdgeInsets.symmetric(vertical: 6),
        shape: RoundedRectangleBorder(borderRadius: radius, side: BorderSide(color: scheme.outlineVariant)),
        clipBehavior: Clip.antiAlias,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: buttonShape,
          padding: buttonPadding,
          textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          shape: buttonShape,
          padding: buttonPadding,
          side: BorderSide(color: scheme.outlineVariant, width: 1.2),
          textStyle: const TextStyle(fontWeight: FontWeight.w600),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(shape: buttonShape, textStyle: const TextStyle(fontWeight: FontWeight.w600)),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: scheme.primary,
        foregroundColor: scheme.onPrimary,
        elevation: 2,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerLow,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: scheme.outlineVariant)),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: scheme.outlineVariant)),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: scheme.primary, width: 1.6)),
      ),
      chipTheme: base.chipTheme.copyWith(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      listTileTheme: ListTileThemeData(
        iconColor: scheme.primary,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        indicatorColor: scheme.primary.withValues(alpha: 0.16),
        elevation: 3,
        height: 70,
        labelTextStyle: WidgetStateProperty.resolveWith((states) => TextStyle(
              fontSize: 12,
              fontWeight: states.contains(WidgetState.selected) ? FontWeight.w700 : FontWeight.w500,
              color: states.contains(WidgetState.selected) ? scheme.primary : scheme.onSurfaceVariant,
            )),
        iconTheme: WidgetStateProperty.resolveWith((states) => IconThemeData(
              color: states.contains(WidgetState.selected) ? scheme.primary : scheme.onSurfaceVariant,
            )),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      dividerTheme: DividerThemeData(color: scheme.outlineVariant, space: 1),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: SegmentedButton.styleFrom(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          side: BorderSide(color: scheme.outlineVariant),
        ),
      ),
    );
  }
}

// ─── Culori care arată bine în ambele teme ────────────────────────────────────
bool isDarkTheme(BuildContext context) => Theme.of(context).brightness == Brightness.dark;

// Fundal discret colorat (carduri de stare, avertismente).
Color tintBg(BuildContext context, MaterialColor c) => c.withValues(alpha: isDarkTheme(context) ? 0.16 : 0.09);

// Text / icon pe un fundal tintBg.
Color toneFg(BuildContext context, MaterialColor c) => isDarkTheme(context) ? c.shade200 : c.shade800;

// Text secundar.
Color mutedText(BuildContext context) => Theme.of(context).colorScheme.onSurfaceVariant;

// Linii, chenare, iconuri inactive.
Color subtleLine(BuildContext context) => Theme.of(context).colorScheme.outlineVariant;
