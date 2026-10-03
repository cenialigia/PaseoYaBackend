# PaseoYA · Backend

Definición reproducible de **Supabase** para PaseoYA: migraciones SQL, RLS, seed sintético y operaciones confiables. No hay servidor Node adicional: Node sólo ejecuta la Supabase CLI (ADR-009).

La documentación vive en el Core, fuera de este repositorio: [cenialigia/documentacionPaseoYa](https://github.com/cenialigia/documentacionPaseoYa). El cliente está en [cenialigia/PaseoYaFrontend](https://github.com/cenialigia/PaseoYaFrontend).

## Requisitos

Node.js ≥ 22.13 y Docker Desktop **en ejecución**.

## Arranque local

```bash
npm install
npm run db:start    # supabase start: Postgres, Auth, API y Studio locales
npm run db:status   # URL y claves LOCALES para el .env del frontend
npm run db:reset    # aplica supabase/migrations y seed desde cero
npm run db:stop
```

## Qué contiene

- `supabase/migrations/20261003000000_esquema_demo.sql`: tipos, tablas (`comercios`, `perfiles`, `productos`, `pedidos`, `pedido_lineas`, `credenciales_retiro`, `reportes`), **RLS por rol y `comercio_id`** y funciones confiables:
  - `confirmar_pedido`: checkout de un comercio, idempotente por clave, con stock atómico al confirmar.
  - `simular_pago`: pago QR simulado; no mueve dinero.
  - `cancelar_pedido`: sólo en `CONFIRMED`; libera el stock una vez.
  - `avanzar_pedido` y `confirmar_efectivo`: acciones del comercio dueño.
  - `validar_retiro`: PIN de un solo uso; exige el pago hecho.
  - `expirar_pedidos`: 72 h efectivo y 14 días QR; se puede reejecutar sin doble efecto.
- `supabase/seed.sql`: catálogo ficticio y cuentas de demostración (contraseña `demo1234`): `cliente@`, `cliente2@`, `techzone@`, `boutique@` y `admin@paseoya.demo`. El registro libre siempre crea CLIENTE; COMERCIO y ADMIN sólo los asigna el seed o un ADMIN.
- `supabase/tests/`: `npm run test:db` (RLS y flujo, 17 comprobaciones, en una transacción revertida) y `npm run test:concurrencia` (dos compras simultáneas de la última unidad).

No hay proyecto cloud conectado. No versionar `.env`, la `service_role` ni las claves de un proyecto remoto.

> Estado: esquema de la demo con RLS y funciones probados localmente. La app todavía usa datos simulados; la integración (INT-01) queda fuera del plazo de la entrega.
