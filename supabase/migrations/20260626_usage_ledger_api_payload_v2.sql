begin;

-- =========================================================
-- NdsApp Usage Ledger API Payload v2
-- Adds a v2 RPC wrapper for plugin usage metrics.
-- Compatible:
-- - keeps nds_report_plugin_usage unchanged
-- - /api/licensing/plugin-usage can move to v2 safely
-- - old client payloads still work because new params default to null
-- =========================================================

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

    return v_result;
end;
$function$;

commit;
