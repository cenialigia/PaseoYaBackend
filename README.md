# PaseoYA · Backend

Definición reproducible de **Supabase** para PaseoYA: migraciones SQL, RLS, seed sintético y operaciones confiables. No hay servidor Node adicional: Node sólo ejecuta la Supabase CLI (ADR-009).

La documentación vive en el Core, fuera de este repositorio: [cenialigia/documentacionPaseoYa](https://github.com/cenialigia/documentacionPaseoYa). El cliente está en [cenialigia/PaseoYaFrontend](https://github.com/cenialigia/PaseoYaFrontend).

## Requisitos

Node.js ≥ 22.13 y Docker Desktop **en ejecución**.

## Arranque local

```bash
npm install
npm run db:start    # supabase start: Postgres, Auth, API y Studio locales
npm run db:status   # URL y claves LOCALES para el .env del frontend
npm run db:reset    # aplica supabase/migrations y seed desde cero
npm run db:stop
```

No hay proyecto cloud conectado. No versionar `.env`, la `service_role` ni las claves de un proyecto remoto.

> Estado: F0-03 completo, sin esquema todavía. El esquema, Auth y RLS llegan en BE-01.
