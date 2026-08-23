-- Keep the pre-IBV RPC implementations internal.
--
-- The public wrapper functions validate the IBV_NO_CHARGE membership before
-- delegating to these helpers. Direct execution would bypass that contract, so
-- only the database owner/service path should be able to invoke them.

begin;

revoke all on function public.nds_check_plugin_access_base(uuid,text,text) from public;
revoke all on function public.nds_check_plugin_access_base(uuid,text,text) from anon;
revoke all on function public.nds_check_plugin_access_base(uuid,text,text) from authenticated;

revoke all on function public.nds_get_billing_status_context_base(uuid,text) from public;
revoke all on function public.nds_get_billing_status_context_base(uuid,text) from anon;
revoke all on function public.nds_get_billing_status_context_base(uuid,text) from authenticated;

revoke all on function public.nds_activate_payg_postpaid_from_setup_base(uuid,text,text,text,text,text) from public;
revoke all on function public.nds_activate_payg_postpaid_from_setup_base(uuid,text,text,text,text,text) from anon;
revoke all on function public.nds_activate_payg_postpaid_from_setup_base(uuid,text,text,text,text,text) from authenticated;

commit;
