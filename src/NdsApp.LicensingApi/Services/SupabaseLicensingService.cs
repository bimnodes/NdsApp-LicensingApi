using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;
using Microsoft.Extensions.Options;
using NdsApp.LicensingApi.Models;
using NdsApp.LicensingApi.Options;

namespace NdsApp.LicensingApi.Services;

public sealed class SupabaseLicensingService : ILicensingService
{
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);

    private readonly HttpClient _httpClient;
    private readonly SupabaseOptions _options;

    public SupabaseLicensingService(HttpClient httpClient, IOptions<SupabaseOptions> options)
    {
        _httpClient = httpClient;
        _options = options.Value;

        if (string.IsNullOrWhiteSpace(_options.Url))
        {
            throw new InvalidOperationException("Supabase URL is required.");
        }

        if (string.IsNullOrWhiteSpace(_options.ServiceRoleKey))
        {
            throw new InvalidOperationException("Supabase API key is required.");
        }

        _httpClient.BaseAddress = new Uri(_options.Url.TrimEnd('/'));
        _httpClient.DefaultRequestHeaders.Clear();
        _httpClient.DefaultRequestHeaders.Add("apikey", _options.ServiceRoleKey);
        _httpClient.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", _options.ServiceRoleKey);
    }

    public Task<JsonElement> ActivateAsync(ActivateLicenseRequest request, CancellationToken cancellationToken)
    {
        var payload = new Dictionary<string, object?>
        {
            ["p_email"] = request.Email,
            ["p_" + "license_key"] = request.LicenseKey,
            ["p_machine_hash"] = request.MachineHash,
            ["p_device_label"] = request.DeviceLabel,
            ["p_revit_version"] = request.RevitVersion,
            ["p_ndsapp_version"] = request.NdsAppVersion
        };

        return PostRpcAsync("nds_activate_license", payload, cancellationToken);
    }

    public Task<JsonElement> CheckAsync(CheckActivationRequest request, CancellationToken cancellationToken)
    {
        var payload = new Dictionary<string, object?>
        {
            ["p_activation_id"] = request.ActivationId,
            ["p_machine_hash"] = request.MachineHash
        };

        return PostRpcAsync("nds_check_activation", payload, cancellationToken);
    }

    public Task<JsonElement> SyncStripeSubscriptionAsync(StripeSubscriptionSyncRequest request, CancellationToken cancellationToken)
    {
        var rawData = request.RawData.ValueKind == JsonValueKind.Undefined
            ? new Dictionary<string, object?>()
            : request.RawData;

        var payload = new Dictionary<string, object?>
        {
            ["p_email"] = request.Email,
            ["p_stripe_customer_id"] = request.StripeCustomerId,
            ["p_stripe_subscription_id"] = request.StripeSubscriptionId,
            ["p_stripe_price_id"] = request.StripePriceId,
            ["p_stripe_status"] = request.StripeStatus,
            ["p_current_period_start"] = request.CurrentPeriodStart,
            ["p_current_period_end"] = request.CurrentPeriodEnd,
            ["p_checkout_session_id"] = request.CheckoutSessionId,
            ["p_raw_data"] = rawData
        };

        return PostRpcAsync("nds_sync_stripe_subscription", payload, cancellationToken);
    }

    private async Task<JsonElement> PostRpcAsync(string functionName, object payload, CancellationToken cancellationToken)
    {
        using var response = await _httpClient.PostAsJsonAsync(
            $"/rest/v1/rpc/{functionName}",
            payload,
            JsonOptions,
            cancellationToken);

        var responseBody = await response.Content.ReadAsStringAsync(cancellationToken);

        if (!response.IsSuccessStatusCode)
        {
            throw new SupabaseRpcException($"Supabase RPC '{functionName}' failed.", (int)response.StatusCode, responseBody);
        }

        using var document = JsonDocument.Parse(responseBody);
        return document.RootElement.Clone();
    }
}
