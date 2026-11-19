class Reservation {
  const Reservation({
    required this.id,
    required this.cliente,
    required this.fecha,
    required this.sillas,
    required this.mesas,
    required this.decoracion,
    required this.entrega,
    required this.totalCentavos,
    required this.estado,
    required this.creadoEn,
    required this.pagos,
  });

  static const pending = 'Pendiente';
  static const confirmed = 'Confirmada';
  static const cancelled = 'Cancelada';

  final List<Payment> pagos;
  final String id;
  final String cliente;
  final String fecha;
  final int sillas;
  final int mesas;
  final bool decoracion;
  final bool entrega;
  final int totalCentavos;
  final String estado;
  final String creadoEn;

  int get pagado => pagos.fold(0, (sum, payment) => sum + payment.importe);
  int get saldo => totalCentavos - pagado;
  bool get liquidada => saldo == 0;
  bool get occupiesInventory => estado == pending || estado == confirmed;

  Reservation withStatus(String nextStatus) => Reservation(
        id: id,
        cliente: cliente,
        fecha: fecha,
        sillas: sillas,
        mesas: mesas,
        decoracion: decoracion,
        entrega: entrega,
        totalCentavos: totalCentavos,
        estado: nextStatus,
        creadoEn: creadoEn,
        pagos: pagos,
      );

  Reservation withDate(String nextDate) => Reservation(
        id: id,
        cliente: cliente,
        fecha: nextDate,
        sillas: sillas,
        mesas: mesas,
        decoracion: decoracion,
        entrega: entrega,
        totalCentavos: totalCentavos,
        estado: estado,
        creadoEn: creadoEn,
        pagos: pagos,
      );

  Reservation withPayment(Payment payment, {required String nextStatus}) {
    if (estado == cancelled) {
      throw StateError('No se pueden registrar pagos en una reserva cancelada.');
    }
    if (!Payment.allowedMethods.contains(payment.metodo) || payment.importe <= 0) {
      throw StateError('El pago no tiene un importe o método válido.');
    }
    final nextPayments = [...pagos, payment]
      ..sort(_comparePayments);
    final nextPaid = nextPayments.fold(0, (sum, item) => sum + item.importe);
    if (nextPaid > totalCentavos) {
      throw StateError('Los pagos exceden el total de la reserva.');
    }

    return Reservation(
      id: id,
      cliente: cliente,
      fecha: fecha,
      sillas: sillas,
      mesas: mesas,
      decoracion: decoracion,
      entrega: entrega,
      totalCentavos: totalCentavos,
      estado: nextStatus,
      creadoEn: creadoEn,
      pagos: nextPayments,
    );
  }

  Map<String, Object?> toJson() => {
        'id': id,
        'cliente': cliente,
        'fecha': fecha,
        'sillas': sillas,
        'mesas': mesas,
        'decoracion': decoracion,
        'entrega': entrega,
        'totalCentavos': totalCentavos,
        'estado': estado,
        'creadoEn': creadoEn,
        'pagos': pagos.map((payment) => payment.toJson()).toList(),
      };

  Map<String, Object?> toRustJson() => {
        'id': id,
        'date': fecha,
        'chairs': sillas,
        'tables': mesas,
        'status': estado,
      };

  factory Reservation.fromJson(Map<String, dynamic> json) {
    final status = json['estado'];
    if (status is! String ||
        !{pending, confirmed, cancelled}.contains(status)) {
      throw const FormatException('El estado de una reserva no es válido.');
    }

    final totalCents = _requiredInt(json, 'totalCentavos');
    final serializedPayments = json['pagos'] ?? const [];
    if (serializedPayments is! List) {
      throw const FormatException('El historial de pagos no es válido.');
    }
    final payments = serializedPayments.map((entry) {
      if (entry is! Map) {
        throw const FormatException('Un pago guardado no es válido.');
      }
      return Payment.fromJson(Map<String, dynamic>.from(entry));
    }).toList()
      ..sort(_comparePayments);
    if (status == pending && payments.isNotEmpty) {
      throw const FormatException(
        'Una reserva Pendiente no puede tener pagos registrados.',
      );
    }

    var paid = 0;
    final paymentIds = <String>{};
    for (final payment in payments) {
      if (!paymentIds.add(payment.id)) {
        throw const FormatException('Los ids de pago deben ser únicos.');
      }
      if (payment.importe > totalCents - paid) {
        throw const FormatException('Los pagos exceden el total de la reserva.');
      }
      paid += payment.importe;
    }

    return Reservation(
      id: _requiredString(json, 'id'),
      cliente: _requiredString(json, 'cliente'),
      fecha: _requiredString(json, 'fecha'),
      sillas: _requiredInt(json, 'sillas'),
      mesas: _requiredInt(json, 'mesas'),
      decoracion: _requiredBool(json, 'decoracion'),
      entrega: _requiredBool(json, 'entrega'),
      totalCentavos: totalCents,
      estado: status,
      creadoEn: _requiredString(json, 'creadoEn'),
      pagos: payments,
    );
  }
}

int _comparePayments(Payment first, Payment second) {
  final byDate = DateTime.parse(first.fechaHora)
      .compareTo(DateTime.parse(second.fechaHora));
  return byDate == 0 ? first.id.compareTo(second.id) : byDate;
}

class Payment {
  const Payment({
    required this.id,
    required this.importe,
    required this.metodo,
    required this.fechaHora,
  });

  static const allowedMethods = {'Efectivo', 'Transferencia'};

  final String id;
  // Importe expresado en centavos enteros.
  final int importe;
  final String metodo;
  final String fechaHora;

  Map<String, Object?> toJson() => {
        'id': id,
        'importe': importe,
        'metodo': metodo,
        'fechaHora': fechaHora,
      };

  factory Payment.fromJson(Map<String, dynamic> json) {
    final payment = Payment(
      id: _requiredString(json, 'id'),
      importe: _requiredInt(json, 'importe'),
      metodo: _requiredString(json, 'metodo'),
      fechaHora: _requiredString(json, 'fechaHora'),
    );
    if (payment.id.isEmpty ||
        payment.importe == 0 ||
        !allowedMethods.contains(payment.metodo)) {
      throw const FormatException('Un pago guardado no cumple las reglas.');
    }
    DateTime.parse(payment.fechaHora);
    return payment;
  }
}

String _requiredString(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! String) {
    throw FormatException('El campo "$key" de una reserva no es válido.');
  }
  return value;
}

int _requiredInt(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! int || value < 0) {
    throw FormatException('El campo "$key" de una reserva no es válido.');
  }
  return value;
}

bool _requiredBool(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! bool) {
    throw FormatException('El campo "$key" de una reserva no es válido.');
  }
  return value;
}
