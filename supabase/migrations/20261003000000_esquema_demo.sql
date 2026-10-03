-- PaseoYA · esquema de la demo (BE-01/03/04 mínimo). Decisiones: Core ADR-011.
-- Toda escritura sensible pasa por funciones SECURITY DEFINER; las tablas sólo exponen lectura vía RLS.

create extension if not exists pgcrypto with schema extensions;

-- Tipos ----------------------------------------------------------------------
create type public.rol_usuario as enum ('CLIENTE', 'COMERCIO', 'ADMIN');
create type public.estado_pedido as enum ('CONFIRMED', 'IN_PREPARATION', 'READY_FOR_PICKUP', 'DELIVERED', 'CANCELLED', 'EXPIRED');
create type public.metodo_pago as enum ('QR_SIMULADO', 'EFECTIVO');
-- DEC-07: un QR simulado pagado y vencido queda retenido por el comercio.
create type public.estado_pago as enum ('PENDING', 'PAID', 'REFUNDED', 'RETAINED');

-- Tablas ---------------------------------------------------------------------
create table public.comercios (
  id uuid primary key default gen_random_uuid(),
  nombre text not null check (length(trim(nombre)) > 1),
  local text not null,
  piso text not null,
  categoria text not null,
  abierto boolean not null default true,
  activo boolean not null default true,
  creado_en timestamptz not null default now()
);

-- DEC-10: un solo rol por usuario; COMERCIO ligado a exactamente un comercio y un comercio con una sola cuenta.
create table public.perfiles (
  id uuid primary key references auth.users (id) on delete cascade,
  nombre text not null,
  rol public.rol_usuario not null default 'CLIENTE',
  comercio_id uuid references public.comercios (id),
  creado_en timestamptz not null default now(),
  constraint comercio_solo_para_rol_comercio check ((rol = 'COMERCIO') = (comercio_id is not null))
);
create unique index una_cuenta_por_comercio on public.perfiles (comercio_id) where rol = 'COMERCIO';

create table public.productos (
  id uuid primary key default gen_random_uuid(),
  comercio_id uuid not null references public.comercios (id),
  nombre text not null,
  precio numeric(10, 2) not null check (precio > 0),
  precio_anterior numeric(10, 2) check (precio_anterior is null or precio_anterior > precio),
  stock integer not null check (stock >= 0),
  activo boolean not null default true
);
create index on public.productos (comercio_id);

create sequence public.pedido_numero start 1004;

create table public.pedidos (
  id uuid primary key default gen_random_uuid(),
  codigo text not null unique default ('PY-' || nextval('public.pedido_numero')),
  cliente_id uuid not null references public.perfiles (id),
  comercio_id uuid not null references public.comercios (id),
  estado public.estado_pedido not null default 'CONFIRMED',
  metodo_pago public.metodo_pago not null,
  estado_pago public.estado_pago not null default 'PENDING',
  total numeric(10, 2) not null check (total > 0),
  clave_idempotencia text not null,
  confirmado_en timestamptz not null default now(),
  -- DEC-06: tiempo corrido desde la confirmación (72 h efectivo, 14 días QR).
  vence_en timestamptz not null,
  actualizado_en timestamptz not null default now(),
  unique (cliente_id, clave_idempotencia)
);
create index on public.pedidos (cliente_id);
create index on public.pedidos (comercio_id, estado);

create table public.pedido_lineas (
  pedido_id uuid not null references public.pedidos (id) on delete cascade,
  producto_id uuid not null references public.productos (id),
  cantidad integer not null check (cantidad > 0),
  precio_unitario numeric(10, 2) not null,
  primary key (pedido_id, producto_id)
);

-- DEC-16: credencial de un solo uso, separada para que el comercio no pueda leer el PIN.
create table public.credenciales_retiro (
  pedido_id uuid primary key references public.pedidos (id) on delete cascade,
  pin text not null check (pin ~ '^[0-9]{6}$'),
  usado_en timestamptz
);

create table public.reportes (
  id uuid primary key default gen_random_uuid(),
  cliente_id uuid not null references public.perfiles (id),
  pedido_id uuid references public.pedidos (id),
  mensaje text not null check (length(trim(mensaje)) >= 5),
  creado_en timestamptz not null default now()
);

-- Ayudantes de autorización -----------------------------------------------------
create function public.rol_actual() returns public.rol_usuario
language sql stable security definer set search_path = public as $$
  select rol from public.perfiles where id = auth.uid()
$$;

create function public.comercio_actual() returns uuid
language sql stable security definer set search_path = public as $$
  select comercio_id from public.perfiles where id = auth.uid() and rol = 'COMERCIO'
$$;

-- DEC-10: el registro libre siempre crea CLIENTE; los metadatos del cliente no pueden elevar el rol.
create function public.crear_perfil_cliente() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.perfiles (id, nombre, rol)
  values (new.id, coalesce(nullif(trim(new.raw_user_meta_data ->> 'nombre'), ''), split_part(new.email, '@', 1)), 'CLIENTE');
  return new;
end;
$$;
create trigger al_crear_usuario after insert on auth.users for each row execute function public.crear_perfil_cliente();

-- RLS --------------------------------------------------------------------------
alter table public.comercios enable row level security;
alter table public.perfiles enable row level security;
alter table public.productos enable row level security;
alter table public.pedidos enable row level security;
alter table public.pedido_lineas enable row level security;
alter table public.credenciales_retiro enable row level security;
alter table public.reportes enable row level security;

create policy comercios_lectura on public.comercios for select to authenticated
  using (activo or public.rol_actual() = 'ADMIN' or id = public.comercio_actual());
create policy comercios_admin on public.comercios for all to authenticated
  using (public.rol_actual() = 'ADMIN') with check (public.rol_actual() = 'ADMIN');

create policy perfiles_propio_o_admin on public.perfiles for select to authenticated
  using (id = auth.uid() or public.rol_actual() = 'ADMIN');
create policy perfiles_admin on public.perfiles for update to authenticated
  using (public.rol_actual() = 'ADMIN') with check (public.rol_actual() = 'ADMIN');

create policy productos_lectura on public.productos for select to authenticated
  using (activo or comercio_id = public.comercio_actual() or public.rol_actual() = 'ADMIN');
create policy productos_gestion on public.productos for all to authenticated
  using (comercio_id = public.comercio_actual() or public.rol_actual() = 'ADMIN')
  with check (comercio_id = public.comercio_actual() or public.rol_actual() = 'ADMIN');

-- Pedidos: sólo lectura directa; altas y transiciones únicamente por funciones.
create policy pedidos_lectura on public.pedidos for select to authenticated
  using (cliente_id = auth.uid() or comercio_id = public.comercio_actual() or public.rol_actual() = 'ADMIN');

create policy lineas_lectura on public.pedido_lineas for select to authenticated
  using (exists (select 1 from public.pedidos p where p.id = pedido_id
    and (p.cliente_id = auth.uid() or p.comercio_id = public.comercio_actual() or public.rol_actual() = 'ADMIN')));

-- Sólo el cliente dueño ve su PIN, y sólo cuando el pedido está listo.
create policy credencial_cliente_listo on public.credenciales_retiro for select to authenticated
  using (exists (select 1 from public.pedidos p where p.id = pedido_id and p.cliente_id = auth.uid() and p.estado = 'READY_FOR_PICKUP'));

create policy reportes_cliente_alta on public.reportes for insert to authenticated
  with check (cliente_id = auth.uid() and public.rol_actual() = 'CLIENTE');
create policy reportes_lectura on public.reportes for select to authenticated
  using (cliente_id = auth.uid() or public.rol_actual() = 'ADMIN');

-- Funciones confiables -------------------------------------------------------
-- BE-03 · checkout de un comercio: idempotente, stock atómico al confirmar (DEC-05).
create function public.confirmar_pedido(p_comercio_id uuid, p_lineas jsonb, p_metodo public.metodo_pago, p_clave text)
returns public.pedidos
language plpgsql security definer set search_path = public as $$
declare
  v_pedido public.pedidos;
  v_linea record;
  v_total numeric(10, 2) := 0;
begin
  if public.rol_actual() is distinct from 'CLIENTE' then
    raise exception 'Sólo un cliente puede confirmar pedidos' using errcode = '42501';
  end if;

  select * into v_pedido from public.pedidos where cliente_id = auth.uid() and clave_idempotencia = p_clave;
  if found then
    return v_pedido;
  end if;

  if not exists (select 1 from public.comercios where id = p_comercio_id and activo and abierto) then
    raise exception 'El comercio no está disponible' using errcode = 'P0001';
  end if;
  if jsonb_typeof(p_lineas) <> 'array' or jsonb_array_length(p_lineas) = 0 then
    raise exception 'El pedido no tiene productos' using errcode = '22023';
  end if;

  -- Bloqueo en orden estable para evitar interbloqueos y sobreventa concurrente (RN-09).
  for v_linea in
    select pr.id, pr.precio, pr.stock, (l ->> 'cantidad')::int as cantidad
    from jsonb_array_elements(p_lineas) l
    join public.productos pr on pr.id = (l ->> 'producto_id')::uuid
    where pr.comercio_id = p_comercio_id and pr.activo
    order by pr.id
    for update of pr
  loop
    if v_linea.cantidad is null or v_linea.cantidad <= 0 then
      raise exception 'Cantidad inválida' using errcode = '22023';
    end if;
    if v_linea.stock < v_linea.cantidad then
      raise exception 'Stock insuficiente' using errcode = 'P0002';
    end if;
    v_total := v_total + v_linea.precio * v_linea.cantidad;
  end loop;

  if (select count(*) from jsonb_array_elements(p_lineas) l join public.productos pr on pr.id = (l ->> 'producto_id')::uuid
      where pr.comercio_id = p_comercio_id and pr.activo) <> jsonb_array_length(p_lineas) then
    raise exception 'Hay productos que no pertenecen al comercio o no están activos' using errcode = '22023';
  end if;

  insert into public.pedidos (cliente_id, comercio_id, metodo_pago, total, clave_idempotencia, vence_en)
  values (auth.uid(), p_comercio_id, p_metodo, v_total, p_clave,
          now() + case when p_metodo = 'EFECTIVO' then interval '72 hours' else interval '14 days' end)
  returning * into v_pedido;

  insert into public.pedido_lineas (pedido_id, producto_id, cantidad, precio_unitario)
  select v_pedido.id, pr.id, (l ->> 'cantidad')::int, pr.precio
  from jsonb_array_elements(p_lineas) l join public.productos pr on pr.id = (l ->> 'producto_id')::uuid;

  update public.productos pr set stock = pr.stock - (l ->> 'cantidad')::int
  from jsonb_array_elements(p_lineas) l where pr.id = (l ->> 'producto_id')::uuid;

  insert into public.credenciales_retiro (pedido_id, pin)
  values (v_pedido.id, lpad((floor(random() * 1000000))::int::text, 6, '0'));

  return v_pedido;
end;
$$;

-- DEC-04: pago QR simulado; no mueve dinero.
create function public.simular_pago(p_pedido uuid) returns public.pedidos
language plpgsql security definer set search_path = public as $$
declare v public.pedidos;
begin
  update public.pedidos set estado_pago = 'PAID', actualizado_en = now()
  where id = p_pedido and cliente_id = auth.uid() and metodo_pago = 'QR_SIMULADO' and estado_pago = 'PENDING'
    and estado not in ('CANCELLED', 'EXPIRED', 'DELIVERED')
  returning * into v;
  if not found then raise exception 'No se puede simular el pago de este pedido' using errcode = 'P0001'; end if;
  return v;
end;
$$;

create function public.liberar_stock(p_pedido uuid) returns void
language sql security definer set search_path = public as $$
  update public.productos pr set stock = pr.stock + pl.cantidad
  from public.pedido_lineas pl where pl.pedido_id = p_pedido and pr.id = pl.producto_id
$$;

-- DEC-08: el cliente cancela sólo en CONFIRMED; libera stock una vez; QR pagado → reembolso simulado.
create function public.cancelar_pedido(p_pedido uuid) returns public.pedidos
language plpgsql security definer set search_path = public as $$
declare v public.pedidos;
begin
  update public.pedidos
  set estado = 'CANCELLED',
      estado_pago = case when estado_pago = 'PAID' and metodo_pago = 'QR_SIMULADO' then 'REFUNDED'::public.estado_pago else estado_pago end,
      actualizado_en = now()
  where id = p_pedido and estado = 'CONFIRMED' and (cliente_id = auth.uid() or public.rol_actual() = 'ADMIN')
  returning * into v;
  if not found then raise exception 'El pedido no se puede cancelar' using errcode = 'P0001'; end if;
  perform public.liberar_stock(p_pedido);
  return v;
end;
$$;

-- BE-04 · transiciones del comercio dueño.
create function public.avanzar_pedido(p_pedido uuid) returns public.pedidos
language plpgsql security definer set search_path = public as $$
declare v public.pedidos;
begin
  update public.pedidos
  set estado = case estado when 'CONFIRMED' then 'IN_PREPARATION'::public.estado_pedido else 'READY_FOR_PICKUP'::public.estado_pedido end,
      actualizado_en = now()
  where id = p_pedido and comercio_id = public.comercio_actual() and estado in ('CONFIRMED', 'IN_PREPARATION')
  returning * into v;
  if not found then raise exception 'Transición no permitida' using errcode = '42501'; end if;
  return v;
end;
$$;

create function public.confirmar_efectivo(p_pedido uuid) returns public.pedidos
language plpgsql security definer set search_path = public as $$
declare v public.pedidos;
begin
  update public.pedidos set estado_pago = 'PAID', actualizado_en = now()
  where id = p_pedido and comercio_id = public.comercio_actual() and metodo_pago = 'EFECTIVO'
    and estado_pago = 'PENDING' and estado = 'READY_FOR_PICKUP'
  returning * into v;
  if not found then raise exception 'No se puede confirmar el efectivo' using errcode = 'P0001'; end if;
  return v;
end;
$$;

-- DEC-16: valida el PIN una sola vez, sólo el comercio dueño, sólo en READY y con el pago hecho.
create function public.validar_retiro(p_pedido uuid, p_pin text) returns text
language plpgsql security definer set search_path = public as $$
declare v public.pedidos; c public.credenciales_retiro;
begin
  select * into v from public.pedidos where id = p_pedido for update;
  if not found or v.comercio_id is distinct from public.comercio_actual() then return 'ajeno'; end if;
  if v.estado <> 'READY_FOR_PICKUP' then return 'no-listo'; end if;
  select * into c from public.credenciales_retiro where pedido_id = p_pedido for update;
  if c.usado_en is not null then return 'no-listo'; end if;
  if c.pin <> trim(p_pin) then return 'pin-incorrecto'; end if;
  if v.estado_pago <> 'PAID' then return 'pago-pendiente'; end if;
  update public.credenciales_retiro set usado_en = now() where pedido_id = p_pedido;
  update public.pedidos set estado = 'DELIVERED', actualizado_en = now() where id = p_pedido;
  return 'ok';
end;
$$;

-- DEC-06/07: expira por tiempo corrido; reejecutable sin doble efecto. Se programa con pg_cron fuera de la demo.
create function public.expirar_pedidos() returns integer
language plpgsql security definer set search_path = public as $$
declare v_id uuid; n integer := 0;
begin
  for v_id in
    select id from public.pedidos
    where vence_en <= now() and estado in ('CONFIRMED', 'IN_PREPARATION', 'READY_FOR_PICKUP')
    for update skip locked
  loop
    update public.pedidos
    set estado = 'EXPIRED',
        estado_pago = case when estado_pago = 'PAID' and metodo_pago = 'QR_SIMULADO' then 'RETAINED'::public.estado_pago else estado_pago end,
        actualizado_en = now()
    where id = v_id;
    perform public.liberar_stock(v_id);
    n := n + 1;
  end loop;
  return n;
end;
$$;

-- Permisos de ejecución: nada para anon; las funciones validan rol internamente.
revoke execute on all functions in schema public from public, anon;
grant execute on function public.confirmar_pedido(uuid, jsonb, public.metodo_pago, text), public.simular_pago(uuid),
  public.cancelar_pedido(uuid), public.avanzar_pedido(uuid), public.confirmar_efectivo(uuid),
  public.validar_retiro(uuid, text), public.rol_actual(), public.comercio_actual() to authenticated;
-- liberar_stock y expirar_pedidos quedan sólo para el servidor (service_role / pg_cron).
revoke execute on function public.liberar_stock(uuid), public.expirar_pedidos() from authenticated;
