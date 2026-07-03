create or replace function public.nds_get_billing_status_context(
  p_activation_id uuid,
  p_machine_hash text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_activation record;
  v_license record;
  v_plan record;
  v_now timestamptz := now();
  v_allowed boolean := false;
  v_billing_mode text;
begin
  select
    a.id,
    a.license_id,
    a.machine_hash,
    a.status::text as activation_status,
    a.activated_at,
    a.last_seen_at,
    a.deactivated_at
  into v_activation
  from public.nds_license_activations a
  where a.id = p_activation_id
    and a.machine_hash = p_machine_hash
  limit 1;

  if v_activation.id is null then
    return jsonb_build_object(
      'success', false,
      'allowed', false,
      'code', 'billing_status_activation_not_found',
      'message', 'Activation was not found for this machine.'
    );
  end if;

  select
    l.id,
    l.email,
    l.plan_id,
    l.status::text as license_status,
    l.max_devices,
    l.valid_from,
    l.valid_until,
    l.stripe_customer_id,
    l.stripe_subscription_id,
    l.stripe_checkout_session_id,
    l.created_at,
    l.updated_at
  into v_license
  from public.nds_licenses l
  where l.id = v_activation.license_id
  limit 1;

  if v_license.id is null then
    return jsonb_build_object(
      'success', false,
      'allowed', false,
      'code', 'billing_status_license_not_found',
      'message', 'License was not found for this activation.'
    );
  end if;

  select
    p.id,
    p.code,
    p.name,
    p.price_amount_cents,
    p.currency,
    p.billing_interval,
    p.max_devices,
    p.stripe_price_id,
    p.is_active
  into v_plan
  from public.nds_plans p
  where p.id = v_license.plan_id
  limit 1;

  v_billing_mode :=
    case
      when coalesce(v_plan.code, '') = 'FREE_LICENSE' then 'free'
      when coalesce(v_plan.code, '') = 'PRO_MONTHLY_10' then 'pro_monthly'
      when coalesce(v_plan.code, '') = 'NDSAPP_ANNUAL_100' then 'pro_annual'
      when coalesce(v_plan.code, '') = 'PAYG_POSTPAID' then 'payg_postpaid'
      else lower(coalesce(v_plan.code, 'unknown'))
    end;

  v_allowed :=
    v_activation.activation_status = 'active'
    and v_license.license_status = 'active'
    and (
      v_license.valid_until is null
      or v_license.valid_until > v_now
    )
    and (
      v_plan.id is null
      or v_plan.is_active = true
    );

  return jsonb_build_object(
    'success', true,
    'allowed', v_allowed,
    'code', 'billing_status_loaded',

    'activation_id', v_activation.id,
    'activation_status', v_activation.activation_status,

    'license_id', v_license.id,
    'email', v_license.email,
    'license_status', v_license.license_status,
    'valid_from', v_license.valid_from,
    'valid_until', v_license.valid_until,
    'max_devices', v_license.max_devices,

    'plan_code', coalesce(v_plan.code, 'UNKNOWN'),
    'plan_name', coalesce(v_plan.name, 'Unknown'),
    'billing_mode', v_billing_mode,
    'billing_interval', v_plan.billing_interval,
    'price_amount_cents', v_plan.price_amount_cents,
    'currency', v_plan.currency,

    'has_stripe_customer', v_license.stripe_customer_id is not null,
    'has_active_subscription',
      v_license.stripe_subscription_id is not null
      and v_license.license_status = 'active',

    'stripe_customer_id', v_license.stripe_customer_id,
    'stripe_subscription_id', v_license.stripe_subscription_id,

    'checked_at', v_now
  );
end;
$$;
