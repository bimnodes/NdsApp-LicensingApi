-- Usage Ledger outcome semantics
--
-- Contract after this migration:
--   success   = the command completed successfully; this is the only billable/countable outcome.
--   cancelled = the command started but returned Autodesk Revit Result.Cancelled.
--   failed    = the command failed or raised an unhandled exception.
--   blocked   = the command was prevented from executing by access/entitlement logic.
--
-- metadata.outcome_code provides a stable analytics dimension without changing the v2 RPC payload.

alter table public.nds_plugin_usage_events
    drop constraint if exists nds_plugin_usage_execution_status_check;

alter table public.nds_plugin_usage_events
    add constraint nds_plugin_usage_execution_status_check
    check (execution_status in ('success', 'cancelled', 'failed', 'blocked'));

create or replace function public.nds_report_plugin_usage(
    p_activation_id uuid,
    p_machine_hash text,
    p_plugin_id text,
    p_execution_id uuid,
    p_execution_status text
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
    v_now timestamptz := now();
    v_access jsonb;
    v_allowed boolean := false;
    v_access_code text;
    v_billing_mode text := 'no_charge';
    v_execution_status text := lower(trim(p_execution_status));
    v_license_id uuid;
    v_trial_id bigint;
    v_usage_id bigint;
    v_price_cents integer := 0;
    v_trial_days integer := 7;
    v_existing_usage record;
begin
    if p_execution_id is null then
        return jsonb_build_object(
            'success', false,
            'recorded', false,
            'code', 'invalid_execution_id',
            'message', 'Execution id is required.'
        );
    end if;

    if v_execution_status not in ('success', 'cancelled', 'failed', 'blocked') then
        return jsonb_build_object(
            'success', false,
            'recorded', false,
            'code', 'invalid_execution_status',
            'message', 'Execution status must be success, cancelled, failed, or blocked.'
        );
    end if;

    select
        u.id,
        u.execution_id,
        u.license_id,
        u.plugin_id,
        u.execution_status,
        u.billing_mode,
        u.price_cents,
        u.created_at
    into v_existing_usage
    from public.nds_plugin_usage_events u
    where u.execution_id = p_execution_id;

    if found then
        return jsonb_build_object(
            'success', true,
            'recorded', false,
            'idempotent', true,
            'code', 'usage_already_recorded',
            'usage_event_id', v_existing_usage.id,
            'execution_id', v_existing_usage.execution_id,
            'plugin_id', v_existing_usage.plugin_id,
            'execution_status', v_existing_usage.execution_status,
            'billing_mode', v_existing_usage.billing_mode,
            'price_cents', v_existing_usage.price_cents,
            'created_at', v_existing_usage.created_at
        );
    end if;

    v_access := public.nds_check_plugin_access(
        p_activation_id,
        p_machine_hash,
        p_plugin_id
    );

    v_allowed := coalesce((v_access ->> 'allowed')::boolean, false);
    v_access_code := coalesce(nullif(v_access ->> 'code', ''), 'unknown');

    if v_allowed = false then
        return jsonb_build_object(
            'success', true,
            'recorded', false,
            'code', 'access_not_allowed',
            'plugin_id', p_plugin_id,
            'access_result', v_access
        );
    end if;

    select a.license_id
    into v_license_id
    from public.nds_license_activations a
    where a.id = p_activation_id
      and a.machine_hash = p_machine_hash
      and a.status::text = 'active';

    if not found then
        return jsonb_build_object(
            'success', false,
            'recorded', false,
            'code', 'activation_not_found',
            'message', 'Active activation was not found.'
        );
    end if;

    -- Non-success outcomes are telemetry only: they never consume free usage and never bill.
    if v_execution_status <> 'success' then
        insert into public.nds_plugin_usage_events (
            execution_id,
            license_id,
            plugin_id,
            trial_id,
            machine_hash,
            execution_status,
            price_cents,
            billing_mode,
            created_at,
            activation_id,
            access_code,
            access_allowed
        )
        values (
            p_execution_id,
            v_license_id,
            p_plugin_id,
            null,
            p_machine_hash,
            v_execution_status,
            0,
            'no_charge',
            v_now,
            p_activation_id,
            v_access_code,
            v_allowed
        )
        returning id into v_usage_id;

        return jsonb_build_object(
            'success', true,
            'recorded', true,
            'code', 'usage_recorded_no_charge',
            'usage_event_id', v_usage_id,
            'plugin_id', p_plugin_id,
            'execution_status', v_execution_status,
            'billing_mode', 'no_charge',
            'price_cents', 0,
            'access_code', v_access_code
        );
    end if;

    v_billing_mode := coalesce(v_access ->> 'billing_mode', 'no_charge');
    v_price_cents := coalesce(nullif(v_access ->> 'price_cents', '')::integer, 0);

    if v_billing_mode = 'trial' then
        if v_access ? 'trial_id' then
            v_trial_id := nullif(v_access ->> 'trial_id', '')::bigint;
        end if;

        if v_trial_id is null then
            select coalesce(p.trial_days, 7)
            into v_trial_days
            from public.nds_plugins p
            where p.plugin_id = p_plugin_id;

            insert into public.nds_plugin_trials (
                license_id,
                plugin_id,
                trial_started_at,
                trial_ends_at,
                first_success_execution_id,
                status,
                created_at
            )
            values (
                v_license_id,
                p_plugin_id,
                v_now,
                v_now + make_interval(days => v_trial_days),
                p_execution_id,
                'active',
                v_now
            )
            on conflict (license_id, plugin_id) do nothing
            returning id into v_trial_id;

            if v_trial_id is null then
                select t.id
                into v_trial_id
                from public.nds_plugin_trials t
                where t.license_id = v_license_id
                  and t.plugin_id = p_plugin_id
                limit 1;
            end if;
        else
            update public.nds_plugin_trials
            set first_success_execution_id = coalesce(first_success_execution_id, p_execution_id)
            where id = v_trial_id;
        end if;

        v_price_cents := 0;
    end if;

    if v_billing_mode in ('free', 'trial', 'pro_monthly', 'pro_annual', 'no_charge') then
        v_price_cents := 0;
    end if;

    insert into public.nds_plugin_usage_events (
        execution_id,
        license_id,
        plugin_id,
        trial_id,
        machine_hash,
        execution_status,
        price_cents,
        billing_mode,
        created_at,
        activation_id,
        access_code,
        access_allowed
    )
    values (
        p_execution_id,
        v_license_id,
        p_plugin_id,
        v_trial_id,
        p_machine_hash,
        'success',
        v_price_cents,
        v_billing_mode,
        v_now,
        p_activation_id,
        v_access_code,
        v_allowed
    )
    returning id into v_usage_id;

    insert into public.nds_plugin_usage_counters (
        license_id,
        plugin_id,
        successful_usage_count,
        free_usage_limit,
        first_used_at,
        last_used_at,
        limit_reached_at,
        created_at,
        updated_at
    )
    values (
        v_license_id,
        p_plugin_id,
        1,
        10,
        v_now,
        v_now,
        null,
        v_now,
        v_now
    )
    on conflict (license_id, plugin_id)
    do update set
        successful_usage_count = public.nds_plugin_usage_counters.successful_usage_count + 1,
        first_used_at = coalesce(public.nds_plugin_usage_counters.first_used_at, excluded.first_used_at),
        last_used_at = excluded.last_used_at,
        limit_reached_at = case
            when public.nds_plugin_usage_counters.limit_reached_at is null
             and public.nds_plugin_usage_counters.successful_usage_count + 1 >= public.nds_plugin_usage_counters.free_usage_limit
                then excluded.last_used_at
            else public.nds_plugin_usage_counters.limit_reached_at
        end,
        updated_at = excluded.updated_at;

    return jsonb_build_object(
        'success', true,
        'recorded', true,
        'code', 'usage_recorded',
        'usage_event_id', v_usage_id,
        'execution_id', p_execution_id,
        'plugin_id', p_plugin_id,
        'execution_status', 'success',
        'billing_mode', v_billing_mode,
        'price_cents', v_price_cents,
        'trial_id', v_trial_id,
        'access_code', v_access_code
    );

exception
    when unique_violation then
        select
            u.id,
            u.execution_id,
            u.license_id,
            u.plugin_id,
            u.execution_status,
            u.billing_mode,
            u.price_cents,
            u.created_at
        into v_existing_usage
        from public.nds_plugin_usage_events u
        where u.execution_id = p_execution_id;

        return jsonb_build_object(
            'success', true,
            'recorded', false,
            'idempotent', true,
            'code', 'usage_already_recorded',
            'usage_event_id', v_existing_usage.id,
            'execution_id', v_existing_usage.execution_id,
            'plugin_id', v_existing_usage.plugin_id,
            'execution_status', v_existing_usage.execution_status,
            'billing_mode', v_existing_usage.billing_mode,
            'price_cents', v_existing_usage.price_cents,
            'created_at', v_existing_usage.created_at
        );
end;
$function$;

-- Keep a queryable generic outcome dimension on every usage row. The v2 RPC may overwrite
-- metadata after the base insert, so the trigger runs on both INSERT and UPDATE.
create or replace function public.nds_usage_apply_outcome_metadata()
returns trigger
language plpgsql
set search_path to 'public'
as $function$
begin
    if new.metadata is null or jsonb_typeof(new.metadata) <> 'object' then
        new.metadata := '{}'::jsonb;
    end if;

    if not (new.metadata ? 'outcome_code') then
        new.metadata := new.metadata || jsonb_build_object(
            'outcome_code',
            case new.execution_status
                when 'success' then 'completed'
                when 'cancelled' then 'command_cancelled'
                when 'failed' then 'command_failed'
                when 'blocked' then 'access_blocked'
                else 'unknown'
            end
        );
    end if;

    return new;
end;
$function$;

drop trigger if exists trg_nds_usage_apply_outcome_metadata
    on public.nds_plugin_usage_events;

create trigger trg_nds_usage_apply_outcome_metadata
before insert or update of execution_status, metadata
on public.nds_plugin_usage_events
for each row
execute function public.nds_usage_apply_outcome_metadata();

-- Historical repair.
-- Result.Cancelled was mapped to "blocked" from 2026-06-29 onward. The real local free-usage
-- block was introduced at commit d7fb1037 (2026-06-29 16:30:22 UTC) and always reported
-- duration_ms = 0. Positive-duration blocked rows are therefore command cancellations; the two
-- earlier rows without duration predate the duration payload and are cancellations as well.
update public.nds_plugin_usage_events
set
    execution_status = 'cancelled',
    metadata = coalesce(metadata, '{}'::jsonb) || jsonb_build_object(
        'outcome_code', 'command_cancelled',
        'legacy_execution_status', 'blocked',
        'status_migration', '2026-08-27_cancelled_semantics'
    )
where execution_status = 'blocked'
  and (
      duration_ms > 0
      or created_at < timestamptz '2026-06-29 16:30:22+00'
  );

-- Mark the remaining historical true access blocks explicitly.
update public.nds_plugin_usage_events
set metadata = coalesce(metadata, '{}'::jsonb) || jsonb_build_object(
    'outcome_code', 'access_blocked',
    'block_reason', 'free_usage_exhausted'
)
where execution_status = 'blocked';

-- Ensure every existing event has a normalized generic outcome code.
update public.nds_plugin_usage_events
set metadata = coalesce(metadata, '{}'::jsonb) || jsonb_build_object(
    'outcome_code',
    case execution_status
        when 'success' then 'completed'
        when 'cancelled' then 'command_cancelled'
        when 'failed' then 'command_failed'
        when 'blocked' then 'access_blocked'
        else 'unknown'
    end
)
where metadata is null
   or not (metadata ? 'outcome_code');

-- Catalog repair for active NdsExternalCommand mappings that previously had no backend row.
insert into public.nds_plugins (
    plugin_id,
    folder_path,
    display_name,
    access_type,
    included_in_pro,
    payg_available,
    default_price_cents,
    is_active,
    trial_days,
    created_at,
    updated_at
)
values
    (
        'aks_number',
        'NdsApp.Core/Features/MEP/AKSNumber',
        'AKS Number',
        'paid',
        true,
        true,
        10,
        true,
        0,
        now(),
        now()
    ),
    (
        'system_separator',
        'NdsApp.Core/Features/MEP/SystemSeparator',
        'System Separator',
        'paid',
        true,
        true,
        10,
        true,
        0,
        now(),
        now()
    )
on conflict (plugin_id) do update set
    folder_path = excluded.folder_path,
    display_name = excluded.display_name,
    access_type = excluded.access_type,
    included_in_pro = excluded.included_in_pro,
    payg_available = excluded.payg_available,
    default_price_cents = excluded.default_price_cents,
    is_active = excluded.is_active,
    trial_days = excluded.trial_days,
    updated_at = now();
