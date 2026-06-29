begin;

-- Enrich v2 plugin usage responses with current free-usage counter state.
-- This lets Revit learn locally when a paid plugin has reached its free-use limit
-- without doing a blocking plugin-access HTTP check inside Execute.

create or replace function public.nds_report_plugin_usage_v2(
    p_activation_id uuid,
    p_machine_hash text,
    p_plugin_id text,
    p_execution_id uuid,
    p_execution_status text,
    p_ndsapp_version text default null,
    p_revit_version text default null,
    p_language text default null,
    p_duration_ms integer default null,
    p_selected_elements_count integer default null,
    p_processed_elements_count integer default null,
    p_created_elements_count integer default null,
    p_modified_elements_count integer default null,
    p_deleted_elements_count integer default null,
    p_input_count integer default null,
    p_output_count integer default null,
    p_complexity_bucket text default null,
    p_model_size_bucket text default null,
    p_error_code text default null,
    p_error_hash text default null,
    p_metrics jsonb default '{}'::jsonb,
    p_metadata jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
    v_result jsonb;
    v_usage_event_id bigint;
    v_metrics jsonb := '{}'::jsonb;
    v_metadata jsonb := '{}'::jsonb;

    v_license_id uuid;
    v_counter record;
    v_access_result jsonb := '{}'::jsonb;

    v_free_usage_count integer;
    v_free_usage_limit integer;
    v_remaining_free_uses integer;
    v_limit_reached_at timestamptz;
begin
    v_result := public.nds_report_plugin_usage(
        p_activation_id,
        p_machine_hash,
        p_plugin_id,
        p_execution_id,
        p_execution_status
    );

    v_usage_event_id := nullif(v_result ->> 'usage_event_id', '')::bigint;

    if p_metrics is not null and jsonb_typeof(p_metrics) = 'object' then
        v_metrics := p_metrics;
    end if;

    if p_metadata is not null and jsonb_typeof(p_metadata) = 'object' then
        v_metadata := p_metadata;
    end if;

    if v_usage_event_id is not null then
        update public.nds_plugin_usage_events
        set
            ndsapp_version = nullif(trim(p_ndsapp_version), ''),
            revit_version = nullif(trim(p_revit_version), ''),
            language = nullif(trim(p_language), ''),
            duration_ms = case
                when p_duration_ms is not null and p_duration_ms >= 0 then p_duration_ms
                else null
            end,
            selected_elements_count = case
                when p_selected_elements_count is not null and p_selected_elements_count >= 0 then p_selected_elements_count
                else null
            end,
            processed_elements_count = case
                when p_processed_elements_count is not null and p_processed_elements_count >= 0 then p_processed_elements_count
                else null
            end,
            created_elements_count = case
                when p_created_elements_count is not null and p_created_elements_count >= 0 then p_created_elements_count
                else null
            end,
            modified_elements_count = case
                when p_modified_elements_count is not null and p_modified_elements_count >= 0 then p_modified_elements_count
                else null
            end,
            deleted_elements_count = case
                when p_deleted_elements_count is not null and p_deleted_elements_count >= 0 then p_deleted_elements_count
                else null
            end,
            input_count = case
                when p_input_count is not null and p_input_count >= 0 then p_input_count
                else null
            end,
            output_count = case
                when p_output_count is not null and p_output_count >= 0 then p_output_count
                else null
            end,
            complexity_bucket = case
                when lower(nullif(trim(p_complexity_bucket), '')) in ('low', 'medium', 'high', 'unknown')
                    then lower(nullif(trim(p_complexity_bucket), ''))
                else null
            end,
            model_size_bucket = case
                when lower(nullif(trim(p_model_size_bucket), '')) in ('small', 'medium', 'large', 'unknown')
                    then lower(nullif(trim(p_model_size_bucket), ''))
                else null
            end,
            error_code = nullif(trim(p_error_code), ''),
            error_hash = nullif(trim(p_error_hash), ''),
            metrics = v_metrics,
            metadata = v_metadata
        where id = v_usage_event_id;

        v_result := v_result || jsonb_build_object(
            'usage_payload_version', 2,
            'usage_event_enriched', true
        );
    else
        v_result := v_result || jsonb_build_object(
            'usage_payload_version', 2,
            'usage_event_enriched', false
        );
    end if;

    select a.license_id
    into v_license_id
    from public.nds_license_activations a
    where a.id = p_activation_id
      and a.machine_hash = p_machine_hash
    limit 1;

    if v_license_id is not null then
        select
            c.successful_usage_count,
            c.free_usage_limit,
            greatest(c.free_usage_limit - c.successful_usage_count, 0) as remaining_free_uses,
            c.limit_reached_at
        into v_counter
        from public.nds_plugin_usage_counters c
        where c.license_id = v_license_id
          and c.plugin_id = p_plugin_id;

        if found then
            v_free_usage_count := coalesce(v_counter.successful_usage_count, 0);
            v_free_usage_limit := coalesce(v_counter.free_usage_limit, 10);
            v_remaining_free_uses := coalesce(v_counter.remaining_free_uses, 0);
            v_limit_reached_at := v_counter.limit_reached_at;
        end if;
    end if;

    if jsonb_typeof(v_result -> 'access_result') = 'object' then
        v_access_result := v_result -> 'access_result';
    end if;

    v_free_usage_count := coalesce(
        v_free_usage_count,
        nullif(v_access_result ->> 'free_usage_count', '')::integer
    );

    v_free_usage_limit := coalesce(
        v_free_usage_limit,
        nullif(v_access_result ->> 'free_usage_limit', '')::integer,
        10
    );

    v_remaining_free_uses := coalesce(
        v_remaining_free_uses,
        nullif(v_access_result ->> 'remaining_free_uses', '')::integer
    );

    if v_free_usage_count is not null then
        v_remaining_free_uses := coalesce(
            v_remaining_free_uses,
            greatest(v_free_usage_limit - v_free_usage_count, 0)
        );

        v_result := v_result || jsonb_build_object(
            'free_usage_count', v_free_usage_count,
            'free_usage_limit', v_free_usage_limit,
            'remaining_free_uses', v_remaining_free_uses,
            'remaining_free_uses_after_success', v_remaining_free_uses,
            'limit_reached_at', v_limit_reached_at
        );
    end if;

    return v_result;
end;
$function$;

commit;