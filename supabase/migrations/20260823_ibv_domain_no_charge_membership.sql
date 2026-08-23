-- NdsApp domain-based no-charge membership entitlement.
--
-- Employees registering with an @ibv-hd.de email receive access to every active
-- NdsApp plugin without Stripe billing. Usage remains recorded with billing_mode
-- = no_charge so product analytics continue to work.
--
-- The entitlement is data-driven so future corporate domains can be added without
-- changing the access functions again.

begin;

create table if not exists public.nds_membership_domain_entitlements (
    domain text primary key,
    membership_code text not null unique,
    display_name text not null,
    billing_mode text not null,
    grants_all_plugins boolean not null default true,
    price_amount_cents integer not null default 0,
    currency text not null default 'EUR',
    is_active boolean not null default true,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    constraint nds_membership_domain_entitlements_domain_check
        check (domain = lower(trim(domain)) and domain <> '' and position('@' in domain) = 0),
    constraint nds_membership_domain_entitlements_billing_mode_check
        check (billing_mode in ('no_charge')),
    constraint nds_membership_domain_entitlements_price_check
        check (price_amount_cents >= 0)
);

insert into public.nds_membership_domain_entitlements (
    domain,
    membership_code,
    display_name,
    billing_mode,
    grants_all_plugins,
    price_amount_cents,
    currency,
    is_active,
    updated_at
)
values (
    'ibv-hd.de',
    'IBV_NO_CHARGE',
    'IBV Corporate',
    'no_charge',
    true,
    0,
    'EUR',
    true,
    now()
)
on conflict (domain)
do update set
    membership_code = excluded.membership_code,
    display_name = excluded.display_name,
    billing_mode = excluded.billing_mode,
    grants_all_plugins = excluded.grants_all_plugins,
    price_amount_cents = excluded.price_amount_cents,
    currency = excluded.currency,
    is_active = excluded.is_active,
    updated_at = now();

create or replace function public.nds_get_membership_domain_entitlement(
    p_email text
)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
    v_email text;
    v_domain text;
    v_entitlement record;
begin
    v_email := lower(nullif(trim(p_email), ''));

    if v_email is null or v_email !~ '^[^@]+@[^@]+$' then
        return null;
    end if;

    v_domain := split_part(v_email, '@', 2);

    select
        e.domain,
        e.membership_code,
        e.display_name,
        e.billing_mode,
        e.grants_all_plugins,
        e.price_amount_cents,
        e.currency
    into v_entitlement
    from public.nds_membership_domain_entitlements e
    where e.domain = v_domain
      and e.is_active = true
    limit 1;

    if not found then
        return null;
    end if;

    return jsonb_build_object(
        'domain', v_entitlement.domain,
        'membership_code', v_entitlement.membership_code,
        'display_name', v_entitlement.display_name,
        'billing_mode', v_entitlement.billing_mode,
        'grants_all_plugins', v_entitlement.grants_all_plugins,
        'price_amount_cents', v_entitlement.price_amount_cents,
        'currency', v_entitlement.currency
    );
end;
$function$;

-- Preserve the current production access implementation and wrap it with the
-- domain entitlement. This avoids duplicating the existing Free/Pro/PayG rules.
do $migration$
begin
    if to_regprocedure('public.nds_check_plugin_access_without_domain_entitlement(uuid,text,text)') is null then
        if to_regprocedure('public.nds_check_plugin_access(uuid,text,text)') is null then
            raise exception 'nds_check_plugin_access(uuid,text,text) is missing.';
        end if;

        alter function public.nds_check_plugin_access(uuid,text,text)
            rename to nds_check_plugin_access_without_domain_entitlement;
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
    v_activation_found boolean := false;
    v_license_found boolean := false;
    v_activation_id uuid;
    v_license_id uuid;
    v_activation_machine_hash text;
    v_activation_status text;
    v_license_email text;
    v_license_status text;
    v_license_valid_until timestamptz;
    v_entitlement jsonb;
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
        a.status::text
    into
        v_activation_id,
        v_license_id,
        v_activation_machine_hash,
        v_activation_status
    from public.nds_license_activations a
    where a.id = p_activation_id;

    v_activation_found := found;

    if v_activation_found then
        select
            l.email,
            l.status::text,
            l.valid_until
        into
            v_license_email,
            v_license_status,
            v_license_valid_until
        from public.nds_licenses l
        where l.id = v_license_id;

        v_license_found := found;
    end if;

    if v_license_found then
        v_entitlement := public.nds_get_membership_domain_entitlement(v_license_email);
    end if;

    if v_entitlement is not null
       and coalesce((v_entitlement ->> 'grants_all_plugins')::boolean, false) = true
       and v_activation_status = 'active'
       and v_activation_machine_hash = p_machine_hash
       and v_license_status = 'active'
       and (v_license_valid_until is null or v_license_valid_until > v_now) then

        select exists (
            select 1
            from public.nds_plugins p
            where p.plugin_id = p_plugin_id
              and p.is_active = true
        )
        into v_plugin_exists;

        if v_plugin_exists then
            select
                c.successful_usage_count,
                c.free_usage_limit
            into v_counter
            from public.nds_plugin_usage_counters c
            where c.license_id = v_license_id
              and c.plugin_id = p_plugin_id;

            if found then
                v_free_usage_count := coalesce(v_counter.successful_usage_count, 0);
                v_free_usage_limit := coalesce(v_counter.free_usage_limit, 10);
            end if;

            v_remaining_free_uses := greatest(v_free_usage_limit - v_free_usage_count, 0);

            update public.nds_license_activations
            set
                last_seen_at = v_now,
                updated_at = v_now
            where id = v_activation_id;

            v_result := jsonb_build_object(
                'success', true,
                'allowed', true,
                'code', 'allowed_domain_no_charge',
                'billing_mode', v_entitlement ->> 'billing_mode',
                'membership_code', v_entitlement ->> 'membership_code',
                'membership_name', v_entitlement ->> 'display_name',
                'membership_domain', v_entitlement ->> 'domain',
                'plugin_id', p_plugin_id,
                'price_cents', 0,
                'free_usage_count', v_free_usage_count,
                'free_usage_limit', v_free_usage_limit,
                'remaining_free_uses', v_remaining_free_uses,
                'remaining_free_uses_after_success', v_remaining_free_uses
            );

            perform public.nds_record_plugin_access_event(
                v_activation_id,
                v_license_id,
                p_machine_hash,
                p_plugin_id,
                v_result
            );

            return v_result;
        end if;
    end if;

    return public.nds_check_plugin_access_without_domain_entitlement(
        p_activation_id,
        p_machine_hash,
        p_plugin_id
    );
end;
$function$;

-- Present the effective corporate membership in Settings/Billing status while
-- preserving any real Stripe linkage that may already exist for legacy users.
do $migration$
begin
    if to_regprocedure('public.nds_get_billing_status_context_without_domain_entitlement(uuid,text)') is null then
        if to_regprocedure('public.nds_get_billing_status_context(uuid,text)') is null then
            raise exception 'nds_get_billing_status_context(uuid,text) is missing.';
        end if;

        alter function public.nds_get_billing_status_context(uuid,text)
            rename to nds_get_billing_status_context_without_domain_entitlement;
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
    v_entitlement jsonb;
begin
    v_result := public.nds_get_billing_status_context_without_domain_entitlement(
        p_activation_id,
        p_machine_hash
    );

    if coalesce((v_result ->> 'success')::boolean, false) = false then
        return v_result;
    end if;

    v_entitlement := public.nds_get_membership_domain_entitlement(v_result ->> 'email');

    if v_entitlement is null then
        return v_result;
    end if;

    return v_result || jsonb_build_object(
        'plan_code', v_entitlement ->> 'membership_code',
        'plan_name', v_entitlement ->> 'display_name',
        'billing_mode', v_entitlement ->> 'billing_mode',
        'billing_interval', null,
        'price_amount_cents', 0,
        'currency', v_entitlement ->> 'currency',
        'membership_source', 'email_domain',
        'membership_domain', v_entitlement ->> 'domain'
    );
end;
$function$;

-- Reject PayG activation even if a stale setup session completes after the
-- corporate entitlement has been introduced.
do $migration$
begin
    if to_regprocedure('public.nds_activate_payg_postpaid_from_setup_without_domain_entitlement(uuid,text,text,text,text,text)') is null then
        if to_regprocedure('public.nds_activate_payg_postpaid_from_setup(uuid,text,text,text,text,text)') is null then
            raise exception 'nds_activate_payg_postpaid_from_setup(uuid,text,text,text,text,text) is missing.';
        end if;

        alter function public.nds_activate_payg_postpaid_from_setup(uuid,text,text,text,text,text)
            rename to nds_activate_payg_postpaid_from_setup_without_domain_entitlement;
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
    v_email text;
    v_entitlement jsonb;
begin
    select l.email
    into v_email
    from public.nds_license_activations a
    join public.nds_licenses l on l.id = a.license_id
    where a.id = p_activation_id
      and a.machine_hash = p_machine_hash
    limit 1;

    v_entitlement := public.nds_get_membership_domain_entitlement(
        coalesce(v_email, p_customer_email)
    );

    if v_entitlement is not null then
        return jsonb_build_object(
            'success', false,
            'allowed', false,
            'code', 'no_charge_membership_cannot_enable_payg',
            'message', 'This corporate membership already includes all plugins at no charge.',
            'membership_code', v_entitlement ->> 'membership_code',
            'billing_mode', v_entitlement ->> 'billing_mode'
        );
    end if;

    return public.nds_activate_payg_postpaid_from_setup_without_domain_entitlement(
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
