import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'models/reservation.dart';
import 'services/reservation_storage.dart';
import 'services/rust_bridge.dart';

void main() {
  runApp(const MiEventoApp());
}

class MiEventoApp extends StatelessWidget {
  const MiEventoApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'MiEvento Seguimiento',
        debugShowCheckedModeBanner: false,
        locale: const Locale('es', 'MX'),
        supportedLocales: const [Locale('es', 'MX')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        theme: ThemeData(
          useMaterial3: true,
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF276A62),
            surface: const Color(0xFFFCFBF8),
          ),
          scaffoldBackgroundColor: const Color(0xFFF4F3EE),
          inputDecorationTheme: InputDecorationTheme(
            filled: true,
            fillColor: Colors.white,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: const BorderSide(color: Color(0xFFE1E3DD)),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: const BorderSide(color: Color(0xFFE1E3DD)),
            ),
          ),
        ),
        home: FutureBuilder<void>(
          future: RustBridge.ensureInitialized(),
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return StartupMessage(
                title: 'No se pudo iniciar Rust WASM',
                message: '${snapshot.error}',
              );
            }
            if (snapshot.connectionState != ConnectionState.done) {
              return const StartupMessage(
                title: 'Preparando MiEvento',
                message: 'Inicializando las reglas de reservas...',
                loading: true,
              );
            }
            return const ReservationsPage();
          },
        ),
      );
}

class StartupMessage extends StatelessWidget {
  const StartupMessage({
    required this.title,
    required this.message,
    this.loading = false,
    super.key,
  });

  final String title;
  final String message;
  final bool loading;

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Padding(
              padding: const EdgeInsets.all(28),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (loading) const CircularProgressIndicator(),
                  if (loading) const SizedBox(height: 20),
                  Text(title, style: Theme.of(context).textTheme.headlineSmall),
                  const SizedBox(height: 10),
                  Text(message, textAlign: TextAlign.center),
                ],
              ),
            ),
          ),
        ),
      );
}

class ReservationsPage extends StatefulWidget {
  const ReservationsPage({super.key});

  @override
  State<ReservationsPage> createState() => _ReservationsPageState();
}

class _ReservationsPageState extends State<ReservationsPage> {
  final _formKey = GlobalKey<FormState>();
  final _storage = ReservationStorage();
  final _customerController = TextEditingController();
  final _chairsController = TextEditingController(text: '0');
  final _tablesController = TextEditingController(text: '0');

  late final Future<void> _loading;
  List<Reservation> _reservations = [];
  final Set<String> _paymentsInProgress = {};
  final Set<String> _reschedulesInProgress = {};
  DateTime _selectedDate = _dateOnly(DateTime.now());
  DateTime? _filterDate;
  Future<int>? _quote;
  String? _quantityError;
  bool _decoration = false;
  bool _delivery = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _quote = _getQuote(0, 0, false, false);
    _loading = _loadReservations();
  }

  @override
  void dispose() {
    _customerController.dispose();
    _chairsController.dispose();
    _tablesController.dispose();
    super.dispose();
  }

  Future<void> _loadReservations() async {
    final reservations = _storage.readAll();
    if (mounted) setState(() => _reservations = reservations);
  }

  Future<int> _getQuote(int chairs, int tables, bool decoration, bool delivery) =>
      RustBridge.calculateTotalCents(
        chairs: chairs,
        tables: tables,
        decoration: decoration,
        delivery: delivery,
      );

  Map<String, _DateAvailability> get _availabilityByDate {
    final totals = <String, List<int>>{};
    for (final reservation in _reservations) {
      if (!reservation.occupiesInventory) continue;
      final quantities = totals.putIfAbsent(reservation.fecha, () => [0, 0]);
      quantities[0] += reservation.sillas;
      quantities[1] += reservation.mesas;
    }
    return totals.map(
      (date, quantities) => MapEntry(
        date,
        _DateAvailability(
          chairs: 120 - quantities[0] < 0 ? 0 : 120 - quantities[0],
          tables: 12 - quantities[1] < 0 ? 0 : 12 - quantities[1],
        ),
      ),
    );
  }

  void _refreshQuote() {
    final chairs = int.tryParse(_chairsController.text.trim());
    final tables = int.tryParse(_tablesController.text.trim());
    if (chairs == null ||
        tables == null ||
        chairs < 0 ||
        tables < 0 ||
        chairs > 0xFFFFFFFF ||
        tables > 0xFFFFFFFF) {
      setState(() => _quote = null);
      return;
    }
    setState(() {
      _quantityError = null;
      _quote = _getQuote(chairs, tables, _decoration, _delivery);
    });
  }

  Future<void> _submitReservation() async {
    if (_saving || !_formKey.currentState!.validate()) return;

    final customer = _customerController.text.trim();
    final chairs = int.parse(_chairsController.text.trim());
    final tables = int.parse(_tablesController.text.trim());
    if (chairs == 0 && tables == 0) {
      setState(() => _quantityError = 'Agrega al menos una silla o una mesa.');
      return;
    }
    if (!_dateOnly(_selectedDate).isBefore(_dateOnly(DateTime.now()))) {
      setState(() => _quantityError = null);
    } else {
      _showMessage('La fecha del evento no puede ser anterior a hoy.');
      return;
    }

    setState(() => _saving = true);
    final id = DateTime.now().microsecondsSinceEpoch.toString();
    final date = _isoDate(_selectedDate);
    try {
      await RustBridge.validateAvailability(
        reservations: _reservations,
        reservationId: id,
        date: date,
        chairs: chairs,
        tables: tables,
      );
      final totalCents = await RustBridge.calculateTotalCents(
        chairs: chairs,
        tables: tables,
        decoration: _decoration,
        delivery: _delivery,
      );
      final reservation = Reservation(
        id: id,
        cliente: customer,
        fecha: date,
        sillas: chairs,
        mesas: tables,
        decoracion: _decoration,
        entrega: _delivery,
        totalCentavos: totalCents,
        estado: Reservation.pending,
        creadoEn: DateTime.now().toIso8601String(),
        pagos: const [],
      );
      final updated = [..._reservations, reservation];
      _storage.writeAll(updated);
      if (!mounted) return;
      setState(() {
        _reservations = updated;
        _customerController.clear();
        _chairsController.text = '0';
        _tablesController.text = '0';
        _decoration = false;
        _delivery = false;
        _quantityError = null;
        _quote = _getQuote(0, 0, false, false);
      });
      _showMessage('Reserva creada correctamente.');
    } catch (error) {
      _showMessage('$error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _cancelReservation(Reservation reservation) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Cancelar reserva'),
        content: Text('¿Cancelar la reserva de ${reservation.cliente}?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Volver'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Cancelar reserva'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    final updated = _reservations
        .map((item) => item.id == reservation.id
            ? item.withStatus(Reservation.cancelled)
            : item)
        .toList(growable: false);
    try {
      _storage.writeAll(updated);
      if (mounted) setState(() => _reservations = updated);
    } catch (error) {
      _showMessage('$error');
    }
  }

  Future<void> _openPaymentDialog(Reservation reservation) async {
    if (reservation.estado == Reservation.cancelled ||
        reservation.liquidada ||
        _paymentsInProgress.contains(reservation.id)) {
      return;
    }

    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => _PaymentDialog(
        reservation: reservation,
        onSave: (amount, method) =>
            _savePayment(reservation.id, amount, method),
      ),
    );
    if (saved == true) _showMessage('Pago registrado correctamente.');
  }

  Future<void> _savePayment(
    String reservationId,
    String amount,
    String method,
  ) async {
    if (_paymentsInProgress.contains(reservationId)) {
      throw StateError('Ya se está guardando un pago para esta reserva.');
    }
    if (!Payment.allowedMethods.contains(method)) {
      throw ArgumentError('Selecciona Efectivo o Transferencia.');
    }

    final index = _reservations.indexWhere((item) => item.id == reservationId);
    if (index < 0) throw StateError('No se encontró la reserva.');
    final current = _reservations[index];
    if (current.estado == Reservation.cancelled) {
      throw StateError('No se pueden registrar pagos en una reserva cancelada.');
    }
    if (current.liquidada) {
      throw StateError('La reserva ya está liquidada.');
    }

    setState(() => _paymentsInProgress.add(reservationId));
    try {
      final amountCents = await RustBridge.validatePayment(
        amount: amount,
        method: method,
        status: current.estado,
        totalCents: current.totalCentavos,
        paidCents: current.pagado,
      );
      final payment = Payment(
        id: '$reservationId-'
            '${DateTime.now().microsecondsSinceEpoch}-'
            '${current.pagos.length}',
        importe: amountCents,
        metodo: method,
        fechaHora: DateTime.now().toUtc().toIso8601String(),
      );
      final nextStatus = current.estado == Reservation.pending
          ? Reservation.confirmed
          : current.estado;
      final updatedReservation = current.withPayment(
        payment,
        nextStatus: nextStatus,
      );
      final updated = [..._reservations];
      updated[index] = updatedReservation;
      _storage.writeAll(updated);
      if (mounted) setState(() => _reservations = updated);
    } finally {
      if (mounted) setState(() => _paymentsInProgress.remove(reservationId));
    }
  }

  Future<void> _rescheduleReservation(Reservation reservation) async {
    if (!reservation.occupiesInventory ||
        _reschedulesInProgress.contains(reservation.id)) {
      return;
    }

    final selectedDate = await showDialog<DateTime>(
      context: context,
      builder: (context) => _RescheduleDateDialog(
        currentDate: reservation.fecha,
      ),
    );
    if (selectedDate == null || !mounted) return;

    final newDate = _isoDate(selectedDate);
    if (newDate == reservation.fecha) {
      _showMessage('No hubo cambios: elegiste la fecha actual.');
      return;
    }

    try {
      await RustBridge.validateAvailability(
        reservations: _reservations,
        reservationId: reservation.id,
        date: newDate,
        chairs: reservation.sillas,
        tables: reservation.mesas,
      );
    } catch (error) {
      _showMessage('$error');
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Confirmar reprogramación'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Fecha anterior: ${_formatDate(reservation.fecha)}'),
            const SizedBox(height: 8),
            Text('Nueva fecha: ${_formatDate(newDate)}'),
            const SizedBox(height: 12),
            const Text('La disponibilidad se volverá a validar al confirmar.'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Volver'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Confirmar'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    if (_reschedulesInProgress.contains(reservation.id)) return;

    setState(() => _reschedulesInProgress.add(reservation.id));
    try {
      final latestReservations = _storage.readAll();
      final index = latestReservations.indexWhere((item) => item.id == reservation.id);
      if (index < 0) throw StateError('No se encontró la reserva.');
      final latestReservation = latestReservations[index];
      if (!latestReservation.occupiesInventory) {
        throw StateError('La reserva ya no se puede reprogramar.');
      }
      if (latestReservation.fecha != reservation.fecha) {
        throw StateError(
          'La fecha cambió desde la vista previa; vuelve a intentarlo.',
        );
      }

      await RustBridge.validateAvailability(
        reservations: latestReservations,
        reservationId: latestReservation.id,
        date: newDate,
        chairs: latestReservation.sillas,
        tables: latestReservation.mesas,
      );

      final updatedReservation = latestReservation.withDate(newDate);
      final updated = [...latestReservations];
      updated[index] = updatedReservation;
      _storage.writeAll(updated);
      if (!mounted) return;
      setState(() {
        _reservations = updated;
        if (_filterDate != null &&
            _isoDate(_filterDate!) == latestReservation.fecha) {
          _filterDate = DateTime.parse('${newDate}T00:00:00');
        }
      });
      _showMessage('Reserva reprogramada correctamente.');
    } catch (error) {
      _showMessage('$error');
    } finally {
      if (mounted) {
        setState(() => _reschedulesInProgress.remove(reservation.id));
      }
    }
  }

  Future<void> _chooseEventDate() async {
    final today = _dateOnly(DateTime.now());
    final selected = await showDatePicker(
      context: context,
      initialDate: _selectedDate.isBefore(today) ? today : _selectedDate,
      firstDate: today,
      lastDate: DateTime(2100),
    );
    if (selected == null || !mounted) return;
    setState(() {
      _selectedDate = _dateOnly(selected);
      _quantityError = null;
    });
  }

  Future<void> _chooseFilterDate() async {
    final selected = await showDatePicker(
      context: context,
      initialDate: _filterDate ?? _dateOnly(DateTime.now()),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (selected != null && mounted) {
      setState(() => _filterDate = _dateOnly(selected));
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<void>(
        future: _loading,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return StartupMessage(
              title: 'No se pudieron leer las reservas',
              message: '${snapshot.error}',
            );
          }
          if (snapshot.connectionState != ConnectionState.done) {
            return const StartupMessage(
              title: 'Cargando reservas',
              message: 'Leyendo los datos guardados en este navegador...',
              loading: true,
            );
          }
          return _buildPage(context);
        },
      );

  Widget _buildPage(BuildContext context) => Scaffold(
        body: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) => SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 28),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1160),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _buildHeader(context),
                      const SizedBox(height: 24),
                      if (constraints.maxWidth >= 820)
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(flex: 3, child: _buildFormPanel(context)),
                            const SizedBox(width: 20),
                            Expanded(flex: 2, child: _buildAvailabilityPanel(context)),
                          ],
                        )
                      else ...[
                        _buildFormPanel(context),
                        const SizedBox(height: 16),
                        _buildAvailabilityPanel(context),
                      ],
                      const SizedBox(height: 24),
                      _buildReservationsPanel(context),
                      const SizedBox(height: 18),
                      const Text(
                        'Los datos se guardan en este navegador.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Color(0xFF68716B)),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );

  Widget _buildHeader(BuildContext context) => Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primary,
              borderRadius: BorderRadius.circular(16),
            ),
            child: const Icon(Icons.event_available, color: Colors.white),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'MiEvento Seguimiento',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                ),
                const Text('Reservas y disponibilidad de mobiliario'),
              ],
            ),
          ),
          const Chip(label: Text('Paso 2')),
        ],
      );

  Widget _buildFormPanel(BuildContext context) => _Panel(
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const _SectionHeading(
                eyebrow: 'NUEVA RESERVA',
                title: 'Datos del evento',
              ),
              const SizedBox(height: 20),
              TextFormField(
                controller: _customerController,
                maxLength: 100,
                decoration: const InputDecoration(
                  labelText: 'Cliente',
                  hintText: 'Nombre y apellido',
                  counterText: '',
                  prefixIcon: Icon(Icons.person_outline),
                ),
                validator: (value) => value == null || value.trim().isEmpty
                    ? 'Escribe el nombre del cliente.'
                    : null,
              ),
              const SizedBox(height: 14),
              OutlinedButton.icon(
                onPressed: _chooseEventDate,
                icon: const Icon(Icons.calendar_month_outlined),
                label: Text('Fecha del evento: ${_formatDate(_isoDate(_selectedDate))}'),
                style: OutlinedButton.styleFrom(
                  alignment: Alignment.centerLeft,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
                ),
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: _quantityField(
                      controller: _chairsController,
                      label: 'Sillas',
                      price: '\$15 c/u',
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _quantityField(
                      controller: _tablesController,
                      label: 'Mesas',
                      price: '\$120 c/u',
                    ),
                  ),
                ],
              ),
              if (_quantityError != null) ...[
                const SizedBox(height: 8),
                Text(
                  _quantityError!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
              const SizedBox(height: 10),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: _decoration,
                title: const Text('Decoración'),
                subtitle: const Text('\$800 por evento'),
                secondary: const Icon(Icons.auto_awesome_outlined),
                onChanged: (value) {
                  setState(() => _decoration = value ?? false);
                  _refreshQuote();
                },
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: _delivery,
                title: const Text('Entrega'),
                subtitle: const Text('\$250 por evento'),
                secondary: const Icon(Icons.local_shipping_outlined),
                onChanged: (value) {
                  setState(() => _delivery = value ?? false);
                  _refreshQuote();
                },
              ),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: const Color(0xFFF1F5F1),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Row(
                  children: [
                    const Expanded(child: Text('Total estimado')),
                    if (_quote == null)
                      const Text('—')
                    else
                      FutureBuilder<int>(
                        future: _quote,
                        builder: (context, snapshot) {
                          if (snapshot.hasError) {
                            return const Text('No disponible');
                          }
                          if (!snapshot.hasData) {
                            return const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            );
                          }
                          return Text(
                            _formatMoney(snapshot.data!),
                            style: const TextStyle(fontWeight: FontWeight.w800),
                          );
                        },
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _saving ? null : _submitReservation,
                icon: _saving
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.add),
                label: Text(_saving ? 'Guardando...' : 'Crear reserva'),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
              ),
            ],
          ),
        ),
      );

  Widget _quantityField({
    required TextEditingController controller,
    required String label,
    required String price,
  }) =>
      TextFormField(
        controller: controller,
        keyboardType: TextInputType.number,
        decoration: InputDecoration(
          labelText: label,
          helperText: price,
          prefixIcon: const Icon(Icons.numbers),
        ),
        onChanged: (_) => _refreshQuote(),
        validator: (value) {
          final quantity = int.tryParse(value?.trim() ?? '');
          if (quantity == null || quantity < 0) return 'Usa un entero desde 0.';
          if (quantity > 0xFFFFFFFF) return 'Cantidad fuera de rango.';
          return null;
        },
      );

  Widget _buildAvailabilityPanel(BuildContext context) {
    final date = _isoDate(_selectedDate);
    final availability = _availabilityByDate[date] ??
        const _DateAvailability(chairs: 120, tables: 12);
    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _SectionHeading(
            eyebrow: 'INVENTARIO POR FECHA',
            title: 'Disponibilidad restante',
          ),
          const SizedBox(height: 8),
          Text('Para ${_formatDate(date)}'),
          const SizedBox(height: 18),
          Row(
            children: [
              Expanded(
                child: _InventoryTile(
                  label: 'Sillas',
                  remaining: availability.chairs,
                  capacity: 120,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _InventoryTile(
                  label: 'Mesas',
                  remaining: availability.tables,
                  capacity: 12,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          const Text(
            'Las reservas canceladas no ocupan inventario. '
            'La disponibilidad se valida con Rust antes de guardar.',
            style: TextStyle(color: Color(0xFF68716B), height: 1.4),
          ),
        ],
      ),
    );
  }

  Widget _buildReservationsPanel(BuildContext context) {
    final filteredReservations = _reservations
        .where((reservation) =>
            _filterDate == null || reservation.fecha == _isoDate(_filterDate!))
        .toList()
      ..sort((first, second) {
        final byDate = first.fecha.compareTo(second.fecha);
        return byDate == 0 ? second.creadoEn.compareTo(first.creadoEn) : byDate;
      });
    final availability = _availabilityByDate;

    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _SectionHeading(eyebrow: 'CONSULTA', title: 'Reservas'),
          const SizedBox(height: 14),
          Wrap(
            spacing: 10,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              OutlinedButton.icon(
                onPressed: _chooseFilterDate,
                icon: const Icon(Icons.filter_list),
                label: Text(
                  _filterDate == null
                      ? 'Filtrar por fecha'
                      : _formatDate(_isoDate(_filterDate!)),
                ),
              ),
              if (_filterDate != null)
                TextButton(
                  onPressed: () => setState(() => _filterDate = null),
                  child: const Text('Mostrar todas'),
                ),
            ],
          ),
          const SizedBox(height: 10),
          if (filteredReservations.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 28),
              child: Text(
                _reservations.isEmpty
                    ? 'Aún no hay reservas registradas.'
                    : 'No hay reservas para la fecha seleccionada.',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Color(0xFF68716B)),
              ),
            )
          else
            ...filteredReservations.map(
              (reservation) => Padding(
                padding: const EdgeInsets.only(top: 10),
                child: _ReservationCard(
                  reservation: reservation,
                  availability: availability[reservation.fecha] ??
                      const _DateAvailability(chairs: 120, tables: 12),
                  onPayment: reservation.estado == Reservation.cancelled ||
                          reservation.liquidada ||
                          _paymentsInProgress.contains(reservation.id)
                      ? null
                      : () => _openPaymentDialog(reservation),
                  onReschedule: reservation.occupiesInventory &&
                          !_reschedulesInProgress.contains(reservation.id)
                      ? () => _rescheduleReservation(reservation)
                      : null,
                  rescheduling:
                      _reschedulesInProgress.contains(reservation.id),
                  onCancel: reservation.estado == Reservation.cancelled
                      ? null
                      : () => _cancelReservation(reservation),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _DateAvailability {
  const _DateAvailability({required this.chairs, required this.tables});

  final int chairs;
  final int tables;
}

class _Panel extends StatelessWidget {
  const _Panel({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(22),
        decoration: BoxDecoration(
          color: const Color(0xFFFCFBF8),
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: const Color(0xFFE5E5DF)),
        ),
        child: child,
      );
}

class _SectionHeading extends StatelessWidget {
  const _SectionHeading({required this.eyebrow, required this.title});

  final String eyebrow;
  final String title;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            eyebrow,
            style: const TextStyle(
              color: Color(0xFF54796E),
              fontSize: 11,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            title,
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
          ),
        ],
      );
}

class _InventoryTile extends StatelessWidget {
  const _InventoryTile({
    required this.label,
    required this.remaining,
    required this.capacity,
  });

  final String label;
  final int remaining;
  final int capacity;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: const Color(0xFFF2F5F1),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label),
            const SizedBox(height: 8),
            Text(
              '$remaining',
              style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: Theme.of(context).colorScheme.primary,
                  ),
            ),
            Text('disponibles de $capacity'),
          ],
        ),
      );
}

class _ReservationCard extends StatelessWidget {
  const _ReservationCard({
    required this.reservation,
    required this.availability,
    required this.onPayment,
    required this.onReschedule,
    required this.rescheduling,
    required this.onCancel,
  });

  final Reservation reservation;
  final _DateAvailability availability;
  final VoidCallback? onPayment;
  final VoidCallback? onReschedule;
  final bool rescheduling;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    final isCancelled = reservation.estado == Reservation.cancelled;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: const Color(0xFFE7E8E2)),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                reservation.cliente,
                style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
              ),
              Chip(
                label: Text(reservation.estado),
                visualDensity: VisualDensity.compact,
                backgroundColor: isCancelled
                    ? const Color(0xFFF2E9E7)
                    : const Color(0xFFE5F1E8),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text('${_formatDate(reservation.fecha)} · ${reservation.sillas} sillas · '
              '${reservation.mesas} mesas'),
          const SizedBox(height: 4),
          Text(
            'Decoración: ${reservation.decoracion ? 'Sí' : 'No'} · '
            'Entrega: ${reservation.entrega ? 'Sí' : 'No'} · '
            'Total: ${_formatMoney(reservation.totalCentavos)}',
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 16,
            runSpacing: 4,
            children: [
              Text('Pagado: ${_formatMoney(reservation.pagado)}'),
              Text('Saldo: ${_formatMoney(reservation.saldo)}'),
              if (reservation.liquidada)
                const Chip(
                  label: Text('Liquidada'),
                  visualDensity: VisualDensity.compact,
                  backgroundColor: Color(0xFFE5F1E8),
                ),
            ],
          ),
          if (isCancelled)
            const Padding(
              padding: EdgeInsets.only(top: 4),
              child: Text(
                'Reserva cancelada; no se calculan devoluciones.',
                style: TextStyle(color: Color(0xFF8A5149)),
              ),
            ),
          const SizedBox(height: 8),
          Text(
            'Historial de pagos (${reservation.pagos.length})',
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          if (reservation.pagos.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text('Sin pagos registrados.'),
            )
          else
            ...reservation.pagos.map(
              (payment) => _PaymentHistoryRow(payment: payment),
            ),
          const SizedBox(height: 8),
          Text(
            isCancelled
                ? 'Disponibilidad en esa fecha: ${availability.chairs} sillas · '
                    '${availability.tables} mesas'
                : 'Restan en esa fecha: ${availability.chairs} sillas · '
                    '${availability.tables} mesas',
            style: const TextStyle(
              color: Color(0xFF54796E),
              fontWeight: FontWeight.w600,
            ),
          ),
          if (onPayment != null)
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.tonalIcon(
                onPressed: onPayment,
                icon: const Icon(Icons.payments_outlined),
                label: Text(
                  reservation.estado == Reservation.pending
                      ? 'Registrar primer pago'
                      : 'Agregar abono',
                ),
              ),
            ),
          if (rescheduling || onReschedule != null)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: onReschedule,
                icon: rescheduling
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.event_repeat),
                label: Text(rescheduling ? 'Reprogramando...' : 'Reprogramar'),
              ),
            ),
          if (onCancel != null)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: onCancel,
                icon: const Icon(Icons.event_busy_outlined),
                label: const Text('Cancelar reserva'),
                style: TextButton.styleFrom(foregroundColor: const Color(0xFF9B4339)),
              ),
            ),
        ],
      ),
    );
  }
}

class _PaymentHistoryRow extends StatelessWidget {
  const _PaymentHistoryRow({required this.payment});

  final Payment payment;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 5),
        child: Row(
          children: [
            const Icon(Icons.check_circle_outline, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '${_formatMoney(payment.importe)} · ${payment.metodo} · '
                '${_formatDateTime(payment.fechaHora)}',
              ),
            ),
          ],
        ),
      );
}

class _RescheduleDateDialog extends StatefulWidget {
  const _RescheduleDateDialog({required this.currentDate});

  final String currentDate;

  @override
  State<_RescheduleDateDialog> createState() => _RescheduleDateDialogState();
}

class _RescheduleDateDialogState extends State<_RescheduleDateDialog> {
  DateTime? _newDate;

  Future<void> _chooseDate() async {
    final today = _dateOnly(DateTime.now());
    final currentDate = DateTime.parse('${widget.currentDate}T00:00:00');
    final initialDate = _newDate ??
        (currentDate.isBefore(today) ? today : currentDate);
    final selected = await showDatePicker(
      context: context,
      initialDate: initialDate,
      firstDate: today,
      lastDate: DateTime(2100),
    );
    if (selected != null && mounted) {
      setState(() => _newDate = _dateOnly(selected));
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Reprogramar reserva'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Fecha actual: ${_formatDate(widget.currentDate)}'),
            const SizedBox(height: 14),
            OutlinedButton.icon(
              onPressed: _chooseDate,
              icon: const Icon(Icons.calendar_month_outlined),
              label: Text(
                _newDate == null
                    ? 'Seleccionar nueva fecha'
                    : _formatDate(_isoDate(_newDate!)),
              ),
            ),
            if (_newDate != null)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text('La nueva fecha debe ser hoy o posterior.'),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed:
                _newDate == null ? null : () => Navigator.pop(context, _newDate),
            child: const Text('Ver disponibilidad'),
          ),
        ],
      );
}

class _PaymentDialog extends StatefulWidget {
  const _PaymentDialog({
    required this.reservation,
    required this.onSave,
  });

  final Reservation reservation;
  final Future<void> Function(String amount, String method) onSave;

  @override
  State<_PaymentDialog> createState() => _PaymentDialogState();
}

class _PaymentDialogState extends State<_PaymentDialog> {
  final _formKey = GlobalKey<FormState>();
  final _amountController = TextEditingController();
  String _method = 'Efectivo';
  bool _saving = false;

  @override
  void dispose() {
    _amountController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_saving || !_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      await widget.onSave(_amountController.text, _method);
      if (!mounted) return;
      _amountController.clear();
      _method = 'Efectivo';
      Navigator.of(context).pop(true);
    } catch (error) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('$error')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final isFirstPayment = widget.reservation.estado == Reservation.pending;
    return AlertDialog(
      title: Text(isFirstPayment ? 'Registrar primer pago' : 'Registrar abono'),
      content: SizedBox(
        width: 420,
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                isFirstPayment
                    ? 'El primer pago debe cubrir al menos el 30% del total.'
                    : 'Saldo actual: ${_formatMoney(widget.reservation.saldo)}',
              ),
              const SizedBox(height: 14),
              TextFormField(
                controller: _amountController,
                autofocus: true,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(
                  labelText: 'Importe',
                  hintText: '0.00',
                  prefixText: '\$ ',
                ),
                validator: (value) => value == null || value.trim().isEmpty
                    ? 'Ingresa el importe del pago.'
                    : null,
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                value: _method,
                decoration: const InputDecoration(labelText: 'Método de pago'),
                items: Payment.allowedMethods
                    .map(
                      (method) => DropdownMenuItem(
                        value: method,
                        child: Text(method),
                      ),
                    )
                    .toList(),
                onChanged: _saving
                    ? null
                    : (method) {
                        if (method != null) setState(() => _method = method);
                      },
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context, false),
          child: const Text('Volver'),
        ),
        FilledButton(
          onPressed: _saving ? null : _submit,
          child: _saving
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Guardar pago'),
        ),
      ],
    );
  }
}

DateTime _dateOnly(DateTime date) => DateTime(date.year, date.month, date.day);

String _isoDate(DateTime? date) {
  if (date == null) return '';
  final year = date.year.toString().padLeft(4, '0');
  final month = date.month.toString().padLeft(2, '0');
  final day = date.day.toString().padLeft(2, '0');
  return '$year-$month-$day';
}

String _formatDate(String isoDate) {
  final parts = isoDate.split('-');
  if (parts.length != 3) return isoDate;
  return '${parts[2]}/${parts[1]}/${parts[0]}';
}

String _formatDateTime(String isoDateTime) {
  final dateTime = DateTime.parse(isoDateTime).toLocal();
  final date = _formatDate(_isoDate(dateTime));
  final hour = dateTime.hour.toString().padLeft(2, '0');
  final minute = dateTime.minute.toString().padLeft(2, '0');
  return '$date $hour:$minute';
}

String _formatMoney(int cents) {
  final amount = cents ~/ 100;
  final digits = amount.toString();
  final grouped = StringBuffer();
  for (var index = 0; index < digits.length; index++) {
    if (index > 0 && (digits.length - index) % 3 == 0) grouped.write(',');
    grouped.write(digits[index]);
  }
  return '\$${grouped.toString()}.${(cents % 100).toString().padLeft(2, '0')}';
}
