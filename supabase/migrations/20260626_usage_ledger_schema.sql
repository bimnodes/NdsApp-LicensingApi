begin;

-- =========================================================
-- NdsApp Usage Ledger Schema
-- Additive migration: no behavior change.
-- Purpose:
-- - product analytics
-- - 10 free uses per paid plugin
-- - PayG billing support
-- - access/paywall analytics
-- =========================================================

alter table public.nds_plugin_usage_events
    add column if not exists activation_id uuid null references public.nds_license_activations(id),
    add column if not exists access_code text null,
    add column if not exists access_allowed boolean null,
    add column if not exists billing_country_code text null,
    add column if not exists runtime_country_code text null,
    add column if not exists ndsapp_version text null,
    add column if not exists revit_version text null,
    add column if not exists language text null,
    add column if not exists duration_ms integer null,
    add column if not exists selected_elements_count integer null,
    add column if not exists processed_elements_count integer null,
    add column if not exists created_elements_count integer null,
    add column if not exists modified_elements_count integer null,
    add column if not exists deleted_elements_count integer null,
    add column if not exists input_count integer null,
    add column if not exists output_count integer null,
    add column if not exists complexity_bucket text null,
    add column if not exists model_size_bucket text null,
    add column if not exists error_code text null,
    add column if not exists error_hash text null,
    add column if not exists metrics jsonb not null default '{}'::jsonb,
    add column if not exists metadata jsonb not null default '{}'::jsonb;

-- Backfill activation_id where possible.
update public.nds_plugin_usage_events u
set activation_id = a.id
from public.nds_license_activations a
where u.activation_id is null
  and a.license_id = u.license_id
  and a.machine_hash = u.machine_hash;

-- Defensive checks for usage event analytics fields.
do $$
begin
    if not exists (
        select 1 from pg_constraint
        where conname = 'nds_plugin_usage_events_duration_ms_check'
    ) then
        alter table public.nds_plugin_usage_events
            add constraint nds_plugin_usage_events_duration_ms_check
            check (duration_ms is null or duration_ms >= 0);
    end if;

    if not exists (
        select 1 from pg_constraint
        where conname = 'nds_plugin_usage_events_counts_check'
    ) then
        alter table public.nds_plugin_usage_events
            add constraint nds_plugin_usage_events_counts_check
            check (
                (selected_elements_count is null or selected_elements_count >= 0)
                and (processed_elements_count is null or processed_elements_count >= 0)
                and (created_elements_count is null or created_elements_count >= 0)
                and (modified_elements_count is null or modified_elements_count >= 0)
                and (deleted_elements_count is null or deleted_elements_count >= 0)
                and (input_count is null or input_count >= 0)
                and (output_count is null or output_count >= 0)
            );
    end if;

    if not exists (
        select 1 from pg_constraint
        where conname = 'nds_plugin_usage_events_country_code_check'
    ) then
        alter table public.nds_plugin_usage_events
            add constraint nds_plugin_usage_events_country_code_check
            check (
                (billing_country_code is null or billing_country_code ~ '^[A-Z]{2}$')
                and (runtime_country_code is null or runtime_country_code ~ '^[A-Z]{2}$')
            );
    end if;

    if not exists (
        select 1 from pg_constraint
        where conname = 'nds_plugin_usage_events_bucket_check'
    ) then
        alter table public.nds_plugin_usage_events
            add constraint nds_plugin_usage_events_bucket_check
            check (
                (complexity_bucket is null or complexity_bucket in ('low', 'medium', 'high', 'unknown'))
                and (model_size_bucket is null or model_size_bucket in ('small', 'medium', 'large', 'unknown'))
            );
    end if;

    if not exists (
        select 1 from pg_constraint
        where conname = 'nds_plugin_usage_events_json_objects_check'
    ) then
        alter table public.nds_plugin_usage_events
            add constraint nds_plugin_usage_events_json_objects_check
            check (
                jsonb_typeof(metrics) = 'object'
                and jsonb_typeof(metadata) = 'object'
            );
    end if;
end $$;

-- Counter table for 10 free uses per paid plugin.
create table if not exists public.nds_plugin_usage_counters (
    license_id uuid not null references public.nds_licenses(id) on delete cascade,
    plugin_id text not null references public.nds_plugins(plugin_id),
    successful_usage_count integer not null default 0,
    free_usage_limit integer not null default 10,
    first_used_at timestamptz null,
    last_used_at timestamptz null,
    limit_reached_at timestamptz null,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    primary key (license_id, plugin_id),
    constraint nds_plugin_usage_counters_counts_check
        check (
            successful_usage_count >= 0
            and free_usage_limit >= 0
        )
);

-- Backfill counters from existing successful usage.
with ranked_success as (
    select
        u.license_id,
        u.plugin_id,
        u.created_at,
        row_number() over (
            partition by u.license_id, u.plugin_id
            order by u.created_at, u.id
        ) as rn
    from public.nds_plugin_usage_events u
    where u.execution_status = 'success'
),
counter_source as (
    select
        license_id,
        plugin_id,
        count(*)::integer as successful_usage_count,
        min(created_at) as first_used_at,
        max(created_at) as last_used_at,
        min(created_at) filter (where rn = 10) as limit_reached_at
    from ranked_success
    group by license_id, plugin_id
)
insert into public.nds_plugin_usage_counters (
    license_id,
    plugin_id,
    successful_usage_count,
    free_usage_limit,
    first_used_at,
    last_used_at,
    limit_reached_at,
    updated_at
)
select
    license_id,
    plugin_id,
    successful_usage_count,
    10,
    first_used_at,
    last_used_at,
    limit_reached_at,
    now()
from counter_source
on conflict (license_id, plugin_id)
do update set
    successful_usage_count = excluded.successful_usage_count,
    first_used_at = excluded.first_used_at,
    last_used_at = excluded.last_used_at,
    limit_reached_at = excluded.limit_reached_at,
    updated_at = now();

-- Access/paywall event table.
create table if not exists public.nds_plugin_access_events (
    id bigint generated by default as identity primary key,
    activation_id uuid null references public.nds_license_activations(id),
    license_id uuid null references public.nds_licenses(id),
    plugin_id text not null references public.nds_plugins(plugin_id),
    machine_hash text null,
    access_allowed boolean not null,
    access_code text not null,
    billing_mode text null,
    price_cents integer not null default 0,
    free_usage_count integer null,
    free_usage_limit integer null,
    remaining_free_uses integer null,
    monthly_used_cents integer null,
    monthly_limit_cents integer null,
    billing_country_code text null,
    runtime_country_code text null,
    ndsapp_version text null,
    revit_version text null,
    language text null,
    metadata jsonb not null default '{}'::jsonb,
    created_at timestamptz not null default now(),
    constraint nds_plugin_access_events_amounts_check
        check (
            price_cents >= 0
            and (free_usage_count is null or free_usage_count >= 0)
            and (free_usage_limit is null or free_usage_limit >= 0)
            and (remaining_free_uses is null or remaining_free_uses >= 0)
            and (monthly_used_cents is null or monthly_used_cents >= 0)
            and (monthly_limit_cents is null or monthly_limit_cents >= 0)
        ),
    constraint nds_plugin_access_events_country_code_check
        check (
            (billing_country_code is null or billing_country_code ~ '^[A-Z]{2}$')
            and (runtime_country_code is null or runtime_country_code ~ '^[A-Z]{2}$')
        ),
    constraint nds_plugin_access_events_metadata_object_check
        check (jsonb_typeof(metadata) = 'object')
);

create index if not exists idx_nds_plugin_usage_events_activation_created
    on public.nds_plugin_usage_events (activation_id, created_at desc);

create index if not exists idx_nds_plugin_usage_events_country_created
    on public.nds_plugin_usage_events (runtime_country_code, created_at desc);

create index if not exists idx_nds_plugin_usage_events_access_code_created
    on public.nds_plugin_usage_events (access_code, created_at desc);

create index if not exists idx_nds_plugin_usage_events_versions_created
    on public.nds_plugin_usage_events (ndsapp_version, revit_version, created_at desc);

create index if not exists idx_nds_plugin_usage_counters_plugin
    on public.nds_plugin_usage_counters (plugin_id);

create index if not exists idx_nds_plugin_usage_counters_limit
    on public.nds_plugin_usage_counters (limit_reached_at)
    where limit_reached_at is not null;

create index if not exists idx_nds_plugin_access_events_license_created
    on public.nds_plugin_access_events (license_id, created_at desc);

create index if not exists idx_nds_plugin_access_events_plugin_created
    on public.nds_plugin_access_events (plugin_id, created_at desc);

create index if not exists idx_nds_plugin_access_events_code_created
    on public.nds_plugin_access_events (access_code, created_at desc);

create index if not exists idx_nds_plugin_access_events_country_created
    on public.nds_plugin_access_events (runtime_country_code, created_at desc);

commit;
