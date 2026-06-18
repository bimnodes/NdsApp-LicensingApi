namespace NdsApp.LicensingApi.Services;

public sealed class SupabaseRpcException : Exception
{
    public SupabaseRpcException(string message, int statusCode, string responseBody)
        : base(message)
    {
        StatusCode = statusCode;
        ResponseBody = responseBody;
    }

    public int StatusCode { get; }

    public string ResponseBody { get; }
}
