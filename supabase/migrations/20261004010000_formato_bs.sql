-- Montos en notificaciones con el mismo formato que la app (es-BO): «Bs 3.200,00».
create function public.formato_bs(p numeric) returns text
language sql immutable set search_path = public as $$
  select 'Bs ' || translate(to_char(p, 'FM999G999G990D00'), ',.', '.,');
$$;

create or replace function public.notificar_pedido() returns trigger
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
    v_cuerpo := 'Tu pago simulado de ' || public.formato_bs(new.total) || ' para ' || new.codigo || ' fue aprobado.';
  end if;
  if v_titulo is not null then
    insert into public.notificaciones (usuario_id, pedido_id, tipo, titulo, cuerpo) values (new.cliente_id, new.id, v_tipo, v_titulo, v_cuerpo);
  end if;
  return new;
end;
$$;

do $$
begin
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'notificaciones') then
    alter publication supabase_realtime add table public.notificaciones;
  end if;
end;
$$;
