-- F14 · Lote Comercio: edición del local (DEC-F14-07), retiro en dos pasos con QR o PIN (DEC-F14-13/14)
-- y avisos para el comercio (DEC-F14-05).

-- Establecimiento ------------------------------------------------------------------
alter table public.comercios add column horario text check (horario is null or length(horario) <= 120);

-- DEC-F14-07: el comercio edita descripción, horario, foto y abierto/cerrado; nombre, categoría, piso/local y estado son del admin.
create function public.proteger_comercio() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is not null and public.rol_actual() is distinct from 'ADMIN'
     and (new.id, new.nombre, new.categoria_id, new.piso, new.local, new.activo, new.creado_en)
         is distinct from (old.id, old.nombre, old.categoria_id, old.piso, old.local, old.activo, old.creado_en) then
    raise exception 'Sólo la administración cambia nombre, categoría, piso, local o estado del comercio' using errcode = '42501';
  end if;
  return new;
end;
$$;
create trigger al_editar_comercio before update on public.comercios
  for each row execute function public.proteger_comercio();

create policy comercios_editar_propio on public.comercios for update to authenticated
  using (id = public.comercio_actual()) with check (id = public.comercio_actual());

-- Retiro en dos pasos (DEC-F14-14) -------------------------------------------------
-- El QR del ticket lleva «paseoya:retiro:<pedido>:<pin>»; el PIN manual son 6 dígitos.
-- verificar_retiro no consume nada: sólo dice si se puede entregar y qué falta.
drop function public.validar_retiro(uuid, text);

create function public.verificar_retiro(p_codigo text, p_pedido uuid default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_codigo text := trim(coalesce(p_codigo, ''));
  v_id uuid := p_pedido;
  v_pin text;
  v_ids uuid[];
  v public.pedidos;
  c public.credenciales_retiro;
begin
  if public.rol_actual() is distinct from 'COMERCIO' then return jsonb_build_object('resultado', 'ajeno'); end if;
  if v_codigo ~ '^paseoya:retiro:[0-9a-f-]{36}:[0-9]{6}$' then
    v_id := split_part(v_codigo, ':', 3)::uuid;
    v_pin := split_part(v_codigo, ':', 4);
    if p_pedido is not null and p_pedido <> v_id then return jsonb_build_object('resultado', 'otro-pedido'); end if;
  elsif v_codigo ~ '^[0-9]{6}$' then
    v_pin := v_codigo;
    -- PIN sin pedido elegido: se busca entre los pedidos listos del propio comercio.
    if v_id is null then
      select array_agg(p.id) into v_ids
      from public.pedidos p join public.credenciales_retiro cr on cr.pedido_id = p.id
      where p.comercio_id = public.comercio_actual() and p.estado = 'READY_FOR_PICKUP' and cr.usado_en is null and cr.pin = v_pin;
      if coalesce(array_length(v_ids, 1), 0) <> 1 then return jsonb_build_object('resultado', 'pin-incorrecto'); end if;
      v_id := v_ids[1];
    end if;
  else
    return jsonb_build_object('resultado', 'codigo-invalido');
  end if;

  select * into v from public.pedidos where id = v_id;
  if not found or v.comercio_id is distinct from public.comercio_actual() then return jsonb_build_object('resultado', 'ajeno'); end if;
  select * into c from public.credenciales_retiro where pedido_id = v_id;
  if v.estado = 'DELIVERED' or c.usado_en is not null then return jsonb_build_object('resultado', 'usado', 'pedido_id', v.id); end if;
  if v.estado = 'EXPIRED' then return jsonb_build_object('resultado', 'vencido', 'pedido_id', v.id); end if;
  if v.estado = 'CANCELLED' then return jsonb_build_object('resultado', 'cancelado', 'pedido_id', v.id); end if;
  if v.estado <> 'READY_FOR_PICKUP' then return jsonb_build_object('resultado', 'no-listo', 'pedido_id', v.id); end if;
  if c.pin is distinct from v_pin then return jsonb_build_object('resultado', 'pin-incorrecto', 'pedido_id', v.id); end if;
  return jsonb_build_object('resultado', 'ok', 'pedido_id', v.id, 'pago_pendiente', v.estado_pago <> 'PAID');
end;
$$;

-- «Confirmar entrega»: vuelve a verificar con el pedido bloqueado y consume la credencial en la misma transacción.
create function public.confirmar_entrega(p_pedido uuid, p_codigo text) returns text
language plpgsql security definer set search_path = public as $$
declare r jsonb;
begin
  perform 1 from public.pedidos where id = p_pedido for update;
  r := public.verificar_retiro(p_codigo, p_pedido);
  if r->>'resultado' <> 'ok' then return r->>'resultado'; end if;
  if (r->>'pago_pendiente')::boolean then return 'pago-pendiente'; end if;
  update public.credenciales_retiro set usado_en = now() where pedido_id = p_pedido and usado_en is null;
  if not found then return 'usado'; end if;
  update public.pedidos set estado = 'DELIVERED', actualizado_en = now() where id = p_pedido;
  return 'ok';
end;
$$;

-- Avisos: el cliente como antes y, además, las cuentas del comercio (pedido nuevo, pago QR y cancelación del cliente).
create or replace function public.notificar_pedido() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_comercio text; v_titulo text; v_cuerpo text; v_tipo text; v_aviso_comercio text; v_cuerpo_comercio text;
begin
  select nombre into v_comercio from public.comercios where id = new.comercio_id;
  if tg_op = 'INSERT' then
    v_tipo := 'pedido';
    v_titulo := case when new.metodo_pago = 'EFECTIVO' then 'Reserva confirmada' else 'Compra registrada' end;
    v_cuerpo := 'Tu pedido ' || new.codigo || ' en ' || v_comercio || ' fue registrado.';
    v_aviso_comercio := case when new.metodo_pago = 'EFECTIVO' then 'Nueva reserva' else 'Nueva compra' end;
    v_cuerpo_comercio := 'Pedido ' || new.codigo || ' por ' || public.formato_bs(new.total)
      || case when new.metodo_pago = 'EFECTIVO' then ', se paga en efectivo al recoger.' else ', pago con QR simulado.' end;
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
    if new.estado = 'CANCELLED' then
      v_aviso_comercio := 'Pedido cancelado';
      v_cuerpo_comercio := 'El cliente canceló el pedido ' || new.codigo || '; el stock volvió a tu catálogo.';
    elsif new.estado = 'EXPIRED' then
      v_aviso_comercio := 'Pedido vencido';
      v_cuerpo_comercio := 'El pedido ' || new.codigo || ' venció sin retirarse.';
    end if;
  elsif new.estado_pago is distinct from old.estado_pago and new.estado_pago = 'PAID' and new.metodo_pago = 'QR_SIMULADO' then
    v_tipo := 'pago';
    v_titulo := 'Pago confirmado';
    v_cuerpo := 'Tu pago simulado de ' || public.formato_bs(new.total) || ' para ' || new.codigo || ' fue aprobado.';
    v_aviso_comercio := 'Pago QR recibido';
    v_cuerpo_comercio := 'El pedido ' || new.codigo || ' quedó pagado (' || public.formato_bs(new.total) || ', simulado).';
  end if;
  if v_titulo is not null then
    insert into public.notificaciones (usuario_id, pedido_id, tipo, titulo, cuerpo) values (new.cliente_id, new.id, v_tipo, v_titulo, v_cuerpo);
  end if;
  if v_aviso_comercio is not null then
    insert into public.notificaciones (usuario_id, pedido_id, tipo, titulo, cuerpo)
    select pf.id, new.id, v_tipo, v_aviso_comercio, v_cuerpo_comercio
    from public.perfiles pf where pf.comercio_id = new.comercio_id and pf.rol = 'COMERCIO';
  end if;
  return new;
end;
$$;

revoke execute on function public.verificar_retiro(text, uuid), public.confirmar_entrega(uuid, text), public.proteger_comercio() from public, anon;
grant execute on function public.verificar_retiro(text, uuid), public.confirmar_entrega(uuid, text) to authenticated;
