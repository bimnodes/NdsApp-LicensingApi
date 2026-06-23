using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;
using Microsoft.Extensions.Options;
using NdsApp.LicensingApi.Models;
using NdsApp.LicensingApi.Options;

namespace NdsApp.LicensingApi.Services;

public sealed class SupabaseCustomerPortalContextService : ICustomerPortalContextService
{
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);

    private readonly HttpClient _httpClient;
    private readonly SupabaseOptions _options;

    public SupabaseCustomerPortalContextService(HttpClient httpClient, IOptions<SupabaseOptions> options)
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

    public async Task<JsonElement> GetContextAsync(CreateCustomerPortalSessionRequest request, CancellationToken cancellationToken)
    {
        var payload = new Dictionary<string, object?>
        {
            ["p_activation_id"] = request.ActivationId,
            ["p_machine_hash"] = request.MachineHash
        };

        using var response = await _httpClient.PostAsJsonAsync(
            "/rest/v1/rpc/nds_get_customer_portal_context",
            payload,
            JsonOptions,
            cancellationToken);

        var responseBody = await response.Content.ReadAsStringAsync(cancellationToken);

        if (!response.IsSuccessStatusCode)
        {
            throw new SupabaseRpcException("Supabase RPC 'nds_get_customer_portal_context' failed.", (int)response.StatusCode, responseBody);
        }

        using var document = JsonDocument.Parse(responseBody);
        return document.RootElement.Clone();
    }
}
