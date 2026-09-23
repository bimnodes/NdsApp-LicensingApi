-- nds-migration-governance: restored-applied-migration
-- Restored on 2026-09-23 from the BIM Nodes Licensing production migration history.
-- Production migration: 20260903083200_harden_stripe_subscription_license_sync.
-- This file preserves SQL that was already applied in production. Do not edit it;
-- add a new forward migration for future changes.

CREATE UNIQUE INDEX IF NOT EXISTS uq_nds_licenses_stripe_subscription_id
ON public.nds_licenses (stripe_subscription_id)
WHERE stripe_subscription_id IS NOT NULL;

CREATE OR REPLACE FUNCTION public.nds_sync_stripe_subscription(
    p_email text,
    p_stripe_customer_id text,
    p_stripe_subscription_id text,
    p_stripe_price_id text,
    p_stripe_status text,
    p_current_period_start timestamp with time zone DEFAULT NULL::timestamp with time zone,
    p_current_period_end timestamp with time zone DEFAULT NULL::timestamp with time zone,
    p_checkout_session_id text DEFAULT NULL::text,
    p_raw_data jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions'
AS $function$
DECLARE
    v_email text;
    v_customer_id text;
    v_subscription_id text;
    v_price_id text;

    v_metadata_license_id uuid;
    v_metadata_license_id_text text;
    v_existing_subscription_raw_data jsonb;
    v_subscription_preexisting boolean := false;
    v_is_renewal boolean := false;

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
BEGIN
    v_email := lower(nullif(trim(p_email), ''));
    v_customer_id := nullif(trim(p_stripe_customer_id), '');
    v_subscription_id := nullif(trim(p_stripe_subscription_id), '');
    v_price_id := nullif(trim(p_stripe_price_id), '');

    IF v_subscription_id IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'stripe_subscription_id_required',
            'message', 'Stripe subscription id is required.'
        );
    END IF;

    SELECT raw_data
    INTO v_existing_subscription_raw_data
    FROM public.nds_stripe_subscriptions
    WHERE stripe_subscription_id = v_subscription_id
    LIMIT 1;

    v_subscription_preexisting := FOUND;
    v_is_renewal := lower(coalesce(p_raw_data ->> 'billing_reason', '')) = 'subscription_cycle';

    -- Stripe sends ndsapp_license_id in different locations depending on the event object.
    -- Support Subscription metadata, Invoice parent.subscription_details.metadata,
    -- Invoice line-item metadata, and the previously stored raw Stripe object.
    v_metadata_license_id_text := coalesce(
        nullif(p_raw_data #>> '{metadata,ndsapp_license_id}', ''),
        nullif(p_raw_data #>> '{parent,subscription_details,metadata,ndsapp_license_id}', ''),
        nullif(p_raw_data #>> '{lines,data,0,metadata,ndsapp_license_id}', ''),
        nullif(v_existing_subscription_raw_data #>> '{metadata,ndsapp_license_id}', ''),
        nullif(v_existing_subscription_raw_data #>> '{parent,subscription_details,metadata,ndsapp_license_id}', ''),
        nullif(v_existing_subscription_raw_data #>> '{lines,data,0,metadata,ndsapp_license_id}', '')
    );

    IF v_metadata_license_id_text IS NOT NULL THEN
        BEGIN
            v_metadata_license_id := v_metadata_license_id_text::uuid;
        EXCEPTION
            WHEN invalid_text_representation THEN
                v_metadata_license_id := NULL;
        END;
    END IF;

    IF v_email IS NULL THEN
        SELECT email
        INTO v_email
        FROM public.nds_stripe_subscriptions
        WHERE stripe_subscription_id = v_subscription_id
        LIMIT 1;
    END IF;

    IF v_email IS NULL AND v_metadata_license_id IS NOT NULL THEN
        SELECT lower(email)
        INTO v_email
        FROM public.nds_licenses
        WHERE id = v_metadata_license_id
        LIMIT 1;
    END IF;

    IF v_email IS NULL THEN
        SELECT email
        INTO v_email
        FROM public.nds_licenses
        WHERE stripe_subscription_id = v_subscription_id
        LIMIT 1;
    END IF;

    IF v_email IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'email_required',
            'message', 'Email is required to create or update a license.'
        );
    END IF;

    IF v_price_id IS NULL THEN
        SELECT stripe_price_id
        INTO v_price_id
        FROM public.nds_stripe_subscriptions
        WHERE stripe_subscription_id = v_subscription_id
        LIMIT 1;
    END IF;

    IF v_price_id IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'stripe_price_id_required',
            'message', 'Stripe price id is required.'
        );
    END IF;

    SELECT id, product_id, billing_interval, max_devices
    INTO v_plan_id, v_product_id, v_plan_billing_interval, v_max_devices
    FROM public.nds_plans
    WHERE stripe_price_id = v_price_id
      AND is_active = true
    LIMIT 1;

    IF v_plan_id IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'plan_not_found',
            'message', 'No active plan was found for this Stripe price id.',
            'stripe_price_id', v_price_id
        );
    END IF;

    v_fallback_valid_until :=
        CASE lower(coalesce(v_plan_billing_interval, ''))
            WHEN 'month' THEN now() + interval '1 month'
            WHEN 'year' THEN now() + interval '1 year'
            ELSE now() + interval '1 year'
        END;

    SELECT id
    INTO v_profile_id
    FROM public.nds_profiles
    WHERE lower(email) = v_email
    LIMIT 1;

    IF v_profile_id IS NOT NULL AND v_customer_id IS NOT NULL THEN
        UPDATE public.nds_profiles
        SET stripe_customer_id = v_customer_id,
            updated_at = now()
        WHERE id = v_profile_id;
    END IF;

    v_license_status :=
        CASE lower(coalesce(p_stripe_status, ''))
            WHEN 'trialing' THEN 'trial'::public.nds_license_status
            WHEN 'active' THEN 'active'::public.nds_license_status
            WHEN 'past_due' THEN 'past_due'::public.nds_license_status
            WHEN 'unpaid' THEN 'past_due'::public.nds_license_status
            WHEN 'canceled' THEN 'cancelled'::public.nds_license_status
            WHEN 'cancelled' THEN 'cancelled'::public.nds_license_status
            WHEN 'incomplete_expired' THEN 'expired'::public.nds_license_status
            ELSE 'pending_payment'::public.nds_license_status
        END;

    v_valid_until :=
        CASE
            WHEN v_license_status IN ('active', 'trial') THEN coalesce(p_current_period_end, v_fallback_valid_until)
            WHEN v_license_status IN ('cancelled', 'expired') THEN coalesce(p_current_period_end, now())
            ELSE p_current_period_end
        END;

    -- Prefer the explicit license id that NdsApp attached to Checkout/Subscription metadata.
    IF v_metadata_license_id IS NOT NULL THEN
        SELECT id
        INTO v_license_id
        FROM public.nds_licenses
        WHERE id = v_metadata_license_id
          AND lower(email) = v_email
        LIMIT 1;
    END IF;

    -- If Stripe points at a license that no longer exists, never silently mint a replacement.
    IF v_metadata_license_id IS NOT NULL AND v_license_id IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'checkout_license_not_found_or_email_mismatch',
            'message', 'Checkout metadata license id does not match an existing license for this email. Automatic replacement is blocked.',
            'metadata_license_id', v_metadata_license_id,
            'email', v_email,
            'stripe_subscription_id', v_subscription_id
        );
    END IF;

    -- Existing subscription linkage is the next authoritative lookup.
    IF v_license_id IS NULL THEN
        SELECT id
        INTO v_license_id
        FROM public.nds_licenses
        WHERE stripe_subscription_id = v_subscription_id
        LIMIT 1;
    END IF;

    -- For a first-time upgrade where metadata was lost in transport, safely reuse exactly one
    -- unlinked active/trial license for the same email+product rather than creating a second license.
    IF v_license_id IS NULL AND NOT v_is_renewal AND NOT v_subscription_preexisting THEN
        SELECT min(id)
        INTO v_license_id
        FROM public.nds_licenses
        WHERE lower(email) = v_email
          AND product_id = v_product_id
          AND stripe_subscription_id IS NULL
          AND status IN (
              'active'::public.nds_license_status,
              'trial'::public.nds_license_status,
              'past_due'::public.nds_license_status,
              'pending_payment'::public.nds_license_status
          )
        HAVING count(*) = 1;
    END IF;

    -- A renewal or already-known Stripe subscription is never allowed to create a new license.
    IF v_license_id IS NULL AND (v_is_renewal OR v_subscription_preexisting) THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'existing_subscription_without_license',
            'message', 'Existing or renewing Stripe subscription has no valid license mapping. Automatic license creation is blocked.',
            'email', v_email,
            'stripe_subscription_id', v_subscription_id,
            'billing_reason', p_raw_data ->> 'billing_reason',
            'metadata_license_id', v_metadata_license_id
        );
    END IF;

    -- Persist Stripe subscription data only after license mapping has passed the safety checks.
    UPDATE public.nds_stripe_subscriptions
    SET stripe_customer_id = coalesce(v_customer_id, stripe_customer_id),
        stripe_price_id = v_price_id,
        email = v_email,
        status = coalesce(p_stripe_status, status),
        current_period_start = p_current_period_start,
        current_period_end = p_current_period_end,
        raw_data = coalesce(p_raw_data, '{}'::jsonb),
        updated_at = now()
    WHERE stripe_subscription_id = v_subscription_id;

    IF NOT FOUND THEN
        INSERT INTO public.nds_stripe_subscriptions (
            stripe_subscription_id,
            stripe_customer_id,
            stripe_price_id,
            email,
            status,
            current_period_start,
            current_period_end,
            raw_data
        )
        VALUES (
            v_subscription_id,
            coalesce(v_customer_id, ''),
            v_price_id,
            v_email,
            coalesce(p_stripe_status, 'unknown'),
            p_current_period_start,
            p_current_period_end,
            coalesce(p_raw_data, '{}'::jsonb)
        );
    END IF;

    IF v_license_id IS NULL THEN
        v_plain_license_key :=
            'NDS-' ||
            upper(substring(encode(gen_random_bytes(4), 'hex') from 1 for 8)) || '-' ||
            upper(substring(encode(gen_random_bytes(4), 'hex') from 1 for 8)) || '-' ||
            upper(substring(encode(gen_random_bytes(4), 'hex') from 1 for 8));

        v_license_key_hash := encode(digest(v_plain_license_key, 'sha256'), 'hex');
        v_license_key_prefix := substring(v_plain_license_key from 1 for 8);
        v_license_key_last4 := right(v_plain_license_key, 4);

        INSERT INTO public.nds_licenses (
            user_id, email, product_id, plan_id,
            license_key_hash, license_key_prefix, license_key_last4,
            status, max_devices, valid_from, valid_until,
            stripe_customer_id, stripe_subscription_id, stripe_checkout_session_id
        )
        VALUES (
            v_profile_id, v_email, v_product_id, v_plan_id,
            v_license_key_hash, v_license_key_prefix, v_license_key_last4,
            v_license_status, v_max_devices, now(), v_valid_until,
            v_customer_id, v_subscription_id, p_checkout_session_id
        )
        RETURNING id INTO v_license_id;

        v_created := true;
    ELSE
        UPDATE public.nds_licenses
        SET user_id = coalesce(user_id, v_profile_id),
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
        WHERE id = v_license_id;
    END IF;

    IF v_license_status IN ('cancelled', 'expired') THEN
        UPDATE public.nds_license_activations
        SET status = 'deactivated'::public.nds_activation_status,
            deactivated_at = coalesce(deactivated_at, now()),
            updated_at = now()
        WHERE license_id = v_license_id
          AND status = 'active'::public.nds_activation_status;
    END IF;

    INSERT INTO public.nds_license_events (
        license_id, event_type, event_source, metadata
    )
    VALUES (
        v_license_id,
        CASE WHEN v_created THEN 'stripe.license.created' ELSE 'stripe.license.updated' END,
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
            'fallback_valid_until_used', p_current_period_end IS NULL,
            'metadata_license_id', v_metadata_license_id,
            'billing_reason', p_raw_data ->> 'billing_reason'
        )
    );

    RETURN jsonb_build_object(
        'success', true,
        'code', CASE WHEN v_created THEN 'license_created' ELSE 'license_updated' END,
        'message', CASE WHEN v_created THEN 'License created from Stripe subscription.' ELSE 'License updated from Stripe subscription.' END,
        'license_id', v_license_id,
        'email', v_email,
        'status', v_license_status,
        'max_devices', v_max_devices,
        'valid_until', v_valid_until,
        'stripe_subscription_id', v_subscription_id,
        'plain_license_key', CASE WHEN v_created THEN v_plain_license_key ELSE NULL END,
        'metadata_license_id', v_metadata_license_id
    );
END;
$function$;
