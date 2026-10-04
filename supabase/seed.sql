-- Seed sintético de desarrollo local con los datos de los mosaicos F14 (DEC-F14-12). Sólo datos ficticios.
-- Contraseña de todas las cuentas: demo1234. Los UUID de comercios, productos y cuentas que usan las pruebas no cambian.

insert into public.categorias (id, nombre, icono, orden) values
  ('30000000-0000-0000-0000-000000000001', 'Tecnología', 'devices', 1),
  ('30000000-0000-0000-0000-000000000002', 'Moda', 'checkroom', 2),
  ('30000000-0000-0000-0000-000000000003', 'Comida', 'restaurant', 3),
  ('30000000-0000-0000-0000-000000000004', 'Accesorios', 'watch', 4);

insert into public.comercios (id, nombre, local, piso, categoria_id, abierto, descripcion) values
  ('10000000-0000-0000-0000-000000000001', 'TechStore', 'Local 215', 'Piso 2', '30000000-0000-0000-0000-000000000001', true, 'Computadoras, celulares y accesorios'),
  ('10000000-0000-0000-0000-000000000002', 'Fashion Store', 'Local 110', 'Piso 1', '30000000-0000-0000-0000-000000000002', true, 'Ropa y calzado urbano'),
  ('10000000-0000-0000-0000-000000000003', 'GameZone', 'Local 220', 'Piso 3', '30000000-0000-0000-0000-000000000001', false, 'Consolas, videojuegos y accesorios'),
  ('10000000-0000-0000-0000-000000000004', 'Sabor Criollo', 'Local 123', 'Piso 1', '30000000-0000-0000-0000-000000000003', true, 'Almuerzos y comida criolla'),
  ('10000000-0000-0000-0000-000000000005', 'SmartLife', 'Local 105', 'Piso 1', '30000000-0000-0000-0000-000000000004', true, 'Hogar inteligente y wearables'),
  ('10000000-0000-0000-0000-000000000006', 'MobiCenter', 'Local 301', 'Piso 3', '30000000-0000-0000-0000-000000000001', true, 'Celulares y accesorios'),
  ('10000000-0000-0000-0000-000000000007', 'Digital World', 'Local 101', 'Piso 1', '30000000-0000-0000-0000-000000000001', true, 'Tecnología, gaming y sonido');

insert into public.productos (id, comercio_id, nombre, precio, stock, descripcion) values
  ('20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'Audífonos Bluetooth', 300, 1, 'Audífonos inalámbricos con batería de larga duración'),
  ('20000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', 'Cargador USB-C 30 W', 120, 14, 'Carga rápida para celulares y tablets'),
  ('20000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001', 'Mouse inalámbrico', 180, 0, 'Mouse ergonómico recargable'),
  ('20000000-0000-0000-0000-00000000000a', '10000000-0000-0000-0000-000000000001', 'iPhone 15', 3500, 4, '128 GB'),
  ('20000000-0000-0000-0000-00000000000b', '10000000-0000-0000-0000-000000000001', 'Samsung S24', 3200, 5, '256 GB'),
  ('20000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000002', 'Chaqueta de mezclilla', 380, 6, 'Talla M'),
  ('20000000-0000-0000-0000-000000000005', '10000000-0000-0000-0000-000000000002', 'Bufanda de alpaca', 210, 3, 'Tejido artesanal'),
  ('20000000-0000-0000-0000-000000000006', '10000000-0000-0000-0000-000000000002', 'Cinturón de cuero', 150, 9, 'Cuero genuino'),
  ('20000000-0000-0000-0000-00000000000c', '10000000-0000-0000-0000-000000000002', 'Zapatillas Urbanas', 350, 8, 'Tallas 38 a 43'),
  ('20000000-0000-0000-0000-00000000000d', '10000000-0000-0000-0000-000000000002', 'Polera Básica', 90, 20, 'Algodón'),
  ('20000000-0000-0000-0000-000000000007', '10000000-0000-0000-0000-000000000003', 'Control inalámbrico', 65, 20, 'Compatible con consolas actuales'),
  ('20000000-0000-0000-0000-000000000008', '10000000-0000-0000-0000-000000000003', 'Juego de carreras', 72, 8, 'Edición estándar'),
  ('20000000-0000-0000-0000-000000000009', '10000000-0000-0000-0000-000000000003', 'Soporte para auriculares', 28, 0, 'Acrílico'),
  ('20000000-0000-0000-0000-00000000000e', '10000000-0000-0000-0000-000000000004', 'Almuerzo Ejecutivo', 45, 30, 'Sopa, segundo y refresco'),
  ('20000000-0000-0000-0000-00000000000f', '10000000-0000-0000-0000-000000000004', 'Ensalada César', 35, 25, 'Con pollo a la plancha'),
  ('20000000-0000-0000-0000-000000000010', '10000000-0000-0000-0000-000000000005', 'Smartwatch', 600, 6, 'Monitor de ritmo cardíaco y GPS'),
  ('20000000-0000-0000-0000-000000000011', '10000000-0000-0000-0000-000000000006', 'Funda para celular', 40, 50, 'Silicona resistente');

-- Promociones aprobadas (vigentes un mes) y una pendiente de aprobación (DEC-F14-11).
insert into public.promociones (producto_id, comercio_id, porcentaje, inicio, fin, estado) values
  ('20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 40, now() - interval '1 day', now() + interval '30 days', 'APROBADA'),
  ('20000000-0000-0000-0000-00000000000c', '10000000-0000-0000-0000-000000000002', 30, now() - interval '1 day', now() + interval '30 days', 'APROBADA'),
  ('20000000-0000-0000-0000-000000000010', '10000000-0000-0000-0000-000000000005', 25, now() - interval '1 day', now() + interval '30 days', 'APROBADA'),
  ('20000000-0000-0000-0000-00000000000d', '10000000-0000-0000-0000-000000000002', 10, now(), now() + interval '15 days', 'PENDIENTE');

-- Cuentas de demostración. El trigger crea cada perfil como CLIENTE.
with cuentas(id, email, nombre, telefono, genero, nacimiento) as (
  values
    ('00000000-0000-0000-0000-0000000000a1'::uuid, 'cliente@paseoya.demo', 'María Fernanda', '+591 70000001', 'FEMENINO', '1998-04-12'),
    ('00000000-0000-0000-0000-0000000000a2'::uuid, 'cliente2@paseoya.demo', 'Carlos Rojas', '+591 70000002', 'MASCULINO', '1995-09-30'),
    ('00000000-0000-0000-0000-0000000000b1'::uuid, 'techstore@paseoya.demo', 'TechStore', null, null, null),
    ('00000000-0000-0000-0000-0000000000b2'::uuid, 'fashion@paseoya.demo', 'Fashion Store', null, null, null),
    ('00000000-0000-0000-0000-0000000000b3'::uuid, 'saborcriollo@paseoya.demo', 'Sabor Criollo', null, null, null),
    ('00000000-0000-0000-0000-0000000000c1'::uuid, 'admin@paseoya.demo', 'Administración Paseo Aranjuez', null, null, null)
)
insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
  confirmation_token, recovery_token, email_change_token_new, email_change)
select '00000000-0000-0000-0000-000000000000', id, 'authenticated', 'authenticated', email,
  extensions.crypt('demo1234', extensions.gen_salt('bf')), now(),
  '{"provider":"email","providers":["email"]}',
  jsonb_strip_nulls(jsonb_build_object('nombre', nombre, 'telefono', telefono, 'genero', genero, 'fecha_nacimiento', nacimiento)),
  now(), now(), '', '', '', ''
from cuentas;

insert into auth.identities (id, user_id, provider_id, provider, identity_data, last_sign_in_at, created_at, updated_at)
select gen_random_uuid(), u.id, u.id::text, 'email', jsonb_build_object('sub', u.id::text, 'email', u.email, 'email_verified', true), now(), now(), now()
from auth.users u where u.email like '%@paseoya.demo';

-- Elevación explícita de roles: sólo el seed (o un ADMIN) puede crear COMERCIO y ADMIN (DEC-10).
update public.perfiles set rol = 'COMERCIO', comercio_id = '10000000-0000-0000-0000-000000000001' where id = '00000000-0000-0000-0000-0000000000b1';
update public.perfiles set rol = 'COMERCIO', comercio_id = '10000000-0000-0000-0000-000000000002' where id = '00000000-0000-0000-0000-0000000000b2';
update public.perfiles set rol = 'COMERCIO', comercio_id = '10000000-0000-0000-0000-000000000004' where id = '00000000-0000-0000-0000-0000000000b3';
update public.perfiles set rol = 'ADMIN' where id = '00000000-0000-0000-0000-0000000000c1';

-- Horario de atención (DEC-F14-07: lo edita cada comercio).
update public.comercios set horario = 'Lun a dom · 10:00 a 22:00';
update public.comercios set horario = 'Lun a dom · 11:00 a 21:00' where id = '10000000-0000-0000-0000-000000000004';
