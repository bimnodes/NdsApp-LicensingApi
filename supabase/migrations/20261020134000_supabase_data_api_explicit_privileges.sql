begin;

-- Supabase is removing automatic Data API grants for newly created objects in
-- existing projects. Keep NdsApp independent from platform defaults by making
-- the production posture explicit now.
alter default privileges for role postgres in schema public
  revoke select, insert, update, delete on tables from anon, authenticated, service_role;

alter default privileges for role postgres in schema public
  revoke execute on functions from anon, authenticated, service_role;

alter default privileges for role postgres in schema public
  revoke usage, select on sequences from anon, authenticated, service_role;

alter default privileges for role postgres in schema public
  revoke execute on functions from public;

-- Server-facing RPCs are reached by NdsApp-LicensingApi with the service role.
-- Do not expose them directly to Data API client roles.
revoke execute on function public.nds_activate_license(text,text,text,text,text,text)
  from public, anon, authenticated;
grant execute on function public.nds_activate_license(text,text,text,text,text,text)
  to service_role;

revoke execute on function public.nds_check_activation(uuid,text)
  from public, anon, authenticated;
grant execute on function public.nds_check_activation(uuid,text)
  to service_role;

revoke execute on function public.nds_check_plugin_access(uuid,text,text)
  from public, anon, authenticated;
grant execute on function public.nds_check_plugin_access(uuid,text,text)
  to service_role;

revoke execute on function public.nds_get_billing_status_context(uuid,text)
  from public, anon, authenticated;
grant execute on function public.nds_get_billing_status_context(uuid,text)
  to service_role;

revoke execute on function public.nds_get_customer_portal_context(uuid,text)
  from public, anon, authenticated;
grant execute on function public.nds_get_customer_portal_context(uuid,text)
  to service_role;

revoke execute on function public.nds_issue_license_key_for_email(text)
  from public, anon, authenticated;
grant execute on function public.nds_issue_license_key_for_email(text)
  to service_role;

revoke execute on function public.nds_report_plugin_usage(uuid,text,text,uuid,text)
  from public, anon, authenticated;
grant execute on function public.nds_report_plugin_usage(uuid,text,text,uuid,text)
  to service_role;

revoke execute on function public.nds_report_plugin_usage_v2(
  uuid,text,text,uuid,text,text,text,text,integer,integer,integer,integer,
  integer,integer,integer,integer,text,text,text,text,jsonb,jsonb
) from public, anon, authenticated;
grant execute on function public.nds_report_plugin_usage_v2(
  uuid,text,text,uuid,text,text,text,text,integer,integer,integer,integer,
  integer,integer,integer,integer,text,text,text,text,jsonb,jsonb
) to service_role;

revoke execute on function public.nds_set_email_membership_policy_enabled(text,boolean)
  from public, anon, authenticated;
grant execute on function public.nds_set_email_membership_policy_enabled(text,boolean)
  to service_role;

revoke execute on function public.nds_sync_stripe_subscription(
  text,text,text,text,text,timestamptz,timestamptz,text,jsonb
) from public, anon, authenticated;
grant execute on function public.nds_sync_stripe_subscription(
  text,text,text,text,text,timestamptz,timestamptz,text,jsonb
) to service_role;

-- Trigger/event-trigger helpers and implementation-only RPCs must never be
-- callable through PostgREST/GraphQL. Existing triggers continue to execute
-- under their normal PostgreSQL trigger context.
revoke execute on function public.nds_apply_email_membership_plan()
  from public, anon, authenticated, service_role;
revoke execute on function public.nds_check_plugin_access_base(uuid,text,text)
  from public, anon, authenticated, service_role;
revoke execute on function public.nds_get_billing_status_context_base(uuid,text)
  from public, anon, authenticated, service_role;
revoke execute on function public.nds_handle_auth_user_email_updated()
  from public, anon, authenticated, service_role;
revoke execute on function public.nds_handle_new_auth_user()
  from public, anon, authenticated, service_role;
revoke execute on function public.nds_plugins_set_updated_at()
  from public, anon, authenticated, service_role;
revoke execute on function public.nds_prevent_production_truncate()
  from public, anon, authenticated, service_role;
revoke execute on function public.nds_record_plugin_access_event(uuid,uuid,text,text,jsonb)
  from public, anon, authenticated, service_role;
revoke execute on function public.nds_set_updated_at()
  from public, anon, authenticated, service_role;
revoke execute on function public.nds_usage_apply_outcome_metadata()
  from public, anon, authenticated, service_role;
revoke execute on function public.rls_auto_enable()
  from public, anon, authenticated, service_role;

commit;
