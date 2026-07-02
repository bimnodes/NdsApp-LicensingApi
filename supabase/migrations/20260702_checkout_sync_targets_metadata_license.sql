-- Version the production fix for Stripe Checkout started from Revit/NdsApp.
-- The checkout metadata can include ndsapp_license_id.
-- When present, Stripe subscription sync must update that existing license
-- instead of creating a separate Pro license for the same email.

create or replace function public.nds_sync_stripe_subscription(
    p_email text,
    p_stripe_customer_id text,
    p_stripe_subscription_id text,
    p_stripe_price_id text,
    p_stripe_status text,
    p_current_period_start timestamp with time zone default null::timestamp with time zone,
    p_current_period_end timestamp with time zone default null::timestamp with time zone,
    p_checkout_session_id text default null::text,
    p_raw_data jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'extensions'
as $function$
declare
    v_email text;
    v_customer_id text;
    v_subscription_id text;
    v_price_id text;

    v_metadata_license_id uuid;
    v_profile_id uuid;
    v_product_id uuid;
    v_plan_id uuid;
    v_plan_billing_interval text;
    v_max_devices integer;

    v_license_id uuid;
    v_license_status public.nds_license_status;
    v_valid_until timestamp with time zone;
    v_fallback_valid_until timestamp with time zone;

    v_plain_license_key text;
    v_license_key_hash text;
    v_license_key_prefix text;
    v_license_key_last4 text;
    v_created boolean := false;
begin
    v_email := lower(nullif(trim(p_email), ''));
    v_customer_id := nullif(trim(p_stripe_customer_id), '');
    v_subscription_id := nullif(trim(p_stripe_subscription_id), '');
    v_price_id := nullif(trim(p_stripe_price_id), '');

    begin
        v_metadata_license_id := nullif(p_raw_data #>> '{metadata,ndsapp_license_id}', '')::uuid;
    exception
        when invalid_text_representation then
            v_metadata_license_id := null;
    end;

    if v_subscription_id is null then
        return jsonb_build_object(
            'success', false,
            'code', 'stripe_subscription_id_required',
            'message', 'Stripe subscription id is required.'
        );
    end if;

    if v_email is null then
        select email
        into v_email
        from public.nds_stripe_subscriptions
        where stripe_subscription_id = v_subscription_id
        limit 1;
    end if;

    if v_email is null and v_metadata_license_id is not null then
        select lower(email)
        into v_email
        from public.nds_licenses
        where id = v_metadata_license_id
        limit 1;
    end if;

    if v_email is null then
        select email
        into v_email
        from public.nds_licenses
        where stripe_subscription_id = v_subscription_id
        limit 1;
    end if;

    if v_email is null then
        return jsonb_build_object(
            'success', false,
            'code', 'email_required',
            'message', 'Email is required to create or update a license.'
        );
    end if;

    if v_price_id is null then
        select stripe_price_id
        into v_price_id
        from public.nds_stripe_subscriptions
        where stripe_subscription_id = v_subscription_id
        limit 1;
    end if;

    if v_price_id is null then
        return jsonb_build_object(
            'success', false,
            'code', 'stripe_price_id_required',
            'message', 'Stripe price id is required.'
        );
    end if;

    select
        id,
        product_id,
        billing_interval,
        max_devices
    into
        v_plan_id,
        v_product_id,
        v_plan_billing_interval,
        v_max_devices
    from public.nds_plans
    where stripe_price_id = v_price_id
      and is_active = true
    limit 1;

    if v_plan_id is null then
        return jsonb_build_object(
            'success', false,
            'code', 'plan_not_found',
            'message', 'No active plan was found for this Stripe price id.',
            'stripe_price_id', v_price_id
        );
    end if;

    v_fallback_valid_until :=
        case lower(coalesce(v_plan_billing_interval, ''))
            when 'month' then now() + interval '1 month'
            when 'year' then now() + interval '1 year'
            else now() + interval '1 year'
        end;

    select id
    into v_profile_id
    from public.nds_profiles
    where lower(email) = v_email
    limit 1;

    if v_profile_id is not null and v_customer_id is not null then
        update public.nds_profiles
        set
            stripe_customer_id = v_customer_id,
            updated_at = now()
        where id = v_profile_id;
    end if;

    v_license_status :=
        case lower(coalesce(p_stripe_status, ''))
            when 'trialing' then 'trial'::public.nds_license_status
            when 'active' then 'active'::public.nds_license_status
            when 'past_due' then 'past_due'::public.nds_license_status
            when 'unpaid' then 'past_due'::public.nds_license_status
            when 'canceled' then 'cancelled'::public.nds_license_status
            when 'cancelled' then 'cancelled'::public.nds_license_status
            when 'incomplete_expired' then 'expired'::public.nds_license_status
            else 'pending_payment'::public.nds_license_status
        end;

    v_valid_until :=
        case
            when v_license_status in ('active', 'trial') then coalesce(p_current_period_end, v_fallback_valid_until)
            when v_license_status in ('cancelled', 'expired') then coalesce(p_current_period_end, now())
            else p_current_period_end
        end;

    update public.nds_stripe_subscriptions
    set
        stripe_customer_id = coalesce(v_customer_id, stripe_customer_id),
        stripe_price_id = v_price_id,
        email = v_email,
        status = coalesce(p_stripe_status, status),
        current_period_start = p_current_period_start,
        current_period_end = p_current_period_end,
        raw_data = coalesce(p_raw_data, '{}'::jsonb),
        updated_at = now()
    where stripe_subscription_id = v_subscription_id;

    if not found then
        insert into public.nds_stripe_subscriptions (
            stripe_subscription_id,
            stripe_customer_id,
            stripe_price_id,
            email,
            status,
            current_period_start,
            current_period_end,
            raw_data
        )
        values (
            v_subscription_id,
            coalesce(v_customer_id, ''),
            v_price_id,
            v_email,
            coalesce(p_stripe_status, 'unknown'),
            p_current_period_start,
            p_current_period_end,
            coalesce(p_raw_data, '{}'::jsonb)
        );
    end if;

    if v_metadata_license_id is not null then
        select id
        into v_license_id
        from public.nds_licenses
        where id = v_metadata_license_id
          and lower(email) = v_email
        limit 1;
    end if;

    if v_metadata_license_id is not null and v_license_id is null then
        return jsonb_build_object(
            'success', false,
            'code', 'checkout_license_not_found_or_email_mismatch',
            'message', 'Checkout metadata license id does not match an existing license for this email.',
            'metadata_license_id', v_metadata_license_id,
            'email', v_email
        );
    end if;

    if v_license_id is null then
        select id
        into v_license_id
        from public.nds_licenses
        where stripe_subscription_id = v_subscription_id
        limit 1;
    end if;

    if v_license_id is null then
        v_plain_license_key :=
            'NDS-' ||
            upper(substring(encode(gen_random_bytes(4), 'hex') from 1 for 8)) ||
            '-' ||
            upper(substring(encode(gen_random_bytes(4), 'hex') from 1 for 8)) ||
            '-' ||
            upper(substring(encode(gen_random_bytes(4), 'hex') from 1 for 8));

        v_license_key_hash := encode(digest(v_plain_license_key, 'sha256'), 'hex');
        v_license_key_prefix := substring(v_plain_license_key from 1 for 8);
        v_license_key_last4 := right(v_plain_license_key, 4);

        insert into public.nds_licenses (
            user_id,
            email,
            product_id,
            plan_id,
            license_key_hash,
            license_key_prefix,
            license_key_last4,
            status,
            max_devices,
            valid_from,
            valid_until,
            stripe_customer_id,
            stripe_subscription_id,
            stripe_checkout_session_id
        )
        values (
            v_profile_id,
            v_email,
            v_product_id,
            v_plan_id,
            v_license_key_hash,
            v_license_key_prefix,
            v_license_key_last4,
            v_license_status,
            v_max_devices,
            now(),
            v_valid_until,
            v_customer_id,
            v_subscription_id,
            p_checkout_session_id
        )
        returning id into v_license_id;

        v_created := true;
    else
        update public.nds_licenses
        set
            user_id = coalesce(user_id, v_profile_id),
            email = v_email,
            product_id = v_product_id,
            plan_id = v_plan_id,
            status = v_license_status,
            max_devices = v_max_devices,
            valid_until = coalesce(v_valid_until, valid_until),
            stripe_customer_id = coalesce(v_customer_id, stripe_customer_id),
            stripe_subscription_id = v_subscription_id,
            stripe_checkout_session_id = coalesce(p_checkout_session_id, stripe_checkout_session_id),
            updated_at = now()
        where id = v_license_id;
    end if;

    if v_license_status in ('cancelled', 'expired') then
        update public.nds_license_activations
        set
            status = 'deactivated'::public.nds_activation_status,
            deactivated_at = coalesce(deactivated_at, now()),
            updated_at = now()
        where license_id = v_license_id
          and status = 'active'::public.nds_activation_status;
    end if;

    insert into public.nds_license_events (
        license_id,
        event_type,
        event_source,
        metadata
    )
    values (
        v_license_id,
        case when v_created then 'stripe.license.created' else 'stripe.license.updated' end,
        'stripe',
        jsonb_build_object(
            'email', v_email,
            'stripe_customer_id', v_customer_id,
            'stripe_subscription_id', v_subscription_id,
            'stripe_price_id', v_price_id,
            'stripe_status', p_stripe_status,
            'license_status', v_license_status,
            'created', v_created,
            'plan_billing_interval', v_plan_billing_interval,
            'fallback_valid_until_used', p_current_period_end is null,
            'metadata_license_id', v_metadata_license_id
        )
    );

    return jsonb_build_object(
        'success', true,
        'code', case when v_created then 'license_created' else 'license_updated' end,
        'message', case when v_created then 'License created from Stripe subscription.' else 'License updated from Stripe subscription.' end,
        'license_id', v_license_id,
        'email', v_email,
        'status', v_license_status,
        'max_devices', v_max_devices,
        'valid_until', v_valid_until,
        'stripe_subscription_id', v_subscription_id,
        'plain_license_key', case when v_created then v_plain_license_key else null end,
        'metadata_license_id', v_metadata_license_id
    );
end;
$function$;