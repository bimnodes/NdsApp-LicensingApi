begin;

-- Pay-as-you-go is intentionally retired. Abort instead of deleting live commercial data
-- if any PayG entitlement or billable usage has appeared since this migration was prepared.
do $$
begin
  if exists (
    select 1
    from public.nds_licenses l
    join public.nds_plans p on p.id = l.plan_id
    where p.code = 'PAYG_POSTPAID'
  ) then
    raise exception 'Cannot remove PayG: at least one license still uses PAYG_POSTPAID.';
  end if;

  if exists (
    select 1
    from public.nds_plugin_usage_events
    where billing_mode in ('payg_postpaid', 'payg_prepaid')
  ) then
    raise exception 'Cannot remove PayG: PayG usage events still exist.';
  end if;

  if exists (select 1 from public.nds_license_billing_settings) then
    raise exception 'Cannot remove PayG: license billing settings still exist.';
  end if;

  if exists (select 1 from public.nds_payg_invoices) then
    raise exception 'Cannot remove PayG: PayG invoices still exist.';
  end if;
end
$$;

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
  v_price_cents := coalesce(nullif(p_access_result ->> 'price_cents', '')::integer, 0);
  v_free_usage_count := nullif(p_access_result ->> 'free_usage_count', '')::integer;
  v_free_usage_limit := nullif(p_access_result ->> 'free_usage_limit', '')::integer;
  v_remaining_free_uses := nullif(p_access_result ->> 'remaining_free_uses', '')::integer;

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
    jsonb_build_object('access_result', p_access_result),
    now()
  );
end;
$function$;

create or replace function public.nds_check_plugin_access_base(
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
  v_counter record;
  v_has_success boolean := false;
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
      p_activation_id, null, p_machine_hash, p_plugin_id, v_result
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
      v_activation.id, v_activation.license_id, p_machine_hash, p_plugin_id, v_result
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
      v_activation.id, v_activation.license_id, p_machine_hash, p_plugin_id, v_result
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
  left join public.nds_plans p on p.id = l.plan_id
  where l.id = v_activation.license_id;

  if not found then
    v_result := jsonb_build_object(
      'success', false,
      'allowed', false,
      'code', 'license_not_found',
      'message', 'License was not found.'
    );
    perform public.nds_record_plugin_access_event(
      v_activation.id, v_activation.license_id, p_machine_hash, p_plugin_id, v_result
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
      v_activation.id, v_license.id, p_machine_hash, p_plugin_id, v_result
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
      v_activation.id, v_license.id, p_machine_hash, p_plugin_id, v_result
    );
    return v_result;
  end if;

  select
    p.plugin_id,
    p.display_name,
    p.access_type,
    p.included_in_pro,
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
      v_activation.id, v_license.id, p_machine_hash, p_plugin_id, v_result
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
  set last_seen_at = v_now, updated_at = v_now
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
      v_activation.id, v_license.id, p_machine_hash, v_plugin.plugin_id, v_result
    );
    return v_result;
  end if;

  if v_license.plan_code = 'PRO_MONTHLY_10'
     and coalesce(v_plugin.included_in_pro, false) = true then
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
      v_activation.id, v_license.id, p_machine_hash, v_plugin.plugin_id, v_result
    );
    return v_result;
  end if;

  if v_license.plan_code in ('NDSAPP_ANNUAL_100', 'PRO_ANNUAL_100')
     and coalesce(v_plugin.included_in_pro, false) = true then
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
      v_activation.id, v_license.id, p_machine_hash, v_plugin.plugin_id, v_result
    );
    return v_result;
  end if;

  if v_license.plan_code = 'FREE_LICENSE'
     and v_plugin.access_type = 'paid'
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
      v_activation.id, v_license.id, p_machine_hash, v_plugin.plugin_id, v_result
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
      v_activation.id, v_license.id, p_machine_hash, v_plugin.plugin_id, v_result
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
      v_activation.id, v_license.id, p_machine_hash, v_plugin.plugin_id, v_result
    );
    return v_result;
  end if;

  v_result := jsonb_build_object(
    'success', true,
    'allowed', false,
    'code', 'payment_required',
    'message', 'This plugin requires an active Pro plan after free access is exhausted.',
    'plugin_id', v_plugin.plugin_id,
    'free_usage_count', v_free_usage_count,
    'free_usage_limit', v_free_usage_limit,
    'remaining_free_uses', v_remaining_free_uses
  );

  perform public.nds_record_plugin_access_event(
    v_activation.id, v_license.id, p_machine_hash, v_plugin.plugin_id, v_result
  );
  return v_result;
end;
$function$;

create or replace function public.nds_get_billing_status_context_base(
  p_activation_id uuid,
  p_machine_hash text
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
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
      else lower(coalesce(v_plan.code, 'unknown'))
    end;

  v_allowed :=
    v_activation.activation_status = 'active'
    and v_license.license_status = 'active'
    and (v_license.valid_until is null or v_license.valid_until > v_now)
    and (v_plan.id is null or v_plan.is_active = true);

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
$function$;

drop function if exists public.nds_activate_payg_postpaid_from_setup(uuid, text, text, text, text, text);
drop function if exists public.nds_activate_payg_postpaid_from_setup_base(uuid, text, text, text, text, text);
drop function if exists public.nds_complete_payg_billing_run(uuid);
drop function if exists public.nds_get_payg_billing_invoices(uuid);
drop function if exists public.nds_mark_payg_invoice_created(uuid, text, text);
drop function if exists public.nds_mark_payg_invoice_failed(uuid, text);
drop function if exists public.nds_payg_monthly_limit_default_cents();
drop function if exists public.nds_prepare_payg_billing_run(date, date);
drop function if exists public.nds_sync_payg_invoice_status(text, text, text, jsonb);

alter table public.nds_plugin_usage_events
  drop constraint if exists nds_plugin_usage_billing_mode_check,
  drop constraint if exists nds_plugin_usage_events_payg_invoice_id_fkey,
  drop column if exists payg_invoice_id,
  drop column if exists payg_billed_at;

alter table public.nds_plugin_usage_events
  add constraint nds_plugin_usage_billing_mode_check
  check (billing_mode = any (array[
    'free'::text,
    'trial'::text,
    'free_usage'::text,
    'pro_monthly'::text,
    'pro_annual'::text,
    'no_charge'::text
  ]));

alter table public.nds_plugin_access_events
  drop constraint if exists nds_plugin_access_events_amounts_check,
  drop column if exists monthly_used_cents,
  drop column if exists monthly_limit_cents;

alter table public.nds_plugin_access_events
  add constraint nds_plugin_access_events_amounts_check
  check (
    price_cents >= 0
    and (free_usage_count is null or free_usage_count >= 0)
    and (free_usage_limit is null or free_usage_limit >= 0)
    and (remaining_free_uses is null or remaining_free_uses >= 0)
  );

alter table public.nds_plugins
  drop constraint if exists nds_plugins_default_price_check,
  drop column if exists payg_available,
  drop column if exists default_price_cents;

alter table public.nds_licenses
  drop column if exists stripe_setup_intent_id;

drop table if exists public.nds_payg_invoices;
drop table if exists public.nds_payg_billing_runs;
drop table if exists public.nds_license_billing_settings;

delete from public.nds_plans
where code = 'PAYG_POSTPAID';

commit;
