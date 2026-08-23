using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Security.Cryptography;
using System.Text;
using Microsoft.Extensions.Options;
using NdsApp.LicensingApi.Models;
using NdsApp.LicensingApi.Options;

namespace NdsApp.LicensingApi.Services;

public sealed class ResendLicenseKeyEmailService : ILicenseKeyEmailService
{
    private const string ResendEmailEndpoint = "https://api.resend.com/emails";

    private readonly HttpClient _httpClient;
    private readonly ResendOptions _options;
    private readonly ILogger<ResendLicenseKeyEmailService> _logger;

    public ResendLicenseKeyEmailService(
        HttpClient httpClient,
        IOptions<ResendOptions> options,
        ILogger<ResendLicenseKeyEmailService> logger)
    {
        _httpClient = httpClient;
        _options = options.Value;
        _logger = logger;
    }

    public async Task SendAsync(LicenseKeyEmailRequest request, CancellationToken cancellationToken)
    {
        ValidateOptions();

        if (string.IsNullOrWhiteSpace(request.ToEmail))
        {
            throw new InvalidOperationException("The license email recipient is missing.");
        }

        if (string.IsNullOrWhiteSpace(request.LicenseKey))
        {
            throw new InvalidOperationException("The license key is missing.");
        }

        using var httpRequest = new HttpRequestMessage(HttpMethod.Post, ResendEmailEndpoint);
        httpRequest.Headers.Authorization = new AuthenticationHeaderValue("Bearer", _options.ApiKey);
        httpRequest.Headers.Add("Idempotency-Key", BuildIdempotencyKey(request.LicenseKey));
        httpRequest.Content = JsonContent.Create(BuildPayload(request));

        using var response = await _httpClient.SendAsync(httpRequest, cancellationToken);
        var responseBody = await response.Content.ReadAsStringAsync(cancellationToken);

        if (!response.IsSuccessStatusCode)
        {
            _logger.LogError(
                "Resend failed to send requested license key to {Email}. Status: {StatusCode}. Response: {ResponseBody}",
                request.ToEmail,
                response.StatusCode,
                responseBody);

            throw new InvalidOperationException("Resend failed to send the requested license key.");
        }

        _logger.LogInformation(
            "Requested NdsApp license key sent to {Email}. Resend response: {ResponseBody}",
            request.ToEmail,
            responseBody);
    }

    private Dictionary<string, object?> BuildPayload(LicenseKeyEmailRequest request)
    {
        var payload = new Dictionary<string, object?>
        {
            ["from"] = BuildFromAddress(),
            ["to"] = new[] { request.ToEmail },
            ["subject"] = "Tu licencia de NdsApp",
            ["html"] = BuildHtml(request),
            ["text"] = BuildText(request),
            ["tags"] = new[]
            {
                new { name = "category", value = "license_key_requested" }
            }
        };

        if (!string.IsNullOrWhiteSpace(_options.ReplyToEmail))
        {
            payload["reply_to"] = new[] { _options.ReplyToEmail };
        }

        return payload;
    }

    private string BuildFromAddress()
    {
        return string.IsNullOrWhiteSpace(_options.FromName)
            ? _options.FromEmail
            : $"{_options.FromName} <{_options.FromEmail}>";
    }

    private static string BuildHtml(LicenseKeyEmailRequest request)
    {
        var licenseKey = WebUtility.HtmlEncode(request.LicenseKey);
        var planName = WebUtility.HtmlEncode(ResolvePlanName(request));
        var validUntil = request.ValidUntil?.ToString("yyyy-MM-dd") ?? "Sin fecha de caducidad";
        var maxDevices = request.MaxDevices?.ToString() ?? "1";

        return $"""
            <p>Hola,</p>
            <p>Has solicitado una clave de licencia de <strong>NdsApp</strong>.</p>
            <p>Tu clave de licencia es:</p>
            <p style="font-size:18px;font-weight:700;letter-spacing:0.04em;"><code>{licenseKey}</code></p>
            <p>Detalles de la licencia:</p>
            <ul>
                <li>Producto: NdsApp</li>
                <li>Plan: {planName}</li>
                <li>Dispositivos permitidos: {maxDevices}</li>
                <li>Válida hasta: {validUntil}</li>
            </ul>
            <p>Para activar NdsApp, introduce este mismo email y la clave de licencia en la ventana de activación.</p>
            <p>Si no solicitaste esta clave, puedes ignorar este mensaje.</p>
            <p>Gracias,<br/>BIM Nodes</p>
            """;
    }

    private static string BuildText(LicenseKeyEmailRequest request)
    {
        var planName = ResolvePlanName(request);
        var validUntil = request.ValidUntil?.ToString("yyyy-MM-dd") ?? "Sin fecha de caducidad";
        var maxDevices = request.MaxDevices?.ToString() ?? "1";

        return $"""
            Hola,

            Has solicitado una clave de licencia de NdsApp.

            Tu clave de licencia es:
            {request.LicenseKey}

            Detalles de la licencia:
            - Producto: NdsApp
            - Plan: {planName}
            - Dispositivos permitidos: {maxDevices}
            - Válida hasta: {validUntil}

            Para activar NdsApp, introduce este mismo email y la clave de licencia en la ventana de activación.

            Si no solicitaste esta clave, puedes ignorar este mensaje.

            Gracias,
            BIM Nodes
            """;
    }

    private static string ResolvePlanName(LicenseKeyEmailRequest request)
    {
        if (!string.IsNullOrWhiteSpace(request.PlanName))
        {
            return request.PlanName;
        }

        return string.IsNullOrWhiteSpace(request.PlanCode)
            ? "NdsApp"
            : request.PlanCode;
    }

    private void ValidateOptions()
    {
        if (string.IsNullOrWhiteSpace(_options.ApiKey))
        {
            throw new InvalidOperationException("Resend API key is not configured.");
        }

        if (string.IsNullOrWhiteSpace(_options.FromEmail))
        {
            throw new InvalidOperationException("Resend sender email is not configured.");
        }
    }

    private static string BuildIdempotencyKey(string licenseKey)
    {
        var hash = SHA256.HashData(Encoding.UTF8.GetBytes(licenseKey));
        var hashText = Convert.ToHexString(hash).ToLowerInvariant();
        return $"ndsapp-license-key-request-{hashText[..32]}";
    }
}
