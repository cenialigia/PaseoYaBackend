-- F11 · RNF-06 Trazabilidad (historial de estados con fecha y autor) y DEC-F11-01 (rechazo del pedido por el comercio).
-- Responde quién hizo el pedido, qué comercio lo recibió, qué estados tuvo y cuándo se retiró o venció.

create table public.pedido_eventos (
  id bigint generated always as identity primary key,
  pedido_id uuid not null references public.pedidos (id) on delete cascade,
  estado public.estado_pedido not null,
  estado_pago public.estado_pago not null,
  -- Quién provocó el cambio; null = el sistema (vencimiento programado).
  actor_id uuid references public.perfiles (id),
  creado_en timestamptz not null default now()
);
create index on public.pedido_eventos (pedido_id, creado_en);

alter table public.pedido_eventos enable row level security;
-- Lo ve quien puede ver el pedido (cliente dueño, comercio del pedido o admin); sólo escribe el disparador.
create policy pedido_eventos_lectura on public.pedido_eventos for select to authenticated
  using (exists (select 1 from public.pedidos p where p.id = pedido_id
    and (p.cliente_id = auth.uid() or p.comercio_id = public.comercio_actual() or public.rol_actual() = 'ADMIN')));

create function public.registrar_evento_pedido() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' or new.estado is distinct from old.estado or new.estado_pago is distinct from old.estado_pago then
    insert into public.pedido_eventos (pedido_id, estado, estado_pago, actor_id)
    values (new.id, new.estado, new.estado_pago, (select id from public.perfiles where id = auth.uid()));
  end if;
  return new;
end;
$$;
create trigger al_cambiar_pedido_evento after insert or update on public.pedidos
  for each row execute function public.registrar_evento_pedido();

-- Pedidos anteriores a esta migración: un evento con su estado actual a la fecha de su última actualización.
insert into public.pedido_eventos (pedido_id, estado, estado_pago, actor_id, creado_en)
select p.id, p.estado, p.estado_pago, null, p.actualizado_en
from public.pedidos p
where not exists (select 1 from public.pedido_eventos e where e.pedido_id = p.id);

revoke execute on function public.registrar_evento_pedido() from public, anon, authenticated;

-- F11 · DEC-F11-01: el pedido sigue naciendo confirmado y el comercio puede rechazarlo antes de que esté listo.
alter table public.pedidos add column motivo_cancelacion text check (motivo_cancelacion is null or length(trim(motivo_cancelacion)) between 3 and 200);

create function public.rechazar_pedido(p_pedido uuid, p_motivo text) returns public.pedidos
language plpgsql security definer set search_path = public as $$
declare v public.pedidos;
begin
  if length(trim(coalesce(p_motivo, ''))) < 3 then raise exception 'Indica el motivo del rechazo' using errcode = '22023'; end if;
  update public.pedidos
  set estado = 'CANCELLED',
      estado_pago = case when estado_pago = 'PAID' and metodo_pago = 'QR_SIMULADO' then 'REFUNDED'::public.estado_pago else estado_pago end,
      motivo_cancelacion = trim(p_motivo),
      actualizado_en = now()
  where id = p_pedido and comercio_id = public.comercio_actual() and estado in ('CONFIRMED', 'IN_PREPARATION')
  returning * into v;
  if not found then raise exception 'El pedido no se puede rechazar' using errcode = '42501'; end if;
  perform public.liberar_stock(p_pedido);
  return v;
end;
$$;

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
    if new.estado = 'CANCELLED' and new.motivo_cancelacion is not null then
      -- DEC-F11-01: rechazo del comercio; avisa sólo al cliente, con el motivo.
      v_titulo := 'Pedido rechazado por la tienda';
      v_cuerpo := v_comercio || ' no pudo atender tu pedido ' || new.codigo || ': ' || new.motivo_cancelacion
        || case when new.estado_pago = 'REFUNDED' then '. Tu pago simulado fue reembolsado.' else '.' end;
    elsif new.estado = 'CANCELLED' then
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

revoke execute on function public.rechazar_pedido(uuid, text) from public, anon;
grant execute on function public.rechazar_pedido(uuid, text) to authenticated;
