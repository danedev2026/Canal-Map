// Smoke test: the app builds and shows its loading state before the (plugin-
// backed) basemap finishes preparing. We deliberately pump a single frame so
// we don't await the path_provider/asset calls, which aren't wired in tests.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:canal_map/main.dart';

void main() {
  testWidgets('App builds and shows the loading indicator first',
      (WidgetTester tester) async {
    await tester.pumpWidget(const CanalMapApp());

    expect(find.byType(MaterialApp), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });
}
