using System.Text.Json;
using Microsoft.AspNetCore.Mvc;
using NdsApp.LicensingApi.Models;
using NdsApp.LicensingApi.Services;

namespace NdsApp.LicensingApi.Controllers;

[ApiController]
[Route("api/licensing")]
public sealed class LicensingController : ControllerBase
{
    private readonly ILicensingService _licensingService;
    private readonly ILicenseKeyIssuanceService _licenseKeyIssuanceService;
    private readonly ILicenseKeyEmailService _licenseKeyEmailService;
    private readonly ILogger<LicensingController> _logger;

    public LicensingController(
        ILicensingService licensingService,
        ILicenseKeyIssuanceService licenseKeyIssuanceService,
        ILicenseKeyEmailService licenseKeyEmailService,
        ILogger<LicensingController> logger)
    {
        _licensingService = licensingService;
        _licenseKeyIssuanceService = licenseKeyIssuanceService;
        _licenseKeyEmailService = licenseKeyEmailService;
        _logger = logger;
    }

    [HttpPost("request-key")]
    public async Task<IActionResult> RequestLicenseKey(
        [FromBody] RequestLicenseKeyRequest request,
        CancellationToken cancellationToken)
    {
        if (request is null || string.IsNullOrWhiteSpace(request.Email))
        {
            return BadRequest(new
            {
                success = false,
                code = "invalid_email",
                message = "A valid email address is required."
            });
        }

        try
        {
            var result = await _licenseKeyIssuanceService.IssueAsync(request.Email, cancellationToken);
            var success = GetBoolean(result, "success") == true;
            var code = GetString(result, "code") ?? "license_key_request_failed";

            if (!success)
            {
                if (string.Equals(code, "license_key_request_rate_limited", StringComparison.OrdinalIgnoreCase))
                {
                    var retryAfterSeconds = GetInt32(result, "retry_after_seconds") ?? 120;
                    Response.Headers.RetryAfter = retryAfterSeconds.ToString();

                    return StatusCode(StatusCodes.Status429TooManyRequests, new
                    {
                        success = false,
                        code,
                        message = GetString(result, "message") ?? "Please wait before requesting another license key.",
                        retry_after_seconds = retryAfterSeconds
                    });
                }

                return BadRequest(new
                {
                    success = false,
                    code,
                    message = GetString(result, "message") ?? "The license key could not be issued."
                });
            }

            var licenseKey = GetString(result, "plain_license_key");
            var email = GetString(result, "email");

            if (string.IsNullOrWhiteSpace(licenseKey) || string.IsNullOrWhiteSpace(email))
            {
                _logger.LogError("License key issuance succeeded but delivery data was missing.");
                return StatusCode(StatusCodes.Status502BadGateway, new
                {
                    success = false,
                    code = "license_key_delivery_data_missing",
                    message = "The license key was issued but could not be prepared for email delivery."
                });
            }

            await _licenseKeyEmailService.SendAsync(new LicenseKeyEmailRequest
            {
                ToEmail = email,
                LicenseKey = licenseKey,
                PlanCode = GetString(result, "plan_code"),
                PlanName = GetString(result, "plan_name"),
                MaxDevices = GetInt32(result, "max_devices"),
                ValidUntil = GetDateTimeOffset(result, "valid_until")
            }, cancellationToken);

            return Ok(new
            {
                success = true,
                code = "license_key_email_sent",
                message = "License key sent to the requested email address.",
                plan_code = GetString(result, "plan_code")
            });
        }
        catch (SupabaseRpcException ex)
        {
            _logger.LogError(ex, "Supabase license key issuance RPC failed with status {StatusCode}.", ex.StatusCode);
            return StatusCode(StatusCodes.Status502BadGateway, new
            {
                success = false,
                code = "supabase_rpc_failed",
                message = "License key issuance service failed."
            });
        }
        catch (InvalidOperationException ex)
        {
            _logger.LogError(ex, "License key email delivery failed.");
            return StatusCode(StatusCodes.Status502BadGateway, new
            {
                success = false,
                code = "license_key_email_failed",
                message = "The license key was issued, but the email could not be sent. Request a new key and try again."
            });
        }
    }

    [HttpPost("activate")]
    public async Task<IActionResult> Activate(
        [FromBody] ActivateLicenseRequest request,
        CancellationToken cancellationToken)
    {
        if (string.IsNullOrWhiteSpace(request.Email) ||
            string.IsNullOrWhiteSpace(request.LicenseKey) ||
            string.IsNullOrWhiteSpace(request.MachineHash))
        {
            return BadRequest(new
            {
                success = false,
                code = "invalid_request",
                message = "Email, license key and machine hash are required."
            });
        }

        try
        {
            var result = await _licensingService.ActivateAsync(request, cancellationToken);
            return Ok(result);
        }
        catch (SupabaseRpcException ex)
        {
            _logger.LogError(ex, "Supabase activation RPC failed with status {StatusCode}.", ex.StatusCode);
            return StatusCode(StatusCodes.Status502BadGateway, new
            {
                success = false,
                code = "supabase_rpc_failed",
                message = "License activation service failed."
            });
        }
    }

    [HttpPost("check")]
    public async Task<IActionResult> Check(
        [FromBody] CheckActivationRequest request,
        CancellationToken cancellationToken)
    {
        if (request.ActivationId == Guid.Empty || string.IsNullOrWhiteSpace(request.MachineHash))
        {
            return BadRequest(new
            {
                success = false,
                code = "invalid_request",
                message = "Activation id and machine hash are required."
            });
        }

        try
        {
            var result = await _licensingService.CheckAsync(request, cancellationToken);
            return Ok(result);
        }
        catch (SupabaseRpcException ex)
        {
            _logger.LogError(ex, "Supabase check RPC failed with status {StatusCode}.", ex.StatusCode);
            return StatusCode(StatusCodes.Status502BadGateway, new
            {
                success = false,
                code = "supabase_rpc_failed",
                message = "License check service failed."
            });
        }
    }

    [HttpPost("plugin-access")]
    public async Task<IActionResult> CheckPluginAccess(
        [FromBody] CheckPluginAccessRequest request,
        CancellationToken cancellationToken)
    {
        if (request.ActivationId == Guid.Empty ||
            string.IsNullOrWhiteSpace(request.MachineHash) ||
            string.IsNullOrWhiteSpace(request.PluginId))
        {
            return BadRequest(new
            {
                success = false,
                code = "invalid_request",
                message = "Activation id, machine hash and plugin id are required."
            });
        }

        try
        {
            var result = await _licensingService.CheckPluginAccessAsync(request, cancellationToken);
            return Ok(result);
        }
        catch (SupabaseRpcException ex)
        {
            _logger.LogError(ex, "Supabase plugin access RPC failed with status {StatusCode}.", ex.StatusCode);
            return StatusCode(StatusCodes.Status502BadGateway, new
            {
                success = false,
                code = "supabase_rpc_failed",
                message = "Plugin access service failed."
            });
        }
    }

    [HttpPost("plugin-usage")]
    public async Task<IActionResult> ReportPluginUsage(
        [FromBody] ReportPluginUsageRequest request,
        CancellationToken cancellationToken)
    {
        if (request.ActivationId == Guid.Empty ||
            request.ExecutionId == Guid.Empty ||
            string.IsNullOrWhiteSpace(request.MachineHash) ||
            string.IsNullOrWhiteSpace(request.PluginId) ||
            string.IsNullOrWhiteSpace(request.ExecutionStatus))
        {
            return BadRequest(new
            {
                success = false,
                code = "invalid_request",
                message = "Activation id, execution id, machine hash, plugin id and execution status are required."
            });
        }

        try
        {
            var result = await _licensingService.ReportPluginUsageAsync(request, cancellationToken);
            return Ok(result);
        }
        catch (SupabaseRpcException ex)
        {
            _logger.LogError(ex, "Supabase plugin usage RPC failed with status {StatusCode}.", ex.StatusCode);
            return StatusCode(StatusCodes.Status502BadGateway, new
            {
                success = false,
                code = "supabase_rpc_failed",
                message = "Plugin usage service failed."
            });
        }
    }

    private static string? GetString(JsonElement element, string propertyName)
    {
        if (element.ValueKind != JsonValueKind.Object ||
            !element.TryGetProperty(propertyName, out var property) ||
            property.ValueKind == JsonValueKind.Null)
        {
            return null;
        }

        return property.ValueKind == JsonValueKind.String
            ? property.GetString()
            : property.ToString();
    }

    private static bool? GetBoolean(JsonElement element, string propertyName)
    {
        if (element.ValueKind != JsonValueKind.Object ||
            !element.TryGetProperty(propertyName, out var property))
        {
            return null;
        }

        if (property.ValueKind == JsonValueKind.True)
        {
            return true;
        }

        if (property.ValueKind == JsonValueKind.False)
        {
            return false;
        }

        return null;
    }

    private static int? GetInt32(JsonElement element, string propertyName)
    {
        if (element.ValueKind != JsonValueKind.Object ||
            !element.TryGetProperty(propertyName, out var property))
        {
            return null;
        }

        if (property.ValueKind == JsonValueKind.Number && property.TryGetInt32(out var value))
        {
            return value;
        }

        return null;
    }

    private static DateTimeOffset? GetDateTimeOffset(JsonElement element, string propertyName)
    {
        var value = GetString(element, propertyName);
        return DateTimeOffset.TryParse(value, out var parsed) ? parsed : null;
    }
}
