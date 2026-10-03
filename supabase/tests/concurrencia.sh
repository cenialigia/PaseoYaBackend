#!/usr/bin/env bash
# T-STOCK concurrente: dos clientes compran a la vez la última unidad; sólo una compra debe confirmarse.
# Requiere el stack local (`npm run db:start`). Deja la base como el seed al terminar (`npm run db:reset`).
set -euo pipefail
DB=supabase_db_paseoya
PRODUCTO=20000000-0000-0000-0000-000000000006
psql_db() { docker exec -i "$DB" psql -U postgres -d postgres -X -q -v ON_ERROR_STOP=1 "$@"; }

psql_db -c "update public.productos set stock = 1 where id = '$PRODUCTO';"

compra() {
  local cliente=$1 clave=$2
  psql_db <<SQL 2>&1 | grep -oE 'PY-[0-9]+|Stock insuficiente' || true
begin;
select set_config('request.jwt.claims', json_build_object('sub', '$cliente', 'role', 'authenticated')::text, true);
select set_config('role', 'authenticated', true);
select (public.confirmar_pedido('10000000-0000-0000-0000-000000000002',
        '[{"producto_id":"$PRODUCTO","cantidad":1}]', 'EFECTIVO', '$clave')).codigo;
-- Mantiene el bloqueo de fila para que la otra compra llegue mientras tanto.
select pg_sleep(2);
commit;
SQL
}

compra 00000000-0000-0000-0000-0000000000a1 conc-a > /tmp/conc_a.txt &
sleep 0.3
compra 00000000-0000-0000-0000-0000000000a2 conc-b > /tmp/conc_b.txt &
wait

A=$(cat /tmp/conc_a.txt); B=$(cat /tmp/conc_b.txt)
STOCK=$(psql_db -tAc "select stock from public.productos where id = '$PRODUCTO';")
OK=$(printf '%s\n%s\n' "$A" "$B" | grep -c '^PY-' || true)
echo "Compra A: $A | Compra B: $B | stock final: $STOCK"
if [ "$OK" = "1" ] && [ "$STOCK" = "0" ]; then
  echo "PASS T-STOCK concurrente: una compra confirmada, la otra rechazada, stock 0"
else
  echo "FAIL T-STOCK concurrente"; exit 1
fi
