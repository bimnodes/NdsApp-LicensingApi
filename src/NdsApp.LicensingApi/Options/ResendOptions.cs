namespace NdsApp.LicensingApi.Options;

public sealed class ResendOptions
{
    public const string SectionName = "Resend";

    public string ApiKey { get; init; } = string.Empty;

    public string FromEmail { get; init; } = string.Empty;

    public string FromName { get; init; } = "NdsApp";

    public string ReplyToEmail { get; init; } = string.Empty;
}
