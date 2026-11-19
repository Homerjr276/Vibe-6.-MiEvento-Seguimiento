import 'dart:convert';
import 'dart:js_interop';

import '../models/reservation.dart';

@JS('MiEventoRustReady')
external JSPromise<JSAny?> get _rustReady;

@JS('MiEventoRust.calculateTotal')
external JSString _calculateTotal(
  int chairs,
  int tables,
  bool decoration,
  bool delivery,
);

@JS('MiEventoRust.validateAvailability')
external JSString _validateAvailability(
  String reservationsJson,
  String reservationId,
  String date,
  int chairs,
  int tables,
);

@JS('MiEventoRust.validatePayment')
external JSString _validatePayment(
  String amount,
  String method,
  String status,
  String totalCents,
  String paidCents,
);

class RustBridge {
  static final Future<void> _initialization = _initialize();

  static Future<void> _initialize() async {
    try {
      await _rustReady.toDart;
    } catch (error) {
      throw StateError('No se pudo inicializar el módulo WASM de Rust: $error');
    }
  }

  static Future<void> ensureInitialized() => _initialization;

  static Future<int> calculateTotalCents({
    required int chairs,
    required int tables,
    required bool decoration,
    required bool delivery,
  }) async {
    await ensureInitialized();
    _checkWasmQuantity(chairs);
    _checkWasmQuantity(tables);
    final result = _decodeResult(
      _calculateTotal(chairs, tables, decoration, delivery).toDart,
    );
    return int.parse(result['value'] as String);
  }

  static Future<void> validateAvailability({
    required List<Reservation> reservations,
    required String reservationId,
    required String date,
    required int chairs,
    required int tables,
  }) async {
    await ensureInitialized();
    _checkWasmQuantity(chairs);
    _checkWasmQuantity(tables);
    _decodeResult(
      _validateAvailability(
        jsonEncode(reservations.map((reservation) => reservation.toRustJson()).toList()),
        reservationId,
        date,
        chairs,
        tables,
      ).toDart,
    );
  }

  static Future<int> validatePayment({
    required String amount,
    required String method,
    required String status,
    required int totalCents,
    required int paidCents,
  }) async {
    await ensureInitialized();
    final result = _decodeResult(
      _validatePayment(
        amount,
        method,
        status,
        totalCents.toString(),
        paidCents.toString(),
      ).toDart,
    );
    return int.parse(result['value'] as String);
  }

  static Map<String, dynamic> _decodeResult(String serialized) {
    final decoded = jsonDecode(serialized);
    if (decoded is! Map<String, dynamic> || decoded['ok'] is! bool) {
      throw StateError('La respuesta del módulo WASM tiene un formato inválido.');
    }
    if (decoded['ok'] != true) {
      throw RustOperationException(
        decoded['error'] as String? ?? 'La operación Rust falló.',
      );
    }
    return decoded;
  }

  static void _checkWasmQuantity(int quantity) {
    if (quantity < 0 || quantity > 0xFFFFFFFF) {
      throw RangeError('La cantidad está fuera del rango aceptado por Rust.');
    }
  }
}

class RustOperationException implements Exception {
  const RustOperationException(this.message);

  final String message;

  @override
  String toString() => message;
}
