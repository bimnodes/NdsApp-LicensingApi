-- Protect NdsApp production data from accidental destructive resets.
--
-- Runtime roles do not need TRUNCATE/TRIGGER/REFERENCES privileges. RLS does not
-- protect TRUNCATE, so these privileges are explicitly removed. A BEFORE
-- TRUNCATE trigger also blocks accidental administrative resets executed as the
-- table owner/postgres. Deliberate destructive maintenance must first remove the
-- relevant guard in a reviewed migration.

revoke truncate, trigger, references on all tables in schema public from anon, authenticated, service_role;

alter default privileges for role postgres in schema public
    revoke truncate, trigger, references on tables from anon, authenticated, service_role;

create or replace function public.nds_prevent_production_truncate()
returns trigger
language plpgsql
security definer
set search_path = public
as $function$
begin
    raise exception using
        errcode = '42501',
        message = format(
            'NDSAPP_PRODUCTION_TRUNCATE_BLOCKED: refusing to truncate public.%I. Use an explicit reviewed migration to remove this guard before any intentional destructive maintenance.',
            tg_table_name
        );
end;
$function$;

revoke all on function public.nds_prevent_production_truncate() from public, anon, authenticated, service_role;

do $block$
declare
    v_table text;
begin
    foreach v_table in array array[
        'nds_profiles',
        'nds_licenses',
        'nds_license_activations',
        'nds_license_events',
        'nds_license_key_requests',
        'nds_license_billing_settings',
        'nds_stripe_subscriptions',
        'nds_plugin_usage_events',
        'nds_plugin_usage_counters',
        'nds_plugin_access_events',
        'nds_plugin_trials',
        'nds_payg_invoices',
        'nds_payg_billing_runs',
        'nds_plugins',
        'nds_plans',
        'nds_products',
        'nds_email_membership_policies'
    ]
    loop
        if to_regclass(format('public.%I', v_table)) is not null then
            execute format('drop trigger if exists trg_nds_prevent_production_truncate on public.%I', v_table);
            execute format(
                'create trigger trg_nds_prevent_production_truncate before truncate on public.%I for each statement execute function public.nds_prevent_production_truncate()',
                v_table
            );
        end if;
    end loop;
end;
$block$;
