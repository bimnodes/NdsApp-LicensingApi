-- Cover the foreign keys introduced by self-service license key issuance.

begin;

create index if not exists idx_nds_email_membership_policies_plan
    on public.nds_email_membership_policies (plan_id);

create index if not exists idx_nds_license_key_requests_license
    on public.nds_license_key_requests (license_id);

commit;
