# Supabase migration governance

Supabase schema and RPC changes for NdsApp are versioned under
`supabase/migrations`. The repository is the durable source of truth for the
database contract; the live Supabase project is authoritative only for current
operational state.

## Rules

1. Applied migration files are immutable. Fixes move forward in a new migration.
2. Never rely on Supabase platform default privileges for Data API access.
3. Every new `public` table must declare its access intent in the same migration
   with an object-specific `GRANT` or `REVOKE`.
4. If `anon` or `authenticated` receives direct table access, Row Level
   Security must be enabled in that migration. Policies still determine which
   rows are visible or writable.
5. Every new or replaced `public` function must explicitly declare function
   execution access with `GRANT EXECUTE` and/or `REVOKE`.
6. Server-only RPCs should normally revoke execution from `public`, `anon`
   and `authenticated`, then grant only the minimum role required, commonly
   `service_role`.
7. Internal tables used only behind owner/`SECURITY DEFINER` functions should
   explicitly revoke direct Data API access rather than depending on defaults.
8. Explicitly created `public` sequences must also declare their access intent.
   If a future Data API table needs client-side inserts that consume a sequence,
   grant only the sequence privileges required by that role; otherwise revoke
   direct sequence access.
9. Trigger functions, event-trigger functions and implementation-only helper
   functions in `public` are not API endpoints. Revoke direct `EXECUTE` from
   Data API roles even when PostgreSQL itself invokes them through a trigger.

The CI validator in `scripts/validate_supabase_migrations.py` enforces these
rules for newly added migrations and rejects edits/deletions of existing
migration files.

## October 2026 Data API default change

Supabase is removing automatic Data API grants for newly created objects in
existing projects. NdsApp deliberately does not depend on either the old or the
new platform default.

Migration
`20261020134000_supabase_data_api_explicit_privileges.sql` records the intended
production posture:

- future `public` tables do not receive automatic CRUD grants for
  `anon`, `authenticated` or `service_role`;
- future `public` functions do not receive automatic `EXECUTE`;
- future `public` sequences do not receive automatic usage/select privileges;
- current backend-facing RPCs are executable by `service_role` only;
- trigger/event-trigger and implementation-only helpers are not directly
  executable through the Data API.

Changing those defaults does not remove `USAGE` on the exposed `public`
schema and does not disable the Data API. NdsApp-LicensingApi intentionally uses
PostgREST RPC endpoints with its server-side service role, so the Data API must
remain available unless the backend architecture is changed explicitly.

## Historical production migration recovery

Production already contained migration
`20260903083200_harden_stripe_subscription_license_sync` while the file was
missing from GitHub. The repository copy is recovered from
`supabase_migrations.schema_migrations` in the live **BIM Nodes Licensing**
project.

That recovered file carries the marker
`nds-migration-governance: restored-applied-migration`. The validator accepts
that marker only for the explicitly allowlisted historical recovery; it is not
a general escape hatch for future migrations.

## Why this is explicit

Supabase is removing automatic Data API grants for newly created objects in
existing projects. NdsApp must remain correct regardless of Supabase's current
platform default: migrations state their intended privileges themselves.
