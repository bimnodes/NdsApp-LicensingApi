begin;

insert into public.nds_plugins (
  plugin_id,
  folder_path,
  display_name,
  access_type,
  included_in_pro,
  is_active,
  trial_days,
  updated_at
)
values (
  'standard_transfer',
  'NdsApp.Core/Features/Documentation/StandardTransfer',
  'Standard Transfer',
  'paid',
  true,
  true,
  0,
  now()
)
on conflict (plugin_id) do update
set
  folder_path = excluded.folder_path,
  display_name = excluded.display_name,
  access_type = 'paid',
  included_in_pro = true,
  is_active = true,
  trial_days = 0,
  updated_at = now();

commit;
