FROM mcr.microsoft.com/dotnet/sdk:8.0 AS build
WORKDIR /src
COPY FabricOEESimulator/FabricOEESimulator.csproj FabricOEESimulator/
RUN dotnet restore FabricOEESimulator/FabricOEESimulator.csproj
COPY FabricOEESimulator/ FabricOEESimulator/
RUN dotnet publish FabricOEESimulator/FabricOEESimulator.csproj -c Release -o /app

FROM mcr.microsoft.com/dotnet/runtime:8.0
WORKDIR /app
COPY --from=build /app .
ENTRYPOINT ["dotnet", "FabricOEESimulator.dll"]
