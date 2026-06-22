# syntax=docker/dockerfile:1

FROM mcr.microsoft.com/dotnet/sdk:8.0 AS build
WORKDIR /src

COPY src/NdsApp.LicensingApi/NdsApp.LicensingApi.csproj src/NdsApp.LicensingApi/
RUN dotnet restore src/NdsApp.LicensingApi/NdsApp.LicensingApi.csproj

COPY . .
RUN dotnet publish src/NdsApp.LicensingApi/NdsApp.LicensingApi.csproj \
    -c Release \
    -o /app/publish \
    /p:UseAppHost=false

FROM mcr.microsoft.com/dotnet/aspnet:8.0 AS final
WORKDIR /app

EXPOSE 8080
COPY --from=build /app/publish .

ENTRYPOINT ["sh", "-c", "dotnet NdsApp.LicensingApi.dll --urls http://0.0.0.0:${PORT:-8080}"]
