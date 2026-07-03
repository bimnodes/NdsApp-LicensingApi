-- PR17: PayG billing hardening.
-- Fixes:
-- 1. Do not attach new usage to closed Stripe invoices.
-- 2. Do not mark usage as billed when an invoice is merely created.
-- 3. Mark usage as billed only after Stripe reports the PayG invoice as paid.
-- 4. Keep PayG usage below Stripe minimum charge pending until it accumulates enough amount.

with reopened_usage as (
  update public.nds_plugin_usage_events e
  set
    payg_invoice_id = null,
    payg_billed_at = null
  from public.nds_payg_invoices i
  where e.payg_invoice_id = i.id
    and e.billing_mode = 'payg_postpaid'
    and e.execution_status = 'success'
    and e.price_cents > 0
    and i.status <> 'paid'
  returning
    e.id as usage_event_id,
    i.id as payg_invoice_id
),
affected as (
  select distinct payg_invoice_id
  from reopened_usage
),
invoice_totals as (
  select
    a.payg_invoice_id,
    count(e.id)::integer as usage_event_count,
    coalesce(sum(e.price_cents), 0)::integer as total_amount_cents
  from affected a
  left join public.nds_plugin_usage_events e
    on e.payg_invoice_id = a.payg_invoice_id
   and e.billing_mode = 'payg_postpaid'
   and e.execution_status = 'success'
   and e.price_cents > 0
  group by a.payg_invoice_id
)
update public.nds_payg_invoices i
set
  usage_event_count = t.usage_event_count,
  total_amount_cents = t.total_amount_cents,
  updated_at = now()
from invoice_totals t
where i.id = t.payg_invoice_id;

create or replace function public.nds_prepare_payg_billing_run(
  p_period_start date,
  p_period_end date
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_run_id uuid;
  v_invoice_count integer := 0;
  v_usage_count integer := 0;
  v_total_amount_cents integer := 0;
  v_skipped_closed_invoice_usage_count integer := 0;
  v_skipped_closed_invoice_amount_cents integer := 0;
  v_skipped_minimum_usage_count integer := 0;
  v_skipped_minimum_amount_cents integer := 0;
  v_minimum_charge_amount_cents integer := 50;
begin
  if p_period_start is null or p_period_end is null or p_period_end <= p_period_start then
    return jsonb_build_object(
      'success', false,
      'code', 'invalid_period',
      'message', 'Invalid PayG billing period.'
    );
  end if;

  insert into public.nds_payg_billing_runs (
    period_start,
    period_end,
    status,
    started_at,
    updated_at
  )
  values (
    p_period_start,
    p_period_end,
    'running',
    now(),
    now()
  )
  on conflict (period_start, period_end)
  do update set
    status = 'running',
    started_at = now(),
    completed_at = null,
    error_message = null,
    updated_at = now()
  returning id into v_run_id;

  with billable as (
    select
      l.id as license_id,
      l.stripe_customer_id,
      e.id as usage_event_id,
      e.price_cents
    from public.nds_plugin_usage_events e
    join public.nds_licenses l on l.id = e.license_id
    join public.nds_license_billing_settings bs on bs.license_id = l.id
    where e.billing_mode = 'payg_postpaid'
      and e.execution_status = 'success'
      and e.payg_invoice_id is null
      and e.created_at < p_period_end::timestamptz
      and e.price_cents > 0
      and l.status = 'active'
      and l.stripe_customer_id is not null
      and bs.payg_enabled = true
  ),
  closed_invoice_conflicts as (
    select
      b.usage_event_id,
      b.price_cents
    from billable b
    join public.nds_payg_invoices i
      on i.license_id = b.license_id
     and i.period_start = p_period_start
     and i.period_end = p_period_end
    where i.status not in ('pending', 'failed')
  )
  select
    count(*)::integer,
    coalesce(sum(price_cents), 0)::integer
  into
    v_skipped_closed_invoice_usage_count,
    v_skipped_closed_invoice_amount_cents
  from closed_invoice_conflicts;

  with billable as (
    select
      l.id as license_id,
      l.stripe_customer_id,
      e.id as usage_event_id,
      e.price_cents
    from public.nds_plugin_usage_events e
    join public.nds_licenses l on l.id = e.license_id
    join public.nds_license_billing_settings bs on bs.license_id = l.id
    where e.billing_mode = 'payg_postpaid'
      and e.execution_status = 'success'
      and e.payg_invoice_id is null
      and e.created_at < p_period_end::timestamptz
      and e.price_cents > 0
      and l.status = 'active'
      and l.stripe_customer_id is not null
      and bs.payg_enabled = true
      and not exists (
        select 1
        from public.nds_payg_invoices i
        where i.license_id = l.id
          and i.period_start = p_period_start
          and i.period_end = p_period_end
          and i.status not in ('pending', 'failed')
      )
  ),
  invoice_groups as (
    select
      license_id,
      stripe_customer_id,
      count(*)::integer as usage_event_count,
      sum(price_cents)::integer as total_amount_cents
    from billable
    group by license_id, stripe_customer_id
  ),
  below_minimum_groups as (
    select *
    from invoice_groups
    where total_amount_cents < v_minimum_charge_amount_cents
  )
  select
    coalesce(sum(usage_event_count), 0)::integer,
    coalesce(sum(total_amount_cents), 0)::integer
  into
    v_skipped_minimum_usage_count,
    v_skipped_minimum_amount_cents
  from below_minimum_groups;

  with billable as (
    select
      l.id as license_id,
      l.stripe_customer_id,
      e.id as usage_event_id,
      e.price_cents
    from public.nds_plugin_usage_events e
    join public.nds_licenses l on l.id = e.license_id
    join public.nds_license_billing_settings bs on bs.license_id = l.id
    where e.billing_mode = 'payg_postpaid'
      and e.execution_status = 'success'
      and e.payg_invoice_id is null
      and e.created_at < p_period_end::timestamptz
      and e.price_cents > 0
      and l.status = 'active'
      and l.stripe_customer_id is not null
      and bs.payg_enabled = true
      and not exists (
        select 1
        from public.nds_payg_invoices i
        where i.license_id = l.id
          and i.period_start = p_period_start
          and i.period_end = p_period_end
          and i.status not in ('pending', 'failed')
      )
  ),
  invoice_groups as (
    select
      license_id,
      stripe_customer_id,
      count(*)::integer as usage_event_count,
      sum(price_cents)::integer as total_amount_cents
    from billable
    group by license_id, stripe_customer_id
    having sum(price_cents)::integer >= v_minimum_charge_amount_cents
  ),
  upserted_invoices as (
    insert into public.nds_payg_invoices (
      billing_run_id,
      license_id,
      stripe_customer_id,
      period_start,
      period_end,
      usage_event_count,
      total_amount_cents,
      status,
      updated_at
    )
    select
      v_run_id,
      license_id,
      stripe_customer_id,
      p_period_start,
      p_period_end,
      usage_event_count,
      total_amount_cents,
      'pending',
      now()
    from invoice_groups
    on conflict (license_id, period_start, period_end)
    do update set
      billing_run_id = excluded.billing_run_id,
      stripe_customer_id = excluded.stripe_customer_id,
      usage_event_count = excluded.usage_event_count,
      total_amount_cents = excluded.total_amount_cents,
      status = 'pending',
      error_message = null,
      updated_at = now()
    where public.nds_payg_invoices.status in ('pending', 'failed')
    returning id, license_id
  ),
  linked_events as (
    update public.nds_plugin_usage_events e
    set payg_invoice_id = i.id
    from upserted_invoices i
    where e.license_id = i.license_id
      and e.billing_mode = 'payg_postpaid'
      and e.execution_status = 'success'
      and e.payg_invoice_id is null
      and e.created_at < p_period_end::timestamptz
      and e.price_cents > 0
    returning e.id, e.price_cents
  )
  select
    count(*)::integer,
    coalesce(sum(price_cents), 0)::integer
  into
    v_usage_count,
    v_total_amount_cents
  from linked_events;

  select count(*)::integer
  into v_invoice_count
  from public.nds_payg_invoices
  where billing_run_id = v_run_id
    and status in ('pending', 'failed');

  update public.nds_payg_billing_runs
  set
    total_licenses = v_invoice_count,
    total_usage_events = v_usage_count,
    total_amount_cents = v_total_amount_cents,
    updated_at = now()
  where id = v_run_id;

  return jsonb_build_object(
    'success', true,
    'code', 'payg_billing_run_prepared',
    'billing_run_id', v_run_id,
    'period_start', p_period_start,
    'period_end', p_period_end,
    'invoice_count', v_invoice_count,
    'usage_event_count', v_usage_count,
    'total_amount_cents', v_total_amount_cents,
    'skipped_closed_invoice_usage_count', v_skipped_closed_invoice_usage_count,
    'skipped_closed_invoice_amount_cents', v_skipped_closed_invoice_amount_cents,
    'skipped_minimum_usage_count', v_skipped_minimum_usage_count,
    'skipped_minimum_amount_cents', v_skipped_minimum_amount_cents,
    'minimum_charge_amount_cents', v_minimum_charge_amount_cents
  );
end;
$function$;

create or replace function public.nds_mark_payg_invoice_created(
  p_payg_invoice_id uuid,
  p_stripe_invoice_id text,
  p_stripe_invoice_item_id text
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_billing_run_id uuid;
  v_total_amount_cents integer;
  v_usage_event_count integer;
begin
  if p_payg_invoice_id is null
     or nullif(trim(p_stripe_invoice_id), '') is null
     or nullif(trim(p_stripe_invoice_item_id), '') is null then
    return jsonb_build_object(
      'success', false,
      'code', 'invalid_request'
    );
  end if;

  update public.nds_payg_invoices
  set
    stripe_invoice_id = p_stripe_invoice_id,
    stripe_invoice_item_id = p_stripe_invoice_item_id,
    status = 'invoiced',
    error_message = null,
    updated_at = now()
  where id = p_payg_invoice_id
  returning
    billing_run_id,
    total_amount_cents,
    usage_event_count
  into
    v_billing_run_id,
    v_total_amount_cents,
    v_usage_event_count;

  if v_billing_run_id is null then
    return jsonb_build_object(
      'success', false,
      'code', 'payg_invoice_not_found'
    );
  end if;

  update public.nds_payg_billing_runs
  set
    stripe_invoice_count = (
      select count(*)::integer
      from public.nds_payg_invoices
      where billing_run_id = v_billing_run_id
        and stripe_invoice_id is not null
    ),
    updated_at = now()
  where id = v_billing_run_id;

  return jsonb_build_object(
    'success', true,
    'code', 'payg_invoice_marked_created',
    'billing_run_id', v_billing_run_id,
    'payg_invoice_id', p_payg_invoice_id,
    'stripe_invoice_id', p_stripe_invoice_id,
    'stripe_invoice_item_id', p_stripe_invoice_item_id,
    'total_amount_cents', v_total_amount_cents,
    'usage_event_count', v_usage_event_count
  );
end;
$function$;

create or replace function public.nds_sync_payg_invoice_status(
  p_stripe_invoice_id text,
  p_stripe_invoice_status text,
  p_event_type text,
  p_raw_data jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_payg_invoice_id uuid;
  v_billing_run_id uuid;
  v_status text;
begin
  if nullif(trim(p_stripe_invoice_id), '') is null then
    return jsonb_build_object(
      'success', false,
      'code', 'stripe_invoice_id_required'
    );
  end if;

  v_status := case
    when p_event_type in ('invoice.payment_succeeded', 'invoice.paid') then 'paid'
    when p_event_type = 'invoice.payment_failed' then 'payment_failed'
    when lower(coalesce(p_stripe_invoice_status, '')) = 'paid' then 'paid'
    when lower(coalesce(p_stripe_invoice_status, '')) = 'void' then 'void'
    when lower(coalesce(p_stripe_invoice_status, '')) = 'uncollectible' then 'uncollectible'
    when lower(coalesce(p_stripe_invoice_status, '')) = 'open' then 'open'
    when lower(coalesce(p_stripe_invoice_status, '')) = 'draft' then 'draft'
    else coalesce(nullif(lower(p_stripe_invoice_status), ''), 'unknown')
  end;

  update public.nds_payg_invoices
  set
    status = v_status,
    error_message = case
      when v_status in ('payment_failed', 'uncollectible') then 'Stripe invoice payment failed or became uncollectible.'
      else null
    end,
    updated_at = now()
  where stripe_invoice_id = p_stripe_invoice_id
  returning id, billing_run_id
  into v_payg_invoice_id, v_billing_run_id;

  if v_payg_invoice_id is null then
    return jsonb_build_object(
      'success', true,
      'code', 'payg_invoice_not_found',
      'handled', false,
      'stripe_invoice_id', p_stripe_invoice_id
    );
  end if;

  if v_status = 'paid' then
    update public.nds_plugin_usage_events
    set payg_billed_at = coalesce(payg_billed_at, now())
    where payg_invoice_id = v_payg_invoice_id;
  elsif v_status in ('payment_failed', 'uncollectible', 'void') then
    update public.nds_plugin_usage_events
    set payg_billed_at = null
    where payg_invoice_id = v_payg_invoice_id;
  end if;

  update public.nds_payg_billing_runs
  set
    error_count = (
      select count(*)::integer
      from public.nds_payg_invoices
      where billing_run_id = v_billing_run_id
        and status in ('failed', 'payment_failed', 'uncollectible')
    ),
    updated_at = now()
  where id = v_billing_run_id;

  return jsonb_build_object(
    'success', true,
    'code', 'payg_invoice_status_synced',
    'handled', true,
    'payg_invoice_id', v_payg_invoice_id,
    'billing_run_id', v_billing_run_id,
    'stripe_invoice_id', p_stripe_invoice_id,
    'status', v_status
  );
end;
$function$;