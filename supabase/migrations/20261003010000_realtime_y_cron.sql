-- PaseoYA · Realtime de pedidos y expiración programada.

-- Realtime: el cliente y el comercio reciben cambios de sus pedidos; Realtime aplica la RLS de lectura.
-- credenciales_retiro queda fuera: el PIN nunca se difunde.
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'pedidos'
  ) then
    alter publication supabase_realtime add table public.pedidos;
  end if;
end;
$$;

-- pg_cron: expirar_pedidos cada minuto; reejecutable sin doble efecto.
create extension if not exists pg_cron with schema pg_catalog;
-- cron.schedule con nombre reemplaza el job si ya existe.
select cron.schedule('expirar-pedidos', '* * * * *', 'select public.expirar_pedidos();');
