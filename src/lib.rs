use serde::Deserialize;
use wasm_bindgen::prelude::*;

const CHAIR_PRICE_CENTS: i64 = 1_500;
const TABLE_PRICE_CENTS: i64 = 12_000;
const DECORATION_PRICE_CENTS: i64 = 80_000;
const DELIVERY_PRICE_CENTS: i64 = 25_000;
const DISCOUNT_THRESHOLD_CENTS: i64 = 200_000;
const CHAIR_CAPACITY: u64 = 120;
const TABLE_CAPACITY: u64 = 12;

/// Calcula el total en centavos. El descuento se aplica al subtotal antes de la entrega.
#[wasm_bindgen]
pub fn calculate_total(
    chairs: u32,
    tables: u32,
    decoration: bool,
    delivery: bool,
) -> Result<i64, JsValue> {
    let subtotal = i128::from(chairs) * i128::from(CHAIR_PRICE_CENTS)
        + i128::from(tables) * i128::from(TABLE_PRICE_CENTS)
        + if decoration {
            i128::from(DECORATION_PRICE_CENTS)
        } else {
            0
        };

    // El redondeo del descuento al centavo más cercano es mitad hacia arriba.
    let discounted_subtotal = if subtotal >= i128::from(DISCOUNT_THRESHOLD_CENTS) {
        (subtotal * 9 + 5) / 10
    } else {
        subtotal
    };
    let total = discounted_subtotal
        + if delivery {
            i128::from(DELIVERY_PRICE_CENTS)
        } else {
            0
        };

    i64::try_from(total)
        .map_err(|_| JsValue::from_str("El total excede el rango permitido."))
}

#[derive(Deserialize)]
struct ExistingReservation {
    id: String,
    date: String,
    chairs: u32,
    tables: u32,
    status: ReservationStatus,
}

#[derive(Deserialize)]
enum ReservationStatus {
    #[serde(rename = "Pendiente")]
    Pending,
    #[serde(rename = "Confirmada")]
    Confirmed,
    #[serde(rename = "Cancelada")]
    Cancelled,
}

impl ReservationStatus {
    fn occupies_capacity(&self) -> bool {
        matches!(self, Self::Pending | Self::Confirmed)
    }
}

/// Valida capacidad por fecha; `reservation_id` se excluye al reprogramar.
///
/// `reservations_json` debe ser un arreglo de reservas con id, date, chairs,
/// tables y status ("Pendiente", "Confirmada" o "Cancelada").
#[wasm_bindgen]
pub fn validate_availability(
    reservations_json: &str,
    reservation_id: &str,
    date: &str,
    chairs: u32,
    tables: u32,
) -> Result<(), JsValue> {
    validate_availability_inner(reservations_json, reservation_id, date, chairs, tables)
        .map_err(|error| JsValue::from_str(&error))
}

fn validate_availability_inner(
    reservations_json: &str,
    reservation_id: &str,
    date: &str,
    chairs: u32,
    tables: u32,
) -> Result<(), String> {
    if reservation_id.trim().is_empty() || date.trim().is_empty() {
        return Err("El id de reserva y la fecha son obligatorios.".to_owned());
    }

    let reservations: Vec<ExistingReservation> = serde_json::from_str(reservations_json)
        .map_err(|error| format!("Reservas inválidas: {error}"))?;

    let (reserved_chairs, reserved_tables) = reservations
        .iter()
        .filter(|reservation| {
            reservation.id != reservation_id
                && reservation.date == date
                && reservation.status.occupies_capacity()
        })
        .try_fold((0_u64, 0_u64), |(chair_sum, table_sum), reservation| {
            Some((
                chair_sum.checked_add(u64::from(reservation.chairs))?,
                table_sum.checked_add(u64::from(reservation.tables))?,
            ))
        })
        .ok_or_else(|| "La suma de reservas excede el rango permitido.".to_owned())?;

    let requested_chairs = reserved_chairs
        .checked_add(u64::from(chairs))
        .ok_or_else(|| "La suma de sillas excede el rango permitido.".to_owned())?;
    let requested_tables = reserved_tables
        .checked_add(u64::from(tables))
        .ok_or_else(|| "La suma de mesas excede el rango permitido.".to_owned())?;

    let available_chairs = CHAIR_CAPACITY.saturating_sub(reserved_chairs);
    let available_tables = TABLE_CAPACITY.saturating_sub(reserved_tables);
    let mut shortages = Vec::new();
    if requested_chairs > CHAIR_CAPACITY {
        shortages.push(format!("Sillas: quedan {available_chairs} disponibles."));
    }
    if requested_tables > TABLE_CAPACITY {
        shortages.push(format!("Mesas: quedan {available_tables} disponibles."));
    }
    if !shortages.is_empty() {
        return Err(format!(
            "Disponibilidad insuficiente. {}",
            shortages.join(" ")
        ));
    }

    Ok(())
}

/// Valida un pago decimal y devuelve su valor en centavos.
///
/// `method` solo puede ser "Efectivo" o "Transferencia".
/// `status` debe ser "Pendiente" para el primer pago o "Confirmada" para un abono.
/// `paid_cents` es lo ya pagado; en estado Pendiente debe ser cero.
#[wasm_bindgen]
pub fn validate_payment(
    amount: &str,
    method: &str,
    status: &str,
    total_cents: i64,
    paid_cents: i64,
) -> Result<i64, JsValue> {
    validate_payment_inner(amount, method, status, total_cents, paid_cents)
        .map_err(|error| JsValue::from_str(&error))
}

fn validate_payment_inner(
    amount: &str,
    method: &str,
    status: &str,
    total_cents: i64,
    paid_cents: i64,
) -> Result<i64, String> {
    if !matches!(method, "Efectivo" | "Transferencia") {
        return Err("El método de pago no es válido.".to_owned());
    }

    let amount_cents = parse_amount_cents(amount)?;
    if amount_cents <= 0 {
        return Err("El monto debe ser mayor que cero.".to_owned());
    }
    if total_cents <= 0 || paid_cents < 0 || paid_cents > total_cents {
        return Err("El total o el acumulado de pagos no es válido.".to_owned());
    }

    match status {
        "Pendiente" => {
            if paid_cents != 0 {
                return Err("Una reserva Pendiente no debe tener pagos previos.".to_owned());
            }

            // Redondea 30% del total a centavos, mitad hacia arriba.
            let minimum_payment = (i128::from(total_cents) * 30 + 50) / 100;
            if i128::from(amount_cents) < minimum_payment {
                return Err("El primer pago debe ser al menos el 30% del total.".to_owned());
            }
            if amount_cents > total_cents {
                return Err("El pago no puede superar el total.".to_owned());
            }
        }
        "Confirmada" => {
            if amount_cents > total_cents - paid_cents {
                return Err("El abono no puede superar el saldo actual.".to_owned());
            }
        }
        _ => return Err("El estado de pago no es válido.".to_owned()),
    }

    Ok(amount_cents)
}

fn parse_amount_cents(amount: &str) -> Result<i64, String> {
    let amount = amount.trim();
    if amount.is_empty() || amount.starts_with('-') {
        return Err("El monto no puede estar vacío ni ser negativo.".to_owned());
    }

    let mut parts = amount.split('.');
    let whole = parts
        .next()
        .ok_or_else(|| "El monto debe ser un decimal válido.".to_owned())?;
    let fractional = parts.next();
    if parts.next().is_some()
        || whole.is_empty()
        || !whole.bytes().all(|byte| byte.is_ascii_digit())
    {
        return Err("El monto debe ser un decimal válido.".to_owned());
    }

    let fractional = fractional.unwrap_or("");
    if fractional.len() > 2 {
        return Err("El monto no puede tener más de dos decimales.".to_owned());
    }
    if !fractional.bytes().all(|byte| byte.is_ascii_digit()) {
        return Err("El monto debe ser un decimal válido.".to_owned());
    }

    let whole_cents = whole
        .parse::<i64>()
        .ok()
        .and_then(|value| value.checked_mul(100))
        .ok_or_else(|| "El monto excede el rango permitido.".to_owned())?;
    let fractional_cents = match fractional.len() {
        0 => 0,
        1 => i64::from(fractional.as_bytes()[0] - b'0') * 10,
        2 => {
            let bytes = fractional.as_bytes();
            i64::from(bytes[0] - b'0') * 10 + i64::from(bytes[1] - b'0')
        }
        _ => unreachable!(),
    };

    whole_cents
        .checked_add(fractional_cents)
        .ok_or_else(|| "El monto excede el rango permitido.".to_owned())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn calculates_discount_before_delivery() {
        assert_eq!(calculate_total(100, 5, false, true).unwrap(), 214_000);
        assert_eq!(calculate_total(100, 5, false, false).unwrap(), 189_000);
    }

    #[test]
    fn availability_excludes_reservation_and_cancelled_entries() {
        let reservations = r#"[
            {"id":"moving","date":"2026-12-01","chairs":120,"tables":12,"status":"Pendiente"},
            {"id":"cancelled","date":"2026-12-01","chairs":100,"tables":12,"status":"Cancelada"}
        ]"#;

        assert!(validate_availability_inner(reservations, "moving", "2026-12-01", 120, 12).is_ok());
        assert!(validate_availability_inner(reservations, "new", "2026-12-01", 1, 0).is_err());
    }

    #[test]
    fn availability_reports_each_remaining_inventory_count() {
        let reservations = r#"[
            {"id":"existing","date":"2026-12-01","chairs":119,"tables":11,"status":"Confirmada"}
        ]"#;
        let error =
            validate_availability_inner(reservations, "new", "2026-12-01", 2, 2).unwrap_err();

        assert!(error.contains("Sillas: quedan 1 disponibles."));
        assert!(error.contains("Mesas: quedan 1 disponibles."));
    }

    #[test]
    fn payment_validation_uses_cents_and_remaining_balance() {
        assert_eq!(
            validate_payment_inner("30.00", "Efectivo", "Pendiente", 10_000, 0).unwrap(),
            3_000
        );
        assert!(validate_payment_inner("29.99", "Efectivo", "Pendiente", 10_000, 0).is_err());
        assert!(validate_payment_inner("", "Efectivo", "Pendiente", 10_000, 0).is_err());
        assert!(validate_payment_inner("-1.00", "Efectivo", "Pendiente", 10_000, 0).is_err());
        assert!(validate_payment_inner("100.01", "Efectivo", "Pendiente", 10_000, 0).is_err());
        assert!(validate_payment_inner("0", "Efectivo", "Confirmada", 10_000, 3_000).is_err());
        assert!(validate_payment_inner("0.001", "Efectivo", "Confirmada", 10_000, 3_000).is_err());
        assert!(validate_payment_inner("70.01", "Efectivo", "Confirmada", 10_000, 3_000).is_err());
        assert!(validate_payment_inner("70.00", "Transferencia", "Confirmada", 10_000, 3_000)
            .is_ok());
        assert!(validate_payment_inner("70.00", "Tarjeta", "Confirmada", 10_000, 3_000).is_err());
    }
}
