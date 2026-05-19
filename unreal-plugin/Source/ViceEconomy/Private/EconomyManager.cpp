#include "EconomyManager.h"

#include "Dom/JsonObject.h"
#include "GenericPlatform/GenericPlatformHttp.h"
#include "Serialization/JsonReader.h"
#include "Serialization/JsonSerializer.h"

namespace
{
const FString WalletOperation = TEXT("FetchWalletBalance");
const FString InventoryOperation = TEXT("FetchInventory");
const FString MarketItemsOperation = TEXT("FetchMarketItems");
const FString DistrictPricesOperation = TEXT("FetchDistrictPrices");
const FString BuyOperation = TEXT("BuyItem");
const FString LaunderOperation = TEXT("StartLaundering");

bool DeserializeJsonArray(const FString& Content, TArray<TSharedPtr<FJsonValue>>& OutArray)
{
    const TSharedRef<TJsonReader<>> Reader = TJsonReaderFactory<>::Create(Content);
    return FJsonSerializer::Deserialize(Reader, OutArray);
}

bool DeserializeJsonObject(const FString& Content, TSharedPtr<FJsonObject>& OutObject)
{
    const TSharedRef<TJsonReader<>> Reader = TJsonReaderFactory<>::Create(Content);
    return FJsonSerializer::Deserialize(Reader, OutObject) && OutObject.IsValid();
}

FString SerializeJsonObject(const TSharedRef<FJsonObject>& Object)
{
    FString Content;
    const TSharedRef<TJsonWriter<>> Writer = TJsonWriterFactory<>::Create(&Content);
    FJsonSerializer::Serialize(Object, Writer);
    return Content;
}
}

void UEconomyManager::Initialize(FSubsystemCollectionBase& Collection)
{
    Super::Initialize(Collection);
}

void UEconomyManager::Deinitialize()
{
    Super::Deinitialize();
}

void UEconomyManager::SetUserJWT(const FString& JWT)
{
    UserJWT = JWT;
}

FHttpRequestRef UEconomyManager::CreateRequest(
    const FString& Operation,
    const FString& Url,
    const FString& Verb,
    bool bRequiresJwt)
{
    FHttpRequestRef Request = FHttpModule::Get().CreateRequest();
    Request->SetURL(Url);
    Request->SetVerb(Verb);
    Request->SetHeader(TEXT("X-Vice-Economy-Operation"), Operation);
    ApplyJsonHeaders(Request, bRequiresJwt);
    return Request;
}

void UEconomyManager::ApplyJsonHeaders(FHttpRequestRef Request, bool bRequiresJwt) const
{
    Request->SetHeader(TEXT("Accept"), TEXT("application/json"));

    if (!AnonKey.IsEmpty())
    {
        Request->SetHeader(TEXT("apikey"), AnonKey);
    }

    if (bRequiresJwt && !UserJWT.IsEmpty())
    {
        Request->SetHeader(TEXT("Authorization"), TEXT("Bearer ") + UserJWT);
    }
}

void UEconomyManager::BroadcastFailure(
    const FString& Operation,
    FHttpResponsePtr Response,
    const FString& FallbackMessage)
{
    FString Message = FallbackMessage;
    if (Response.IsValid() && !Response->GetContentAsString().IsEmpty())
    {
        Message = Response->GetContentAsString();
    }

    UE_LOG(LogTemp, Error, TEXT("%s failed: %s"), *Operation, *Message);
    OnRequestFailed.Broadcast(Operation, Message);
}

void UEconomyManager::FetchWalletBalance()
{
    FHttpRequestRef Request = CreateRequest(
        WalletOperation,
        SupabaseUrl + TEXT("/rest/v1/wallet_balances?select=cash_clean,cash_dirty&limit=1"),
        TEXT("GET"),
        true);

    Request->OnProcessRequestComplete().BindUObject(this, &UEconomyManager::OnFetchWalletResponse);
    Request->ProcessRequest();
}

void UEconomyManager::OnFetchWalletResponse(FHttpRequestPtr Request, FHttpResponsePtr Response, bool bSuccess)
{
    if (!bSuccess || !Response.IsValid() || Response->GetResponseCode() != 200)
    {
        BroadcastFailure(WalletOperation, Response, TEXT("Wallet request failed"));
        return;
    }

    TArray<TSharedPtr<FJsonValue>> Rows;
    if (!DeserializeJsonArray(Response->GetContentAsString(), Rows) || Rows.Num() == 0)
    {
        BroadcastFailure(WalletOperation, Response, TEXT("Wallet response was empty"));
        return;
    }

    const TSharedPtr<FJsonObject> Row = Rows[0]->AsObject();
    if (!Row.IsValid())
    {
        BroadcastFailure(WalletOperation, Response, TEXT("Wallet row was invalid"));
        return;
    }

    OnWalletUpdated.Broadcast(
        Row->GetIntegerField(TEXT("cash_clean")),
        Row->GetIntegerField(TEXT("cash_dirty")));
}

void UEconomyManager::FetchInventory()
{
    FHttpRequestRef Request = CreateRequest(
        InventoryOperation,
        SupabaseUrl + TEXT("/rest/v1/player_inventory?select=item_id,quantity&order=item_id.asc"),
        TEXT("GET"),
        true);

    Request->OnProcessRequestComplete().BindUObject(this, &UEconomyManager::OnFetchInventoryResponse);
    Request->ProcessRequest();
}

void UEconomyManager::OnFetchInventoryResponse(FHttpRequestPtr Request, FHttpResponsePtr Response, bool bSuccess)
{
    if (!bSuccess || !Response.IsValid() || Response->GetResponseCode() != 200)
    {
        BroadcastFailure(InventoryOperation, Response, TEXT("Inventory request failed"));
        return;
    }

    TArray<TSharedPtr<FJsonValue>> Rows;
    if (!DeserializeJsonArray(Response->GetContentAsString(), Rows))
    {
        BroadcastFailure(InventoryOperation, Response, TEXT("Inventory response was invalid"));
        return;
    }

    TArray<FViceInventoryEntry> Items;
    for (const TSharedPtr<FJsonValue>& RowValue : Rows)
    {
        const TSharedPtr<FJsonObject> Row = RowValue->AsObject();
        if (!Row.IsValid())
        {
            continue;
        }

        FViceInventoryEntry Entry;
        Entry.ItemId = Row->GetStringField(TEXT("item_id"));
        Entry.Quantity = Row->GetIntegerField(TEXT("quantity"));
        Items.Add(Entry);
    }

    OnInventoryUpdated.Broadcast(Items);
}

void UEconomyManager::FetchMarketItems()
{
    FHttpRequestRef Request = CreateRequest(
        MarketItemsOperation,
        SupabaseUrl + TEXT("/rest/v1/market_items?select=item_id,display_name,category,current_price&active=eq.true&order=item_id.asc"),
        TEXT("GET"),
        true);

    Request->OnProcessRequestComplete().BindUObject(this, &UEconomyManager::OnFetchMarketItemsResponse);
    Request->ProcessRequest();
}

void UEconomyManager::OnFetchMarketItemsResponse(FHttpRequestPtr Request, FHttpResponsePtr Response, bool bSuccess)
{
    if (!bSuccess || !Response.IsValid() || Response->GetResponseCode() != 200)
    {
        BroadcastFailure(MarketItemsOperation, Response, TEXT("Market items request failed"));
        return;
    }

    TArray<TSharedPtr<FJsonValue>> Rows;
    if (!DeserializeJsonArray(Response->GetContentAsString(), Rows))
    {
        BroadcastFailure(MarketItemsOperation, Response, TEXT("Market items response was invalid"));
        return;
    }

    TArray<FViceMarketItem> Items;
    for (const TSharedPtr<FJsonValue>& RowValue : Rows)
    {
        const TSharedPtr<FJsonObject> Row = RowValue->AsObject();
        if (!Row.IsValid())
        {
            continue;
        }

        FViceMarketItem Item;
        Item.ItemId = Row->GetStringField(TEXT("item_id"));
        Item.DisplayName = Row->GetStringField(TEXT("display_name"));
        Item.Category = Row->GetStringField(TEXT("category"));
        Item.CurrentPrice = Row->GetIntegerField(TEXT("current_price"));
        Items.Add(Item);
    }

    OnMarketItemsUpdated.Broadcast(Items);
}

void UEconomyManager::FetchDistrictPrices(const FString& DistrictId)
{
    const FString EncodedDistrictId = FGenericPlatformHttp::UrlEncode(DistrictId);
    FHttpRequestRef Request = CreateRequest(
        DistrictPricesOperation,
        SupabaseUrl + TEXT("/rest/v1/district_prices?select=district_id,item_id,current_price&district_id=eq.") + EncodedDistrictId + TEXT("&order=item_id.asc"),
        TEXT("GET"),
        false);

    Request->OnProcessRequestComplete().BindUObject(this, &UEconomyManager::OnFetchDistrictPricesResponse);
    Request->ProcessRequest();
}

void UEconomyManager::OnFetchDistrictPricesResponse(FHttpRequestPtr Request, FHttpResponsePtr Response, bool bSuccess)
{
    if (!bSuccess || !Response.IsValid() || Response->GetResponseCode() != 200)
    {
        BroadcastFailure(DistrictPricesOperation, Response, TEXT("District prices request failed"));
        return;
    }

    TArray<TSharedPtr<FJsonValue>> Rows;
    if (!DeserializeJsonArray(Response->GetContentAsString(), Rows))
    {
        BroadcastFailure(DistrictPricesOperation, Response, TEXT("District prices response was invalid"));
        return;
    }

    TArray<FViceDistrictPrice> Prices;
    for (const TSharedPtr<FJsonValue>& RowValue : Rows)
    {
        const TSharedPtr<FJsonObject> Row = RowValue->AsObject();
        if (!Row.IsValid())
        {
            continue;
        }

        FViceDistrictPrice Price;
        Price.DistrictId = Row->GetStringField(TEXT("district_id"));
        Price.ItemId = Row->GetStringField(TEXT("item_id"));
        Price.CurrentPrice = Row->GetIntegerField(TEXT("current_price"));
        Prices.Add(Price);
    }

    OnDistrictPricesUpdated.Broadcast(Prices);
}

void UEconomyManager::BuyItem(const FString& ItemId, int32 Quantity)
{
    FHttpRequestRef Request = CreateRequest(
        BuyOperation,
        SupabaseUrl + TEXT("/functions/v1/buy-item"),
        TEXT("POST"),
        true);
    Request->SetHeader(TEXT("Content-Type"), TEXT("application/json"));

    TSharedRef<FJsonObject> Body = MakeShared<FJsonObject>();
    Body->SetStringField(TEXT("item_id"), ItemId);
    Body->SetNumberField(TEXT("quantity"), Quantity);
    Request->SetContentAsString(SerializeJsonObject(Body));

    Request->OnProcessRequestComplete().BindUObject(this, &UEconomyManager::OnBuyResponse);
    Request->ProcessRequest();
}

void UEconomyManager::OnBuyResponse(FHttpRequestPtr Request, FHttpResponsePtr Response, bool bSuccess)
{
    if (!bSuccess || !Response.IsValid() || Response->GetResponseCode() != 200)
    {
        BroadcastFailure(BuyOperation, Response, TEXT("Buy item request failed"));
        return;
    }

    TSharedPtr<FJsonObject> Json;
    if (!DeserializeJsonObject(Response->GetContentAsString(), Json) || !Json->GetBoolField(TEXT("success")))
    {
        BroadcastFailure(BuyOperation, Response, TEXT("Buy item response was not successful"));
        return;
    }

    FetchWalletBalance();
    FetchInventory();
}

void UEconomyManager::StartLaundering(const FString& BusinessId, int64 Amount)
{
    FHttpRequestRef Request = CreateRequest(
        LaunderOperation,
        SupabaseUrl + TEXT("/functions/v1/start-laundering"),
        TEXT("POST"),
        true);
    Request->SetHeader(TEXT("Content-Type"), TEXT("application/json"));

    TSharedRef<FJsonObject> Body = MakeShared<FJsonObject>();
    Body->SetStringField(TEXT("business_id"), BusinessId);
    Body->SetNumberField(TEXT("amount"), static_cast<double>(Amount));
    Request->SetContentAsString(SerializeJsonObject(Body));

    Request->OnProcessRequestComplete().BindUObject(this, &UEconomyManager::OnLaunderResponse);
    Request->ProcessRequest();
}

void UEconomyManager::OnLaunderResponse(FHttpRequestPtr Request, FHttpResponsePtr Response, bool bSuccess)
{
    if (!bSuccess || !Response.IsValid() || Response->GetResponseCode() != 200)
    {
        BroadcastFailure(LaunderOperation, Response, TEXT("Start laundering request failed"));
        return;
    }

    FetchWalletBalance();
}
