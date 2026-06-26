begin;

-- =========================================================
-- NdsApp Usage Ledger RPC v2
-- Compatible migration:
-- - keeps current function signatures
-- - logs plugin access decisions
-- - enriches usage events with activation/access fields
-- - updates usage counters on successful executions
-- - does not enforce the 10-use limit yet
-- =========================================================

create or replace function public.nds_record_plugin_access_event(
    p_activation_id uuid,
    p_license_id uuid,
    p_machine_hash text,
    p_plugin_id text,
    p_access_result jsonb
)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
    v_plugin_exists boolean := false;
    v_allowed boolean := false;
    v_code text := 'unknown';
    v_billing_mode text;
    v_price_cents integer := 0;

    v_free_usage_count integer;
    v_free_usage_limit integer;
    v_remaining_free_uses integer;
    v_monthly_used_cents integer;
    v_monthly_limit_cents integer;
begin
    if p_plugin_id is null or trim(p_plugin_id) = '' then
        return;
    end if;

    select exists (
        select 1
        from public.nds_plugins p
        where p.plugin_id = p_plugin_id
    )
    into v_plugin_exists;

    if v_plugin_exists = false then
        return;
    end if;

    v_allowed := coalesce((p_access_result ->> 'allowed')::boolean, false);
    v_code := coalesce(nullif(p_access_result ->> 'code', ''), 'unknown');
    v_billing_mode := nullif(p_access_result ->> 'billing_mode', '');

    v_price_cents := coalesce(
        nullif(p_access_result ->> 'price_cents', '')::integer,
        0
    );

    v_free_usage_count := nullif(p_access_result ->> 'free_usage_count', '')::integer;
    v_free_usage_limit := nullif(p_access_result ->> 'free_usage_limit', '')::integer;
    v_remaining_free_uses := nullif(p_access_result ->> 'remaining_free_uses', '')::integer;
    v_monthly_used_cents := nullif(p_access_result ->> 'monthly_used_cents', '')::integer;
    v_monthly_limit_cents := nullif(p_access_result ->> 'monthly_limit_cents', '')::integer;

    insert into public.nds_plugin_access_events (
        activation_id,
        license_id,
        plugin_id,
        machine_hash,
        access_allowed,
        access_code,
        billing_mode,
        price_cents,
        free_usage_count,
        free_usage_limit,
        remaining_free_uses,
        monthly_used_cents,
        monthly_limit_cents,
        metadata,
        created_at
    )
    values (
        p_activation_id,
        p_license_id,
        p_plugin_id,
        p_machine_hash,
        v_allowed,
        v_code,
        v_billing_mode,
        v_price_cents,
        v_free_usage_count,
        v_free_usage_limit,
        v_remaining_free_uses,
        v_monthly_used_cents,
        v_monthly_limit_cents,
        jsonb_build_object(
            'access_result', p_access_result
        ),
        now()
    );
end;
$function$;

create or replace function public.nds_check_plugin_access(
    p_activation_id uuid,
    p_machine_hash text,
    p_plugin_id text
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
    v_now timestamptz := now();

    v_activation record;
    v_license record;
    v_plugin record;
    v_trial record;
    v_settings record;
    v_counter record;

    v_has_success boolean := false;

    v_month_start timestamptz := date_trunc('month', now());
    v_month_end timestamptz := date_trunc('month', now()) + interval '1 month';

    v_month_used_cents integer := 0;
    v_month_limit_cents integer := 2000;
    v_price_cents integer;

    v_free_usage_count integer := 0;
    v_free_usage_limit integer := 10;
    v_remaining_free_uses integer := 10;

    v_result jsonb;
begin
    select
        a.id,
        a.license_id,
        a.machine_hash,
        a.status::text as activation_status
    into v_activation
    from public.nds_license_activations a
    where a.id = p_activation_id;

    if not found then
        v_result := jsonb_build_object(
            'success', false,
            'allowed', false,
            'code', 'activation_not_found',
            'message', 'Activation was not found.'
        );

        perform public.nds_record_plugin_access_event(
            p_activation_id,
            null,
            p_machine_hash,
            p_plugin_id,
            v_result
        );

        return v_result;
    end if;

    if v_activation.activation_status <> 'active' then
        v_result := jsonb_build_object(
            'success', false,
            'allowed', false,
            'code', 'activation_not_active',
            'message', 'Activation is not active.'
        );

        perform public.nds_record_plugin_access_event(
            v_activation.id,
            v_activation.license_id,
            p_machine_hash,
            p_plugin_id,
            v_result
        );

        return v_result;
    end if;

    if v_activation.machine_hash <> p_machine_hash then
        v_result := jsonb_build_object(
            'success', false,
            'allowed', false,
            'code', 'machine_hash_mismatch',
            'message', 'Machine hash does not match this activation.'
        );

        perform public.nds_record_plugin_access_event(
            v_activation.id,
            v_activation.license_id,
            p_machine_hash,
            p_plugin_id,
            v_result
        );

        return v_result;
    end if;

    select
        l.id,
        l.email,
        l.status::text as license_status,
        l.valid_until,
        l.plan_id,
        p.code as plan_code
    into v_license
    from public.nds_licenses l
    left join public.nds_plans p
        on p.id = l.plan_id
    where l.id = v_activation.license_id;

    if not found then
        v_result := jsonb_build_object(
            'success', false,
            'allowed', false,
            'code', 'license_not_found',
            'message', 'License was not found.'
        );

        perform public.nds_record_plugin_access_event(
            v_activation.id,
            v_activation.license_id,
            p_machine_hash,
            p_plugin_id,
            v_result
        );

        return v_result;
    end if;

    if v_license.license_status <> 'active' then
        v_result := jsonb_build_object(
            'success', false,
            'allowed', false,
            'code', 'license_not_active',
            'message', 'License is not active.'
        );

        perform public.nds_record_plugin_access_event(
            v_activation.id,
            v_license.id,
            p_machine_hash,
            p_plugin_id,
            v_result
        );

        return v_result;
    end if;

    if v_license.valid_until is not null and v_license.valid_until <= v_now then
        v_result := jsonb_build_object(
            'success', false,
            'allowed', false,
            'code', 'license_expired',
            'message', 'License has expired.'
        );

        perform public.nds_record_plugin_access_event(
            v_activation.id,
            v_license.id,
            p_machine_hash,
            p_plugin_id,
            v_result
        );

        return v_result;
    end if;

    select
        p.plugin_id,
        p.display_name,
        p.access_type,
        p.included_in_pro,
        p.payg_available,
        p.default_price_cents,
        p.trial_days,
        p.is_active
    into v_plugin
    from public.nds_plugins p
    where p.plugin_id = p_plugin_id
      and p.is_active = true;

    if not found then
        v_result := jsonb_build_object(
            'success', false,
            'allowed', false,
            'code', 'plugin_not_found',
            'message', 'Plugin was not found or is inactive.'
        );

        perform public.nds_record_plugin_access_event(
            v_activation.id,
            v_license.id,
            p_machine_hash,
            p_plugin_id,
            v_result
        );

        return v_result;
    end if;

    select
        c.successful_usage_count,
        c.free_usage_limit
    into v_counter
    from public.nds_plugin_usage_counters c
    where c.license_id = v_license.id
      and c.plugin_id = v_plugin.plugin_id;

    if found then
        v_free_usage_count := coalesce(v_counter.successful_usage_count, 0);
        v_free_usage_limit := coalesce(v_counter.free_usage_limit, 10);
    end if;

    v_remaining_free_uses := greatest(v_free_usage_limit - v_free_usage_count, 0);

    update public.nds_license_activations
    set
        last_seen_at = v_now,
        updated_at = v_now
    where id = v_activation.id;

    if v_plugin.access_type = 'free' then
        v_result := jsonb_build_object(
            'success', true,
            'allowed', true,
            'code', 'allowed_free',
            'billing_mode', 'free',
            'plugin_id', v_plugin.plugin_id,
            'price_cents', 0,
            'free_usage_count', v_free_usage_count,
            'free_usage_limit', v_free_usage_limit,
            'remaining_free_uses', v_remaining_free_uses
        );

        perform public.nds_record_plugin_access_event(
            v_activation.id,
            v_license.id,
            p_machine_hash,
            v_plugin.plugin_id,
            v_result
        );

        return v_result;
    end if;

    if v_license.plan_code = 'PRO_MONTHLY_10' then
        v_result := jsonb_build_object(
            'success', true,
            'allowed', true,
            'code', 'allowed_pro_monthly',
            'billing_mode', 'pro_monthly',
            'plugin_id', v_plugin.plugin_id,
            'price_cents', 0,
            'free_usage_count', v_free_usage_count,
            'free_usage_limit', v_free_usage_limit,
            'remaining_free_uses', v_remaining_free_uses
        );

        perform public.nds_record_plugin_access_event(
            v_activation.id,
            v_license.id,
            p_machine_hash,
            v_plugin.plugin_id,
            v_result
        );

        return v_result;
    end if;

    if v_license.plan_code in ('NDSAPP_ANNUAL_100', 'PRO_ANNUAL_100') then
        v_result := jsonb_build_object(
            'success', true,
            'allowed', true,
            'code', 'allowed_pro_annual',
            'billing_mode', 'pro_annual',
            'plugin_id', v_plugin.plugin_id,
            'price_cents', 0,
            'free_usage_count', v_free_usage_count,
            'free_usage_limit', v_free_usage_limit,
            'remaining_free_uses', v_remaining_free_uses
        );

        perform public.nds_record_plugin_access_event(
            v_activation.id,
            v_license.id,
            p_machine_hash,
            v_plugin.plugin_id,
            v_result
        );

        return v_result;
    end if;

    select
        t.id,
        t.trial_started_at,
        t.trial_ends_at,
        t.status
    into v_trial
    from public.nds_plugin_trials t
    where t.license_id = v_license.id
      and t.plugin_id = v_plugin.plugin_id
      and t.status = 'active'
      and t.trial_ends_at > v_now
    limit 1;

    if found then
        v_result := jsonb_build_object(
            'success', true,
            'allowed', true,
            'code', 'allowed_trial_active',
            'billing_mode', 'trial',
            'plugin_id', v_plugin.plugin_id,
            'trial_id', v_trial.id,
            'trial_started_at', v_trial.trial_started_at,
            'trial_ends_at', v_trial.trial_ends_at,
            'price_cents', 0,
            'free_usage_count', v_free_usage_count,
            'free_usage_limit', v_free_usage_limit,
            'remaining_free_uses', v_remaining_free_uses
        );

        perform public.nds_record_plugin_access_event(
            v_activation.id,
            v_license.id,
            p_machine_hash,
            v_plugin.plugin_id,
            v_result
        );

        return v_result;
    end if;

    select exists (
        select 1
        from public.nds_plugin_usage_events u
        where u.license_id = v_license.id
          and u.plugin_id = v_plugin.plugin_id
          and u.execution_status = 'success'
    )
    into v_has_success;

    if v_has_success = false and v_plugin.trial_days > 0 then
        v_result := jsonb_build_object(
            'success', true,
            'allowed', true,
            'code', 'allowed_trial_available',
            'billing_mode', 'trial',
            'plugin_id', v_plugin.plugin_id,
            'trial_pending', true,
            'trial_days', v_plugin.trial_days,
            'trial_starts_after_success', true,
            'estimated_trial_ends_at', v_now + make_interval(days => v_plugin.trial_days),
            'price_cents', 0,
            'free_usage_count', v_free_usage_count,
            'free_usage_limit', v_free_usage_limit,
            'remaining_free_uses', v_remaining_free_uses
        );

        perform public.nds_record_plugin_access_event(
            v_activation.id,
            v_license.id,
            p_machine_hash,
            v_plugin.plugin_id,
            v_result
        );

        return v_result;
    end if;

    select
        s.payg_enabled,
        s.payg_monthly_limit_cents
    into v_settings
    from public.nds_license_billing_settings s
    where s.license_id = v_license.id;

    if found then
        v_month_limit_cents := coalesce(v_settings.payg_monthly_limit_cents, 2000);
    end if;

    if v_license.plan_code = 'PAYG_POSTPAID'
       or coalesce(v_settings.payg_enabled, false) = true then

        if v_plugin.payg_available = false then
            v_result := jsonb_build_object(
                'success', true,
                'allowed', false,
                'code', 'payg_not_available',
                'message', 'This plugin is not available for pay-as-you-go.',
                'plugin_id', v_plugin.plugin_id,
                'free_usage_count', v_free_usage_count,
                'free_usage_limit', v_free_usage_limit,
                'remaining_free_uses', v_remaining_free_uses
            );

            perform public.nds_record_plugin_access_event(
                v_activation.id,
                v_license.id,
                p_machine_hash,
                v_plugin.plugin_id,
                v_result
            );

            return v_result;
        end if;

        if v_plugin.default_price_cents is null then
            v_result := jsonb_build_object(
                'success', true,
                'allowed', false,
                'code', 'payg_price_not_configured',
                'message', 'This plugin does not have a pay-as-you-go price configured.',
                'plugin_id', v_plugin.plugin_id,
                'free_usage_count', v_free_usage_count,
                'free_usage_limit', v_free_usage_limit,
                'remaining_free_uses', v_remaining_free_uses
            );

            perform public.nds_record_plugin_access_event(
                v_activation.id,
                v_license.id,
                p_machine_hash,
                v_plugin.plugin_id,
                v_result
            );

            return v_result;
        end if;

        v_price_cents := v_plugin.default_price_cents;

        select coalesce(sum(u.price_cents), 0)
        into v_month_used_cents
        from public.nds_plugin_usage_events u
        where u.license_id = v_license.id
          and u.execution_status = 'success'
          and u.billing_mode = 'payg_postpaid'
          and u.created_at >= v_month_start
          and u.created_at < v_month_end;

        if v_month_used_cents + v_price_cents > v_month_limit_cents then
            v_result := jsonb_build_object(
                'success', true,
                'allowed', false,
                'code', 'payg_monthly_limit_reached',
                'message', 'Monthly pay-as-you-go limit reached.',
                'plugin_id', v_plugin.plugin_id,
                'monthly_limit_cents', v_month_limit_cents,
                'monthly_used_cents', v_month_used_cents,
                'price_cents', v_price_cents,
                'free_usage_count', v_free_usage_count,
                'free_usage_limit', v_free_usage_limit,
                'remaining_free_uses', v_remaining_free_uses
            );

            perform public.nds_record_plugin_access_event(
                v_activation.id,
                v_license.id,
                p_machine_hash,
                v_plugin.plugin_id,
                v_result
            );

            return v_result;
        end if;

        v_result := jsonb_build_object(
            'success', true,
            'allowed', true,
            'code', 'allowed_payg_postpaid',
            'billing_mode', 'payg_postpaid',
            'plugin_id', v_plugin.plugin_id,
            'price_cents', v_price_cents,
            'monthly_limit_cents', v_month_limit_cents,
            'monthly_used_cents', v_month_used_cents,
            'monthly_remaining_cents', v_month_limit_cents - v_month_used_cents,
            'free_usage_count', v_free_usage_count,
            'free_usage_limit', v_free_usage_limit,
            'remaining_free_uses', v_remaining_free_uses
        );

        perform public.nds_record_plugin_access_event(
            v_activation.id,
            v_license.id,
            p_machine_hash,
            v_plugin.plugin_id,
            v_result
        );

        return v_result;
    end if;

    v_result := jsonb_build_object(
        'success', true,
        'allowed', false,
        'code', 'payment_required',
        'message', 'This plugin requires Pro, an active trial, or pay-as-you-go.',
        'plugin_id', v_plugin.plugin_id,
        'free_usage_count', v_free_usage_count,
        'free_usage_limit', v_free_usage_limit,
        'remaining_free_uses', v_remaining_free_uses
    );

    perform public.nds_record_plugin_access_event(
        v_activation.id,
        v_license.id,
        p_machine_hash,
        v_plugin.plugin_id,
        v_result
    );

    return v_result;
end;
$function$;

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

    if v_execution_status not in ('success', 'failed', 'blocked') then
        return jsonb_build_object(
            'success', false,
            'recorded', false,
            'code', 'invalid_execution_status',
            'message', 'Execution status must be success, failed, or blocked.'
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

    select
        a.license_id
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

    v_price_cents := coalesce(
        nullif(v_access ->> 'price_cents', '')::integer,
        0
    );

    if v_billing_mode = 'trial' then
        if v_access ? 'trial_id' then
            v_trial_id := nullif(v_access ->> 'trial_id', '')::bigint;
        end if;

        if v_trial_id is null then
            select
                coalesce(p.trial_days, 7)
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
                select
                    t.id
                into v_trial_id
                from public.nds_plugin_trials t
                where t.license_id = v_license_id
                  and t.plugin_id = p_plugin_id
                limit 1;
            end if;
        else
            update public.nds_plugin_trials
            set
                first_success_execution_id = coalesce(first_success_execution_id, p_execution_id)
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

commit;
