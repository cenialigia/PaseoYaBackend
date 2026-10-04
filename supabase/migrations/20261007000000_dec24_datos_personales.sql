-- DEC-24 · Datos personales (respuesta del usuario, 2026-10-04):
-- eliminación a pedido con anonimización, avisos 90 días, reportes 12 meses; los pedidos se conservan sin datos personales.

alter table public.perfiles add column eliminado_en timestamptz;

-- El admin puede borrar la foto de una cuenta que elimina (la de la propia cuenta ya la cubre avatares_propios).
-- La foto se borra con la API de Storage: storage.objects no admite DELETE directo desde SQL.
create policy avatares_admin_borrar on storage.objects for delete to authenticated
  using (bucket_id = 'avatares' and public.rol_actual() = 'ADMIN');

-- Elimina la cuenta de un CLIENTE: la propia (sin argumento) o cualquiera si quien llama es ADMIN.
-- No se borra la fila de perfil ni el usuario de Auth porque los pedidos los referencian:
-- se anonimizan (nombre genérico, sin teléfono/género/nacimiento/foto, correo irrecuperable, sin identidad ni sesiones).
create function public.eliminar_cuenta(p_usuario uuid default null) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare v_id uuid := coalesce(p_usuario, auth.uid()); v_rol public.rol_usuario;
begin
  if auth.uid() is null then raise exception 'Sin sesión' using errcode = '42501'; end if;
  if v_id <> auth.uid() and public.rol_actual() is distinct from 'ADMIN' then
    raise exception 'Sólo puedes eliminar tu propia cuenta' using errcode = '42501';
  end if;
  select rol into v_rol from public.perfiles where id = v_id and eliminado_en is null;
  if not found then raise exception 'Cuenta no encontrada' using errcode = 'P0002'; end if;
  if v_rol <> 'CLIENTE' then raise exception 'Sólo se eliminan cuentas de cliente; los comercios se desactivan' using errcode = 'P0001'; end if;
  if exists (select 1 from public.pedidos where cliente_id = v_id and estado in ('CONFIRMED', 'IN_PREPARATION', 'READY_FOR_PICKUP')) then
    raise exception 'La cuenta tiene pedidos en curso' using errcode = 'P0003';
  end if;

  update public.perfiles
  set nombre = 'Cliente eliminado', telefono = null, genero = null, fecha_nacimiento = null, avatar_path = null,
      activo = false, eliminado_en = now()
  where id = v_id;
  delete from public.favoritos where usuario_id = v_id;
  delete from public.notificaciones where usuario_id = v_id;

  update auth.users
  set email = 'eliminado-' || v_id || '@paseoya.invalid', encrypted_password = crypt(gen_random_uuid()::text, gen_salt('bf')),
      raw_user_meta_data = '{}'::jsonb, phone = null, banned_until = now() + interval '100 years', updated_at = now()
  where id = v_id;
  delete from auth.identities where user_id = v_id;
  delete from auth.sessions where user_id = v_id;
end;
$$;

-- listar_usuarios ahora indica si la cuenta fue eliminada (anonimizada).
drop function public.listar_usuarios();
create function public.listar_usuarios()
returns table (id uuid, nombre text, email text, rol public.rol_usuario, comercio_id uuid, comercio text, activo boolean,
               telefono text, creado_en timestamptz, ultimo_acceso timestamptz, eliminado boolean)
language plpgsql stable security definer set search_path = public as $$
begin
  if public.rol_actual() is distinct from 'ADMIN' then raise exception 'Sólo la administración' using errcode = '42501'; end if;
  return query
    select p.id, p.nombre, u.email::text, p.rol, p.comercio_id, c.nombre, p.activo, p.telefono, p.creado_en, u.last_sign_in_at, p.eliminado_en is not null
    from public.perfiles p
    join auth.users u on u.id = p.id
    left join public.comercios c on c.id = p.comercio_id
    order by p.creado_en desc;
end;
$$;
revoke execute on function public.listar_usuarios() from public, anon;
grant execute on function public.listar_usuarios() to authenticated;

-- Retención de datos operativos: avisos 90 días y reportes 12 meses.
create function public.purgar_datos_operativos() returns jsonb
language plpgsql security definer set search_path = public as $$
declare n_avisos integer; n_reportes integer;
begin
  delete from public.notificaciones where creado_en < now() - interval '90 days';
  get diagnostics n_avisos = row_count;
  delete from public.reportes where creado_en < now() - interval '12 months';
  get diagnostics n_reportes = row_count;
  return jsonb_build_object('avisos', n_avisos, 'reportes', n_reportes);
end;
$$;

select cron.schedule('purgar-datos-operativos', '30 3 * * *', 'select public.purgar_datos_operativos();');

revoke execute on function public.eliminar_cuenta(uuid), public.purgar_datos_operativos() from public, anon;
grant execute on function public.eliminar_cuenta(uuid) to authenticated;
-- purgar_datos_operativos queda sólo para el servidor (pg_cron).
revoke execute on function public.purgar_datos_operativos() from authenticated;
