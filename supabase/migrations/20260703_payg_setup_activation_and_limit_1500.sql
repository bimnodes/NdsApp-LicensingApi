-- NdsApp PayG setup activation flow and monthly limit correction.
--
-- This migration:
-- 1. Centralizes the PayG monthly limit default at 1500 cents.
-- 2. Updates existing PayG billing settings from the old 2000-cent limit to 1500.
-- 3. Removes the old 2000-cent hardcode from nds_check_plugin_access.
-- 4. Stores Stripe setup intent id on licenses.
-- 5. Adds an RPC used by the API webhook after Stripe Checkout mode=setup completes.

begin;

alter table public.nds_license_billing_settings
  alter column payg_monthly_limit_cents set default 1500;

update public.nds_license_billing_settings
set
  payg_monthly_limit_cents = 1500,
  updated_at = now()
where payg_monthly_limit_cents = 2000;

create or replace function public.nds_payg_monthly_limit_default_cents()
returns integer
language sql
stable
as $$
  select 1500;
$$;

do $$
declare
  v_oid oid;
  v_def text;
  v_new_def text;
begin
  select 'public.nds_check_plugin_access(uuid,text,text)'::regprocedure::oid
  into v_oid;

  v_def := pg_get_functiondef(v_oid);
  v_new_def := v_def;

  if position('v_month_limit_cents integer := 2000;' in v_new_def) > 0 then
    v_new_def := replace(
      v_new_def,
      'v_month_limit_cents integer := 2000;',
      'v_month_limit_cents integer := public.nds_payg_monthly_limit_default_cents();'
    );
  elsif position('v_month_limit_cents integer := public.nds_payg_monthly_limit_default_cents();' in v_new_def) = 0 then
    raise exception 'Unexpected nds_check_plugin_access monthly limit declaration. Manual review required.';
  end if;

  if position('coalesce(v_settings.payg_monthly_limit_cents, 2000)' in v_new_def) > 0 then
    v_new_def := replace(
      v_new_def,
      'coalesce(v_settings.payg_monthly_limit_cents, 2000)',
      'coalesce(v_settings.payg_monthly_limit_cents, public.nds_payg_monthly_limit_default_cents())'
    );
  elsif position('coalesce(v_settings.payg_monthly_limit_cents, public.nds_payg_monthly_limit_default_cents())' in v_new_def) = 0 then
    raise exception 'Unexpected nds_check_plugin_access monthly limit fallback. Manual review required.';
  end if;

  if v_new_def <> v_def then
    execute v_new_def;
  end if;
end $$;

alter table public.nds_licenses
  add column if not exists stripe_setup_intent_id text;

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
set search_path = public
as $$
declare
  v_activation record;
  v_license record;
  v_payg_plan record;
  v_now timestamptz := now();
  v_monthly_limit_cents integer := public.nds_payg_monthly_limit_default_cents();
begin
  if p_activation_id is null then
    return jsonb_build_object(
      'success', false,
      'allowed', false,
      'code', 'activation_id_required',
      'message', 'activation_id is required.'
    );
  end if;

  if nullif(trim(coalesce(p_machine_hash, '')), '') is null then
    return jsonb_build_object(
      'success', false,
      'allowed', false,
      'code', 'machine_hash_required',
      'message', 'machine_hash is required.'
    );
  end if;

  if nullif(trim(coalesce(p_stripe_customer_id, '')), '') is null then
    return jsonb_build_object(
      'success', false,
      'allowed', false,
      'code', 'stripe_customer_required',
      'message', 'stripe_customer_id is required.'
    );
  end if;

  select
    a.id,
    a.license_id,
    a.machine_hash,
    a.status::text as activation_status
  into v_activation
  from public.nds_license_activations a
  where a.id = p_activation_id
    and a.machine_hash = p_machine_hash
  limit 1;

  if not found then
    return jsonb_build_object(
      'success', false,
      'allowed', false,
      'code', 'activation_not_found',
      'message', 'Activation was not found for this machine.'
    );
  end if;

  if v_activation.activation_status <> 'active' then
    return jsonb_build_object(
      'success', false,
      'allowed', false,
      'code', 'activation_not_active',
      'message', 'Activation is not active.',
      'activation_status', v_activation.activation_status
    );
  end if;

  select
    l.id,
    l.email,
    l.status::text as license_status,
    l.plan_id,
    l.valid_until,
    l.stripe_customer_id,
    l.stripe_subscription_id,
    p.code as plan_code
  into v_license
  from public.nds_licenses l
  join public.nds_plans p on p.id = l.plan_id
  where l.id = v_activation.license_id
  limit 1;

  if not found then
    return jsonb_build_object(
      'success', false,
      'allowed', false,
      'code', 'license_not_found',
      'message', 'License was not found.'
    );
  end if;

  if v_license.license_status <> 'active' then
    return jsonb_build_object(
      'success', false,
      'allowed', false,
      'code', 'license_not_active',
      'message', 'License is not active.',
      'license_status', v_license.license_status
    );
  end if;

  if v_license.valid_until is not null and v_license.valid_until <= v_now then
    return jsonb_build_object(
      'success', false,
      'allowed', false,
      'code', 'license_expired',
      'message', 'License is expired.'
    );
  end if;

  if v_license.plan_code in ('PRO_MONTHLY_10', 'NDSAPP_ANNUAL_100') then
    return jsonb_build_object(
      'success', false,
      'allowed', false,
      'code', 'active_pro_plan_cannot_enable_payg',
      'message', 'This license already has an active Pro plan. Manage or cancel the Pro plan before switching to PayG.',
      'current_plan_code', v_license.plan_code
    );
  end if;

  select
    p.id,
    p.code,
    p.name,
    p.max_devices
  into v_payg_plan
  from public.nds_plans p
  where p.code = 'PAYG_POSTPAID'
    and p.is_active = true
  limit 1;

  if not found then
    return jsonb_build_object(
      'success', false,
      'allowed', false,
      'code', 'payg_plan_missing',
      'message', 'PAYG_POSTPAID plan is missing or inactive.'
    );
  end if;

  update public.nds_licenses
  set
    plan_id = v_payg_plan.id,
    max_devices = coalesce(v_payg_plan.max_devices, max_devices),
    valid_until = null,
    stripe_customer_id = trim(p_stripe_customer_id),
    stripe_subscription_id = null,
    stripe_checkout_session_id = nullif(trim(coalesce(p_stripe_checkout_session_id, '')), ''),
    stripe_setup_intent_id = nullif(trim(coalesce(p_stripe_setup_intent_id, '')), ''),
    updated_at = now()
  where id = v_license.id;

  insert into public.nds_license_billing_settings (
    license_id,
    payg_enabled,
    payg_monthly_limit_cents,
    created_at,
    updated_at
  )
  values (
    v_license.id,
    true,
    v_monthly_limit_cents,
    now(),
    now()
  )
  on conflict (license_id)
  do update set
    payg_enabled = true,
    payg_monthly_limit_cents = excluded.payg_monthly_limit_cents,
    updated_at = now();

  return jsonb_build_object(
    'success', true,
    'allowed', true,
    'code', 'payg_postpaid_activated',
    'message', 'Pay-as-you-go was activated for this license.',
    'license_id', v_license.id,
    'activation_id', v_activation.id,
    'plan_code', 'PAYG_POSTPAID',
    'billing_mode', 'payg_postpaid',
    'stripe_customer_id', trim(p_stripe_customer_id),
    'stripe_checkout_session_id', nullif(trim(coalesce(p_stripe_checkout_session_id, '')), ''),
    'stripe_setup_intent_id', nullif(trim(coalesce(p_stripe_setup_intent_id, '')), ''),
    'payg_enabled', true,
    'payg_monthly_limit_cents', v_monthly_limit_cents
  );
end;
$$;

commit;