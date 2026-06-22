using Microsoft.AspNetCore.Mvc;
using NdsApp.LicensingApi.Models;
using NdsApp.LicensingApi.Services;

namespace NdsApp.LicensingApi.Controllers;

[ApiController]
[Route("api/licensing")]
public sealed class LicensingController : ControllerBase
{
    private readonly ILicensingService _licensingService;
    private readonly ILogger<LicensingController> _logger;

    public LicensingController(
        ILicensingService licensingService,
        ILogger<LicensingController> logger)
    {
        _licensingService = licensingService;
        _logger = logger;
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
}
