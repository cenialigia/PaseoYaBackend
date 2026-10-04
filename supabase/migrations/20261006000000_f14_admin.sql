-- F14 · Lote Administrador (DEC-F14-06/11): comercios con cuenta propia, usuarios activos/inactivos,
-- productos sólo activar/desactivar, aprobación de promociones y auditoría de cada acción del admin.

-- Auditoría ------------------------------------------------------------------------
create table public.auditoria_admin (
  id bigint generated always as identity primary key,
  admin_id uuid not null references public.perfiles (id),
  tabla text not null,
  accion text not null,
  registro_id uuid,
  cambios jsonb not null default '{}'::jsonb,
  creado_en timestamptz not null default now()
);
create index on public.auditoria_admin (creado_en desc);
alter table public.auditoria_admin enable row level security;
-- Sólo lectura para el admin; las filas las escribe el disparador (sin políticas de escritura).
create policy auditoria_lectura on public.auditoria_admin for select to authenticated using (public.rol_actual() = 'ADMIN');

-- Registra sólo lo que hace un ADMIN con sesión (el seed y las funciones del sistema no tienen auth.uid()).
create function public.auditar_admin() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_nuevo jsonb := case when tg_op = 'DELETE' then null else to_jsonb(new) end;
        v_viejo jsonb := case when tg_op = 'INSERT' then null else to_jsonb(old) end;
        v_cambios jsonb;
begin
  if auth.uid() is null or public.rol_actual() is distinct from 'ADMIN' then return coalesce(new, old); end if;
  if tg_op = 'UPDATE' then
    select coalesce(jsonb_object_agg(k, v_nuevo -> k), '{}'::jsonb) into v_cambios
    from jsonb_object_keys(v_nuevo) k where v_nuevo -> k is distinct from v_viejo -> k;
    if v_cambios = '{}'::jsonb then return new; end if;
  else
    v_cambios := coalesce(v_nuevo, v_viejo);
  end if;
  insert into public.auditoria_admin (admin_id, tabla, accion, registro_id, cambios)
  values (auth.uid(), tg_table_name, tg_op, (coalesce(v_nuevo, v_viejo) ->> 'id')::uuid, v_cambios);
  return coalesce(new, old);
end;
$$;

create trigger auditar after insert or update or delete on public.comercios for each row execute function public.auditar_admin();
create trigger auditar after insert or update or delete on public.categorias for each row execute function public.auditar_admin();
create trigger auditar after insert or update or delete on public.promociones for each row execute function public.auditar_admin();
create trigger auditar after insert or update or delete on public.productos for each row execute function public.auditar_admin();
create trigger auditar after update on public.perfiles for each row execute function public.auditar_admin();

-- Productos: el admin sólo activa o desactiva (PDF ADM-08/09); crear, borrar o tocar precio/stock es del comercio.
create function public.proteger_producto_admin() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or public.rol_actual() is distinct from 'ADMIN' then return coalesce(new, old); end if;
  if tg_op <> 'UPDATE'
     or (new.id, new.comercio_id, new.nombre, new.precio, new.precio_anterior, new.stock, new.descripcion, new.imagen_path)
        is distinct from (old.id, old.comercio_id, old.nombre, old.precio, old.precio_anterior, old.stock, old.descripcion, old.imagen_path) then
    raise exception 'La administración sólo puede activar o desactivar productos' using errcode = '42501';
  end if;
  return new;
end;
$$;
create trigger al_cambiar_producto_admin before insert or update or delete on public.productos
  for each row execute function public.proteger_producto_admin();

-- Usuarios -------------------------------------------------------------------------
alter table public.perfiles add column activo boolean not null default true;

-- Lista para el admin con el correo (vive en auth.users, fuera del alcance de la API).
create function public.listar_usuarios()
returns table (id uuid, nombre text, email text, rol public.rol_usuario, comercio_id uuid, comercio text, activo boolean,
               telefono text, creado_en timestamptz, ultimo_acceso timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if public.rol_actual() is distinct from 'ADMIN' then raise exception 'Sólo la administración' using errcode = '42501'; end if;
  return query
    select p.id, p.nombre, u.email::text, p.rol, p.comercio_id, c.nombre, p.activo, p.telefono, p.creado_en, u.last_sign_in_at
    from public.perfiles p
    join auth.users u on u.id = p.id
    left join public.comercios c on c.id = p.comercio_id
    order by p.creado_en desc;
end;
$$;

-- Desactivar bloquea el inicio de sesión (banned_until); la sesión abierta caduca con su token.
create function public.cambiar_estado_usuario(p_usuario uuid, p_activo boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if public.rol_actual() is distinct from 'ADMIN' then raise exception 'Sólo la administración' using errcode = '42501'; end if;
  if p_usuario = auth.uid() then raise exception 'No puedes desactivar tu propia cuenta' using errcode = 'P0001'; end if;
  update public.perfiles set activo = p_activo where id = p_usuario;
  if not found then raise exception 'Usuario no encontrado' using errcode = 'P0002'; end if;
  -- Fecha lejana en lugar de 'infinity': GoTrue no sabe leer infinity y respondería con error 500.
  update auth.users set banned_until = case when p_activo then null else now() + interval '100 years' end where id = p_usuario;
end;
$$;

-- Comercios: alta con su cuenta única (DEC-F14-06) ---------------------------------
create function public.crear_comercio(p_nombre text, p_categoria uuid, p_piso text, p_local text, p_email text, p_password text)
returns uuid
language plpgsql security definer set search_path = public, extensions as $$
declare v_comercio uuid; v_usuario uuid := gen_random_uuid(); v_email text := lower(trim(p_email));
begin
  if public.rol_actual() is distinct from 'ADMIN' then raise exception 'Sólo la administración' using errcode = '42501'; end if;
  if v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' or length(coalesce(p_password, '')) < 8 then
    raise exception 'Correo o contraseña inválidos' using errcode = '22023';
  end if;
  if exists (select 1 from auth.users where email = v_email) then raise exception 'Ya existe una cuenta con ese correo' using errcode = '23505'; end if;

  insert into public.comercios (nombre, categoria_id, piso, local, abierto)
  values (trim(p_nombre), p_categoria, trim(p_piso), trim(p_local), false)
  returning id into v_comercio;

  -- Misma forma que el seed: usuario confirmado con contraseña; el disparador crea su perfil CLIENTE.
  insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at, confirmation_token, recovery_token, email_change_token_new, email_change)
  values ('00000000-0000-0000-0000-000000000000', v_usuario, 'authenticated', 'authenticated', v_email,
    crypt(p_password, gen_salt('bf')), now(), '{"provider":"email","providers":["email"]}', jsonb_build_object('nombre', trim(p_nombre)),
    now(), now(), '', '', '', '');
  insert into auth.identities (id, user_id, provider_id, provider, identity_data, last_sign_in_at, created_at, updated_at)
  values (gen_random_uuid(), v_usuario, v_usuario::text, 'email',
    jsonb_build_object('sub', v_usuario::text, 'email', v_email, 'email_verified', true), null, now(), now());

  update public.perfiles set rol = 'COMERCIO', comercio_id = v_comercio where id = v_usuario;
  return v_comercio;
end;
$$;

-- Promociones: avisos de revisión ---------------------------------------------------
create function public.notificar_promocion() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_producto text; v_comercio text;
begin
  select pr.nombre, c.nombre into v_producto, v_comercio
  from public.productos pr join public.comercios c on c.id = pr.comercio_id where pr.id = new.producto_id;
  if tg_op = 'INSERT' and new.estado = 'PENDIENTE' then
    insert into public.notificaciones (usuario_id, tipo, titulo, cuerpo)
    select id, 'promocion', 'Promoción por revisar', v_comercio || ' propone ' || new.porcentaje || '% en ' || v_producto || '.'
    from public.perfiles where rol = 'ADMIN' and activo;
  elsif tg_op = 'UPDATE' and new.estado is distinct from old.estado and new.estado in ('APROBADA', 'RECHAZADA') then
    insert into public.notificaciones (usuario_id, tipo, titulo, cuerpo)
    select id, 'promocion',
      case when new.estado = 'APROBADA' then 'Promoción aprobada' else 'Promoción rechazada' end,
      'El ' || new.porcentaje || '% en ' || v_producto
        || case when new.estado = 'APROBADA' then ' ya es visible para los clientes.' else ' no fue aprobado por la administración.' end
    from public.perfiles where comercio_id = new.comercio_id and rol = 'COMERCIO';
  end if;
  return new;
end;
$$;
create trigger al_revisar_promocion after insert or update on public.promociones
  for each row execute function public.notificar_promocion();

revoke execute on function public.auditar_admin(), public.proteger_producto_admin(), public.notificar_promocion(),
  public.listar_usuarios(), public.cambiar_estado_usuario(uuid, boolean), public.crear_comercio(text, uuid, text, text, text, text) from public, anon;
grant execute on function public.listar_usuarios(), public.cambiar_estado_usuario(uuid, boolean),
  public.crear_comercio(text, uuid, text, text, text, text) to authenticated;
