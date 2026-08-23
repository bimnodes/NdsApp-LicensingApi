-- Self-service license key issuance for NdsApp.
--
-- Every user receives a normal NdsApp license key by email and activates with
-- Email + License Key. New users receive FREE_LICENSE by default. Enabled
-- corporate email-domain policies can assign another no-charge plan (currently
-- @ibv-hd.de -> IBV_NO_CHARGE) without changing the activation mechanism.

begin;

create table if not exists public.nds_email_membership_policies (
    id uuid primary key default gen_random_uuid(),
    email_domain text not null unique,
    plan_id uuid not null references public.nds_plans(id),
    is_enabled boolean not null default true,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    constraint nds_email_membership_policies_domain_check
        check (
            email_domain = lower(trim(email_domain))
            and email_domain <> ''
            and email_domain not like '%@%'
            and email_domain like '%.%'
        )
);

alter table public.nds_email_membership_policies enable row level security;
revoke all on table public.nds_email_membership_policies from anon;
revoke all on table public.nds_email_membership_policies from authenticated;
grant select, insert, update, delete on table public.nds_email_membership_policies to service_role;

insert into public.nds_email_membership_policies (
    email_domain,
    plan_id,
    is_enabled,
    created_at,
    updated_at
)
select
    'ibv-hd.de',
    p.id,
    true,
    now(),
    now()
from public.nds_plans p
where p.code = 'IBV_NO_CHARGE'
  and p.is_active = true
limit 1
on conflict (email_domain)
do update set
    plan_id = excluded.plan_id,
    is_enabled = true,
    updated_at = now();

do $migration$
begin
    if not exists (
        select 1
        from public.nds_email_membership_policies mp
        join public.nds_plans p on p.id = mp.plan_id
        where mp.email_domain = 'ibv-hd.de'
          and p.code = 'IBV_NO_CHARGE'
    ) then
        raise exception 'The IBV email membership policy could not be configured.';
    end if;
end;
$migration$;

create table if not exists public.nds_license_key_requests (
    id uuid primary key default gen_random_uuid(),
    email text not null,
    license_id uuid references public.nds_licenses(id) on delete set null,
    plan_code text,
    was_created boolean not null default false,
    requested_at timestamptz not null default now()
);

create index if not exists idx_nds_license_key_requests_email_requested
    on public.nds_license_key_requests (email, requested_at desc);

alter table public.nds_license_key_requests enable row level security;
revoke all on table public.nds_license_key_requests from anon;
revoke all on table public.nds_license_key_requests from authenticated;
grant select, insert on table public.nds_license_key_requests to service_role;

-- Apply an enabled email-domain membership policy to newly created licenses.
-- If a policy is disabled, registration falls through to the plan selected by
-- the issuer (FREE_LICENSE for self-service registration).
create or replace function public.nds_apply_email_membership_plan()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
    v_domain text;
    v_plan record;
begin
    v_domain := split_part(lower(trim(coalesce(new.email, ''))), '@', 2);

    if v_domain = '' then
        return new;
    end if;

    select p.id, p.max_devices
    into v_plan
    from public.nds_email_membership_policies mp
    join public.nds_plans p on p.id = mp.plan_id
    where mp.email_domain = v_domain
      and mp.is_enabled = true
      and p.is_active = true
    limit 1;

    if found then
        new.plan_id := v_plan.id;
        new.max_devices := v_plan.max_devices;
    end if;

    return new;
end;
$function$;

revoke all on function public.nds_apply_email_membership_plan() from public;
revoke all on function public.nds_apply_email_membership_plan() from anon;
revoke all on function public.nds_apply_email_membership_plan() from authenticated;

-- Issue or re-issue a normal NdsApp license key for an email address.
-- This RPC is intentionally service-role only. The public API calls it and
-- sends the returned plaintext key to that same email address via Resend.
create or replace function public.nds_issue_license_key_for_email(p_email text)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'extensions'
as $function$
declare
    v_email text;
    v_domain text;
    v_profile_id uuid;
    v_license record;
    v_plan record;
    v_free_plan record;
    v_plain_license_key text;
    v_license_key_hash text;
    v_license_key_prefix text;
    v_license_key_last4 text;
    v_license_id uuid;
    v_created boolean := false;
    v_last_request timestamptz;
begin
    v_email := lower(nullif(trim(p_email), ''));

    if v_email is null
       or v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then
        return jsonb_build_object(
            'success', false,
            'code', 'invalid_email',
            'message', 'A valid email address is required.'
        );
    end if;

    -- Serialize requests for the same mailbox so concurrent requests cannot
    -- create duplicate licenses or bypass the cooldown.
    perform pg_advisory_xact_lock(hashtext(v_email));

    select max(r.requested_at)
    into v_last_request
    from public.nds_license_key_requests r
    where r.email = v_email;

    if v_last_request is not null
       and v_last_request > now() - interval '2 minutes' then
        return jsonb_build_object(
            'success', false,
            'code', 'license_key_request_rate_limited',
            'message', 'A license key was requested recently. Please wait before requesting another one.',
            'retry_after_seconds', greatest(
                1,
                ceil(extract(epoch from ((v_last_request + interval '2 minutes') - now())))::integer
            )
        );
    end if;

    select id, product_id, max_devices
    into v_free_plan
    from public.nds_plans
    where code = 'FREE_LICENSE'
      and is_active = true
    limit 1;

    if not found then
        raise exception 'FREE_LICENSE plan is missing or inactive.';
    end if;

    v_domain := split_part(v_email, '@', 2);

    select p.id, p.product_id, p.code, p.name, p.max_devices
    into v_plan
    from public.nds_email_membership_policies mp
    join public.nds_plans p on p.id = mp.plan_id
    where mp.email_domain = v_domain
      and mp.is_enabled = true
      and p.is_active = true
    limit 1;

    if not found then
        select
            v_free_plan.id as id,
            v_free_plan.product_id as product_id,
            'FREE_LICENSE'::text as code,
            'Free'::text as name,
            v_free_plan.max_devices as max_devices
        into v_plan;
    end if;

    -- Prefer an existing usable license. Paid licenses are never downgraded by
    -- a key request; their existing plan/subscription remains unchanged.
    select
        l.id,
        l.user_id,
        l.product_id,
        l.plan_id,
        l.status::text as status,
        l.max_devices,
        l.valid_until,
        l.stripe_subscription_id,
        p.code as plan_code,
        p.name as plan_name
    into v_license
    from public.nds_licenses l
    left join public.nds_plans p on p.id = l.plan_id
    where lower(l.email) = v_email
      and l.status in (
          'active'::public.nds_license_status,
          'trial'::public.nds_license_status,
          'past_due'::public.nds_license_status,
          'pending_payment'::public.nds_license_status
      )
    order by
        case l.status::text
            when 'active' then 0
            when 'trial' then 1
            when 'past_due' then 2
            else 3
        end,
        case when l.stripe_subscription_id is not null then 0 else 1 end,
        l.updated_at desc
    limit 1;

    v_plain_license_key :=
        'NDS-' ||
        upper(substring(encode(gen_random_bytes(4), 'hex') from 1 for 8)) ||
        '-' ||
        upper(substring(encode(gen_random_bytes(4), 'hex') from 1 for 8)) ||
        '-' ||
        upper(substring(encode(gen_random_bytes(4), 'hex') from 1 for 8));

    v_license_key_hash := encode(
        digest(upper(trim(v_plain_license_key)), 'sha256'),
        'hex'
    );
    v_license_key_prefix := substring(v_plain_license_key from 1 for 8);
    v_license_key_last4 := right(v_plain_license_key, 4);

    if v_license.id is null then
        select id
        into v_profile_id
        from public.nds_profiles
        where lower(email) = v_email
        limit 1;

        insert into public.nds_licenses (
            user_id,
            email,
            product_id,
            plan_id,
            license_key_hash,
            license_key_prefix,
            license_key_last4,
            status,
            max_devices,
            valid_from,
            valid_until
        )
        values (
            v_profile_id,
            v_email,
            v_plan.product_id,
            v_plan.id,
            v_license_key_hash,
            v_license_key_prefix,
            v_license_key_last4,
            'active'::public.nds_license_status,
            v_plan.max_devices,
            now(),
            null
        )
        returning id into v_license_id;

        v_created := true;
    else
        v_license_id := v_license.id;

        -- An existing paid/Stripe license keeps its commercial plan. For a
        -- non-Stripe Free/IBV license, reflect the currently enabled domain
        -- policy so enabling/disabling corporate access behaves predictably.
        if v_license.stripe_subscription_id is null
           and v_license.plan_code in ('FREE_LICENSE', 'IBV_NO_CHARGE') then
            update public.nds_licenses
            set
                plan_id = v_plan.id,
                product_id = v_plan.product_id,
                max_devices = v_plan.max_devices,
                license_key_hash = v_license_key_hash,
                license_key_prefix = v_license_key_prefix,
                license_key_last4 = v_license_key_last4,
                updated_at = now()
            where id = v_license_id;
        else
            update public.nds_licenses
            set
                license_key_hash = v_license_key_hash,
                license_key_prefix = v_license_key_prefix,
                license_key_last4 = v_license_key_last4,
                updated_at = now()
            where id = v_license_id;
        end if;
    end if;

    -- Read back the effective plan because the INSERT trigger may have applied
    -- an enabled domain policy.
    select
        l.id,
        l.valid_until,
        l.max_devices,
        p.code as plan_code,
        p.name as plan_name
    into v_license
    from public.nds_licenses l
    left join public.nds_plans p on p.id = l.plan_id
    where l.id = v_license_id;

    insert into public.nds_license_key_requests (
        email,
        license_id,
        plan_code,
        was_created,
        requested_at
    )
    values (
        v_email,
        v_license_id,
        v_license.plan_code,
        v_created,
        now()
    );

    insert into public.nds_license_events (
        license_id,
        event_type,
        event_source,
        metadata
    )
    values (
        v_license_id,
        case when v_created then 'license.key.issued' else 'license.key.reissued' end,
        'self_service',
        jsonb_build_object(
            'email', v_email,
            'plan_code', v_license.plan_code,
            'created', v_created
        )
    );

    return jsonb_build_object(
        'success', true,
        'code', case when v_created then 'license_key_issued' else 'license_key_reissued' end,
        'message', 'License key issued for email delivery.',
        'license_id', v_license_id,
        'email', v_email,
        'plan_code', v_license.plan_code,
        'plan_name', v_license.plan_name,
        'max_devices', v_license.max_devices,
        'valid_until', v_license.valid_until,
        'plain_license_key', v_plain_license_key,
        'created', v_created
    );
end;
$function$;

revoke all on function public.nds_issue_license_key_for_email(text) from public;
revoke all on function public.nds_issue_license_key_for_email(text) from anon;
revoke all on function public.nds_issue_license_key_for_email(text) from authenticated;
grant execute on function public.nds_issue_license_key_for_email(text) to service_role;

-- Controlled global switch for a corporate email-domain membership. The
-- reconciliation only changes non-Stripe Free/Corporate licenses: paid
-- subscriptions are never cancelled or downgraded by this function.
create or replace function public.nds_set_email_membership_policy_enabled(
    p_email_domain text,
    p_enabled boolean
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
    v_domain text;
    v_policy record;
    v_free_plan record;
    v_changed integer := 0;
begin
    v_domain := lower(trim(coalesce(p_email_domain, '')));
    v_domain := trim(leading '@' from v_domain);

    select mp.id, mp.plan_id, p.code as plan_code, p.max_devices, p.product_id
    into v_policy
    from public.nds_email_membership_policies mp
    join public.nds_plans p on p.id = mp.plan_id
    where mp.email_domain = v_domain
    limit 1;

    if not found then
        return jsonb_build_object(
            'success', false,
            'code', 'email_membership_policy_not_found',
            'email_domain', v_domain
        );
    end if;

    select id, product_id, max_devices
    into v_free_plan
    from public.nds_plans
    where code = 'FREE_LICENSE'
      and is_active = true
    limit 1;

    if not found then
        raise exception 'FREE_LICENSE plan is missing or inactive.';
    end if;

    update public.nds_email_membership_policies
    set is_enabled = p_enabled,
        updated_at = now()
    where id = v_policy.id;

    if p_enabled then
        update public.nds_licenses l
        set
            plan_id = v_policy.plan_id,
            product_id = v_policy.product_id,
            max_devices = v_policy.max_devices,
            updated_at = now()
        from public.nds_plans current_plan
        where current_plan.id = l.plan_id
          and split_part(lower(trim(l.email)), '@', 2) = v_domain
          and l.stripe_subscription_id is null
          and current_plan.code in ('FREE_LICENSE', v_policy.plan_code);
    else
        update public.nds_licenses l
        set
            plan_id = v_free_plan.id,
            product_id = v_free_plan.product_id,
            max_devices = v_free_plan.max_devices,
            updated_at = now()
        where split_part(lower(trim(l.email)), '@', 2) = v_domain
          and l.stripe_subscription_id is null
          and l.plan_id = v_policy.plan_id;
    end if;

    get diagnostics v_changed = row_count;

    return jsonb_build_object(
        'success', true,
        'code', 'email_membership_policy_updated',
        'email_domain', v_domain,
        'enabled', p_enabled,
        'plan_code', v_policy.plan_code,
        'licenses_reconciled', v_changed
    );
end;
$function$;

revoke all on function public.nds_set_email_membership_policy_enabled(text,boolean) from public;
revoke all on function public.nds_set_email_membership_policy_enabled(text,boolean) from anon;
revoke all on function public.nds_set_email_membership_policy_enabled(text,boolean) from authenticated;
grant execute on function public.nds_set_email_membership_policy_enabled(text,boolean) to service_role;

commit;
