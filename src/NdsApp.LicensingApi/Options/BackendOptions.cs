namespace NdsApp.LicensingApi.Options;

public sealed class BackendOptions
{
    public const string SectionName = "Backend";

    public string ApiKey { get; init; } = string.Empty;
}
