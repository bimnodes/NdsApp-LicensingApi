do $$
declare
  v_expected integer := 6;
  v_found integer;
begin
  select count(*)
  into v_found
  from public.nds_plugins
  where plugin_id in (
    'ibv_wuerfel',
    'nds_jump_to',
    'no_defined_system_types',
    'nds_social_hub',
    'login',
    'nds_update'
  );

  if v_found <> v_expected then
    raise exception 'Common-panel commercial policy migration expected % target plugin rows, found %.', v_expected, v_found;
  end if;
end
$$;

update public.nds_plugins
set
  access_type = 'paid',
  included_in_pro = true,
  trial_days = 0,
  updated_at = now()
where plugin_id in (
  'ibv_wuerfel',
  'nds_jump_to',
  'no_defined_system_types',
  'nds_social_hub',
  'login',
  'nds_update'
);
