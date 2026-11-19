import 'dart:convert';

import 'package:web/web.dart' as web;

import '../models/reservation.dart';

class ReservationStorage {
  static const storageKey = 'mievento_seguimiento_v1';

  List<Reservation> readAll() {
    final serialized = web.window.localStorage.getItem(storageKey);
    if (serialized == null) {
      web.window.localStorage.setItem(storageKey, '[]');
      return [];
    }

    final decoded = jsonDecode(serialized);
    if (decoded is! List) {
      throw const FormatException('Las reservas guardadas no son una lista.');
    }

    return decoded.map((entry) {
      if (entry is! Map) {
        throw const FormatException('Una reserva guardada no es válida.');
      }
      return Reservation.fromJson(Map<String, dynamic>.from(entry));
    }).toList(growable: false);
  }

  void writeAll(List<Reservation> reservations) {
    web.window.localStorage.setItem(
      storageKey,
      jsonEncode(
        reservations.map((reservation) => reservation.toJson()).toList(),
      ),
    );
  }
}
