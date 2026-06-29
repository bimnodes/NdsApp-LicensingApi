begin;

-- Disable legacy 7-day paid plugin trials in favor of the 10-free-uses model.
update public.nds_plugins
set trial_days = 0
where access_type = 'paid'
  and trial_days <> 0;

-- Allow usage ledger events to store the 10-free-uses billing mode.
alter table public.nds_plugin_usage_events
    drop constraint if exists nds_plugin_usage_billing_mode_check;

alter table public.nds_plugin_usage_events
    add constraint nds_plugin_usage_billing_mode_check
    check (
        billing_mode in (
            'free',
            'trial',
            'free_usage',
            'pro_monthly',
            'pro_annual',
            'payg_postpaid',
            'payg_prepaid',
            'no_charge'
        )
    );

-- Activate 10 free successful uses per paid plugin before requiring Pro or PayG.
-- This keeps the legacy trial code in place, but paid plugin trial_days are now configured as 0.
-- Access order:
-- 1. free plugins
-- 2. Pro monthly / annual
-- 3. paid plugins with remaining free uses
-- 4. legacy trial compatibility
-- 5. PayG
-- 6. payment_required

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


    if v_plugin.access_type = 'paid'
       and v_remaining_free_uses > 0 then
        v_result := jsonb_build_object(
            'success', true,
            'allowed', true,
            'code', 'allowed_free_usage',
            'billing_mode', 'free_usage',
            'plugin_id', v_plugin.plugin_id,
            'price_cents', 0,
            'free_usage_count', v_free_usage_count,
            'free_usage_limit', v_free_usage_limit,
            'remaining_free_uses', v_remaining_free_uses,
            'remaining_free_uses_after_success', greatest(v_remaining_free_uses - 1, 0)
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
        'message', 'This plugin requires Pro, remaining free uses, or pay-as-you-go.',
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

commit;


