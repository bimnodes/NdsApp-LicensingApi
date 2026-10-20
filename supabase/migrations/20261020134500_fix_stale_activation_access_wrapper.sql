begin;

-- The IBV wrapper must delegate to the base access implementation when an
-- activation or its license cannot be loaded. Referencing fields on an
-- unassigned PL/pgSQL record raises SQLSTATE 55000 and caused stale queued usage
-- reports to return HTTP 500 instead of the normal activation_not_found result.
create or replace function public.nds_check_plugin_access(
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
    v_plugin_exists boolean := false;
    v_counter record;
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
        return public.nds_check_plugin_access_base(
            p_activation_id,
            p_machine_hash,
            p_plugin_id
        );
    end if;

    select
        l.id,
        l.status::text as license_status,
        l.valid_until,
        p.code as plan_code
    into v_license
    from public.nds_licenses l
    left join public.nds_plans p on p.id = l.plan_id
    where l.id = v_activation.license_id;

    if not found then
        return public.nds_check_plugin_access_base(
            p_activation_id,
            p_machine_hash,
            p_plugin_id
        );
    end if;

    if v_license.plan_code = 'IBV_NO_CHARGE'
       and v_activation.activation_status = 'active'
       and v_activation.machine_hash = p_machine_hash
       and v_license.license_status = 'active'
       and (v_license.valid_until is null or v_license.valid_until > v_now) then
        select exists (
            select 1
            from public.nds_plugins p
            where p.plugin_id = p_plugin_id
              and p.is_active = true
        )
        into v_plugin_exists;

        if v_plugin_exists then
            select
                c.successful_usage_count,
                c.free_usage_limit
            into v_counter
            from public.nds_plugin_usage_counters c
            where c.license_id = v_license.id
              and c.plugin_id = p_plugin_id;

            if found then
                v_free_usage_count := coalesce(v_counter.successful_usage_count, 0);
                v_free_usage_limit := coalesce(v_counter.free_usage_limit, 10);
            end if;

            v_remaining_free_uses := greatest(
                v_free_usage_limit - v_free_usage_count,
                0
            );

            update public.nds_license_activations
            set
                last_seen_at = v_now,
                updated_at = v_now
            where id = v_activation.id;

            v_result := jsonb_build_object(
                'success', true,
                'allowed', true,
                'code', 'allowed_ibv_no_charge',
                'billing_mode', 'no_charge',
                'plugin_id', p_plugin_id,
                'price_cents', 0,
                'free_usage_count', v_free_usage_count,
                'free_usage_limit', v_free_usage_limit,
                'remaining_free_uses', v_remaining_free_uses,
                'remaining_free_uses_after_success', v_remaining_free_uses
            );

            perform public.nds_record_plugin_access_event(
                v_activation.id,
                v_license.id,
                p_machine_hash,
                p_plugin_id,
                v_result
            );

            return v_result;
        end if;
    end if;

    return public.nds_check_plugin_access_base(
        p_activation_id,
        p_machine_hash,
        p_plugin_id
    );
end;
$function$;

revoke execute on function public.nds_check_plugin_access(uuid,text,text)
    from public, anon, authenticated;
grant execute on function public.nds_check_plugin_access(uuid,text,text)
    to service_role;

-- These trigger helpers are not API endpoints. Pin their search path so the
-- database linter no longer reports mutable-search-path warnings.
alter function public.nds_set_updated_at()
    set search_path to pg_catalog;

alter function public.nds_plugins_set_updated_at()
    set search_path to pg_catalog;

commit;
