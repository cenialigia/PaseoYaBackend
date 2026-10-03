-- Seed sintético de desarrollo local. Sólo datos ficticios (DEC-15). Contraseña de todas las cuentas: demo1234.

insert into public.comercios (id, nombre, local, piso, categoria, abierto) values
  ('10000000-0000-0000-0000-000000000001', 'TechZone', 'Local 208', 'Planta baja', 'Tecnología', true),
  ('10000000-0000-0000-0000-000000000002', 'Boutique Aranjuez', 'Local 105', 'Piso 1', 'Moda', true),
  ('10000000-0000-0000-0000-000000000003', 'Café del Paseo', 'Local 012', 'Planta baja', 'Gastronomía', false);

insert into public.productos (id, comercio_id, nombre, precio, precio_anterior, stock) values
  ('20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'Audífonos inalámbricos', 450, 520, 1),
  ('20000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', 'Cargador USB-C 30 W', 120, null, 14),
  ('20000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001', 'Mouse ergonómico', 180, null, 0),
  ('20000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000002', 'Chaqueta de mezclilla', 380, null, 6),
  ('20000000-0000-0000-0000-000000000005', '10000000-0000-0000-0000-000000000002', 'Bufanda de alpaca', 210, 250, 3),
  ('20000000-0000-0000-0000-000000000006', '10000000-0000-0000-0000-000000000002', 'Cinturón de cuero', 150, null, 9),
  ('20000000-0000-0000-0000-000000000007', '10000000-0000-0000-0000-000000000003', 'Café de altura 250 g', 65, null, 20),
  ('20000000-0000-0000-0000-000000000008', '10000000-0000-0000-0000-000000000003', 'Caja de 6 salteñas', 72, null, 8),
  ('20000000-0000-0000-0000-000000000009', '10000000-0000-0000-0000-000000000003', 'Porción de torta de chocolate', 28, null, 0);

-- Cuentas de demostración. El trigger crea cada perfil como CLIENTE.
with cuentas(id, email, nombre) as (
  values
    ('00000000-0000-0000-0000-0000000000a1'::uuid, 'cliente@paseoya.demo', 'Cliente Demo'),
    ('00000000-0000-0000-0000-0000000000a2'::uuid, 'cliente2@paseoya.demo', 'Cliente Dos'),
    ('00000000-0000-0000-0000-0000000000b1'::uuid, 'techzone@paseoya.demo', 'TechZone'),
    ('00000000-0000-0000-0000-0000000000b2'::uuid, 'boutique@paseoya.demo', 'Boutique Aranjuez'),
    ('00000000-0000-0000-0000-0000000000c1'::uuid, 'admin@paseoya.demo', 'Administración Paseo Aranjuez')
)
insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
  confirmation_token, recovery_token, email_change_token_new, email_change)
select '00000000-0000-0000-0000-000000000000', id, 'authenticated', 'authenticated', email,
  extensions.crypt('demo1234', extensions.gen_salt('bf')), now(),
  '{"provider":"email","providers":["email"]}', jsonb_build_object('nombre', nombre), now(), now(), '', '', '', ''
from cuentas;

insert into auth.identities (id, user_id, provider_id, provider, identity_data, last_sign_in_at, created_at, updated_at)
select gen_random_uuid(), u.id, u.id::text, 'email', jsonb_build_object('sub', u.id::text, 'email', u.email, 'email_verified', true), now(), now(), now()
from auth.users u where u.email like '%@paseoya.demo';

-- Elevación explícita de roles: sólo el seed (o un ADMIN) puede crear COMERCIO y ADMIN (DEC-10).
update public.perfiles set rol = 'COMERCIO', comercio_id = '10000000-0000-0000-0000-000000000001' where id = '00000000-0000-0000-0000-0000000000b1';
update public.perfiles set rol = 'COMERCIO', comercio_id = '10000000-0000-0000-0000-000000000002' where id = '00000000-0000-0000-0000-0000000000b2';
update public.perfiles set rol = 'ADMIN' where id = '00000000-0000-0000-0000-0000000000c1';
