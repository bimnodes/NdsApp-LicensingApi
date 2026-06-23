using NdsApp.LicensingApi.Options;
using NdsApp.LicensingApi.Services;

var builder = WebApplication.CreateBuilder(args);

builder.Services.Configure<BackendOptions>(
    builder.Configuration.GetSection(BackendOptions.SectionName));

builder.Services.Configure<SupabaseOptions>(
    builder.Configuration.GetSection(SupabaseOptions.SectionName));

builder.Services.Configure<StripeOptions>(
    builder.Configuration.GetSection(StripeOptions.SectionName));

builder.Services.Configure<ResendOptions>(
    builder.Configuration.GetSection(ResendOptions.SectionName));

builder.Services.AddHttpClient<ILicensingService, SupabaseLicensingService>();
builder.Services.AddHttpClient<ICustomerPortalContextService, SupabaseCustomerPortalContextService>();
builder.Services.AddHttpClient<IEmailService, ResendEmailService>();
builder.Services.AddScoped<IPaygBillingService, PaygBillingService>();

builder.Services.AddControllers();
builder.Services.AddEndpointsApiExplorer();
builder.Services.AddSwaggerGen();

var app = builder.Build();

if (app.Environment.IsDevelopment())
{
    app.UseSwagger();
    app.UseSwaggerUI();
}

app.UseHttpsRedirection();
app.UseAuthorization();
app.MapControllers();

app.Run();
