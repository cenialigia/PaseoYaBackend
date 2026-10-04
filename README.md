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
  - `verificar_retiro` (QR del ticket o PIN, no consume) y `confirmar_entrega` (consume la credencial de un uso; exige el pago hecho).
  - `expirar_pedidos`: 72 h efectivo y 14 días QR; se puede reejecutar sin doble efecto.
- `supabase/migrations/20261003010000_realtime_y_cron.sql`: **Realtime** sobre `pedidos` (cada usuario recibe sólo los pedidos que su RLS le deja ver; `credenciales_retiro` no se difunde) y job de `pg_cron` `expirar-pedidos` que ejecuta `expirar_pedidos()` cada minuto.
- `supabase/seed.sql`: catálogo ficticio y cuentas de demostración (contraseña `demo1234`): `cliente@`, `cliente2@`, `techstore@`, `fashion@`, `saborcriollo@` y `admin@paseoya.demo`. Datos de tiendas y productos tomados de los mosaicos F14 (DEC-F14-12). El registro libre siempre crea CLIENTE; COMERCIO y ADMIN sólo los asigna el seed o un ADMIN.
- `supabase/tests/`: `npm run test:db` (RLS y flujo, 17 comprobaciones, en una transacción revertida) y `npm run test:concurrencia` (dos compras simultáneas de la última unidad).

No hay proyecto cloud conectado. No versionar `.env`, la `service_role` ni las claves de un proyecto remoto.

> Estado: esquema con RLS y funciones probados localmente (`npm run test:db`, 33 comprobaciones). La app ya está conectada a este backend (INT-01/02).

## F14 · lote Cliente

`20261004000000_f14_cliente.sql` añade:
- Perfil ampliado: teléfono, género, nacimiento y avatar, editables sólo por su dueño (permisos de columna). `contacto_cliente` da el teléfono al comercio dueño sólo en pedidos activos.
- Tabla `categorias`.
- `promociones` en porcentaje: las de comercio quedan PENDIENTE hasta que el admin las aprueba; `precio_vigente` las aplica en `confirmar_pedido` y el precio se congela en el pedido.
- `favoritos` y `notificaciones` (generadas por trigger al cambiar un pedido, con Realtime).
- `productos_mas_pedidos`.
- Buckets de Storage `avatares` (privado por usuario) e `imagenes` (público; escribe el comercio en su carpeta).

La recuperación de contraseña envía un código de 6 dígitos (plantilla `supabase/templates/recuperar.html`; en local se lee en Mailpit).

## F14 · lote Comercio

`20261005000000_f14_comercio.sql` añade:
- `comercios.horario`. El comercio edita descripción, horario, foto y abierto/cerrado; el disparador `proteger_comercio` reserva nombre, categoría, piso, local y estado al admin (DEC-F14-07).
- Retiro en dos pasos (DEC-F14-14): `verificar_retiro(codigo, pedido?)` acepta el QR del ticket (`paseoya:retiro:<pedido>:<pin>`) o el PIN y no consume nada; `confirmar_entrega(pedido, codigo)` vuelve a verificar con el pedido bloqueado, exige el pago hecho y consume la credencial. Sustituye a `validar_retiro`.
- Avisos para las cuentas del comercio: pedido nuevo, pago QR recibido, cancelación y vencimiento.
- Un producto con pedidos no se puede borrar (clave foránea); el comercio lo desactiva.

## F14 · lote Administrador

`20261006000000_f14_admin.sql` añade:
- `auditoria_admin`: cada alta, cambio o baja que hace un ADMIN en comercios, categorías, promociones, productos y perfiles queda registrada por disparador (sólo lectura para el admin).
- El admin sólo activa o desactiva productos (`proteger_producto_admin`); precio, stock, altas y bajas son del comercio.
- `crear_comercio(...)`: crea el comercio (cerrado) y su cuenta COMERCIO con correo y contraseña inicial.
- `perfiles.activo` y `cambiar_estado_usuario`: desactivar bloquea el inicio de sesión (`banned_until`); el admin no puede desactivarse a sí mismo.
- `listar_usuarios()`: usuarios con su correo, sólo para el admin.
- Avisos de promociones: al admin cuando un comercio propone una y al comercio cuando se aprueba o rechaza.

