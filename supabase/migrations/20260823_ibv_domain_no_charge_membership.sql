-- NdsApp IBV corporate membership.
--
-- New licenses registered with an @ibv-hd.de email are assigned the
-- IBV_NO_CHARGE plan automatically. The plan grants access to every active
-- NdsApp plugin without Stripe billing while preserving usage telemetry with
-- billing_mode = no_charge.

begin;

-- Create an explicit membership plan so the entitlement is part of the same
-- membership structure as Free, Pro Monthly, Pro Annual and PayG.
insert into public.nds_plans (
    product_id,
    code,
    name,
    price_amount_cents,
    currency,
    billing_interval,
    max_devices,
    stripe_price_id,
    is_active,
    created_at,
    updated_at
)
select
    p.product_id,
    'IBV_NO_CHARGE',
    'IBV Corporate',
    0,
    'eur',
    'none',
    p.max_devices,
    null,
    true,
    now(),
    now()
from public.nds_plans p
where p.code = 'FREE_LICENSE'
limit 1
on conflict (code)
do update set
    name = excluded.name,
    price_amount_cents = 0,
    currency = excluded.currency,
    billing_interval = 'none',
    max_devices = excluded.max_devices,
    stripe_price_id = null,
    is_active = true,
    updated_at = now();

do $migration$
begin
    if not exists (select 1 from public.nds_plans where code = 'IBV_NO_CHARGE') then
        raise exception 'IBV_NO_CHARGE could not be created because FREE_LICENSE is missing.';
    end if;
end;
$migration$;

-- Registration rule: only new licenses are reassigned automatically. Existing
-- paid subscriptions are intentionally not changed or cancelled by this migration.
create or replace function public.nds_apply_email_membership_plan()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
    v_plan record;
begin
    if lower(trim(coalesce(new.email, ''))) ~ '^[^@]+@ibv-hd\.de$' then
        select id, max_devices
        into v_plan
        from public.nds_plans
        where code = 'IBV_NO_CHARGE'
          and is_active = true
        limit 1;

        if not found then
            raise exception 'IBV_NO_CHARGE plan is missing or inactive.';
        end if;

        new.plan_id := v_plan.id;
        new.max_devices := v_plan.max_devices;
    end if;

    return new;
end;
$function$;

revoke all on function public.nds_apply_email_membership_plan() from public;
revoke all on function public.nds_apply_email_membership_plan() from anon;
revoke all on function public.nds_apply_email_membership_plan() from authenticated;

drop trigger if exists trg_nds_licenses_ibv_membership on public.nds_licenses;
create trigger trg_nds_licenses_ibv_membership
before insert on public.nds_licenses
for each row
execute function public.nds_apply_email_membership_plan();

-- Keep the existing access implementation intact and add the corporate plan as
-- an early allow path. All other plans continue through the previous function.
do $migration$
begin
    if to_regprocedure('public.nds_check_plugin_access_base(uuid,text,text)') is null then
        if to_regprocedure('public.nds_check_plugin_access(uuid,text,text)') is null then
            raise exception 'nds_check_plugin_access(uuid,text,text) is missing.';
        end if;

        alter function public.nds_check_plugin_access(uuid,text,text)
            rename to nds_check_plugin_access_base;
    end if;
end;
$migration$;

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
    v_plugin_exists boolean := false;
    v_counter record;
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

    if found then
        select
            l.id,
            l.status::text as license_status,
            l.valid_until,
            p.code as plan_code
        into v_license
        from public.nds_licenses l
        left join public.nds_plans p on p.id = l.plan_id
        where l.id = v_activation.license_id;
    end if;

    if v_license.plan_code = 'IBV_NO_CHARGE'
       and v_activation.activation_status = 'active'
       and v_activation.machine_hash = p_machine_hash
       and v_license.license_status = 'active'
       and (v_license.valid_until is null or v_license.valid_until > v_now) then

        select exists (
            select 1
            from public.nds_plugins p
            where p.plugin_id = p_plugin_id
              and p.is_active = true
        )
        into v_plugin_exists;

        if v_plugin_exists then
            select c.successful_usage_count, c.free_usage_limit
            into v_counter
            from public.nds_plugin_usage_counters c
            where c.license_id = v_license.id
              and c.plugin_id = p_plugin_id;

            if found then
                v_free_usage_count := coalesce(v_counter.successful_usage_count, 0);
                v_free_usage_limit := coalesce(v_counter.free_usage_limit, 10);
            end if;

            v_remaining_free_uses := greatest(v_free_usage_limit - v_free_usage_count, 0);

            update public.nds_license_activations
            set last_seen_at = v_now, updated_at = v_now
            where id = v_activation.id;

            v_result := jsonb_build_object(
                'success', true,
                'allowed', true,
                'code', 'allowed_ibv_no_charge',
                'billing_mode', 'no_charge',
                'plugin_id', p_plugin_id,
                'price_cents', 0,
                'free_usage_count', v_free_usage_count,
                'free_usage_limit', v_free_usage_limit,
                'remaining_free_uses', v_remaining_free_uses,
                'remaining_free_uses_after_success', v_remaining_free_uses
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
    end if;

    return public.nds_check_plugin_access_base(
        p_activation_id,
        p_machine_hash,
        p_plugin_id
    );
end;
$function$;

-- Billing status should expose the corporate plan as no_charge rather than free.
do $migration$
begin
    if to_regprocedure('public.nds_get_billing_status_context_base(uuid,text)') is null then
        if to_regprocedure('public.nds_get_billing_status_context(uuid,text)') is null then
            raise exception 'nds_get_billing_status_context(uuid,text) is missing.';
        end if;

        alter function public.nds_get_billing_status_context(uuid,text)
            rename to nds_get_billing_status_context_base;
    end if;
end;
$migration$;

create or replace function public.nds_get_billing_status_context(
    p_activation_id uuid,
    p_machine_hash text
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
    v_result jsonb;
begin
    v_result := public.nds_get_billing_status_context_base(
        p_activation_id,
        p_machine_hash
    );

    if coalesce((v_result ->> 'success')::boolean, false) = true
       and v_result ->> 'plan_code' = 'IBV_NO_CHARGE' then
        return v_result || jsonb_build_object(
            'plan_name', 'IBV Corporate',
            'billing_mode', 'no_charge',
            'billing_interval', 'none',
            'price_amount_cents', 0,
            'currency', 'eur',
            'has_active_subscription', false
        );
    end if;

    return v_result;
end;
$function$;

-- Prevent a no-charge license from being converted to PayG if a setup request
-- is attempted outside the normal Revit UI.
do $migration$
begin
    if to_regprocedure('public.nds_activate_payg_postpaid_from_setup_base(uuid,text,text,text,text,text)') is null then
        if to_regprocedure('public.nds_activate_payg_postpaid_from_setup(uuid,text,text,text,text,text)') is null then
            raise exception 'nds_activate_payg_postpaid_from_setup(uuid,text,text,text,text,text) is missing.';
        end if;

        alter function public.nds_activate_payg_postpaid_from_setup(uuid,text,text,text,text,text)
            rename to nds_activate_payg_postpaid_from_setup_base;
    end if;
end;
$migration$;

create or replace function public.nds_activate_payg_postpaid_from_setup(
    p_activation_id uuid,
    p_machine_hash text,
    p_stripe_customer_id text,
    p_stripe_checkout_session_id text,
    p_stripe_setup_intent_id text default null,
    p_customer_email text default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
    v_plan_code text;
begin
    select p.code
    into v_plan_code
    from public.nds_license_activations a
    join public.nds_licenses l on l.id = a.license_id
    left join public.nds_plans p on p.id = l.plan_id
    where a.id = p_activation_id
      and a.machine_hash = p_machine_hash
    limit 1;

    if v_plan_code = 'IBV_NO_CHARGE' then
        return jsonb_build_object(
            'success', false,
            'allowed', false,
            'code', 'no_charge_membership_cannot_enable_payg',
            'message', 'This corporate membership already includes all plugins at no charge.',
            'plan_code', v_plan_code,
            'billing_mode', 'no_charge'
        );
    end if;

    return public.nds_activate_payg_postpaid_from_setup_base(
        p_activation_id,
        p_machine_hash,
        p_stripe_customer_id,
        p_stripe_checkout_session_id,
        p_stripe_setup_intent_id,
        p_customer_email
    );
end;
$function$;

commit;
