/// How the app looks, in one place: a dark list that reads at arm's length.
library;

import 'package:flutter/material.dart';

const plate = Color(0xff0b0f14);
const panel = Color(0xff121822);
const accent = Color(0xff38bdf8);
const hair = Color(0x14ffffff);

ThemeData theme() {
  final base = ThemeData.dark(useMaterial3: true);
  return base.copyWith(
    scaffoldBackgroundColor: plate,
    colorScheme: base.colorScheme.copyWith(
      primary: accent,
      surface: panel,
      surfaceTint: Colors.transparent,
    ),
    dividerTheme: const DividerThemeData(color: hair, space: 1, thickness: 1),
    appBarTheme: const AppBarTheme(backgroundColor: plate, surfaceTintColor: Colors.transparent),
  );
}
