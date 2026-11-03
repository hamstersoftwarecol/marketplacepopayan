import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marketplace_popayan/main.dart';

void main() {
  testWidgets('Permite reintentar cuando el servidor no está disponible', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Failure(error: Exception('offline'), retry: () {}),
      ),
    );
    expect(find.text('Reintentar'), findsOneWidget);
    expect(find.byIcon(Icons.cloud_off_outlined), findsOneWidget);
  });
  test('Los precios convierten unidades menores a COP', () {
    expect(price(1250000), contains('12.500'));
  });
}
