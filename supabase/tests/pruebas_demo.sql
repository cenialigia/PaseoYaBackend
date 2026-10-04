-- Pruebas de RLS y flujo (T-RLS, T-CHECKOUT, T-RET, T-CAN, T-STOCK, T-EXP). Ejecutar con `npm run test:db`.
-- Todo ocurre dentro de una transacción que se revierte al final: la base queda como el seed.
\set ON_ERROR_STOP on
\set QUIET on
begin;

create temp table ctx (k text primary key, v text);
grant all on ctx to authenticated, anon;

-- Ejecuta como el usuario indicado, con el JWT que usaría PostgREST.
create function pg_temp.como(p uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p, 'role', 'authenticated')::text, true);
  select set_config('role', 'authenticated', true);
$$;

-- Identificadores del seed
\set cliA   '''00000000-0000-0000-0000-0000000000a1'''
\set cliB   '''00000000-0000-0000-0000-0000000000a2'''
\set tech   '''00000000-0000-0000-0000-0000000000b1'''
\set bout   '''00000000-0000-0000-0000-0000000000b2'''
\set admin  '''00000000-0000-0000-0000-0000000000c1'''

-- T-CHECKOUT · confirmar e idempotencia -------------------------------------------
select pg_temp.como(:cliA);
do $$
declare p1 public.pedidos; p2 public.pedidos; s int;
begin
  p1 := public.confirmar_pedido('10000000-0000-0000-0000-000000000001',
        '[{"producto_id":"20000000-0000-0000-0000-000000000002","cantidad":2}]', 'QR_SIMULADO', 'k1');
  p2 := public.confirmar_pedido('10000000-0000-0000-0000-000000000001',
        '[{"producto_id":"20000000-0000-0000-0000-000000000002","cantidad":2}]', 'QR_SIMULADO', 'k1');
  if p1.id <> p2.id then raise exception 'FAIL idempotencia: dos pedidos para la misma clave'; end if;
  select stock into s from public.productos where id = '20000000-0000-0000-0000-000000000002';
  if s <> 12 then raise exception 'FAIL stock tras confirmar: esperado 12, obtenido %', s; end if;
  if p1.total <> 240 or p1.estado <> 'CONFIRMED' or p1.estado_pago <> 'PENDING' then raise exception 'FAIL datos del pedido'; end if;
  insert into ctx values ('pedido', p1.id);
  raise notice 'PASS T-CHECKOUT confirmar: % total %, stock 14→12', p1.codigo, p1.total;
  raise notice 'PASS T-CHECKOUT idempotencia: la misma clave devuelve el mismo pedido y descuenta stock una vez';
end $$;

-- T-RLS · acceso directo prohibido ---------------------------------------------
do $$
begin
  begin
    insert into public.pedidos (cliente_id, comercio_id, metodo_pago, total, clave_idempotencia, vence_en)
    values (auth.uid(), '10000000-0000-0000-0000-000000000001', 'EFECTIVO', 1, 'x', now());
    raise exception 'FAIL el cliente insertó un pedido directo';
  exception when insufficient_privilege then raise notice 'PASS T-RLS inserción directa de pedidos rechazada';
  end;
  if exists (select 1 from public.credenciales_retiro) then raise exception 'FAIL el cliente ve el PIN antes de READY'; end if;
  raise notice 'PASS T-RET el cliente no ve su PIN antes de «Listo para retiro»';
  -- F14: el rol no es una columna editable por el usuario (permisos de columna).
  begin
    update public.perfiles set rol = 'ADMIN' where id = auth.uid();
    raise exception 'FAIL el cliente pudo escribir su rol';
  exception when insufficient_privilege then null;
  end;
  if public.rol_actual() <> 'CLIENTE' then raise exception 'FAIL el cliente se elevó de rol'; end if;
  raise notice 'PASS T-RLS el cliente no puede cambiar su propio rol';
end $$;

-- T-RLS · otro cliente y otro comercio -----------------------------------------
reset role;
select pg_temp.como(:cliB);
do $$
begin
  if exists (select 1 from public.pedidos where id = (select v::uuid from ctx where k = 'pedido')) then raise exception 'FAIL cliente B ve el pedido de A'; end if;
  if exists (select 1 from public.pedido_lineas) then raise exception 'FAIL cliente B ve líneas ajenas'; end if;
  raise notice 'PASS T-RLS cliente B no ve pedidos ni líneas de cliente A';
end $$;

reset role;
select pg_temp.como(:bout);
do $$
declare n int;
begin
  if exists (select 1 from public.pedidos) then raise exception 'FAIL Boutique ve pedidos de TechZone'; end if;
  begin
    perform public.avanzar_pedido((select v::uuid from ctx where k = 'pedido'));
    raise exception 'FAIL Boutique avanzó un pedido ajeno';
  exception when insufficient_privilege then null;
  end;
  update public.productos set precio = 1 where comercio_id = '10000000-0000-0000-0000-000000000001';
  get diagnostics n = row_count;
  if n <> 0 then raise exception 'FAIL Boutique modificó productos de TechZone'; end if;
  if public.confirmar_entrega((select v::uuid from ctx where k = 'pedido'), '000000') <> 'ajeno' then raise exception 'FAIL Boutique entregó un retiro ajeno'; end if;
  raise notice 'PASS T-RLS Boutique no ve, no avanza, no valida pedidos de TechZone ni edita sus productos';
end $$;

-- T-RET · preparación, PIN y pago ------------------------------------------------
reset role;
select pg_temp.como(:tech);
do $$
declare p public.pedidos;
begin
  p := public.avanzar_pedido((select v::uuid from ctx where k = 'pedido'));
  p := public.avanzar_pedido(p.id);
  if p.estado <> 'READY_FOR_PICKUP' then raise exception 'FAIL estado tras avanzar: %', p.estado; end if;
  if exists (select 1 from public.credenciales_retiro) then raise exception 'FAIL el comercio puede leer el PIN'; end if;
  raise notice 'PASS T-RET TechZone avanza CONFIRMED→IN_PREPARATION→READY y no puede leer el PIN';
end $$;

reset role;
select pg_temp.como(:cliA);
do $$
declare pin text;
begin
  select c.pin into pin from public.credenciales_retiro c where c.pedido_id = (select v::uuid from ctx where k = 'pedido');
  if pin is null then raise exception 'FAIL el cliente no ve su PIN en READY'; end if;
  insert into ctx values ('pin', pin);
  raise notice 'PASS T-RET el cliente ve su PIN en READY';
end $$;

reset role;
select pg_temp.como(:tech);
do $$
declare id uuid := (select v::uuid from ctx where k = 'pedido'); pin text := (select v from ctx where k = 'pin');
begin
  if pin <> '999999' and public.verificar_retiro('999999', id)->>'resultado' <> 'pin-incorrecto' then raise exception 'FAIL PIN incorrecto aceptado'; end if;
  if public.verificar_retiro(pin, id)->>'resultado' <> 'ok' or not (public.verificar_retiro(pin, id)->>'pago_pendiente')::boolean then raise exception 'FAIL verificar no avisa el pago pendiente'; end if;
  if public.confirmar_entrega(id, pin) <> 'pago-pendiente' then raise exception 'FAIL se entregó con el pago pendiente'; end if;
  raise notice 'PASS T-RET PIN incorrecto rechazado; verificar avisa el pago pendiente y no se entrega';
end $$;

reset role;
select pg_temp.como(:cliA);
do $$
declare p public.pedidos;
begin
  p := public.simular_pago((select v::uuid from ctx where k = 'pedido'));
  if p.estado_pago <> 'PAID' then raise exception 'FAIL simular pago'; end if;
  raise notice 'PASS DEC-04 «Simular pago» deja el pago QR en PAID';
end $$;

reset role;
select pg_temp.como(:tech);
do $$
declare id uuid := (select v::uuid from ctx where k = 'pedido'); pin text := (select v from ctx where k = 'pin');
begin
  -- DEC-F14-14: verificar no consume; el QR del ticket y el PIN suelto encuentran el mismo pedido.
  if public.verificar_retiro('paseoya:retiro:' || id || ':' || pin)->>'pedido_id' <> id::text then raise exception 'FAIL el QR no identifica el pedido'; end if;
  if public.verificar_retiro(pin)->>'pedido_id' <> id::text then raise exception 'FAIL el PIN manual no encuentra el pedido'; end if;
  if (select p.estado from public.pedidos p join ctx on ctx.k = 'pedido' and p.id = ctx.v::uuid) <> 'READY_FOR_PICKUP' then raise exception 'FAIL verificar cambió el pedido'; end if;
  if public.confirmar_entrega(id, 'paseoya:retiro:' || id || ':' || pin) <> 'ok' then raise exception 'FAIL entrega correcta rechazada'; end if;
  if public.confirmar_entrega(id, pin) <> 'usado' then raise exception 'FAIL el código se pudo reutilizar'; end if;
  if public.verificar_retiro(pin, id)->>'resultado' <> 'usado' then raise exception 'FAIL verificar no detecta el código usado'; end if;
  raise notice 'PASS T-RET verificar (QR o PIN) no consume; confirmar entrega consume y no se reutiliza';
end $$;

-- T-CAN · cancelación ------------------------------------------------------------
reset role;
select pg_temp.como(:cliA);
do $$
declare p public.pedidos; s int;
begin
  p := public.confirmar_pedido('10000000-0000-0000-0000-000000000002',
       '[{"producto_id":"20000000-0000-0000-0000-000000000005","cantidad":1}]', 'EFECTIVO', 'k2');
  p := public.cancelar_pedido(p.id);
  select stock into s from public.productos where id = '20000000-0000-0000-0000-000000000005';
  if p.estado <> 'CANCELLED' or s <> 3 then raise exception 'FAIL cancelar: estado % stock %', p.estado, s; end if;
  begin
    perform public.cancelar_pedido(p.id);
    raise exception 'FAIL se canceló dos veces';
  exception when raise_exception then
    if sqlerrm like 'FAIL%' then raise; end if;
  end;
  select stock into s from public.productos where id = '20000000-0000-0000-0000-000000000005';
  if s <> 3 then raise exception 'FAIL doble liberación de stock: %', s; end if;
  raise notice 'PASS T-CAN cancelar en CONFIRMED libera el stock una sola vez';
end $$;

-- T-STOCK · última unidad (secuencial; la prueba concurrente está en concurrencia.sh) -
do $$
declare s int;
begin
  perform public.confirmar_pedido('10000000-0000-0000-0000-000000000001',
          '[{"producto_id":"20000000-0000-0000-0000-000000000001","cantidad":1}]', 'EFECTIVO', 'k3');
end $$;
reset role;
select pg_temp.como(:cliB);
do $$
declare s int;
begin
  begin
    perform public.confirmar_pedido('10000000-0000-0000-0000-000000000001',
            '[{"producto_id":"20000000-0000-0000-0000-000000000001","cantidad":1}]', 'EFECTIVO', 'k4');
    raise exception 'FAIL se vendió una unidad inexistente';
  exception when sqlstate 'P0002' then null;
  end;
  select stock into s from public.productos where id = '20000000-0000-0000-0000-000000000001';
  if s <> 0 then raise exception 'FAIL stock final de la última unidad: %', s; end if;
  raise notice 'PASS T-STOCK la segunda compra de la última unidad se rechaza y el stock no queda negativo';
end $$;

-- Comercio cerrado y anon ----------------------------------------------------------
do $$
begin
  begin
    perform public.confirmar_pedido('10000000-0000-0000-0000-000000000003',
            '[{"producto_id":"20000000-0000-0000-0000-000000000007","cantidad":1}]', 'EFECTIVO', 'k5');
    raise exception 'FAIL se compró en un comercio cerrado';
  exception when sqlstate 'P0001' then null;
  end;
  raise notice 'PASS comercio cerrado rechaza pedidos';
end $$;

reset role;
select set_config('role', 'anon', true);
do $$
begin
  begin
    perform public.confirmar_pedido('10000000-0000-0000-0000-000000000001', '[]', 'EFECTIVO', 'anon');
    raise exception 'FAIL anon ejecutó confirmar_pedido';
  exception when insufficient_privilege then raise notice 'PASS T-RLS anon no puede ejecutar funciones de pedidos';
  end;
end $$;

-- T-EXP · expiración por tiempo corrido y reejecución --------------------------------
reset role;
do $$
declare n int; p public.pedidos; s int;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', '00000000-0000-0000-0000-0000000000a2', 'role', 'authenticated')::text, true);
  p := public.confirmar_pedido('10000000-0000-0000-0000-000000000002',
       '[{"producto_id":"20000000-0000-0000-0000-000000000006","cantidad":2}]', 'QR_SIMULADO', 'k6');
  update public.pedidos set estado_pago = 'PAID', vence_en = now() - interval '1 minute' where id = p.id;
  n := public.expirar_pedidos();
  select * into p from public.pedidos where id = p.id;
  select stock into s from public.productos where id = '20000000-0000-0000-0000-000000000006';
  if p.estado <> 'EXPIRED' or p.estado_pago <> 'RETAINED' or s <> 9 then raise exception 'FAIL expirar: % % stock %', p.estado, p.estado_pago, s; end if;
  if public.expirar_pedidos() <> 0 then raise exception 'FAIL la reejecución volvió a expirar'; end if;
  select stock into s from public.productos where id = '20000000-0000-0000-0000-000000000006';
  if s <> 9 then raise exception 'FAIL doble liberación al reejecutar: %', s; end if;
  raise notice 'PASS T-EXP vence por tiempo, QR pagado queda RETAINED (DEC-07), libera stock y se puede reejecutar sin doble efecto';
end $$;

-- F14 · lote Cliente -------------------------------------------------------------
reset role;
-- Repone stock como administrador de la base (el cliente no puede, por RLS).
update public.productos set stock = 5 where id = '20000000-0000-0000-0000-000000000001';
select pg_temp.como(:cliA);
do $$
declare p public.pedidos; n int; precio numeric;
begin
  -- Promoción aprobada del 40 % sobre Audífonos (Bs 300): el servidor cobra Bs 180.
  p := public.confirmar_pedido('10000000-0000-0000-0000-000000000001',
       '[{"producto_id":"20000000-0000-0000-0000-000000000001","cantidad":1}]', 'QR_SIMULADO', 'f14-promo');
  if p.total <> 180 then raise exception 'FAIL precio con promoción: %', p.total; end if;
  select precio_unitario into precio from public.pedido_lineas where pedido_id = p.id;
  if precio <> 180 then raise exception 'FAIL precio congelado en la línea: %', precio; end if;
  insert into ctx values ('pedido_f14', p.id);
  raise notice 'PASS F14 promoción aprobada aplicada y congelada en el pedido (Bs 300 → 180)';

  -- La promoción pendiente (Polera 10 %) no la ve el cliente.
  if exists (select 1 from public.promociones where estado <> 'APROBADA') then raise exception 'FAIL el cliente ve promociones no aprobadas'; end if;
  raise notice 'PASS F14 el cliente sólo ve promociones aprobadas y vigentes';

  -- Notificación automática del alta.
  select count(*) into n from public.notificaciones where pedido_id = p.id;
  if n <> 1 then raise exception 'FAIL notificación del alta: %', n; end if;
  raise notice 'PASS F14 el alta del pedido genera una notificación para su cliente';

  -- Favoritos y perfil propios.
  insert into public.favoritos (producto_id) values ('20000000-0000-0000-0000-00000000000c');
  update public.perfiles set telefono = '+591 71111111' where id = auth.uid();
  if (select telefono from public.perfiles where id = auth.uid()) <> '+591 71111111' then raise exception 'FAIL editar teléfono propio'; end if;
  raise notice 'PASS F14 el cliente guarda favoritos y edita su teléfono';
end $$;

reset role;
select pg_temp.como(:cliB);
do $$
begin
  if exists (select 1 from public.favoritos where usuario_id <> auth.uid()) then raise exception 'FAIL cliente B ve favoritos de A'; end if;
  if exists (select 1 from public.notificaciones where usuario_id <> auth.uid()) then raise exception 'FAIL cliente B ve notificaciones de A'; end if;
  if exists (select 1 from public.perfiles where id <> auth.uid()) then raise exception 'FAIL cliente B ve perfiles ajenos'; end if;
  raise notice 'PASS F14 favoritos, notificaciones y perfiles son privados de cada cliente';
end $$;

reset role;
select pg_temp.como(:tech);
do $$
declare id uuid := (select v::uuid from ctx where k = 'pedido_f14'); tel text; pm public.promociones;
begin
  select telefono into tel from public.contacto_cliente(id);
  if tel is distinct from '+591 71111111' then raise exception 'FAIL el comercio no ve el teléfono del pedido activo: %', tel; end if;
  -- Una promoción creada por el comercio queda pendiente aunque pida APROBADA.
  insert into public.promociones (producto_id, porcentaje, fin, estado)
  values ('20000000-0000-0000-0000-000000000002', 15, now() + interval '7 days', 'APROBADA') returning * into pm;
  if pm.estado <> 'PENDIENTE' or pm.comercio_id <> '10000000-0000-0000-0000-000000000001' then raise exception 'FAIL promoción del comercio: % %', pm.estado, pm.comercio_id; end if;
  if public.precio_vigente('20000000-0000-0000-0000-000000000002') <> 120 then raise exception 'FAIL una promoción pendiente cambió el precio'; end if;
  raise notice 'PASS F14 teléfono visible al comercio en pedido activo; su promoción queda PENDIENTE y no altera el precio';
end $$;

reset role;
select pg_temp.como(:bout);
do $$
begin
  if exists (select 1 from public.contacto_cliente((select v::uuid from ctx where k = 'pedido_f14'))) then raise exception 'FAIL otro comercio ve el contacto del cliente'; end if;
  begin
    insert into public.promociones (producto_id, porcentaje, fin) values ('20000000-0000-0000-0000-000000000002', 20, now() + interval '7 days');
    raise exception 'FAIL Fashion creó promoción sobre producto de TechStore';
  exception when insufficient_privilege then null;
  end;
  raise notice 'PASS F14 otro comercio no ve el contacto ni crea promociones sobre productos ajenos';
end $$;

-- F14 · Comercio ------------------------------------------------------------------
reset role;
select pg_temp.como(:tech);
do $$
declare n int; v_id uuid;
begin
  update public.comercios set descripcion = 'Nueva descripción', horario = 'Lun a vie · 9:00 a 20:00', abierto = false where id = '10000000-0000-0000-0000-000000000001';
  get diagnostics n = row_count;
  if n <> 1 then raise exception 'FAIL TechStore no pudo editar sus campos'; end if;
  begin
    update public.comercios set nombre = 'Otro nombre' where id = '10000000-0000-0000-0000-000000000001';
    raise exception 'FAIL TechStore cambió su nombre (campo del admin)';
  exception when insufficient_privilege then null;
  end;
  update public.comercios set descripcion = 'x' where id = '10000000-0000-0000-0000-000000000002';
  get diagnostics n = row_count;
  if n <> 0 then raise exception 'FAIL TechStore editó otro comercio'; end if;
  begin
    delete from public.productos where id = (select producto_id from public.pedido_lineas where pedido_id = (select v::uuid from ctx where k = 'pedido') limit 1);
    raise exception 'FAIL se eliminó un producto con pedidos';
  exception when foreign_key_violation then null;
  end;
  insert into public.productos (comercio_id, nombre, precio, stock) values ('10000000-0000-0000-0000-000000000001', 'Producto temporal', 10, 1) returning id into v_id;
  delete from public.productos where id = v_id;
  get diagnostics n = row_count;
  if n <> 1 then raise exception 'FAIL no se pudo eliminar un producto sin pedidos'; end if;
  if not exists (select 1 from public.notificaciones where pedido_id = (select v::uuid from ctx where k = 'pedido') and titulo in ('Nueva compra', 'Nueva reserva')) then
    raise exception 'FAIL el comercio no recibió el aviso de pedido nuevo';
  end if;
  if public.verificar_retiro('hola')->>'resultado' <> 'codigo-invalido' then raise exception 'FAIL código inválido aceptado'; end if;
  raise notice 'PASS F14 comercio edita sólo descripción/horario/abierto, elimina sólo productos sin pedidos y recibe avisos';
end $$;

reset role;
select pg_temp.como(:bout);
do $$
begin
  if public.verificar_retiro('paseoya:retiro:' || (select v from ctx where k = 'pedido') || ':123456')->>'resultado' <> 'ajeno' then raise exception 'FAIL Fashion verificó el QR de TechStore'; end if;
  if exists (select 1 from public.notificaciones where pedido_id = (select v::uuid from ctx where k = 'pedido')) then raise exception 'FAIL Fashion ve avisos de TechStore'; end if;
  raise notice 'PASS F14 otro comercio no verifica el QR ni ve los avisos ajenos';
end $$;

reset role;
select pg_temp.como(:cliA);
do $$
begin
  if public.verificar_retiro((select v from ctx where k = 'pin'))->>'resultado' <> 'ajeno' then raise exception 'FAIL un cliente usó verificar_retiro'; end if;
  raise notice 'PASS F14 sólo el comercio puede verificar retiros';
end $$;

-- F14 · Administrador -------------------------------------------------------------
reset role;
select pg_temp.como(:tech);
do $$
begin
  insert into public.promociones (producto_id, porcentaje, fin) values ('20000000-0000-0000-0000-000000000002', 12, now() + interval '5 days');
  raise notice 'PASS F14 admin: TechStore propone una promoción (queda PENDIENTE)';
end $$;

reset role;
select pg_temp.como(:admin);
do $$
declare v_promo uuid; v_comercio uuid; n int;
begin
  if not exists (select 1 from public.notificaciones where titulo = 'Promoción por revisar') then raise exception 'FAIL el admin no recibió la promoción por revisar'; end if;
  select id into v_promo from public.promociones where estado = 'PENDIENTE' and porcentaje = 12;
  update public.promociones set estado = 'APROBADA' where id = v_promo;
  if (select estado from public.promociones where id = v_promo) <> 'APROBADA' then raise exception 'FAIL el admin no pudo aprobar'; end if;
  insert into public.promociones (producto_id, porcentaje, fin, estado) values ('20000000-0000-0000-0000-000000000003', 20, now() + interval '3 days', 'APROBADA') returning id into v_promo;
  if (select estado from public.promociones where id = v_promo) <> 'APROBADA' then raise exception 'FAIL la promoción del admin no quedó aprobada'; end if;

  update public.productos set activo = false where id = '20000000-0000-0000-0000-000000000003';
  get diagnostics n = row_count;
  if n <> 1 then raise exception 'FAIL el admin no pudo desactivar un producto'; end if;
  begin
    update public.productos set precio = 1 where id = '20000000-0000-0000-0000-000000000003';
    raise exception 'FAIL el admin cambió un precio';
  exception when insufficient_privilege then null;
  end;
  begin
    insert into public.productos (comercio_id, nombre, precio, stock) values ('10000000-0000-0000-0000-000000000001', 'X', 1, 1);
    raise exception 'FAIL el admin creó un producto';
  exception when insufficient_privilege then null;
  end;
  begin
    perform public.avanzar_pedido((select v::uuid from ctx where k = 'pedido'));
    raise exception 'FAIL el admin avanzó un pedido';
  exception when insufficient_privilege then null;
  end;

  v_comercio := public.crear_comercio('Librería Central', '30000000-0000-0000-0000-000000000004', 'Piso 1', 'Local 140', 'libreria@paseoya.demo', 'clave-segura-1');
  if not exists (select 1 from public.listar_usuarios() u where u.email = 'libreria@paseoya.demo' and u.rol = 'COMERCIO' and u.comercio_id = v_comercio) then
    raise exception 'FAIL crear_comercio no dejó la cuenta COMERCIO enlazada';
  end if;
  begin
    perform public.crear_comercio('Otra', '30000000-0000-0000-0000-000000000004', 'Piso 1', 'Local 141', 'libreria@paseoya.demo', 'clave-segura-1');
    raise exception 'FAIL se repitió el correo de un comercio';
  exception when unique_violation then null;
  end;

  perform public.cambiar_estado_usuario('00000000-0000-0000-0000-0000000000a2', false);
  if (select activo from public.perfiles where id = '00000000-0000-0000-0000-0000000000a2') then
    raise exception 'FAIL desactivar no bloqueó al usuario';
  end if;
  begin
    perform public.cambiar_estado_usuario(auth.uid(), false);
    raise exception 'FAIL el admin se desactivó a sí mismo';
  exception when raise_exception then null;
  end;
  if (select count(*) from public.listar_usuarios() where email like '%@paseoya.demo') < 7 then raise exception 'FAIL listar_usuarios incompleto'; end if;
  if (select count(*) from public.auditoria_admin) < 5 then raise exception 'FAIL faltan registros de auditoría'; end if;
  raise notice 'PASS F14 admin aprueba promociones, sólo activa productos, crea comercios con cuenta, desactiva usuarios y queda auditado';
end $$;

reset role;
do $$
begin
  if (select banned_until from auth.users where id = '00000000-0000-0000-0000-0000000000a2') is null then raise exception 'FAIL el usuario desactivado puede iniciar sesión'; end if;
  if not exists (select 1 from auth.identities i join auth.users u on u.id = i.user_id where u.email = 'libreria@paseoya.demo') then raise exception 'FAIL la cuenta del comercio no tiene identidad de correo'; end if;
  raise notice 'PASS F14 el usuario desactivado queda bloqueado en Auth y la cuenta nueva tiene identidad';
end $$;

select pg_temp.como(:bout);
do $$
begin
  begin
    perform public.listar_usuarios();
    raise exception 'FAIL un comercio listó usuarios';
  exception when insufficient_privilege then null;
  end;
  if exists (select 1 from public.auditoria_admin) then raise exception 'FAIL un comercio ve la auditoría'; end if;
  raise notice 'PASS F14 sólo el admin lista usuarios y ve la auditoría';
end $$;

reset role;
select pg_temp.como(:tech);
do $$
begin
  if not exists (select 1 from public.notificaciones where titulo = 'Promoción aprobada') then raise exception 'FAIL TechStore no recibió el aviso de aprobación'; end if;
  raise notice 'PASS F14 el comercio recibe el aviso de promoción aprobada';
end $$;

-- DEC-24 · Eliminación de cuenta y retención -------------------------------------
reset role;
select pg_temp.como(:cliA);
do $$
begin
  perform public.confirmar_pedido('10000000-0000-0000-0000-000000000004', '[{"producto_id":"20000000-0000-0000-0000-00000000000e","cantidad":1}]', 'EFECTIVO', 'dec24-activo');
  begin
    perform public.eliminar_cuenta();
    raise exception 'FAIL se eliminó una cuenta con pedidos en curso';
  exception when sqlstate 'P0003' then null;
  end;
  begin
    perform public.eliminar_cuenta('00000000-0000-0000-0000-0000000000a2');
    raise exception 'FAIL un cliente eliminó otra cuenta';
  exception when insufficient_privilege then null;
  end;
  begin
    perform public.purgar_datos_operativos();
    raise exception 'FAIL un cliente ejecutó la purga';
  exception when insufficient_privilege then null;
  end;
  raise notice 'PASS DEC-24 no se elimina con pedidos en curso, ni una cuenta ajena, ni se purga desde la app';
end $$;

reset role;
select pg_temp.como(:tech);
do $$
begin
  begin
    perform public.eliminar_cuenta();
    raise exception 'FAIL se eliminó una cuenta de comercio';
  exception when sqlstate 'P0001' then null;
  end;
  raise notice 'PASS DEC-24 las cuentas de comercio no se eliminan (se desactivan)';
end $$;

reset role;
select pg_temp.como(:cliB);
do $$
begin
  insert into public.favoritos (producto_id) values ('20000000-0000-0000-0000-000000000002');
  perform public.eliminar_cuenta();
  raise notice 'PASS DEC-24 el cliente elimina su propia cuenta';
end $$;

reset role;
do $$
declare v jsonb;
begin
  if not exists (select 1 from public.perfiles where id = '00000000-0000-0000-0000-0000000000a2' and nombre = 'Cliente eliminado'
                 and telefono is null and genero is null and fecha_nacimiento is null and avatar_path is null and eliminado_en is not null) then
    raise exception 'FAIL el perfil no quedó anonimizado';
  end if;
  if (select email from auth.users where id = '00000000-0000-0000-0000-0000000000a2') not like 'eliminado-%@paseoya.invalid'
     or exists (select 1 from auth.identities where user_id = '00000000-0000-0000-0000-0000000000a2')
     or exists (select 1 from public.favoritos where usuario_id = '00000000-0000-0000-0000-0000000000a2') then
    raise exception 'FAIL quedaron datos de la cuenta eliminada';
  end if;
  insert into public.notificaciones (usuario_id, tipo, titulo, cuerpo, creado_en) values ('00000000-0000-0000-0000-0000000000a1', 'pedido', 'viejo', 'viejo', now() - interval '91 days');
  insert into public.notificaciones (usuario_id, tipo, titulo, cuerpo) values ('00000000-0000-0000-0000-0000000000a1', 'pedido', 'reciente', 'reciente');
  insert into public.reportes (cliente_id, mensaje, creado_en) values ('00000000-0000-0000-0000-0000000000a1', 'reporte antiguo', now() - interval '13 months');
  v := public.purgar_datos_operativos();
  if (v->>'avisos')::int < 1 or (v->>'reportes')::int < 1 or exists (select 1 from public.notificaciones where titulo = 'viejo')
     or not exists (select 1 from public.notificaciones where titulo = 'reciente') then
    raise exception 'FAIL la purga no respeta los plazos: %', v;
  end if;
  if not exists (select 1 from cron.job where jobname = 'purgar-datos-operativos') then raise exception 'FAIL falta la tarea programada de purga'; end if;
  raise notice 'PASS DEC-24 la cuenta queda anonimizada y la purga borra avisos de más de 90 días y reportes de más de 12 meses';
end $$;

reset role;
do $$
begin
  if public.formato_bs(180) <> 'Bs 180,00' or public.formato_bs(3200.5) <> 'Bs 3.200,50' then raise exception 'FAIL formato_bs no usa el formato es-BO de la app'; end if;
  raise notice 'PASS F14 montos de notificaciones con formato es-BO (Bs 3.200,50)';
end $$;

rollback;
\echo 'Todas las pruebas terminaron sin fallos (transacción revertida).'
