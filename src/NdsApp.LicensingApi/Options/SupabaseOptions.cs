namespace NdsApp.LicensingApi.Options;

public sealed class SupabaseOptions
{
    public const string SectionName = "Supabase";

    public string Url { get; init; } = string.Empty;

    public string ServiceRoleKey { get; init; } = string.Empty;
}
