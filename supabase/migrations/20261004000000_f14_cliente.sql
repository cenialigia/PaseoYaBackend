-- PaseoYA · F14 lote Cliente. Decisiones: Core «Decisiones F14 antes de iniciar» (DEC-F14-05/08/11/15/16) y ADR-012.

-- Perfil ampliado (DEC-F14-08) -------------------------------------------------
create type public.genero as enum ('FEMENINO', 'MASCULINO', 'OTRO', 'PREFIERO_NO_DECIR');

alter table public.perfiles
  add column telefono text check (telefono is null or telefono ~ '^\+?[0-9 ]{7,16}$'),
  add column genero public.genero,
  add column fecha_nacimiento date check (fecha_nacimiento is null or fecha_nacimiento >= date '1900-01-01'),
  add column avatar_path text;

-- El usuario edita sólo sus datos personales; rol y comercio_id quedan fuera de su alcance por permisos de columna.
revoke update on public.perfiles from authenticated;
grant update (nombre, telefono, genero, fecha_nacimiento, avatar_path) on public.perfiles to authenticated;
create policy perfiles_editar_propio on public.perfiles for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());

-- El registro libre sigue creando siempre CLIENTE; los datos inválidos de metadatos se descartan en vez de romper el alta.
create or replace function public.crear_perfil_cliente() returns trigger
language plpgsql security definer set search_path = public as $$
declare m jsonb := coalesce(new.raw_user_meta_data, '{}'::jsonb);
begin
  insert into public.perfiles (id, nombre, rol, telefono, genero, fecha_nacimiento)
  values (
    new.id,
    coalesce(nullif(trim(m ->> 'nombre'), ''), split_part(new.email, '@', 1)),
    'CLIENTE',
    case when m ->> 'telefono' ~ '^\+?[0-9 ]{7,16}$' then m ->> 'telefono' end,
    case when m ->> 'genero' in ('FEMENINO', 'MASCULINO', 'OTRO', 'PREFIERO_NO_DECIR') then (m ->> 'genero')::public.genero end,
    case when m ->> 'fecha_nacimiento' ~ '^\d{4}-\d{2}-\d{2}$' then (m ->> 'fecha_nacimiento')::date end
  );
  return new;
end;
$$;

-- DEC-F14-08: el comercio dueño ve nombre y teléfono del cliente sólo mientras el pedido está activo.
create function public.contacto_cliente(p_pedido uuid) returns table (nombre text, telefono text)
language sql stable security definer set search_path = public as $$
  select pf.nombre, pf.telefono
  from public.pedidos p join public.perfiles pf on pf.id = p.cliente_id
  where p.id = p_pedido and p.comercio_id = public.comercio_actual()
    and p.estado in ('CONFIRMED', 'IN_PREPARATION', 'READY_FOR_PICKUP')
$$;

-- Categorías de comercio (DEC-F14-15) ------------------------------------------
create table public.categorias (
  id uuid primary key default gen_random_uuid(),
  nombre text not null unique check (length(trim(nombre)) > 1),
  icono text not null default 'storefront',
  orden integer not null default 0,
  activa boolean not null default true
);
alter table public.categorias enable row level security;
create policy categorias_lectura on public.categorias for select to authenticated using (activa or public.rol_actual() = 'ADMIN');
create policy categorias_admin on public.categorias for all to authenticated
  using (public.rol_actual() = 'ADMIN') with check (public.rol_actual() = 'ADMIN');

alter table public.comercios add column categoria_id uuid references public.categorias (id);
-- Migra la categoría de texto existente (vacía en un reset local; útil en una base con datos).
insert into public.categorias (nombre) select distinct categoria from public.comercios on conflict (nombre) do nothing;
update public.comercios c set categoria_id = k.id from public.categorias k where k.nombre = c.categoria;
alter table public.comercios alter column categoria_id set not null;
alter table public.comercios drop column categoria;
alter table public.comercios add column imagen_path text, add column descripcion text;
alter table public.productos add column imagen_path text, add column descripcion text;

-- Promociones % con aprobación (DEC-F14-11) ------------------------------------
create type public.estado_promocion as enum ('PENDIENTE', 'APROBADA', 'RECHAZADA', 'PAUSADA');

create table public.promociones (
  id uuid primary key default gen_random_uuid(),
  producto_id uuid not null references public.productos (id) on delete cascade,
  comercio_id uuid not null references public.comercios (id),
  porcentaje integer not null check (porcentaje between 1 and 90),
  inicio timestamptz not null default now(),
  fin timestamptz not null,
  estado public.estado_promocion not null default 'PENDIENTE',
  creada_por uuid references public.perfiles (id) default auth.uid(),
  creado_en timestamptz not null default now(),
  check (fin > inicio)
);
create index on public.promociones (producto_id, estado);

-- El comercio de la promoción es siempre el del producto; lo que crea o edita un comercio vuelve a PENDIENTE.
create function public.normalizar_promocion() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  select comercio_id into new.comercio_id from public.productos where id = new.producto_id;
  -- auth.uid() identifica a quien hace la petición (en SECURITY DEFINER current_user es el propietario); sin JWT es el seed.
  if auth.uid() is not null and public.rol_actual() is distinct from 'ADMIN' then
    if tg_op = 'INSERT' or new.estado is distinct from 'PAUSADA' then
      new.estado := 'PENDIENTE';
    end if;
  end if;
  return new;
end;
$$;
create trigger al_guardar_promocion before insert or update on public.promociones
  for each row execute function public.normalizar_promocion();

alter table public.promociones enable row level security;
create policy promociones_lectura on public.promociones for select to authenticated
  using ((estado = 'APROBADA' and now() between inicio and fin) or comercio_id = public.comercio_actual() or public.rol_actual() = 'ADMIN');
create policy promociones_gestion on public.promociones for all to authenticated
  using (comercio_id = public.comercio_actual() or public.rol_actual() = 'ADMIN')
  with check (comercio_id = public.comercio_actual() or public.rol_actual() = 'ADMIN');

-- Precio que cobra el servidor: base con la mayor promoción aprobada y vigente.
create function public.precio_vigente(p_producto uuid) returns numeric
language sql stable security definer set search_path = public as $$
  select round(pr.precio * (100 - coalesce(max(pm.porcentaje), 0)) / 100.0, 2)
  from public.productos pr
  left join public.promociones pm on pm.producto_id = pr.id and pm.estado = 'APROBADA' and now() between pm.inicio and pm.fin
  where pr.id = p_producto
  group by pr.precio
$$;

-- confirmar_pedido: igual que BE-03, pero congela el precio vigente (con promoción) en el pedido.
create or replace function public.confirmar_pedido(p_comercio_id uuid, p_lineas jsonb, p_metodo public.metodo_pago, p_clave text)
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

  for v_linea in
    select pr.id, pr.stock, (l ->> 'cantidad')::int as cantidad
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
    v_total := v_total + public.precio_vigente(v_linea.id) * v_linea.cantidad;
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
  select v_pedido.id, pr.id, (l ->> 'cantidad')::int, public.precio_vigente(pr.id)
  from jsonb_array_elements(p_lineas) l join public.productos pr on pr.id = (l ->> 'producto_id')::uuid;

  update public.productos pr set stock = pr.stock - (l ->> 'cantidad')::int
  from jsonb_array_elements(p_lineas) l where pr.id = (l ->> 'producto_id')::uuid;

  insert into public.credenciales_retiro (pedido_id, pin)
  values (v_pedido.id, lpad((floor(random() * 1000000))::int::text, 6, '0'));

  return v_pedido;
end;
$$;

-- «Más pedidos» de Inicio: sólo conteos agregados, sin datos de clientes.
create function public.productos_mas_pedidos(p_limite integer default 6) returns table (producto_id uuid, veces bigint)
language sql stable security definer set search_path = public as $$
  select pl.producto_id, sum(pl.cantidad)::bigint
  from public.pedido_lineas pl
  join public.pedidos p on p.id = pl.pedido_id and p.estado not in ('CANCELLED', 'EXPIRED')
  join public.productos pr on pr.id = pl.producto_id and pr.activo
  group by pl.producto_id
  order by 2 desc
  limit least(greatest(p_limite, 1), 20)
$$;

-- Favoritos (DEC-F14-05) --------------------------------------------------------
create table public.favoritos (
  usuario_id uuid not null default auth.uid() references public.perfiles (id) on delete cascade,
  producto_id uuid not null references public.productos (id) on delete cascade,
  creado_en timestamptz not null default now(),
  primary key (usuario_id, producto_id)
);
alter table public.favoritos enable row level security;
create policy favoritos_propios on public.favoritos for all to authenticated
  using (usuario_id = auth.uid()) with check (usuario_id = auth.uid());

-- Notificaciones (DEC-F14-05, reabre la campana de DEC-20) -----------------------
create table public.notificaciones (
  id uuid primary key default gen_random_uuid(),
  usuario_id uuid not null references public.perfiles (id) on delete cascade,
  pedido_id uuid references public.pedidos (id) on delete cascade,
  tipo text not null,
  titulo text not null,
  cuerpo text not null,
  leida boolean not null default false,
  creado_en timestamptz not null default now()
);
create index on public.notificaciones (usuario_id, creado_en desc);
alter table public.notificaciones enable row level security;
create policy notificaciones_lectura on public.notificaciones for select to authenticated using (usuario_id = auth.uid());
create policy notificaciones_marcar on public.notificaciones for update to authenticated
  using (usuario_id = auth.uid()) with check (usuario_id = auth.uid());
revoke update on public.notificaciones from authenticated;
grant update (leida) on public.notificaciones to authenticated;

-- Avisos al cliente cuando cambia su pedido; los genera el servidor, nunca la app.
create function public.notificar_pedido() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_comercio text; v_titulo text; v_cuerpo text; v_tipo text;
begin
  select nombre into v_comercio from public.comercios where id = new.comercio_id;
  if tg_op = 'INSERT' then
    v_tipo := 'pedido';
    v_titulo := case when new.metodo_pago = 'EFECTIVO' then 'Reserva confirmada' else 'Compra registrada' end;
    v_cuerpo := 'Tu pedido ' || new.codigo || ' en ' || v_comercio || ' fue registrado.';
  elsif new.estado is distinct from old.estado then
    v_tipo := 'pedido';
    v_titulo := case new.estado
      when 'IN_PREPARATION' then 'Tu pedido está en preparación'
      when 'READY_FOR_PICKUP' then 'Tu pedido está listo'
      when 'DELIVERED' then 'Pedido entregado'
      when 'CANCELLED' then 'Pedido cancelado'
      when 'EXPIRED' then 'Pedido vencido'
      else null end;
    v_cuerpo := case new.estado
      when 'READY_FOR_PICKUP' then 'Muestra tu código de recojo en ' || v_comercio || '. Pedido ' || new.codigo || '.'
      else 'Pedido ' || new.codigo || ' en ' || v_comercio || '.' end;
  elsif new.estado_pago is distinct from old.estado_pago and new.estado_pago = 'PAID' and new.metodo_pago = 'QR_SIMULADO' then
    v_tipo := 'pago';
    v_titulo := 'Pago confirmado';
    v_cuerpo := 'Tu pago simulado de Bs ' || to_char(new.total, 'FM999990.00') || ' para ' || new.codigo || ' fue aprobado.';
  end if;
  if v_titulo is not null then
    insert into public.notificaciones (usuario_id, pedido_id, tipo, titulo, cuerpo) values (new.cliente_id, new.id, v_tipo, v_titulo, v_cuerpo);
  end if;
  return new;
end;
$$;
create trigger al_cambiar_pedido after insert or update of estado, estado_pago on public.pedidos
  for each row execute function public.notificar_pedido();

do $$
begin
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'notificaciones') then
    alter publication supabase_realtime add table public.notificaciones;
  end if;
end;
$$;

-- Storage (DEC-F14-16) ----------------------------------------------------------
insert into storage.buckets (id, name, public) values ('avatares', 'avatares', false), ('imagenes', 'imagenes', true)
on conflict (id) do nothing;

-- Avatares privados: cada usuario sólo su carpeta <uid>/.
create policy avatares_propios on storage.objects for all to authenticated
  using (bucket_id = 'avatares' and (storage.foldername(name))[1] = auth.uid()::text)
  with check (bucket_id = 'avatares' and (storage.foldername(name))[1] = auth.uid()::text);

-- Imágenes públicas de tiendas/productos: escribe el comercio en <comercio_id>/ o el admin.
create policy imagenes_escritura on storage.objects for all to authenticated
  using (bucket_id = 'imagenes' and ((storage.foldername(name))[1] = public.comercio_actual()::text or public.rol_actual() = 'ADMIN'))
  with check (bucket_id = 'imagenes' and ((storage.foldername(name))[1] = public.comercio_actual()::text or public.rol_actual() = 'ADMIN'));

-- Permisos de ejecución de las funciones nuevas.
revoke execute on function public.contacto_cliente(uuid), public.precio_vigente(uuid), public.productos_mas_pedidos(integer),
  public.normalizar_promocion(), public.notificar_pedido() from public, anon;
grant execute on function public.contacto_cliente(uuid), public.precio_vigente(uuid), public.productos_mas_pedidos(integer) to authenticated;
